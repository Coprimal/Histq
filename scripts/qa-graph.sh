#!/usr/bin/env bash
# Builds and inspects the fixtures of the graph QA campaign (Histq vs the reference client "Ref"),
# deterministic and isolated from the user's git config. Each fixture is built twice, once per side
# (histq, ref), at its final path with fixed dates, so both sides start with the same SHAs.
#
# Usage: scripts/qa-graph.sh list [--names]
#        scripts/qa-graph.sh reset <fixture...|all> [--root DIR] [--side histq|ref|both] [--histq-state DIR|none]
#        scripts/qa-graph.sh paths <fixture> [--root DIR]
#        scripts/qa-graph.sh state <fixture> <histq|ref> [--root DIR] [--trees]
#        scripts/qa-graph.sh compare <fixture> [--root DIR] [--trees] [--strict]
#        scripts/qa-graph.sh teammate <fixture> <action|list> [--side histq|ref|both] [--root DIR]
#        scripts/qa-graph.sh selfcheck [--root DIR]
#        scripts/qa-graph.sh doccheck [--docs DIR]
#
#   <root>/.histq-qa-graph               marker file (safety guard)
#   <root>/.home                         isolated HOME of the builders
#   <root>/<fixture>/<side>/repo         what the app opens
#   <root>/<fixture>/<side>/origin.git   bare remote (repo's origin = its absolute path)
#   <root>/<fixture>/<side>/teammate     clone of origin.git used by `teammate` (some fixtures)
#   <root>/<fixture>/<side>/wt-*         linked worktrees (worktree fixture)
#   <root>/<fixture>/<side>/sub-origin.git  submodule remote (submodule fixture)
#
# Root: --root > $QA_GRAPH_ROOT > ~/HistqQA/graph-interactive.
# Histq state folder cleaned by reset: --histq-state > $QA_HISTQ_STATE > <repo>/build/qa/view/state when it
# exists > none (warning). `none` turns the cleanup off. Only undo/<key>.json and repo-view/<key>.json of the
# reset repos and their linked worktrees are deleted (key = RepoSession.stateKey).
#
# Safety: refuses an empty root, /, $HOME, a non-folder, and any existing non-empty folder without the marker
# file .histq-qa-graph (a symlinked marker too). It deletes only <root>/<fixture>/<side> folders being reset
# (and <root>/.home), and refuses a reset while a *.lock file exists in the side's repo/.git.
#
# state prints a normalized dump of one side; compare diffs the two sides' dumps (sections 1-11, all with
# --strict) and prints "identical" (exit 0) or the diff (exit 1); reset ends each fixture built on both sides
# with compare. Commits are named by content ids (cid): SHA-1 over the tree, the parents' cids, the subject
# and the body's hash, so commits made by the two apps at other dates or with other identities compare equal.
# Stash commits (entries and their index/untracked parents) use the tree and parents only: their subjects
# embed short SHAs. --trees drops subject and body from every cid. Paths under the side folder print as
# <SIDE>. Both are read-only: GIT_OPTIONAL_LOCKS=0, hash-object without -w, a temp HOME.
#
# doccheck checks the run sheets (--docs, default <repo>/docs/qa/graph-interactive/*.md): fixture names exist,
# scenario ids are unique, every ⟦label⟧ fragment is found in App/, and no competitor name appears in the docs
# or in scripts/qa-graph*.sh (pattern read from the project CLAUDE.md at run time). Exit 0 + "doccheck: OK".
set -euo pipefail

die() { echo "qa-graph: $*" >&2; exit 1; }
warn() { echo "qa-graph: warning: $*" >&2; }
usage() {
  sed -n 's/^#        scripts\//usage: scripts\//p; s/^# Usage: scripts\//usage: scripts\//p' "$0" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MARKER=".histq-qa-graph"
SIDES_ALL="histq ref"
REAL_HOME=""
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then REAL_HOME="$(cd "$HOME" && pwd -P)"; fi

# shellcheck source=qa-graph-fixtures.sh
. "$SCRIPT_DIR/qa-graph-fixtures.sh"

# ---- Fixtures registry ----
fixture_names() { qa_fixture_table | cut -f1; }
is_fixture() {
  local f
  for f in $(fixture_names); do [ "$f" = "$1" ] && return 0; done
  return 1
}
builder_of() { echo "qa_build_$(echo "$1" | tr '-' '_')"; }

# ---- Root and safety guard ----
# root_arg <flag value> <flag given 0|1>: the root as given, before any check.
root_arg() {
  if [ "$2" = 1 ]; then echo "$1"
  elif [ -n "${QA_GRAPH_ROOT:-}" ]; then echo "$QA_GRAPH_ROOT"
  else
    [ -n "$REAL_HOME" ] || die "no \$HOME: pass --root"
    echo "$REAL_HOME/HistqQA/graph-interactive"
  fi
}

# guard_existing <dir>: refusals for an existing root; prints its physical path.
guard_existing() {
  local dir="$1" root
  [ -d "$dir" ] || die "refusing a non-folder root: $dir"
  root="$(cd "$dir" && pwd -P)"
  [ "$root" != "/" ] || die "refusing /"
  [ -z "$REAL_HOME" ] || [ "$root" != "$REAL_HOME" ] || die "refusing \$HOME"
  if [ -n "$(ls -A "$root")" ] && { [ ! -f "$root/$MARKER" ] || [ -L "$root/$MARKER" ]; }; then
    die "refusing non-empty folder without $MARKER: $root"
  fi
  echo "$root"
}

# check_root <dir>: refuses a bad root without writing anything (a missing root passes).
check_root() {
  [ -n "$1" ] || die "refusing an empty root argument"
  if [ -e "$1" ] || [ -L "$1" ]; then guard_existing "$1" > /dev/null; fi
}

# prepare_root <dir>: creates the root if missing, re-checks it, writes the marker; sets ROOT.
prepare_root() {
  check_root "$1"
  [ -e "$1" ] || [ -L "$1" ] || mkdir -p "$1"
  ROOT="$(guard_existing "$1")"
  : > "$ROOT/$MARKER"
}

# physical <path>: the path as realpath(3) gives it when it exists, else unchanged (minus a trailing slash).
physical() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P)
  else case "$1" in /) echo / ;; */) echo "${1%/}" ;; *) echo "$1" ;; esac
  fi
}

# ---- Isolation (builders run it in a subshell) ----
# qa_isolate [home]: HOME is <root>/.home unless given (state/compare pass a temp folder: they write nothing).
qa_isolate() {
  local home="${1:-${ROOT:?}/.home}"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS \
    GIT_TEMPLATE_DIR GIT_SEQUENCE_EDITOR XDG_CONFIG_HOME
  mkdir -p "$home"
  export HOME="$home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 TZ=UTC LC_ALL=C
  export GIT_AUTHOR_NAME="QA Fixture" GIT_AUTHOR_EMAIL="qa@histq.invalid"
  export GIT_COMMITTER_NAME="QA Fixture" GIT_COMMITTER_EMAIL="qa@histq.invalid"
  export GIT_CONFIG_COUNT=7 \
    GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main \
    GIT_CONFIG_KEY_1=commit.gpgSign GIT_CONFIG_VALUE_1=false \
    GIT_CONFIG_KEY_2=tag.gpgSign GIT_CONFIG_VALUE_2=false \
    GIT_CONFIG_KEY_3=core.autocrlf GIT_CONFIG_VALUE_3=false \
    GIT_CONFIG_KEY_4=gc.auto GIT_CONFIG_VALUE_4=0 \
    GIT_CONFIG_KEY_5=advice.detachedHead GIT_CONFIG_VALUE_5=false \
    GIT_CONFIG_KEY_6=protocol.file.allow GIT_CONFIG_VALUE_6=always
}

# Fixed, increasing dates: commit N at T0 + N hours (T0 = 2026-01-01 00:00 UTC). QA_N restarts at 0 per side.
T0=1767225600
QA_N=0
qa_date() { # $1 = commit number; sets the dates in the current shell
  export GIT_AUTHOR_DATE="$((T0 + $1 * 3600)) +0000" GIT_COMMITTER_DATE="$((T0 + $1 * 3600)) +0000"
}
qa_tick() { QA_N=$((QA_N + 1)); qa_date "$QA_N"; }
qa_commit() { qa_tick; git commit -q -m "$1"; }

# qa_local_config <repo>: the repo-local config of every app-facing repo, and .DS_Store in info/exclude.
qa_local_config() {
  local exclude
  git -C "$1" config user.name "QA Fixture"
  git -C "$1" config user.email "qa@histq.invalid"
  git -C "$1" config commit.gpgSign false
  git -C "$1" config tag.gpgSign false
  git -C "$1" config tag.forceSignAnnotated false
  git -C "$1" config gc.auto 0
  git -C "$1" config maintenance.auto false
  git -C "$1" config core.autocrlf false
  exclude="$(cd "$1" && git rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF .DS_Store "$exclude" 2>/dev/null || echo .DS_Store >> "$exclude"
}

# ---- Histq state cleanup ----
# qa_state_key <path>: RepoSession.stateKey = first 16 bytes of SHA-256(ProfileStore.repoKey) as lowercase hex,
# where repoKey is realpath(3) of the folder (no trailing slash).
qa_state_key() {
  printf '%s' "$(physical "$1")" | shasum -a 256 | cut -c1-32
}

# worktree_paths <repo>: the repo and its linked worktrees (physical paths), one per line; nothing if no repo.
worktree_paths() {
  [ -d "$1" ] || return 0
  physical "$1"
  (
    qa_isolate
    export GIT_OPTIONAL_LOCKS=0
    git -C "$1" worktree list --porcelain 2>/dev/null || true
  ) | while IFS= read -r line; do
    case "$line" in "worktree "*) physical "${line#worktree }" ;; esac
  done
}

# state_dir <flag value> <flag given 0|1>: the Histq state folder to clean, or empty for none.
state_dir() {
  local dir=""
  if [ "$2" = 1 ]; then dir="$1"
  elif [ -n "${QA_HISTQ_STATE:-}" ]; then dir="$QA_HISTQ_STATE"
  elif [ -d "$REPO_ROOT/build/qa/view/state" ]; then dir="$REPO_ROOT/build/qa/view/state"
  else warn "Histq state not cleaned (no --histq-state, \$QA_HISTQ_STATE or $REPO_ROOT/build/qa/view/state)"; return 0
  fi
  [ "$dir" != none ] || return 0
  [ -n "$dir" ] || die "refusing an empty --histq-state"
  [ -d "$dir" ] || die "no Histq state folder: $dir"
  (cd "$dir" && pwd -P)
}

# clean_state <state dir>: deletes undo/<key>.json and repo-view/<key>.json of each path read from stdin.
clean_state() {
  local state="$1" p key f
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    key="$(qa_state_key "$p")"
    for f in "$state/undo/$key.json" "$state/repo-view/$key.json"; do
      if [ -f "$f" ]; then rm -f "${f:?}"; echo "deleted Histq state: $f ($p)"; fi
    done
  done
}

# ---- State dump (read-only) ----
# Fixture and teammate commits have committer dates in [T0, T0 + 6000 h) (fixture: T0 + N h, teammate:
# T0 + 5000 h + slot). A commit whose committer date is outside was made by an app: its message goes to
# [messages] and its identity to [identity] ("rewritten" when its author date is still inside).
QA_WINDOW_HI=$((T0 + 6000 * 3600))

# Content ids in one pass (perl ships with macOS; shasum itself is a perl script using Digest::SHA).
# Args: <full|trees> <stashes file> <listed tips file> <out dir> <window lo> <window hi>.
# Stdin: `git log -z` records "H T P an cn at ct s b" separated by 0x1f. Stdout: "sha cid10 tree10" per commit.
# Writes <out>/commits, <out>/stash, <out>/messages, <out>/identity (section bodies).
QA_CID_PERL='
use strict;
use Digest::SHA qw(sha1_hex);
my ($mode, $stashf, $tipf, $out, $lo, $hi) = @ARGV;
my (%t, %p, %s, %b, %an, %cn, %at, %ct, %stash, %cid, %listed);
my @order;
{
  local $/ = "\0";
  while (my $r = <STDIN>) {
    chomp $r;
    $r =~ s/\A\n//;
    next if $r eq "";
    my ($h, $tree, $par, $an, $cn, $at, $ct, $subj, $body) = split /\x1f/, $r, 9;
    next if exists $t{$h};
    push @order, $h;
    $t{$h} = $tree;
    $p{$h} = [ grep { length } split / /, (defined $par ? $par : "") ];
    $an{$h} = $an; $cn{$h} = $cn; $at{$h} = $at; $ct{$h} = $ct;
    $s{$h} = defined $subj ? $subj : "";
    $body = "" unless defined $body;
    $body =~ s/\s+\z//;
    $b{$h} = $body;
  }
}
sub lines_of {
  my $f = shift;
  open(my $fh, "<", $f) or return ();
  my @l = <$fh>;
  close $fh;
  chomp @l;
  return grep { length } @l;
}
sub c10 { return substr($_[0], 0, 10); }
sub bh { my $h = shift; return $b{$h} eq "" ? "-" : sha1_hex($b{$h}); }
sub cid {
  my $h = shift;
  return $cid{$h} if defined $cid{$h};
  my $pj = join(",", map { exists $t{$_} ? cid($_) : "missing-$_" } @{$p{$h}});
  my $c;
  if ($stash{$h}) { $c = sha1_hex("stash\0$t{$h}\0$pj"); }
  elsif ($mode eq "trees") { $c = sha1_hex("tree\0$t{$h}\0$pj"); }
  else { $c = sha1_hex("commit\0$t{$h}\0$pj\0$s{$h}\0" . bh($h)); }
  $cid{$h} = $c;
  return $c;
}
sub pid { my $h = shift; return exists $t{$h} ? c10($cid{$h}) : "?" . c10($h); }
my @stashes = lines_of($stashf);
for my $w (@stashes) {
  next unless exists $t{$w};
  $stash{$w} = 1;
  my @pp = @{$p{$w}};
  for my $i (1, 2) { $stash{$pp[$i]} = 1 if defined $pp[$i] && exists $t{$pp[$i]}; }
}
cid($_) for @order;
my @stack = grep { exists $t{$_} } lines_of($tipf);
while (@stack) {
  my $h = pop @stack;
  next if $listed{$h}++;
  push @stack, grep { exists $t{$_} } @{$p{$h}};
}
print "$_ ", c10($cid{$_}), " ", c10($t{$_}), "\n" for @order;

my @rows;
for my $h (grep { $listed{$_} } @order) {
  my $par = join(",", map { pid($_) } @{$p{$h}});
  $par = "-" if $par eq "";
  my $row = c10($cid{$h}) . "  parents=$par  tree=" . c10($t{$h});
  if ($stash{$h}) { $row .= "  stash"; }
  elsif ($mode ne "trees") { my $x = bh($h); $row .= "  \"$s{$h}\"  body=" . ($x eq "-" ? "-" : c10($x)); }
  push @rows, $row;
}
open(my $C, ">", "$out/commits") or die "$out/commits: $!";
print $C "$_\n" for sort @rows;
close $C;

open(my $S, ">", "$out/stash") or die "$out/stash: $!";
my @msg;
my $n = 0;
for my $w (@stashes) {
  if (exists $t{$w}) {
    my @pp = @{$p{$w}};
    my $base = defined $pp[0] ? pid($pp[0]) : "-";
    my $it = defined $pp[1] && exists $t{$pp[1]} ? c10($t{$pp[1]}) : "-";
    my $ut = defined $pp[2] && exists $t{$pp[2]} ? c10($t{$pp[2]}) : "-";
    print $S "stash\@{$n} base=$base worktree-tree=" . c10($t{$w}) . " index-tree=$it untracked-tree=$ut\n";
    push @msg, "stash\@{$n} \"$s{$w}\"";
  } else {
    print $S "stash\@{$n} ?" . c10($w) . " (not a commit)\n";
  }
  $n++;
}
close $S;

my (%m, %id);
for my $h (grep { $listed{$_} && !$stash{$_} } @order) {
  next unless $ct{$h} < $lo || $ct{$h} >= $hi;
  my $k = c10($cid{$h}) . " $h";
  my $body = $b{$h} eq "" ? "" : join("", map { "    $_\n" } split /\n/, $b{$h});
  $m{$k} = c10($cid{$h}) . " \"$s{$h}\"\n$body";
  $id{$k} = c10($cid{$h}) . " author=$an{$h}"
    . ($at{$h} >= $lo && $at{$h} < $hi ? "  (rewritten)" : "  committer=$cn{$h}");
}
open(my $M, ">", "$out/messages") or die "$out/messages: $!";
print $M "$_\n" for @msg;
print $M $m{$_} for sort keys %m;
close $M;
open(my $I, ">", "$out/identity") or die "$out/identity: $!";
print $I "$id{$_}\n" for sort keys %id;
close $I;
'

# st_resolve <git path>: commit SHAs of the names on stdin (non-commits and missing names skipped).
st_resolve() {
  awk 'NF { print $0 "^{commit}" }' | git -C "$1" cat-file --batch-check='%(objectname) %(objecttype)' |
    awk '$2 == "commit" { print $1 }'
}

# st_map <git path> <dir> <full|trees>: content ids of the commits reachable from <dir>/tips (listed in
# [commits]) and <dir>/extra (ids only); <dir>/stashes lists the stash entries. Writes <dir>/map and the
# section bodies of QA_CID_PERL.
st_map() {
  local g="$1" o="$2"
  st_resolve "$g" < "$o/tips" > "$o/tips.sha"
  st_resolve "$g" < "$o/extra" > "$o/extra.sha"
  cat "$o/tips.sha" "$o/extra.sha" | awk '!seen[$0]++' > "$o/all.sha"
  if [ -s "$o/all.sha" ]; then
    git -C "$g" log --stdin -z --topo-order --reverse --no-show-signature \
      --format='%H%x1f%T%x1f%P%x1f%an <%ae>%x1f%cn <%ce>%x1f%at%x1f%ct%x1f%s%x1f%b' < "$o/all.sha"
  fi | perl -e "$QA_CID_PERL" "$3" "$o/stashes" "$o/tips.sha" "$o" "$T0" "$QA_WINDOW_HI" > "$o/map"
}

# st_ids <map>: replaces every full object id on stdin by its cid ("?<sha10>" when not a mapped commit), and
# every abbreviated one (7+ hex digits, as in sequencer/todo) that is a unique prefix of a mapped commit.
st_ids() {
  QA_MAP="$1" awk 'BEGIN { f = ENVIRON["QA_MAP"]; while ((getline l < f) > 0) { split(l, a, " "); m[a[1]] = a[2] } }
    {
      s = $0; o = ""
      while (match(s, /[0-9a-f]+/)) {
        w = substr(s, RSTART, RLENGTH)
        if (RLENGTH == 40 || RLENGTH == 64) w = (w in m) ? m[w] : "?" substr(w, 1, 10)
        else if (RLENGTH >= 7 && RLENGTH < 40) {
          hits = 0
          for (k in m) if (index(k, w) == 1) { hits++; hit = k }
          if (hits == 1) w = m[hit]
        }
        o = o substr(s, 1, RSTART - 1) w
        s = substr(s, RSTART + RLENGTH)
      }
      print o s
    }'
}

# st_hexes: the object ids (full or abbreviated, 7+ hex digits) found on stdin, one per line.
st_hexes() {
  awk '{ n = split($0, a, /[^0-9a-f]+/); for (i = 1; i <= n; i++) if (length(a[i]) >= 7 && length(a[i]) <= 64) print a[i] }'
}

# st_refs <git path> <map> [patterns...]: "<ref> <cid>", "<ref> tag <cid> \"<tag subject>\"" (annotated),
# "<ref> -> <target>" (symref), "<ref> <type> <id10>" (not a commit).
st_refs() {
  local g="$1" map="$2"
  shift 2
  git -C "$g" for-each-ref --format='%(refname)%09%(symref)%09%(objecttype)%09%(objectname)%09%(*objecttype)%09%(*objectname)%09%(contents:subject)' "$@" |
    QA_MAP="$map" awk -F'\t' 'BEGIN { f = ENVIRON["QA_MAP"]; while ((getline l < f) > 0) { split(l, a, " "); m[a[1]] = a[2] } }
      function id(x) { return (x in m) ? m[x] : "?" substr(x, 1, 10) }
      $2 != "" { print $1 " -> " $2; next }
      $3 == "commit" { print $1 " " id($4); next }
      $3 == "tag" && $5 == "commit" { print $1 " tag " id($6) " \"" $7 "\""; next }
      { print $1 " " $3 " " substr($4, 1, 10) }'
}

# st_worktree <repo> <dir>: status entries "XY path [<- orig]  <blob10|deleted|dir|symlink:<target>>".
st_worktree() {
  local repo="$1" o="$2" rec xy path orig kind
  if ! git -C "$repo" status --porcelain=v1 -z -uall > "$o/status" 2>/dev/null; then
    echo "(git status failed)"
    return 0
  fi
  while IFS= read -r -d '' rec; do
    xy="${rec:0:2}" path="${rec:3}" orig=""
    case "$xy" in R?|C?|?R|?C) IFS= read -r -d '' orig || true ;; esac
    if [ -L "$repo/$path" ]; then kind="symlink:$(readlink "$repo/$path")"
    elif [ -d "$repo/$path" ]; then kind=dir
    elif [ -f "$repo/$path" ]; then
      case "$path" in *$'\n'*|*$'\t'*) kind=unhashed ;; *) kind=hash ;; esac
    else kind=deleted
    fi
    printf '%s\t%s\t%s\t%s\n' "$xy" "$path" "$orig" "$kind"
  done < "$o/status" > "$o/wt.lst"
  awk -F'\t' '$4 == "hash" { print $2 }' "$o/wt.lst" | git -C "$repo" hash-object --stdin-paths > "$o/wt.hash"
  QA_HASH="$o/wt.hash" awk -F'\t' 'BEGIN { f = ENVIRON["QA_HASH"] }
    { k = $4; if (k == "hash") { k = "?"; if ((getline l < f) > 0) k = substr(l, 1, 10) }
      print $1 " " $2 ($3 != "" ? " <- " $3 : "") "  " k }' "$o/wt.lst"
}

# st_operation <repo> <map>: the stopped operation (merge, rebase, am, cherry-pick, revert, bisect) or none.
st_operation() {
  local repo="$1" map="$2" gd found=0 d kind nx last
  gd="$(git -C "$repo" rev-parse --absolute-git-dir)"
  if [ -f "$gd/MERGE_HEAD" ]; then
    echo "merge $(st_ids "$map" < "$gd/MERGE_HEAD" | tr '\n' ' ' | sed 's/ *$//')"
    echo "merge-msg \"$(head -n 1 "$gd/MERGE_MSG" 2>/dev/null || true)\""
    found=1
  fi
  for d in rebase-merge rebase-apply; do
    [ -d "$gd/$d" ] || continue
    found=1
    kind=rebase
    if [ "$d" = rebase-apply ] && [ -f "$gd/$d/applying" ]; then kind=am; fi
    echo "$kind ($d) head-name=$(cat "$gd/$d/head-name" 2>/dev/null || echo -)" \
      "onto=$( (cat "$gd/$d/onto" 2>/dev/null || echo -) | st_ids "$map")"
    if [ "$d" = rebase-merge ]; then
      echo "done $( (grep -v '^[[:space:]]*#' "$gd/$d/done" 2>/dev/null || true) | grep -c '[^[:space:]]' || true)"
      (grep -v '^[[:space:]]*#' "$gd/$d/git-rebase-todo" 2>/dev/null || true) | grep '[^[:space:]]' |
        st_ids "$map" | sed 's/^/todo /' || true
    else
      nx="$(cat "$gd/$d/next" 2>/dev/null || true)" last="$(cat "$gd/$d/last" 2>/dev/null || true)"
      case "$nx$last" in
        ''|*[!0-9]*) echo "done ? remaining ?" ;;
        *) echo "done $((nx - 1)) remaining $((last - nx + 1))" ;;
      esac
    fi
  done
  for d in CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert; do
    if [ -f "$gd/${d%%:*}" ]; then echo "${d#*:} $(st_ids "$map" < "$gd/${d%%:*}" | head -n 1)"; found=1; fi
  done
  if [ -f "$gd/sequencer/todo" ]; then
    (grep -v '^[[:space:]]*#' "$gd/sequencer/todo" || true) | grep '[^[:space:]]' | st_ids "$map" |
      sed 's/^/sequencer /' || true
    found=1
  fi
  if [ -f "$gd/BISECT_LOG" ]; then
    (grep '[^[:space:]]' "$gd/BISECT_LOG" || true) | st_ids "$map" | sed 's/^/bisect /'
    found=1
  fi
  [ "$found" = 1 ] || echo none
}

# st_origin <origin.git> <dir> <full|trees>: the bare remote's refs as cids (same algorithm).
st_origin() {
  local og="$1" o="$2"
  if [ ! -d "$og" ] || ! git -C "$og" rev-parse --git-dir > /dev/null 2>&1; then
    echo "(no origin.git)"
    return 0
  fi
  mkdir -p "$o"
  : > "$o/stashes"
  : > "$o/extra"
  { echo HEAD; git -C "$og" for-each-ref --format='%(refname)'; } > "$o/tips"
  st_map "$og" "$o" "$3"
  local head
  head="$(git -C "$og" symbolic-ref -q HEAD 2>/dev/null || true)"
  if [ -n "$head" ]; then echo "HEAD -> $head"; fi
  st_refs "$og" "$o/map"
}

# st_submodules <repo> <dir> <full|trees>: `submodule status --recursive`, commit as the sub-repo's cid
# (the "(describe)" part is dropped: it can be an abbreviated SHA).
st_submodules() {
  local repo="$1" o="$2" line pre rest sha path sub n=0 so
  if ! git -C "$repo" submodule status --recursive > "$o/subs" 2>/dev/null; then
    echo "(git submodule status failed)"
  fi
  while IFS= read -r line; do
    pre="${line:0:1}" rest="${line:1}"
    sha="${rest%% *}" rest="${rest#* }"
    path="${rest%% (*}"
    sub="$repo/$path"
    n=$((n + 1))
    if [ -e "$sub/.git" ] && git -C "$sub" cat-file -e "$sha^{commit}" 2>/dev/null; then
      so="$o/sub.$n"
      mkdir -p "$so"
      echo "$sha" > "$so/tips"
      : > "$so/extra"
      : > "$so/stashes"
      st_map "$sub" "$so" "$3"
      echo "$pre$(echo "$sha" | st_ids "$so/map") $path"
    else
      echo "$pre${sha:0:10} $path (unknown)"
    fi
  done < "$o/subs"
}

# st_dump <side dir> <full|trees>: the 12 sections of one side (raw paths). Needs $T and the read env.
st_dump() {
  local sd="$1" mode="$2" repo="$1/repo" o="$T/repo" gd ref h
  mkdir -p "$o"
  gd="$(git -C "$repo" rev-parse --absolute-git-dir)"
  { git -C "$repo" stash list --format=%H 2>/dev/null || true
    git -C "$repo" rev-parse -q --verify refs/stash 2>/dev/null || true
  } | awk 'NF && !seen[$0]++' > "$o/stashes"
  git -C "$repo" worktree list --porcelain > "$o/worktrees" 2>/dev/null || : > "$o/worktrees"
  { echo HEAD
    git -C "$repo" for-each-ref --format='%(refname)' refs/heads refs/tags refs/remotes refs/stash
    cat "$o/stashes"
    awk '/^HEAD / { print $2 }' "$o/worktrees"
  } > "$o/tips"
  { for h in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge/onto rebase-apply/onto \
      rebase-merge/done rebase-merge/git-rebase-todo sequencer/todo BISECT_LOG; do
      if [ -f "$gd/$h" ]; then cat "$gd/$h"; fi
    done
  } | st_hexes > "$o/extra"
  st_map "$repo" "$o" "$mode"

  echo "[head]"
  if ref="$(git -C "$repo" symbolic-ref -q HEAD 2>/dev/null)"; then
    if git -C "$repo" rev-parse -q --verify HEAD > /dev/null 2>&1; then echo "ref: $ref"; else echo "ref: $ref (unborn)"; fi
  else
    h="$(git -C "$repo" rev-parse -q --verify HEAD 2>/dev/null || true)"
    echo "detached $(echo "${h:-none}" | st_ids "$o/map")"
  fi
  echo "[refs]"
  st_refs "$repo" "$o/map" refs/heads refs/tags refs/remotes refs/stash
  echo "[upstream]"
  git -C "$repo" for-each-ref --format='%(refname:short)%09%(upstream:short)%09%(upstream:track)' refs/heads |
    awk -F'\t' '$2 != "" { print $1 " -> " $2 ($3 != "" ? " " $3 : "") }'
  echo "[commits]"
  cat "$o/commits"
  echo "[index]"
  git -C "$repo" ls-files -s 2>/dev/null || echo "(git ls-files failed)"
  echo "[worktree]"
  st_worktree "$repo" "$o"
  echo "[stash]"
  cat "$o/stash"
  echo "[operation]"
  st_operation "$repo" "$o/map"
  echo "[origin]"
  st_origin "$sd/origin.git" "$T/origin" "$mode"
  echo "[worktrees]"
  st_ids "$o/map" < "$o/worktrees"
  echo "[submodules]"
  st_submodules "$repo" "$o" "$mode"
  echo "[messages]"
  cat "$o/messages"
  echo "[identity]"
  cat "$o/identity"
  echo "[other-refs]"
  git -C "$repo" for-each-ref --format='%(refname) %(objectname)' |
    awk '$1 !~ /^refs\/(heads|tags|remotes)\// && $1 != "refs/stash"' | st_ids "$o/map"
}

# side_paths <path...>: replaces each literal path (longest first) by <SIDE>.
side_paths() {
  QA_P1="$1" QA_P2="${2:-}" awk '
    function rep(s, x,   i, o) { o = ""; while (x != "" && (i = index(s, x)) > 0) { o = o substr(s, 1, i - 1) "<SIDE>"; s = substr(s, i + length(x)) } return o s }
    BEGIN { a = ENVIRON["QA_P1"]; b = ENVIRON["QA_P2"]; if (length(b) > length(a)) { t = a; a = b; b = t } }
    { print rep(rep($0, a), b) }'
}

# state_out <root> <root as given> <fixture> <side> <full|trees>: the dump of one side, paths as <SIDE>.
state_out() {
  local sd="$1/$3/$4" given=""
  case "$2" in /*) given="${2%/}/$3/$4" ;; esac
  [ -d "$sd/repo" ] || die "no repo for $3/$4: $sd/repo (run: qa-graph.sh reset $3)"
  (
    set -e
    T="$(mktemp -d "${TMPDIR:-/tmp}/qa-graph-state.XXXXXX")"
    trap 'rm -rf "${T:?}"' EXIT
    qa_isolate "$T/home"
    # Read-only: no optional locks (no index refresh writes), no replace refs, no protocol.file.allow (key 6).
    export GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_COUNT=6
    st_dump "$sd" "$5"
  ) | side_paths "$sd" "$given"
}

# compare_fixture <root> <root as given> <fixture> <full|trees> <strict 0|1>: diff -u of the two sides
# (sections 1-11, all with strict); prints "identical" and returns 0, or the diff and returns 1.
compare_fixture() {
  local s t rc
  for s in $SIDES_ALL; do
    [ -d "$1/$3/$s/repo" ] || die "no repo for $3/$s: $1/$3/$s/repo (run: qa-graph.sh reset $3)"
  done
  t="$(mktemp -d "${TMPDIR:-/tmp}/qa-graph-compare.XXXXXX")"
  for s in $SIDES_ALL; do
    set +e
    state_out "$1" "$2" "$3" "$s" "$4" > "$t/$s"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then rm -rf "${t:?}"; die "state $3 $s failed"; fi
    if [ "$5" = 1 ]; then cp "$t/$s" "$t/$s.cmp"
    else awk '/^\[(messages|identity|other-refs)\]$/ { skip = 1; next } /^\[[a-z-]+\]$/ { skip = 0 } !skip' \
      "$t/$s" > "$t/$s.cmp"
    fi
  done
  set +e
  diff -u --label "$3/histq" --label "$3/ref" "$t/histq.cmp" "$t/ref.cmp"
  rc=$?
  set -e
  rm -rf "${t:?}"
  case "$rc" in
    0) echo identical; return 0 ;;
    1) return 1 ;;
    *) die "diff failed for $3" ;;
  esac
}

# ---- Commands ----
cmd_list() {
  case "${1:-}" in
    "") qa_fixture_table | awk -F'\t' '{ printf "%-12s %s\n", $1, $2 }' ;;
    --names) [ $# -eq 1 ] || usage; fixture_names ;;
    *) usage ;;
  esac
}

cmd_reset() {
  local fixtures="" root_flag="" root_given=0 side=both hs_flag="" hs_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage; root_flag="$2"; root_given=1; shift 2 ;;
      --side) [ $# -ge 2 ] || usage; side="$2"; shift 2 ;;
      --histq-state) [ $# -ge 2 ] || usage; hs_flag="$2"; hs_given=1; shift 2 ;;
      -?*) usage ;;
      *) fixtures="$fixtures $1"; shift ;;
    esac
  done
  [ -n "$fixtures" ] || usage
  local sides
  case "$side" in histq|ref) sides="$side" ;; both) sides="$SIDES_ALL" ;; *) die "--side must be histq, ref or both" ;; esac

  # Every check runs before anything is written or deleted.
  local dir state
  dir="$(root_arg "$root_flag" "$root_given")"
  check_root "$dir"
  local fx list=""
  for fx in $fixtures; do
    if [ "$fx" = all ]; then list="$list $(fixture_names | tr '\n' ' ')"
    else is_fixture "$fx" || die "unknown fixture: $fx (see: qa-graph.sh list)"; list="$list $fx"
    fi
  done
  list="$(echo $list | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')"
  state="$(state_dir "$hs_flag" "$hs_given")"
  prepare_root "$dir"

  local s lock
  for fx in $list; do
    for s in $sides; do
      if [ -d "$ROOT/$fx/$s/repo/.git" ]; then
        lock="$(find "$ROOT/$fx/$s/repo/.git" -name '*.lock' -print -quit 2>/dev/null || true)"
        [ -z "$lock" ] || die "refusing to reset $fx/$s: an app is mid-operation ($lock exists)"
      fi
    done
  done

  rm -rf "${ROOT:?}/.home"
  local old new rc
  for fx in $list; do
    for s in $sides; do
      old="$(worktree_paths "$ROOT/$fx/$s/repo")"
      rm -rf "${ROOT:?}/${fx:?}/${s:?}"
      mkdir -p "$ROOT/$fx/$s"
      set +e
      (
        set -e
        qa_isolate
        cd "$ROOT/$fx/$s"
        QA_N=0
        "$(builder_of "$fx")" "$ROOT/$fx/$s"
      )
      rc=$?
      set -e
      [ "$rc" -eq 0 ] || die "building $fx/$s failed"
      new="$(worktree_paths "$ROOT/$fx/$s/repo")"
      if [ -n "$state" ]; then
        printf '%s\n%s\n%s\n' "$ROOT/$fx/$s/repo" "$old" "$new" | awk 'NF && !seen[$0]++' | clean_state "$state"
      fi
      echo "built $fx/$s: $ROOT/$fx/$s/repo"
    done
    if [ "$side" = both ]; then
      set +e
      (compare_fixture "$ROOT" "$ROOT" "$fx" full 0) > "$ROOT/.home/compare.out"
      rc=$?
      set -e
      [ "$rc" -eq 0 ] || { cat "$ROOT/.home/compare.out"; die "$fx: the histq and ref sides differ after reset"; }
      echo "compared $fx: identical"
    fi
  done
}

cmd_paths() {
  local fx="" root_flag="" root_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage; root_flag="$2"; root_given=1; shift 2 ;;
      -?*) usage ;;
      *) [ -z "$fx" ] || usage; fx="$1"; shift ;;
    esac
  done
  [ -n "$fx" ] || usage
  is_fixture "$fx" || die "unknown fixture: $fx (see: qa-graph.sh list)"
  local dir root s p
  dir="$(root_arg "$root_flag" "$root_given")"
  check_root "$dir"
  root="$(physical "$dir")"
  for s in $SIDES_ALL; do
    echo "$s:"
    printf '  %-10s %s\n' repo "$root/$fx/$s/repo" origin "$root/$fx/$s/origin.git"
    for p in "$root/$fx/$s"/teammate "$root/$fx/$s"/wt-* "$root/$fx/$s"/sub-origin.git; do
      if [ -e "$p" ]; then printf '  %-10s %s\n' "$(basename "$p")" "$p"; fi
    done
  done
}

# state_args <args...>: parses [--root DIR] [--trees] [--strict] and positionals; sets SA_* variables.
state_args() {
  SA_POS="" SA_ROOT="" SA_ROOT_GIVEN=0 SA_MODE=full SA_STRICT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage; SA_ROOT="$2"; SA_ROOT_GIVEN=1; shift 2 ;;
      --trees) SA_MODE=trees; shift ;;
      --strict) SA_STRICT=1; shift ;;
      -?*) usage ;;
      *) SA_POS="$SA_POS $1"; shift ;;
    esac
  done
}

cmd_state() {
  state_args "$@"
  [ "$SA_STRICT" = 0 ] || usage
  set -- $SA_POS
  [ $# -eq 2 ] || usage
  is_fixture "$1" || die "unknown fixture: $1 (see: qa-graph.sh list)"
  case "$2" in histq|ref) ;; *) die "side must be histq or ref" ;; esac
  local dir
  dir="$(root_arg "$SA_ROOT" "$SA_ROOT_GIVEN")"
  check_root "$dir"
  [ -d "$dir" ] || die "no fixture root: $dir (run: qa-graph.sh reset $1)"
  state_out "$(physical "$dir")" "$dir" "$1" "$2" "$SA_MODE"
}

cmd_compare() {
  state_args "$@"
  set -- $SA_POS
  [ $# -eq 1 ] || usage
  is_fixture "$1" || die "unknown fixture: $1 (see: qa-graph.sh list)"
  local dir
  dir="$(root_arg "$SA_ROOT" "$SA_ROOT_GIVEN")"
  check_root "$dir"
  [ -d "$dir" ] || die "no fixture root: $dir (run: qa-graph.sh reset $1)"
  compare_fixture "$(physical "$dir")" "$dir" "$1" "$SA_MODE" "$SA_STRICT"
}

# ---- Teammate ----
# origin_refs <origin.git>: "<sha> <ref>" of every ref, or nothing.
origin_refs() {
  if [ -d "$1" ]; then git -C "$1" for-each-ref --format='%(objectname) %(refname)' 2>/dev/null || true; fi
}

cmd_teammate() {
  local pos="" side=both root_flag="" root_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage; root_flag="$2"; root_given=1; shift 2 ;;
      --side) [ $# -ge 2 ] || usage; side="$2"; shift 2 ;;
      -?*) usage ;;
      *) pos="$pos $1"; shift ;;
    esac
  done
  set -- $pos
  [ $# -ge 2 ] && [ $# -le 3 ] || usage
  local fx="$1" action="$2" name="${3:-}"
  is_fixture "$fx" || die "unknown fixture: $fx (see: qa-graph.sh list)"
  case " $(qa_teammate_fixtures) " in
    *" $fx "*) ;;
    *) die "refusing: fixture $fx has no teammate (teammate actions exist for: $(qa_teammate_fixtures))" ;;
  esac
  if [ "$action" = list ]; then
    [ -z "$name" ] || usage
    qa_teammate_table | awk -F'\t' '{ printf "%-22s %s\n", $1, $2 }'
    return 0
  fi
  [ -n "$(qa_tm_slot "$action")" ] || die "unknown teammate action: $action (see: qa-graph.sh teammate $fx list)"
  if [ "$action" = delete-branch ]; then
    [ -n "$name" ] || die "delete-branch needs a branch name (develop or hotfix)"
    git check-ref-format --branch "$name" > /dev/null 2>&1 || die "not a branch name: $name"
  else
    [ -z "$name" ] || usage
  fi
  local sides
  case "$side" in histq|ref) sides="$side" ;; both) sides="$SIDES_ALL" ;; *) die "--side must be histq, ref or both" ;; esac

  local dir root s
  dir="$(root_arg "$root_flag" "$root_given")"
  check_root "$dir"
  [ -d "$dir" ] || die "no fixture root: $dir (run: qa-graph.sh reset $fx)"
  root="$(physical "$dir")"
  for s in $sides; do
    [ -d "$root/$fx/$s/teammate/.git" ] || die "no teammate clone: $root/$fx/$s/teammate (run: qa-graph.sh reset $fx)"
    [ -d "$root/$fx/$s/origin.git" ] || die "no origin: $root/$fx/$s/origin.git (run: qa-graph.sh reset $fx)"
  done

  local before_h before_r
  before_h="$(origin_refs "$root/$fx/histq/origin.git")"
  before_r="$(origin_refs "$root/$fx/ref/origin.git")"
  if [ -d "$root/$fx/histq/origin.git" ] && [ -d "$root/$fx/ref/origin.git" ] && [ "$before_h" != "$before_r" ]; then
    echo "note: the histq and ref origins differ before this action (the apps pushed different commits, or the" \
      "teammate ran on one side only): the action still runs, but the two sides may get different SHAs"
  fi

  local rc=0 r
  for s in $sides; do
    set +e
    (
      set -e
      TH="$(mktemp -d "${TMPDIR:-/tmp}/qa-graph-teammate.XXXXXX")"
      trap 'rm -rf "${TH:?}"' EXIT
      qa_isolate "$TH/home"
      QA_DIR="$root/$fx/$s"
      qa_tm_run "$fx" "$s" "$action" "$name"
    )
    r=$?
    set -e
    if [ "$r" -ne 0 ]; then echo "qa-graph: teammate $fx/$s: $action failed" >&2; rc=1; fi
  done
  if [ "$side" = both ]; then
    if [ "$(origin_refs "$root/$fx/histq/origin.git")" = "$(origin_refs "$root/$fx/ref/origin.git")" ]; then
      echo "origins: histq and ref have the same refs"
    else
      echo "origins: histq and ref refs differ"
    fi
  fi
  return "$rc"
}

# ---- Selfcheck ----
# Every premise runs in a subshell (set -e, isolation env with a temp HOME) on a throwaway copy of the histq
# side (cp -R; local-only git commands) or, for premises that push or fetch, on fixtures built into a temp root.
# A fixture missing under the root is built into a temp root. The fixtures under the root are only read.
SC_T="" SC_ROOT="" SC_OK=0 SC_FAIL=0

# sc_fail <detail>: ends the premise with a detail line (read by sc_run).
sc_fail() { echo "detail: $*" >&2; exit 1; }

# sc_want <what> <actual> <expected>
sc_want() {
  [ "$2" = "$3" ] || sc_fail "$1: got '$(printf '%s' "$2" | tr '\n' '|')', want '$(printf '%s' "$3" | tr '\n' '|')'"
}

# sc_build <fixture> <temp root> <side histq|both>: builds the fixture into a temp root (no Histq state cleanup).
sc_build() {
  local rc
  set +e
  (cmd_reset "$1" --root "$2" --side "$3" --histq-state none) > "$2.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || sc_fail "building $1 into a temp root failed: $(grep . "$2.log" | tail -n 1 || true)"
}

# sc_copy <fixture>: a fresh throwaway copy of the fixture's histq side; prints its folder.
sc_copy() {
  local src d
  if [ -n "$SC_ROOT" ] && [ -d "$SC_ROOT/$1/histq/repo" ]; then src="$SC_ROOT/$1/histq"
  else
    src="$SC_T/build-$1/$1/histq"
    [ -d "$src/repo" ] || sc_build "$1" "$SC_T/build-$1" histq
  fi
  d="$(mktemp -d "$SC_T/copy.XXXXXX")"
  cp -Rp "$src" "$d/histq"
  echo "$d/histq"
}

# sc_run <name> <function> [args...]: prints "ok <name>" or "FAIL <name>: <detail>".
sc_run() {
  local name="$1" log rc detail
  shift
  log="$(mktemp "$SC_T/log.XXXXXX")"
  set +e
  (
    set -e
    qa_isolate "$SC_T/home"
    "$@"
  ) > "$log" 2>&1 < /dev/null
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "ok $name"
    SC_OK=$((SC_OK + 1))
  else
    detail="$( (grep '^detail: ' "$log" || true) | tail -n 1 | sed 's/^detail: //')"
    [ -n "$detail" ] || detail="$( (grep . "$log" || true) | tail -n 1)"
    echo "FAIL $name: ${detail:-exit $rc}"
    SC_FAIL=$((SC_FAIL + 1))
  fi
}

sc_unmerged() { git diff --name-only --diff-filter=U | tr '\n' ' ' | sed 's/ $//'; }
sc_wip() { git status --porcelain -uall; git diff --cached | shasum; git diff | shasum; }
sc_subject() { git log -1 --format=%s "$1"; }
sc_stashes() { qa_count "$(git stash list | wc -l)"; }

# sc_sha <rev> <subject>: the commit with this exact subject reachable from <rev> (dies when absent).
sc_sha() {
  local h
  h="$(git log --format='%H%x09%s' "$1" | QA_S="$2" awk -F'\t' '!f && $2 == ENVIRON["QA_S"] { print $1; f = 1 }')"
  [ -n "$h" ] || sc_fail "no commit \"$2\" on $1"
  echo "$h"
}

# sc_todo <file> <action:subject>...: writes a rebase todo (subjects looked up on HEAD).
sc_todo() {
  local f="$1" e h
  shift
  : > "$f"
  for e in "$@"; do
    h="$(sc_sha HEAD "${e#*:}")"
    echo "${e%%:*} $h ${e#*:}" >> "$f"
  done
}

# sc_rebase_i <upstream> <todo>: interactive rebase with a scripted todo; git's exit status.
sc_rebase_i() {
  GIT_SEQUENCE_EDITOR="cp '$2'" git rebase -q -i --no-autosquash "$1" > /dev/null 2>&1
}

# sc_stash_index <message>: n of the stash entry "On <branch>: <message>" (dies when absent).
sc_stash_index() {
  local n
  n="$(git stash list --format=%gs | QA_S="$1" awk '!f && $0 ~ /^On [^:]*: / { sub(/^On [^:]*: /, ""); if ($0 == ENVIRON["QA_S"]) { print NR - 1; f = 1 } }')"
  [ -n "$n" ] || sc_fail "no stash \"$1\""
  echo "$n"
}

# Premise 1: core-wip carries the WIP to hotfix, refuses feature/login.
sc_p_wip_refuse() {
  local before out
  cd "$(sc_copy core-wip)/repo"
  before="$(sc_wip)"
  if out="$(git checkout feature/login 2>&1)"; then sc_fail "checkout feature/login succeeded"; fi
  case "$out" in *"would be overwritten"*) ;; *) sc_fail "checkout feature/login: $(echo "$out" | head -n 1)" ;; esac
  sc_want HEAD "$(git symbolic-ref HEAD)" refs/heads/main
  sc_want "WIP unchanged" "$(sc_wip)" "$before"
}
sc_p_wip_carry() {
  local before
  cd "$(sc_copy core-wip)/repo"
  before="$(sc_wip)"
  git checkout -q hotfix > /dev/null 2>&1 || sc_fail "checkout hotfix failed"
  sc_want HEAD "$(git symbolic-ref HEAD)" refs/heads/hotfix
  sc_want "WIP carried" "$(sc_wip)" "$before"
}

# Premise 2: stashes.
sc_p_stash_conflict() {
  cd "$(sc_copy stashes)/repo"
  sc_want "stash@{2}" "$(git stash list --format=%gs | sed -n 3p)" "On (no branch): retry tweak"
  if git stash pop -q 'stash@{2}' > /dev/null 2>&1; then sc_fail "stash pop stash@{2} did not conflict"; fi
  sc_want unmerged "$(sc_unmerged)" config.ini
  sc_want "stash kept" "$(sc_stashes)" 4
}
sc_p_stash_clean() {
  cd "$(sc_copy stashes)/repo"
  sc_want "stash@{3}" "$(git stash list --format=%gs | sed -n 4p)" "On main: notes edit"
  git stash apply -q 'stash@{3}' > /dev/null 2>&1 || sc_fail "stash apply stash@{3} failed"
  sc_want unmerged "$(sc_unmerged)" ""
  sc_want status "$(git status --porcelain -uall)" " M docs/notes.md"
}

# Premise 3 and 7: interactive rebases of topic/series (onto c05).
sc_series() {
  cd "$(sc_copy core)/repo"
  git checkout -q topic/series
  C05="$(sc_sha main "Update README intro")"
  S6TREE="$(git rev-parse 'HEAD^{tree}')"
  TODO="$(pwd -P)/../todo"
}
sc_p_move_s6() {
  sc_series
  sc_todo "$TODO" "pick:Series: add step 1" "pick:Series: add step 2" "pick:Series: extend step 3" \
    "pick:Series: add step 3" "pick:fixup! Series: add step 2" "pick:Series: fix typo in step 1"
  if sc_rebase_i "$C05" "$TODO"; then sc_fail "moving s6 above s3 did not conflict"; fi
  sc_want "rebase stopped" "$([ -d .git/rebase-merge ] && echo yes)" yes
  sc_want "stopped at" "$(sc_subject REBASE_HEAD)" "Series: extend step 3"
  sc_want unmerged "$(sc_unmerged)" docs/step-3.md
}
sc_p_move_s5() {
  sc_series
  sc_todo "$TODO" "pick:Series: add step 1" "pick:Series: add step 2" "pick:Series: add step 3" \
    "pick:Series: fix typo in step 1" "pick:fixup! Series: add step 2" "pick:Series: extend step 3"
  sc_rebase_i "$C05" "$TODO" || sc_fail "moving s5 above s4 stopped ($(sc_unmerged))"
  sc_want "same tree" "$(git rev-parse 'HEAD^{tree}')" "$S6TREE"
  sc_want "s4 above s5" "$(sc_subject HEAD~1)" "fixup! Series: add step 2"
}
sc_p_fixup_s4() {
  sc_series
  sc_todo "$TODO" "pick:Series: add step 1" "pick:Series: add step 2" "fixup:fixup! Series: add step 2" \
    "pick:Series: add step 3" "pick:Series: fix typo in step 1" "pick:Series: extend step 3"
  sc_rebase_i "$C05" "$TODO" || sc_fail "fixup s4 into s2 stopped ($(sc_unmerged))"
  sc_want "same tree" "$(git rev-parse 'HEAD^{tree}')" "$S6TREE"
  sc_want "commit count" "$(git rev-list --count "$C05..HEAD")" 5
}
sc_p_squash() {
  local s3tree
  sc_series
  s3tree="$(git rev-parse "$(sc_sha HEAD "Series: add step 3")^{tree}")"
  sc_todo "$TODO" "pick:Series: add step 1" "squash:Series: add step 2" "squash:Series: add step 3" \
    "pick:fixup! Series: add step 2" "pick:Series: fix typo in step 1" "pick:Series: extend step 3"
  sc_rebase_i "$C05" "$TODO" || sc_fail "squash s1..s3 stopped ($(sc_unmerged))"
  sc_want "commit count" "$(git rev-list --count "$C05..HEAD")" 4
  sc_want "squashed tree = s3 tree" "$(git rev-parse 'HEAD~3^{tree}')" "$s3tree"
}
sc_p_with_merge() {
  local w1
  cd "$(sc_copy rebase-lab)/repo"
  w1="$(sc_sha with-merge "Merge test: base")"
  sc_want "merges in w1^..with-merge" "$(git rev-list --merges --count "$w1^..with-merge")" 1
}

# Premise 4: conflicts.
sc_p_cherry_pick() {
  cd "$(sc_copy conflicts)/repo"
  if git cherry-pick "$(sc_sha conflict/a "Conflict A: app line 12, new file, drop notes")" > /dev/null 2>&1; then
    sc_fail "cherry-pick k1 did not conflict"
  fi
  sc_want unmerged "$(sc_unmerged)" "docs/notes.md src/app.txt src/new.txt"
}
sc_p_rebase_stops() {
  cd "$(sc_copy conflicts)/repo"
  git checkout -q conflict/a
  if git rebase main > /dev/null 2>&1; then sc_fail "rebase conflict/a onto main did not stop"; fi
  sc_want "first stop" "$(sc_subject REBASE_HEAD)" "Conflict A: app line 12, new file, drop notes"
  sc_want "first stop unmerged" "$(sc_unmerged)" "docs/notes.md src/app.txt src/new.txt"
  git add -A
  if git rebase --continue > /dev/null 2>&1; then sc_fail "rebase did not stop at k2"; fi
  sc_want "second stop" "$(sc_subject REBASE_HEAD)" "Conflict A: timeout 90"
  sc_want "second stop unmerged" "$(sc_unmerged)" config.ini
}
sc_p_revert() {
  cd "$(sc_copy conflicts)/repo"
  if git revert --no-edit "$(sc_sha main "Tune config timeout")" > /dev/null 2>&1; then sc_fail "revert c03 did not conflict"; fi
  sc_want unmerged "$(sc_unmerged)" config.ini
}
sc_p_merge() {
  cd "$(sc_copy conflicts)/repo"
  if git merge --no-edit conflict/a > /dev/null 2>&1; then sc_fail "merge conflict/a did not conflict"; fi
  sc_want unmerged "$(sc_unmerged)" "config.ini docs/notes.md src/app.txt src/new.txt"
}

# Premise 5: stopped operations.
sc_p_stop_merge() {
  cd "$(sc_copy stop-merge)/repo"
  sc_want MERGE_HEAD "$(sc_subject MERGE_HEAD)" "Conflict A: util tweak"
  sc_want unmerged "$(sc_unmerged)" "config.ini docs/notes.md src/app.txt src/new.txt"
}
sc_p_stop_rebase() {
  cd "$(sc_copy stop-rebase)/repo"
  sc_want "rebase-merge" "$([ -d .git/rebase-merge ] && echo yes)" yes
  sc_want msgnum "$(cat .git/rebase-merge/msgnum)" 1
  sc_want end "$(cat .git/rebase-merge/end)" 3
  sc_want "stopped at" "$(sc_subject REBASE_HEAD)" "Conflict A: app line 12, new file, drop notes"
  sc_want unmerged "$(sc_unmerged)" "docs/notes.md src/app.txt src/new.txt"
}
sc_p_stop_edit() {
  cd "$(sc_copy stop-edit)/repo"
  sc_want "rebase-merge" "$([ -d .git/rebase-merge ] && echo yes)" yes
  sc_want "last done" "$(tail -n 1 .git/rebase-merge/done | cut -d' ' -f1)" edit
  sc_want HEAD "$(sc_subject HEAD)" "Series: add step 3"
  sc_want unmerged "$(sc_unmerged)" ""
}

# Premise 8: detached, worktree, submodule.
sc_p_detached() {
  cd "$(sc_copy detached)/repo"
  sc_want "symbolic-ref" "$(git symbolic-ref -q HEAD || echo detached)" detached
  sc_want HEAD "$(sc_subject HEAD)" "Detached experiment"
  sc_want "branches containing x1" "$(git for-each-ref --contains HEAD refs/heads)" ""
}
sc_p_worktree() {
  cd "$(sc_copy worktree)/repo"
  sc_want "worktrees" "$(git worktree list --porcelain | grep -c '^worktree ')" 3
}
sc_p_submodule() {
  local st
  cd "$(sc_copy submodule)/repo"
  st="$(git submodule status)"
  sc_want "submodule lines" "$(echo "$st" | grep -c .)" 1
  sc_want "submodule prefix" "$(echo "$st" | cut -c1)" " "
  sc_want "submodule path" "$(echo "$st" | awk '{ print $2 }')" libs/sub
}

# Premise 6: teammate actions and the marathon pull.
# sc_push_root <fixture>: both sides of the fixture built into $SC_T/push-<fixture> (once); prints the root.
sc_push_root() {
  local r="$SC_T/push-$1"
  [ -d "$r/$1/ref/repo" ] || sc_build "$1" "$r" both
  echo "$r"
}

# sc_teammate <root> <fixture> <action> [name]: runs the action on both sides.
sc_teammate() {
  local root="$1" log rc
  shift
  log="$(mktemp "$SC_T/tm.XXXXXX")"
  set +e
  (cmd_teammate "$@" --side both --root "$root") > "$log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || sc_fail "teammate $*: $( (grep . "$log" || true) | tail -n 1)"
  grep -q '^origins: histq and ref have the same refs$' "$log" || sc_fail "teammate $*: origins differ"
  ! grep -q '^note: ' "$log" || sc_fail "teammate $*: origins differed before the action"
}

# sc_og <root> <fixture> <rev>: the subject of <rev> in the histq origin (or "-").
sc_og() { git --git-dir="$1/$2/histq/origin.git" log -1 --format=%s "$3" 2>/dev/null || echo -; }

sc_p_actions() {
  local fx="$1" root a og
  root="$(sc_push_root "$fx")"
  og="$root/$fx/histq/origin.git"
  for a in push-main push-main-clean rewrite-main force-push-feature push-feature push-branch \
    "delete-branch develop" push-tag move-tag push-main push-branch push-tag; do
    sc_teammate "$root" "$fx" $a
    case "$a" in
      push-main) sc_want "$a: main" "$(sc_og "$root" "$fx" main)" "Teammate: update notes" ;;
      push-main-clean) sc_want "$a: main" "$(sc_og "$root" "$fx" main)" "Teammate: add changelog" ;;
      rewrite-main)
        sc_want "$a: main" "$(sc_og "$root" "$fx" main)" "Teammate: add contributing guide (v2)"
        sc_want "$a: main^" "$(sc_og "$root" "$fx" main^)" "Raise retry count" ;;
      force-push-feature)
        sc_want "$a: feature/login" "$(sc_og "$root" "$fx" feature/login)" "Add login tests (teammate)"
        sc_want "$a: feature/login^" "$(sc_og "$root" "$fx" feature/login^)" "Validate login input" ;;
      push-feature)
        sc_want "$a: feature/login" "$(sc_og "$root" "$fx" feature/login)" "Teammate: login error text" ;;
      push-branch)
        sc_want "$a: teammate/idea" "$(sc_og "$root" "$fx" teammate/idea)" "Idea: refine"
        sc_want "$a: teammate/idea~2" "$(git --git-dir="$og" rev-parse teammate/idea~2)" \
          "$(git --git-dir="$og" rev-parse main)" ;;
      "delete-branch develop")
        sc_want "$a" "$(git --git-dir="$og" for-each-ref refs/heads/develop)" "" ;;
      push-tag)
        sc_want "$a: v1.2 type" "$(git --git-dir="$og" cat-file -t v1.2)" tag
        sc_want "$a: v1.2 target" "$(git --git-dir="$og" rev-parse 'v1.2^{commit}')" \
          "$(git --git-dir="$og" rev-parse main)" ;;
      move-tag) sc_want "$a: v1.0" "$(sc_og "$root" "$fx" 'v1.0^{commit}')" "Update README intro" ;;
    esac
  done
}

# sc_p_marathon_pull <side> <ours|theirs>: on that side of the temp marathon (after push-main on both sides):
# stash the WIP, pull --rebase stops at L1 vs T2, resolve with one side, continue, pop the two fixture stashes.
sc_p_marathon_pull() {
  local root p n
  root="$(sc_push_root marathon)"
  [ -n "$(git --git-dir="$root/marathon/histq/origin.git" log --format=%s main | grep -x 'Teammate: update notes')" ] ||
    sc_teammate "$root" marathon push-main
  cd "$root/marathon/$1/repo"
  sc_want "WIP" "$(git status --porcelain -uall)" " M src/app.txt"
  git stash push -q -m "qa wip" > /dev/null || sc_fail "stash of the WIP failed"
  sc_want "stashes" "$(git stash list --format=%gs)" \
    "$(printf '%s\n' 'On main: qa wip' 'On main: with untracked' 'On main: readme edit')"
  if git pull -q --rebase > /dev/null 2>&1; then sc_fail "pull --rebase of main did not conflict"; fi
  sc_want "stopped at" "$(sc_subject REBASE_HEAD)" "Local: tweak notes"
  sc_want "upstream" "$(sc_subject HEAD)" "Teammate: update notes"
  sc_want unmerged "$(sc_unmerged)" docs/notes.md
  git checkout -q "--$2" -- docs/notes.md
  git add docs/notes.md
  git rebase --continue > /dev/null 2>&1 || sc_fail "rebase --continue after taking $2 failed ($(sc_unmerged))"
  sc_want "rebase done" "$([ -d .git/rebase-merge ] || [ -d .git/rebase-apply ] || echo done)" done
  sc_want "main tip" "$(sc_subject HEAD)" "Local: notes footer"
  git merge-base --is-ancestor origin/main HEAD || sc_fail "origin/main is not in main after the pull"
  for p in "with untracked" "readme edit"; do
    n="$(sc_stash_index "$p")"
    git stash pop -q "stash@{$n}" > /dev/null 2>&1 || sc_fail "stash pop \"$p\" failed ($(sc_unmerged))"
    sc_want "unmerged after pop \"$p\"" "$(sc_unmerged)" ""
  done
  sc_want "stashes left" "$(git stash list --format=%gs)" "On main: qa wip"
  sc_want "status" "$(git status --porcelain -uall)" \
    "$(printf '%s\n' ' M README.md' ' M src/app.txt' '?? tmp/cache.txt')"
}

cmd_selfcheck() {
  local root_flag="" root_given=0 dir start
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || usage; root_flag="$2"; root_given=1; shift 2 ;;
      *) usage ;;
    esac
  done
  dir="$(root_arg "$root_flag" "$root_given")"
  check_root "$dir"
  SC_ROOT=""
  if [ -d "$dir" ]; then SC_ROOT="$(physical "$dir")"; fi
  start="$(date +%s)"
  SC_T="$(mktemp -d "${TMPDIR:-/tmp}/qa-graph-selfcheck.XXXXXX")"
  SC_T="$(cd "$SC_T" && pwd -P)"
  trap 'rm -rf "${SC_T:?}"' EXIT
  echo "selfcheck: fixtures from ${SC_ROOT:-(none)}; missing ones and the push premises use temp roots"

  sc_run "core-wip: checkout feature/login is refused, WIP unchanged" sc_p_wip_refuse
  sc_run "core-wip: checkout hotfix carries the WIP" sc_p_wip_carry
  sc_run "stashes: pop stash@{2} (retry tweak) conflicts in config.ini, stash kept" sc_p_stash_conflict
  sc_run "stashes: stash@{3} (notes edit) applies cleanly" sc_p_stash_clean
  sc_run "core: moving s6 above s3 conflicts on docs/step-3.md" sc_p_move_s6
  sc_run "core: moving s5 above s4 does not conflict" sc_p_move_s5
  sc_run "core: fixup s4 into s2 does not conflict" sc_p_fixup_s4
  sc_run "conflicts: cherry-pick k1 onto main gives 3 unmerged paths" sc_p_cherry_pick
  sc_run "conflicts: rebase conflict/a onto main stops at k1 (3 paths) then k2 (config.ini)" sc_p_rebase_stops
  sc_run "conflicts: revert c03 on main conflicts in config.ini" sc_p_revert
  sc_run "conflicts: merge conflict/a into main gives 4 unmerged paths" sc_p_merge
  sc_run "stop-merge: merge stopped, 4 unmerged paths" sc_p_stop_merge
  sc_run "stop-rebase: rebase stopped at k1 (1 of 3), 3 unmerged paths" sc_p_stop_rebase
  sc_run "stop-edit: rebase paused at edit s3, no conflict" sc_p_stop_edit
  sc_run "remote: every teammate action runs, both origins on the same SHAs" sc_p_actions remote
  sc_run "marathon: pull --rebase conflicts at L1 vs T2, keep L1, both stashes pop (histq side)" \
    sc_p_marathon_pull histq theirs
  sc_run "marathon: pull --rebase conflicts at L1 vs T2, keep T2, both stashes pop (ref side)" \
    sc_p_marathon_pull ref ours
  sc_run "marathon: every teammate action runs, both origins on the same SHAs" sc_p_actions marathon
  sc_run "core: squash s1..s3 gives s3's tree" sc_p_squash
  sc_run "rebase-lab: with-merge from w1 has a merge commit in its range" sc_p_with_merge
  sc_run "detached: x1 is on no branch" sc_p_detached
  sc_run "worktree: 3 worktrees" sc_p_worktree
  sc_run "submodule: status has no prefix char" sc_p_submodule

  echo "selfcheck: $SC_OK ok, $SC_FAIL FAIL ($(( $(date +%s) - start )) s)"
  [ "$SC_FAIL" -eq 0 ]
}

# ---- doccheck ----
# DC_PROBLEMS counts problems; each check prints its own lines.
DC_PROBLEMS=0
dc_problem() { echo "doccheck: $*"; DC_PROBLEMS=$((DC_PROBLEMS + 1)); }

# dc_fixtures <md files...>: every fixture `<name>` names a known fixture.
dc_fixtures() {
  local f name
  for f in "$@"; do
    for name in $(grep -oE 'fixture `[a-z-]+`' "$f" | sed -E 's/^fixture `([a-z-]+)`$/\1/' | sort -u); do
      is_fixture "$name" || dc_problem "unknown fixture \`$name\` in $f"
    done
  done
}

# dc_ids <md files...>: no scenario heading id twice (in one file or across files).
dc_ids() {
  local line f
  while IFS= read -r line; do
    if [ -n "$line" ]; then dc_problem "duplicate id $line"; fi
  done <<DC_IDS
$(for f in "$@"; do
    grep -oE '^### (S[0-9]{2}-[0-9]{2}|M[0-9]{2})' "$f" | sed "s|^### ||; s|\$|	$f|" || true
  done | awk -F'\t' '{ n[$1]++; files[$1] = files[$1] " " $2 } END { for (id in n) if (n[id] > 1) print id " in" files[id] }' | sort)
DC_IDS
}

# dc_frag_found <fragment>: the fragment is in App/ as written, or with its ellipsis spelled \u{2026} or ...,
# or without its ellipsis (labels built as title + "…"); a fragment under 4 characters once stripped passes.
dc_frag_found() {
  local frag="$1" alt
  grep -rqF -- "$frag" "$REPO_ROOT/App/" && return 0
  case "$frag" in *…*) ;; *) return 1 ;; esac
  for alt in "$(printf '%s' "$frag" | perl -CSD -pe 's/\x{2026}/\\u{2026}/g')" \
             "$(printf '%s' "$frag" | perl -CSD -pe 's/\x{2026}/.../g')"; do
    grep -rqF -- "$alt" "$REPO_ROOT/App/" && return 0
  done
  alt="$(printf '%s' "$frag" | perl -CSD -pe 's/\x{2026}//g; s/^\s+|\s+$//g')"
  [ "$(printf '%s' "$alt" | perl -CSD -ne 'print length')" -ge 4 ] || return 0
  grep -rqF -- "$alt" "$REPO_ROOT/App/"
}

# dc_labels <md files...>: every fragment of every ⟦label⟧ (split on " > " and <placeholders>, >= 4 characters)
# is found in App/.
dc_labels() {
  local frag file last="" found=1
  while IFS="$(printf '\t')" read -r frag file; do
    [ -n "$frag" ] || continue
    if [ "$frag" != "$last" ]; then
      last="$frag"
      if dc_frag_found "$frag"; then found=1; else found=0; fi
    fi
    [ "$found" = 1 ] || dc_problem "label fragment not found in App/: \`$frag\` ($file)"
  done <<DC_LABELS
$(perl -CSDA -ne '
    while (/\x{27E6}(.*?)\x{27E7}/g) {
      for my $part (split / > /, $1) {
        for my $frag (split /<[^<>]*>/, $part) {
          $frag =~ s/^\s+|\s+$//g;
          print "$frag\t$ARGV\n" if length($frag) >= 4;
        }
      }
    }' "$@" | sort -u)
DC_LABELS
}

# dc_competitors <paths...>: no competitor name; the pattern is built at run time from the project CLAUDE.md
# (never write the names into a file).
dc_competitors() {
  local claude="$REPO_ROOT/CLAUDE.md" L P n hits line
  if [ ! -f "$claude" ]; then
    warn "doccheck: $claude missing, competitor-name check skipped"
    return 0
  fi
  L=$(grep -m1 'competing git client' "$claude" || true)
  P="$( { echo "$L" | sed -E 's/.*Never write ([A-Za-z]+) or any other competing git client \(([^)]*)\).*/\1, \2/' | tr -d '…' | tr ',' '\n'; echo "$L" | sed -E 's/.*Never write ([A-Za-z]+) .*/\1/' | sed 's/r//'; } | sed 's/^ *//;s/ *$//' | { grep -v '^$' || true; } | sort -u | paste -sd'|' -)"
  n=0
  [ -z "$P" ] || n="$(echo "$P" | tr '|' '\n' | wc -l | tr -d ' ')"
  if [ "$n" -lt 8 ]; then
    dc_problem "competitor-name pattern from $claude has $n names (need >= 8)"
    return 0
  fi
  [ $# -gt 0 ] || return 0
  hits="$(grep -rniwE -- "$P" "$@" || true)"
  [ -n "$hits" ] || return 0
  while IFS= read -r line; do dc_problem "competitor name: $line"; done <<DC_HITS
$hits
DC_HITS
}

cmd_doccheck() {
  local dir="$REPO_ROOT/docs/qa/graph-interactive" f mds="" n_md=0 paths="" ifs_save="$IFS"
  while [ $# -gt 0 ]; do
    case "$1" in
      --docs) [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ -d "$dir" ]; then
    for f in "$dir"/*.md; do
      [ -f "$f" ] || continue
      mds="$mds$f
"
      n_md=$((n_md + 1))
    done
  fi
  if [ "$n_md" -eq 0 ]; then
    echo "doccheck: no docs in $dir (fixture, id and label checks pass)"
  else
    IFS='
'
    # shellcheck disable=SC2086
    set -- $mds
    IFS="$ifs_save"
    dc_fixtures "$@"
    dc_ids "$@"
    dc_labels "$@"
  fi
  if [ -d "$dir" ]; then paths="$dir
"; fi
  for f in "$SCRIPT_DIR"/qa-graph*.sh; do
    if [ -f "$f" ]; then paths="$paths$f
"; fi
  done
  IFS='
'
  # shellcheck disable=SC2086
  set -- $paths
  IFS="$ifs_save"
  dc_competitors "$@"
  if [ "$DC_PROBLEMS" -eq 0 ]; then
    echo "doccheck: OK"
  else
    echo "doccheck: $DC_PROBLEMS problem(s)"
    return 1
  fi
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  list) cmd_list "$@" ;;
  reset) cmd_reset "$@" ;;
  paths) cmd_paths "$@" ;;
  state) cmd_state "$@" ;;
  compare) cmd_compare "$@" ;;
  teammate) cmd_teammate "$@" ;;
  selfcheck) cmd_selfcheck "$@" ;;
  doccheck) cmd_doccheck "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

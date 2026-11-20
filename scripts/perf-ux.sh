#!/usr/bin/env bash
# UX latency harness: launches a Histq measurement build in the background on fixture copies under
# build/qa/perf/ux/ and keeps a stamp of the source state the measurement app was built from.
#
# Usage:
#   scripts/perf-ux.sh stamp                 writes the source-state checksum to build/qa/perf/ux/app-perf/STAMP
#   scripts/perf-ux.sh check-stamp           exit 0 when that STAMP matches the current source state, else 1
#   scripts/perf-ux.sh <Histq.app> launch <seconds> <repo…> [-- <app args…>]
#                                            one background launch on <repo…>, quit after <seconds> (or earlier
#                                            once every walk/run driver in the app args logged its end); prints
#                                            the state dir (timing.log, operations.txt, uptime.txt, qa-defaults.txt)
#   scripts/perf-ux.sh <Histq.app> <scenario|all> [runs=3] [label=<date>] [-- <extra app args…>]
#                                            each run on a fresh copy under build/qa/perf/ux/run/: scenario state set
#                                            with plain git, one launch, its logs to build/qa/perf/ux/results/<label>/
#                                            <scenario>-<run>.*, the copy removed, one stats row printed
#                                            (scripts/perf-ux-stats.py). An app under build/qa/perf/ux/app-perf/ must
#                                            match the STAMP; another app (a Debug build for a smoke run) is not checked.
#
# Scenarios (CONTRIBUTING.md, "UX latency benchmark"): reads sel-adjacent sel-repeat sel-far sel-wip file-commit
# file-wip tabs; writes checkout-clean checkout-dirty checkout-big checkout-fail commit commit-fail outside-edit stash
# stash-many stash-pop rebase rebase-interactive rebase-abort fetch pull push; pull requests pr-open pr-open-slow
# pr-action pr-mergeable; checks (not in all) tabs-ignored tabs-tracked. Fixtures: build/qa/perf/ux/fx
# (make-fixtures.sh) and build/qa/perf/ux/base (big-cg, self).
#
# The source state is HEAD's trees of App, Packages and project.yml, the uncommitted diff of those paths and the
# untracked files under App and Packages (scripts and docs do not count: editing the harness never forces a rebuild).
#
# Launches are background only: open -g -n with -HistqBackground YES and a state dir, the front app is checked
# before and after. Use the perf build (Release with HISTQ_SEAMS='HISTQ_PERF DEBUG') or a Debug build; a plain
# Release build ignores -HistqBackground and would come to front, so a build without the DEBUG launch seams is
# refused. Only the instance launched here is killed (matched by its state dir), never other Histq instances.
set -euo pipefail

die() { echo "perf-ux.sh: $*" >&2; exit 1; }
note() { echo "perf-ux.sh: $*" >&2; }
usage() {
  echo "usage: perf-ux.sh stamp | check-stamp | <Histq.app> launch <seconds> <repo…> [-- <app args…>]" >&2
  echo "       perf-ux.sh <Histq.app> <scenario|all> [runs] [label] [-- <extra app args…>]" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
UX="$ROOT/build/qa/perf/ux"
STAMP_FILE="$UX/app-perf/STAMP"

# ---- Stamp ----

# The checksum of the source state the app is built from (see the header).
stamp_now() {
  (
    cd "$ROOT"
    git rev-parse HEAD:App HEAD:Packages HEAD:project.yml
    git diff --no-ext-diff --no-textconv --no-color HEAD -- App Packages project.yml
    git ls-files -z --others --exclude-standard -- App Packages | while IFS= read -r -d '' f; do
      printf 'untracked %s\n' "$f"
      cat -- "$f"
    done
  ) | shasum -a 256 | cut -d' ' -f1
}

stamp() {
  local sum
  sum="$(stamp_now)"
  mkdir -p "$(dirname "$STAMP_FILE")"
  printf '%s\n' "$sum" > "$STAMP_FILE"
  echo "stamp: $sum"
}

# stamp_matches: 0 when the STAMP matches the current source state, else 1 (with a note).
stamp_matches() {
  local want have
  [ -f "$STAMP_FILE" ] || { note "no stamp at $STAMP_FILE"; return 1; }
  want="$(cat "$STAMP_FILE")"
  have="$(stamp_now)" || return 1
  if [ -n "$want" ] && [ "$want" = "$have" ]; then return 0; fi
  note "stamp mismatch: the source state changed since the app-perf build"
  return 1
}

check_stamp() {
  if stamp_matches; then exit 0; fi
  exit 1
}

# ---- Launch ----

# The app under test, set by check_app.
APP=""

# check_app <Histq.app>: resolves the app and refuses a build without the DEBUG launch seams (a plain Release build
# ignores -HistqBackground and -HistqStateDir). -HistqSelectWalk exists only inside #if DEBUG; a Debug build keeps its
# code in Histq.debug.dylib, hence the whole MacOS folder.
check_app() {
  APP="$(cd "$1" 2>/dev/null && pwd -P)" || die "no app at $1"
  [ -x "$APP/Contents/MacOS/Histq" ] || die "not a built Histq app: $APP"
  grep -aqF -- "-HistqSelectWalk" "$APP"/Contents/MacOS/* \
    || die "refusing $APP: no DEBUG launch seams (a plain Release build would come to front); use the perf or a Debug build"
}

# check_repo <repo>: prints the resolved path of a repo the harness may hand to the app: the top of its own repo
# under build/qa/perf/ux/ (a folder that is not a repo would resolve to the Histq checkout itself).
check_repo() {
  local repo top
  repo="$(cd "$1" 2>/dev/null && pwd -P)" || die "no repo at $1"
  case "$repo/" in "$UX"/?*/) ;; *) die "refusing $repo: launch repos must be under $UX/" ;; esac
  case "$repo/" in "$UX"/state/*) die "refusing $repo: it is under the state folder" ;; esac
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "$repo is not a git repo"
  [ "$(cd "$top" && pwd -P)" = "$repo" ] || die "refusing $repo: not the top of its own repo (its repo is $top)"
  printf '%s\n' "$repo"
}

# Pids of a Histq binary launched with state dir $1, matched on the full command line.
our_pids() {
  ps -axwwo pid=,command= | awk -v d=" -HistqStateDir $1 " \
    'index($0 " ", d) && index($0, "Histq.app/Contents/MacOS/Histq ") { print $1 }'
}
is_ours() { case "$(ps -wwo command= -p "$1" 2>/dev/null)" in *" -HistqStateDir $2 "*) return 0 ;; esac; return 1; }

# The running launch, for quit_launch and the EXIT trap.
UX_PID=""
UX_STATE=""
UX_FRONT=""

# quit_launch: reads the front app, kills only the launched instance (TERM, then KILL) and reports the front app.
quit_launch() {
  local front front_pid i pid="$UX_PID" state="$UX_STATE"
  [ -n "$state" ] || return 0
  front="$(lsappinfo front)" || true
  front_pid="$(lsappinfo info "$front" | sed -n 's/.*pid = \([0-9]*\).*/\1/p' | sed -n 1p)" || true
  # A die between open and the pid lookup leaves UX_PID empty: find the instance by its state dir.
  [ -n "$pid" ] || pid="$(our_pids "$state" | sed -n 1p)" || true
  if [ -n "$pid" ] && is_ours "$pid" "$state"; then
    kill "$pid" 2>/dev/null || true
    for i in $(seq 25); do is_ours "$pid" "$state" || break; sleep 0.2; done
    if is_ours "$pid" "$state"; then kill -9 "$pid" 2>/dev/null || true; fi
    for i in $(seq 25); do is_ours "$pid" "$state" || break; sleep 0.2; done
  fi
  if [ "$front" = "$UX_FRONT" ]; then
    echo "front app: unchanged ($UX_FRONT)" | tee "$state/front.txt"
  elif [ -n "$pid" ] && [ "$front_pid" = "$pid" ]; then
    echo "WARNING: the launched Histq (pid $pid) is the front app (was $UX_FRONT)" | tee "$state/front.txt" >&2
  else
    echo "WARNING: front app changed: $UX_FRONT -> $front (pid ${front_pid:-?}, not the launched Histq)" \
      | tee "$state/front.txt" >&2
  fi
  UX_PID=""
  UX_STATE=""
}
trap 'quit_launch' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# driver_done <state> <app args…>: true once every driver in the app args logged its end (` walk done` in
# timing.log for a *Walk flag, `done` in operations.txt for -HistqRun); false when there is no driver to wait for.
driver_done() {
  local state="$1" walk=0 run=0 a
  shift
  for a in "$@"; do
    case "$a" in
      -Histq*Walk) walk=1 ;;
      -HistqRun) run=1 ;;
    esac
  done
  [ $((walk + run)) -gt 0 ] || return 1
  if [ $walk = 1 ]; then grep -q " walk done" "$state/timing.log" 2>/dev/null || return 1; fi
  if [ $run = 1 ]; then grep -qx "done" "$state/operations.txt" 2>/dev/null || return 1; fi
  return 0
}

# launch_app <state dir> <seconds> <repo…> -- <app args…>: one background launch of $APP (check_app first) with its
# own state dir under build/qa/perf/ux/state/, quit once $UX_WAIT returns (launch mode: after <seconds> or 1.5 s after
# driver_done). The front app check goes to stdout (a warning to stderr) and to <state>/front.txt.
launch_app() {
  local state="$1" wait="$2" repos=() args=() r deadline
  shift 2
  [[ "$wait" =~ ^[1-9][0-9]*$ ]] || die "seconds must be a positive number, got '$wait'"
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do repos+=("$(check_repo "$1")"); shift; done
  [ $# -gt 0 ] && shift
  args=("$@")
  [ ${#repos[@]} -gt 0 ] || die "no repo to open"
  case "$state/" in "$UX"/state/?*/) ;; *) die "refusing state dir $state: it must be under $UX/state/" ;; esac
  [ -z "$(our_pids "$state")" ] || die "a Histq instance already uses $state"

  rm -rf "$state"
  mkdir -p "$state"
  # Seed the login-shell PATH cache, as the shipped app has it, so a write does not wait for `$SHELL -ilc`.
  # Captured once from the app's own cache; cp keeps the bytes (a trailing newline makes the app reject it).
  [ -s "$UX/login-path" ] || cp "$HOME/Library/Application Support/Histq/login-path" "$UX/login-path" 2>/dev/null || true
  [ -s "$UX/login-path" ] && cp "$UX/login-path" "$state/login-path"
  UX_FRONT="$(lsappinfo front)"
  UX_STATE="$state"
  # The repos go before --args: after it, a path is an app argument and is ignored.
  open -g -n -a "$APP" "${repos[@]}" --args -HistqStateDir "$state" -HistqBackground YES \
    -ApplePersistenceIgnoreState YES -NSAppSleepDisabled YES -HistqLayout classic ${args[@]+"${args[@]}"} \
    || die "open failed for $APP"
  deadline=$((SECONDS + 30))
  until [ -n "$(our_pids "$state")" ]; do
    [ $SECONDS -lt $deadline ] || die "no Histq instance with $state started within 30 s"
    sleep 0.2
  done
  UX_PID="$(our_pids "$state")"
  [ "$(printf '%s\n' "$UX_PID" | wc -l | tr -d ' ')" -eq 1 ] || die "several Histq instances use $state: $(echo $UX_PID)"
  note "launched pid $UX_PID on ${repos[*]}"

  deadline=$((SECONDS + 15))
  until [ -f "$state/timing.log" ]; do
    is_ours "$UX_PID" "$state" || die "Histq (pid $UX_PID) exited"
    [ $SECONDS -lt $deadline ] || die "no timing.log in $state after 15 s (the build ignores -HistqStateDir?)"
    sleep 0.2
  done
  uptime > "$state/uptime.txt"
  { defaults read com.math2it.histq.qa 2>&1 || true; } > "$state/qa-defaults.txt"

  "$UX_WAIT" "$state" "$wait" ${args[@]+"${args[@]}"}
  uptime >> "$state/uptime.txt"
  quit_launch
}

# The wait between the launch and the quit: wait_driver (launch mode) or wait_scenario (scenario mode).
UX_WAIT=wait_driver

# wait_driver <state> <seconds> <app args…>: <seconds>, or 1.5 s after driver_done.
wait_driver() {
  local state="$1" deadline=$((SECONDS + $2))
  shift 2
  while [ $SECONDS -lt $deadline ]; do
    is_ours "$UX_PID" "$state" || die "Histq (pid $UX_PID) exited"
    if driver_done "$state" "$@"; then sleep 1.5; break; fi
    sleep 0.5
  done
}

# ---- Scenarios ----

FX="$UX/fx"
BASE="$UX/base"
RUN="$UX/run"
RESULTS="$UX/results"
READ_SCENARIOS="sel-adjacent sel-repeat sel-far sel-wip file-commit file-wip tabs"
WRITE_SCENARIOS="checkout-clean checkout-dirty checkout-big checkout-fail commit commit-fail outside-edit stash"
WRITE_SCENARIOS+=" stash-many stash-pop rebase rebase-interactive rebase-abort fetch pull push"
PR_SCENARIOS="pr-open pr-open-slow pr-action pr-mergeable"
SCENARIOS="$(echo $READ_SCENARIOS $WRITE_SCENARIOS $PR_SCENARIOS)"
# Checks, not in `all`: `tabs` with tab 2 (big-cg) on its WIP, where an ignored file (tabs-ignored) or a tracked file
# (tabs-tracked) changes while it is hidden.
CHECK_SCENARIOS="tabs-ignored tabs-tracked"
# The stub's answer delay of the pull request scenarios (pr-open-slow sets its own per part).
PR_DELAY=300

# One run's scenario, set by prepare_scenario: the run copy, the repos to open (in tab order), the scenario's app args,
# its end line (walk | run | rebase | settled | edited | pr-action | mergeable), when the harness edits a tracked file
# from outside (tail: on `walk tail`; settled: 1 s after `op-settled`) and which file of which repo, the run's state dir.
S_DIR=""
S_REPOS=()
S_ARGS=()
S_END=""
S_EDIT=""
S_EDIT_REPO=""
S_EDIT_FILE=""
S_EDITED=0
S_STATE=""
S_RESULT=""
SCENARIO=""
EXTRA=()

# Plain git in a run copy, with git's automatic maintenance and gc off (no background writes during a run).
cgit() { local repo="$1"; shift; git -C "$repo" -c maintenance.auto=false -c gc.auto=0 "$@"; }
clean_tree() { cgit "$1" reset -q --hard; cgit "$1" clean -qfd; }
append_line() { printf 'perf-ux outside edit\n' >> "$1/$2"; }
# README.md when the repo tracks it, else its first tracked file.
edit_target() {
  if [ -n "$(cgit "$1" ls-files -- README.md)" ]; then echo README.md; else cgit "$1" ls-files | awk 'NR == 1'; fi
}

# The copies: graph with its bare origin and its linked worktree as siblings (relative remote and worktree paths; push
# and fetch write the origin copy), the self clone without its remote (an auto-fetch would bring main's refs into its
# graph), big-cg (50000 commits with a commit-graph).
copy_graph() { cp -cR "$FX/graph" "$FX/graph-origin.git" "$FX/graph-wt" "$S_DIR/"; }
copy_self() { cp -cR "$BASE/self" "$S_DIR/"; cgit "$S_DIR/self" remote remove origin; }
copy_big() { cp -cR "$BASE/big-cg" "$S_DIR/"; }
copy_pr() { cp -cR "$FX/conflict-pr" "$FX/conflict-pr-origin.git" "$S_DIR/"; }

# prepare_scenario <scenario>: makes the run copy in $S_DIR and sets the S_ variables.
prepare_scenario() {
  local s="$1" g="$S_DIR/graph" i tree commit
  S_REPOS=("$g")
  S_ARGS=()
  S_END=run
  S_EDIT=""
  S_EDIT_REPO=""
  S_EDIT_FILE=""
  S_EDITED=0
  case "$s" in
    sel-*|checkout-big) copy_big; S_REPOS=("$S_DIR/big-cg") ;;
    file-*) copy_self; S_REPOS=("$S_DIR/self") ;;
    # Tab 1 (graph, WIP selected) is the revisit without a change, tab 2 (big-cg, clean) gets the outside edit.
    tabs|tabs-*) copy_graph; copy_self; copy_big; S_REPOS=("$S_DIR/self" "$g" "$S_DIR/big-cg") ;;
    pr-*) copy_pr; S_REPOS=("$S_DIR/conflict-pr") ;;
    rebase-abort) cp -cR "$FX/conflict-rebase" "$S_DIR/"; S_REPOS=("$S_DIR/conflict-rebase") ;;
    *) copy_graph ;;
  esac
  case "$s" in
    sel-adjacent) S_END=walk; S_ARGS=(-HistqSelectWalk 60,300) ;;
    sel-repeat) S_END=walk; S_ARGS=(-HistqSelectWalk 120,30) ;;
    sel-far) S_END=walk; S_ARGS=(-HistqSelectWalk 40,400,97) ;;
    sel-wip)
      # One edited tracked file gives the WIP row; the walk selects it after each commit.
      append_line "$S_DIR/big-cg" "$(edit_target "$S_DIR/big-cg")"
      S_END=walk; S_ARGS=(-HistqSelectWalk 10,300,1,wip) ;;
    file-commit) S_END=walk; S_ARGS=(-HistqSelect commit:d8b266d -HistqFileWalk 6,500) ;;
    file-wip)
      # 3 edited files of 59, 883 and 5520 lines; on `walk tail` the open one (the walk's last) gets another line.
      for i in README.md App/Detail/WIPPanel.swift App/Repo/RepoSession.swift; do append_line "$S_DIR/self" "$i"; done
      S_END=walk; S_EDIT=tail; S_EDIT_REPO="$S_DIR/self"; S_ARGS=(-HistqSelect wip -HistqFileWalk 3,500) ;;
    tabs) S_END=walk; S_EDIT=tail; S_ARGS=(-HistqTabWalk 2,1500) ;;
    tabs-ignored|tabs-tracked)
      # A tracked edit puts big-cg on its WIP; tabs-ignored writes perf-ignored/out.txt, which info/exclude ignores.
      append_line "$S_DIR/big-cg" "$(edit_target "$S_DIR/big-cg")"
      echo "perf-ignored/" >> "$S_DIR/big-cg/.git/info/exclude"
      mkdir -p "$S_DIR/big-cg/perf-ignored"; : > "$S_DIR/big-cg/perf-ignored/out.txt"
      S_END=walk; S_EDIT=tail; S_ARGS=(-HistqTabWalk 2,1500) ;;
    checkout-clean) clean_tree "$g"; S_ARGS=(-HistqRun "branches|develop") ;;
    # The fixture's own changes (staged, unstaged, untracked) go along through the autostash.
    checkout-dirty) S_ARGS=(-autoStash always -HistqRun "branches|develop") ;;
    checkout-big) S_ARGS=(-HistqRun "branches|topic") ;;
    checkout-fail)
      # develop changes CHANGELOG.md, so git refuses to carry this edit there; autostash off in the argument domain
      # (the shared com.math2it.histq.qa suite is not changed).
      clean_tree "$g"; append_line "$g" CHANGELOG.md
      S_ARGS=(-autoStash never -HistqRun "branches|develop") ;;
    commit|commit-fail|outside-edit)
      # The box commits only staged changes.
      clean_tree "$g"; append_line "$g" README.md; cgit "$g" add README.md
      S_END=settled; S_ARGS=(-HistqSelect wip -HistqCommitBox perf)
      if [ "$s" = commit-fail ]; then
        printf '#!/bin/sh\necho "perf-ux: pre-commit refuses" >&2\nexit 1\n' > "$g/.git/hooks/pre-commit"
        chmod +x "$g/.git/hooks/pre-commit"
      fi
      if [ "$s" = outside-edit ]; then S_END=edited; S_EDIT=settled; S_EDIT_REPO="$g"; S_EDIT_FILE=CHANGELOG.md; fi ;;
    stash) S_ARGS=(-HistqRun "wip|Stash All Changes") ;;
    stash-many)
      clean_tree "$g"; mkdir "$g/many"
      for i in $(seq -w 1 300); do printf 'line\n' > "$g/many/f$i.txt"; done
      cgit "$g" add many; cgit "$g" commit -q -m "Add 300 files"
      for i in $(seq -w 1 300); do append_line "$g" "many/f$i.txt"; done
      S_ARGS=(-HistqRun "wip|Stash All Changes") ;;
    stash-pop) clean_tree "$g"; S_ARGS=(-HistqRun "stash:$(cgit "$g" rev-parse 'stash@{0}')|Pop Stash") ;;
    rebase) clean_tree "$g"; S_ARGS=(-HistqRun "local:series|Rebase main onto series") ;;
    rebase-interactive)
      clean_tree "$g"; cgit "$g" checkout -q series
      S_END=rebase; S_ARGS=(-HistqOpenRebase series~4 -HistqStartRebase) ;;
    # conflict-rebase stops in a rebase; the operation banner's Abort.
    rebase-abort) S_END=settled; S_ARGS=(-HistqOperation abort) ;;
    fetch)
      # A new commit on a new branch of the origin copy.
      tree="$(cgit "$S_DIR/graph-origin.git" rev-parse 'develop^{tree}')"
      commit="$(cgit "$S_DIR/graph-origin.git" -c user.name=perf -c user.email=perf@histq.invalid \
        commit-tree "$tree" -p develop -m "Fetched commit")"
      cgit "$S_DIR/graph-origin.git" update-ref refs/heads/perf-fetch "$commit"
      S_ARGS=(-HistqRun "pull|Fetch All") ;;
    pull) clean_tree "$g"; cgit "$g" checkout -q feature; S_ARGS=(-HistqRun "pull|Pull (fast-forward if possible)") ;;
    push) clean_tree "$g"; cgit "$g" checkout -q develop; S_ARGS=(-HistqRun "push|Push") ;;
    pr-open) S_END=walk; S_ARGS=(-HistqGitHubStub YES -HistqGitHubStubDelay "$PR_DELAY" -HistqPRWalk 1,2,2500) ;;
    pr-open-slow)
      S_END=walk; S_ARGS=(-HistqGitHubStub YES -HistqGitHubStubDelay "300,files=900,check-runs=600" -HistqPRWalk 1,2,2500) ;;
    pr-action)
      S_END=pr-action; S_ARGS=(-HistqGitHubStub YES -HistqGitHubStubDelay "$PR_DELAY" -HistqSelect pr:1 -HistqPRAction merge) ;;
    pr-mergeable)
      S_END=mergeable
      S_ARGS=(-HistqGitHubStub YES -HistqGitHubStubDelay "$PR_DELAY" -HistqSelect pr:1 -HistqPRMergeable null) ;;
    *) die "unknown scenario $s" ;;
  esac
}

# The last time stamp of the timing and refresh logs: the outside edit happens after it.
last_stamp() {
  { cat "$1/timing.log" "$1/refresh.log" 2>/dev/null || true; } \
    | awk '$1 ~ /^[0-9.]+$/ && $1 + 0 > m { m = $1 + 0 } END { print m + 0 }'
}

# edit_tick <state>: the outside edit once its moment came (tail: `walk tail`; settled: 1 s after `op-settled`). The
# file: tabs, README.md (or the first tracked file) of tab 2's repo; file-wip, the file open at `walk tail` (the walk's
# last `select file`). Writes `edit <ms> <repo folder> <path>` to <state>/meta for the stats' proof column.
edit_tick() {
  local state="$1" tl="$1/timing.log" name anchor
  [ -n "$S_EDIT" ] && [ "$S_EDITED" = 0 ] || return 0
  case "$S_EDIT" in
    tail)
      grep -q " walk tail$" "$tl" || return 0
      if [[ "$SCENARIO" == tabs* ]]; then
        name="$(awk '$2 == "tab-shown" && $3 == "2" { n = $4 } END { print n }' "$tl")"
        [ -n "$name" ] && [ -d "$S_DIR/$name" ] || die "tabs: no tab-shown line for tab 2 before walk tail"
        S_EDIT_REPO="$S_DIR/$name"
        if [ "$SCENARIO" = tabs-ignored ]; then S_EDIT_FILE=perf-ignored/out.txt
        else S_EDIT_FILE="$(edit_target "$S_EDIT_REPO")"; fi
      else
        S_EDIT_FILE="$(awk '$2 == "walk" && $3 == "tail" { exit }
          $2 == "select" && $3 == "file" { f = substr($0, index($0, " select file ") + 13) } END { print f }' "$tl")"
      fi ;;
    settled)
      grep -q " op-settled " "$tl" || return 0
      sleep 1 ;;
  esac
  [ -n "$S_EDIT_FILE" ] && [ -f "$S_EDIT_REPO/$S_EDIT_FILE" ] || die "no file to edit: $S_EDIT_REPO/$S_EDIT_FILE"
  anchor="$(last_stamp "$state")"
  append_line "$S_EDIT_REPO" "$S_EDIT_FILE"
  S_EDITED=1
  echo "edit $anchor $(basename "$S_EDIT_REPO") $S_EDIT_FILE" >> "$state/meta"
}

# end_reached <state>: the scenario's end line is in.
end_reached() {
  local tl="$1/timing.log" ops="$1/operations.txt"
  case "$S_END" in
    walk) grep -q " walk done$" "$tl" ;;
    run) grep -qx "done" "$ops" 2>/dev/null ;;
    rebase) grep -qE "^(ok|fail) (open )?rebase" "$ops" 2>/dev/null ;;
    settled) grep -q " op-settled " "$tl" ;;
    edited) [ "$S_EDITED" = 1 ] ;;
    pr-action) grep -qE " content pr [0-9]+ action [^ ]+ (ok|failed)$" "$tl" ;;
    *) return 1 ;;
  esac
}

# wait_scenario <state> <seconds> <app args…>: until the end line (at most <seconds>), making the outside edit on the
# way, then until 2 s without a new line in timing.log and refresh.log (at most 30 s). pr-mergeable ends on its fourth
# `content pr 1 mergeable` line (the first answer and 3 re-asks) or 12 s after the first, without the quiet wait.
wait_scenario() {
  local state="$1" deadline=$((SECONDS + $2)) n since="" size last="" quiet=0
  S_RESULT="timeout ($2 s)"
  while [ $SECONDS -lt $deadline ]; do
    is_ours "$UX_PID" "$state" || { S_RESULT="exited"; return 0; }
    edit_tick "$state"
    if [ "$S_END" = mergeable ]; then
      n="$(grep -c " content pr 1 mergeable " "$state/timing.log" || true)"
      if [ "$n" -ge 4 ]; then S_RESULT=ok; return 0; fi
      if [ "$n" -ge 1 ]; then
        since="${since:-$SECONDS}"
        if [ $((SECONDS - since)) -ge 12 ]; then S_RESULT="ok (12 s, $n mergeable lines)"; return 0; fi
      fi
    elif end_reached "$state"; then
      S_RESULT=ok
      break
    fi
    sleep 0.2
  done
  [ "$S_RESULT" = ok ] || return 0
  deadline=$((SECONDS + 30))
  while [ $SECONDS -lt $deadline ]; do
    size="$({ cat "$state/timing.log" "$state/refresh.log" 2>/dev/null || true; } | wc -c | tr -d ' ')"
    if [ "$size" = "$last" ]; then quiet=$((quiet + 1)); else quiet=0; last="$size"; fi
    [ $quiet -lt 10 ] || return 0
    sleep 0.2
  done
  S_RESULT="ok (never 2 s quiet within 30 s)"
}

# exercised <scenario> <state>: whether the run did what it is for: a write's op-click and its op-end with the expected
# outcome (fail for checkout-fail and commit-fail), no `missing` menu step; pr-action's `action … ok`; the end line for
# the others.
exercised() {
  local s="$1" tl="$2/timing.log" ops="$2/operations.txt" want=ok id kind result
  if grep -q "^missing " "$ops" 2>/dev/null; then echo "NOT EXERCISED ($(grep -m1 '^missing ' "$ops"))"; return; fi
  case " $WRITE_SCENARIOS " in
    *" $s "*)
      case "$s" in checkout-fail|commit-fail) want=fail ;; esac
      read -r id kind < <(awk '$2 == "op-click" { print $3, $4; exit }' "$tl") || true
      [ -n "${id:-}" ] || { echo "NOT EXERCISED (no op-click)"; return; }
      result="$(awk -v id="$id" '$2 == "op-end" && $3 == id { print $4; exit }' "$tl")"
      if [ "$result" = "$want" ]; then echo "exercised: $kind $result"
      else echo "NOT EXERCISED ($kind op-end ${result:-missing}, expected $want)"; fi ;;
    *)
      case "$S_RESULT" in ok*) ;; *) echo "NOT EXERCISED (no end line)"; return ;; esac
      if [ "$s" = pr-action ]; then
        if grep -qE " content pr [0-9]+ action [^ ]+ ok$" "$tl"; then echo "exercised: $(grep -m1 -oE 'action [^ ]+ ok$' "$tl")"
        else echo "NOT EXERCISED (the action failed)"; fi
      else
        echo "exercised: end line"
      fi ;;
  esac
}

# Waits while any xcodebuild runs: no measurement during a build (other projects build on this Mac too).
wait_for_builds() {
  local said=0
  while pgrep -xq xcodebuild; do
    [ $said = 1 ] || { note "waiting for xcodebuild to finish (no measurement while a build runs)"; said=1; }
    sleep 5
  done
}

# Removes the run copy and the run's state dir (each only under its own folder).
remove_run() {
  case "$S_DIR/" in "$RUN"/?*/) rm -rf "$S_DIR" ;; esac
  case "$S_STATE/" in "$UX"/state/?*/) rm -rf "$S_STATE" ;; esac
}

# run_one <scenario> <run> <label>: one run in a subshell of its own (a die ends only this run): copy, scenario state,
# launch, wait, logs to results/<label>/<scenario>-<run>.*, copy removed, stats row printed. Exits 3 when the row
# says NOT EXERCISED.
run_one() {
  local s="$1" k="$2" label="$3" out f check front stats
  SCENARIO="$s"
  S_DIR="$RUN/$label-$s-$k"
  S_STATE="$UX/state/$label-$s-$k"
  out="$RESULTS/$label/$s-$k"
  trap 'quit_launch >/dev/null; remove_run' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  remove_run
  mkdir -p "$S_DIR" "$RESULTS/$label"
  prepare_scenario "$s"
  wait_for_builds
  UX_WAIT=wait_scenario
  launch_app "$S_STATE" 150 "${S_REPOS[@]}" -- "${S_ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null
  {
    echo "scenario $s"
    echo "args ${S_ARGS[*]} ${EXTRA[*]:-}"
    echo "end $S_END $S_RESULT"
    echo "qa autoStash=$(qa_key autoStash) pullMode=$(qa_key pullMode) pruneOnFetch=$(qa_key pruneOnFetch)"
    echo "head $(git -C "$ROOT" rev-parse HEAD)"
  } >> "$S_STATE/meta"
  for f in timing.log refresh.log operations.txt uptime.txt qa-defaults.txt front.txt meta; do
    if [ -f "$S_STATE/$f" ]; then cp "$S_STATE/$f" "$out.$f"; fi
  done
  check="$(exercised "$s" "$S_STATE")"
  front="$(cat "$S_STATE/front.txt" 2>/dev/null || echo "front app: not checked")"
  stats="$(python3 "$ROOT/scripts/perf-ux-stats.py" --row "$s" "$out.timing.log" 2>&1 || true)"
  printf '%-18s %s | %s | %s | %s | %s\n' "$s" "$k" "$S_RESULT" "$check" "$front" "$stats"
  case "$check" in "NOT EXERCISED"*) exit 3 ;; esac
}

# A key of the shared QA suite, or "default" when unset (the app's registered default applies).
qa_key() { defaults read com.math2it.histq.qa "$1" 2>/dev/null || echo default; }

# scenarios <scenario|all> [runs] [label] [-- <extra app args…>]
scenarios() {
  local which="$1" runs=3 label s k rc failed=0 list
  shift
  if [ $# -gt 0 ] && [ "$1" != "--" ]; then runs="$1"; shift; fi
  label="$(date +%Y%m%d-%H%M%S)"
  if [ $# -gt 0 ] && [ "$1" != "--" ]; then label="$1"; shift; fi
  if [ $# -gt 0 ]; then [ "$1" = "--" ] || usage; shift; EXTRA=("$@"); fi
  [[ "$runs" =~ ^[1-9][0-9]*$ ]] || die "runs must be a positive number, got '$runs'"
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "label must be letters, digits, '.', '_' or '-', got '$label'"
  if [ "$which" = all ]; then list="$SCENARIOS"
  else
    case " $SCENARIOS $CHECK_SCENARIOS " in
      *" $which "*) list="$which" ;;
      *) die "unknown scenario '$which' (one of: $SCENARIOS $CHECK_SCENARIOS)" ;;
    esac
  fi
  case "$APP/" in
    "$UX"/app-perf/*) stamp_matches || die "refusing $APP: its STAMP does not match the source tree (run the PERF chain)" ;;
    *) note "$APP is not under build/qa/perf/ux/app-perf/: not stamp-checked" ;;
  esac
  for f in "$FX/graph" "$FX/graph-origin.git" "$FX/graph-wt" "$FX/conflict-pr" "$FX/conflict-pr-origin.git" \
    "$FX/conflict-rebase" "$BASE/big-cg" "$BASE/self"; do
    [ -d "$f" ] || die "missing fixture $f (see CONTRIBUTING.md, "UX latency benchmark")"
  done
  mkdir -p "$RESULTS/$label"
  printf '%s HEAD=%s stamp=%s app=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(git -C "$ROOT" rev-parse HEAD)" \
    "$(stamp_now)" "$APP" >> "$RESULTS/$label/HEAD"
  for s in $list; do
    for k in $(seq "$runs"); do
      set +e
      ( set -e; run_one "$s" "$k" "$label" )
      rc=$?
      set -e
      if [ $rc -eq 3 ]; then
        failed=$((failed + 1))
      elif [ $rc -ne 0 ]; then
        failed=$((failed + 1))
        printf '%-18s %s | FAILED (exit %s): see the messages above\n' "$s" "$k" "$rc"
        S_DIR="$RUN/$label-$s-$k"
        S_STATE="$UX/state/$label-$s-$k"
        remove_run
        [ $rc -ne 130 ] && [ $rc -ne 143 ] || exit $rc
      fi
    done
  done
  echo "results: $RESULTS/$label (scripts/perf-ux-stats.py $RESULTS/$label for the tables)"
  [ $failed -eq 0 ] || die "$failed run(s) failed or did not exercise their scenario"
}

# ---- Main ----

[ $# -ge 1 ] || usage
case "$1" in
  stamp) [ $# -eq 1 ] || usage; stamp ;;
  check-stamp) [ $# -eq 1 ] || usage; check_stamp ;;
  *)
    [ $# -ge 2 ] || usage
    check_app "$1"
    mode="$2"
    shift 2
    case "$mode" in
      launch)
        [ $# -ge 2 ] || usage
        state="$UX/state/launch-$(date +%Y%m%d-%H%M%S)-$$"
        launch_app "$state" "$@"
        echo "state: $state"
        ;;
      *) scenarios "$mode" "$@" ;;
    esac
    ;;
esac

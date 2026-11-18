#!/usr/bin/env bash
# Reload benchmark: launches a Histq build (Debug, or the HISTQ_PERF Release build; never the plain Release build,
# which ignores -HistqBackground and would come to front) in the background on a disposable fixture clone, waits for
# its first full load, then per cycle edits a tracked file (the WIP reload) and commits it (the commit reload), and
# prints each reload's timing events from the state dir's timing.log and refresh.log (ms since launch in both).
#
# Usage: scripts/perf-reload.sh <Histq.app> <repo> <cycles> [extra app args…]
#
# <repo> must be a clean repo of its own under build/qa/perf/: it is reset to its starting tip at the end
# (`git reset --hard`), so its test commits are discarded. Commits are dated after the tip, a minute apart, with git
# maintenance and auto gc off. Only the instance this script starts is killed (matched by pid and state dir).
set -euo pipefail

die() { echo "perf-reload.sh: $*" >&2; exit 1; }
usage() { echo "usage: perf-reload.sh <Histq.app> <repo> <cycles> [extra app args…]" >&2; exit 2; }
note() { echo "perf-reload.sh: $*" >&2; }

[ $# -ge 3 ] || usage
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$(cd "$1" 2>/dev/null && pwd -P)" || die "no app at $1"
REPO="$(cd "$2" 2>/dev/null && pwd -P)" || die "no repo at $2"
CYCLES="$3"
shift 3
[[ "$CYCLES" =~ ^[1-9][0-9]*$ ]] || die "cycles must be a positive number, got '$CYCLES'"
[ -x "$APP/Contents/MacOS/Histq" ] || die "not a built Histq app: $APP"

PERF_DIR="$ROOT/build/qa/perf"
STATE_DIR="$PERF_DIR/state"
TL="$STATE_DIR/timing.log"
RL="$STATE_DIR/refresh.log"

# The repo is reset --hard at the end: only a repo of its own under build/qa/perf/, never a folder inside another
# repo (git would walk up to the Histq checkout), and only a clean one.
case "$REPO/" in "$PERF_DIR"/?*/) ;; *) die "refusing $REPO: the repo is reset at the end, so it must be under $PERF_DIR/" ;; esac
[ "$REPO" != "$STATE_DIR" ] || die "the repo cannot be the state dir"
top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || die "$REPO is not a git repo"
[ "$(cd "$top" && pwd -P)" = "$REPO" ] || die "refusing $REPO: not the top of its own repo (its repo is $top)"
g() { git -C "$REPO" -c maintenance.auto=false -c gc.auto=0 "$@"; }
[ -z "$(g status --short)" ] || die "$REPO has uncommitted changes; the reset at the end would discard them"
FILE="$(g ls-files | sed -n 1p)"
[ -n "$FILE" ] || die "$REPO has no tracked file to edit"
TIP_DATE="$(g log -1 --format=%ct)"

FRONT="$(lsappinfo front)"
# Only processes of a Histq binary launched with this state dir count; matched on the full command line.
our_pids() {
  ps -axwwo pid=,command= | awk -v d=" -HistqStateDir $STATE_DIR " \
    'index($0 " ", d) && index($0, "/Contents/MacOS/Histq ") { print $1 }'
}
is_ours() { case "$(ps -wwo command= -p "$1" 2>/dev/null)" in *" -HistqStateDir $STATE_DIR "*) return 0 ;; esac; return 1; }
[ -z "$(our_pids)" ] || die "a Histq instance already uses $STATE_DIR (pid $(our_pids | tr '\n' ' '))"

pid=""
START_TIP=""
cleanup() {
  set +e
  # The front app is read before the kill: the launched instance must not be it.
  local front front_pid i
  front="$(lsappinfo front)"
  front_pid="$(lsappinfo info "$front" | sed -n 's/.*pid = \([0-9]*\).*/\1/p' | sed -n 1p)"
  if [ -n "$pid" ] && is_ours "$pid"; then
    kill "$pid" 2>/dev/null
    for i in $(seq 25); do is_ours "$pid" || break; sleep 0.2; done
    is_ours "$pid" && kill -9 "$pid" 2>/dev/null
    for i in $(seq 25); do is_ours "$pid" || break; sleep 0.2; done
  fi
  if [ -n "$START_TIP" ]; then
    g reset -q --hard "$START_TIP"
    if [ "$(g rev-parse HEAD)" = "$START_TIP" ] && [ -z "$(g status --short)" ]; then
      echo "fixture: reset to $START_TIP, clean"
    else
      echo "WARNING: fixture $REPO is not back at $START_TIP or not clean" >&2
    fi
  fi
  if [ "$front" = "$FRONT" ]; then
    echo "front app: unchanged ($FRONT)"
  elif [ -n "$pid" ] && [ "$front_pid" = "$pid" ]; then
    echo "WARNING: the launched Histq (pid $pid) is the front app (was $FRONT)" >&2
  else
    echo "WARNING: front app changed: $FRONT -> $front (pid ${front_pid:-?}, not the launched Histq)" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
START_TIP="$(g rev-parse HEAD)"

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"

# The repo goes before --args: after it, the path is an app argument and is ignored.
open -g -n -a "$APP" "$REPO" --args -HistqStateDir "$STATE_DIR" -HistqBackground YES -ApplePersistenceIgnoreState YES "$@" \
  || die "open failed for $APP"
deadline=$((SECONDS + 30))
until [ -n "$(our_pids)" ]; do
  [ $SECONDS -lt $deadline ] || die "no Histq instance with $STATE_DIR started within 30 s"
  sleep 0.2
done
pid="$(our_pids)"
[ "$(printf '%s\n' "$pid" | wc -l | tr -d ' ')" -eq 1 ] || die "several Histq instances use $STATE_DIR: $(echo $pid)"
note "launched pid $pid on $REPO"

alive() { is_ours "$pid" || die "Histq (pid $pid) exited"; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
fsize() { if [ -f "$1" ]; then stat -f%z "$1"; else echo 0; fi; }
# The number of timing.log lines of one event.
count() { awk -v e="$1" '$2 == e { n++ } END { print n + 0 }' "$TL" 2>/dev/null || echo 0; }
last_time() { awk 'END { print $1 + 0 }' "$TL"; }
has_log_complete() { [ -f "$TL" ] && awk '$2 == "content" && $3 == "log-complete" { f = 1 } END { exit !f }' "$TL"; }
new_refresh() { [ "$(lines "$RL")" -gt "$1" ]; }
new_graph_reload() { [ "$(count graph-reload)" -gt "$1" ]; }

# wait_for <timeout s> <what> <command…>: polls every 0.2 s until the command succeeds.
wait_for() {
  local timeout="$1" what="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    alive
    [ $SECONDS -lt $deadline ] || die "timed out after ${timeout} s waiting for $what"
    sleep 0.2
  done
}

# Waits until timing.log and refresh.log are quiet for 2 s, every branch-map-start has its `content branch-map` line
# (done or cancelled) and the last log-start has its `content log-complete`: a Debug log load or branch map of a big
# log can run longer than 2 s without logging, and the next change would cancel it.
settle() {
  local deadline=$((SECONDS + 300)) last="" now quiet=0
  while :; do
    alive
    now="$(fsize "$TL") $(fsize "$RL")"
    if [ "$now" = "$last" ]; then quiet=$((quiet + 1)); else quiet=0; last="$now"; fi
    if [ $quiet -ge 10 ] && awk '$2 == "branch-map-start" { s++ } $2 == "content" && $3 == "branch-map" { d++ }
        $2 == "log-start" { l = 1 } $2 == "content" && $3 == "log-complete" { l = 0 }
        END { exit !(s == d && !l) }' "$TL"; then
      return
    fi
    [ $SECONDS -lt $deadline ] || die "the logs did not settle within 300 s (a log load or branch map never ended)"
    sleep 0.2
  done
}

# report <label> <refresh.log lines before the change> <window end (timing.log ms)>: prints one row, from the change's
# refresh (the first new refresh with `refs`, else the first new one) to the window end, and sets M1.
M1="-"
report() {
  local label="$1" before="$2" end="$3" refresh t0 scope row
  refresh="$(awk -v b="$before" 'NR > b && $2 == "refresh" { if (!f) f = $0; if (!r && $3 ~ /refs/) r = $0 }
    END { print (r ? r : f) }' "$RL")"
  t0="${refresh%% *}"
  scope="${refresh##* }"
  row="$(awk -v t0="$t0" -v end="$end" '
    $1 + 0 < t0 + 0 || $1 + 0 > end + 0 { next }
    $2 == "graph-reload" { reloads++; if (m1 == "") m1 = sprintf("%.1f", $1 - t0) }
    $2 == "log-start" { starts++ }
    $2 == "log-again" { again++ }
    $2 == "branch-map-start" { bm++ }
    $2 == "content" && $3 == "branch-map" && $4 == "cancelled" { bmc++ }
    $2 == "content" && $3 == "log-reload" {
      d = $4; for (i = 5; i <= NF; i++) d = d " " $i
      lr = lr (lr == "" ? "" : " | ") d
    }
    $2 == "mem" { fp = $3; pk = $4; sub(/.*=/, "", fp); sub(/.*=/, "", pk) }
    END {
      if (m1 == "") m1 = "-"
      printf "%s\t%8s %6d %6d %7d %6d %6d %9s %8s  %s\n", m1, m1, starts, again, reloads, bm, bmc,
        (fp == "" ? "-" : fp), (pk == "" ? "-" : pk), (lr == "" ? "-" : lr)
    }' "$TL")"
  M1="${row%%$'\t'*}"
  row="${row#*$'\t'}"
  printf '%-6s %-12s %s\n' "$label" "${scope:--}" "$row"
}

note "waiting for the first log-complete (up to 600 s)"
state_used() { [ -n "$(ls -A "$STATE_DIR")" ]; }
wait_for 60 "a file in the state dir (a build without DEBUG or HISTQ_PERF ignores it)" state_used
wait_for 600 "the first log-complete" has_log_complete
settle
first="$(awk '$2 == "content" && $3 == "log-complete" { print $1, $4; exit }' "$TL")"
first_peak="$(awk -v t="${first%% *}" '$2 == "mem" && $1 + 0 >= t + 0 { p = $4; sub(/.*=/, "", p); print p; exit }' "$TL")"
echo "app: $APP"
echo "repo: $REPO (tip $START_TIP, file $FILE)"
echo "first load: log-complete at ${first%% *} ms, ${first##* } commits, peak ${first_peak:--} MB"
echo
printf '%-6s %-12s %8s %6s %6s %7s %6s %6s %9s %8s  %s\n' cycle refresh "M1 ms" starts again reloads bm bm-cx \
  "fp MB" "peak MB" "log-reload"

m1s=()
for k in $(seq "$CYCLES"); do
  before="$(lines "$RL")"
  echo "perf $k" >> "$REPO/$FILE"
  wait_for 60 "the refresh after edit $k" new_refresh "$before"
  settle
  report "${k}w" "$before" "$(last_time)"

  before="$(lines "$RL")"
  reloads="$(count graph-reload)"
  GIT_AUTHOR_DATE="@$((TIP_DATE + 60 * k)) +0000" GIT_COMMITTER_DATE="@$((TIP_DATE + 60 * k)) +0000" \
    g commit -qam "perf $k"
  wait_for 120 "a graph-reload after commit $k" new_graph_reload "$reloads"
  settle
  report "$k" "$before" "$(last_time)"
  m1s+=("$M1")
done

median="$(printf '%s\n' "${m1s[@]}" | awk '$1 != "-"' | sort -n | awk '{ v[NR] = $1 } END {
  if (NR == 0) print "-"; else if (NR % 2) print v[(NR + 1) / 2]; else printf "%.1f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }')"
max="$(printf '%s\n' "${m1s[@]}" | awk '$1 != "-"' | sort -n | awk 'END { print (NR ? $1 : "-") }')"
ratio="n/a (fewer than 5 cycles)"
if [ "$CYCLES" -ge 5 ]; then
  ratio="$(awk -v c="${m1s[4]}" -v m="$median" 'BEGIN { print (c == "-" || m == "-" || m == 0) ? "-" : sprintf("%.2f", c / m) }')"
fi
final_peak="$(awk '$2 == "mem" { p = $4; sub(/.*=/, "", p) } END { print (p == "" ? "-" : p) }' "$TL")"
echo
echo "rows: <k>w = the WIP reload after the edit of cycle k, <k> = the reload after its commit; M1 = first graph-reload"
echo "      minus the refresh; starts/again/reloads/bm/bm-cx = log-start, log-again, graph-reload, branch-map-start,"
echo "      branch-map cancelled lines in the window; fp/peak = the window's last mem line"
echo "summary (commit reloads): M1 median ${median} ms, max ${max} ms, cycle 5/median ${ratio}," \
  "final peak ${final_peak} MB, first-load peak ${first_peak:--} MB"

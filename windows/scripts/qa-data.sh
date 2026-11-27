#!/usr/bin/env bash
# Data and checks for the Windows QA runs (the phase 5 spike, the M2 exit), run on the Mac.
#
# Usage:
#   windows/scripts/qa-data.sh fixtures [out]
#       Builds scripts/make-fixtures.sh's repos (--big 200000 --portable) in a temp folder and zips the graph fixture
#       and the 200k-commit one into [out] (default ~/Downloads/HistqQA-data): fx-graph.zip (folder graph) and
#       fx-big-200k.zip (folder big-200k), each unzipped into C:\HistqQA\fx in the VM.
#   windows/scripts/qa-data.sh check-rows <fixture> <rows.json>
#       Compares the app's -HistqRowsProbe output with git log of the same fixture on the Mac (LogReader's arguments,
#       date order): the first rows.json count of commits (50 by default), hash and parents in order, refs as an
#       unordered set of full ref names (HEAD only when detached; the symbolic refs/remotes/*/HEAD and the refs the log
#       excludes left out). Prints MATCH, or each difference; exits 1 on any.
#   windows/scripts/qa-data.sh check-scroll <scroll.json>
#       The scroll checks of "check" on a repo tab's -HistqScrollProbe output: its run conditions and the frame-time
#       thresholds (median 17.5, p95 33.4, max 100, draw p95 8 ms).
#   windows/scripts/qa-data.sh dump <n> [out]
#       Builds scripts/make-fixtures.sh's big repo with <n> commits in a temp folder (outside the checkout, deleted
#       afterwards) and writes its history with LogReader's exact git log arguments (date order, the app's default):
#       NUL-terminated records, to [out] or ~/Downloads/HistqQA-data/big-<n>.log (big-1m.log for 1000000).
#       Prints the record count. The VM parses the file with LogParser, so it needs no git.
#   windows/scripts/qa-data.sh check <spike.json> [n]
#       Compares the harness's spike.json with the phase 5 gate thresholds (parsedCommits == n, default 1000000) and
#       the scroll probe's run conditions (drawCount >= 0.9 * frameCount, wheelStepsSent == 200, scrollSeconds >= 10).
#       Prints PASS/FAIL per check, then the probe's diagnostic fields (INFO, not checked); exits 1 on any FAIL.
#       With "probes": "skipped" (an interactive -HistqScrollProbe 0 run) only the load checks run.
set -euo pipefail

die() { echo "qa-data: $*" >&2; exit 1; }
usage() {
  echo "usage: qa-data.sh fixtures [out] | check-rows <fixture> <rows.json> | check-scroll <scroll.json>" \
    "| dump <n> [out] | check <spike.json> [n]" >&2
  exit 2
}

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"

# LogReader.Arguments (windows/src/Histq.Core/Read/LogReader.cs) with --topo-order swapped for --date-order, as
# LogReader.ArgumentsFor does for Order.Date. Keep in sync with LogReader.cs.
log_args=(
  log -z --exclude=refs/stash '--exclude=refs/notes/*' '--exclude=refs/prefetch/*'
  '--exclude=refs/remotes/*/HEAD' --all
  --date-order
  '--format=%H%x1f%P%x1f%at%x1f%ct%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s%x1f%b'
)

is_count() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ]; }

dump() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  local n="$1"
  is_count "$n" || die "<n> must be a positive number"
  local name="big-$n.log"
  [ "$n" != 1000000 ] || name="big-1m.log"
  local out="${2:-$HOME/Downloads/HistqQA-data/$name}"
  mkdir -p "$(dirname "$out")"

  # Global, so the EXIT trap still sees it after the function returns.
  qa_tmp="$(mktemp -d "${TMPDIR:-/tmp}/histq-qa-data.XXXXXX")"
  trap 'rm -rf "$qa_tmp"' EXIT
  "$repo_root/scripts/make-fixtures.sh" "$qa_tmp/fixtures" --big "$n" --portable >/dev/null

  # The read environment's settings that change log output: no user or system config, UTF-8 output, no signatures.
  (
    cd "$qa_tmp/fixtures/big"
    env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_COUNT=2 \
      GIT_CONFIG_KEY_0=i18n.logOutputEncoding GIT_CONFIG_VALUE_0=UTF-8 \
      GIT_CONFIG_KEY_1=log.showSignature GIT_CONFIG_VALUE_1=false \
      git "${log_args[@]}"
  ) >"$out.partial"
  mv "$out.partial" "$out"

  local count
  count="$(LC_ALL=C tr -cd '\000' <"$out" | wc -c | tr -d ' ')"
  echo "$count records in $out"
  [ "$count" -eq "$n" ] || die "expected $n records, got $count"
}

fixtures() {
  [ $# -le 1 ] || usage
  local out="${1:-$HOME/Downloads/HistqQA-data}"
  mkdir -p "$out"
  qa_tmp="$(mktemp -d "${TMPDIR:-/tmp}/histq-qa-fixtures.XXXXXX")"
  trap 'rm -rf "$qa_tmp"' EXIT
  "$repo_root/scripts/make-fixtures.sh" "$qa_tmp/fx" --big 200000 --portable >/dev/null
  mv "$qa_tmp/fx/big" "$qa_tmp/fx/big-200k"
  local name
  for name in graph big-200k; do
    rm -f "$out/fx-$name.zip.partial"
    ditto -c -k --norsrc --noextattr --keepParent "$qa_tmp/fx/$name" "$out/fx-$name.zip.partial"
    mv "$out/fx-$name.zip.partial" "$out/fx-$name.zip"
    echo "$out/fx-$name.zip"
  done
}

check_rows() {
  [ $# -eq 2 ] || usage
  local fixture="$1" rows="$2"
  [ -d "$fixture" ] || die "no such folder: $fixture"
  [ -f "$rows" ] || die "no such file: $rows"
  qa_tmp="$(mktemp -d "${TMPDIR:-/tmp}/histq-qa-rows.XXXXXX")"
  trap 'rm -rf "$qa_tmp"' EXIT
  # LogReader's arguments (date order, the app's default) with full ref names in %D, without the user's or the
  # system's git config (as the read environment).
  env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$fixture" log \
    --exclude=refs/stash '--exclude=refs/notes/*' '--exclude=refs/prefetch/*' '--exclude=refs/remotes/*/HEAD' --all \
    --date-order --decorate=full '--format=%H%x1f%P%x1f%D' >"$qa_tmp/log"
  python3 -I - "$rows" "$qa_tmp/log" <<'PY'
import json
import re
import sys

rows_path, log_path = sys.argv[1], sys.argv[2]
with open(rows_path, encoding="utf-8-sig") as f:
    probe = json.load(f)
if probe.get("error"):
    print(f"FAIL  rows.json error: {probe['error']}")
    sys.exit(1)
rows = probe.get("rows")
if not isinstance(rows, list) or not rows:
    print("FAIL  rows.json has no rows")
    sys.exit(1)

# Refs the app never lists: symbolic remote HEADs and what the log excludes.
EXCLUDED = re.compile(r"^refs/(stash$|notes/|prefetch/|remotes/[^/]+/HEAD$)")


def refs_of(decoration):
    refs = set()
    for part in filter(None, (p.strip() for p in decoration.split(","))):
        if part.startswith("HEAD -> "):
            part = part[len("HEAD -> "):]
        elif part.startswith("tag: "):
            part = part[len("tag: "):]
        if not EXCLUDED.match(part):
            refs.add(part)
    return refs


expected = []
with open(log_path, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        sha, parents, decoration = (line.split("\x1f") + ["", ""])[:3]
        expected.append({"hash": sha, "parents": parents.split() if parents else [], "refs": refs_of(decoration)})
        if len(expected) == len(rows):
            break

differences = []
if len(expected) < len(rows):
    differences.append(f"git log has {len(expected)} commits, rows.json {len(rows)}")
for index, (want, got) in enumerate(zip(expected, rows)):
    if got.get("hash") != want["hash"]:
        differences.append(f"row {index}: hash {got.get('hash')} != {want['hash']}")
    if list(got.get("parents") or []) != want["parents"]:
        differences.append(f"row {index}: parents {got.get('parents')} != {want['parents']}")
    if set(got.get("refs") or []) != want["refs"]:
        differences.append(f"row {index}: refs {sorted(got.get('refs') or [])} != {sorted(want['refs'])}")

if differences:
    for difference in differences:
        print(f"DIFF  {difference}")
    print(f"FAIL  {len(differences)} differences in the first {len(rows)} rows")
    sys.exit(1)
print(f"MATCH  the first {len(rows)} rows (hash, parents, refs)")
PY
}

check() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage
  local file="$1" n="${2:-1000000}"
  [ -f "$file" ] || die "no such file: $file"
  is_count "$n" || die "[n] must be a positive number"
  check_probe spike "$file" "$n"
}

check_scroll() {
  [ $# -eq 1 ] || usage
  [ -f "$1" ] || die "no such file: $1"
  check_probe scroll "$1" 0
}

# check_probe spike|scroll <file> <n>: spike.json (every gate check) or scroll.json (the scroll probe's only).
check_probe() {
  python3 -I - "$@" <<'PY'
import json
import sys

mode, path, expected = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, encoding="utf-8") as f:
    probe = json.load(f)

failed = False


def check(name, ok, value):
    global failed
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {json.dumps(value)}")
    failed = failed or not ok


def number(key):
    value = probe.get(key)
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def at_most(key, limit):
    value = number(key)
    check(f"{key} <= {limit}", value is not None and value <= limit, probe.get(key))


if probe.get("error"):
    check("error", False, probe["error"])

parsed = number("parsedCommits")
if mode == "spike":
    check(f"parsedCommits == {expected}", parsed == expected, probe.get("parsedCommits"))
    at_most("firstRowsMs", 1500)
    at_most("fullLoadMs", 15000)

if probe.get("probes") == "skipped":
    print('SKIP  all probe checks: "probes": "skipped" (an interactive -HistqScrollProbe 0 run)')
    sys.exit(1 if failed else 0)

# Run conditions: the probe ran the way the gate assumes.
frames = number("frameCount")
draws = number("drawCount")
check(
    "drawCount >= 0.9 * frameCount",
    frames is not None and draws is not None and draws >= 0.9 * frames,
    {"drawCount": probe.get("drawCount"), "frameCount": probe.get("frameCount")},
)
check("wheelStepsSent == 200", number("wheelStepsSent") == 200, probe.get("wheelStepsSent"))
seconds = number("scrollSeconds")
check("scrollSeconds >= 10", seconds is not None and seconds >= 10, probe.get("scrollSeconds"))

at_most("frameIntervalMedianMs", 17.5)
at_most("frameIntervalP95Ms", 33.4)
at_most("frameIntervalMaxMs", 100)
at_most("drawMsP95", 8)

if mode == "scroll":
    print(f"INFO  parsedCommits (graph rows): {json.dumps(probe.get('parsedCommits'))}")
    for key in ("scrollPacing", "pacingDrawSteps", "pacingTimerSteps", "intervalsOver33", "intervalsOver100", "topIntervalsMs"):
        print(f"INFO  {key}: {json.dumps(probe[key]) if key in probe else '(absent)'}")
    sys.exit(1 if failed else 0)

last = number("lastRowIndex")
check("lastRowIndex == parsedCommits - 1", parsed is not None and last == parsed - 1, probe.get("lastRowIndex"))
check("lastRowFullyDrawn", probe.get("lastRowFullyDrawn") is True, probe.get("lastRowFullyDrawn"))
hit = number("lastRowHitTest")
check("lastRowHitTest == lastRowIndex", last is not None and hit == last, probe.get("lastRowHitTest"))

matches = probe.get("hitTestMatches")
if isinstance(matches, list):
    ok = len(matches) == 5 and all(m is True for m in matches)
else:
    ok = isinstance(matches, int) and not isinstance(matches, bool) and matches == 5
check("hitTestMatches (5 of 5)", ok, matches)
at_most("rowTopErrorPx", 0.5)
at_most("clickToHighlightFrames", 1)

backdrop = probe.get("backdrop")
mica = probe.get("micaSupported")
check(
    "backdrop != none, or micaSupported == false",
    backdrop in ("mica", "acrylic") or (backdrop == "none" and mica is False),
    {"backdrop": backdrop, "micaSupported": mica},
)

# Diagnostics, printed as they are (absent in an older spike.json).
for key in (
    "scrollPacing",
    "gcLatencyMode",
    "gcConcurrent",
    "gcServer",
    "pacingDrawSteps",
    "pacingTimerSteps",
    "firstTickAtMs",
    "secondTickAtMs",
    "firstIntervalMs",
    "firstIntervalIncludesSetup",
    "maxIntervalIndex",
    "maxIntervalAtMs",
    "topIntervalsMs",
    "intervalsOver33",
    "intervalsOver100",
    "drawIntervalMedianMs",
    "drawIntervalP95Ms",
    "drawIntervalMaxMs",
    "gcCount0Before",
    "gcCount0After",
    "gcCount1Before",
    "gcCount1After",
    "gcCount2Before",
    "gcCount2After",
    "gcPauseTotalMsBeforeProbe",
    "gcPauseMs",
    "gcTotalAllocatedBytesProbe",
    "subjectText",
    "probeDelaySeconds",
    "gcLatencyModeDuringProbe",
    "gcEventsDropped",
    "gcEventsError",
    "bisect",
    "layoutUpdatedCount",
    "sheetUpdateCount",
    "transformToVisualCount",
    "automationEventsCount",
    "automationRowPeersCreated",
):
    print(f"INFO  {key}: {json.dumps(probe[key]) if key in probe else '(absent)'}")

# GC.GetGCMemoryInfo per kind before and after the probe, one compact line each.
for key in ("gcInfoBefore", "gcInfoAfter"):
    info = probe.get(key)
    if not isinstance(info, dict):
        print(f"INFO  {key}: (absent)")
        continue
    for kind, value in info.items():
        print(f"INFO  {key}.{kind}: {json.dumps(value, separators=(',', ':'))}")

# The runtime's GC events (all of them are in spike.json), compactly: ms since the probe start, then GCStart (count,
# depth, reason, type), GCEnd (count, depth), and each pause from a GCSuspendEEBegin to the next GCRestartEEEnd.
events = probe.get("gcEvents")
if not isinstance(events, list):
    print("INFO  gcEvents: (absent)")
else:
    events = [e for e in events if isinstance(e, dict)]
    shown = []
    suspended = None
    for event in events:
        at = event.get("atMs")
        at = at if isinstance(at, (int, float)) and not isinstance(at, bool) else None
        event_id = event.get("id")
        if event_id == 1:
            # The number is the runtime's; the name only a reading of it.
            reason = "/".join(str(v) for v in (event.get("reason"), event.get("reasonName")) if v is not None)
            kind = "/".join(str(v) for v in (event.get("type"), event.get("typeName")) if v is not None)
            shown.append((at, f"GCStart count={event.get('count')} depth={event.get('depth')} reason={reason} type={kind}"))
        elif event_id == 2:
            shown.append((at, f"GCEnd   count={event.get('count')} depth={event.get('depth')}"))
        elif event_id == 9:
            suspended = at
        elif event_id == 3:
            pause = f"{at - suspended:.1f} ms" if at is not None and suspended is not None else "?"
            shown.append((suspended, f"pause   {pause}"))
            suspended = None
    print(f"INFO  gcEvents: {len(events)} events, {len(shown)} shown")
    # A pause is shown at its start, so it sorts before the GCStart it holds.
    for at, text in sorted(shown, key=lambda item: float("inf") if item[0] is None else item[0]):
        print(f"INFO    {at:9.1f} ms  {text}" if at is not None else f"INFO    {'?':>9} ms  {text}")

sys.exit(1 if failed else 0)
PY
}

[ $# -ge 1 ] || usage
command="$1"
shift
case "$command" in
  fixtures) fixtures "$@" ;;
  check-rows) check_rows "$@" ;;
  check-scroll) check_scroll "$@" ;;
  dump) dump "$@" ;;
  check) check "$@" ;;
  *) usage ;;
esac

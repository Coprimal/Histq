#!/usr/bin/env python3
"""UX latency stats: cuts a Histq timing.log (DEBUG or HISTQ_PERF build) into one window per click and prints, per
window, the first feedback, the content / settled times and the git processes it ran.

Usage:
  perf-ux-stats.py --row <scenario> <timing.log>     one summary row for one run (scripts/perf-ux.sh prints it)
  perf-ux-stats.py <scenario> <timing.log>…          the scenario's table over the given runs
  perf-ux-stats.py <results/<label> dir>             the table of every scenario in a results label folder

Each `<x>.timing.log` may have a `<x>.refresh.log` beside it (a state dir's `refresh.log` too) and a `<x>.meta` (the
harness's notes: the outside edit's time, repo and file). Times are ms since launch; a `git` line is written when its
process ends, so it started at `t - ms`. Git lines whose verb starts with `-` or whose repo is `/` are the startup
probes and are dropped.

Click windows: `select commit|wip|file|tab|pr …` (reads; after `walk start` when the run walks) and `op-click` (writes).
A window runs to the next click. Feedback and content lines are matched to their click by detail (`select file X` ->
`placeholder file X`, `content file X`), up to the next click of the same detail, so a late line is never given to
the wrong click. Writes: pre = op-start - op-click, end = op-end - op-click, settled = op-settled - op-click,
O1 = end - the main git command (the longest line of the scenario's main verb inside op-start..op-end), O2 = op-settled -
op-end, O3 = first graph-reload after op-end - op-end, unaccounted = op-end - op-start - the serial git ms inside it.
Serial ms is the union of the processes' intervals (what a strictly one-after-the-other run would add up to).
"""
import os
import re
import statistics
import sys
from collections import Counter, defaultdict

# Scenario -> groups of verbs; the main command is the longest line of each group present, summed (pull: its fetch
# plus its merge or rebase).
MAIN_VERBS = {
    "checkout": [{"checkout", "switch"}],
    "commit": [{"commit"}],
    "outside-edit": [{"commit"}],
    "stash": [{"stash"}],
    "rebase": [{"rebase"}],
    "fetch": [{"fetch"}],
    "pull": [{"fetch", "pull"}, {"merge", "rebase"}],
    "push": [{"push"}],
}

READS = {"sel-adjacent", "sel-repeat", "sel-far", "sel-wip", "file-commit", "file-wip", "tabs"}
PRS = {"pr-open", "pr-open-slow", "pr-action", "pr-mergeable"}
CLICK_KINDS = ("commit ", "wip", "file ", "tab ", "pr ")
FEEDBACK = ("placeholder", "content-info", "content", "tab-shown", "op-feedback")
REREAD_VERBS = {"status", "for-each-ref", "log", "rev-list"}


def main_verbs(scenario):
    for prefix, groups in MAIN_VERBS.items():
        if scenario == prefix or scenario.startswith(prefix + "-"):
            return groups
    return []


# ---- Parsing ----


class Git:
    __slots__ = ("end", "start", "ms", "verb", "repo", "exit", "signal")

    def __init__(self, t, detail):
        tokens = detail.split(" ")
        self.exit = self.signal = None
        while len(tokens) > 3 and re.match(r"^(exit|signal)=", tokens[-1]):
            key, value = tokens.pop().split("=", 1)
            setattr(self, key, value)
        self.verb = tokens[0]
        self.ms = float(tokens[1])
        self.repo = " ".join(tokens[2:])
        self.end = t
        self.start = t - self.ms


def sibling(timing, suffix):
    """`x.timing.log` -> `x.<suffix>`; a state dir's `timing.log` -> `refresh.log` beside it."""
    if timing.endswith(".timing.log"):
        return timing[: -len("timing.log")] + suffix
    return os.path.join(os.path.dirname(timing), suffix)


def read_lines(path):
    out = []
    try:
        with open(path, errors="replace") as handle:
            for raw in handle:
                parts = raw.rstrip("\n").split(" ", 2)
                if len(parts) < 2:
                    continue
                try:
                    t = float(parts[0])
                except ValueError:
                    continue
                out.append((t, parts[1], parts[2] if len(parts) > 2 else ""))
    except FileNotFoundError:
        pass
    return out


def read_meta(path):
    meta = {}
    try:
        with open(path) as handle:
            for raw in handle:
                key, _, value = raw.rstrip("\n").partition(" ")
                meta[key] = value
    except FileNotFoundError:
        pass
    return meta


class Run:
    def __init__(self, timing):
        self.path = timing
        lines = read_lines(timing)
        refresh = [(t, "refresh", d) for t, e, d in read_lines(sibling(timing, "refresh.log")) if e == "refresh"]
        self.events = sorted(lines + refresh, key=lambda line: line[0])
        self.meta = read_meta(sibling(timing, "meta"))
        self.gits = []
        for t, event, detail in self.events:
            if event != "git":
                continue
            try:
                git = Git(t, detail)
            except (ValueError, IndexError):
                continue
            if git.verb.startswith("-") or git.repo == "/":
                continue
            self.gits.append(git)
        self.end = self.events[-1][0] if self.events else 0.0
        self.file_lines = {}
        for _, event, detail in self.events:
            match = event == "file-load" and re.search(r" lines=(\d+)", detail)
            if match:
                self.file_lines.setdefault(detail.split(" env=")[0], int(match.group(1)))

    def first(self, start, stop, test):
        for t, event, detail in self.events:
            if t < start:
                continue
            if t > stop:
                return None
            if test(event, detail):
                return t
        return None

    def gits_in(self, start, stop, repo=None):
        return [g for g in self.gits if start <= g.start < stop and (repo is None or g.repo == repo)]


def serial_ms(gits):
    total, cur_start, cur_end = 0.0, None, None
    for g in sorted(gits, key=lambda g: g.start):
        if cur_end is None or g.start > cur_end:
            if cur_end is not None:
                total += cur_end - cur_start
            cur_start, cur_end = g.start, g.end
        else:
            cur_end = max(cur_end, g.end)
    if cur_end is not None:
        total += cur_end - cur_start
    return total


def git_summary(gits):
    verbs = Counter()
    counts = Counter()
    for g in gits:
        verbs[g.verb] += g.ms
        counts[g.verb] += 1
    top = " ".join(f"{v}*{counts[v]}:{ms:.0f}" for v, ms in verbs.most_common(3))
    return {
        "verb-ms": verbs,
        "verb-n": counts,
        "git": len(gits),
        "git-ms": sum(g.ms for g in gits),
        "serial": serial_ms(gits),
        "signal": sum(1 for g in gits if g.signal),
        "top": top or "-",
    }


# ---- Windows ----


def clicks(run, scenario):
    """(t, kind, detail) of each click: reads after `walk start` (when there is one), writes on op-click."""
    walk = run.first(0, float("inf"), lambda e, d: e == "walk" and d.startswith("start"))
    # The checks tabs-ignored and tabs-tracked are `tabs` walks.
    is_read, is_pr = scenario in READS or scenario.startswith("tabs-"), scenario in PRS
    is_write = not is_read and not is_pr and scenario != "-"
    out = []
    for t, event, detail in run.events:
        if event == "op-click" and not is_read and not is_pr:
            out.append((t, "op", detail))
        elif event == "select" and detail.startswith(CLICK_KINDS) and not is_write:
            if (is_pr and not detail.startswith("pr ")) or (walk is not None and t < walk):
                continue
            out.append((t, "select", detail))
    return out


def edit_anchor(run):
    parts = run.meta.get("edit", "").split(" ", 2)
    if len(parts) < 3:
        return None
    try:
        return float(parts[0]), parts[1], parts[2]
    except ValueError:
        return None


def windows(run, scenario):
    cs = clicks(run, scenario)
    anchor = edit_anchor(run)
    seen = set()
    out = []
    tail = run.first(0, float("inf"), lambda e, d: e == "walk" and d == "tail")
    for i, (t, kind, detail) in enumerate(cs):
        stop = cs[i + 1][0] if i + 1 < len(cs) else run.end + 1
        if kind == "op" and anchor and t < anchor[0] < stop:
            stop = anchor[0]
        if kind == "op":
            w = op_window(run, scenario, t, detail, stop)
        else:
            same = next((c[0] for c in cs[i + 1 :] if c[2] == detail), t + 10000)
            w = read_window(run, t, detail, stop, same)
            key = detail
            w["group"] = "revisit" if key in seen else "first"
            seen.add(key)
            if detail.startswith("tab ") and tail is not None and t > tail:
                w["group"] = "tail-changed" if anchor and anchor[1] == w.get("repo") else "tail-same"
            if detail.startswith("file "):
                lines = run.file_lines.get(detail[5:])
                w["lines"] = lines
                w["group"] += " " + bucket(lines)
            if detail.startswith("wip") or (scenario == "sel-wip" and detail.startswith("commit ")):
                w["group"] = ("wip " if detail.startswith("wip") else "commit ") + w["group"]
        w["t"] = t
        w["detail"] = detail
        out.append(w)
    return out


def bucket(lines):
    if lines is None:
        return "lines=?"
    if lines <= 200:
        return "<=200 lines"
    if lines <= 1400:
        return "<=1400 lines"
    return ">1400 lines"


def read_window(run, t, detail, stop, same):
    """A read click: `detail` is `commit <sha>`, `wip`, `file <path>`, `tab <i>` or `pr <n>`."""
    w = {"kind": "read"}
    is_tab = detail.startswith("tab ")
    if is_tab:
        index = detail[4:]
        shown = None
        for tt, event, d in run.events:
            if tt >= t and tt < stop and event == "tab-shown" and d.split(" ")[0] == index:
                shown = (tt, d.split(" ", 1)[1] if " " in d else "")
                break
        w["repo"] = shown[1] if shown else None
        w["F"] = shown[0] - t if shown else None
        commits = run.first(t, stop, lambda e, d: e == "content" and d.startswith("commits "))
        w["content"] = commits - t if commits is not None else w["F"]
        frame = None
        for tt, event, d in run.events:
            if t <= tt < stop and event == "tab-frame" and d.split(" ")[0] == index:
                frame = d
                break
        if frame:
            m = re.search(r"max=([\d.]+) over16=([\d.]+)", frame)
            if m:
                w["frame-max"], w["over16"] = float(m.group(1)), float(m.group(2))
        gits = run.gits_in(t, stop)
        by_repo = defaultdict(Counter)
        for g in gits:
            by_repo[g.repo][g.verb] += 1
        w["repo-verbs"] = by_repo
        w["repos"] = " ".join(
            f"{repo}[{','.join(f'{v}*{n}' for v, n in verbs.most_common())}]" for repo, verbs in sorted(by_repo.items())
        ) or "-"
        if w["repo"]:
            w["reread"] = sum(1 for g in gits if g.repo == w["repo"] and g.verb in REREAD_VERBS)
    else:
        bound = min(same, t + 10000)

        def matches(event, d):
            return event in FEEDBACK and (d == detail or d.startswith(detail + " "))

        first = run.first(t, bound, matches)
        w["F"] = first - t if first is not None else None
        content = run.first(t, bound, lambda e, d: e == "content" and d == detail)
        w["content"] = content - t if content is not None else None
        spin = run.first(t, bound, lambda e, d: e == "spinner" and d == detail)
        w["spinner"] = spin - t if spin is not None else None
    last = None
    for tt, event, _ in run.events:
        if tt >= stop:
            break
        if tt > t and event not in ("walk", "tab-frame", "mem", "select", "refresh"):
            last = tt
    w["settled"] = last - t if last is not None else None
    w.update(git_summary(run.gits_in(t, stop)))
    return w


def op_window(run, scenario, t, detail, stop):
    op_id, _, rest = detail.partition(" ")
    w = {"kind": "op", "op": rest.split(" ")[0] if rest else "?"}

    def line(event, test=lambda d: True):
        return run.first(t, float("inf"), lambda e, d: e == event and d.split(" ")[0] == op_id and test(d))

    start = line("op-start")
    end = line("op-end")
    settled = line("op-settled")
    end_detail = next((d for tt, e, d in run.events if e == "op-end" and d.split(" ")[0] == op_id), "")
    w["result"] = end_detail.split(" ")[1] if " " in end_detail else "?"
    w["pre"] = start - t if start is not None else None
    w["end"] = end - t if end is not None else None
    w["settled"] = settled - t if settled is not None else None
    feedback = run.first(t, stop, lambda e, d: e == "op-feedback")
    w["F"] = feedback - t if feedback is not None else None
    w["feedback"] = next((d for tt, e, d in run.events if tt == feedback and e == "op-feedback"), "-")
    w["O2"] = settled - end if settled is not None and end is not None else None
    if end is not None:
        reload = run.first(end, stop, lambda e, d: e == "graph-reload")
        w["O3"] = reload - end if reload is not None else None
    else:
        w["O3"] = None
    main_ms, main_names = 0.0, []
    if start is not None and end is not None:
        lane = [g for g in run.gits if g.start >= start - 0.5 and g.end <= end + 0.5]
        for group in main_verbs(scenario):
            best = max((g for g in lane if g.verb in group), key=lambda g: g.ms, default=None)
            if best:
                main_ms += best.ms
                main_names.append(f"{best.verb}:{best.ms:.0f}")
        w["main"] = " + ".join(main_names) or "none"
        w["O1"] = (end - t) - main_ms if main_names else None
        lane_serial = serial_ms(lane)
        w["lane-git"] = len(lane)
        w["unaccounted"] = (end - start) - lane_serial
    else:
        w["main"] = "none"
        w["O1"] = w["unaccounted"] = None
    w.update(git_summary(run.gits_in(t, stop)))
    return w


# ---- Run-level extras ----


def proof(run, scenario):
    """The proof that an outside change was read (CONTRIBUTING.md, "UX latency benchmark"): after the harness's edit, a
    `refresh` (refresh.log), a `refresh-read` and a `git status` of that repo, then, once that status is in, the graph's
    reaction to the WIP row appearing: `log-again synthetic` or `graph-reload`. In `tabs` the hidden repo holds its
    refresh until it is shown (task 3.6): after its `select tab`, a `git status` of that repo, a `refresh-read`, then
    `log-start` or `log-again synthetic` and the log's `graph-reload` (the switch's own `graph-reload` comes before and
    does not count). In the file-wip tail the file was already changed, so the WIP row stays and no graph line is due;
    a `file-load` of the open file is due instead. pass(<a>/<b>ms) = from the edit / from the `refresh` line (in
    `tabs`, from the `select tab`) to the last of those lines; the first number is an upper bound (the edit's time is
    the last log line before it, which can be up to 1 s earlier after `op-settled`), the second is the watcher's own
    latency (in `tabs`, the select's)."""
    # The checks tabs-ignored and tabs-tracked are `tabs` walks.
    scenario = "tabs" if scenario.startswith("tabs-") else scenario
    anchor = edit_anchor(run)
    if anchor is None:
        return None
    t0, repo, path = anchor
    inf = float("inf")
    refresh = run.first(t0, inf, lambda e, d: e == "refresh")
    if refresh is None:
        return "fail(no refresh)"
    missing = []
    if scenario == "tabs":
        index = next((d.split(" ")[0] for _, e, d in run.events if e == "tab-shown" and d.split(" ", 1)[-1] == repo), None)
        refresh = run.first(t0, inf, lambda e, d: e == "select" and d == f"tab {index}")
        if refresh is None:
            return "fail(no select tab)"
    read = run.first(refresh, inf, lambda e, d: e == "refresh-read")
    if read is None:
        missing.append("refresh-read")
    status = min((g.end for g in run.gits if g.repo == repo and g.verb == "status" and g.end >= refresh), default=None)
    if status is None:
        missing.append("git status " + repo)
    found = [read, status]
    after = status if status is not None else refresh
    if scenario == "tabs":
        log = run.first(max(t for t in found + [refresh] if t is not None), inf,
                        lambda e, d: (e == "log-again" and d == "synthetic") or e == "log-start")
        graph = run.first(log, inf, lambda e, d: e == "graph-reload") if log is not None else None
        if graph is None:
            missing.append("log-start|log-again synthetic, then graph-reload")
        found.append(graph)
    elif scenario != "file-wip":
        graph = run.first(after, inf, lambda e, d: (e == "log-again" and d == "synthetic") or e == "graph-reload")
        if graph is None:
            missing.append("log-again synthetic|graph-reload")
        found.append(graph)
    else:
        load = run.first(refresh, inf, lambda e, d: e == "file-load" and d.startswith(path + " "))
        if load is None:
            missing.append("file-load " + path)
        found.append(load)
    if missing:
        return "fail(no " + ", ".join(missing) + ")"
    last = max(t for t in found if t is not None)
    return f"pass({last - t0:.0f}/{last - refresh:.0f}ms)"


def pr_extras(run):
    out = {}
    for t, event, detail in run.events:
        m = event == "content" and re.match(r"^pr (\d+) action (\S+) (ok|failed)$", detail)
        if m:
            reload = run.first(t, float("inf"), lambda e, d: e == "content" and d == f"pr {m.group(1)} reloaded")
            out["action"] = f"{m.group(2)} {m.group(3)}"
            out["action->reloaded"] = reload - t if reload is not None else None
            break
    mergeable = [t for t, e, d in run.events if e == "content" and re.match(r"^pr \d+ mergeable ", d)]
    if mergeable:
        out["mergeable"] = len(mergeable)
        out["mergeable-gaps"] = [b - a for a, b in zip(mergeable, mergeable[1:])]
    return out


def walk_wall(run):
    start = run.first(0, float("inf"), lambda e, d: e == "walk" and d.startswith("start"))
    done = run.first(0, float("inf"), lambda e, d: e == "walk" and d == "done")
    return done - start if start is not None and done is not None else None


# ---- Formatting ----


def fmt(x):
    return "-" if x is None else f"{x:.0f}" if abs(x) >= 10 else f"{x:.1f}"


def stat(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return "n=0"
    p90 = xs[min(len(xs) - 1, int(len(xs) * 0.9))]
    return f"n={len(xs)} min={fmt(xs[0])} med={fmt(statistics.median(xs))} p90={fmt(p90)} max={fmt(xs[-1])}"


def short(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return "-"
    return f"{fmt(xs[0])}/{fmt(statistics.median(xs))}/{fmt(xs[-1])}"


def row(scenario, timing):
    """One line for one run (min/med/max over its windows for reads)."""
    run = Run(timing)
    ws = windows(run, scenario)
    parts = []
    ops = [w for w in ws if w["kind"] == "op"]
    reads = [w for w in ws if w["kind"] == "read"]
    for w in ops:
        parts.append(
            f"op {w['op']} {w['result']} F={fmt(w['F'])}({w['feedback'][:28]}) pre={fmt(w['pre'])} end={fmt(w['end'])}"
            f" settled={fmt(w['settled'])} O1={fmt(w['O1'])}[{w['main']}] O2={fmt(w['O2'])} O3={fmt(w['O3'])}"
            f" git={w['git']}/{fmt(w['git-ms'])}ms/serial {fmt(w['serial'])} sig={w['signal']}"
            f" unacc={fmt(w['unaccounted'])} top={w['top']}"
        )
    if reads:
        parts.append(
            f"clicks={len(reads)} F={short([w['F'] for w in reads])} content={short([w['content'] for w in reads])}"
            f" settled={short([w['settled'] for w in reads])} git/click={short([w['git'] for w in reads])}"
            f" serial/click={short([w['serial'] for w in reads])} sig={sum(w['signal'] for w in reads)}"
        )
        spins = [w.get("spinner") for w in reads if w.get("spinner") is not None]
        if spins:
            parts.append(f"spinner={short(spins)}")
        frames = [w.get("frame-max") for w in reads if w.get("frame-max") is not None]
        if frames:
            parts.append(f"frame-max={short(frames)}")
            rereads = [w["reread"] for w in reads if w.get("group") == "tail-same" and "reread" in w]
            parts.append(f"tail-same reread={rereads[0] if rereads else '-'}")
        if any("lines" in w for w in reads):
            big = [w["content"] for w in reads if (w.get("lines") or 0) > 1400]
            if big:
                parts.append(f"content>1400={short(big)}")
        wall = walk_wall(run)
        if wall is not None:
            parts.append(f"walk={fmt(wall)}ms")
    extras = pr_extras(run)
    if "action" in extras:
        parts.append(f"action {extras['action']} ->reloaded={fmt(extras['action->reloaded'])}")
    if "mergeable" in extras and scenario == "pr-mergeable":
        parts.append(f"mergeable lines={extras['mergeable']} gaps={'/'.join(fmt(g) for g in extras['mergeable-gaps'])}")
    p = proof(run, scenario)
    if p:
        parts.append(f"proof={p}")
    if not ws:
        parts.append("no click window")
    return " | ".join(parts)


METRICS_READ = ("F", "content", "spinner", "settled", "frame-max", "over16", "reread", "git", "git-ms", "serial", "signal")
METRICS_OP = ("F", "pre", "end", "settled", "O1", "O2", "O3", "git", "git-ms", "serial", "signal", "lane-git", "unaccounted")


def table(scenario, timings):
    """The scenario's table over its runs: min / median / p90 / max per metric and window group."""
    print(f"== {scenario}: {len(timings)} run(s)")
    groups = defaultdict(list)
    verbs = defaultdict(Counter)
    verb_n = defaultdict(Counter)
    repo_verbs = defaultdict(lambda: defaultdict(Counter))
    extras = defaultdict(list)
    for timing in timings:
        run = Run(timing)
        for w in windows(run, scenario):
            group = f"op {w['op']}" if w["kind"] == "op" else w.get("group", "?")
            groups[group].append(w)
            verbs[group].update(w["verb-ms"])
            verb_n[group].update(w["verb-n"])
            if w["kind"] == "op":
                extras["main " + group].append(w["main"])
                extras["result " + group].append(w["result"])
            for repo, counts in w.get("repo-verbs", {}).items():
                repo_verbs[group][repo].update(counts)
        p = proof(run, scenario)
        if p:
            extras["proof"].append(p)
        wall = walk_wall(run)
        if wall is not None:
            extras["walk ms"].append(fmt(wall))
        pe = pr_extras(run)
        if "action" in pe:
            extras["action->reloaded ms"].append(fmt(pe["action->reloaded"]))
        if "mergeable" in pe and scenario == "pr-mergeable":
            extras["mergeable lines"].append(str(pe["mergeable"]))
        uptime = read_lines_raw(sibling(timing, "uptime.txt"))
        if uptime:
            m = re.search(r"load averages?: ([\d.]+)", uptime)
            extras["load 1m"].append(m.group(1) if m else "?")
    for group, ws in sorted(groups.items()):
        print(f"  {group}: {len(ws)} window(s)")
        metrics = METRICS_OP if ws[0]["kind"] == "op" else METRICS_READ
        for key in metrics:
            values = [w.get(key) for w in ws]
            if any(v is not None for v in values):
                print(f"    {key:12s} {stat(values)}")
        n = max(len(ws), 1)
        top = " ".join(f"{v}*{verb_n[group][v] / n:.1f}:{ms / n:.0f}" for v, ms in verbs[group].most_common(6))
        print(f"    {'top verbs':12s} {top or '-'} (<verb>*<count>:<ms> per window)")
        for repo, counts in sorted(repo_verbs[group].items()):
            per = ",".join(f"{v}*{c / n:.1f}" for v, c in counts.most_common())
            print(f"    {'git ' + repo:12s} {per} (<verb>*<count> per window)")
    for key, values in extras.items():
        print(f"  {key}: {' | '.join(values)}")


def read_lines_raw(path):
    try:
        with open(path) as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


def label_dir(folder):
    by_scenario = defaultdict(list)
    for name in sorted(os.listdir(folder)):
        m = re.match(r"^(.+)-(\d+)\.timing\.log$", name)
        if m:
            by_scenario[m.group(1)].append((int(m.group(2)), os.path.join(folder, name)))
    head = read_lines_raw(os.path.join(folder, "HEAD")).strip()
    if head:
        print(f"HEAD: {head}")
    for scenario in sorted(by_scenario):
        table(scenario, [path for _, path in sorted(by_scenario[scenario])])


def main(argv):
    if len(argv) == 3 and argv[0] == "--row":
        print(row(argv[1], argv[2]))
    elif len(argv) == 1 and os.path.isdir(argv[0]):
        label_dir(argv[0])
    elif len(argv) >= 2:
        table(argv[0], argv[1:])
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

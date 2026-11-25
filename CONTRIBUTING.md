# Contributing to Histq

## Setup

You need Xcode 27 (the version `project.yml` names; the app compiles macOS 26 APIs behind availability checks), git
2.36 or later, and XcodeGen. `project.yml` is the source of truth: `Histq.xcodeproj` is generated from it and
git-ignored. Run `xcodegen generate` again after you change `project.yml` or add, move or delete a source file.

```sh
brew install xcodegen
xcodegen generate
open Histq.xcodeproj
```

## Build and test

From the repository root:

```sh
xcodegen generate && xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Debug -skipPackagePluginValidation build
cd Packages/HistqCore && swift test   # core tests (Swift Testing)
```

`-skipPackagePluginValidation` is needed because the terminal uses SwiftTerm, whose package has a build-tool plugin.
Xcode asks you once to trust a package plugin; `xcodebuild` cannot ask, so without the flag the build fails on plugin
validation. Pass it to every `xcodebuild` call on this project, including `-showBuildSettings`.

Never pass `-derivedDataPath` to a local `xcodebuild`: the default DerivedData folder is the one Xcode uses, so a
command-line build and Cmd-R in Xcode share one cache instead of building twice.

## Signing

Debug is signed with Developer ID like Release (team in `project.yml`), so Keychain items (the GitHub token, AI keys)
and macOS grants survive rebuilds. Without that certificate, add these overrides to every `xcodebuild` build; macOS
then asks again for Keychain access and grants after each rebuild:

```sh
CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=
```

## OAuth apps

"Sign in with GitHub" and "Sign in with GitLab" use the OAuth device flow with Histq's own registered apps; "Sign in
with Bitbucket" and "Sign in with Microsoft" (Azure DevOps) use the authorization code flow in the browser, back to
Histq at `http://127.0.0.1:47823/callback` (Bitbucket) or `http://localhost:<random port>` (Microsoft, with PKCE).
Their IDs are public values, set as build settings in `project.yml` and read from Info.plist. With an empty GitHub ID,
Settings › Integrations shows how to set it; with an empty GitLab ID, gitlab.com has no sign-in. A personal access token
(an API token on Bitbucket) works either way.

| Provider | What to register | Build setting (Info.plist key) |
| -------- | ---------------- | ------------------------------ |
| GitHub | An OAuth App with "Enable Device Flow" checked. | `HISTQ_GITHUB_CLIENT_ID` (`HistqGitHubClientID`) |
| GitLab (gitlab.com) | An application with Confidential off (a public client), scopes `api`, `read_user`, `read_repository` and `write_repository`, and the device authorization grant enabled. | `HISTQ_GITLAB_CLIENT_ID` (`HistqGitLabClientID`) |
| Bitbucket (bitbucket.org) | An OAuth client (Workspace settings › OAuth clients) with the grant types Authorization code and Refresh token, the callback URL `http://127.0.0.1:47823/callback`, and the scopes Account read, Workspace membership read, Repositories read and write, Pull requests read and write, Pipelines read. | `HISTQ_BITBUCKET_CLIENT_ID` (`HistqBitbucketClientID`), and the secret below |
| Azure DevOps (Microsoft Entra) | An app registration (Entra admin center › App registrations) with supported account types "Multiple Entra ID tenants", the platform Mobile and desktop applications with the redirect URI `http://localhost`, Authentication › Allow public client flows: Yes, no client secret, and the delegated API permission Azure DevOps › `user_impersonation` (users of another tenant need their admin's consent until the app is publisher verified). Personal Microsoft accounts can't sign in to Azure DevOps through Entra apps. | `HISTQ_AZURE_CLIENT_ID` (`HistqAzureClientID`) |

A GitLab Self-Managed account can use its own application (registered the same way on that instance): its Application
ID goes in the Add Account form and is kept with the account in the profile.

Only public client IDs are committed. Never commit a client secret.

Bitbucket requires its client secret for the token requests. It lives only in `Config/Secrets.xcconfig`, which is
gitignored and never committed (there is no placeholder in the repository either): create it yourself with one line,

```
HISTQ_BITBUCKET_CLIENT_SECRET = <the OAuth client's secret>
```

The tracked `Config/Base.xcconfig` (the app target's `configFiles`) includes it when it exists, and Info.plist gets it as
`HistqBitbucketClientSecret`. Without the file the value is empty and "Sign in with Bitbucket" is hidden; Bitbucket API
tokens still work. Do not paste the secret into chats, logs or issues, and check with `git status` that the file stays
untracked. `scripts/check-build-parity.sh` compares only whether the secret is set in both builds, never its value.
Once the file exists, `xcodebuild -showBuildSettings` (and Xcode's build log) prints the secret: pipe it through
`grep -v SECRET`, and never paste unfiltered build settings anywhere.

## Fixtures

`scripts/make-fixtures.sh build/qa/fx` builds deterministic git repositories for tests and QA, isolated from your git
config: `graph` (branches, merges, tags, stashes, a remote, a worktree, uncommitted changes), `graph-origin.git`,
`graph-wt`, `conflict` (a merge stopped on 3 conflicted files), `conflict-rebase`, `conflict-pr` (a clean `main` with
no local `feature`; `origin/feature` conflicts with `main` in 3 files, the stub's pull request #1),
`conflict-pr-origin.git` (its bare remote: `main`, `feature` and `refs/pull/1/head` = `feature`) and `expected/`.
`--big N` adds `big` (N commits); `--portable` skips `graph-wt`, for git older than 2.48. The script refuses `/`, your
home folder and any non-empty folder it did not create. Everything under `build/` is git-ignored.

Submodule QA uses `build/qa/view/make-submodules.sh <root>`, a maintainer script kept outside git in `build/qa/view/`
(not in `scripts/`). It builds `<root>/subs` (`build/qa/view/fx/subs` with `<root>` = `build/qa/view/fx`): six
submodules, one in each state (clean with a nested submodule, moved, dirty, on a branch, not initialized, never cloned),
the branches `sub/bump`, `ff/behind` and `ff/diverged`, and their bare sources `<root>/subs-*.git`. Its own git calls
allow `file://` submodules; Histq does not, so Initialize on `vendor/never` shows git's refusal.

## Benchmark

The graph benchmark parses and lays out 50,000 commits and must finish in under 2 seconds. It runs only when
`HISTQ_BIG_FIXTURE` points at a big fixture (an absolute path):

```sh
scripts/make-fixtures.sh build/qa/fx --big 50000
export HISTQ_BIG_FIXTURE="$PWD/build/qa/fx/big"
cd Packages/HistqCore && swift test -c release --filter GraphLayoutTests
```

## Reload benchmark

`scripts/perf-reload.sh <Histq.app> <repo> <cycles> [extra app args...]` measures how long the app takes to show a
new commit. It launches the app in the background (`open -g`, `-HistqBackground YES`, state in `build/qa/perf/state`,
wiped first), waits for the first full load, then per cycle edits a tracked file and commits it, and prints one row
for the WIP reload (`<k>w`) and one for the commit reload (`<k>`): M1 (`graph-reload` minus the watcher's `refresh`,
in ms), the counts of `log-start`, `log-again`, `graph-reload`, `branch-map-start` and cancelled branch maps, the
`log-reload` steps and the last `mem` line. A summary follows (M1 median and max, cycle 5 / median, peak memory after
the first load and at the end). It quits only the instance it started.

Use the Debug app or a measurement build (Release with `HISTQ_PERF`, which honours the state dir and writes the
timing logs), never the plain Release build (it ignores `-HistqBackground` and would come to front). The repo is a
disposable APFS clone of a big fixture, with a commit-graph and git maintenance off. After the runs, build plain
Release again so DerivedData does not keep the perf build:

```sh
scripts/make-fixtures.sh build/qa/bigfx --big 1000000
mkdir -p build/qa/perf && cp -cR build/qa/bigfx/big build/qa/perf/big-cg
git -C build/qa/perf/big-cg -c maintenance.auto=false -c gc.auto=0 commit-graph write --reachable
xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Release -skipPackagePluginValidation \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) HISTQ_PERF' build
# the app: <BUILT_PRODUCTS_DIR of -configuration Release -showBuildSettings>/Histq.app
scripts/perf-reload.sh <Histq.app> build/qa/perf/big-cg 5
xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Release -skipPackagePluginValidation build
```

The script refuses a repo outside `build/qa/perf/` or with uncommitted changes, and resets it to its starting tip at
the end (`git reset --hard`), so its test commits are dropped. They are dated after the fixture's tip (its commits are
dated up to 2027), a minute apart, with `maintenance.auto` and `gc.auto` off.

## UX latency benchmark

`scripts/perf-ux.sh` times what a click does: how soon the app shows a reaction, when the content is in, and which git
processes each click or operation runs. It reads the timing lines a Debug build or the measurement build writes to
`timing.log` in its state folder (`select`, `placeholder`, `content`, `op-click` / `op-start` / `op-end` /
`op-settled`, `op-feedback`, one `git <verb> <ms> <repo>` line per git process, `tab-shown`, `focus`, `tab-frame`,
`walk …`). Everything
lives under `build/qa/perf/ux/`: the fixtures in `fx` and `base`, a fresh APFS copy per run in `run` (removed after
the run), the logs in `results/<label>/`, the measurement app and its stamp in `app-perf`.

Set up the fixtures once (they are only read; each run works on its own copy):

```sh
scripts/make-fixtures.sh build/qa/perf/ux/fx --big 50000
mkdir -p build/qa/perf/ux/base && cp -cR build/qa/perf/ux/fx/big build/qa/perf/ux/base/big-cg
git -C build/qa/perf/ux/base/big-cg -c maintenance.auto=false -c gc.auto=0 commit-graph write --reachable
git clone -q . build/qa/perf/ux/base/self && git -C build/qa/perf/ux/base/self checkout -q --detach 399b9ee
```

Measure on the measurement build: Release with the DEBUG launch seams on the app target only (`HISTQ_SEAMS`, which no
package target reads), copied to `app-perf` and stamped with the source state it was built from. Scenario mode refuses
an app under `app-perf` whose stamp no longer matches `App`, `Packages` and `project.yml` (`scripts/perf-ux.sh
check-stamp` exits 1: build it again). After measuring, always build plain Release again, so DerivedData never keeps
the measurement build:

```sh
xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Release -skipPackagePluginValidation \
  HISTQ_SEAMS='HISTQ_PERF DEBUG' build
# the app: <BUILT_PRODUCTS_DIR of -configuration Release -showBuildSettings>/Histq.app
ditto <that Histq.app> build/qa/perf/ux/app-perf/Histq.app && scripts/perf-ux.sh stamp
scripts/perf-ux.sh "$PWD/build/qa/perf/ux/app-perf/Histq.app" all 3 baseline   # or one scenario
xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Release -skipPackagePluginValidation build
```

`scripts/perf-ux.sh <Histq.app> <scenario|all> [runs=3] [label] [-- <extra app args…>]` runs each scenario `runs`
times. A Debug app passed by path works too (smoke runs; not stamp-checked); never pass the plain Release build (it
ignores `-HistqBackground` and would come to front, so the script refuses a build without the launch seams). Each run
copies the fixture, sets the scenario's state with plain git, launches the app in the background (`open -g`,
`-HistqBackground YES`, its own state folder, `-HistqLayout classic`), waits for the scenario's end line and then 2 s
without a new line, quits only that instance, and copies `timing.log`, `refresh.log`, `operations.txt`, the load
average (`uptime`), the shared QA preferences (`com.math2it.histq.qa`; autoStash, pullMode and pruneOnFetch also go
to the `.meta` file) and the front app check to `results/<label>/<scenario>-<run>.*`; `results/<label>/HEAD` records
the commit and source stamp of each invocation. The script waits while any `xcodebuild` runs: no measurement during a
build. The machine is often busy: compare minimums over runs, taken at a 1-minute load average below 15.

Scenarios (27 in `all`, plus 2 checks):

- Reads: `sel-adjacent` (60 adjacent commits of `big-cg`, 300 ms apart, down and back), `sel-repeat` (120 at 30 ms,
  as a held arrow key), `sel-far` (40 commits 97 rows apart: cold), `sel-wip` (the WIP row between commits),
  `file-commit` (the 6 files of d8b266d in `self`, up to the 5520-line `RepoSession.swift`), `file-wip` (3 changed
  files; then the open file is changed from outside), `tabs` (tabs on `self`, `graph` and `big-cg`, 2 rounds; then
  `big-cg` is changed from outside while hidden, and tabs 1 and 2 are shown once more).
- Writes, on `graph` unless noted: `checkout-clean`, `checkout-dirty` (autostash), `checkout-big` (`big-cg`),
  `checkout-fail` (a change that conflicts with the target, autostash off: must fail), `commit` (through the WIP
  panel's commit box), `commit-fail` (a pre-commit hook that exits 1: must fail), `outside-edit` (`commit`, then a
  tracked file is changed from outside 1 s after the operation settled), `stash`, `stash-many` (300 changed files),
  `stash-pop`, `rebase`, `rebase-interactive`, `rebase-abort` (`conflict-rebase`), `fetch` (a new commit in the origin
  copy), `pull` (`feature`, behind 1), `push` (`develop`, ahead 1).
- Pull requests, on `conflict-pr` with the GitHub stub answering 300 ms late: `pr-open` (opens pull request #1
  twice), `pr-open-slow` (files 900 ms, checks 600 ms late), `pr-action` (merge), `pr-mergeable` (GitHub still
  computing mergeability: the first answer and 3 re-asks).
- Checks, not in `all` (name them): `tabs-ignored` and `tabs-tracked`, the `tabs` walk with `big-cg` on its WIP (one
  tracked file changed before launch). While it is hidden, a file that `info/exclude` ignores (`perf-ignored/out.txt`)
  or a tracked file is changed. The hidden tab asks `git check-ignore` about the changed files: an ignored file holds
  nothing and the tab comes back with its WIP as it was (no `placeholder` after its `select tab`); a tracked one holds
  the status, and the tab comes back on the WIP placeholder until the status is read. Their `proof` column fails by
  design (the WIP row was already there, so no graph line follows).

Each run prints one row: `<scenario> <run> | <end> | exercised: … | front app: unchanged (…) | <stats>`. `exercised`
says the operation really ran (a write's `op-click` and its `op-end`, `fail` for the two failing scenarios). Any other
front app is a warning: someone switched apps meanwhile, or the launch came to front. The stats, in ms from the click:

- Reads: `clicks` = timed selects; `F`, `content`, `settled` = min/median/max over the run's clicks of the first
  reaction (placeholder, info card, content or `tab-shown`), of the content of that selection and of the last line
  before the next click; `git/click` and `serial/click` = git processes per click and their serial time (the union of
  their intervals); `sig` = processes ended by a signal (a cancelled read); `spinner` when a load took long enough to
  show one; `frame-max` = the longest main-thread gap after a tab switch; `tail-same reread` = status, ref or log
  processes of a revisited tab whose repo did not change (0 is right); `walk` = the walk's wall time. A tab click's
  `content` is the `content commits <repo>` line of the repo its `tab-shown <i> <repo>` names, logged when a layout
  becomes shown (on revisits too, never for a graph that appears while its tab is hidden); a window without it has no
  `content` (older logs logged it on every rebuild, so their numbers still compare). A window keeps the last 4 shown
  tabs alive: switching back to one rebuilds nothing, so a revisit window has no `content sidebar` or
  `content overview`.
- `focus` (`tabs`, `tabs-ignored`, `tabs-tracked`): `pass` when each `select tab <i>` is followed, before the next
  click, by `tab-shown <i> <repo>` and exactly one `focus <repo> <kind>` naming that repo (`WindowModel.focusShownTab`
  logs it once per switch; `kind` is where the keyboard went: `search`, `diff`, `blame`, `graph` or `none`, the
  window itself); `fail(tab <i> at <t>: …)` names the first bad switch: no `tab-shown`, no focus line, a focus
  line of another repo, or more than one. A diff or blame table that takes the focus when it mounts in the shown tab
  logs `focus <repo> diff|blame` too, which counts as a second line in a switch window.
- Writes: `op <kind> ok|fail`, `F` (the first `op-feedback` and which one), `pre` (`op-start` − `op-click`), `end`,
  `settled`, `O1` = `end` minus the main git command (named in brackets: `checkout`, `commit`, `stash`, `rebase`,
  `fetch`, `fetch` + `merge` or `rebase` for a pull, `push`), `O2` = `op-settled` − `op-end`, `O3` = the first
  `graph-reload` after `op-end`, `git` = count / total / serial ms from the click on, `unacc` = `op-end` − `op-start`
  minus the serial git time inside it, `top` = the 3 costliest verbs (`<verb>*<count>:<ms>`).
- `proof` (`outside-edit`, `file-wip`, `tabs`): `pass(<ms>)` when the outside change was read: a watcher `refresh`, a
  `refresh-read` and a `git status` of that repo, then the graph's reload (the WIP row appeared) or, for `file-wip`, a
  new `file-load` of the open file; in `tabs` the hidden repo holds its refresh until it is shown, so after its
  `select tab`: a `git status` of that repo, a `refresh-read`, then `log-start` or `log-again synthetic` and the log's
  `graph-reload` (the switch's own `graph-reload` does not count); the second number is the time from the watcher's
  `refresh` line (in `tabs`, from the `select tab`), the first one from the edit is an upper bound (the edit is timed by
  the last log line before it, up to 1 s early in `outside-edit`); `fail(no …)` names what is missing.
- Pull requests: `action <name> ok ->reloaded` (from the action's answer to the reloaded page), `mergeable lines` and
  the gaps between the re-asks.

`scripts/perf-ux-stats.py build/qa/perf/ux/results/<label>` prints the tables over all runs of a label (min, median,
p90 and max per metric; reads split into first visits and revisits, files by size, tabs into first visits, revisits
and the two windows after the outside change, each with its git verbs per repo); `scripts/perf-ux-stats.py <scenario> <timing.log>…` does the same for
some logs, and `--row <scenario> <timing.log>` prints one run's row.

## Screenshots

`scripts/shot.sh <out.png> [--keep-state] [--wait <s>] [repo paths...] [-- app args...]` launches the Debug app (build
it first) and captures its window. Set `HISTQ_APP` to use a built `Histq.app` from elsewhere (a QA VM has no project).

```sh
scripts/shot.sh build/qa/shots/graph.png build/qa/fx/graph
scripts/shot.sh build/qa/shots/terminal.png build/qa/fx/graph -- -HistqOpenTerminal YES
# Resolve a conflicting pull request: manually, then (after rebuilding the fixtures) with AI.
scripts/shot.sh build/qa/shots/pr-resolve.png --wait 10 build/qa/fx/conflict-pr -- -HistqGitHubStub YES \
  -HistqSelect pr:1 -HistqPRMergeable false -HistqPRAction resolve-manual
scripts/shot.sh build/qa/shots/pr-resolve-ai.png --wait 10 build/qa/fx/conflict-pr -- -HistqGitHubStub YES \
  -HistqSelect pr:1 -HistqPRMergeable false -HistqAIStub YES -HistqKeychain memory -HistqAI pr-resolve-ai
```

A Resolve run leaves `conflict-pr` on `feature` in the middle of a merge: run `scripts/make-fixtures.sh build/qa/fx`
again before the next one.

- **Background only**: `open -g` and `-HistqBackground YES`, so the app never activates and its window is never key.
  Shots show an inactive window (grey traffic lights).
- **Isolated state**: every run passes `-HistqStateDir build/qa/state`; the folder and the QA preferences suite
  (`com.math2it.histq.qa`) are wiped first unless you pass `--keep-state`.
- It waits for the window, then `--wait` seconds (default 1.5), and captures it with `screencapture -l` (the Terminal
  needs the Screen Recording permission). It quits only the instance it started.

## Timing logs

The click-first rule (a click selects at once, the detail shows a placeholder, then its content) is checked with
timings. In a state-dir run, Debug builds append `<ms since launch> <event> <detail>` lines to
`build/qa/state/timing.log` (watcher refreshes go to `refresh.log`). Events:

- `open`, `select`, `placeholder`, `spinner` (only when a load takes over about 150 ms) and `content` (for every
  select; `content log-complete <n>` when the whole history is laid out; `content branch-map <commits> <ms>` when the
  faded branch labels are computed, `content branch-map cancelled <ms>` when a newer one replaced them; `content
  log-reload incremental <new commits> <ms> env=<ms> stashes=<ms> tips=<ms> delta=<ms> concat=<ms> index=<ms>
  layout=<ms>` (the read's steps, the status's wait counted in `env`) or `content log-reload full <ms>` when a change
  reloads the log).
- Log reloads: `log-start <generation> incremental|full` when a log load starts; `log-again synthetic|worktree` when a
  finished load starts another load or a worktree-row layout; `log-publish <ms>` for the main-actor work after a load;
  `branch-map-start <log generation>` when a branch attribution starts; `refresh-read <ms>` when a refresh has read
  the status and refs; `graph-reload <generation> <ms>` when the graph table reloads for a new generation; `mem
  footprint=<MB> peak=<MB>` after every `log-complete`.
- `file-load <path> env=<ms> size=<ms> diff=<ms> rows=<ms>`: the steps of a commit file's diff read (a click, or the
  prefetch of a file history's neighbouring rows).
- `content-info` (a commit's info card is on screen; its files may still load) and `layout <detail> <state>
  filesTop=<y> filesBottom=<y> panelBottom=<y>` (the Files card edges, for `placeholder`, `pending` or `loaded`).
- `find <query> matches=<m> current=<n> commit=<sha>` (Cmd-F search), `graph-col` (the graph column fitted to its
  lanes), `columns`, `toolbar`, `click`, `dblclick`, `zoom` and `walk` (from the DEBUG arguments below).

Read the file right after a `scripts/shot.sh` run (which wipes the state dir first): each `select` line must have a
`placeholder` line, or for a commit of the log a `content-info` line, then a `content` line. Over a
`-HistqSelectWalk` in a Debug build, `content-info` comes a median of at most 16 ms after `select` (p95 at most 33 ms),
a commit selected again (or prefetched) shows its `content` with a p95 of at most 33 ms, and a commit of the log never
logs `placeholder` or `spinner`. A commit with many files can take two frames in Debug; Release is faster.

## DEBUG launch arguments

Debug builds read these; Release ignores them. With `scripts/shot.sh`, put them after `--`. Always pass
`-HistqStateDir`: Debug and Release share the bundle id `com.math2it.histq`, so a run would otherwise use your real
state. Outcomes go to `timing.log` or `operations.txt` in the state dir. Exact behavior: `grep -rn '"-Histq' App`.

| Argument | What it does |
| --- | --- |
| `-HistqStateDir <dir>` | Keeps files, logs and session state in `<dir>`; uses the QA preferences suite and Keychain service. |
| `-HistqBackground YES` | Never activates the app; windows stay behind others and are never key. |
| `-HistqSelect <kind>[:<value>]` | Selects at launch through the click path: `tab:<n>`, `wip`, `commit:<sha>`, `commits:<sha>,<sha\|wip>` (full shas), `branch:<name>`, `file:<path>`, `conflict:<path>`, `edit:<path>` (the WIP file in the editor's Edit tab), `commitfile:<sha>:<path>`, `settings:<section>`, `sidebar:<tab>`, `pr:<n>`, `issue:<n>`, `prbadge:<branch>`, `submodule:<path>` (a Submodules card row). |
| `-HistqSelectWalk <n>[,<ms>]` | Selects the first n commits `ms` apart (default 250), walks back up, then logs `walk done`. |
| `-HistqHistoryWalk <n>[,<ms>]` | With `-HistqSelect history:<path>`: clicks the first n history rows `ms` apart (default 250), walks back up, then logs `walk done`. |
| `-HistqSelectAfter <path>` | Then selects that WIP file (with or without `-HistqResolve`), to drive the conflict editor's leave prompt. |
| `-HistqWindowSize <w>x<h>` / `-HistqTabbedWindows <n>` | Size of new windows; spreads the repositories over n native-tab windows. |
| `-HistqTabPosition left\|top` / `-HistqAvatarMode real\|generated\|initials` / `-HistqLayout classic\|stacked\|columns\|focus` | Overrides the preference. |
| `-HistqGraphWidth <pt>` / `-HistqRefColumnWidth <pt>` | Graph column width as a border drag would set it (logs `graph-col`); Branch / Tag column width. |
| `-HistqDensityAfter <density>` | Switches the row density about 2 s after launch, as the Settings picker does (logs `graph-cells`). |
| `-HistqColumnDrag <column>:<dx>` | Drags the border right of `message` or `author` by dx points; logs `columns`. |
| `-HistqFind "<query>[;next\|prev...]"` / `-HistqFindEarly YES` | Opens the Cmd-F search, types the query, runs each step; `FindEarly` starts on the log's first page. |
| `-HistqDoubleClick toolbar\|toolbargap\|tabrow` | Double-clicks that window row; logs `click`, `dblclick` and `zoom`. |
| `-HistqToolbarFrames YES` | Logs the repo and branch dropdowns' frames (`toolbar`). |
| `-HistqOpenPalette "<query>"` / `-HistqPaletteRun` | Opens the command palette with that query; runs its first row. |
| `-HistqFileSearch "<query>"` | Types that query in the File History…, Blame… or Edit File… modal when it opens (`-HistqOpenPalette "File History" -HistqPaletteRun`). |
| `-HistqFileSearchPick YES` | With `-HistqFileSearch`, picks the first ranked row once the files are read, as Return does; logs `filesearch pick <path>` to `operations.txt`, or `filesearch pick: no row for <query>`. |
| `-HistqOpenTerminal YES` | Opens the terminal drawer with each repository tab and starts its shell. |
| `-HistqShowHidden YES` | The Local, Remote and Tags cards list their hidden rows (dimmed), as their header's eye button does. |
| `-HistqSaveWorkspace <path>` | Once the launch's windows are open, Save Workspace As… to `<path>` from the front window, without a panel. |
| `-HistqCloseWorkspace <name>` | Once the launch's windows are open, Close Workspace on the open workspace with that name. |
| `-HistqMoveTab <from>:<tab>:<to>` | Once the launch's windows are restored and the profiles read, Move Tab to Window: tab `<tab>` (offset in that window's tabs) of window `<from>` to window `<to>` (window offsets in the app's window list: after a restore, the Untitled windows first, then each workspace's), without selecting it first. `operations.txt` gets `move-tab <spec>: moved`, `refused <reason>` or `bad indices`. |
| `-HistqImportProfiles YES` | When a workspace opens with the offer to import its missing profiles, presses Import about 1 s after the sheet shows. |
| `-HistqTerminalProbe <repo>` / `-HistqTerminalSettingsProbe <spec>` | Probes a repo's terminal (its shell, identity and environment) or the Settings › Terminal preferences. |
| `-HistqHTMLProbe YES` | Snapshots every GitHub HTML view (`html-<n>.png`) and logs its size. |
| `-HistqSlotProbe YES` | Outlines the pull request and issue pages' overlay slots in red and logs `slot-probe <id> html <x,y,w,h> overlay <x,y,w,h> delta <d>` after each measurement; 3 s after the first, the window widens by 400 pt for a pass at another width. Stub only. |
| `-HistqScrollProbe YES` | Wheels 120 px over the first GitHub page, then over an avatar and the first reply row (when the page has one), logging `scroll-probe outer <before>-><after>` for each, then scrolls the column to its end. Not with `-HistqHTMLProbe`. Stub only. |
| `-HistqKeychain memory` / `-HistqKeychainSelfTest memory\|login` | In-memory Keychain; a Keychain round trip to `keychain-selftest.txt`. |
| `-HistqRun "<menu>\|<item>[;;<next>...]"` | Runs context-menu items by title, accepting confirmations. Menus include `local:<name>`, `remote:<name>`, `tag:<name>` (`tag:v1.0\|Hide`), `badge:<local\|remote\|tag>:<name>` (a graph badge's menu), `wipfile:<path>` (a WIP file's Stash Changes, Edit File (`wipfile:<path>\|Edit File`) and, when untracked, its Ignore entries: `wipfile:<path>\|Ignore <name>`, `wipfile:<path>\|Exclude Locally\|Ignore <name>`), `stashfile:<sha>:<path>` (a tracked file of a stash, full sha), `repo` (the toolbar repo menu's repository actions: `repo\|Optimize Repository…`, `repo\|Show Reflog`), `reflog:<sha>` (a reflog entry's menu, full sha), `submodule:<path>` (a submodule row's menu: `submodule:vendor/moved\|Update`) and `submodules` (the Submodules card's menu: `submodules\|Update All`); a submodule root waits for the submodule list. Fixture copies only. |
| `-HistqShow "<menu>\|<item>"` / `-HistqFormName "<name>"` | Opens one item's confirmation or form; fills and submits the form. |
| `-HistqWorktreeFolder "<parent>"` | With `-HistqFormName`, fills and submits the Add Worktree form. |
| `-HistqCommit "<message>"` | Commits the staged changes through the WIP panel. |
| `-HistqStageLines <n>,<m>` | Selects those changed lines in the first stageable diff. |
| `-HistqResolve A1,B2,AB3[,<step>]` | Ticks sides of conflicts 1, 2, 3...; steps: `save`, `save-output`, `save-chunks`, `reset`, `keep`, `delete`, `leave-save`, `leave-save-output`, `dontsave`, `cancel`. |
| `-HistqEditorRun "<step>[;;<step>...]"` | With `-HistqSelect edit:<path>`: once the editor shows its text, runs each step and logs its outcome to `operations.txt`: `append:<text>` (typed at the end through the text view; `\n` is a newline), `save` (`saved`, `blocked` or `failed`), `leave:<path>` (selects that WIP file: `prompt` or `no-prompt`), `answer:save\|discard\|cancel` (the leave prompt's button; then `answer <x>: open=<path> …`), `wait-file:<name>` (`waiting <name>`, then `go <name>` once `<name>` exists in the state dir, or `timeout` after 10 s: make the outside change, then `touch` it), `reload` / `keepmine` (the disk notice's buttons: `reloaded`; `saved`, `failed` or `skipped` without a change on disk), `wait-refresh` (a status refresh and its disk check, 10 s at most: `reloaded`, `diskChange modified`, `diskChange deleted`, `unchanged` or `timeout`) and `state` (after 500 ms: `editor open <path> shows=<edit\|diff> dirty=<yes\|no>` or `editor closed`); then `done`. Fixture copies only. |
| `-HistqOperation continue\|abort\|skip` | Presses the operation banner's button. |
| `-HistqOpenRebase <rev>` / `-HistqOpenSquash "<rev>,<rev>"` / `-HistqStartRebase` | Opens the interactive rebase or squash sheet; starts it. |
| `-HistqRewordRow <n>` | With `-HistqOpenRebase`, switches row n (1-based) to Reword once the sheet has loaded. |
| `-HistqEditMessage open\|save:<summary>` | With `-HistqSelect commit:<sha>`, presses the commit card's Edit button once (HEAD: the inline editor; an older commit: the rebase sheet with that row on Reword); `save:` also sets the summary and presses Update Message. |
| `-HistqUndo <n>` / `-HistqRedo <n>` / `-HistqLogUndo` | Runs n undos, then n redos; logs the Undo button's state. |
| `-HistqFakeUpdate` | Shows the toolbar's Update button (version 9.9.9) without Sparkle; a click does nothing. |
| `-HistqSparkle` | Starts Sparkle in a Debug build (off by default: Debug and Release share the bundle id, so a Debug build would download the release). Not with `-HistqStateDir` or `-HistqBackground YES`, which keep it off. |
| `-HistqOnboarding off\|auto\|<step>\|tour\|tour:<stop>` | How the onboarding starts at launch: `off` never shows it, `auto` evaluates the real first-run gate even in state-dir mode, `<step>` opens the card on that step (`welcome`, `git`, `profile`, `github`, `clone` (shown only when GitHub is connected; otherwise the next step opens), `ai`, `tabPosition`, `layout`, `avatars`, `rowHeight`, `laneColors`, `fadeWorktrees`, `tour`, `finish`), `tour` opens the tour at its first stop and `tour:<stop>` at that stop; an unknown value is ignored. The onboarding never shows by itself in a launch with `-HistqStateDir` (except with `auto`) or with repo paths. |
| `-HistqSpotlight <target>` | Shows the onboarding's spotlight over every window on one target (`sync`, `repoMenu`, `branchMenu`, `profile`, `workspaceMenu`, `history`, `branchActions`, `terminal`, `search`, or a content target such as `graph`), with a sample popover and without the onboarding: the rest of the window is dimmed, the toolbar dims its other items and blocks clicks. Return or Esc ends it. A toolbar target without a view (before macOS 26, or with `--force-fallbacks`) anchors the popover to the toolbar band, no ring. |
| `-HistqGitHubStub YES` / `-HistqGitHubFakeLogin <login>` | Canned pull request and issue data, without GitHub; a fake connected account (with `-HistqKeychain memory`). |
| `-HistqHostingStubKind gitlab` | With `-HistqGitHubStub YES`: the PRs tab and the details get the same canned data in GitLab's shapes through the GitLab client (`stub/stub` on gitlab.com: merge request !1, issue #2), so the GitLab wording and mapping show without GitLab. `-HistqPRAction` and `-HistqPRMergeable` work with it. Stub only. |
| `-HistqHostingStubKind bitbucket` | With `-HistqGitHubStub YES`: the PRs tab and the details get Bitbucket's 2.0 shapes through the Bitbucket client (`stub/stub` on bitbucket.org: pull request #1 from the same repository, #2 from a fork, whose Checkout Locally is unavailable). Reads only: actions answer 404. Stub only. |
| `-HistqGitHubFakeTokens YES` | With `-HistqKeychain memory`: a fake token for every account of every profile in `profiles.json`, on its own host, so Settings › Integrations shows each one connected. |
| `-HistqDisconnectHost <host>` | With `-HistqGitHubFakeTokens YES`: then disconnects the accounts on `<host>` as Disconnect does. |
| `-HistqAIStubAnswer <file.json>` | With `-HistqAIStub YES`: every AI answer is `{"answer": "…", "reason": "…"}` from the file (reason optional) instead of the canned text; for website screenshots. |
| `-HistqPRTab commits\|files\|checks` | The tab a pull request opens on. |
| `-HistqPRAction <action>` / `-HistqIssueAction <action>` | Runs a pull request or issue action once, without confirmation. `-HistqPRAction reply` posts "QA reply" to the first review thread, `resolve` resolves the first unresolved thread and `unresolve` unresolves the first resolved one. `resolve-manual` clicks Resolve manually in the merge box of a pull request with conflicts (needs `-HistqPRMergeable false`) once it can start, and logs `content resolve pr <n> manual stopped <N>\|clean\|failed\|refused <reason>` in `timing.log` (`refused busy\|in-progress\|dirty` when another operation, a stopped one or uncommitted changes showed up after the click; `refused diverged` when the local head branch has commits that `<remote>/<head>` lacks; one only behind is fast-forwarded first). Stub only. |
| `-HistqPRMergeable true\|false\|null` | Whether the stub's PR #1 merges: `true` (default, `clean`), `false` (conflicts, `dirty`) or `null` (GitHub still checking, `unknown`; the detail asks again up to 3 times, 3 s apart, and logs `pr 1 mergeable <value>` in `timing.log` for each answer). Stub only. |
| `-HistqPRStubComments <n>` | The stub's PR #1 gets n generated comments (up to 600, a minute apart, every third with a long line of code) instead of one, for a conversation longer than the panel. Stub only. |
| `-HistqOpenCreatePR <branch>` / `-HistqCreatePRSubmit YES` | Opens the Create Pull Request form; fills and submits it. Stub only. |
| `-HistqGenerateKey` | Opens Generate Key in Settings › SSH. |
| `-HistqAIStub YES\|error` | Answers AI requests locally (or with HTTP 401), never reaching the network; logs each request's data block labels as `blocks [<label>, ...]` in `ai.log` (labels only, never content). |
| `-HistqAI <hook>[,amend][,apply\|,cancel][,regenerate][,undo][,close-tab\|,close-window]` | Clicks one AI button: `generate`, `explain-wip`, `explain`, `resolve`, `resolve-all`, `improve-message`, `pr-describe`, `pr-resolve-ai`, `test`, `load-models` or `save-key`. `save-key` (with `-HistqKeychain memory`) removes the active provider's key, saves the fake one through Save and logs `key saved <provider>` or `key not saved <provider>: <why>` in `ai.log`. `improve-message` clicks Improve on the reword row (see `-HistqRewordRow`). `pr-describe` clicks Generate in the Create Pull Request form (needs `-HistqOpenCreatePR` and `-HistqGitHubStub YES`). `pr-resolve-ai` clicks Resolve with AI in the merge box of a pull request with conflicts (needs `-HistqGitHubStub YES`, `-HistqSelect pr:1` and `-HistqPRMergeable false`): `timing.log` gets `content resolve pr <n> ai stopped <N>`, then `select ai resolve-all` as Suggest All starts in the first conflicted file that both sides still have (UU or AA), and `ai.log` gets `batch finished ok=<n> failed=<m>`. `generate,amend` turns Amend on and clicks Generate Message once the last message has loaded. `regenerate` clicks Regenerate once after the first answer and logs `regenerate` in `ai.log`. `resolve-all` (Suggest All) logs `batch finished ok=<n> failed=<m>` once the batch ends; with `apply` it clicks Apply N and logs `apply-batch regions [...]`, and `undo` then does Undo AI and logs `unresolved <a>-><b>`. `close-tab` (another tab must stay open) or `close-window` closes the card's tab or window as soon as the card opens, while the job still reads its content (`resolve-all`: while the batch runs), as Cmd-W would, and logs a `close-tab …` or `close-window …` line; no stub request may follow. When AI is set up but the named hook's button is unavailable, `ai.log` gets `unavailable <hook>: <reason>` once per reason. Each single-card `apply` also logs `form-open <logName> <true\|false>` (whether the rebase or pull request form is still shown). `explain` and `explain-wip` open in the tab's AI chat: there `cancel` stops the turn as soon as the first words show and logs `cancel <logName> after reply chars <n>`, and `close-tab` / `close-window` close right after the click (before the context is sent) and log `close-tab chat <hook> …` / `close-window chat <hook> …`; each chat turn logs `chat finished ai <logName> chars <n>` (or `chat failed …`). Stub only. |
| `-HistqAIChatSend "<text>"` | With `-HistqAIStub YES`: once the first chat answer finishes, puts `text` in the chat's draft and sends it (once per launch); `ai.log` gets `chat-send "<text>"` and `timing.log` `select ai chat-send` then `content ai chat-send`. |

Workspace QA (background, own state dir): make two or three `git init` repos with a commit next to a folder, open them
as Untitled tabs, then relaunch with `-HistqSaveWorkspace <folder>/w.histqws`. The file is mode `600` with
relative tab `path`s, and `session.json` lists it under `workspaces` with `open: true` and no Untitled window. Kill and
relaunch: the file's `shasum` stays the same (opening never rewrites it). `-HistqCloseWorkspace w` stores its layout with
`open: false`. A tab whose profile id is not in the state's `profiles.json` refuses `-HistqCommit` (`fail commit` in
`operations.txt`); `-HistqImportProfiles YES` accepts the import sheet. `kill` skips quit-time writes, so ⌘Q checks are
manual.

## Project layout

- `App/`: the macOS app (SwiftUI and AppKit, UI only). `App/GlassStyle.swift` holds the design tokens.
- `Packages/HistqCore/`: a Foundation-only package with everything that is not UI (git, parsing, graph layout, diffs,
  three-way merge, profiles, the GitHub and AI clients), tested in `Packages/HistqCore/Tests/HistqCoreTests`.
- `scripts/`: `make-fixtures.sh`, `shot.sh`, `check-build-parity.sh` and the release scripts.
- `assets/`: the logo artwork. `build/` and `docs/` are git-ignored.

## Commit style

One-line conventional commits: `<type>(<scope>): <summary>`, for example `fix(graph): keep the selection on refresh`.
Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`. No body.

## Update feed

- **Feed:** `SUFeedURL` is `https://histq.coprimal.dev/appcast.xml`, served by GitHub Pages through `.github/workflows/pages.yml` (Settings > Pages > Source = "GitHub Actions") and a Cloudflare CNAME `histq` → `coprimal.github.io` (DNS only). Its source is the root `appcast.xml` on `main`; the workflow deploys it with `website/` on every push that changes either.
- **Old address:** `histq.dinhanhthi.com` (the site's first host) answers with a 301 to the same path on `histq.coprimal.dev`, through a Cloudflare redirect rule and a proxied `histq` record in the `dinhanhthi.com` zone. Keep both.
- **Never:** move or rename the root `appcast.xml`, change the Pages source, remove the custom domain, or create or fork a repo named `dinhanhthi/Histq` (it would take over the old GitHub redirects).
- **Website re-render:** the site generator (`render.py`) rewrites `.github/workflows/pages.yml` from its template, which has no appcast lines while the site's version source is `github`. After a re-render, put back the `appcast.xml` path trigger and the `cp appcast.xml _site/appcast.xml` step (`git diff .github/workflows/pages.yml`), or the next deploy drops the feed.
- **Feed check:** `curl -sI https://histq.coprimal.dev/appcast.xml` shows HTTP 200 without `location`, and `curl -s https://histq.coprimal.dev/appcast.xml | cmp - appcast.xml` prints nothing.

## Releasing

Releases are maintainer-only: built, signed, notarized and published from the maintainer's Mac with `scripts/`.

## License

By contributing, you agree that your contributions are licensed under the [GNU GPL v3.0](LICENSE).

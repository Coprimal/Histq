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

## Fixtures

`scripts/make-fixtures.sh build/qa/fx` builds deterministic git repositories for tests and QA, isolated from your git
config: `graph` (branches, merges, tags, stashes, a remote, a worktree, uncommitted changes), `graph-origin.git`,
`graph-wt`, `conflict` (a merge stopped on 3 conflicted files), `conflict-rebase` and `expected/`. `--big N` adds
`big` (N commits); `--portable` skips `graph-wt`, for git older than 2.48. The script refuses `/`, your home folder
and any non-empty folder it did not create. Everything under `build/` is git-ignored.

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

## Screenshots

`scripts/shot.sh <out.png> [--keep-state] [--wait <s>] [repo paths...] [-- app args...]` launches the Debug app (build
it first) and captures its window. Set `HISTQ_APP` to use a built `Histq.app` from elsewhere (a QA VM has no project).

```sh
scripts/shot.sh build/qa/shots/graph.png build/qa/fx/graph
scripts/shot.sh build/qa/shots/terminal.png build/qa/fx/graph -- -HistqOpenTerminal YES
```

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
| `-HistqSelect <kind>[:<value>]` | Selects at launch through the click path: `tab:<n>`, `wip`, `commit:<sha>`, `commits:<sha>,<sha\|wip>` (full shas), `branch:<name>`, `file:<path>`, `conflict:<path>`, `commitfile:<sha>:<path>`, `settings:<section>`, `sidebar:<tab>`, `pr:<n>`, `issue:<n>`, `prbadge:<branch>`. |
| `-HistqSelectWalk <n>[,<ms>]` | Selects the first n commits `ms` apart (default 250), walks back up, then logs `walk done`. |
| `-HistqSelectAfter <path>` | Then selects that WIP file (with or without `-HistqResolve`), to drive the conflict editor's leave prompt. |
| `-HistqWindowSize <w>x<h>` / `-HistqTabbedWindows <n>` | Size of new windows; spreads the repositories over n native-tab windows. |
| `-HistqTabPosition left\|top` / `-HistqAvatarMode real\|generated\|initials` / `-HistqLayout classic\|stacked\|focus` | Overrides the preference. |
| `-HistqGraphWidth <pt>` / `-HistqRefColumnWidth <pt>` | Graph column width as a border drag would set it (logs `graph-col`); Branch / Tag column width. |
| `-HistqDensityAfter <density>` | Switches the row density about 2 s after launch, as the Settings picker does (logs `graph-cells`). |
| `-HistqColumnDrag <column>:<dx>` | Drags the border right of `message` or `author` by dx points; logs `columns`. |
| `-HistqFind "<query>[;next\|prev...]"` / `-HistqFindEarly YES` | Opens the Cmd-F search, types the query, runs each step; `FindEarly` starts on the log's first page. |
| `-HistqDoubleClick toolbar\|toolbargap\|tabrow` | Double-clicks that window row; logs `click`, `dblclick` and `zoom`. |
| `-HistqToolbarFrames YES` | Logs the repo and branch dropdowns' frames (`toolbar`). |
| `-HistqOpenPalette "<query>"` / `-HistqPaletteRun` | Opens the command palette with that query; runs its first row. |
| `-HistqOpenTerminal YES` | Opens the terminal drawer with each repository tab and starts its shell. |
| `-HistqShowHidden YES` | The Local, Remote and Tags cards list their hidden rows (dimmed), as their header's eye button does. |
| `-HistqTerminalProbe <repo>` / `-HistqTerminalSettingsProbe <spec>` | Probes a repo's terminal (its shell, identity and environment) or the Settings › Terminal preferences. |
| `-HistqHTMLProbe YES` | Snapshots every GitHub HTML view (`html-<n>.png`) and logs its size. |
| `-HistqSlotProbe YES` | Outlines the pull request and issue pages' overlay slots in red and logs `slot-probe <id> html <x,y,w,h> overlay <x,y,w,h> delta <d>` after each measurement; 3 s after the first, the window widens by 400 pt for a pass at another width. Stub only. |
| `-HistqScrollProbe YES` | Wheels 120 px over the first GitHub page, then over an avatar and the first reply row (when the page has one), logging `scroll-probe outer <before>-><after>` for each, then scrolls the column to its end. Not with `-HistqHTMLProbe`. Stub only. |
| `-HistqKeychain memory` / `-HistqKeychainSelfTest memory\|login` | In-memory Keychain; a Keychain round trip to `keychain-selftest.txt`. |
| `-HistqRun "<menu>\|<item>[;;<next>...]"` | Runs context-menu items by title, accepting confirmations. Menus include `local:<name>`, `remote:<name>`, `tag:<name>` (`tag:v1.0\|Hide`), `badge:<local\|remote\|tag>:<name>` (a graph badge's menu), `wipfile:<path>` (a WIP file's Stash Changes and, when untracked, its Ignore entries: `wipfile:<path>\|Ignore <name>`, `wipfile:<path>\|Exclude Locally\|Ignore <name>`), `stashfile:<sha>:<path>` (a tracked file of a stash, full sha), `repo` (the toolbar repo menu's repository actions: `repo\|Optimize Repository…`, `repo\|Show Reflog`) and `reflog:<sha>` (a reflog entry's menu, full sha). Fixture copies only. |
| `-HistqShow "<menu>\|<item>"` / `-HistqFormName "<name>"` | Opens one item's confirmation or form; fills and submits the form. |
| `-HistqWorktreeFolder "<parent>"` | With `-HistqFormName`, fills and submits the Add Worktree form. |
| `-HistqCommit "<message>"` | Commits the staged changes through the WIP panel. |
| `-HistqStageLines <n>,<m>` | Selects those changed lines in the first stageable diff. |
| `-HistqResolve A1,B2,AB3[,<step>]` | Ticks sides of conflicts 1, 2, 3...; steps: `save`, `save-output`, `save-chunks`, `reset`, `keep`, `delete`, `leave-save`, `leave-save-output`, `dontsave`, `cancel`. |
| `-HistqOperation continue\|abort\|skip` | Presses the operation banner's button. |
| `-HistqOpenRebase <rev>` / `-HistqOpenSquash "<rev>,<rev>"` / `-HistqStartRebase` | Opens the interactive rebase or squash sheet; starts it. |
| `-HistqRewordRow <n>` | With `-HistqOpenRebase`, switches row n (1-based) to Reword once the sheet has loaded. |
| `-HistqUndo <n>` / `-HistqRedo <n>` / `-HistqLogUndo` | Runs n undos, then n redos; logs the Undo button's state. |
| `-HistqGitHubStub YES` / `-HistqGitHubFakeLogin <login>` | Canned pull request and issue data, without GitHub; a fake connected account (with `-HistqKeychain memory`). |
| `-HistqPRTab commits\|files\|checks` | The tab a pull request opens on. |
| `-HistqPRAction <action>` / `-HistqIssueAction <action>` | Runs a pull request or issue action once, without confirmation. `-HistqPRAction reply` posts "QA reply" to the first review thread, `resolve` resolves the first unresolved thread and `unresolve` unresolves the first resolved one. Stub only. |
| `-HistqPRMergeable true\|false\|null` | Whether the stub's PR #1 merges: `true` (default, `clean`), `false` (conflicts, `dirty`) or `null` (GitHub still checking, `unknown`; the detail asks again up to 3 times, 3 s apart, and logs `pr 1 mergeable <value>` in `timing.log` for each answer). Stub only. |
| `-HistqPRStubComments <n>` | The stub's PR #1 gets n generated comments (up to 600, a minute apart, every third with a long line of code) instead of one, for a conversation longer than the panel. Stub only. |
| `-HistqOpenCreatePR <branch>` / `-HistqCreatePRSubmit YES` | Opens the Create Pull Request form; fills and submits it. Stub only. |
| `-HistqGenerateKey` | Opens Generate Key in Settings › SSH. |
| `-HistqAIStub YES\|error` | Answers AI requests locally (or with HTTP 401), never reaching the network; logs each request's data block labels as `blocks [<label>, ...]` in `ai.log` (labels only, never content). |
| `-HistqAI <hook>[,amend][,apply\|,cancel][,regenerate][,undo][,close-tab\|,close-window]` | Clicks one AI button: `generate`, `explain-wip`, `explain`, `resolve`, `resolve-all`, `improve-message`, `pr-describe`, `test` or `load-models`. `improve-message` clicks Improve on the reword row (see `-HistqRewordRow`). `pr-describe` clicks Generate in the Create Pull Request form (needs `-HistqOpenCreatePR` and `-HistqGitHubStub YES`). `generate,amend` turns Amend on and clicks Generate Message once the last message has loaded. `regenerate` clicks Regenerate once after the first answer and logs `regenerate` in `ai.log`. `resolve-all` (Suggest All) logs `batch finished ok=<n> failed=<m>` once the batch ends; with `apply` it clicks Apply N and logs `apply-batch regions [...]`, and `undo` then does Undo AI and logs `unresolved <a>-><b>`. `close-tab` (another tab must stay open) or `close-window` closes the card's tab or window as soon as the card opens, while the job still reads its content (`resolve-all`: while the batch runs), as Cmd-W would, and logs a `close-tab …` or `close-window …` line; no stub request may follow. When AI is set up but the named hook's button is unavailable, `ai.log` gets `unavailable <hook>: <reason>` once per reason. Each single-card `apply` also logs `form-open <logName> <true\|false>` (whether the rebase or pull request form is still shown). Stub only. |

## Project layout

- `App/`: the macOS app (SwiftUI and AppKit, UI only). `App/GlassStyle.swift` holds the design tokens.
- `Packages/HistqCore/`: a Foundation-only package with everything that is not UI (git, parsing, graph layout, diffs,
  three-way merge, profiles, the GitHub and AI clients), tested in `Packages/HistqCore/Tests/HistqCoreTests`.
- `scripts/`: `make-fixtures.sh`, `shot.sh`, `check-build-parity.sh` and the release scripts.
- `assets/`: the logo artwork. `build/` and `docs/` are git-ignored.

## Commit style

One-line conventional commits: `<type>(<scope>): <summary>`, for example `fix(graph): keep the selection on refresh`.
Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`. No body.

## Releasing

Releases are maintainer-only: built, signed, notarized and published from the maintainer's Mac with `scripts/`.

## License

By contributing, you agree that your contributions are licensed under the [GNU GPL v3.0](LICENSE).

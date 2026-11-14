# Contributing to Histq

## Setup

You need Xcode 27 (the version `project.yml` names; the app compiles macOS 26 APIs behind availability checks), git
2.36 or later, and XcodeGen. The Xcode project is generated
from `project.yml` and is not in the repository.

```sh
brew install xcodegen
xcodegen generate
open Histq.xcodeproj
```

Run `xcodegen generate` again after you change `project.yml` or add, move or delete a source file.

## Build and test

Core tests (the `HistqCore` package, Swift Testing), from the repository root:

```sh
cd Packages/HistqCore && swift test
```

App build (Debug), from the repository root:

```sh
xcodegen generate && xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Debug -skipPackagePluginValidation build
```

`-skipPackagePluginValidation` is needed because the terminal uses SwiftTerm, whose package has a build-tool plugin.
Xcode asks you once to trust a package plugin; `xcodebuild` cannot ask, so without the flag the build fails on plugin
validation. Pass it to every `xcodebuild` call on this project, including `-showBuildSettings`.

Never pass `-derivedDataPath` to a local `xcodebuild`: the default DerivedData folder is the one Xcode uses, so a
command-line build and Cmd-R in Xcode share one cache instead of building twice.

**Signing**: Debug is signed with Developer ID like Release (team in `project.yml`), so Keychain items (the GitHub
token, AI keys) and macOS grants survive rebuilds and are shared with the installed app. Without that certificate, add
these overrides to every `xcodebuild` build:

```sh
CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=
```

An ad hoc build is signed differently on every rebuild, so macOS asks again for access to Keychain items and for its
grants.

To check that Debug and Release still sign alike (identity, team, hardened runtime, entitlements without the Debug-only
keys, designated requirements both ways, and the Info.plist keys), build both and run
`scripts/check-build-parity.sh`, which prints `PARITY OK` or each mismatch:

```sh
xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Debug -skipPackagePluginValidation build
xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Release -skipPackagePluginValidation build
D="$(xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Debug -skipPackagePluginValidation -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)/Histq.app"
R="$(xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Release -skipPackagePluginValidation -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)/Histq.app"
scripts/check-build-parity.sh "$D" "$R"
```

A local Release build is not the notarized export that ships; the release flow checks the export itself.

## Fixtures

`scripts/make-fixtures.sh` builds deterministic git repositories for tests and QA, isolated from your own git config:

```sh
scripts/make-fixtures.sh build/qa/fx
```

It creates `graph` (branches, merges, tags, stashes, a remote, a worktree, uncommitted changes), `graph-origin.git`
(its bare remote), `graph-wt` (a linked worktree), `conflict` (a merge stopped on 3 conflicted files),
`conflict-rebase` (a rebase stopped on the same conflicts) and `expected/`.

- `--big N` also creates `big`, a repository with N commits (linear history plus merges).
- `--portable` skips `graph-wt`, for git older than 2.48.

The script refuses `/`, your home folder and any non-empty folder it did not create. Everything under `build/` is
git-ignored.

## Benchmark

The graph benchmark parses and lays out 50,000 commits and must finish in under 2 seconds. It only runs when
`HISTQ_BIG_FIXTURE` points at a big fixture (an absolute path). From the repository root:

```sh
scripts/make-fixtures.sh build/qa/fx --big 50000
export HISTQ_BIG_FIXTURE="$PWD/build/qa/fx/big"
cd Packages/HistqCore && swift test -c release --filter GraphLayoutTests
```

The test prints `GraphLayout benchmark: <count> commits parsed and laid out in <time>`.

## Screenshots: `scripts/shot.sh`

`scripts/shot.sh` launches the Debug app (build it first) and captures its window to a PNG:

```sh
scripts/shot.sh build/qa/shots/graph.png build/qa/fx/graph
scripts/shot.sh build/qa/shots/terminal.png build/qa/fx/graph -- -HistqOpenTerminal YES
scripts/shot.sh build/qa/shots/settings.png -- -HistqSelect settings:terminal
```

Usage: `scripts/shot.sh <out.png> [--keep-state] [--wait <s>] [repo paths...] [-- app args...]`.

- **Background only.** The app is opened with `open -g` and `-HistqBackground YES`: it never activates, its window
  stays behind your other windows and is never made key, so a run never takes your focus. Shots therefore show an
  inactive window (grey traffic lights).
- **Isolated state.** Every run passes `-HistqStateDir build/qa/state`. The folder and the QA preferences suite
  (`com.math2it.histq.qa`) are wiped first unless you pass `--keep-state`.
- **Window capture.** It waits for the window, then `--wait` seconds (default 1.5), then captures only that window
  with `screencapture -l`. The Terminal you run it from needs the Screen Recording permission.
- It quits only the instance it started, never an installed Histq.

## Timing logs

The click-first rule (a click selects at once, the detail shows a placeholder, then its content) is checked with
timings, not by feel. In a state-dir run, Debug builds append one line per event to `build/qa/state/timing.log`:

```text
<ms since launch> <event> <detail>
```

Events: `open` (a repository opened in a tab), `select` (the selection changed), `placeholder` (the detail's
placeholder is on screen), `spinner` (the delayed spinner faded in, only when a load takes over about 150 ms),
`content` (the content is on screen; `content log-complete <n>` when the whole history is laid out). Watcher refreshes
go to `build/qa/state/refresh.log` instead.

Read the file right after a `scripts/shot.sh` run (which wipes the state dir first): each `select` line must have a
`placeholder` line at most 16 ms later, and a `content` line after it.

```sh
cat build/qa/state/timing.log
```

## DEBUG launch arguments

Debug builds read these arguments; Release builds ignore all of them. With `scripts/shot.sh`, put them after `--`.
Use `-HistqStateDir` for every automated launch: Debug and Release share the bundle id `com.math2it.histq`, so
without it a test run would read and write the state of your installed Histq.

| Argument | What it does |
| --- | --- |
| `-HistqStateDir <dir>` | Keeps all files, logs and session state in `<dir>`, and uses the QA preferences suite and Keychain service (`com.math2it.histq.qa`). |
| `-HistqBackground YES` | Never activates the app; windows stay behind others and are never key. |
| `-HistqSelect <kind>[:<value>]` | Selects something at launch through the click path. Kinds: `tab:<n>`, `wip`, `commit:<sha>`, `branch:<name>`, `file:<path>`, `conflict:<path>`, `commitfile:<sha>:<path>`, `settings:<section>` (`general`, `appearance`, `profiles`, `ssh`, `integrations`, `ai`, `terminal`), `sidebar:<tab>` (`branches`, `tags`, `prs`), `pr:<n>`, `issue:<n>`, `prbadge:<branch>`. |
| `-HistqWindowSize <w>x<h>` | Size of new windows, e.g. `912x520`. |
| `-HistqTabbedWindows <n>` | Spreads the launch's repositories over n native-tab windows. |
| `-HistqTabPosition left\|top` | Vertical tab list or native tabs, overriding the preference. |
| `-HistqAvatarMode real\|generated\|initials` | Avatar mode, overriding the preference. |
| `-HistqOpenPalette "<query>"` | Opens the command palette with that query. Add `-HistqPaletteRun` to run the first row. |
| `-HistqOpenTerminal YES` | Opens the terminal drawer with each repository tab and starts its shell, as the toolbar button does. (The "Open terminal with each new tab" setting only shows the drawer; its shell waits for a click.) |
| `-HistqHTMLProbe YES` | In a state-dir run, snapshots every GitHub HTML view half a second after it shows (`html-<n>.png` in the state dir) and logs its size and ink pixels to `timing.log`. |
| `-HistqKeychain memory` | Uses an in-memory Keychain, so a run never touches a real keychain. |
| `-HistqRun "<menu>\|<item>[;;<next>...]"` | Runs context-menu items by title, accepting confirmations; outcomes go to `operations.txt` in the state dir. Fixture copies only. |
| `-HistqShow "<menu>\|<item>"` | Opens one menu item's confirmation or form and leaves it on screen. `-HistqFormName "<name>"` then fills and submits a form. |
| `-HistqStageLines <n>,<m>` | Selects those changed lines in the first stageable diff. |
| `-HistqResolve A1,B2,AB3[,save]` | In the conflict editor, ticks side A, B or both of conflict 1, 2, 3..., then presses Save when `save` is listed. |
| `-HistqOpenRebase <rev>` / `-HistqOpenSquash "<rev>,<rev>"` | Opens the interactive rebase or squash sheet. Add `-HistqStartRebase` to start it. |
| `-HistqUndo <n>` / `-HistqRedo <n>` | Runs n undos, then n redos, through the toolbar's path. |
| `-HistqGitHubStub YES` | Serves the pull request and issue features from canned data, without GitHub. |
| `-HistqPRTab commits\|files\|checks` | The tab a pull request opens on. |
| `-HistqPRAction <action>` / `-HistqIssueAction <action>` | Runs a pull request or issue action once, without its confirmation. Only with `-HistqGitHubStub YES`. |
| `-HistqOpenCreatePR <branch>` | Opens the Create Pull Request form for that branch. |
| `-HistqAIStub YES\|error` | Answers AI requests locally with canned replies (or HTTP 401), never reaching the network. State-dir runs only; with `-HistqKeychain memory` every provider gets a fake key. |
| `-HistqAI <hook>[,apply\|,cancel]` | Clicks one AI button: `generate`, `explain-wip`, `explain`, `resolve` or `test`. Only with `-HistqAIStub`. |

The full list, with each argument's exact behavior, is in the doc comments where each one is read:
`grep -rn '"-Histq' App`.

## Project layout

- `App/`: the macOS app (SwiftUI and AppKit, UI only). `App/GlassStyle.swift` holds the `Palette` and `Motion`
  design tokens.
- `Packages/HistqCore/`: a Foundation-only Swift package with everything that is not UI: running git, parsing its
  output, graph layout, diffs, three-way merge, profiles, the GitHub client and the AI clients. Tests are in
  `Packages/HistqCore/Tests/HistqCoreTests`.
- `scripts/`: `make-fixtures.sh`, `shot.sh`, `check-build-parity.sh` and the release scripts.
- `project.yml`: the XcodeGen project (source of truth for `Histq.xcodeproj`, which is generated and git-ignored).
- `assets/`: the original logo artwork.
- `build/` and `docs/` are git-ignored (QA output, local plans and notes).

## Releasing

Releases are maintainer-only. Run `/cf-ship`, which follows the project guide in
`.coding-friend/skills/cf-ship-custom/SKILL.md` and calls `scripts/ship.sh`. The one-time setup (certificate,
notarization profile, Sparkle key), the release steps and the rollback are in `docs/RELEASING.md`, a local file kept
out of git.

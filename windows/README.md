# Histq for Windows

The native Windows port of Histq: C# on .NET 10 with WinUI 3 (Windows App SDK), for Windows 11 on x64 and ARM64, with the same features as the macOS app. The macOS app lives in [`../App`](../App) and [`../Packages/HistqCore`](../Packages/HistqCore); the Swift sources are ported from commit `6fa6d40` (v0.5.0), with the Swift tests translated as the behaviour spec.

Histq drives the user's installed Git for Windows (no bundled git).

## Layout

| Path | What |
|---|---|
| `Histq.slnx` | The solution. |
| `global.json` | Pins the .NET 10 SDK (`10.0.100`, `latestFeature`). |
| `Directory.Build.props` | Shared settings: nullable on, warnings are errors, ordinal string comparison (CA1307/CA1309/CA1310) enforced. |
| `Directory.Packages.props` | Central package versions. |
| `src/Histq.Core` | `net10.0`, no Windows APIs: state paths, the git executable lookup and the git runner (more of HistqCore follows). Builds and tests on macOS. |
| `tests/Histq.Core.Tests` | xUnit v3 tests for Core. The fixture repos are built by `../scripts/make-fixtures.sh` (`/bin/bash` on the Mac, Git Bash's `bin\bash.exe` on Windows). |
| `tools/FixtureBridge` | A SwiftPM tool (macOS 15) on `../Packages/HistqCore` that writes and reads the state formats for the cross-platform fixtures. Mac only. |

Later phases add `src/Histq.Platform` (Win32/WinRT) and `src/Histq.App` (the WinUI 3 app, unpackaged and self-contained).

## Local checks (macOS)

With the .NET 10 SDK installed in `~/.dotnet`, from the repo root:

```sh
~/.dotnet/dotnet test windows/tests/Histq.Core.Tests/Histq.Core.Tests.csproj
```

The Windows-only tests (Git for Windows lookup, `.exe` rules) skip on the Mac.

## Cross-platform fixtures

`tests/Histq.Core.Tests/Fixtures/` holds one file from each side with the four shared state formats (`{workspace, session, profiles, repoView}`: a `.histqws`, `session.json`, the profiles and a repo view); each side reads the other side's file:

- `macos-fixtures.json`: written by HistqCore through `fixture-bridge export` (`tools/FixtureBridge`, the Mac app's own encoder settings), read by `CrossPlatformFixtureTests`, which decodes every part with the C# types and requires the same JSON back.
- `windows-fixtures.json`: written by `CrossPlatformFixtureTests` (Windows-made relative `path`s and `~` homes, built with `PathFlavor.Windows` so the Mac writes the same file), read by `fixture-bridge check`, which decodes it with HistqCore and requires the same JSON back.

Every id is fixed, so both files are the same on every run. The C# writer runs only with `HISTQ_WRITE_FIXTURES=1`; without it the test fails when the committed file no longer matches the writer. Regenerate both from the repo root after changing a format, then check both without the variable:

```sh
swift run --package-path windows/tools/FixtureBridge fixture-bridge export windows/tests/Histq.Core.Tests/Fixtures/macos-fixtures.json
HISTQ_WRITE_FIXTURES=1 ~/.dotnet/dotnet test windows/tests/Histq.Core.Tests/Histq.Core.Tests.csproj
swift run --package-path windows/tools/FixtureBridge fixture-bridge check windows/tests/Histq.Core.Tests/Fixtures/windows-fixtures.json
~/.dotnet/dotnet test windows/tests/Histq.Core.Tests/Histq.Core.Tests.csproj
```

Regenerate on macOS, not Windows, so the files keep LF line endings. FixtureBridge only reads `Packages/HistqCore`; its build output goes to `tools/FixtureBridge/.build` (gitignored).

`qa-session-tab-states.json` is the VM's tab QA state, a `session.json` copied to `C:\HistqQA\state\tabs` (one window, tab paths `C:/HistqQA/fx/tabs/<name>`: pinned tabs and a pinned worktree pair, the groups Scratch, an unnamed collapsed one and Docs, a worktree pair, plain tabs, the archived `web` popped out, the closed group Old). `SessionStoreTests` writes it with the session store's own writer under `HISTQ_WRITE_FIXTURES=1` and always reads it back through the store and the window model; regenerate it on macOS with the same command as `windows-fixtures.json`:

```sh
HISTQ_WRITE_FIXTURES=1 ~/.dotnet/dotnet test windows/tests/Histq.Core.Tests/Histq.Core.Tests.csproj --filter "FullyQualifiedName~SessionStoreTests"
```

For the VM's tab QA, `fixture-bridge export-workspace <out>` writes a `.histqws` with HistqCore's own writer as if it were `C:\HistqQA\data\qa-tabs.histqws` (POSIX stand-in `/HistqQA/data/qa-tabs.histqws`): tabs docs (pinned), api and api-w2 in the group Docs, t1 and t2, each stored as `../fx/tabs/<name>`. `fixture-bridge check-workspace <file> <expected>` compares each tab's stored `path`, group and pin in a workspace the Windows app saved with the expected file.

## CI

`.github/workflows/windows.yml` runs on pushes to `main` and on pull requests that touch `windows/`, `scripts/make-fixtures.sh` or the workflow, and by hand (`workflow_dispatch`):

- `test` (windows-latest, x64) and `test-arm64` (windows-11-arm): `dotnet test` of `tests/Histq.Core.Tests`, with the runner's Git for Windows. Each job sets `core.autocrlf false` before checkout, so the scripts keep LF line endings under Git Bash.

The App builds only on CI (the WinUI XAML compiler does not run on macOS); the package job arrives with the App in phase 2.

## QA

The QA flags exist only in QA builds (`HISTQ_QA`: Debug, or `-p:HistqQa=true`); a Release build ignores them. Their full syntax is in `src/Histq.App/Debug/QaFlags.cs` and `Debug/SpikeHarness.cs`. Every flag takes a value (launch flags are `-Name value` pairs). Probes write `<stateDir>\Probes\<name>.json`, then quit as File › Exit does and exit 0 (ok), 1 (failed) or 3 (watchdog).

| Flag | What |
|---|---|
| `-HistqStateDir <dir>` | The state folder (session, preferences, `repo-view`, `Probes`, `Logs\crash.log`). Give each check its own emptied one. |
| `-HistqOpen <dir>` | Opens the folder in a tab of the front window. |
| `-HistqOpenWorkspace <file>`, `-HistqSaveWorkspace <file>` | Opens a workspace; saves one and exits (`workspace.json`). |
| `-HistqTabPosition left\|top`, `-HistqMoveTab`, `-HistqSelect`, `-HistqTabWalk`, `-HistqTabClickProbe` | Tab position and the tab probes. |
| `-HistqRowClickProbe auto\|<rows>\|sidebar\|sidebar:<refs>` | Graph or sidebar row clicks, frames to highlight (`rowclick.json`). |
| `-HistqFind "<query>[;next\|prev…]"` | Opens the graph search with the query once the log is complete. |
| `-HistqShowHidden YES` | The Local, Remote and Tags cards list their hidden rows. |
| `-HistqLoadProbe YES` | Launch to first rows and to the complete log drawn, in ms (`load.json`). |
| `-HistqRowsProbe <n>\|auto` | The first n (50) commits: hash, parents, full ref names (`rows.json`). |
| `-HistqScrollProbe <seconds>` | On a repo tab: the spike's scroll probe on its graph (`scroll.json`); with `-HistqSpikeLog <dump>`: the phase 5 spike (`spike.json`). |
| `-HistqWatchProbe YES` | The app makes an empty commit in the repo; ms until its row is drawn (`watch.json`). |

`scripts/qa-data.sh` (on the Mac): `fixtures [out]` zips the graph and 200k-commit fixtures (`fx-graph.zip`, `fx-big-200k.zip`, to unzip into `C:\HistqQA\fx`); `check-rows <fixture> <rows.json>` compares `rows.json` with `git log` of the same fixture; `check-scroll <scroll.json>` checks the frame-time thresholds (median 17.5, p95 33.4, max 100 ms); `dump` and `check` are the phase 5 spike's.

The VM (Windows VM 2) runs only CI artifacts: `gh run download <run> -n Histq-win-arm64`, add `scripts/vm-install.ps1`, zip the folder, copy it into the VM's `Downloads` (`VMPalMachine --cli cp`), then `Expand-Archive` and `vm-install.ps1 -Folder <folder> -AppArgs '-HistqStateDir','C:\HistqQA\state\<check>',… -Wait` (`-Launch` alone starts it without arguments). Never build, clone or install toolchains in the VM. Keep fixtures and states in `C:\HistqQA`, unzip a fresh fixture before each check, and look for `<stateDir>\Logs\crash.log` after each run (a recovered or fatal exception is written there in every build).

## Build cache

.NET builds into each project's `bin/` and `obj/` (gitignored). NuGet packages are cached in `~/.nuget/packages` (on Windows CI `%USERPROFILE%\.nuget\packages`). There is no repo `nuget.config`; packages come from nuget.org.

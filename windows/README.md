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

Later phases add `src/Histq.Platform` (Win32/WinRT) and `src/Histq.App` (the WinUI 3 app, unpackaged and self-contained).

## Local checks (macOS)

With the .NET 10 SDK installed in `~/.dotnet`, from the repo root:

```sh
~/.dotnet/dotnet test windows/tests/Histq.Core.Tests/Histq.Core.Tests.csproj
```

The Windows-only tests (Git for Windows lookup, `.exe` rules) skip on the Mac.

## CI

`.github/workflows/windows.yml` runs on pushes to `main` and on pull requests that touch `windows/`, `scripts/make-fixtures.sh` or the workflow, and by hand (`workflow_dispatch`):

- `test` (windows-latest, x64) and `test-arm64` (windows-11-arm): `dotnet test` of `tests/Histq.Core.Tests`, with the runner's Git for Windows. Each job sets `core.autocrlf false` before checkout, so the scripts keep LF line endings under Git Bash.

The App builds only on CI (the WinUI XAML compiler does not run on macOS); the package job arrives with the App in phase 2.

## Build cache

.NET builds into each project's `bin/` and `obj/` (gitignored). NuGet packages are cached in `~/.nuget/packages` (on Windows CI `%USERPROFILE%\.nuget\packages`). There is no repo `nuget.config`; packages come from nuget.org.

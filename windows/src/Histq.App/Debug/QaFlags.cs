#if HISTQ_QA
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Histq.App.Detail;
using Histq.App.Graph;
using Histq.App.Repo;
using Histq.App.Shell;
using Histq.App.Shell.Tabs;
using Histq.App.Sidebar;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Histq.App
{
    /// <summary>
    /// The workspace QA flags (QA builds only; ported from the Mac's DEBUG <c>-HistqSaveWorkspace</c>, AppState.swift
    /// at 6fa6d40), read at startup by <see cref="App"/>:
    /// <list type="bullet">
    /// <item><c>-HistqOpenWorkspace &lt;file&gt;</c>: once the launch's windows are restored, opens the workspace as
    /// Open Workspace… does (its own window, guarded tabs). Alone, the app then stays up (interactive checks).</item>
    /// <item><c>-HistqSaveWorkspace &lt;file&gt;</c>: once the launch's windows are restored (and the workspace above
    /// is open), waits until the windows' repo key reads and folder checks are applied (at most 10 s), then Save
    /// Workspace As… writes <c>&lt;file&gt;</c> without a picker: the opened workspace, else the front window's (an
    /// Untitled front window makes a new workspace of the Untitled windows). Then the session and the pending writes
    /// are flushed, <c>&lt;stateDir&gt;\Probes\workspace.json</c> is written and the process exits 0; any failure is
    /// written there as <c>error</c> and the process exits non-zero (1, or 3 when the run takes too long).</item>
    /// <item><c>-HistqOpen &lt;dir&gt;</c>: once the launch's windows are restored, the folder opens in a tab of the
    /// front window, as a positional folder argument does (<see cref="OpenFolder"/>, opened by <see cref="App"/>
    /// through <see cref="WindowManager.OpenAtLaunchAsync"/>).</item>
    /// <item><c>-HistqTabPosition left|top</c>: the window's tabs show in the vertical panel (left) or the title bar's
    /// strip (top), over the tab position preference at startup, which it never writes; a View › Move Tabs switch
    /// still writes the preference and wins from then on (ported from the Mac's DEBUG flag, VerticalTabsPanel.swift
    /// at 6fa6d40). Read once, when the first window asks (<see cref="TabPositionFlag"/>).</item>
    /// <item>The tab flags <c>-HistqMoveTab</c>, <c>-HistqSelect</c>, <c>-HistqTabWalk</c> and
    /// <c>-HistqTabClickProbe</c>: see <see cref="QaTabProbes"/>.</item>
    /// <item><c>-HistqRowClickProbe auto|row,row,...|sidebar|sidebar:ref,ref,...</c>: graph row clicks, or sidebar ref
    /// clicks, in the front window's selected repo tab, see <see cref="QaRowClickProbe"/>.</item>
    /// <item>The repo tab flags <c>-HistqFind</c>, <c>-HistqShowHidden</c>, <c>-HistqScrollProbe</c> (without
    /// <c>-HistqSpikeLog</c>), <c>-HistqRowsProbe</c>, <c>-HistqLoadProbe</c> and <c>-HistqWatchProbe</c>: see
    /// <see cref="QaRepoProbes"/>.</item>
    /// </list>
    /// workspace.json reads the saved file back as the app opens one and lists each tab of each window with its stored
    /// <c>path</c> / <c>home</c> strings, the native path they resolved to and whether that folder exists (a UNC or
    /// device path is never probed and reads as not existing).
    /// </summary>
    internal sealed class QaFlags
    {
        private const string OpenWorkspaceFlag = "-HistqOpenWorkspace";
        private const string SaveWorkspaceFlag = "-HistqSaveWorkspace";
        private const string TabPositionName = "-HistqTabPosition";
        private const string OpenFolderName = "-HistqOpen";

        /// <summary>How long the save waits for the repo key reads and folder checks.</summary>
        private static readonly TimeSpan SettleLimit = TimeSpan.FromSeconds(10);

        /// <summary>A save run that has not exited by then fails, so a stuck run never holds the VM chain.</summary>
        private static readonly TimeSpan Watchdog = TimeSpan.FromMinutes(3);

        /// <summary>The probes' JSON: camelCase, indented, nulls left out.</summary>
        internal static readonly JsonSerializerOptions JsonOptions = new()
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };

        private readonly WorkspaceProbe _result = new();
        private readonly Lock _writeLock = new();
        private readonly TraceCapture _trace = new();
        private string _probePath = string.Empty;
        private int _finished;

        /// <summary>The tab flags (<see cref="QaTabProbes"/>); null without any.</summary>
        private readonly QaTabProbes? _tabProbes;

        /// <summary>The row click probe (<see cref="QaRowClickProbe"/>); null without the flag.</summary>
        private readonly QaRowClickProbe? _rowProbe;

        /// <summary>The repo tab flags (<see cref="QaRepoProbes"/>); null without any.</summary>
        private readonly QaRepoProbes? _repoProbes;

        private QaFlags(
            string? openWorkspace, string? saveWorkspace, QaTabProbes? tabProbes, QaRowClickProbe? rowProbe,
            QaRepoProbes? repoProbes)
        {
            _repoProbes = repoProbes;
            OpenWorkspace = openWorkspace;
            SaveWorkspace = saveWorkspace;
            _tabProbes = tabProbes;
            _rowProbe = rowProbe;
        }

        /// <summary>The workspace file to open at launch; null without the flag.</summary>
        public string? OpenWorkspace { get; }

        /// <summary>The file to save the workspace to, then exit; null without the flag.</summary>
        public string? SaveWorkspace { get; }

        /// <summary>The <c>-HistqTabPosition</c> value of the launch arguments ("left" or "top"; anything else is
        /// ignored by <see cref="Shell.Tabs.TabPositions"/>), or null without the flag. Read once.</summary>
        public static string? TabPositionFlag { get; } =
            new LaunchFlags(Environment.GetCommandLineArgs().Skip(1).ToList()).String(TabPositionName);

        /// <summary>The <c>-HistqOpen</c> folder of <paramref name="arguments"/> (the launch arguments, without the
        /// program's path), or null without the flag.</summary>
        public static string? OpenFolder(IReadOnlyList<string> arguments) =>
            NonEmpty(new LaunchFlags(arguments).String(OpenFolderName));

        /// <summary>The flags in <paramref name="arguments"/> (the launch arguments, without the program's path).</summary>
        public static QaFlags Read(IReadOnlyList<string> arguments)
        {
            var flags = new LaunchFlags(arguments);
            return new QaFlags(
                NonEmpty(flags.String(OpenWorkspaceFlag)), NonEmpty(flags.String(SaveWorkspaceFlag)),
                QaTabProbes.Read(arguments), QaRowClickProbe.Read(arguments), QaRepoProbes.Read(arguments));
        }

        /// <summary>
        /// Runs the flags given (none: nothing). Call it on the UI thread right after
        /// <see cref="WindowManager.Restore"/> and <see cref="WindowManager.OpenAtLaunchAsync"/>, with their tasks:
        /// nothing starts before the launch's windows are open, and the tab flags (<see cref="QaTabProbes"/>) wait for
        /// the launch's folders and the workspace flags' open too.
        /// </summary>
        public void Start(WindowManager windows, Task restored, Task launched, StatePaths paths)
        {
            Task workspaceRun = StartWorkspace(windows, restored, paths);
            _tabProbes?.Start(windows, Task.WhenAll(restored, launched, workspaceRun), paths);
            _rowProbe?.Start(windows, Task.WhenAll(restored, launched, workspaceRun), paths);
            _repoProbes?.Start(windows, Task.WhenAll(restored, launched, workspaceRun), paths);
        }

        /// <summary>The workspace flags' run (none: a completed task); it never faults.</summary>
        private Task StartWorkspace(WindowManager windows, Task restored, StatePaths paths)
        {
            if (OpenWorkspace is null && SaveWorkspace is null)
                return Task.CompletedTask;
            _probePath = Path.Combine(paths.Root, "Probes", "workspace.json");
            if (SaveWorkspace is not null)
            {
                Trace.Listeners.Add(_trace);
                _ = Task.Delay(Watchdog).ContinueWith(
                    _ => Finish($"watchdog: the run did not finish in {Watchdog.TotalMinutes} minutes", 3),
                    TaskScheduler.Default);
                Application.Current.UnhandledException += (_, e) => Finish(e.Exception.ToString(), 1);
            }

            return RunAsync(windows, restored);
        }

        /// <summary>Never throws: a save run's failure is written to workspace.json and exits; an open-only run's is
        /// logged and the app stays up.</summary>
        private async Task RunAsync(WindowManager windows, Task restored)
        {
            try
            {
                await restored;
                WorkspaceDocument? workspace = null;
                if (OpenWorkspace is { } open)
                {
                    _result.Opened = open;
                    workspace = await windows.QaOpenWorkspaceAsync(open);
                    _result.ReadOnly = workspace.IsReadOnly;
                }

                if (SaveWorkspace is not { } save)
                    return;

                _result.ChecksSettled = await windows.QaSettleAsync(SettleLimit);
                await windows.QaSaveWorkspaceAsAsync(workspace, save);
                _result.Saved = save;
                windows.QaQuit();
                List<ProbeWindow> saved = await Task.Run(() => ReadBack(save));
                _result.Windows = saved;
                _result.TabCount = saved.Sum(window => window.Tabs.Count);
                _result.MissingCount = saved.Sum(window => window.Tabs.Count(tab => !tab.Exists));
                // The probe is written off the UI thread; the process exits back on it.
                if (await Task.Run(() => Record(null)))
                    Environment.Exit(0);
            }
            catch (Exception error) when (SaveWorkspace is not null)
            {
                if (await Task.Run(() => Record(error.ToString())))
                    Environment.Exit(1);
            }
            catch (Exception error)
            {
                Trace.WriteLine($"Histq: {OpenWorkspaceFlag} failed: {error.Message}");
            }
        }

        /// <summary>The saved file read back as the app opens one (<see cref="WorkspaceDocument.Open"/>: 8 MB cap, a
        /// received UNC or device path never probed). Runs on a worker.</summary>
        private static List<ProbeWindow> ReadBack(string path)
        {
            PathFlavor flavor = PathFlavor.Host;
            WorkspaceFile.Resolved resolved = WorkspaceDocument.Open(path).Resolved;
            var windows = new List<ProbeWindow>();
            foreach (WorkspaceFile.LiveWindow window in resolved.Windows)
            {
                var tabs = new List<ProbeTab>();
                foreach (SavedTab tab in window.Tabs)
                {
                    if (tab.Path is not { } tabPath)
                        continue;
                    string native = flavor.Standardized(tabPath);
                    // Resolve keeps the stored strings of every tab it resolved: a miss is a bug, not a probe result.
                    if (!resolved.Originals.TryGetValue(native, out WorkspaceFile.Original? stored))
                        throw new InvalidOperationException($"the saved file has no stored strings for \"{native}\"");
                    tabs.Add(new ProbeTab
                    {
                        StoredPath = stored.Path,
                        StoredHome = stored.Home,
                        Path = native,
                        Exists = !flavor.IsUncOrDevice(native) && Directory.Exists(native),
                        Missing = resolved.Missing.Contains(native),
                    });
                }

                windows.Add(new ProbeWindow { Id = window.Id, Tabs = tabs });
            }

            return windows;
        }

        /// <summary><see cref="Record"/>, then exits with <paramref name="code"/> (the watchdog, an unhandled
        /// exception: any thread).</summary>
        private void Finish(string error, int code)
        {
            if (Record(error))
                Environment.Exit(code);
        }

        /// <summary>Writes workspace.json (with <paramref name="error"/> when there is one); true for the first call
        /// only, which then exits. A failed write is only traced: the exit code still tells.</summary>
        private bool Record(string? error)
        {
            if (Interlocked.Exchange(ref _finished, 1) == 1)
                return false;
            try
            {
                lock (_writeLock)
                {
                    _result.Ok = error is null;
                    _result.Error = error;
                    _result.Trace = _trace.Lines();
                    Directory.CreateDirectory(Path.GetDirectoryName(_probePath)!);
                    File.WriteAllText(_probePath, JsonSerializer.Serialize(_result, JsonOptions));
                }
            }
            catch (Exception failure)
            {
                Trace.WriteLine($"Histq: workspace.json not written: {failure.Message}");
            }

            return true;
        }

        internal static string? NonEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

        /// <summary>workspace.json.</summary>
        private sealed class WorkspaceProbe
        {
            public bool Ok { get; set; }
            public string? Error { get; set; }
            public string? Opened { get; set; }
            public bool? ReadOnly { get; set; }
            public bool? ChecksSettled { get; set; }
            public string? Saved { get; set; }
            public int? TabCount { get; set; }
            public int? MissingCount { get; set; }
            public List<ProbeWindow>? Windows { get; set; }
            public List<string>? Trace { get; set; }
        }

        private sealed class ProbeWindow
        {
            public Guid Id { get; set; }
            public List<ProbeTab> Tabs { get; set; } = [];
        }

        private sealed class ProbeTab
        {
            public string? StoredPath { get; set; }
            public string? StoredHome { get; set; }
            public string Path { get; set; } = string.Empty;
            public bool Exists { get; set; }
            public bool Missing { get; set; }
        }

        /// <summary>The app's trace lines while a save run is under way (a refused or failed save says why only
        /// there and in a toast), kept for workspace.json.</summary>
        private sealed class TraceCapture : TraceListener
        {
            private const int MaxLines = 200;
            private readonly Lock _gate = new();
            private readonly List<string> _lines = [];
            private readonly StringBuilder _partial = new();

            public override void Write(string? message)
            {
                lock (_gate)
                    _partial.Append(message);
            }

            public override void WriteLine(string? message)
            {
                lock (_gate)
                {
                    _partial.Append(message);
                    if (_lines.Count < MaxLines)
                        _lines.Add(_partial.ToString());
                    _partial.Clear();
                }
            }

            public List<string> Lines()
            {
                lock (_gate)
                    return [.. _lines];
            }
        }
    }

    /// <summary>
    /// The tab QA flags (QA builds only; the M1 exit run, task 13.3). They start once the launch's windows are restored,
    /// its folders opened (positional arguments, <c>-HistqOpen</c>) and a <c>-HistqOpenWorkspace</c> open, after the
    /// repo key reads and folder checks are applied (at most 10 s, <see cref="WindowManager.QaSettleAsync"/>), and run in
    /// this order:
    /// <list type="number">
    /// <item><c>-HistqMoveTab &lt;title&gt;:new</c>: File › New Window from the tab's window, then the tab moves into it
    /// through <see cref="WindowManager.MoveTab"/> (Move Tab to Window ›, a tab dragged onto a window), refused first
    /// when it must stay (<see cref="WindowManager.MoveRefusal"/>; the new window then closes). The outcome, a refusal's
    /// reason among them, is written to <c>&lt;stateDir&gt;\Probes\movetab.json</c>. The new window keeps its Welcome
    /// tab (New Window's), the moved tab after it, selected.</item>
    /// <item><c>-HistqSelect &lt;title&gt;</c>: the tab is pressed as a plain left click presses it (<see cref="Click"/>).</item>
    /// <item><c>-HistqTabWalk &lt;label&gt;</c> (letters, digits, <c>-</c> and <c>_</c>; required): once the checks
    /// above are applied again, the tab model of every window is written to
    /// <c>&lt;stateDir&gt;\Probes\tabwalk-&lt;label&gt;.json</c> (<see cref="WalkProbe"/>; without a valid label,
    /// <c>tabwalk.json</c> with the error).</item>
    /// <item><c>-HistqTabClickProbe &lt;title1,title2,...&gt;</c>: the listed tabs (all in one window, revisits allowed)
    /// are clicked in order, each once the one before shows (or timed out), and each switch is measured in
    /// CompositionTarget.Rendering frames (<see cref="ClickProbe"/>), written to
    /// <c>&lt;stateDir&gt;\Probes\tabclick.json</c>.</item>
    /// </list>
    /// A tab is named by its title (alias, else folder name, "New Tab" for Welcome; ordinal), in every window; no tab or
    /// two tabs with that title is a failure. With <c>-HistqTabWalk</c> or <c>-HistqTabClickProbe</c> the process then
    /// quits as File › Exit saves (<see cref="WindowManager.QaQuit"/>: the session with every window) and exits 0, or 1
    /// when anything failed (a failed move or select fails them too), or 3 when the run is not done in 3 minutes; their
    /// files are always written, with <c>ok</c> and, on failure, <c>error</c>. With only <c>-HistqMoveTab</c> /
    /// <c>-HistqSelect</c> the app stays up (interactive checks).
    /// </summary>
    internal sealed class QaTabProbes
    {
        private const string MoveTabFlag = "-HistqMoveTab";
        private const string SelectFlag = "-HistqSelect";
        private const string TabWalkFlag = "-HistqTabWalk";
        private const string TabClickFlag = "-HistqTabClickProbe";

        /// <summary>The only move destination: a new window.</summary>
        private const string NewWindowSuffix = ":new";

        /// <summary>Frames waited before the first click and after each switch shows, so a switch never measures the
        /// one before's last frames.</summary>
        private const int QuietFrames = 10;

        private static readonly TimeSpan SettleLimit = TimeSpan.FromSeconds(10);

        /// <summary>A run that has not exited by then fails, so a stuck run never holds the VM chain.</summary>
        private static readonly TimeSpan Watchdog = TimeSpan.FromMinutes(3);

        /// <summary>A switch whose tab has not shown by then is recorded as timed out.</summary>
        private static readonly TimeSpan SwitchLimit = TimeSpan.FromSeconds(20);

        /// <summary>How long <see cref="FramesAsync"/> waits for its frames before going on (no frame is drawn).</summary>
        private static readonly TimeSpan FramesLimit = TimeSpan.FromSeconds(5);

        private readonly Lock _gate = new();
        private readonly string? _move;
        private readonly string? _select;
        private readonly bool _walk;
        private readonly string? _walkLabel;
        private readonly string? _clickList;
        private readonly ClickProbe _click = new();
        private string _probes = string.Empty;
        private bool _walkWritten;
        private bool _moveWritten;
        private int _finished;

        private QaTabProbes(string? move, string? select, bool walk, string? walkLabel, string? clickList)
        {
            _move = move;
            _select = select;
            _walk = walk;
            _walkLabel = walkLabel;
            _clickList = clickList;
        }

        /// <summary>The flags run and then exit (<c>-HistqTabWalk</c>, <c>-HistqTabClickProbe</c>).</summary>
        private bool Exits => _walk || _clickList is not null;

        /// <summary>The tab flags in <paramref name="arguments"/>; null without any. A flag given without its value
        /// counts (its probe reports the missing value) for <c>-HistqTabWalk</c> and <c>-HistqTabClickProbe</c>.</summary>
        public static QaTabProbes? Read(IReadOnlyList<string> arguments)
        {
            var flags = new LaunchFlags(arguments);
            string? move = Value(arguments, flags, MoveTabFlag);
            string? select = Value(arguments, flags, SelectFlag);
            bool walk = arguments.Contains(TabWalkFlag);
            string? clickList = Value(arguments, flags, TabClickFlag);
            if (move is null && select is null && !walk && clickList is null)
                return null;
            string? label = walk ? Value(arguments, flags, TabWalkFlag) : null;
            return new QaTabProbes(move, select, walk, label, clickList);
        }

        /// <summary>A flag's value; an empty string when the flag is given without one (or with another flag after
        /// it), null without the flag.</summary>
        private static string? Value(IReadOnlyList<string> arguments, LaunchFlags flags, string name)
        {
            if (!arguments.Contains(name))
                return null;
            string? value = flags.String(name);
            return value is null || value.StartsWith('-') ? string.Empty : value.Trim();
        }

        /// <summary>Runs the flags once <paramref name="ready"/> (never faulting) ends. Call it on the UI thread.</summary>
        public void Start(WindowManager windows, Task ready, StatePaths paths)
        {
            _probes = Path.Combine(paths.Root, "Probes");
            if (Exits)
            {
                _ = Task.Delay(Watchdog).ContinueWith(
                    _ => Finish($"watchdog: the run did not finish in {Watchdog.TotalMinutes} minutes", 3),
                    TaskScheduler.Default);
                Application.Current.UnhandledException += (_, e) => Finish(e.Exception.ToString(), 1);
            }

            _ = RunAsync(windows, ready);
        }

        /// <summary>Never throws: a failure is written to the probe files, then the run exits (with only the move or
        /// the select, it is traced and the app stays up).</summary>
        private async Task RunAsync(WindowManager windows, Task ready)
        {
            string? failure = null;
            try
            {
                // Resumes on the UI thread (its SynchronizationContext), as every await below.
                await ready;
                await windows.QaSettleAsync(SettleLimit);
                if (_move is not null && await MoveAsync(windows) is { } moveError)
                    failure ??= $"{MoveTabFlag}: {moveError}";
                if (_select is not null && Select(windows) is { } selectError)
                    failure ??= $"{SelectFlag}: {selectError}";
                bool settled = await windows.QaSettleAsync(SettleLimit);
                if (_walk)
                {
                    WalkProbe walk = Walk(windows, settled, failure);
                    await Task.Run(() => WriteWalk(walk));
                    failure ??= walk.Error;
                }

                if (_clickList is not null && await ClickAsync(windows) is { } clickError)
                    failure ??= clickError;
            }
            catch (Exception error)
            {
                failure ??= error.ToString();
                lock (_gate)
                    _click.Error ??= failure;
            }

            if (!Exits)
            {
                if (failure is not null)
                    Trace.WriteLine($"Histq: tab QA flags failed: {failure}");
                return;
            }

            // As File › Exit: the session with every window, the preference writes waited for.
            windows.QaQuit();
            if (await Task.Run(() => Record(failure)))
                Environment.Exit(failure is null ? 0 : 1);
        }

        // -HistqMoveTab

        /// <summary>Moves the named tab to a new window; the error, else null. Writes movetab.json.</summary>
        private async Task<string?> MoveAsync(WindowManager windows)
        {
            var probe = new MoveProbe { Value = _move };
            string value = _move ?? string.Empty;
            try
            {
                if (!value.EndsWith(NewWindowSuffix, StringComparison.OrdinalIgnoreCase))
                {
                    probe.Error = $"\"{value}\" is not <tab title>{NewWindowSuffix} (only a new window is supported)";
                }
                else
                {
                    probe.Tab = value[..^NewWindowSuffix.Length];
                    if (Find(windows, probe.Tab, out string? notFound) is not { } found)
                    {
                        probe.Error = notFound;
                    }
                    else
                    {
                        probe.Refusal = await windows.QaMoveTabToNewWindowAsync(found.Tab.Id, found.Window);
                        probe.Moved = probe.Refusal is null;
                        if (probe.Refusal is { } refusal)
                            probe.Error = $"the move was refused: {refusal}";
                    }
                }
            }
            catch (Exception error)
            {
                probe.Error = error.ToString();
            }

            probe.Ok = probe.Error is null;
            probe.WindowCount = windows.Windows.Count;
            await Task.Run(() => WriteMove(probe));
            return probe.Error;
        }

        // -HistqSelect

        /// <summary>Presses the named tab as a plain left click; the error, else null.</summary>
        private string? Select(WindowManager windows)
        {
            if (Find(windows, _select ?? string.Empty, out string? notFound) is not { } found)
                return notFound;
            Click(found.Window, found.Tab.Id);
            return found.Window.Tabs.SelectedTabId == found.Tab.Id ? null : "the tab was pressed but is not selected";
        }

        /// <summary>
        /// A plain left click on the tab, through the handlers a pointer press runs (TabDragController.OnTabPressed): the
        /// press is held, the shown tabs view picks the tab (<see cref="TabPress.Plain"/>: the multi-selection ends, the
        /// tab is selected and its content swaps in, <see cref="MainWindow.Apply"/>), and the release lets the press go.
        /// No pointer is captured and no drag can start.
        /// </summary>
        private static void Click(MainWindow window, Guid id)
        {
            ITabDragHost host = window.QaTabsHost;
            host.SetPressHeld(true);
            host.Pick(id, TabPress.Plain);
            host.SetPressHeld(false);
        }

        /// <summary>The one tab titled <paramref name="title"/> (ordinal) in the open windows, with its window; null and
        /// <paramref name="error"/> when none or more than one is.</summary>
        private static (MainWindow Window, WindowTabs.Tab Tab)? Find(
            WindowManager windows, string title, out string? error)
        {
            var found = new List<(MainWindow, WindowTabs.Tab)>();
            foreach (MainWindow window in windows.Windows.OrderBy(window => window.Sequence))
            {
                found.AddRange(window.Tabs.Tabs
                    .Where(tab => string.Equals(tab.Title, title, StringComparison.Ordinal))
                    .Select(tab => (window, tab)));
            }

            error = found.Count switch
            {
                1 => null,
                0 => $"no tab is titled \"{title}\"",
                _ => $"{found.Count} tabs are titled \"{title}\"",
            };
            return found.Count == 1 ? found[0] : null;
        }

        // -HistqTabWalk

        /// <summary>The tab model of every window (UI thread; reads the models only).</summary>
        private WalkProbe Walk(WindowManager windows, bool settled, string? failure)
        {
            string? error = failure;
            if (string.IsNullOrEmpty(_walkLabel) || !IsLabel(_walkLabel))
                error ??= $"{TabWalkFlag} needs a label of letters, digits, - and _ (tabwalk-<label>.json)";
            else if (!settled)
                error ??= $"the repo key reads and folder checks were still running after {SettleLimit.TotalSeconds} s";
            // Sorted by their whole JSON: the open order is the activation order, which changes between launches.
            List<WalkWindow> walked = [.. windows.Windows
                .Select(WalkWindow.Of)
                .Select(window => (Window: window, Key: JsonSerializer.Serialize(window, QaFlags.JsonOptions)))
                .OrderBy(entry => entry.Key, StringComparer.Ordinal)
                .Select(entry => entry.Window)];
            return new WalkProbe
            {
                Ok = error is null,
                Error = error,
                ChecksSettled = settled,
                WindowCount = walked.Count,
                Windows = walked,
            };
        }

        private static bool IsLabel(string label) =>
            label.Length <= 40 && !label.StartsWith('-') && label.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');

        private string WalkPath =>
            Path.Combine(_probes, string.IsNullOrEmpty(_walkLabel) || !IsLabel(_walkLabel)
                ? "tabwalk.json"
                : $"tabwalk-{_walkLabel}.json");

        // -HistqTabClickProbe

        /// <summary>Clicks the listed tabs in order and measures each switch; the error, else null. Its result stays in
        /// <see cref="_click"/>, written by <see cref="Record"/>.</summary>
        private async Task<string?> ClickAsync(WindowManager windows)
        {
            string[] titles = (_clickList ?? string.Empty)
                .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            string? error = null;
            MainWindow? window = null;
            var ids = new List<Guid>();
            foreach (string title in titles)
            {
                if (Find(windows, title, out string? notFound) is not { } found)
                {
                    error = notFound;
                    break;
                }

                if (window is not null && window != found.Window)
                {
                    error = $"\"{title}\" is in another window than \"{titles[0]}\": the listed tabs must share one";
                    break;
                }

                window = found.Window;
                ids.Add(found.Tab.Id);
            }

            if (titles.Length == 0)
                error = $"{TabClickFlag} needs a comma-separated list of tab titles";
            if (error is not null || window is null)
                return SetClickError(error ?? "no window");

            TabContentHost content = window.QaContentHost;
            lock (_gate)
            {
                _click.Visits = [.. titles];
                _click.TabPosition = window.TabPosition == TabPosition.Left ? "left" : "top";
                _click.KeptLayouts = WindowTabs.KeptLayouts;
                _click.StartSelected = window.Tabs.SelectedIndex is { } start ? window.Tabs.Tabs[start].Title : null;
                _click.StartMounted = content.QaMountedRepoTitles(window.Tabs);
            }

            // A real click brings its window forward first.
            windows.Show(window);
            await FramesAsync(QuietFrames);
            for (int step = 0; step < ids.Count; step++)
            {
                if (!windows.Windows.Contains(window))
                    return SetClickError("the window closed during the probe");
                Guid id = ids[step];
                if (!window.Tabs.ShownTabs.Contains(id))
                    return SetClickError($"\"{titles[step]}\" is not shown (in a collapsed group, or gone): it cannot be clicked");

                ClickSwitch measured = await MeasureAsync(window, content, id, titles[step], step + 1);
                lock (_gate)
                    _click.Switches.Add(measured);
                if (measured.TimedOut)
                {
                    return SetClickError(
                        $"\"{titles[step]}\" (step {step + 1}) did not show within {SwitchLimit.TotalSeconds} s");
                }

                // The probe measures repo layouts: "Repo not found", Welcome or a failed load would pass as shown.
                if (measured.Content != "repo" || measured.LoadFailed)
                {
                    return SetClickError(measured.LoadFailed
                        ? $"\"{titles[step]}\" (step {step + 1}): its graph load failed"
                        : $"\"{titles[step]}\" (step {step + 1}) shows {measured.Content}, not a repo layout");
                }

                await FramesAsync(QuietFrames);
            }

            lock (_gate)
            {
                _click.MountedLayouts = content.QaMountedLayouts;
                _click.Ok = true;
            }

            return null;
        }

        private string SetClickError(string error)
        {
            lock (_gate)
                _click.Error ??= error;
            return error;
        }

        /// <summary>
        /// Clicks the tab <paramref name="id"/> (<see cref="Click"/>) and counts the frames (distinct
        /// <see cref="RenderingEventArgs.RenderingTime"/>s of CompositionTarget.Rendering, the first after the click being
        /// frame 1) until the tab's view shows it selected and until its content shows: a repo layout visible with its
        /// graph's placeholder gone (rows in, or the load's error), any other content visible. The frames the layout was
        /// visible with its placeholder are counted too. The Rendering handler only reads.
        /// </summary>
        private static async Task<ClickSwitch> MeasureAsync(
            MainWindow window, TabContentHost content, Guid id, string title, int step)
        {
            var result = new ClickSwitch
            {
                Step = step,
                Title = title,
                WasSelected = window.Tabs.SelectedTabId == id,
                WasMounted = content.QaState(id).Kind != "none",
            };
            var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            TimeSpan? previous = null;
            int frames = 0;
            int placeholder = 0;
            int? highlight = null;
            int? shown = null;
            var clock = Stopwatch.StartNew();

            void OnRendering(object? sender, object e)
            {
                try
                {
                    // Rendering can be raised more than once per frame, with the same time.
                    if (e is not RenderingEventArgs args || args.RenderingTime == previous)
                        return;
                    previous = args.RenderingTime;
                    frames++;
                    if (highlight is null && window.QaShowsSelected(id))
                        highlight = frames;
                    if (shown is null)
                    {
                        QaContentState state = content.QaState(id);
                        if (state.Visible && state.Placeholder)
                        {
                            placeholder++;
                        }
                        else if (state.Visible)
                        {
                            shown = frames;
                            result.ClickToShownMs = Math.Round(clock.Elapsed.TotalMilliseconds, 1);
                        }
                    }

                    if (highlight is not null && shown is not null)
                        done.TrySetResult();
                }
                catch (Exception error)
                {
                    done.TrySetException(error);
                }
            }

            CompositionTarget.Rendering += OnRendering;
            try
            {
                Click(window, id);
                // The click's own update: a fresh layout shows its placeholder here, even when its rows are in before
                // the first frame is drawn.
                result.PlaceholderAtClick = content.QaState(id).Placeholder;
                await Task.WhenAny(done.Task, Task.Delay(SwitchLimit));
            }
            finally
            {
                CompositionTarget.Rendering -= OnRendering;
            }

            if (done.Task.IsFaulted)
                throw done.Task.Exception!.InnerException ?? done.Task.Exception;

            QaContentState after = content.QaState(id);
            result.Content = after.Kind;
            result.LoadFailed = after.Failed;
            result.ClickToHighlightFrames = highlight;
            result.ClickToShownFrames = shown;
            result.PlaceholderFrames = placeholder;
            result.Frames = frames;
            result.TimedOut = shown is null || highlight is null;
            result.Selected = window.Tabs.SelectedTabId == id;
            result.MountedLayouts = content.QaMountedLayouts;
            return result;
        }

        /// <summary>Waits for <paramref name="count"/> drawn frames (at most <see cref="FramesLimit"/>).</summary>
        internal static async Task FramesAsync(int count)
        {
            var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            TimeSpan? previous = null;
            int frames = 0;

            void OnRendering(object? sender, object e)
            {
                if (e is not RenderingEventArgs args || args.RenderingTime == previous)
                    return;
                previous = args.RenderingTime;
                if (++frames >= count)
                    done.TrySetResult();
            }

            CompositionTarget.Rendering += OnRendering;
            try
            {
                await Task.WhenAny(done.Task, Task.Delay(FramesLimit));
            }
            finally
            {
                CompositionTarget.Rendering -= OnRendering;
            }
        }

        // Probe files.

        /// <summary><see cref="Record"/>, then exits with <paramref name="code"/> (the watchdog, an unhandled exception:
        /// any thread).</summary>
        private void Finish(string error, int code)
        {
            if (Record(error))
                Environment.Exit(code);
        }

        /// <summary>
        /// The run's end: writes the probe files not written yet (a walk or a move that never ran says
        /// <paramref name="error"/>) and tabclick.json; true for the first call only, which then exits. Any thread. A
        /// failed write is only traced: the exit code still tells.
        /// </summary>
        private bool Record(string? error)
        {
            if (Interlocked.Exchange(ref _finished, 1) == 1)
                return false;
            lock (_gate)
            {
                string reason = error ?? "the run ended before this probe ran";
                if (_walk && !_walkWritten)
                    Write(WalkPath, new WalkProbe { Ok = false, Error = reason });
                if (_move is not null && !_moveWritten)
                    Write(Path.Combine(_probes, "movetab.json"), new MoveProbe { Ok = false, Value = _move, Error = reason });
                if (_clickList is not null)
                {
                    if (error is not null)
                    {
                        _click.Ok = false;
                        _click.Error ??= error;
                    }
                    else if (!_click.Ok)
                    {
                        _click.Error ??= reason;
                    }

                    Write(Path.Combine(_probes, "tabclick.json"), _click);
                }
            }

            return true;
        }

        /// <summary>Writes the walk, unless the run has ended (the watchdog wrote its error). Runs on a worker.</summary>
        private void WriteWalk(WalkProbe walk)
        {
            lock (_gate)
            {
                if (_finished == 1)
                    return;
                Write(WalkPath, walk);
                _walkWritten = true;
            }
        }

        /// <summary>Writes movetab.json, unless the run has ended (the watchdog wrote its error). Runs on a worker.</summary>
        private void WriteMove(MoveProbe move)
        {
            lock (_gate)
            {
                if (_finished == 1)
                    return;
                Write(Path.Combine(_probes, "movetab.json"), move);
                _moveWritten = true;
            }
        }

        private static void Write<T>(string path, T probe)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, JsonSerializer.Serialize(probe, QaFlags.JsonOptions));
            }
            catch (Exception failure)
            {
                Trace.WriteLine($"Histq: {Path.GetFileName(path)} not written: {failure.Message}");
            }
        }

        /// <summary>
        /// tabwalk-&lt;label&gt;.json. <see cref="Windows"/> is the model; it holds nothing that changes from one launch
        /// to the next on its own (no tab or Untitled window ids, no frames, no window order: the windows are sorted by
        /// their own JSON), so a session saved and restored walks the same.
        /// </summary>
        private sealed class WalkProbe
        {
            public bool Ok { get; set; }
            public string? Error { get; set; }
            public bool? ChecksSettled { get; set; }
            public int? WindowCount { get; set; }
            public List<WalkWindow>? Windows { get; set; }
        }

        private sealed class WalkWindow
        {
            /// <summary>The workspace file's identity key; null for an Untitled window.</summary>
            public string? Workspace { get; set; }

            /// <summary>The workspace window's id (from its file); null for an Untitled window, whose id is new each
            /// launch.</summary>
            public Guid? WorkspaceWindowId { get; set; }

            public int? SelectedIndex { get; set; }
            public string? SelectedTitle { get; set; }
            public List<WalkTab> Tabs { get; set; } = [];
            public List<WalkGroup> Groups { get; set; } = [];
            public List<WalkBox> WorktreeBoxes { get; set; } = [];

            /// <summary>The stowed archived tabs, most recently archived first (the popped-out one is in
            /// <see cref="Tabs"/>, <c>popped</c>).</summary>
            public List<WalkSavedTab> Archived { get; set; } = [];

            public List<WalkClosedGroup> ClosedGroups { get; set; } = [];

            public static WalkWindow Of(MainWindow window)
            {
                WindowTabs model = window.Tabs;
                Guid? selected = model.SelectedTabId;
                var walked = new WalkWindow
                {
                    Workspace = window.Workspace?.Key,
                    WorkspaceWindowId = window.Workspace is null ? null : window.WindowId,
                    SelectedIndex = model.SelectedIndex,
                    SelectedTitle = model.SelectedIndex is { } index ? model.Tabs[index].Title : null,
                    Tabs = [.. model.Tabs.Select((tab, index) => new WalkTab
                    {
                        Index = index,
                        Title = tab.Title,
                        Path = tab.Path,
                        Alias = tab.Alias,
                        Emoji = tab.Emoji,
                        IconColor = tab.IconColor,
                        Pinned = tab.Pinned,
                        Popped = tab.Archived,
                        Missing = tab.IsMissing,
                        GroupId = tab.GroupId,
                        RepoKey = tab.RepoKey,
                        Selected = tab.Id == selected,
                    })],
                    Groups = [.. model.ManualGroups.Select(run => new WalkGroup
                    {
                        Id = run.Group.Id,
                        Name = run.Group.Name,
                        Color = run.Group.ColorIndex,
                        Collapsed = run.Group.Collapsed,
                        First = run.First,
                        Last = run.Last,
                    })],
                    WorktreeBoxes = [.. model.WorktreeBoxes.Select(box => new WalkBox
                    {
                        Key = box.Key,
                        First = box.First,
                        Last = box.Last,
                    })],
                    Archived = [.. model.ArchivedTabs.Select(WalkSavedTab.Of)],
                    ClosedGroups = [.. model.ClosedGroups.Select(group => new WalkClosedGroup
                    {
                        Id = group.Id,
                        Name = group.Name,
                        Color = group.Color,
                        Tabs = [.. group.Tabs.Select(WalkSavedTab.Of)],
                    })],
                };
                // Groups in the table with no tab run (none should be) still show, after the runs.
                var runs = walked.Groups.Select(group => group.Id).ToHashSet();
                walked.Groups.AddRange(model.Groups
                    .Where(group => !runs.Contains(group.Id))
                    .OrderBy(group => group.Id)
                    .Select(group => new WalkGroup
                    {
                        Id = group.Id,
                        Name = group.Name,
                        Color = group.ColorIndex,
                        Collapsed = group.Collapsed,
                    }));
                return walked;
            }
        }

        private sealed class WalkTab
        {
            public int Index { get; set; }
            public string Title { get; set; } = string.Empty;
            public string? Path { get; set; }
            public string? Alias { get; set; }
            public string? Emoji { get; set; }
            public int? IconColor { get; set; }
            public bool Pinned { get; set; }

            /// <summary>The archived tab popped out (the last tab).</summary>
            public bool Popped { get; set; }

            /// <summary>Shows "Repo not found".</summary>
            public bool Missing { get; set; }

            public Guid? GroupId { get; set; }
            public string? RepoKey { get; set; }
            public bool Selected { get; set; }
        }

        private sealed class WalkGroup
        {
            public Guid Id { get; set; }
            public string? Name { get; set; }
            public int Color { get; set; }
            public bool Collapsed { get; set; }

            /// <summary>The group's tab run (indices into the window's tabs); null for a group with no run.</summary>
            public int? First { get; set; }

            public int? Last { get; set; }
        }

        private sealed class WalkBox
        {
            public string Key { get; set; } = string.Empty;
            public int First { get; set; }
            public int Last { get; set; }
        }

        private sealed class WalkSavedTab
        {
            public string Title { get; set; } = string.Empty;
            public string? Path { get; set; }
            public string? Alias { get; set; }
            public string? Emoji { get; set; }
            public string? Icon { get; set; }
            public int? IconColor { get; set; }

            public static WalkSavedTab Of(SavedTab tab) => new()
            {
                Title = tab.Title,
                Path = tab.Path,
                Alias = tab.Alias,
                Emoji = tab.Emoji,
                Icon = tab.Icon,
                IconColor = tab.IconColor,
            };
        }

        private sealed class WalkClosedGroup
        {
            public Guid Id { get; set; }
            public string? Name { get; set; }
            public int Color { get; set; }
            public List<WalkSavedTab> Tabs { get; set; } = [];
        }

        /// <summary>movetab.json.</summary>
        private sealed class MoveProbe
        {
            public bool Ok { get; set; }
            public string? Error { get; set; }

            /// <summary>The flag's value as given.</summary>
            public string? Value { get; set; }

            public string? Tab { get; set; }
            public bool Moved { get; set; }

            /// <summary>Why the move was refused (<see cref="WindowManager.MoveRefusal"/>); null when it was not.</summary>
            public string? Refusal { get; set; }

            /// <summary>The open windows after the move (an emptied source window has closed).</summary>
            public int? WindowCount { get; set; }
        }

        /// <summary>tabclick.json.</summary>
        private sealed class ClickProbe
        {
            public bool Ok { get; set; }
            public string? Error { get; set; }

            /// <summary>The titles clicked, in order.</summary>
            public List<string>? Visits { get; set; }

            public string? TabPosition { get; set; }

            /// <summary><see cref="WindowTabs.KeptLayouts"/>.</summary>
            public int? KeptLayouts { get; set; }

            /// <summary>The tab selected before the first click.</summary>
            public string? StartSelected { get; set; }

            /// <summary>The tabs whose repo layout was mounted before the first click.</summary>
            public List<string>? StartMounted { get; set; }

            public List<ClickSwitch> Switches { get; set; } = [];

            /// <summary>The repo layouts mounted in the window after the last switch.</summary>
            public int? MountedLayouts { get; set; }
        }

        private sealed class ClickSwitch
        {
            /// <summary>1 for the first click.</summary>
            public int Step { get; set; }

            public string Title { get; set; } = string.Empty;

            /// <summary>The tab was already selected before the click.</summary>
            public bool WasSelected { get; set; }

            /// <summary>The tab's content was mounted before the click (a kept layout).</summary>
            public bool WasMounted { get; set; }

            /// <summary>"repo", "missing", "welcome" or "none" after the switch.</summary>
            public string Content { get; set; } = string.Empty;

            /// <summary>Frames until the tab's view shows it selected (1: the first frame after the click).</summary>
            public int? ClickToHighlightFrames { get; set; }

            /// <summary>Frames until the tab's content shows (a repo layout without its placeholder).</summary>
            public int? ClickToShownFrames { get; set; }

            /// <summary>Frames drawn with the tab's repo layout visible and its graph placeholder up.</summary>
            public int PlaceholderFrames { get; set; }

            /// <summary>The graph placeholder was up right after the click's update (before any frame).</summary>
            public bool PlaceholderAtClick { get; set; }

            public double? ClickToShownMs { get; set; }

            /// <summary>The frames counted for this switch.</summary>
            public int Frames { get; set; }

            /// <summary>The repo layout shows its load's error instead of the graph.</summary>
            public bool LoadFailed { get; set; }

            public bool Selected { get; set; }
            public bool TimedOut { get; set; }

            /// <summary>The repo layouts mounted in the window after the switch.</summary>
            public int MountedLayouts { get; set; }
        }
    }

    /// <summary>
    /// <c>-HistqRowClickProbe auto|row,row,...|sidebar|sidebar:ref,ref,...</c> (QA builds only; give it a value, or put
    /// it last or before another flag: launch flags are <c>-Name value</c> pairs, so a bare flag before a positional
    /// folder would take the folder as its value): once the launch's windows, folders and workspace flags
    /// are open and the tabs' checks applied, waits (at most 60 s) until the front window's selected tab is a repo
    /// layout whose log is complete, then clicks graph rows one after another through the pointer press's own path
    /// (<see cref="GraphCanvas.PressRow"/>: the focus, then the selection drawn in the same frame): the listed row indices
    /// (0 = the top row; a row off screen is scrolled into view first, not clicked there), or with <c>auto</c> (or no
    /// value) the first 8 commit rows wholly on screen. Each click is measured in CompositionTarget.Rendering frames (the first after the click is
    /// frame 1): <c>clickToHighlightFrames</c> (the frame whose graph draw shows the row selected),
    /// <c>placeholderFrames</c> (frames the detail's placeholder was up), <c>summaryFrames</c> and <c>summaryMs</c> (until
    /// the summary shows), with <c>meetsCriteria</c> (highlight &lt;= 1 frame, placeholder &lt;= 1 frame, summary &lt;=
    /// 300 ms). Written to <c>&lt;stateDir&gt;\Probes\rowclick.json</c> (<c>ok</c>, <c>error</c>, <c>clicks</c>,
    /// <c>allMeetCriteria</c>); then the process quits as File › Exit saves (<see cref="WindowManager.QaQuit"/>) and exits
    /// 0, or 1 when the run failed, or 3 when it is not done in 3 minutes. Use it alone (not with the tab probes, which
    /// exit on their own).
    /// <para>
    /// Sidebar mode, <c>sidebar</c> or <c>sidebar:ref,ref,...</c>: once the sidebar has the refs too, clicks sidebar ref
    /// rows one after another through the row's own click path (<see cref="SidebarView.Click"/>, which a pointer's or the
    /// keyboard's ItemClick calls: the row selected, then the layout's reveal), after showing the row's tab and opening
    /// its card when needed (not measured). The refs are short names (<c>main</c>, <c>origin/main</c>, <c>v1.0</c>; a
    /// local branch first, then a remote branch, then a tag of that name) or full ref names (<c>refs/tags/v1.0</c>);
    /// without a list, the Local, Remote and Tags cards' rows in that order, one per graph row, at most 8. Each click is
    /// measured as above against the graph row the click reveals (the same resolution as the layout's: the checked-out
    /// branch's WIP row when it has changes, another worktree's row, else the commit), and each click also records
    /// <c>ref</c> (the full ref name). Here <c>meetsCriteria</c> is <c>clickToHighlightFrames</c> &lt;= 1 only (the graph
    /// draws the ref's row selected in the first frame); the placeholder and summary fields are recorded as well.
    /// rowclick.json then also has <c>mode</c> ("sidebar"; "graph" otherwise) and <c>refs</c> (the refs clicked).
    /// </para>
    /// </summary>
    internal sealed class QaRowClickProbe
    {
        private const string Flag = "-HistqRowClickProbe";

        /// <summary>The rows clicked without a list: the first commit rows on screen.</summary>
        private const int DefaultClicks = 8;

        /// <summary>Frames waited before the first click and after each one.</summary>
        private const int QuietFrames = 10;

        private static readonly TimeSpan SettleLimit = TimeSpan.FromSeconds(10);
        private static readonly TimeSpan LoadLimit = TimeSpan.FromSeconds(60);
        private static readonly TimeSpan ClickLimit = TimeSpan.FromSeconds(10);
        private static readonly TimeSpan Watchdog = TimeSpan.FromMinutes(3);

        private const string SidebarMode = "sidebar";

        private readonly Lock _gate = new();
        private readonly string _rows;

        /// <summary>Sidebar mode: <see cref="_rows"/> then lists refs.</summary>
        private readonly bool _sidebar;
        private readonly RowClickResult _result = new();
        private string _path = string.Empty;
        private int _finished;

        private QaRowClickProbe(string rows, bool sidebar)
        {
            _rows = rows;
            _sidebar = sidebar;
            _result.Mode = sidebar ? SidebarMode : "graph";
        }

        /// <summary>The probe when <paramref name="arguments"/> hold the flag (its value optional); else null.</summary>
        public static QaRowClickProbe? Read(IReadOnlyList<string> arguments)
        {
            int at = arguments.ToList().IndexOf(Flag);
            if (at < 0)
                return null;
            string value = at + 1 < arguments.Count && !arguments[at + 1].StartsWith('-') ? arguments[at + 1].Trim() : "";
            if (value.StartsWith(SidebarMode, StringComparison.OrdinalIgnoreCase)
                && (value.Length == SidebarMode.Length || value[SidebarMode.Length] == ':'))
            {
                return new QaRowClickProbe(value.Length > SidebarMode.Length ? value[(SidebarMode.Length + 1)..] : "", true);
            }

            return new QaRowClickProbe(string.Equals(value, "auto", StringComparison.OrdinalIgnoreCase) ? "" : value, false);
        }

        /// <summary>Runs the probe once <paramref name="ready"/> (never faulting) ends. Call it on the UI thread.</summary>
        public void Start(WindowManager windows, Task ready, StatePaths paths)
        {
            _path = Path.Combine(paths.Root, "Probes", "rowclick.json");
            _ = Task.Delay(Watchdog).ContinueWith(
                _ => Finish($"watchdog: the run did not finish in {Watchdog.TotalMinutes} minutes", 3),
                TaskScheduler.Default);
            Application.Current.UnhandledException += (_, e) => Finish(e.Exception.ToString(), 1);
            _ = RunAsync(windows, ready);
        }

        private async Task RunAsync(WindowManager windows, Task ready)
        {
            string? failure;
            try
            {
                // Resumes on the UI thread (its SynchronizationContext), as every await below.
                await ready;
                await windows.QaSettleAsync(SettleLimit);
                failure = await ClickAsync(windows);
            }
            catch (Exception error)
            {
                failure = error.ToString();
            }

            windows.QaQuit();
            if (await Task.Run(() => Record(failure)))
                Environment.Exit(failure is null ? 0 : 1);
        }

        /// <summary>Clicks the rows and measures each click; the error, else null.</summary>
        private async Task<string?> ClickAsync(WindowManager windows)
        {
            var clock = Stopwatch.StartNew();
            RepoLayoutView? layout = null;
            while (clock.Elapsed < LoadLimit)
            {
                if (windows.Windows.Count > 0 && windows.Windows[0] is { } window
                    && window.QaContentHost.QaShownLayout(window.Tabs) is { } shown
                    && (shown.QaLoadFailed || shown.QaGraph.Data?.Snapshot.IsComplete == true))
                {
                    layout = shown;
                    lock (_gate)
                        _result.Tab = window.Tabs.SelectedIndex is { } index ? window.Tabs.Tabs[index].Title : null;
                    break;
                }

                await Task.Delay(100);
            }

            if (layout is null)
                return $"no repo tab with a complete log was shown within {LoadLimit.TotalSeconds} s";
            if (layout.QaLoadFailed)
                return "the repo tab's graph load failed";

            GraphView graph = layout.QaGraph;
            GraphCanvas canvas = graph.Canvas;
            if (_sidebar)
                return await SidebarClickAsync(layout, graph);
            await QaTabProbes.FramesAsync(QuietFrames);
            List<long> rows;
            if (_rows.Length > 0)
            {
                rows = [];
                foreach (string part in _rows.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
                {
                    if (!long.TryParse(part, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out long row)
                        || row >= canvas.RowCount)
                    {
                        return $"{Flag}: \"{part}\" is not a row of the graph (0 to {canvas.RowCount - 1})";
                    }

                    rows.Add(row);
                }
            }
            else
            {
                rows = [];
                for (long row = canvas.FirstVisibleRow; row >= 0 && row <= canvas.LastVisibleRow && rows.Count < DefaultClicks; row++)
                {
                    if (graph.ItemAt(row) is { Kind: GraphItemKind.Commit } && canvas.TopOfRow(row) >= 0
                        && canvas.TopOfRow(row) + canvas.RowHeight <= canvas.ViewportHeight)
                    {
                        rows.Add(row);
                    }
                }
            }

            if (rows.Count == 0)
                return "no commit row on screen to click";
            lock (_gate)
                _result.Rows = [.. rows];

            for (int step = 0; step < rows.Count; step++)
            {
                long row = rows[step];
                if (canvas.TopOfRow(row) < 0 || canvas.TopOfRow(row) + canvas.RowHeight > canvas.ViewportHeight)
                {
                    canvas.ScrollIntoView(row);
                    await QaTabProbes.FramesAsync(QuietFrames);
                }

                RowClick click = await MeasureAsync(layout, graph, row, step + 1, () => canvas.PressRow(row), false);
                lock (_gate)
                    _result.Clicks.Add(click);
                if (click.TimedOut)
                    return $"row {row} (step {step + 1}): the selection or the summary did not show within {ClickLimit.TotalSeconds} s";
                await QaTabProbes.FramesAsync(QuietFrames);
            }

            lock (_gate)
            {
                _result.AllMeetCriteria = _result.Clicks.All(click => click.MeetsCriteria);
                _result.Ok = true;
            }

            return null;
        }

        /// <summary>
        /// Clicks the sidebar's refs (sidebar mode) and measures each click against the graph row it reveals; the error,
        /// else null.
        /// </summary>
        private async Task<string?> SidebarClickAsync(RepoLayoutView layout, GraphView graph)
        {
            SidebarView sidebar = layout.QaSidebar;
            var clock = Stopwatch.StartNew();
            while (!sidebar.QaHasRefs && clock.Elapsed < LoadLimit)
                await Task.Delay(100);
            if (!sidebar.QaHasRefs)
                return $"the sidebar had no refs within {LoadLimit.TotalSeconds} s";
            await QaTabProbes.FramesAsync(QuietFrames);

            var rows = new List<SidebarRow>();
            if (_rows.Length > 0)
            {
                foreach (string name in _rows.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
                {
                    if (sidebar.QaFind(name) is not { } found)
                        return $"{Flag}: \"{name}\" is not a local branch, remote branch or tag in the sidebar";
                    rows.Add(found);
                }
            }
            else
            {
                // One click per graph row: refs on the same commit (main and origin/main) reveal the same row.
                var targets = new HashSet<long>();
                foreach (SidebarRow row in sidebar.QaRefRows())
                {
                    if (rows.Count >= DefaultClicks)
                        break;
                    if (layout.QaTargetRow(row) is >= 0 and var target && targets.Add(target))
                        rows.Add(row);
                }
            }

            if (rows.Count == 0)
                return "no sidebar ref with a graph row to click";
            lock (_gate)
                _result.Refs = [.. rows.Select(row => row.Key)];

            var revealed = new List<long>();
            for (int step = 0; step < rows.Count; step++)
            {
                SidebarRow row = rows[step];
                if (sidebar.QaPrepare(row))
                    await QaTabProbes.FramesAsync(QuietFrames);
                long target = layout.QaTargetRow(row);
                if (target < 0)
                    return $"{row.Key} (step {step + 1}): its commit has no row in the graph";
                revealed.Add(target);
                lock (_gate)
                    _result.Rows = [.. revealed];

                RowClick click = await MeasureAsync(layout, graph, target, step + 1, () => sidebar.Click(row), true);
                click.Ref = row.Key;
                lock (_gate)
                    _result.Clicks.Add(click);
                if (click.TimedOut)
                    return $"{row.Key} (step {step + 1}): the graph row {target} or the summary did not show within {ClickLimit.TotalSeconds} s";
                await QaTabProbes.FramesAsync(QuietFrames);
            }

            lock (_gate)
            {
                _result.AllMeetCriteria = _result.Clicks.All(click => click.MeetsCriteria);
                _result.Ok = true;
            }

            return null;
        }

        /// <summary>
        /// Clicks (<paramref name="press"/>: a graph row's pointer press, a sidebar row's click) and counts the frames
        /// until the graph has drawn <paramref name="row"/> selected and until the detail shows its summary, and the
        /// frames its placeholder was up. The handlers only read. <paramref name="highlightOnly"/>: the criteria are the
        /// highlight's only (sidebar mode).
        /// </summary>
        private static async Task<RowClick> MeasureAsync(
            RepoLayoutView layout, GraphView graph, long row, int step, Action press, bool highlightOnly)
        {
            GraphCanvas canvas = graph.Canvas;
            CommitSummaryView summary = layout.QaSummary;
            var result = new RowClick
            {
                Step = step,
                Row = row,
                Item = graph.ItemAt(row) is { } item ? $"{item.Kind}:{item.Id}" : null,
                WasSelected = canvas.SelectedRow == row,
            };
            var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            TimeSpan? previous = null;
            int frames = 0;
            int placeholder = 0;
            int? highlight = null;
            int? shown = null;
            var clock = new Stopwatch();

            void OnDrawn(object? sender, GraphDrawInfo info)
            {
                if (highlight is null && info.SelectedRow == row)
                    highlight = Math.Max(1, frames);
                if (highlight is not null && shown is not null)
                    done.TrySetResult();
            }

            void OnRendering(object? sender, object e)
            {
                try
                {
                    // Rendering can be raised more than once per frame, with the same time.
                    if (e is not RenderingEventArgs args || args.RenderingTime == previous)
                        return;
                    previous = args.RenderingTime;
                    frames++;
                    // An already selected row is not drawn again: its highlight is the state. Its detail is not
                    // reloaded either: the summary already shows, so its placeholder frames are measured as 0.
                    if (highlight is null && result.WasSelected && canvas.SelectedRow == row)
                        highlight = frames;
                    if (shown is null)
                    {
                        if (summary.QaShowsSummary)
                        {
                            shown = frames;
                            result.SummaryMs = Math.Round(clock.Elapsed.TotalMilliseconds, 1);
                        }
                        else if (summary.QaShowsPlaceholder)
                        {
                            placeholder++;
                        }
                    }

                    if (highlight is not null && shown is not null)
                        done.TrySetResult();
                }
                catch (Exception error)
                {
                    done.TrySetException(error);
                }
            }

            CompositionTarget.Rendering += OnRendering;
            canvas.DrawCompleted += OnDrawn;
            try
            {
                clock.Start();
                press();
                result.PlaceholderAtClick = summary.QaShowsPlaceholder;
                await Task.WhenAny(done.Task, Task.Delay(ClickLimit));
            }
            finally
            {
                CompositionTarget.Rendering -= OnRendering;
                canvas.DrawCompleted -= OnDrawn;
            }

            if (done.Task.IsFaulted)
                throw done.Task.Exception!.InnerException ?? done.Task.Exception;

            result.ClickToHighlightFrames = highlight;
            result.PlaceholderFrames = placeholder;
            result.SummaryFrames = shown;
            result.Frames = frames;
            result.Selected = canvas.SelectedRow == row;
            result.TimedOut = highlight is null || shown is null;
            result.MeetsCriteria = !result.TimedOut && highlight <= 1
                && (highlightOnly || (placeholder <= 1 && result.SummaryMs <= 300));
            return result;
        }

        private void Finish(string error, int code)
        {
            if (Record(error))
                Environment.Exit(code);
        }

        /// <summary>Writes rowclick.json once (the first call, which then exits). Any thread.</summary>
        private bool Record(string? error)
        {
            if (Interlocked.Exchange(ref _finished, 1) == 1)
                return false;
            lock (_gate)
            {
                if (error is not null)
                {
                    _result.Ok = false;
                    _result.Error ??= error;
                }

                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                    File.WriteAllText(_path, JsonSerializer.Serialize(_result, QaFlags.JsonOptions));
                }
                catch (Exception failure)
                {
                    Trace.WriteLine($"Histq: rowclick.json not written: {failure.Message}");
                }
            }

            return true;
        }

        /// <summary>rowclick.json.</summary>
        private sealed class RowClickResult
        {
            public bool Ok { get; set; }
            public string? Error { get; set; }

            /// <summary>"graph", or "sidebar" (sidebar ref clicks).</summary>
            public string? Mode { get; set; }

            /// <summary>The selected tab's title.</summary>
            public string? Tab { get; set; }

            /// <summary>The rows clicked, in order (sidebar mode: the graph rows the clicks revealed).</summary>
            public List<long>? Rows { get; set; }

            /// <summary>Sidebar mode: the refs clicked, in order (full ref names).</summary>
            public List<string>? Refs { get; set; }

            public List<RowClick> Clicks { get; set; } = [];

            /// <summary>Every click met the plan's criteria; null when the run did not end.</summary>
            public bool? AllMeetCriteria { get; set; }
        }

        private sealed class RowClick
        {
            /// <summary>1 for the first click.</summary>
            public int Step { get; set; }

            public long Row { get; set; }

            /// <summary>The row's item: "Commit:&lt;sha&gt;", "Stash:&lt;sha&gt;", "Wip:wip", "Worktree:&lt;path&gt;".</summary>
            public string? Item { get; set; }

            /// <summary>Sidebar mode: the ref clicked (full ref name).</summary>
            public string? Ref { get; set; }

            /// <summary>The row was already selected before the click.</summary>
            public bool WasSelected { get; set; }

            /// <summary>The frame whose graph draw first showed the row selected (1: the first after the click).</summary>
            public int? ClickToHighlightFrames { get; set; }

            /// <summary>The detail's placeholder was up right after the click's own update (before any frame).</summary>
            public bool PlaceholderAtClick { get; set; }

            /// <summary>Frames drawn with the detail's placeholder up.</summary>
            public int PlaceholderFrames { get; set; }

            /// <summary>The frame the summary first showed in.</summary>
            public int? SummaryFrames { get; set; }

            /// <summary>From the click to the frame the summary showed in.</summary>
            public double? SummaryMs { get; set; }

            public int Frames { get; set; }
            public bool Selected { get; set; }
            public bool TimedOut { get; set; }

            /// <summary>clickToHighlightFrames &lt;= 1, placeholderFrames &lt;= 1, summaryMs &lt;= 300; sidebar mode:
            /// clickToHighlightFrames &lt;= 1 only.</summary>
            public bool MeetsCriteria { get; set; }
        }
    }

    /// <summary>
    /// The repo tab flags (QA builds only), on the front window's shown repo tab (the <c>-HistqOpen</c> folder's). Every
    /// flag takes a value (launch flags are <c>-Name value</c> pairs: a bare flag before a positional folder would take
    /// the folder as its value):
    /// <list type="bullet">
    /// <item><c>-HistqFind "&lt;query&gt;[;next|prev…]"</c>: once the log is complete, the graph search opens as Ctrl+F
    /// does with that query, then each step runs 300 ms apart (for screenshots; the app stays up unless a probe below
    /// runs).</item>
    /// <item><c>-HistqShowHidden YES</c>: the Local, Remote and Tags cards list their hidden rows, as their eye buttons
    /// do (as the Mac's flag; the graph's view is unchanged).</item>
    /// <item><c>-HistqLoadProbe YES</c>: <c>Probes\load.json</c>: <c>firstRowsMs</c> (process start to the first draw
    /// with rows), <c>fullLoadMs</c> (to the first draw of the complete log), <c>commits</c>, <c>rows</c>,
    /// <c>dataBeforeHook</c> (the graph had its rows when the probe hooked it on the first frame its layout existed: a
    /// draw before that frame, if any, is missed and the times are late), and the breakdown, each in ms
    /// from process start (<see cref="QaTimeline"/>; null when the step did not happen): <c>onLaunchedMs</c>,
    /// <c>windowFirstFrameMs</c>, <c>sessionStartMs</c>, <c>gitResolvedMs</c>, <c>readEnvMs</c>, <c>loaderEnvMs</c>,
    /// <c>stashesMs</c>, <c>logSpawnMs</c>, <c>firstPageParsedMs</c>, <c>statusMs</c>, <c>firstPagePostedMs</c>.</item>
    /// <item><c>-HistqRowsProbe &lt;n&gt;|auto</c> (auto: 50): <c>Probes\rows.json</c>: the complete log's first n
    /// commits (no WIP or stash row) as <c>hash</c>, <c>parents</c> (in order) and <c>refs</c> (sorted full ref names at
    /// the commit: local and remote branches, tags at their peeled commit, <c>HEAD</c> when detached there), what
    /// <c>windows/scripts/qa-data.sh check-rows</c> compares with git log.</item>
    /// <item><c>-HistqScrollProbe &lt;seconds&gt;</c> (without <c>-HistqSpikeLog</c>; <c>-HistqScrollPacing
    /// draw|rendering</c>, default draw): the spike's scroll probe on the repo graph (<see
    /// cref="SpikeHarness.RepoScrollProbeAsync"/>), from its top: <c>Probes\scroll.json</c> in spike.json's fields,
    /// checked by <c>qa-data.sh check-scroll</c> (median 17.5, p95 33.4, max 100, draw p95 8 ms).</item>
    /// <item><c>-HistqWatchProbe YES</c>: once the repo is watched, the app runs <c>git commit --allow-empty
    /// --no-verify -m &lt;marker&gt;</c> in it (GitRunner, the process job, the base environment with a QA identity:
    /// a write, QA only), with the graph at its top: <c>Probes\watch.json</c>: <c>commitMs</c> (the git run),
    /// <c>appearMs</c> (from git's exit to the first draw showing the new commit's row; 0 when drawn first),
    /// <c>meetsCriteria</c> (appearMs &lt;= 1000).</item>
    /// </list>
    /// The probes run in that order (load, rows, scroll, watch) once the log is complete; each writes its file (with
    /// <c>ok</c> and <c>error</c>; scroll.json only <c>error</c> on failure). With any probe the process then quits as
    /// File › Exit saves (<see cref="WindowManager.QaQuit"/>) and exits 0, 1 when one failed, 3 when not done in 15
    /// minutes.
    /// </summary>
    internal sealed class QaRepoProbes
    {
        private const string FindFlag = "-HistqFind";
        private const string ShowHiddenFlag = "-HistqShowHidden";
        private const string ScrollFlag = "-HistqScrollProbe";
        private const string SpikeLogFlag = "-HistqSpikeLog";
        private const string PacingFlag = "-HistqScrollPacing";
        private const string RowsFlag = "-HistqRowsProbe";
        private const string LoadFlag = "-HistqLoadProbe";
        private const string WatchFlag = "-HistqWatchProbe";
        private const int DefaultRows = 50;
        private const int QuietFrames = 10;

        private static readonly TimeSpan SettleLimit = TimeSpan.FromSeconds(10);
        private static readonly TimeSpan LoadLimit = TimeSpan.FromMinutes(5);
        private static readonly TimeSpan WatchLimit = TimeSpan.FromSeconds(30);
        private static readonly TimeSpan Watchdog = TimeSpan.FromMinutes(15);

        private readonly string? _find;
        private readonly bool _showHidden;
        private readonly double? _scrollSeconds;
        private readonly bool _drawPacing;
        private readonly int? _rows;
        private readonly bool _load;
        private readonly bool _watch;

        /// <summary>An unknown <c>-HistqScrollPacing</c>: the scroll probe fails with it (exit 1).</summary>
        private string? _pacingError;

        private readonly Lock _gate = new();

        /// <summary>The probe files not written yet, by name (a failure writes its error to each).</summary>
        private readonly HashSet<string> _pending = new(StringComparer.Ordinal);
        private readonly TaskCompletionSource<LoadResult> _loaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private string _folder = string.Empty;
        private int _finished;

        private QaRepoProbes(
            string? find, bool showHidden, double? scrollSeconds, bool drawPacing, int? rows, bool load, bool watch)
        {
            (_find, _showHidden, _scrollSeconds, _drawPacing, _rows, _load, _watch) =
                (find, showHidden, scrollSeconds, drawPacing, rows, load, watch);
        }

        private bool Exits => _load || _rows is not null || _scrollSeconds is not null || _watch;

        /// <summary>The flags of <paramref name="arguments"/>; null without any. A row count that is not a positive
        /// number reads as 50; a pacing other than draw or rendering fails the scroll probe.</summary>
        public static QaRepoProbes? Read(IReadOnlyList<string> arguments)
        {
            var flags = new LaunchFlags(arguments);
            static bool Yes(string? value) => string.Equals(value, "YES", StringComparison.OrdinalIgnoreCase);
            string? find = QaFlags.NonEmpty(flags.String(FindFlag));
            double? scroll = flags.String(SpikeLogFlag) is null && flags.Double(ScrollFlag) is > 0 and var seconds
                ? seconds
                : null;
            string? pacing = flags.String(PacingFlag);
            bool drawPacing = !string.Equals(pacing, "rendering", StringComparison.Ordinal);
            string? pacingError = pacing is null or "draw" or "rendering"
                ? null
                : $"{PacingFlag} must be rendering or draw, not '{pacing}'";
            int? rows = flags.String(RowsFlag) is null ? null : flags.Int(RowsFlag) is > 0 and var count ? count : DefaultRows;
            var probes = new QaRepoProbes(
                find, Yes(flags.String(ShowHiddenFlag)), scroll, drawPacing, rows, Yes(flags.String(LoadFlag)),
                Yes(flags.String(WatchFlag)))
            {
                _pacingError = pacingError,
            };
            return find is null && !probes._showHidden && !probes.Exits ? null : probes;
        }

        /// <summary>Runs the flags once <paramref name="ready"/> (never faulting) ends; the load probe watches the graph
        /// from now. Call it on the UI thread right after the windows open.</summary>
        public void Start(WindowManager windows, Task ready, StatePaths paths)
        {
            _folder = Path.Combine(paths.Root, "Probes");
            if (_load)
                _pending.Add("load.json");
            if (_rows is not null)
                _pending.Add("rows.json");
            if (_scrollSeconds is not null)
                _pending.Add("scroll.json");
            if (_watch)
                _pending.Add("watch.json");
            if (Exits)
            {
                _ = Task.Delay(Watchdog).ContinueWith(
                    _ => Finish(windows, $"watchdog: the run did not finish in {Watchdog.TotalMinutes} minutes", 3),
                    TaskScheduler.Default);
                Application.Current.UnhandledException += (_, e) => Finish(windows, e.Exception.ToString(), 1);
            }

            if (_load)
                WatchLoad(windows);
            _ = RunAsync(windows, ready);
        }

        private static double SinceLaunchMs() => QaTimeline.Now();

        /// <summary>The load probe: hooks the shown repo tab's graph on the first frame it exists, then records its first
        /// draw with rows and its first draw of the complete log.</summary>
        private void WatchLoad(WindowManager windows)
        {
            var result = new LoadResult();
            GraphView? graph = null;
            TimeSpan? previous = null;

            void OnDrawn(object? sender, GraphDrawInfo info)
            {
                if (graph?.Data is not { } data || info.FirstRow < 0)
                    return;
                result.FirstRowsMs ??= SinceLaunchMs();
                if (!data.Snapshot.IsComplete)
                    return;
                result.FullLoadMs = SinceLaunchMs();
                result.Commits = data.Snapshot.Commits.Count;
                result.Rows = data.Snapshot.RowCount;
                graph.Canvas.DrawCompleted -= OnDrawn;
                _loaded.TrySetResult(result);
            }

            void OnRendering(object? sender, object e)
            {
                if (e is not RenderingEventArgs args || args.RenderingTime == previous)
                    return;
                previous = args.RenderingTime;
                if (graph is not null)
                {
                    CompositionTarget.Rendering -= OnRendering;
                    return;
                }

                if (windows.Windows.Count == 0 || windows.Windows[0].QaContentHost.QaShownLayout(windows.Windows[0].Tabs)
                    is not { } layout)
                {
                    return;
                }

                graph = layout.QaGraph;
                result.DataBeforeHook = graph.Data is not null;
                graph.Canvas.DrawCompleted += OnDrawn;
                CompositionTarget.Rendering -= OnRendering;
            }

            CompositionTarget.Rendering += OnRendering;
        }

        private async Task RunAsync(WindowManager windows, Task ready)
        {
            string? failure = null;
            try
            {
                await ready;
                await windows.QaSettleAsync(SettleLimit);
                RepoLayoutView layout = await CompleteLayoutAsync(windows);
                if (_showHidden)
                    layout.QaSidebar.QaShowHidden();
                if (_find is not null)
                    await FindAsync(layout, _find);
                if (!Exits)
                    return;
                if (_load)
                {
                    if (await Task.WhenAny(_loaded.Task, Task.Delay(LoadLimit)) != _loaded.Task)
                        throw new TimeoutException($"the load probe saw no complete draw within {LoadLimit.TotalMinutes} minutes");
                    LoadResult load = await _loaded.Task;
                    load.Ok = true;
                    load.OnLaunchedMs = QaTimeline.At("onLaunched");
                    load.WindowFirstFrameMs = QaTimeline.At("windowFirstFrame");
                    load.SessionStartMs = QaTimeline.At("sessionStart");
                    load.GitResolvedMs = QaTimeline.At("gitResolved");
                    load.ReadEnvMs = QaTimeline.At("readEnv");
                    load.LoaderEnvMs = QaTimeline.At("loaderEnv");
                    load.StashesMs = QaTimeline.At("stashes");
                    load.LogSpawnMs = QaTimeline.At("logSpawn");
                    load.FirstPageParsedMs = QaTimeline.At("firstPageParsed");
                    load.StatusMs = QaTimeline.At("status");
                    load.FirstPagePostedMs = QaTimeline.At("firstPagePosted");
                    Write("load.json", load);
                }

                if (_rows is { } count)
                    Write("rows.json", Rows(layout, count));
                if (_scrollSeconds is { } seconds)
                {
                    if (_pacingError is { } pacingError)
                        throw new ArgumentException(pacingError);
                    GraphCanvas canvas = layout.QaGraph.Canvas;
                    canvas.ScrollToRow(0);
                    await QaTabProbes.FramesAsync(QuietFrames);
                    string json = await SpikeHarness.RepoScrollProbeAsync(windows.Windows[0], canvas, seconds, _drawPacing);
                    WriteText("scroll.json", json);
                }

                if (_watch)
                    Write("watch.json", await WatchAsync(layout));
            }
            catch (Exception error)
            {
                failure = error.ToString();
            }

            if (!Exits)
            {
                if (failure is not null)
                    Trace.WriteLine($"Histq: repo QA flags failed: {failure}");
                return;
            }

            windows.QaQuit();
            Finish(windows, failure, failure is null ? 0 : 1);
        }

        /// <summary>The front window's shown repo layout once its log is complete; throws when it failed or never came.</summary>
        private static async Task<RepoLayoutView> CompleteLayoutAsync(WindowManager windows)
        {
            var clock = Stopwatch.StartNew();
            while (clock.Elapsed < LoadLimit)
            {
                if (windows.Windows.Count > 0 && windows.Windows[0] is { } window
                    && window.QaContentHost.QaShownLayout(window.Tabs) is { } layout)
                {
                    if (layout.QaLoadFailed)
                        throw new InvalidOperationException("the repo tab's graph load failed");
                    if (layout.QaGraph.Data?.Snapshot.IsComplete == true)
                        return layout;
                }

                await Task.Delay(50);
            }

            throw new TimeoutException($"no repo tab with a complete log was shown within {LoadLimit.TotalMinutes} minutes");
        }

        /// <summary><c>-HistqFind</c>: the search opens with the query, then its steps run 300 ms apart.</summary>
        private static async Task FindAsync(RepoLayoutView layout, string spec)
        {
            string[] parts = spec.Split(';');
            await QaTabProbes.FramesAsync(QuietFrames);
            layout.QaSearch.QaFind(parts[0]);
            foreach (string step in parts.Skip(1))
            {
                await Task.Delay(300);
                switch (step.Trim())
                {
                    case "next": layout.QaSearch.QaStep(next: true); break;
                    case "prev": layout.QaSearch.QaStep(next: false); break;
                    default: throw new ArgumentException($"{FindFlag}: unknown step '{step}' (next or prev)");
                }
            }
        }

        /// <summary>The complete log's first <paramref name="count"/> commits with their parents and the raw refs at
        /// each (full names, sorted).</summary>
        private static RowsResult Rows(RepoLayoutView layout, int count)
        {
            GraphData data = layout.QaGraph.Data ?? throw new InvalidOperationException("the graph has no data");
            var refsAt = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            void Add(string? commit, string refName)
            {
                if (commit is null)
                    return;
                if (!refsAt.TryGetValue(commit, out List<string>? list))
                    refsAt[commit] = list = [];
                list.Add(refName);
            }

            if (data.Refs is not { } refs)
                throw new InvalidOperationException("the refs were not read");
            foreach (LocalBranch branch in refs.LocalBranches)
                Add(branch.Commit, branch.RefName);
            foreach (RemoteBranch branch in refs.RemoteBranches)
                Add(branch.Commit, branch.RefName);
            foreach (TagRef tag in refs.Tags)
                Add(tag.Commit ?? tag.Target, tag.RefName);
            if (refs.Head is Head.Detached detached)
                Add(detached.Commit, "HEAD");

            List<RowProbe> rows = [.. data.Snapshot.Commits.Take(count).Select(commit => new RowProbe(
                commit.Hash, commit.Parents,
                [.. (refsAt.GetValueOrDefault(commit.Hash) ?? []).Order(StringComparer.Ordinal)]))];
            return new RowsResult { Ok = true, Count = rows.Count, Rows = rows };
        }

        /// <summary><c>-HistqWatchProbe</c>: an empty commit made by the app itself, then the time until its row is drawn.</summary>
        private static async Task<WatchResult> WatchAsync(RepoLayoutView layout)
        {
            RepoTabSession session = layout.QaSession;
            var clock = Stopwatch.StartNew();
            while (!session.QaWatching)
            {
                if (clock.Elapsed > WatchLimit)
                    throw new TimeoutException($"the repo was not watched within {WatchLimit.TotalSeconds} s");
                await Task.Delay(50);
            }

            if (session.QaGit is not ({ } runner, { } environment))
                throw new InvalidOperationException("the session has no git runner");
            GraphView graph = layout.QaGraph;
            graph.Canvas.ScrollToRow(0);
            await QaTabProbes.FramesAsync(QuietFrames);

            string marker = "histq-watch-probe " + Guid.NewGuid().ToString("N");
            var result = new WatchResult { Marker = marker };
            var shown = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var since = Stopwatch.StartNew();
            double? committedAt = null;

            void OnDrawn(object? sender, GraphDrawInfo info)
            {
                if (graph.Data is not { } data || info.FirstRow < 0)
                    return;
                Commit? commit = data.Snapshot.Commits.Take(64)
                    .FirstOrDefault(c => string.Equals(c.Subject, marker, StringComparison.Ordinal));
                if (commit is null)
                    return;
                long row = graph.RowOf(new GraphItem(GraphItemKind.Commit, commit.Hash));
                if (row < info.FirstRow || row > info.LastRow)
                    return;
                double now = since.Elapsed.TotalMilliseconds;
                result.AppearMs = Math.Round(committedAt is { } end ? Math.Max(0, now - end) : 0, 1);
                result.Hash = commit.Hash;
                shown.TrySetResult();
            }

            graph.Canvas.DrawCompleted += OnDrawn;
            try
            {
                string path = layout.QaPath;
                await Task.Run(() => runner.RunAsync(
                    ["-c", "user.name=Histq QA", "-c", "user.email=qa@histq.invalid", "-c", "commit.gpgSign=false",
                        // No auto-maintenance (gc, commit-graph) competing with the timed reload.
                        "-c", "maintenance.auto=false", "-c", "gc.auto=0",
                        "commit", "--allow-empty", "--no-verify", "-m", marker],
                    path, environment, timeout: WatchLimit));
                committedAt = since.Elapsed.TotalMilliseconds;
                result.CommitMs = Math.Round(committedAt.Value, 1);
                if (await Task.WhenAny(shown.Task, Task.Delay(WatchLimit)) != shown.Task)
                    throw new TimeoutException($"the new commit's row was not drawn within {WatchLimit.TotalSeconds} s");
            }
            finally
            {
                graph.Canvas.DrawCompleted -= OnDrawn;
            }

            result.Ok = true;
            result.MeetsCriteria = result.AppearMs <= 1000;
            return result;
        }

        private void Write<T>(string name, T result) => WriteText(name, JsonSerializer.Serialize(result, QaFlags.JsonOptions));

        private void WriteText(string name, string json)
        {
            lock (_gate)
            {
                Directory.CreateDirectory(_folder);
                File.WriteAllText(Path.Combine(_folder, name), json);
                _pending.Remove(name);
            }
        }

        /// <summary>Writes <paramref name="error"/> to every probe file not written yet, then exits with
        /// <paramref name="code"/>; once. Any thread.</summary>
        private void Finish(WindowManager windows, string? error, int code)
        {
            if (Interlocked.Exchange(ref _finished, 1) == 1)
                return;
            try
            {
                if (error is not null)
                {
                    string[] pending;
                    lock (_gate)
                        pending = [.. _pending];
                    foreach (string name in pending)
                        Write(name, new ProbeFailure { Error = error });
                }
            }
            catch (Exception failure)
            {
                Trace.WriteLine($"Histq: repo probe files not written: {failure.Message}");
            }

            Environment.Exit(code);
        }

        private sealed class ProbeFailure
        {
            public bool Ok { get; set; }
            public string? Error { get; set; }
        }

        private sealed class LoadResult
        {
            public bool Ok { get; set; }
            public double? FirstRowsMs { get; set; }
            public double? FullLoadMs { get; set; }
            public int Commits { get; set; }
            public long Rows { get; set; }
            public bool DataBeforeHook { get; set; }
            public double? OnLaunchedMs { get; set; }
            public double? WindowFirstFrameMs { get; set; }
            public double? SessionStartMs { get; set; }
            public double? GitResolvedMs { get; set; }
            public double? ReadEnvMs { get; set; }
            public double? LoaderEnvMs { get; set; }
            public double? StashesMs { get; set; }
            public double? LogSpawnMs { get; set; }
            public double? FirstPageParsedMs { get; set; }
            public double? StatusMs { get; set; }
            public double? FirstPagePostedMs { get; set; }
        }

        private sealed record RowProbe(string Hash, IReadOnlyList<string> Parents, IReadOnlyList<string> Refs);

        private sealed class RowsResult
        {
            public bool Ok { get; set; }
            public int Count { get; set; }
            public List<RowProbe> Rows { get; set; } = [];
        }

        private sealed class WatchResult
        {
            public bool Ok { get; set; }
            public string? Marker { get; set; }
            public string? Hash { get; set; }
            public double? CommitMs { get; set; }
            public double? AppearMs { get; set; }
            public bool MeetsCriteria { get; set; }
        }
    }

    /// <summary>A tab's content as the click probe reads it (<see cref="TabContentHost.QaState"/>).</summary>
    /// <param name="Kind">"repo", "missing", "welcome", or "none" when nothing is mounted for the tab.</param>
    /// <param name="Visible">The content is Visible (the selected tab's).</param>
    /// <param name="Placeholder">A repo layout whose graph placeholder is up.</param>
    /// <param name="Failed">A repo layout showing its load's error.</param>
    internal readonly record struct QaContentState(string Kind, bool Visible, bool Placeholder, bool Failed);

    /// <summary>What the tab probes read of a window (<see cref="QaTabProbes"/>).</summary>
    public sealed partial class MainWindow
    {
        /// <summary>The tabs view shown now, whose presses pick tabs: the vertical panel or the title bar's strip.</summary>
        internal ITabDragHost QaTabsHost =>
            TabPosition == TabPosition.Left ? VerticalTabs : AppTitleBar.TabStrip;

        /// <summary>The selected tab's area.</summary>
        internal TabContentHost QaContentHost => ContentHost;

        /// <summary>The shown tabs view draws the tab <paramref name="id"/> as selected.</summary>
        internal bool QaShowsSelected(Guid id) =>
            TabPosition == TabPosition.Left ? VerticalTabs.QaShowsSelected(id) : AppTitleBar.TabStrip.QaShowsSelected(id);
    }
}

namespace Histq.App.Shell
{
    /// <summary>The workspace commands as <see cref="QaFlags"/> drives them, through the same paths as the menus, with
    /// the outcome checked here (those paths report a failure only as a toast and a trace line).</summary>
    internal sealed partial class WindowManager
    {
        /// <summary>Opens the workspace file at <paramref name="path"/> as Open Workspace… does; the open workspace, or
        /// an exception saying why it did not open.</summary>
        internal async Task<WorkspaceDocument> QaOpenWorkspaceAsync(string path)
        {
            await OpenWorkspaceAsync(path, null);
            string key = await Task.Run(() => WorkspaceFile.IdentityKey(path));
            if (OpenWorkspaceAt(key) is { } workspace)
                return workspace;

            // The open reported only a toast: read the file again for the reason.
            string reason = await Task.Run(() =>
            {
                try
                {
                    WorkspaceDocument.Open(path);
                    return "it reads, but no window of it is open";
                }
                catch (Exception error)
                {
                    return Reason(error);
                }
            });
            throw new InvalidOperationException($"\"{path}\" did not open: {reason}");
        }

        /// <summary>Waits until no repo key read or folder check is pending (their results applied to the tabs); false
        /// when some still are after <paramref name="limit"/>.</summary>
        internal async Task<bool> QaSettleAsync(TimeSpan limit)
        {
            var clock = Stopwatch.StartNew();
            while (_pendingChecks > 0)
            {
                if (clock.Elapsed >= limit)
                    return false;
                // Resumes on the UI thread, where the checks apply their results.
                await Task.Delay(50);
            }

            return true;
        }

        /// <summary>
        /// Save Workspace As… to <paramref name="path"/> without a picker: <paramref name="workspace"/> (written there
        /// and rebound to it), else the front window's workspace, else every Untitled window joins a new workspace
        /// there. Throws when the workspace did not end up at <paramref name="path"/>.
        /// </summary>
        internal async Task QaSaveWorkspaceAsAsync(WorkspaceDocument? workspace, string path)
        {
            if (_windows.Count == 0)
                throw new InvalidOperationException("no window is open");
            MainWindow window;
            if (workspace is not null)
            {
                window = _windows.Find(member => member.Workspace == workspace)
                    ?? throw new InvalidOperationException("the workspace has no window open");
            }
            else
            {
                window = _windows[0];
                workspace = OpenWorkspaceOf(window);
                if (window.Workspace is not null && workspace is null)
                    throw new InvalidOperationException("the front window's workspace is closing");
            }

            if (workspace is not null)
            {
                if (!_workspaces.Contains(workspace) || workspace.IsClosing)
                    throw new InvalidOperationException("the workspace closed before it was saved");
                await RebindWorkspaceAsync(window, workspace, path);
            }
            else
            {
                await SaveUntitledAsAsync(window, path);
                workspace = window.Workspace;
            }

            string key = await Task.Run(() => WorkspaceFile.IdentityKey(path));
            if (workspace is null || !_workspaces.Contains(workspace) || !PathFlavor.Host.KeysEqual(workspace.Key, key))
                throw new IOException($"Save Workspace As to \"{path}\" did not complete (see trace for the reason)");
        }

        /// <summary>Quits as File › Exit does before its windows close: the session (with every window) and every
        /// changed workspace file are written, and the preference writes waited for. The windows stay; the caller
        /// exits the process.</summary>
        internal void QaQuit()
        {
            _quitting = true;
            _store.Flush();
            FlushWrites();
        }

        /// <summary>
        /// <c>-HistqMoveTab &lt;title&gt;:new</c>: File › New Window from <paramref name="source"/> (in its workspace, as
        /// <see cref="NewWindow"/>), then the tab <paramref name="id"/> moves there through <see cref="MoveTab"/>, as Move
        /// Tab to Window › does. Null once moved (an emptied source window closed on its next turn); else why not, and the
        /// new window closes again.
        /// </summary>
        internal async Task<string?> QaMoveTabToNewWindowAsync(Guid id, MainWindow source)
        {
            var before = _windows.ToHashSet();
            NewWindow(source);
            if (_windows.Find(window => !before.Contains(window)) is not { } destination)
                return "File › New Window opened no window";

            string? refusal = MoveRefusal(id, source, destination);
            if (refusal is null && !MoveTab(id, source, destination))
                refusal = "MoveTab did not move it (see the toast in its window)";
            if (refusal is not null)
            {
                destination.Close();
                return refusal;
            }

            // A source left with no tab closes on a later turn: wait for it, so the walk never sees it.
            var clock = Stopwatch.StartNew();
            while (_windows.Exists(window => window.Tabs.Tabs.Count == 0) && clock.Elapsed < TimeSpan.FromSeconds(5))
                await Task.Delay(50);
            return null;
        }
    }

    /// <summary>What the tab click probe reads of a window's tab content (<see cref="QaTabProbes"/>).</summary>
    public sealed partial class TabContentHost
    {
        /// <summary>The repo layouts mounted now (the shown one and the kept ones).</summary>
        internal int QaMountedLayouts => _mounted.Values.Count(mounted => mounted.Kind == ContentKind.Repo);

        /// <summary>The titles of the tabs of <paramref name="tabs"/> whose repo layout is mounted, in tab order.</summary>
        internal List<string> QaMountedRepoTitles(WindowTabs tabs) =>
            [.. tabs.Tabs
                .Where(tab => _mounted.TryGetValue(tab.Id, out Mounted? mounted) && mounted.Kind == ContentKind.Repo)
                .Select(tab => tab.Title)];

        /// <summary>The selected tab's repo layout when it is mounted (<see cref="QaRowClickProbe"/>); null otherwise.</summary>
        internal RepoLayoutView? QaShownLayout(WindowTabs tabs) =>
            tabs.SelectedTabId is { } id && _mounted.TryGetValue(id, out Mounted? mounted)
                ? mounted.Element as RepoLayoutView
                : null;

        /// <summary>The tab <paramref name="id"/>'s mounted content as it stands now; reads only (a Rendering handler
        /// calls it).</summary>
        internal QaContentState QaState(Guid id)
        {
            if (!_mounted.TryGetValue(id, out Mounted? mounted))
                return new QaContentState("none", false, false, false);
            bool visible = mounted.Element.Visibility == Visibility.Visible;
            if (mounted.Element is RepoLayoutView layout)
                return new QaContentState("repo", visible, layout.QaShowsPlaceholder, layout.QaLoadFailed);
            return new QaContentState(mounted.Kind == ContentKind.Missing ? "missing" : "welcome", visible, false, false);
        }
    }
}

namespace Histq.App.Shell.Tabs
{
    /// <summary>The tab click probe's highlight check (<see cref="QaTabProbes"/>).</summary>
    public sealed partial class TabStrip
    {
        /// <summary>The tab's element draws it selected.</summary>
        internal bool QaShowsSelected(Guid id) => _tabViews.TryGetValue(id, out TabItemView? view) && view.IsSelected;
    }

    /// <summary>The tab click probe's highlight check (<see cref="QaTabProbes"/>).</summary>
    public sealed partial class VerticalTabsPanel
    {
        /// <summary>The tab's row, or its pinned cell, draws it selected.</summary>
        internal bool QaShowsSelected(Guid id) =>
            (_rows.TryGetValue(id, out VerticalTabRow? row) && row.IsSelected) || _grid.QaShowsSelected(id);
    }

    /// <summary>The tab click probe's highlight check (<see cref="QaTabProbes"/>).</summary>
    internal sealed partial class VerticalPinnedGrid
    {
        /// <summary>The tab's pinned cell draws it selected.</summary>
        internal bool QaShowsSelected(Guid id) => _cells.TryGetValue(id, out VerticalPinnedCell? cell) && cell.IsSelected;
    }
}

namespace Histq.App.Repo
{
    /// <summary>What the tab click probe reads of a repo layout (<see cref="QaTabProbes"/>).</summary>
    public sealed partial class RepoLayoutView
    {
        /// <summary>The graph's placeholder is up (no rows yet, no error).</summary>
        internal bool QaShowsPlaceholder => GraphPlaceholder.Visibility == Visibility.Visible;

        /// <summary>The graph area shows the load's error.</summary>
        internal bool QaLoadFailed => GraphFailure.Visibility == Visibility.Visible;

        /// <summary>The graph (<see cref="QaRowClickProbe"/>).</summary>
        internal GraphView QaGraph => _graph;

        /// <summary>The detail's summary (<see cref="QaRowClickProbe"/>).</summary>
        internal CommitSummaryView QaSummary => _summary;

        /// <summary>The sidebar (<see cref="QaRowClickProbe"/>).</summary>
        internal SidebarView QaSidebar => _sidebar;

        /// <summary>The graph row a click on <paramref name="row"/> reveals now (the same resolution as the click's);
        /// -1 for none.</summary>
        internal long QaTargetRow(SidebarRow row) => Resolve(row.Targets) is { } item ? _graph.RowOf(item) : -1;

        /// <summary>The graph search (<see cref="QaRepoProbes"/>).</summary>
        internal GraphSearchBar QaSearch => _search;

        /// <summary>The tab's session and folder (<see cref="QaRepoProbes"/>' watch probe).</summary>
        internal RepoTabSession QaSession => _session;

        internal string QaPath => _path;
    }

    /// <summary>What the watch probe reads of a session (<see cref="QaRepoProbes"/>).</summary>
    internal sealed partial class RepoTabSession
    {
        /// <summary>The repo is watched (its watcher started).</summary>
        internal bool QaWatching
        {
            get
            {
                lock (_gate)
                    return _watcher is not null;
            }
        }

        /// <summary>The session's git runner (in the app's process job) and base environment; nulls before they are
        /// set up.</summary>
        internal (GitRunner? Runner, IReadOnlyDictionary<string, string>? Environment) QaGit => (_runner, _base);
    }
}

namespace Histq.App.Graph
{
    /// <summary>What the repo probes drive of the graph search (<see cref="QaRepoProbes"/>).</summary>
    public sealed partial class GraphSearchBar
    {
        /// <summary>Opens the search as Ctrl+F does, with <paramref name="query"/> typed in its field.</summary>
        internal void QaFind(string query)
        {
            Open();
            QueryBox.Text = query;
        }

        /// <summary>Enter (next match) or Shift+Enter (previous).</summary>
        internal void QaStep(bool next)
        {
            if (next)
                _search.Next();
            else
                _search.Previous();
        }
    }
}

namespace Histq.App.Sidebar
{
    /// <summary>What the row click probe's sidebar mode reads and drives (<see cref="QaRowClickProbe"/>).</summary>
    public sealed partial class SidebarView
    {
        /// <summary><c>-HistqShowHidden YES</c>: the Local, Remote and Tags cards list their hidden rows, as their eyes do.</summary>
        internal void QaShowHidden()
        {
            foreach (Card card in new[] { _local, _remote, _tags })
            {
                card.ShowsHidden = true;
                ApplyFilter(card);
                UpdateCard(card);
            }
        }

        /// <summary>The refs came (the Local, Remote and Tags cards have rows).</summary>
        internal bool QaHasRefs => _refs is not null;

        /// <summary>The Local, Remote and Tags cards' rows, in that order (all of them, not through a filter).</summary>
        internal IEnumerable<SidebarRow> QaRefRows() =>
            new[] { _local, _remote, _tags }.SelectMany(card => card.Rows ?? []);

        /// <summary>The ref row named <paramref name="name"/>: a full ref name, else a local branch, a remote branch or a
        /// tag of that short name, in that order; null for none.</summary>
        internal SidebarRow? QaFind(string name)
        {
            List<SidebarRow> rows = [.. QaRefRows()];
            foreach (string key in new[] { name, "refs/heads/" + name, "refs/remotes/" + name, "refs/tags/" + name })
            {
                if (rows.Find(row => string.Equals(row.Key, key, StringComparison.Ordinal)) is { } found)
                    return found;
            }

            return null;
        }

        /// <summary>Shows <paramref name="row"/>'s tab, opens its card and closes its filter, so the row is listed as a
        /// pointer would click it; true when anything changed.</summary>
        internal bool QaPrepare(SidebarRow row)
        {
            Card card = row.Kind switch
            {
                SidebarRowKind.Local => _local,
                SidebarRowKind.Remote => _remote,
                SidebarRowKind.Tag => _tags,
                SidebarRowKind.Worktree => _worktrees,
                _ => _stashes,
            };
            SidebarTab tab = row.Kind == SidebarRowKind.Tag ? SidebarTab.Tags : SidebarTab.Branches;
            bool changed = false;
            if (Tab != tab)
            {
                ShowTab(tab);
                changed = true;
            }

            if (card.Searching)
            {
                CloseSearch(card);
                changed = true;
            }

            if (!card.Expanded)
            {
                ToggleExpanded(card);
                changed = true;
            }

            return changed;
        }
    }
}
#endif

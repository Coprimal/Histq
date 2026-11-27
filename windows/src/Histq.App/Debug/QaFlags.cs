#if HISTQ_QA
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Histq.App.Shell;
using Histq.Core;
using Microsoft.UI.Xaml;

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
    /// </list>
    /// workspace.json reads the saved file back as the app opens one and lists each tab of each window with its stored
    /// <c>path</c> / <c>home</c> strings, the native path they resolved to and whether that folder exists (a UNC or
    /// device path is never probed and reads as not existing).
    /// </summary>
    internal sealed class QaFlags
    {
        private const string OpenWorkspaceFlag = "-HistqOpenWorkspace";
        private const string SaveWorkspaceFlag = "-HistqSaveWorkspace";

        /// <summary>How long the save waits for the repo key reads and folder checks.</summary>
        private static readonly TimeSpan SettleLimit = TimeSpan.FromSeconds(10);

        /// <summary>A save run that has not exited by then fails, so a stuck run never holds the VM chain.</summary>
        private static readonly TimeSpan Watchdog = TimeSpan.FromMinutes(3);

        private static readonly JsonSerializerOptions JsonOptions = new()
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

        private QaFlags(string? openWorkspace, string? saveWorkspace)
        {
            OpenWorkspace = openWorkspace;
            SaveWorkspace = saveWorkspace;
        }

        /// <summary>The workspace file to open at launch; null without the flag.</summary>
        public string? OpenWorkspace { get; }

        /// <summary>The file to save the workspace to, then exit; null without the flag.</summary>
        public string? SaveWorkspace { get; }

        /// <summary>The flags in <paramref name="arguments"/> (the launch arguments, without the program's path).</summary>
        public static QaFlags Read(IReadOnlyList<string> arguments)
        {
            var flags = new LaunchFlags(arguments);
            return new QaFlags(NonEmpty(flags.String(OpenWorkspaceFlag)), NonEmpty(flags.String(SaveWorkspaceFlag)));
        }

        /// <summary>
        /// Runs the flags given (none: nothing). Call it on the UI thread right after
        /// <see cref="WindowManager.Restore"/>, with its task: nothing starts before the launch's windows are open.
        /// </summary>
        public void Start(WindowManager windows, Task restored, StatePaths paths)
        {
            if (OpenWorkspace is null && SaveWorkspace is null)
                return;
            _probePath = Path.Combine(paths.Root, "Probes", "workspace.json");
            if (SaveWorkspace is not null)
            {
                Trace.Listeners.Add(_trace);
                _ = Task.Delay(Watchdog).ContinueWith(
                    _ => Finish($"watchdog: the run did not finish in {Watchdog.TotalMinutes} minutes", 3),
                    TaskScheduler.Default);
                Application.Current.UnhandledException += (_, e) => Finish(e.Exception.ToString(), 1);
            }

            _ = RunAsync(windows, restored);
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

        private static string? NonEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

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
    }
}
#endif

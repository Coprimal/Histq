using System.Diagnostics;
using Histq.Core;
using Histq.Platform.IO;
using Histq.Platform.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Histq.App.Shell;

/// <summary>
/// The app's windows (ported from the window lifecycle of App/Window/WindowModel.swift and its AppDelegate at 6fa6d40):
/// each saved window of the session comes back with its tabs, New Window (Ctrl+Shift+N) opens one with a Welcome tab
/// (in the current window's workspace), and every change saves the session (<see cref="SessionStore"/>). Closing a
/// window that is not the last removes it from the session, as on macOS. Closing the last one quits: the session is
/// saved with it, so the next launch brings it back (a Windows deviation: on macOS the app outlives its last window, on
/// Windows the last window's X is how users quit). File › Exit (<see cref="QuitAll"/>) saves the session with every open
/// window, then closes them. A repo opens through <see cref="OpenRepo"/> (the repo dropdown's and the Welcome page's
/// recent repos, the folder picker of Open…). A tab moves to another window through <see cref="MoveTab"/> (Move Tab to
/// Window ›, a tab dragged onto another window), refused first when it must stay (<see cref="MoveRefusal"/>).
/// <para>
/// A window is Untitled (its tabs are the user's own, <see cref="WindowTabs.ForUserTabs"/>, kept in
/// <c>session.json</c>) or belongs to an open workspace (<see cref="MainWindow.Workspace"/>; its tabs may come from a
/// received <c>.histqws</c>, so it uses the guarded <see cref="WindowTabs()"/> and never probes a UNC or device
/// folder). A workspace's windows are written to its file, their frames, selection and collapsed groups to
/// <c>session.json</c> as its <see cref="WorkspaceLayout"/>; the workspace commands are in WorkspaceCommands.cs.
/// </para>
/// The preferences (the recent repos and workspaces among them) are written on a worker, one write after the other
/// (<see cref="Persist"/>), never on the UI thread: a write fsyncs preferences.json.
/// </summary>
internal sealed partial class WindowManager
{
    private static readonly IReadOnlySet<string> NoneMissing = new HashSet<string>();

    /// <summary>How long quitting waits for the queued preference writes.</summary>
    private static readonly TimeSpan WriteFlushTimeout = TimeSpan.FromSeconds(5);

    private readonly SessionStore _store;

    /// <summary>The layouts of the workspaces not open now, at most one per file, each with its own <c>open</c>: read at
    /// launch and written back, so a capture never drops them. Opening a workspace takes its entry out; closing one puts
    /// it back with <c>open</c> false.</summary>
    private readonly List<WorkspaceLayout> _layouts;

    /// <summary>The open workspaces; their windows point to them.</summary>
    private readonly List<WorkspaceDocument> _workspaces = [];

    /// <summary>The open windows, the front one first.</summary>
    private readonly List<MainWindow> _windows = [];

    /// <summary>The last window's <see cref="MainWindow.Sequence"/>.</summary>
    private long _sequence;

    /// <summary>File › Exit is closing the windows: the session is saved with all of them, and their closes no longer
    /// change it.</summary>
    private bool _quitting;

    /// <summary>A folder, file or git picker is open (one at a time).</summary>
    private bool _picking;

    /// <summary>The last preference write queued (<see cref="Persist"/>); it never faults.</summary>
    private Task _writes = Task.CompletedTask;

    /// <summary>The repo key reads and folder checks started and not yet applied (<see cref="Tracked"/>).</summary>
    private int _pendingChecks;

    /// <param name="store">Saves the session; <see cref="Restore"/> turns its capture on.</param>
    /// <param name="workspaces">The workspace layouts read at launch: those still <c>open</c> reopen, the others are
    /// saved back while their file is in Recent Workspaces.</param>
    /// <param name="preferences">The app's preferences; written only through <see cref="Persist"/>.</param>
    /// <param name="recentRepos">The recent repos, shared by every window, kept in <paramref name="preferences"/>.</param>
    public WindowManager(
        SessionStore store, IReadOnlyList<WorkspaceLayout>? workspaces, Preferences preferences, RecentRepos recentRepos)
    {
        _store = store;
        _layouts = [.. workspaces ?? []];
        Preferences = preferences;
        RecentRepos = recentRepos;
        RecentWorkspaces = new RecentRepos(preferences, PrefKey.RecentWorkspaces);
        _store.WriteResult = OnWorkspaceWritten;
    }

    /// <summary>The open windows, the front one first.</summary>
    public IReadOnlyList<MainWindow> Windows => _windows;

    /// <summary>The app's preferences. Read them off the UI thread (a write holds their lock while it saves the file);
    /// change them only through <see cref="SetPreference"/>.</summary>
    public Preferences Preferences { get; }

    /// <summary>The repositories opened lately, most recent first (one list for every window). Read on the UI thread;
    /// changed on the write worker (<see cref="OpenRepo"/>), which swaps in a new list.</summary>
    public RecentRepos RecentRepos { get; }

    /// <summary>The workspace files opened lately by identity key, most recent first (File › Recent Workspaces). Read
    /// on the UI thread; changed only on the write worker (Add, Clear), which swap in a new list.</summary>
    public RecentRepos RecentWorkspaces { get; }

    /// <summary>
    /// Opens the windows of <paramref name="loaded"/>: the Untitled ones and those of every workspace that was open,
    /// each workspace read off the UI thread first (one that cannot be read is logged and skipped, its layout kept
    /// <c>open</c> for the next launch); the front saved window ends in front, one with a Welcome tab when there is
    /// none. Then turns the session's capture on. The task ends once the windows are open (at once without a
    /// workspace to read); it never faults.
    /// </summary>
    public Task Restore(SessionStore.Loaded? loaded)
    {
        List<string> reopen = _layouts.Where(layout => layout.Open).Select(layout => layout.Path).ToList();
        if (reopen.Count == 0)
        {
            Place(loaded, []);
            return Task.CompletedTask;
        }

        return RestoreWithWorkspacesAsync(loaded, reopen);
    }

    /// <summary>New Window: one Welcome tab, in front, in <paramref name="from"/>'s workspace (the Mac's New Window),
    /// else Untitled.</summary>
    public void NewWindow(MainWindow? from = null)
    {
        if (_quitting)
            return;
        Open(null, null, OpenWorkspaceOf(from));
        _store.Schedule();
    }

    /// <summary>
    /// Move Group to New Window and a closed group's Open Group in New Window (<see cref="WindowTabs.GroupWindow"/>) of
    /// <paramref name="source"/>: a new window of its workspace (guarded like it) or Untitled, in front, with the
    /// group's tabs in the group (same id, name and color) and its tab <see cref="WindowTabs.GroupWindow.Selected"/>
    /// selected; the system places it. Its folders are then checked off the UI thread, as a reopened tab's are (a
    /// folder gone shows "Repo not found").
    /// </summary>
    public void OpenGroupWindow(MainWindow source, WindowTabs.GroupWindow group)
    {
        if (_quitting || group.Tabs.Count == 0)
            return;
        int selected = Math.Clamp(group.Selected, 0, group.Tabs.Count - 1);
        MainWindow window = Open(
            null, model => model.Restore(group.Tabs, selected, group.Missing, [group.Group]), OpenWorkspaceOf(source));
        List<(Guid Id, string Path)> folders = [.. window.Tabs.Tabs
            .Where(tab => tab.Path is not null).Select(tab => (tab.Id, tab.Path!))];
        if (folders.Count > 0)
            _ = Tracked(CheckFoldersAsync(window, folders));
        _store.Schedule();
    }

    /// <summary>Brings the front window forward (a second launch handed its activation here).</summary>
    public void BringForward()
    {
        if (_windows.Count > 0)
            Show(_windows[0]);
    }

    /// <summary>Brings <paramref name="window"/> forward, restored when it is minimized (Window menu).</summary>
    public void Show(MainWindow window)
    {
        if (window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
        window.Activate();
    }

    /// <summary>
    /// File › Exit: saves the session with every open window (so the next launch brings them all back, each open
    /// workspace too), then closes them. Closing one window by itself removes it from the session instead
    /// (<see cref="OnClosed"/>).
    /// </summary>
    public void QuitAll()
    {
        if (_quitting)
            return;
        _quitting = true;
        _store.Flush();
        FlushWrites();
        foreach (MainWindow window in _windows.ToList())
            window.Close();
    }

    /// <summary>
    /// Open… and the Welcome page's Open folder: a folder picker owned by <paramref name="window"/>; the picked folder
    /// opens there at once (<see cref="OpenRepo"/>), as on the Mac: it is not probed first, and a folder that is not a
    /// git repository shows its tab's placeholder until the repo load exists (phase 13/14).
    /// </summary>
    public void ChooseFolder(MainWindow window) => _ = ChooseFolderAsync(window);

    /// <summary>
    /// Opens the repository at <paramref name="path"/> in <paramref name="window"/> at once (its tab when one has it,
    /// the selected Welcome tab filled, else a new tab: <see cref="WindowTabs.OpenTab"/>), then puts it first in the
    /// recent repos on the write worker, as the Mac's openTab: a pick from a recent list is never probed first.
    /// </summary>
    public void OpenRepo(MainWindow window, string path)
    {
        window.Apply(model => model.OpenTab(path));
        _ = AddRecentAsync(path);
    }

    /// <summary>Saves <paramref name="value"/> as <paramref name="key"/> on the write worker; the task ends once it is
    /// written (after every write queued before it).</summary>
    public Task SetPreference<T>(PrefKey key, T value) => Persist(() => Preferences.Set(key, value), key.Name);

    /// <summary>
    /// Choose git…: a file picker for git.exe owned by <paramref name="window"/>. The picked file's path; null when the
    /// user cancels, another picker is open, or the window closed meanwhile.
    /// </summary>
    public async Task<string?> PickGitAsync(MainWindow window)
    {
        if (_picking)
            return null;
        _picking = true;
        string? path;
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder };
            picker.FileTypeFilter.Add(".exe");
            // An unpackaged app's picker needs its owner window.
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
            StorageFile? file = await picker.PickSingleFileAsync();
            path = file?.Path;
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: git picker failed: {error.Message}");
            return null;
        }
        finally
        {
            _picking = false;
        }

        return string.IsNullOrEmpty(path) || _quitting || !_windows.Contains(window) ? null : path;
    }

    // Moving a tab to another window.

    /// <summary>The windows a tab of <paramref name="source"/> can move to: every other open window, in the order they
    /// opened.</summary>
    public IReadOnlyList<MainWindow> MoveDestinations(MainWindow source) =>
        _windows.Where(window => window != source).OrderBy(window => window.Sequence).ToList();

    /// <summary>Why the tab <paramref name="id"/> cannot move from <paramref name="source"/> to
    /// <paramref name="destination"/> now (<see cref="WindowTabs.MoveRefusal"/>); null when it can. No I/O: menus
    /// build their entries with it.</summary>
    public string? MoveRefusal(Guid id, MainWindow source, MainWindow destination)
    {
        if (_quitting || !_windows.Contains(source) || !_windows.Contains(destination)
            || source.Workspace?.IsClosing == true || destination.Workspace?.IsClosing == true)
            return "The tab or the window is gone.";
        WorkspaceDocument? from = source.Workspace;
        return WindowTabs.MoveRefusal(
            id, source.Tabs, from, from is null ? 0 : WindowsOf(from).Count, destination.Tabs, destination.Workspace);
    }

    /// <summary>
    /// Moves the tab <paramref name="id"/> from <paramref name="source"/> to <paramref name="destination"/> (Move Tab to
    /// Window ›, a tab dragged onto another window), refused before anything changes (<see cref="MoveRefusal"/>; the
    /// reason shows as a toast in the source window). The tab goes alone, the source's multi-selection ends, and it is
    /// selected in the destination, which comes forward. A source left with no tab closes on the next turn, after the
    /// menu or the drag that moved it has finished with it.
    /// </summary>
    public bool MoveTab(Guid id, MainWindow source, MainWindow destination)
    {
        if (MoveRefusal(id, source, destination) is { } reason)
        {
            source.ShowToast("Move Tab to Window", reason);
            return false;
        }

        WindowTabs.MovedTab? moved = null;
        source.Apply(model =>
        {
            model.ClearSelection();
            moved = model.DetachTab(id);
        });
        if (moved is null)
        {
            source.ShowToast("Move Tab to Window", "The tab or the window is gone.");
            return false;
        }

        destination.Apply(model => model.Adopt(moved));
        if (source.Tabs.Tabs.Count == 0)
        {
            source.DispatcherQueue.TryEnqueue(() =>
            {
                if (_windows.Contains(source) && source.Tabs.Tabs.Count == 0)
                    source.Close();
            });
        }

        Show(destination);
        _store.Schedule();
        return true;
    }

    /// <summary>
    /// Where a drag of <paramref name="unit"/> released outside <paramref name="source"/> goes (TabDragOut.outcome): the
    /// other Histq window under the pointer, for a lone tab it may move to. Null, and the drag snaps back, for a worktree
    /// box or a group, no Histq window there, or a refused move (its reason as a toast in the source window).
    /// </summary>
    public MainWindow? DropTarget(MainWindow source, TabArrangement.Unit unit)
    {
        nint hit;
        try
        {
            hit = WindowAtCursor.Root();
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Tab drop target (snapped back)", error);
            return null;
        }

        MainWindow? destination = hit == 0 ? null : _windows.Find(window => window != source && window.Handle == hit);
        if (destination is null || unit is not TabArrangement.Unit.Tab tab)
            return null;
        if (MoveRefusal(tab.Id, source, destination) is { } reason)
        {
            source.ShowToast("Move Tab to Window", reason);
            return null;
        }

        return destination;
    }

    // The session.

    /// <summary>The workspace a new window opened from <paramref name="window"/> joins: its own while open, else none.</summary>
    private WorkspaceDocument? OpenWorkspaceOf(MainWindow? window) =>
        window?.Workspace is { IsClosing: false } workspace && _workspaces.Contains(workspace) ? workspace : null;

    /// <summary>
    /// The session as it is now: the Untitled windows, front first, then one layout per open workspace (its windows
    /// numbered with the same order), then the kept layouts of the workspaces not open now; and every open workspace's
    /// file as its windows have it, a closing one (Close Workspace) included, with whether it is read-only.
    /// </summary>
    private SessionStore.Snapshot Capture()
    {
        var untitled = new List<SavedWindow>();
        var placed = new Dictionary<MainWindow, WorkspaceLayout.Window>();
        for (int order = 0; order < _windows.Count; order++)
        {
            MainWindow window = _windows[order];
            if (window.Workspace is null)
                untitled.Add(window.Saved(order));
            else
                placed[window] = window.LayoutWindow(order);
        }

        var layouts = new List<WorkspaceLayout>();
        var files = new Dictionary<string, (WorkspaceFile File, bool IsReadOnly)>(PathFlavor.Host.KeyComparer);
        foreach (WorkspaceDocument workspace in _workspaces)
        {
            List<MainWindow> members = WindowsOf(workspace);
            if (members.Count == 0)
                continue;
            if (!workspace.IsClosing)
                layouts.Add(new WorkspaceLayout(workspace.Key, true, [.. members.Select(window => placed[window])]));
            if (files.ContainsKey(workspace.Key))
                continue;
            try
            {
                files[workspace.Key] = (Build(workspace, members), workspace.IsReadOnly);
            }
            catch (Exception error)
            {
                CrashLog.Recovered("Workspace capture (file not written this pass)", error);
            }
        }

        layouts.AddRange(WorkspaceLayouts.Kept(
            _layouts, layouts.Select(layout => layout.Path), RecentWorkspaces.Paths, _windows.Count));
        return new SessionStore.Snapshot(new SavedSession(untitled, layouts.Count == 0 ? null : layouts), files);
    }

    /// <summary>The open windows of <paramref name="workspace"/> in its file's order, windows added since after them in
    /// the order they opened.</summary>
    private List<MainWindow> WindowsOf(WorkspaceDocument workspace)
    {
        List<Guid> order = workspace.WindowOrder;
        return _windows.Where(window => window.Workspace == workspace)
            .OrderBy(window => order.IndexOf(window.WindowId) is var at && at >= 0 ? at : int.MaxValue)
            .ThenBy(window => window.Sequence)
            .ToList();
    }

    /// <summary><paramref name="workspace"/>'s file as <paramref name="members"/> have it now.</summary>
    private static WorkspaceFile Build(WorkspaceDocument workspace, List<MainWindow> members) =>
        workspace.Build([.. members.Select(window => window.Tabs.LiveWindow(window.WindowId))]);

    /// <summary>A workspace write finished (<see cref="SessionStore.WriteResult"/>, on the UI thread): its outcome is
    /// kept and its windows' labels show it.</summary>
    private void OnWorkspaceWritten(string key, Exception? error)
    {
        foreach (WorkspaceDocument workspace in _workspaces.Where(open => PathFlavor.Host.KeysEqual(open.Key, key)))
        {
            if (error is not null)
                Trace.WriteLine($"Histq: workspace not saved: {error.Message}");
            workspace.RecordWrite(error);
            foreach (MainWindow window in WindowsOf(workspace))
                window.ShowWorkspace();
        }
    }

    /// <summary>A restored window waiting to be opened: its place among the windows (front first; a workspace window
    /// with no saved layout after them) and how it opens.</summary>
    private sealed record Placed(int Order, Func<MainWindow> Open);

    /// <summary>Reads the workspaces of the launch off the UI thread, then opens every window of the session.</summary>
    private async Task RestoreWithWorkspacesAsync(SessionStore.Loaded? loaded, List<string> paths)
    {
        List<(string Path, WorkspaceDocument.Opened Read)> opened;
        try
        {
            opened = await Task.Run(() => ReadWorkspaces(paths));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Workspace reopen (none reopened)", error);
            opened = [];
        }

        // The await resumes on the UI thread (its SynchronizationContext); nothing awaits this task.
        try
        {
            Place(loaded, opened);
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Session restore", error);
            if (_windows.Count == 0)
                Open(null, null, null);
            _store.Start(Capture);
        }
    }

    /// <summary>Each workspace file that reads (<see cref="WorkspaceDocument.Open"/>, 8 MB cap, received paths never
    /// probed under UNC); one that does not is logged and left out. Runs on a worker.</summary>
    private static List<(string Path, WorkspaceDocument.Opened Read)> ReadWorkspaces(List<string> paths)
    {
        var opened = new List<(string, WorkspaceDocument.Opened)>();
        foreach (string path in paths)
        {
            try
            {
                opened.Add((path, WorkspaceDocument.Open(path)));
            }
            catch (Exception error)
            {
                Trace.WriteLine($"Histq: workspace not reopened: {error.Message}");
            }
        }

        return opened;
    }

    /// <summary>
    /// Opens the Untitled windows of <paramref name="loaded"/> and the windows of the <paramref name="workspaces"/> read
    /// (one file named by two layouts opens once), back to front so the front one ends in front; one Welcome window when
    /// there is none. Each workspace then seeds the writer with its file as captured now, and the capture starts.
    /// </summary>
    private void Place(SessionStore.Loaded? loaded, List<(string Path, WorkspaceDocument.Opened Read)> workspaces)
    {
        var placed = new List<Placed>();
        IReadOnlySet<string> missing = loaded?.Missing ?? NoneMissing;
        foreach (SavedWindow saved in loaded?.Session.Windows ?? [])
        {
            placed.Add(new Placed(saved.Group, () => Open(saved, model => model.Restore(
                saved.Tabs, saved.SelectedTab, missing, saved.ManualTabGroups, saved.ClosedTabGroups), null)));
        }

        var restored = new List<WorkspaceDocument>();
        foreach (var (path, read) in workspaces)
        {
            if (_workspaces.Exists(open => PathFlavor.Host.KeysEqual(open.Key, read.Document.Key)))
                continue;
            placed.AddRange(PlaceWorkspace(read, path));
            restored.Add(read.Document);
        }

        if (placed.Count == 0)
            Open(null, null, null);
        OpenBackToFront(placed);
        foreach (WorkspaceDocument workspace in restored)
            Seed(workspace);
        _store.Start(Capture);
    }

    /// <summary>
    /// The windows of the workspace <paramref name="read"/> as its file has them, with the frames, order, selection and
    /// collapsed groups of its layout (the entry at <paramref name="layoutPath"/>, else at its key), which leaves the
    /// kept layouts; with none, each window gets a system frame and its first shown tab. The workspace joins the open
    /// ones now; its windows open when the caller runs them (<see cref="OpenBackToFront"/>), then it seeds the writer
    /// (<see cref="Seed"/>).
    /// </summary>
    private List<Placed> PlaceWorkspace(WorkspaceDocument.Opened read, string? layoutPath)
    {
        PathFlavor flavor = PathFlavor.Host;
        WorkspaceDocument workspace = read.Document;
        string path = layoutPath ?? workspace.Key;
        WorkspaceLayout? layout = _layouts.Find(entry => flavor.KeysEqual(entry.Path, path));
        _layouts.RemoveAll(entry => flavor.KeysEqual(entry.Path, path) || flavor.KeysEqual(entry.Path, workspace.Key));
        var places = new Dictionary<Guid, WorkspaceLayout.Window>();
        foreach (WorkspaceLayout.Window window in layout?.Windows ?? [])
            places.TryAdd(window.Id, window);
        _workspaces.Add(workspace);

        IReadOnlySet<string> missing = read.Resolved.Missing;
        return [.. read.Resolved.Windows.Select(window =>
        {
            places.TryGetValue(window.Id, out WorkspaceLayout.Window? place);
            var collapsed = new HashSet<Guid>(place?.CollapsedGroups ?? []);
            int selected = WorkspaceLayouts.SelectedTab(window, place?.SelectedPath, collapsed);
            IReadOnlyList<SavedTabGroup>? groups = WorkspaceLayouts.TabGroups(window, collapsed);
            SavedWindow? frame = place is null
                ? null
                : new SavedWindow(place.X, place.Y, place.Width, place.Height, 0, 0, true, []);
            return new Placed(place?.Group ?? int.MaxValue, () => Open(
                frame,
                model => model.Restore(window.Tabs, selected, missing, groups, window.ClosedTabGroups, read.RepoKeys),
                workspace,
                window.Id));
        })];
    }

    /// <summary>Opens <paramref name="placed"/> back to front (stable for equal places), so the front one ends active.</summary>
    private static void OpenBackToFront(List<Placed> placed)
    {
        List<Placed> ordered = [.. placed.OrderBy(entry => entry.Order)];
        for (int index = ordered.Count - 1; index >= 0; index--)
            ordered[index].Open();
    }

    /// <summary>An opened workspace's file as its windows have it now is what the writer has: written only once it
    /// changes. Its file goes first in Recent Workspaces.</summary>
    private void Seed(WorkspaceDocument workspace)
    {
        try
        {
            _store.Seed(workspace.Key, Build(workspace, WindowsOf(workspace)));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Workspace seed (written at the next pass)", error);
        }

        AddRecentWorkspace(workspace.Key);
    }

    /// <summary>
    /// Opens a window (not saved yet; the caller schedules a save) at <paramref name="frame"/> when it fits on a display,
    /// in <paramref name="workspace"/> (null: Untitled) with <paramref name="windowId"/> as its id there, its tabs
    /// restored by <paramref name="restore"/> (null: one Welcome tab). A workspace window's tabs are guarded
    /// (<see cref="WindowTabs()"/>), an Untitled one's are the user's own (<see cref="WindowTabs.ForUserTabs"/>).
    /// </summary>
    private MainWindow Open(
        SavedWindow? frame, Action<WindowTabs>? restore, WorkspaceDocument? workspace, Guid? windowId = null)
    {
        WindowTabs tabs = workspace is null ? WindowTabs.ForUserTabs() : new WindowTabs();
        var window = new MainWindow(this, tabs, frame) { Sequence = ++_sequence };
        if (windowId is { } id)
            window.WindowId = id;
        window.Workspace = workspace;
        // Before Restore, which asks for the restored tabs' keys at its end.
        tabs.RepoKeysNeeded = requests => _ = Tracked(ReadRepoKeysAsync(window, requests));
        // A reopened (Ctrl+Shift+T) or popped-out tab shows at once; its folder is checked off the UI thread (UNC).
        tabs.FolderChecksNeeded = requests => _ = Tracked(CheckFoldersAsync(window, requests));
        window.Apply(model => restore?.Invoke(model));

        window.StateChanged += (_, _) => _store.Schedule();
        window.Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated && _windows.Remove(window))
                _windows.Insert(0, window);
        };
        window.Closed += (_, _) => OnClosed(window);
        _windows.Insert(0, window);
        window.Activate();
        return window;
    }

    /// <summary>
    /// A window closed. During File › Exit nothing changes. The last window quits, saving the session with it (its
    /// workspace stays open for the next launch). Another window leaves the session; when it was the last window of
    /// its workspace, the workspace closes as Close Workspace closes it (its file written one last time, its layout kept
    /// with <c>open</c> false).
    /// </summary>
    private void OnClosed(MainWindow window)
    {
        if (!_windows.Contains(window))
            return;

        if (_quitting)
        {
            // File › Exit saved the session with every window already.
            _windows.Remove(window);
            return;
        }

        if (_windows.Count == 1)
        {
            // The last window: quit, saving the session while the window is still in it.
            _store.Flush();
            FlushWrites();
            _windows.Remove(window);
            return;
        }

        // While the window is still listed: its file is written with it.
        if (window.Workspace is { IsClosing: false } workspace && _workspaces.Contains(workspace)
            && WindowsOf(workspace).Count == 1)
            FinishWorkspace(workspace);
        _windows.Remove(window);
        _store.Schedule();
    }

    private async Task ChooseFolderAsync(MainWindow window)
    {
        if (_picking)
            return;
        _picking = true;
        string? path;
        try
        {
            var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.ComputerFolder };
            picker.FileTypeFilter.Add("*");
            // An unpackaged app's picker needs its owner window.
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
            StorageFolder? folder = await picker.PickSingleFolderAsync();
            path = folder?.Path;
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: folder picker failed: {error.Message}");
            return;
        }
        finally
        {
            _picking = false;
        }

        // A library or other virtual folder has no path. The await resumes on the UI thread; the window may have
        // closed meanwhile.
        if (string.IsNullOrEmpty(path) || _quitting || !_windows.Contains(window))
            return;

        OpenRepo(window, path);
    }

    /// <summary>Puts <paramref name="path"/> first in the recent repos on the write worker, then has the open windows'
    /// Welcome pages list them again.</summary>
    private async Task AddRecentAsync(string path)
    {
        await Persist(() => RecentRepos.Add(path), "recent repos");
        // The await resumes on the UI thread (its SynchronizationContext); only windows still open are told.
        foreach (MainWindow window in _windows)
            window.ShowRecentRepos();
    }

    /// <summary>Puts the workspace file <paramref name="key"/> first in Recent Workspaces on the write worker.</summary>
    private void AddRecentWorkspace(string key) => _ = Persist(() => RecentWorkspaces.Add(key), "recent workspaces");

    /// <summary>
    /// Runs <paramref name="write"/> on a worker after every write queued before it (call it on the UI thread). The
    /// returned task ends once it ran; it never faults (a failure is only logged: the value stays for this run).
    /// </summary>
    private Task Persist(Action write, string what)
    {
        _writes = _writes.ContinueWith(
            _ =>
            {
                try
                {
                    write();
                }
                catch (Exception error)
                {
                    Trace.WriteLine($"Histq: {what} not saved: {error.Message}");
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.None,
            TaskScheduler.Default);
        return _writes;
    }

    /// <summary>Quitting: waits (a few seconds at most) for the queued preference writes, so the last open is kept.</summary>
    private void FlushWrites()
    {
        if (!_writes.Wait(WriteFlushTimeout))
            Trace.WriteLine("Histq: preference writes still running at quit");
    }

    /// <summary>Counts <paramref name="check"/> (a repo key read or a folder check, which never faults) in
    /// <see cref="_pendingChecks"/> until it has applied its result. Call it on the UI thread.</summary>
    private async Task Tracked(Task check)
    {
        _pendingChecks++;
        try
        {
            await check;
        }
        finally
        {
            _pendingChecks--;
        }
    }

    /// <summary>Reads the repo keys off the UI thread and hands them to the window's tabs, unless it closed meanwhile.
    /// A workspace window's folders are read as received ones (<see cref="RepoGroupKey.Of(string)"/>, nothing under a
    /// UNC or device path), an Untitled window's as the user's own.</summary>
    private async Task ReadRepoKeysAsync(MainWindow window, IReadOnlyList<(Guid Id, string Path)> requests)
    {
        bool own = window.Workspace is null;
        List<(Guid Id, string Path, string? Key)> keys;
        try
        {
            keys = await Task.Run(() =>
                requests.Select(request => (request.Id, request.Path, RepoKey(request.Path, own))).ToList());
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: repo keys not read: {error.Message}");
            return;
        }

        // The await resumes on the UI thread (its SynchronizationContext). Nothing awaits this task, so a failure here
        // would otherwise go unseen.
        try
        {
            if (_windows.Contains(window))
                window.Apply(model => model.ApplyRepoKeys(keys));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("ApplyRepoKeys (tab row not brought in line)", error);
        }
    }

    /// <summary>Checks the folders off the UI thread and hands the result to the window's tabs, unless it closed
    /// meanwhile: an Untitled window's as the user's own (<see cref="SavedSession.IsUserRepository"/>), a workspace
    /// window's as received ones (<see cref="SavedSession.IsRepository(string)"/>: a UNC or device folder is never
    /// probed and shows "Repo not found").</summary>
    private async Task CheckFoldersAsync(MainWindow window, IReadOnlyList<(Guid Id, string Path)> requests)
    {
        Func<string, bool> isRepository = window.Workspace is null ? SavedSession.IsUserRepository : SavedSession.IsRepository;
        List<(Guid Id, string Path, bool Exists)> checks;
        try
        {
            checks = await Task.Run(() => requests
                .Select(request => (request.Id, request.Path, isRepository(request.Path))).ToList());
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: folders not checked: {error.Message}");
            return;
        }

        // The await resumes on the UI thread (its SynchronizationContext). Nothing awaits this task, so a failure here
        // would otherwise go unseen.
        try
        {
            if (_windows.Contains(window))
                window.Apply(model => model.ApplyFolderChecks(checks));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("ApplyFolderChecks (tab row not brought in line)", error);
        }
    }

    /// <summary>session.json could not be written (<see cref="SessionStore.SessionWriteFailed"/>, marshalled to the UI
    /// thread): a warning toast in the front window; none while quitting or with no window left. The toast says only
    /// that (the error, with its paths, goes to the trace log).</summary>
    public void ShowSessionWriteFailed()
    {
        if (!_quitting && _windows.Count > 0)
            _windows[0].ShowToast("Session not saved", "Histq couldn't save the session.");
    }

    /// <summary>
    /// The repository key of a tab: its git common dir as Windows resolves it (links followed, the on-disk case), so two
    /// spellings of one repository share a key; the standardized path when that cannot be read (a volume mounted only
    /// as a folder). <paramref name="own"/>: one of the user's own folders, read under a UNC path too.
    /// </summary>
    private static string? RepoKey(string folder, bool own) =>
        (own ? RepoGroupKey.OfUserFolder(folder) : RepoGroupKey.Of(folder)) is { } key ? FinalPath.Of(key) ?? key : null;
}

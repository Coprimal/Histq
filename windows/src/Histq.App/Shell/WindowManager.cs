using System.Diagnostics;
using Histq.Core;
using Histq.Platform.IO;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Histq.App.Shell;

/// <summary>
/// The app's windows (ported from the window lifecycle of App/Window/WindowModel.swift and its AppDelegate at 6fa6d40):
/// each saved window of the session comes back with its tabs, New Window (Ctrl+Shift+N) opens one with a Welcome tab,
/// and every change saves the session (<see cref="SessionStore"/>). Closing a window that is not the last removes it from
/// the session, as on macOS. Closing the last one quits: the session is saved with it, so the next launch brings it back
/// (a Windows deviation: on macOS the app outlives its last window, on Windows the last window's X is how users quit).
/// File › Exit (<see cref="QuitAll"/>) saves the session with every open window, then closes them. A repo opens through
/// <see cref="OpenRepo"/> (the repo dropdown's and the Welcome page's recent repos, the folder picker of Open…). Every
/// window's tabs are the user's own (<see cref="WindowTabs.ForUserTabs"/>); workspace windows come in phase 11. The
/// preferences (the recent repos among them) are written on a worker, one write after the other (<see cref="Persist"/>),
/// never on the UI thread: a write fsyncs preferences.json.
/// </summary>
internal sealed class WindowManager
{
    private static readonly IReadOnlySet<string> NoneMissing = new HashSet<string>();

    /// <summary>How long quitting waits for the queued preference writes.</summary>
    private static readonly TimeSpan WriteFlushTimeout = TimeSpan.FromSeconds(5);

    private readonly SessionStore _store;
    private readonly IReadOnlyList<WorkspaceLayout>? _workspaces;

    /// <summary>The open windows, the front one first.</summary>
    private readonly List<MainWindow> _windows = [];

    /// <summary>File › Exit is closing the windows: the session is saved with all of them, and their closes no longer
    /// change it.</summary>
    private bool _quitting;

    /// <summary>A folder or git picker is open (one at a time).</summary>
    private bool _picking;

    /// <summary>The last preference write queued (<see cref="Persist"/>); it never faults.</summary>
    private Task _writes = Task.CompletedTask;

    /// <param name="store">Saves the session; <see cref="Restore"/> turns its capture on.</param>
    /// <param name="workspaces">The workspace layouts read at launch, saved back as they are until workspaces open
    /// (phase 11).</param>
    /// <param name="preferences">The app's preferences; written only through <see cref="Persist"/>.</param>
    /// <param name="recentRepos">The recent repos, shared by every window, kept in <paramref name="preferences"/>.</param>
    public WindowManager(
        SessionStore store, IReadOnlyList<WorkspaceLayout>? workspaces, Preferences preferences, RecentRepos recentRepos)
    {
        _store = store;
        _workspaces = workspaces;
        Preferences = preferences;
        RecentRepos = recentRepos;
    }

    /// <summary>The open windows, the front one first.</summary>
    public IReadOnlyList<MainWindow> Windows => _windows;

    /// <summary>The app's preferences. Read them off the UI thread (a write holds their lock while it saves the file);
    /// change them only through <see cref="SetPreference"/>.</summary>
    public Preferences Preferences { get; }

    /// <summary>The repositories opened lately, most recent first (one list for every window). Read on the UI thread;
    /// changed on the write worker (<see cref="OpenRepo"/>), which swaps in a new list.</summary>
    public RecentRepos RecentRepos { get; }

    /// <summary>
    /// Opens the windows of <paramref name="loaded"/> (one with a Welcome tab when there is none), the first saved
    /// window in front, then turns the session's capture on.
    /// </summary>
    public void Restore(SessionStore.Loaded? loaded)
    {
        var saved = loaded?.Session.Groups.SelectMany(group => group).ToList() ?? [];
        if (saved.Count == 0)
        {
            Open(null, NoneMissing);
        }

        // Back to front, so the front window is activated last.
        for (int i = saved.Count - 1; i >= 0; i--)
            Open(saved[i], loaded!.Missing);

        _store.Start(Capture);
    }

    /// <summary>New Window: one Welcome tab, in front.</summary>
    public void NewWindow()
    {
        if (_quitting)
            return;
        Open(null, NoneMissing);
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
    /// File › Exit: saves the session with every open window (so the next launch brings them all back), then closes
    /// them. Closing one window by itself removes it from the session instead (<see cref="OnClosed"/>).
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

    /// <summary>The session as it is now: every open window, front first, and the workspace layouts read at launch.</summary>
    private SessionStore.Snapshot Capture() =>
        new(
            new SavedSession(_windows.Select((window, index) => window.Saved(index)).ToList(), _workspaces),
            new Dictionary<string, (WorkspaceFile File, bool IsReadOnly)>());

    private MainWindow Open(SavedWindow? saved, IReadOnlySet<string> missing)
    {
        var tabs = WindowTabs.ForUserTabs();
        var window = new MainWindow(this, tabs, saved);
        // Before Restore, which asks for the restored tabs' keys at its end.
        tabs.RepoKeysNeeded = requests => _ = ReadRepoKeysAsync(window, requests);
        // A reopened (Ctrl+Shift+T) or popped-out tab shows at once; its folder is checked off the UI thread (UNC).
        tabs.FolderChecksNeeded = requests => _ = CheckFoldersAsync(window, requests);
        window.Apply(model =>
        {
            if (saved is not null)
                model.Restore(saved.Tabs, saved.SelectedTab, missing, saved.ManualTabGroups, saved.ClosedTabGroups);
        });

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

    /// <summary>Reads the repo keys off the UI thread and hands them to the window's tabs, unless it closed meanwhile.</summary>
    private async Task ReadRepoKeysAsync(MainWindow window, IReadOnlyList<(Guid Id, string Path)> requests)
    {
        List<(Guid Id, string Path, string? Key)> keys;
        try
        {
            keys = await Task.Run(() => requests.Select(request => (request.Id, request.Path, RepoKey(request.Path))).ToList());
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: repo keys not read: {error.Message}");
            return;
        }

        // The await resumes on the UI thread (its SynchronizationContext).
        if (_windows.Contains(window))
            window.Apply(model => model.ApplyRepoKeys(keys));
    }

    /// <summary>Checks the folders off the UI thread (<see cref="SavedSession.IsUserRepository"/>, as the user's own tabs
    /// are) and hands the result to the window's tabs, unless it closed meanwhile.</summary>
    private async Task CheckFoldersAsync(MainWindow window, IReadOnlyList<(Guid Id, string Path)> requests)
    {
        List<(Guid Id, string Path, bool Exists)> checks;
        try
        {
            checks = await Task.Run(() => requests
                .Select(request => (request.Id, request.Path, SavedSession.IsUserRepository(request.Path))).ToList());
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: folders not checked: {error.Message}");
            return;
        }

        // The await resumes on the UI thread (its SynchronizationContext).
        if (_windows.Contains(window))
            window.Apply(model => model.ApplyFolderChecks(checks));
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
    /// The repository key of one of the user's own tabs: its git common dir as Windows resolves it (links followed, the
    /// on-disk case), so two spellings of one repository share a key; the standardized path when that cannot be read
    /// (a volume mounted only as a folder).
    /// </summary>
    private static string? RepoKey(string folder) =>
        RepoGroupKey.OfUserFolder(folder) is { } key ? FinalPath.Of(key) ?? key : null;
}

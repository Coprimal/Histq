using System.Diagnostics;
using Histq.Core;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Histq.App.Shell;

/// <summary>
/// The workspace commands of the app menu's File menu (ported from the Workspaces section of App/HistqApp.swift at
/// 6fa6d40): New Workspace, Open Workspace…, Recent Workspaces ›, Save Workspace As… and Close Workspace. A workspace
/// file (<c>*.histqws</c>) is read through <see cref="WorkspaceDocument.Open"/> (8 MB cap, received paths never probed
/// under UNC) and written through <see cref="SessionStore.WriteNowAsync"/>, both off the UI thread: a menu click returns
/// at once, and its window opens (or its label changes) once the file is read or written. A workspace opens in its own
/// windows; opening one that is open already brings its front window forward. Problems show as warning toasts (the
/// Mac's alert sheets).
/// </summary>
internal sealed partial class WindowManager
{
    /// <summary>The workspace file's extension.</summary>
    private const string WorkspaceExtension = ".histqws";

    /// <summary>The identity keys of the workspace files being read or written now (the Mac's openingKeys): a second
    /// open of one is a no-op, and Save As / New Workspace refuse them.</summary>
    private readonly HashSet<string> _busyKeys = new(PathFlavor.Host.KeyComparer);

    /// <summary>File › New Workspace: asks where to save it (named Untitled), writes a workspace with one window and a
    /// Welcome tab, then opens that window (HistqApp.swift:1156-1163).</summary>
    public void NewWorkspace(MainWindow window) => _ = NewWorkspaceAsync(window);

    /// <summary>File › Open Workspace…: asks for a workspace file and opens it.</summary>
    public void ChooseWorkspace(MainWindow window) => _ = ChooseWorkspaceAsync(window);

    /// <summary>
    /// Opens the workspace file at <paramref name="path"/> (Recent Workspaces, Open Workspace…), or brings its front
    /// window forward when it is open already (same identity key). A file that cannot be read shows a toast in
    /// <paramref name="from"/> and nothing is written; one with keys this build would drop opens read-only.
    /// </summary>
    public void OpenWorkspace(string path, MainWindow? from) => _ = OpenWorkspaceAsync(path, from);

    /// <summary>File › Save Workspace As…: asks for the new file, then saves <paramref name="window"/>'s workspace there
    /// (from an Untitled window, every Untitled window joins a new workspace written there).</summary>
    public void SaveWorkspaceAs(MainWindow window) => _ = SaveWorkspaceAsAsync(window);

    /// <summary>Recent Workspaces › Clear Menu, on the write worker.</summary>
    public void ClearRecentWorkspaces() => _ = Persist(() => RecentWorkspaces.Clear(), "recent workspaces");

    /// <summary>
    /// File › Close Workspace: closes <paramref name="window"/>'s workspace with all its windows. Its file is written
    /// one last time with every window (then never again), its layout is kept with <c>open</c> false (it stays closed at
    /// the next launch), and its windows close without capturing anything. When they are all the app's windows, a
    /// Welcome window opens first: Close Workspace never quits.
    /// </summary>
    public void CloseWorkspace(MainWindow window)
    {
        if (_quitting || !_windows.Contains(window) || window.Workspace is not { IsClosing: false } workspace
            || !_workspaces.Contains(workspace))
            return;
        List<MainWindow> members = WindowsOf(workspace);
        FinishWorkspace(workspace);
        if (_windows.TrueForAll(members.Contains))
            Open(null, null, null);
        foreach (MainWindow member in members)
            member.Close();
        _store.Schedule();
    }

    /// <summary>
    /// The last close of <paramref name="workspace"/> (Close Workspace, its last window closed by hand): its layout is
    /// kept with <c>open</c> false, the writer writes its file one last time with the windows it has now (call it while
    /// they are still listed) and forgets it, and it leaves the open workspaces; its windows then close capturing
    /// nothing.
    /// </summary>
    private void FinishWorkspace(WorkspaceDocument workspace)
    {
        List<MainWindow> members = WindowsOf(workspace);
        if (members.Count > 0)
        {
            var layout = new WorkspaceLayout(
                workspace.Key, false, [.. members.Select(window => window.LayoutWindow(_windows.IndexOf(window)))]);
            _layouts.RemoveAll(entry => PathFlavor.Host.KeysEqual(entry.Path, workspace.Key));
            _layouts.Add(layout);
        }

        workspace.IsClosing = true;
        _store.Finish(workspace.Key);
        _workspaces.Remove(workspace);
    }

    private async Task NewWorkspaceAsync(MainWindow window)
    {
        try
        {
            if (await PickWorkspaceFileAsync(window, "Untitled") is not { } path)
                return;
            var windowId = Guid.NewGuid();
            // The document reads the file's identity key, and building may read its folder: off the UI thread.
            (WorkspaceDocument workspace, WorkspaceFile file) = await Task.Run(() =>
            {
                var created = new WorkspaceDocument(path);
                created.WindowOrder.Add(windowId);
                return (created, created.Build([new WorkspaceFile.LiveWindow(windowId, [new SavedTab()])]));
            });
            if (!await WriteNewFileAsync(window, workspace.Key, null, file, path) || _quitting)
                return;

            _workspaces.Add(workspace);
            Show(Open(null, null, workspace, windowId));
            AddRecentWorkspace(workspace.Key);
            _store.Schedule();
        }
        catch (Exception error)
        {
            CrashLog.Recovered("New Workspace (not created)", error);
        }
    }

    private async Task ChooseWorkspaceAsync(MainWindow window)
    {
        if (_picking)
            return;
        _picking = true;
        string? path;
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
            picker.FileTypeFilter.Add(WorkspaceExtension);
            // An unpackaged app's picker needs its owner window.
            InitializeWithWindow.Initialize(picker, window.Handle);
            StorageFile? file = await picker.PickSingleFileAsync();
            path = file?.Path;
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: workspace picker failed: {error.Message}");
            return;
        }
        finally
        {
            _picking = false;
        }

        if (string.IsNullOrEmpty(path) || _quitting || !_windows.Contains(window))
            return;
        OpenWorkspace(path, window);
    }

    private async Task OpenWorkspaceAsync(string path, MainWindow? from)
    {
        try
        {
            string key = await Task.Run(() => WorkspaceFile.IdentityKey(path));
            if (_quitting)
                return;
            if (OpenWorkspaceAt(key) is { } open)
            {
                BringForward(open);
                return;
            }

            if (!_busyKeys.Add(key))
                return;
            WorkspaceDocument.Opened read;
            try
            {
                read = await Task.Run(() => WorkspaceDocument.Open(path));
            }
            catch (Exception error)
            {
                Trace.WriteLine($"Histq: workspace not opened: {error.Message}");
                ShowWorkspaceProblem(from, $"\"{FileName(path)}\" could not be opened.", Reason(error));
                return;
            }
            finally
            {
                _busyKeys.Remove(key);
            }

            if (_quitting)
                return;
            if (OpenWorkspaceAt(read.Document.Key) is { } again)
            {
                BringForward(again);
                return;
            }

            OpenBackToFront(PlaceWorkspace(read, null));
            Seed(read.Document);
            _store.Schedule();
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Open Workspace (not opened)", error);
        }
    }

    private async Task SaveWorkspaceAsAsync(MainWindow window)
    {
        try
        {
            WorkspaceDocument? workspace = OpenWorkspaceOf(window);
            if (window.Workspace is not null && workspace is null)
                return;
            if (await PickWorkspaceFileAsync(window, workspace?.Name ?? "Untitled") is not { } path)
                return;
            if (workspace is null)
                await SaveUntitledAsAsync(window, path);
            else
                await RebindWorkspaceAsync(window, workspace, path);
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Save Workspace As (not saved)", error);
        }
    }

    /// <summary>Save As from a workspace window: the workspace is written to <paramref name="path"/> and rebound to it
    /// (every path relative to the new folder; the old file keeps its last content). The rebasing and the build run on
    /// a copy off the UI thread; the document takes the result once the file is written.</summary>
    private async Task RebindWorkspaceAsync(MainWindow window, WorkspaceDocument workspace, string path)
    {
        if (!_workspaces.Contains(workspace) || workspace.IsClosing)
            return;
        List<WorkspaceFile.LiveWindow> windows =
            [.. WindowsOf(workspace).Select(member => member.Tabs.LiveWindow(member.WindowId))];
        WorkspaceDocument copy = workspace.Copy();
        (WorkspaceDocument.Rebinding rebinding, WorkspaceFile file) = await Task.Run(() =>
        {
            WorkspaceDocument.Rebinding rebound = copy.Rebound(path);
            return (rebound, copy.Build(windows, path, rebound.Originals, rebound.Carried));
        });
        if (!_workspaces.Contains(workspace) || workspace.IsClosing
            || !await WriteNewFileAsync(window, rebinding.Key, workspace, file, path))
            return;
        // Closed meanwhile: the copy stays on disk, the closed workspace keeps its file.
        if (!_workspaces.Contains(workspace) || workspace.IsClosing)
            return;

        workspace.Rebind(rebinding);
        foreach (MainWindow member in WindowsOf(workspace))
            member.ShowWorkspace();
        AddRecentWorkspace(workspace.Key);
        _store.Schedule();
    }

    /// <summary>Save As from an Untitled window: every Untitled window (in the order they opened) joins a new workspace
    /// written to <paramref name="path"/>. Their tabs are the user's own, so their models stay as they are.</summary>
    private async Task SaveUntitledAsAsync(MainWindow window, string path)
    {
        List<MainWindow> untitled = [.. _windows.Where(other => other.Workspace is null).OrderBy(other => other.Sequence)];
        List<WorkspaceFile.LiveWindow> windows = [.. untitled.Select(member => member.Tabs.LiveWindow(member.WindowId))];
        (WorkspaceDocument workspace, WorkspaceFile file) = await Task.Run(() =>
        {
            var created = new WorkspaceDocument(path);
            created.WindowOrder.AddRange(windows.Select(live => live.Id));
            return (created, created.Build(windows));
        });
        if (!await WriteNewFileAsync(window, workspace.Key, null, file, path) || _quitting)
            return;
        List<MainWindow> joining = untitled.FindAll(member => _windows.Contains(member) && member.Workspace is null);
        if (joining.Count == 0)
            return;

        _workspaces.Add(workspace);
        foreach (MainWindow member in joining)
            member.Workspace = workspace;
        AddRecentWorkspace(workspace.Key);
        _store.Schedule();
    }

    /// <summary>
    /// Writes a new workspace file now (Save As, New Workspace), after checking that <paramref name="key"/> may become
    /// the file of <paramref name="workspace"/> (null: a new one): not another open workspace's, nor one being read or
    /// written. False, with a toast in <paramref name="window"/> naming the problem, when it may not or the write fails.
    /// </summary>
    private async Task<bool> WriteNewFileAsync(
        MainWindow window, string key, WorkspaceDocument? workspace, WorkspaceFile file, string path)
    {
        if (_quitting)
            return false;
        if (_busyKeys.Contains(key)
            || _workspaces.Exists(open => open != workspace && PathFlavor.Host.KeysEqual(open.Key, key)))
        {
            ShowWorkspaceProblem(window, $"\"{FileName(path)}\" is open as another workspace.",
                "Close that workspace first, or choose another file.");
            return false;
        }

        _busyKeys.Add(key);
        try
        {
            await _store.WriteNowAsync(file, path);
            return true;
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: workspace not saved: {error.Message}");
            ShowWorkspaceProblem(window, $"\"{FileName(path)}\" could not be saved.", Reason(error));
            return false;
        }
        finally
        {
            _busyKeys.Remove(key);
        }
    }

    /// <summary>A save picker for a workspace file named <paramref name="name"/>, owned by <paramref name="window"/>.
    /// The picked file's path; null when the user cancels, another picker is open, or the window closed meanwhile.</summary>
    private async Task<string?> PickWorkspaceFileAsync(MainWindow window, string name)
    {
        if (_picking)
            return null;
        _picking = true;
        string? path;
        try
        {
            var picker = new FileSavePicker
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
                SuggestedFileName = name,
                DefaultFileExtension = WorkspaceExtension,
            };
            picker.FileTypeChoices.Add("Histq workspace", [WorkspaceExtension]);
            // An unpackaged app's picker needs its owner window.
            InitializeWithWindow.Initialize(picker, window.Handle);
            StorageFile? file = await picker.PickSaveFileAsync();
            path = file?.Path;
        }
        catch (Exception error)
        {
            Trace.WriteLine($"Histq: workspace picker failed: {error.Message}");
            return null;
        }
        finally
        {
            _picking = false;
        }

        return string.IsNullOrEmpty(path) || _quitting || !_windows.Contains(window) ? null : path;
    }

    /// <summary>The open workspace whose file is <paramref name="key"/> and that has a window; null when none.</summary>
    private WorkspaceDocument? OpenWorkspaceAt(string key) =>
        _workspaces.Find(open => !open.IsClosing && PathFlavor.Host.KeysEqual(open.Key, key) && WindowsOf(open).Count > 0);

    /// <summary>Shows the front window of <paramref name="workspace"/> (it was opened again) and moves its file up in
    /// Recent Workspaces.</summary>
    private void BringForward(WorkspaceDocument workspace)
    {
        AddRecentWorkspace(workspace.Key);
        if (_windows.Find(window => window.Workspace == workspace) is { } front)
            Show(front);
    }

    /// <summary>A warning toast in <paramref name="window"/> (else the front window; a Welcome window when none is
    /// open).</summary>
    private void ShowWorkspaceProblem(MainWindow? window, string title, string detail)
    {
        if (_quitting)
            return;
        MainWindow target = window is not null && _windows.Contains(window) ? window
            : _windows.Count > 0 ? _windows[0]
            : Open(null, null, null);
        target.ShowToast(title, detail);
    }

    /// <summary>The file's name as a toast shows it (the toast sanitizes it).</summary>
    private static string FileName(string path) => PathFlavor.Host.LastComponent(path);

    /// <summary>Why a workspace file could not be read or written, for a toast (HistqApp.swift message(for:)).</summary>
    private static string Reason(Exception error) => error switch
    {
        WorkspaceFileError { Kind: WorkspaceFileErrorKind.UnsupportedVersion } other =>
            $"It was saved by another version of Histq (workspace format {other.Version}) and is left unchanged.",
        WorkspaceFileError { Kind: WorkspaceFileErrorKind.Undecodable } => "It is not a Histq workspace file.",
        WorkspaceFileError { Kind: WorkspaceFileErrorKind.Empty } => "A workspace needs a window with at least one tab.",
        _ => error.Message,
    };
}

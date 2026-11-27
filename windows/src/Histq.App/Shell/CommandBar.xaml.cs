using System.Diagnostics;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Histq.App.Shell;

/// <summary>
/// The command bar at the top of the sheet (design header-and-tab-row.md §1.3, ported from App/Window/HeaderToolbar.swift
/// at 6fa6d40): the repo dropdown (the selected tab's folder name, "Histq" on a Welcome tab; its menu lists the window's
/// repo tabs, the recent repos not open here and Open…), the Row Height capsule (the graphs' row density, as on the
/// Mac) and the workspace dropdown (workspace windows only, with its
/// read-only or not-saved warning; its menu has the workspace commands and the other recent workspaces). The branch dropdown, the profile chip and the action capsules are absent until the
/// milestone that implements each action. A ToolBar named "Command bar" in UI Automation.
/// </summary>
public sealed partial class CommandBar : UserControl
{
    /// <summary>The workspace label shows at most this many characters of the name (an ellipsis included).</summary>
    private const int WorkspaceNameLimit = 12;

    private const string WorkspaceGlyph = "";
    private const string WarningGlyph = "";

    private MainWindow _window = null!;

    /// <summary>The selected tab's folder the repo dropdown shows now, so it is only written when it changes.</summary>
    private string? _repoPath;
    private bool _repoShown;

    /// <summary>What the workspace label shows now, so it is only written when it changes.</summary>
    private (string Text, string ToolTip, bool IsWarning)? _workspaceShown;

    public CommandBar()
    {
        InitializeComponent();
        RepoMenu.Opening += (_, _) => FillRepoMenu();
        WorkspaceMenu.Opening += (_, _) => FillWorkspaceMenu();
        RowHeightMenu.Opening += (_, _) => FillRowHeightMenu();
    }

    /// <summary>Row Height ▾: Compact, Regular, Comfortable, the current one checked; a pick sets rowDensity for every
    /// graph at once (HeaderToolbar.rowHeightEntries).</summary>
    private void FillRowHeightMenu()
    {
        RowHeightMenu.Items.Clear();
        string current = _window.Manager.GraphLook.RowDensity;
        foreach (string density in new[] { "compact", "regular", "comfortable" })
        {
            var item = new ToggleMenuFlyoutItem
            {
                Text = char.ToUpperInvariant(density[0]) + density[1..],
                IsChecked = string.Equals(density, current, StringComparison.Ordinal),
            };
            item.Click += (_, _) => _window.Manager.SetRowDensity(density);
            RowHeightMenu.Items.Add(item);
        }
    }

    internal void Attach(MainWindow window) => _window = window;

    /// <summary>Brings the repo dropdown in line with the selected tab: its folder's name (never the tab's alias, which
    /// only shortens the tab itself) and its path as tooltip.</summary>
    internal void Update()
    {
        WindowTabs tabs = _window.Tabs;
        string? path = tabs.SelectedIndex is { } index ? tabs.Tabs[index].Path : null;
        if (_repoShown && string.Equals(path, _repoPath, StringComparison.Ordinal))
            return;
        _repoShown = true;
        _repoPath = path;
        RepoTitle.Text = path is null ? "Histq" : DisplayText.Sanitize(PathFlavor.Host.LastComponent(path));
        ToolTipService.SetToolTip(RepoButton, path is null ? "Switch repository" : DisplayText.Sanitize(path));
    }

    /// <summary>
    /// The workspace label from the window's workspace (its name, path, read-only flag and last write's error);
    /// collapsed for null (a window that is not a workspace's). A read-only file or a failed write turns it into a
    /// warning (the orange triangle) and the tooltip says why.
    /// </summary>
    internal void ShowWorkspace(WorkspaceDocument? workspace)
    {
        if (workspace is null)
        {
            _workspaceShown = null;
            WorkspaceLabel.Visibility = Visibility.Collapsed;
            return;
        }

        string name = DisplayText.Sanitize(workspace.Name, WorkspaceNameLimit);
        string path = DisplayText.Sanitize(workspace.FilePath);
        string reason = workspace.WriteError is { } error ? DisplayText.Sanitize(error) : "the file could not be written";
        (string Text, string ToolTip, bool IsWarning) shown = workspace.IsReadOnly
            ? (name,
                $"{path}\nRead-only: made by a newer Histq, so changes to this workspace are not saved. "
                    + "Save Workspace As… makes a copy this version saves.",
                true)
            : workspace.WriteFailed
                ? (name, $"{path}\nNot saved: {reason}\nChanges to this workspace are not saved until a write succeeds.", true)
                : (name, path, false);
        if (_workspaceShown != shown)
        {
            _workspaceShown = shown;
            WorkspaceText.Text = shown.Text;
            ToolTipService.SetToolTip(WorkspaceLabel, shown.ToolTip);
            AutomationProperties.SetHelpText(WorkspaceLabel, shown.ToolTip);
            WorkspaceIcon.Glyph = shown.IsWarning ? WarningGlyph : WorkspaceGlyph;
            if (shown.IsWarning)
                WorkspaceIcon.Foreground = (Brush)Resources["WorkspaceWarningBrush"];
            else
                WorkspaceIcon.ClearValue(IconElement.ForegroundProperty);
            string state = workspace.IsReadOnly ? ", read-only" : workspace.WriteFailed ? ", not saved" : string.Empty;
            AutomationProperties.SetName(WorkspaceLabel, $"Workspace {shown.Text}{state}");
        }

        WorkspaceLabel.Visibility = Visibility.Visible;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new CommandBarAutomationPeer(this);

    /// <summary>
    /// The repo menu, built as it opens: the window's repo tabs (the selected one checked; a pick selects that tab at
    /// once, as a click on it does), the recent repos not open here (a pick opens it), then Open…. Listing compares
    /// paths as strings only, so a UNC entry is never probed until it is picked.
    /// </summary>
    private void FillRepoMenu()
    {
        RepoMenu.Items.Clear();
        WindowTabs tabs = _window.Tabs;
        PathFlavor flavor = PathFlavor.Host;

        var open = new HashSet<string>(flavor.KeyComparer);
        foreach (WindowTabs.Tab tab in tabs.Tabs)
        {
            if (tab.Path is not { } path)
                continue;
            open.Add(flavor.Standardized(path));
            Guid id = tab.Id;
            var item = new ToggleMenuFlyoutItem
            {
                Text = DisplayText.Sanitize(flavor.LastComponent(path)),
                IsChecked = id == tabs.SelectedTabId,
            };
            ToolTipService.SetToolTip(item, DisplayText.Sanitize(path));
            item.Click += (_, _) => _window.Apply(model => model.SelectTab(id));
            RepoMenu.Items.Add(item);
        }

        var recent = _window.Manager.RecentRepos.Paths.Where(path => !open.Contains(flavor.Standardized(path))).ToList();
        if (recent.Count > 0)
        {
            AddSeparator();
            RepoMenu.Items.Add(new MenuFlyoutItem { Text = "Recent", IsEnabled = false });
            foreach (string path in recent)
            {
                var item = new MenuFlyoutItem { Text = DisplayText.Sanitize(flavor.LastComponent(path)) };
                ToolTipService.SetToolTip(item, DisplayText.Sanitize(path));
                item.Click += (_, _) => _window.Manager.OpenRepo(_window, path);
                RepoMenu.Items.Add(item);
            }
        }

        AddSeparator();
        var openItem = new MenuFlyoutItem { Text = "Open…", KeyboardAcceleratorTextOverride = "Ctrl+O" };
        openItem.Click += (_, _) => _window.Manager.ChooseFolder(_window);
        RepoMenu.Items.Add(openItem);
    }

    /// <summary>
    /// The workspace menu, built as it opens (HeaderToolbar.swift workspaceEntries): Show in Explorer, Save Workspace
    /// As…, Close Workspace, the recent workspaces other than this one (a pick opens it, or brings it forward), then New
    /// Workspace and Open Workspace…. Listing compares the keys as strings only, never checking the disk.
    /// </summary>
    private void FillWorkspaceMenu()
    {
        WorkspaceMenu.Items.Clear();
        if (_window.Workspace is not { } workspace)
            return;
        WindowManager manager = _window.Manager;
        WorkspaceMenu.Items.Add(Plain("Show in Explorer", () => ShowInExplorer(_window, workspace.FilePath)));
        WorkspaceMenu.Items.Add(Plain("Save Workspace As…", () => manager.SaveWorkspaceAs(_window)));
        WorkspaceMenu.Items.Add(Plain("Close Workspace", () => manager.CloseWorkspace(_window)));

        PathFlavor flavor = PathFlavor.Host;
        var recent = manager.RecentWorkspaces.Paths.Where(path => !flavor.KeysEqual(path, workspace.Key)).ToList();
        if (recent.Count > 0)
        {
            WorkspaceMenu.Items.Add(new MenuFlyoutSeparator());
            WorkspaceMenu.Items.Add(new MenuFlyoutItem { Text = "Recent", IsEnabled = false });
            foreach (string path in recent)
            {
                MenuFlyoutItem item = Plain(
                    DisplayText.Sanitize(Path.GetFileNameWithoutExtension(flavor.LastComponent(path))),
                    () => manager.OpenWorkspace(path, _window));
                ToolTipService.SetToolTip(item, DisplayText.Sanitize(path));
                WorkspaceMenu.Items.Add(item);
            }
        }

        WorkspaceMenu.Items.Add(new MenuFlyoutSeparator());
        WorkspaceMenu.Items.Add(Plain("New Workspace", () => manager.NewWorkspace(_window)));
        WorkspaceMenu.Items.Add(Plain("Open Workspace…", () => manager.ChooseWorkspace(_window)));
    }

    /// <summary>A menu item that runs <paramref name="action"/>.</summary>
    private static MenuFlyoutItem Plain(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>A separator, unless the menu is still empty.</summary>
    private void AddSeparator()
    {
        if (RepoMenu.Items.Count > 0)
            RepoMenu.Items.Add(new MenuFlyoutSeparator());
    }

    /// <summary>Show in Explorer (the Mac's Reveal in Finder): Explorer opens the workspace file's folder with the file
    /// selected. The file check and the launch run off the UI thread; the path is passed as an argument, never through
    /// a shell. A file that is gone, or an Explorer that does not start, shows a toast.</summary>
    private static async void ShowInExplorer(MainWindow window, string path)
    {
        string? problem;
        try
        {
            problem = await Task.Run(() => Reveal(path));
        }
        catch (Exception)
        {
            // Expected (a path Windows refuses, Explorer not starting): a toast, not a crash.log entry.
            problem = "Explorer could not be opened.";
        }

        if (problem is not null)
            window.ShowToast("Show in Explorer", problem);
    }

    /// <summary>Starts Explorer with the file at <paramref name="path"/> selected; the reason it did not, or null.</summary>
    private static string? Reveal(string path)
    {
        string full = Path.GetFullPath(path);
        if (!File.Exists(full))
            return "The workspace file is gone.";

        string explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
        var start = new ProcessStartInfo(explorer) { UseShellExecute = false };
        start.ArgumentList.Add("/select,");
        start.ArgumentList.Add(full);
        // Explorer hands the window to its running instance and exits with 1: its exit code means nothing.
        using Process? process = Process.Start(start);
        return process is null ? "Explorer could not be opened." : null;
    }
}

/// <summary>The command bar in UI Automation: a ToolBar named "Command bar", so vmpal_tree finds it.</summary>
internal sealed partial class CommandBarAutomationPeer(CommandBar owner) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.ToolBar;

    protected override string GetClassNameCore() => nameof(CommandBar);

    protected override string GetNameCore() => "Command bar";

    protected override bool IsControlElementCore() => true;
}

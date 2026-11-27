using System.Globalization;
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
/// repo tabs, the recent repos not open here and Open…) and the workspace label (workspace windows only, with its
/// read-only or not-saved warning). The branch dropdown, the profile chip and the action capsules are absent until the
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
        RepoTitle.Text = path is null ? "Histq" : PathFlavor.Host.LastComponent(path);
        ToolTipService.SetToolTip(RepoButton, path ?? "Switch repository");
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

        string name = Truncated(workspace.Name, WorkspaceNameLimit);
        string path = workspace.FilePath;
        string reason = workspace.WriteError ?? "the file could not be written";
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
                Text = flavor.LastComponent(path),
                IsChecked = id == tabs.SelectedTabId,
            };
            ToolTipService.SetToolTip(item, path);
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
                var item = new MenuFlyoutItem { Text = flavor.LastComponent(path) };
                ToolTipService.SetToolTip(item, path);
                item.Click += (_, _) => _window.Manager.OpenRepo(_window, path);
                RepoMenu.Items.Add(item);
            }
        }

        AddSeparator();
        var openItem = new MenuFlyoutItem { Text = "Open…", KeyboardAcceleratorTextOverride = "Ctrl+O" };
        openItem.Click += (_, _) => _window.Manager.ChooseFolder(_window);
        RepoMenu.Items.Add(openItem);
    }

    /// <summary>A separator, unless the menu is still empty.</summary>
    private void AddSeparator()
    {
        if (RepoMenu.Items.Count > 0)
            RepoMenu.Items.Add(new MenuFlyoutSeparator());
    }

    /// <summary><paramref name="text"/> cut to <paramref name="limit"/> characters (user-perceived), the last one an
    /// ellipsis.</summary>
    private static string Truncated(string text, int limit)
    {
        var info = new StringInfo(text);
        return info.LengthInTextElements > limit ? info.SubstringByTextElements(0, limit - 1) + "…" : text;
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

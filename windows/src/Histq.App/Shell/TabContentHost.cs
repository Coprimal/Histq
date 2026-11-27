using Histq.App.Repo;
using Histq.App.Welcome;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Histq.App.Shell;

/// <summary>
/// The selected tab's area in the sheet (ported from TabContent, App/MainView.swift at 6fa6d40): the layout of a repo
/// tab (<see cref="RepoLayoutView"/>), "Repo not found" for a repo that is gone (<see cref="RepoNotFoundView"/>), or the
/// Welcome page of a new tab. The layouts of the repo tabs shown last (<see cref="WindowTabs.RecentlyShown"/>, at most
/// <see cref="WindowTabs.KeptLayouts"/>) stay mounted, Collapsed and not hit-testable while another tab shows, so a
/// switch back shows the tab as it was without building it again (its log is not read again). "Repo not found" and
/// Welcome (<see cref="WelcomePage"/>) are made per tab and only while selected. A layout unmounted (its tab gone or no
/// longer kept, the window closed) stops its load. In a workspace window a tab on a UNC or device path shows "Repo not
/// found" whatever its folder check says, so no git ever runs in a received network folder.
/// </summary>
public sealed partial class TabContentHost : Grid
{
    private readonly Dictionary<Guid, Mounted> _mounted = [];

    private MainWindow _window = null!;

#if HISTQ_QA
    private FrameworkElement? _qaContent;
#endif

    private enum ContentKind
    {
        Welcome,
        Repo,
        Missing,
    }

    /// <summary>A tab's mounted content, with what it was made for: a Welcome tab filled in place, or a missing repo
    /// found again, keeps its id but gets new content.</summary>
    private sealed record Mounted(ContentKind Kind, string? Path, FrameworkElement Element);

    /// <summary>The window whose tabs it shows; call it before the first <see cref="Sync"/>. Its close stops every
    /// mounted repo layout's load.</summary>
    internal void Attach(MainWindow window)
    {
        _window = window;
        // The tree goes with the window: only the loads are stopped.
        window.Closed += (_, _) =>
        {
            foreach (Mounted mounted in _mounted.Values)
                (mounted.Element as RepoLayoutView)?.Close();
        };
    }

    /// <summary>The recent repos changed: the mounted Welcome page lists them again.</summary>
    internal void ShowRecentRepos()
    {
        foreach (Mounted mounted in _mounted.Values)
        {
            if (mounted.Element is WelcomePage page)
                page.ShowRecent();
        }
    }

    /// <summary>
    /// Brings the host in line with <paramref name="tabs"/>; call it after every <see cref="WindowTabs"/> call. The
    /// content of a tab that is gone (closed, archived, moved: <see cref="WindowTabs"/> raises no removal event) or no
    /// longer kept is unmounted; the selected tab's content is made in this call, so it shows in the same frame as the
    /// selection.
    /// </summary>
    public void Sync(WindowTabs tabs)
    {
        Guid? selected = tabs.SelectedTabId;
        var recent = new HashSet<Guid>(tabs.RecentlyShown);
        // In tab order: a switch never moves a kept layout in the stack.
        var wanted = tabs.Tabs
            .Where(tab => tab.Id == selected || (KindOf(tab) == ContentKind.Repo && recent.Contains(tab.Id)))
            .ToList();
        var byId = wanted.ToDictionary(tab => tab.Id);

        foreach (var (id, mounted) in _mounted.ToList())
        {
            if (!byId.TryGetValue(id, out var tab) || mounted.Kind != KindOf(tab)
                || !string.Equals(mounted.Path, tab.Path, StringComparison.Ordinal))
            {
                Unmount(id);
            }
        }

        foreach (var tab in wanted)
        {
            if (!_mounted.TryGetValue(tab.Id, out var mounted))
            {
                var kind = KindOf(tab);
                mounted = new Mounted(kind, tab.Path, Make(kind, tab));
                _mounted[tab.Id] = mounted;
                Children.Add(mounted.Element);
            }

            bool isShown = tab.Id == selected && !ShowsQaContent;
            mounted.Element.Visibility = isShown ? Visibility.Visible : Visibility.Collapsed;
            mounted.Element.IsHitTestVisible = isShown;
        }
    }

#if HISTQ_QA
    /// <summary>
    /// QA builds: shows <paramref name="content"/> (the spike harness's graph) in place of every tab's content, which
    /// stays mounted but Collapsed. Returns it.
    /// </summary>
    internal T ShowQaContent<T>(T content)
        where T : FrameworkElement
    {
        _qaContent = content;
        Children.Add(content);
        foreach (var mounted in _mounted.Values)
        {
            mounted.Element.Visibility = Visibility.Collapsed;
            mounted.Element.IsHitTestVisible = false;
        }

        return content;
    }

    private bool ShowsQaContent => _qaContent is not null;
#else
    private static bool ShowsQaContent => false;
#endif

    /// <summary>A tab's kind of content. A received UNC or device folder (a workspace window's) is never read: it shows
    /// as missing (a string check, nothing probed).</summary>
    private ContentKind KindOf(WindowTabs.Tab tab)
    {
        if (tab.Path is not { } path)
            return ContentKind.Welcome;
        bool received = _window.Workspace is not null && PathFlavor.Host.IsUncOrDevice(path);
        return tab.IsMissing || received ? ContentKind.Missing : ContentKind.Repo;
    }

    /// <summary>A tab's content: the Welcome page, the repo layout (its log load starts here, off the UI thread) or
    /// "Repo not found".</summary>
    private FrameworkElement Make(ContentKind kind, WindowTabs.Tab tab) => kind switch
    {
        ContentKind.Welcome => new WelcomePage(_window),
        ContentKind.Repo => new RepoLayoutView(_window, tab.Path!),
        _ => new RepoNotFoundView(_window, tab.Id, tab.Path ?? ""),
    };

    /// <summary>Removes a tab's content; a repo layout stops its load.</summary>
    private void Unmount(Guid id)
    {
        if (!_mounted.Remove(id, out Mounted? mounted))
            return;
        Children.Remove(mounted.Element);
        if (mounted.Element is RepoLayoutView layout)
            layout.Close();
    }
}

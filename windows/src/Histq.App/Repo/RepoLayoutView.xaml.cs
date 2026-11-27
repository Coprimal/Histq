using Histq.App.Detail;
using Histq.App.Graph;
using Histq.App.Shell;
using Histq.App.Sidebar;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Windows.ApplicationModel.DataTransfer;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace Histq.App.Repo;

/// <summary>
/// A repo tab (ported from RepoLayoutView, App/Repo/RepoLayoutView.swift at 6fa6d40, its Classic layout): sidebar |
/// commit graph | detail. The sidebar (<see cref="SidebarView"/>) lists the refs, worktrees and stashes of the graph's
/// own data; a click on one of its rows selects that row's commit (or changes' row) in the graph and scrolls it into
/// view in the same call, as on the Mac (RepoSession.selectRef); a ref whose commit is not in the first page yet is
/// revealed once the rows come.
/// <para>
/// It holds the graph's view of the repo (<see cref="RepoViewState"/>: hidden, soloed and pinned branches, hide stale),
/// as on the Mac: a workspace window's from its workspace, else the folder's own file (read by the session before the
/// first rows). The ref and commit menus (<see cref="IRepoMenuHost"/>: the sidebar's rows, the graph's rows) change it
/// in the click's frame: the sidebar and the graph's "N hidden · Show All" chip follow at once (<see
/// cref="LogFilter.For"/> on this thread), the session reads the log again through it, and it is saved
/// (<see cref="WindowManager.SaveRepoView"/>).
/// </para> Made by <see cref="TabContentHost"/> in the same call as the tab's selection, so its cards and
/// the graph's placeholder show in that frame; its <see cref="RepoTabSession"/> reads the log off the UI thread and the
/// graph (<see cref="GraphView"/>, which takes the XAML's plain canvas's place in code) shows the rows as they come. It
/// stays mounted while another tab shows, among the last tabs shown; shown again, it has its session read the worktrees
/// (and the status) again. When it is unmounted (the tab closed or no longer kept, its window closed)
/// <see cref="Close"/> stops the load.
/// <para>
/// The side panels' widths are the app's (<see cref="WindowManager.PanelWidths"/>, the panelWidths preference), fitted in
/// this layout's width (<see cref="PanelWidths.Fitted"/>) whenever it changes size or the widths change. The two gaps are
/// dividers: a drag moves the panel's edge (<see cref="PanelWidths.DraggingSidebar"/>,
/// <see cref="PanelWidths.DraggingDetail"/>) and its end saves the widths for every layout. Widths are written only when
/// they change, from SizeChanged and pointer events, never from a layout pass.
/// </para>
/// </summary>
public sealed partial class RepoLayoutView : UserControl, IRepoMenuHost
{
    private readonly MainWindow _window;
    private readonly string _path;

    /// <summary>The graph's view, the refs last read, and what the graph leaves out for them (UI thread).</summary>
    private RepoViewState _view = RepoViewState.Empty;
    private bool _viewKnown;
    private Refs? _refs;
    private LogFilter _visibility = LogFilter.None;
    private readonly RepoTabSession _session;
    private readonly GraphView _graph;
    private readonly GraphSearchBar _search;
    private readonly CommitSummaryView _summary = new();
    private readonly SidebarView _sidebar;
    private readonly GraphDateFormatter _dates;

    /// <summary>The detail card, and the skeleton it shows while no row is selected.</summary>
    private readonly Border _detailCard;
    private readonly UIElement _detailSkeleton;
    private readonly DispatcherQueueTimer _spinnerTimer;

    /// <summary>The widths the columns have now (fitted); the start of a drag.</summary>
    private PanelWidths _shown;

    /// <summary>The widths while a divider is dragged; null otherwise.</summary>
    private PanelWidths? _dragWidths;

    /// <summary>The dragged divider, where the drag began (layout X) and the widths shown then.</summary>
    private (PanelDivider Divider, double StartX, PanelWidths Start)? _drag;

    private bool _closed;

    /// <summary>Whether the layout was shown when its visibility last changed.</summary>
    private bool _isShown = true;

    /// <summary>A sidebar row's graph items that had no row yet (only the first page is in): revealed when the rows
    /// come, until the log is complete or another row is selected.</summary>
    private IReadOnlyList<GraphItem>? _pendingReveal;

    internal RepoLayoutView(MainWindow window, string path)
    {
        _window = window;
        _path = path;
        InitializeComponent();
        Grid graphHost;
        (_graph, graphHost) = SwapInGraphView();
        _search = new GraphSearchBar(_graph);
        graphHost.Children.Add(_search);
        _dates = new GraphDateFormatter(_window.Manager.GraphLook.DateFormat);
        _detailCard = DetailPanel.Children.OfType<Border>().First();
        _detailSkeleton = _detailCard.Child;
        _graph.SelectionChanged += OnSelectionChanged;
        _summary.ParentClicked += OnParentClicked;
        _sidebar = new SidebarView(_window.Manager.SidebarSections);
        SidebarPanel.Children.Add(_sidebar);
        _sidebar.RowInvoked += OnSidebarRowInvoked;
        _sidebar.SetHost(this);
        _graph.RowMenuRequested += OnGraphRowMenuRequested;
        _graph.ShowAllRequested += () => ((IRepoMenuHost)this).ShowAll();

        // Ctrl+F: the graph search of the shown tab (a kept tab's layout is Collapsed and leaves it to the others).
        var find = new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control };
        find.Invoked += OnFindInvoked;
        KeyboardAccelerators.Add(find);
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyDown += OnLayoutKeyDown;

        GraphSpinner.OpacityTransition = new ScalarTransition
        {
            Duration = PaletteResources.TimeSpan("MotionStandardDuration"),
        };
        _spinnerTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _spinnerTimer.Interval = PaletteResources.TimeSpan("SpinnerDelay");
        _spinnerTimer.IsRepeating = false;
        _spinnerTimer.Tick += (_, _) => ShowSpinner();
        _spinnerTimer.Start();

        SizeChanged += (_, _) => ApplyWidths();
        _window.Manager.PanelWidthsChanged += OnPanelWidthsChanged;
        foreach (PanelDivider divider in new[] { SidebarDivider, DetailDivider })
        {
            divider.PointerPressed += OnDividerPressed;
            divider.PointerMoved += OnDividerMoved;
            divider.PointerReleased += OnDividerReleased;
            divider.PointerCaptureLost += OnDividerCaptureLost;
        }

        // A workspace's own view of the repo; else the session reads the folder's file (ViewLoaded).
        RepoViewState? stored = _window.Manager.WorkspaceView(_window, path);
        if (stored is not null)
            (_view, _viewKnown) = (stored, true);
        // A launch folder's session already reading since the launch (none with a workspace's stored view: it read the
        // folder's own), else a new one.
        _session = (stored is null ? GitWarmup.TakeSession(path) : null)
            ?? new RepoTabSession(
                path, _window.Manager.Preferences, _window.Manager.GraphLook.FadeOtherWorktrees,
                ((App)Application.Current).StatePaths.Root, DispatcherQueue.GetForCurrentThread(), stored);
        _session.ViewLoaded += OnViewLoaded;
        _session.Loaded += OnLoaded;
        _session.Failed += OnFailed;
        _session.Attach(DispatcherQueue.GetForCurrentThread());
        _session.Start();
        RegisterPropertyChangedCallback(VisibilityProperty, OnVisibilityChanged);
    }

    /// <summary>Unmounted: stops the load, the spinner's timer and the widths' updates, and releases the graph's canvas.
    /// Idempotent; UI thread, outside a layout pass.</summary>
    internal void Close()
    {
        if (_closed)
            return;
        _closed = true;
        _session.Dispose();
        _spinnerTimer.Stop();
        _window.Manager.PanelWidthsChanged -= OnPanelWidthsChanged;
        _search.Release();
        _summary.Release();
        _graph.Release();
    }

    // Graph

    /// <summary>
    /// Puts a <see cref="GraphView"/> where the XAML has its plain canvas (<c>CommitGraph</c>), its rows named as that
    /// canvas was in UI Automation, and releases that canvas. The graph card's grid is found from <c>PanelsGrid</c> down
    /// (its child in the third column, the graph's card), never through a Parent. Constructor only.
    /// </summary>
    private (GraphView Graph, Grid Host) SwapInGraphView()
    {
        var graph = new GraphView(_window.Manager, AutomationProperties.GetName(CommitGraph));
        var card = PanelsGrid.Children.OfType<Border>().First(border => Grid.GetColumn(border) == 2);
        var host = (Grid)card.Child;
        host.Children[host.Children.IndexOf(CommitGraph)] = graph;
        CommitGraph.Release();
        return (graph, host);
    }

    // Search and detail

    private void OnFindInvoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_closed || !_isShown || GraphFailure.Visibility == Visibility.Visible)
            return;
        _search.Open();
        args.Handled = true;
    }

    /// <summary>Esc in the layout (the graph has the focus): closes the open search bar.</summary>
    private void OnLayoutKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Escape && _search.IsOpen)
        {
            _search.Close();
            e.Handled = true;
        }
    }

    /// <summary>
    /// A row was selected (a click, the arrow keys, a search match, a parent link) or the selected one went away: the
    /// detail shows its summary's placeholder in this frame, the summary once made; nothing selected shows the skeleton.
    /// </summary>
    private void OnSelectionChanged(GraphItem? item)
    {
        if (_closed)
            return;
        _pendingReveal = null;
        _sidebar.ShowGraphSelection(item);
        if (item is not { } selected || _graph.Data is not { } data)
        {
            if (!ReferenceEquals(_detailCard.Child, _detailSkeleton))
                _detailCard.Child = _detailSkeleton;
            return;
        }

        if (!ReferenceEquals(_detailCard.Child, _summary))
            _detailCard.Child = _summary;
        _summary.Show(selected, data, _dates);
    }

    /// <summary>A parent's link: its commit's row is selected and revealed, as a click on it does.</summary>
    private void OnParentClicked(string hash) =>
        _graph.Select(new GraphItem(GraphItemKind.Commit, hash), _search.IsOpen ? _search.ActualHeight : 0);

    // Sidebar

    /// <summary>A sidebar row's click: its graph row is selected and scrolled into view now (the detail follows in the
    /// same call); while only the first page is in and it has no row yet, once the rows come.</summary>
    private void OnSidebarRowInvoked(SidebarRow row)
    {
        if (_closed)
            return;
        _pendingReveal = null;
        if (!Reveal(row.Targets) && _graph.Data?.Snapshot.IsComplete != true)
            _pendingReveal = row.Targets;
    }

    /// <summary>The first of <paramref name="targets"/> that has a row in the graph now; null for none.</summary>
    private GraphItem? Resolve(IReadOnlyList<GraphItem> targets)
    {
        foreach (GraphItem target in targets)
        {
            if (_graph.RowOf(target) >= 0)
                return target;
        }

        return null;
    }

    /// <summary>Selects and scrolls to the first of <paramref name="targets"/> the graph has a row for; false for none.</summary>
    private bool Reveal(IReadOnlyList<GraphItem> targets) =>
        Resolve(targets) is { } item && _graph.Select(item, _search.IsOpen ? _search.ActualHeight : 0);

    /// <summary>A first page, the complete log or a reload: the graph shows it (an empty log leaves the graph empty,
    /// as on the Mac).</summary>
    private void OnLoaded(GraphData data)
    {
        _graph.Show(data);
        if (data.Refs is { } refs)
            _refs = refs;
        UpdateVisibility();
        _sidebar.Show(data);
        if (_pendingReveal is { } pending && (Reveal(pending) || data.Snapshot.IsComplete))
            _pendingReveal = null;
        // A WIP or worktree row's summary holds its counts: it follows the new data (other rows' do not change).
        if (_graph.SelectedItem is { Kind: GraphItemKind.Wip or GraphItemKind.Worktree } selected
            && ReferenceEquals(_detailCard.Child, _summary))
        {
            _summary.Refresh(selected, data, _dates);
        }
        if (GraphPlaceholder.Visibility == Visibility.Visible)
            HidePlaceholder();
        if (GraphFailure.Visibility == Visibility.Visible)
        {
            GraphFailure.Visibility = Visibility.Collapsed;
            _graph.Visibility = Visibility.Visible;
        }
    }

    // The graph's view

    /// <summary>The folder's own saved view, read before the first rows (not when a menu changed it first). A workspace
    /// window records it in its workspace, as on the Mac.</summary>
    private void OnViewLoaded(RepoViewState view)
    {
        if (_closed || _viewKnown)
            return;
        (_view, _viewKnown) = (view, true);
        _window.Manager.RecordWorkspaceView(_window, _path, view);
        UpdateVisibility();
    }

    /// <summary>What the graph leaves out for the view against the refs; the sidebar and the chip follow.</summary>
    private void UpdateVisibility()
    {
        _visibility = _view.Equals(RepoViewState.Empty) || _refs is not { } refs ? LogFilter.None : LogFilter.For(_view, refs);
        _graph.ShowVisibility(_visibility.Hidden.Count, _visibility.Solo.Count > 0);
        _sidebar.ViewChanged();
    }

    /// <summary>A menu changed the view (RepoSession.viewChanged): in this frame the sidebar and the chip follow, then
    /// the log is read again through it and it is saved.</summary>
    private void ChangeView(RepoViewState view)
    {
        // Before the saved view is known a change would start from an empty one and overwrite it (the menus disable
        // their view items meanwhile).
        if (_closed || !_viewKnown || view.Equals(_view))
            return;
        (_view, _viewKnown) = (view, true);
        UpdateVisibility();
        _session.SetView(view);
        _window.Manager.SaveRepoView(_window, _path, view);
    }

    Refs? IRepoMenuHost.Refs => _refs;

    RepoViewState IRepoMenuHost.View => _view;

    bool IRepoMenuHost.ViewKnown => _viewKnown;

    LogFilter IRepoMenuHost.Visibility => _visibility;

    bool IRepoMenuHost.IsStale(string refName)
    {
        if (_refs is not { } refs)
            return false;
        DateTimeOffset? date = refs.LocalBranches.FirstOrDefault(branch => branch.RefName == refName)?.TipDate
            ?? refs.RemoteBranches.FirstOrDefault(branch => branch.RefName == refName)?.TipDate;
        return date < DateTimeOffset.Now - LogFilter.StaleAge;
    }

    /// <summary>Hides a branch or tag; never the current branch. Its sidebar row, if selected, no longer is.</summary>
    void IRepoMenuHost.Hide(string refName)
    {
        if (_refs?.Head is Head.Branch head && refName == "refs/heads/" + head.Name)
            return;
        if (_view.Hidden.Contains(refName))
            return;
        _sidebar.Deselect(refName);
        ChangeView(_view with { Hidden = [.. _view.Hidden, refName] });
    }

    /// <summary>Shows a ref again, and the hidden local branches it is the own upstream of.</summary>
    void IRepoMenuHost.Show(string refName)
    {
        HashSet<string> locals = (_refs?.LocalBranches ?? [])
            .Where(local => LogFilter.TracksOwnName(local) && "refs/remotes/" + local.Upstream == refName)
            .Select(local => local.RefName)
            .ToHashSet(StringComparer.Ordinal);
        List<string> hidden = [.. _view.Hidden.Where(name => name != refName && !locals.Contains(name))];
        if (hidden.Count != _view.Hidden.Count)
            ChangeView(_view with { Hidden = hidden });
    }

    void IRepoMenuHost.Solo(string refName)
    {
        if (!_view.Solo.Contains(refName))
            ChangeView(_view with { Solo = [.. _view.Solo, refName] });
    }

    void IRepoMenuHost.Unsolo(string refName)
    {
        if (_view.Solo.Contains(refName))
            ChangeView(_view with { Solo = [.. _view.Solo.Where(name => name != refName)] });
    }

    void IRepoMenuHost.Pin(string refName)
    {
        if (!_view.Pinned.Contains(refName))
            ChangeView(_view with { Pinned = [.. _view.Pinned, refName] });
    }

    void IRepoMenuHost.Unpin(string refName)
    {
        if (_view.Pinned.Contains(refName))
            ChangeView(_view with { Pinned = [.. _view.Pinned.Where(name => name != refName)] });
    }

    void IRepoMenuHost.SetHideStale(bool on)
    {
        if (_view.HideStale != on)
            ChangeView(_view with { HideStale = on });
    }

    /// <summary>Shows every branch: no hidden or soloed one, stale ones too. Pins stay.</summary>
    void IRepoMenuHost.ShowAll()
    {
        if (_view.Hidden.Count > 0 || _view.Solo.Count > 0 || _view.HideStale)
            ChangeView(_view with { Hidden = [], Solo = [], HideStale = false });
    }

    /// <summary>Puts <paramref name="text"/> on the clipboard (no I/O); a busy clipboard shows a toast.</summary>
    void IRepoMenuHost.Copy(string text, string what)
    {
        try
        {
            var data = new DataPackage();
            data.SetText(text);
            Clipboard.SetContent(data);
            Clipboard.Flush();
        }
        catch (Exception)
        {
            // Expected (another app holds the clipboard): a toast, not a crash.log entry.
            _window.ShowToast("Copy " + what, "The clipboard is in use by another app. Try again.");
        }
    }

    string? IRepoMenuHost.AuthorEmoji(string email, string name)
    {
        string identity = AvatarRenderer.Identity(email, name);
        return AvatarRenderer.AllowsEmoji(identity)
            && _window.Manager.GraphLook.AuthorEmojis.TryGetValue(identity, out string? emoji) ? emoji : null;
    }

    void IRepoMenuHost.AskAuthorEmoji(string email, string name) => _ = AskAuthorEmojiAsync(email, name);

    void IRepoMenuHost.RemoveAuthorEmoji(string email, string name) =>
        _window.Manager.SetAuthorEmoji(AvatarRenderer.Identity(email, name), null);

    /// <summary>Set Author Emoji…: the dialog, then the emoji for every graph (authorEmojis).</summary>
    private async Task AskAuthorEmojiAsync(string email, string name)
    {
        try
        {
            string? current = ((IRepoMenuHost)this).AuthorEmoji(email, name);
            if (_closed || XamlRoot is null
                || await AuthorEmojiDialog.AskAsync(XamlRoot, email, name, current) is not { } choice)
            {
                return;
            }

            _window.Manager.SetAuthorEmoji(AvatarRenderer.Identity(email, name), choice.Emoji);
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Set Author Emoji (not set)", error);
        }
    }

    /// <summary>A graph row's menu (a right click, the menu key): at the pointer, else at the row.</summary>
    private void OnGraphRowMenuRequested(GraphItem item, Windows.Foundation.Point? position)
    {
        if (_closed || _graph.Data is not { } data || GraphMenus.For(item, data, this) is not { } menu)
            return;
        GraphCanvas canvas = _graph.Canvas;
        long row = _graph.RowOf(item);
        var at = position ?? new Windows.Foundation.Point(24, Math.Max(0, canvas.TopOfRow(row) + canvas.RowHeight));
        menu.ShowAt(canvas, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Position = at });
    }

    private void OnFailed(string message)
    {
        HidePlaceholder();
        _graph.Visibility = Visibility.Collapsed;
        GraphFailureText.Text = message;
        GraphFailure.Visibility = Visibility.Visible;
    }

    /// <summary>Shown again (another tab was shown meanwhile): the session reads the worktrees and the status again.</summary>
    private void OnVisibilityChanged(DependencyObject sender, DependencyProperty property)
    {
        bool shown = Visibility == Visibility.Visible;
        if (shown == _isShown)
            return;
        _isShown = shown;
        if (_closed)
            return;
        _session.SetShown(shown);
        if (shown)
            _session.RefreshOnShow();
    }

    private void HidePlaceholder()
    {
        _spinnerTimer.Stop();
        GraphSpinner.IsActive = false;
        GraphPlaceholder.Visibility = Visibility.Collapsed;
    }

    /// <summary>The load is still under way after SpinnerDelay: the spinner fades in.</summary>
    private void ShowSpinner()
    {
        if (_closed || GraphPlaceholder.Visibility != Visibility.Visible)
            return;
        GraphSpinner.IsActive = true;
        GraphSpinner.Opacity = 1;
    }

    // Panel widths

    private void OnPanelWidthsChanged(object? sender, EventArgs e) => ApplyWidths();

    /// <summary>The width the three panels share: the layout's less its two gaps.</summary>
    private double Available => ActualWidth - 2 * RepoLayoutMetrics.Gap;

    /// <summary>Sets the side columns to the drag's or the app's widths fitted in this layout, when they changed.</summary>
    private void ApplyWidths()
    {
        if (_closed || ActualWidth <= 0)
            return;
        PanelWidths widths = (_dragWidths ?? _window.Manager.PanelWidths).Fitted(Available);
        if (widths == _shown)
            return;
        _shown = widths;
        SidebarColumn.Width = new GridLength(widths.Sidebar);
        DetailColumn.Width = new GridLength(widths.Detail);
    }

    private void OnDividerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not PanelDivider divider || _drag is not null
            || !e.GetCurrentPoint(divider).Properties.IsLeftButtonPressed || !divider.CapturePointer(e.Pointer))
            return;
        _drag = (divider, e.GetCurrentPoint(this).Position.X, _shown);
        e.Handled = true;
    }

    private void OnDividerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is not { } drag || !ReferenceEquals(sender, drag.Divider))
            return;
        // Against the layout, which stays put while the divider moves with the panel's edge.
        double dx = e.GetCurrentPoint(this).Position.X - drag.StartX;
        if (!double.IsFinite(dx))
            return;
        _dragWidths = ReferenceEquals(drag.Divider, SidebarDivider)
            ? drag.Start.DraggingSidebar(dx, Available)
            : drag.Start.DraggingDetail(dx, Available);
        ApplyWidths();
        e.Handled = true;
    }

    private void OnDividerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is not { } drag || !ReferenceEquals(sender, drag.Divider))
            return;
        EndDrag();
        drag.Divider.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void OnDividerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is { } drag && ReferenceEquals(sender, drag.Divider))
            EndDrag();
    }

    /// <summary>The drag ended: its widths become the app's (saved, and every layout takes them).</summary>
    private void EndDrag()
    {
        PanelWidths? widths = _dragWidths;
        _drag = null;
        _dragWidths = null;
        if (widths is { } ended && !_closed)
            _window.Manager.SetPanelWidths(ended);
        ApplyWidths();
    }
}

/// <summary>
/// A side panel of the repo layout: a Grid that UI Automation sees as a named group (a plain Grid has no automation
/// peer), so the sidebar and the detail can be found by name.
/// </summary>
public sealed partial class RepoPanel : Grid
{
    protected override AutomationPeer OnCreateAutomationPeer() => new RepoPanelAutomationPeer(this);

    private sealed partial class RepoPanelAutomationPeer(RepoPanel owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

        protected override string GetClassNameCore() => nameof(RepoPanel);

        protected override bool IsControlElementCore() => true;
    }
}

/// <summary>A gap between two panels that drags their edge: hit-testable across its whole area, with the column-resize
/// pointer. Hidden from UI Automation, as on the Mac.</summary>
public sealed partial class PanelDivider : Grid
{
    public PanelDivider()
    {
        Background = new SolidColorBrush(Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
    }
}

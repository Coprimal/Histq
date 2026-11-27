using Histq.App.Detail;
using Histq.App.Graph;
using Histq.App.Shell;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace Histq.App.Repo;

/// <summary>
/// A repo tab (ported from RepoLayoutView, App/Repo/RepoLayoutView.swift at 6fa6d40, its Classic layout): sidebar |
/// commit graph | detail. Made by <see cref="TabContentHost"/> in the same call as the tab's selection, so its cards and
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
public sealed partial class RepoLayoutView : UserControl
{
    private readonly MainWindow _window;
    private readonly RepoTabSession _session;
    private readonly GraphView _graph;
    private readonly GraphSearchBar _search;
    private readonly CommitSummaryView _summary = new();
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

    internal RepoLayoutView(MainWindow window, string path)
    {
        _window = window;
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

        _session = new RepoTabSession(
            path, _window.Manager.Preferences, _window.Manager.GraphLook.FadeOtherWorktrees,
            ((App)Application.Current).StatePaths.Root, DispatcherQueue.GetForCurrentThread());
        _session.Loaded += OnLoaded;
        _session.Failed += OnFailed;
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

    /// <summary>A first page, the complete log or a reload: the graph shows it (an empty log leaves the graph empty,
    /// as on the Mac).</summary>
    private void OnLoaded(GraphData data)
    {
        _graph.Show(data);
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

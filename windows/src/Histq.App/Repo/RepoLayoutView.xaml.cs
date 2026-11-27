using Histq.App.Shell;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Histq.App.Repo;

/// <summary>
/// A repo tab (ported from RepoLayoutView, App/Repo/RepoLayoutView.swift at 6fa6d40, its Classic layout): sidebar |
/// commit graph | detail. Made by <see cref="TabContentHost"/> in the same call as the tab's selection, so its cards and
/// the graph's placeholder show in that frame; its <see cref="RepoTabSession"/> reads the log off the UI thread and the
/// graph shows the rows as they come. It stays mounted while another tab shows, among the last tabs shown; when it is
/// unmounted (the tab closed or no longer kept, its window closed) <see cref="Close"/> stops the load.
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
    private readonly DispatcherQueueTimer _spinnerTimer;

    /// <summary>The widths the columns have now (fitted); the start of a drag.</summary>
    private PanelWidths _shown;

    /// <summary>The widths while a divider is dragged; null otherwise.</summary>
    private PanelWidths? _dragWidths;

    /// <summary>The dragged divider, where the drag began (layout X) and the widths shown then.</summary>
    private (PanelDivider Divider, double StartX, PanelWidths Start)? _drag;

    private bool _closed;

    internal RepoLayoutView(MainWindow window, string path)
    {
        _window = window;
        InitializeComponent();

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

        _session = new RepoTabSession(path, _window.Manager.Preferences, DispatcherQueue.GetForCurrentThread());
        _session.RowsChanged += OnRowsChanged;
        _session.Completed += OnCompleted;
        _session.Failed += OnFailed;
        _session.Start();
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
        CommitGraph.Release();
    }

    // Graph

    private void OnRowsChanged(IReadOnlyList<GraphRow> rows, IReadOnlyList<Commit> commits)
    {
        CommitGraph.SetRows(rows, commits);
        ShowGraph();
    }

    /// <summary>The whole log is in: an empty one leaves the graph empty, as on the Mac.</summary>
    private void OnCompleted() => ShowGraph();

    private void OnFailed(string message)
    {
        HidePlaceholder();
        CommitGraph.Visibility = Visibility.Collapsed;
        GraphFailureText.Text = message;
        GraphFailure.Visibility = Visibility.Visible;
    }

    private void ShowGraph()
    {
        if (GraphPlaceholder.Visibility == Visibility.Visible)
            HidePlaceholder();
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

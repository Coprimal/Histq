using System.Diagnostics;
using System.Numerics;
using Histq.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI;

namespace Histq.App.Graph;

/// <summary>One frame of <see cref="GraphCanvas"/>, for the spike harness.</summary>
/// <param name="DrawMs">The Draw handler's time on the CPU (Stopwatch), from its first line to its last.</param>
/// <param name="FirstRow">The top row drawn (maybe partly scrolled off); -1 when no row was drawn.</param>
/// <param name="LastRow">The bottom row drawn (maybe partly); -1 when no row was drawn.</param>
/// <param name="LastRowFullyDrawn"><paramref name="LastRow"/>'s bottom edge is inside the viewport.</param>
/// <param name="SelectedRow">The selected row this frame drew, -1 for none.</param>
public readonly record struct GraphDrawInfo(
    double DrawMs, long FirstRow, long LastRow, bool LastRowFullyDrawn, long SelectedRow);

/// <summary>
/// What a <see cref="GraphCanvas"/> draws: its rows, read at draw time on the UI thread. A source never changes once
/// set; new rows come as a new source (<see cref="GraphCanvas.SetSource"/>).
/// </summary>
internal abstract class GraphRowSource
{
    public abstract long Count { get; }

    /// <summary>The laid-out row <paramref name="row"/> (0 to <see cref="Count"/> - 1).</summary>
    public abstract GraphRow RowAt(long row);

    /// <summary>The row's name in UI Automation (its message, safe to show).</summary>
    public abstract string NameOf(long row);

    /// <summary>The row's text columns and badges, when the canvas draws columns.</summary>
    public virtual GraphRowText TextOf(long row) => new(NameOf(row));

    /// <summary>The row's commit (its node's avatar); null for a synthetic row, or a source without commits.</summary>
    public virtual Commit? CommitOf(long row) => null;

    /// <summary>Another worktree's row: its band, node and text are faded.</summary>
    public virtual bool IsFaded(long row) => false;

    /// <summary>A row the graph search does not match while it has matches: its text is dimmed.</summary>
    public virtual bool IsDimmed(long row) => false;

    /// <summary>The lines leaving the commit of index <paramref name="owner"/> (<see cref="GraphSegment.Owner"/>) are
    /// another worktree's: drawn faded.</summary>
    public virtual bool IsSegmentFaded(int owner) => false;
}

/// <summary>A row's text columns. <paramref name="Changes"/> follow a WIP row's message as glyphs and counts;
/// <paramref name="Badges"/> are the Branch / Tag column's (none when null).</summary>
internal readonly record struct GraphRowText(
    string Message, bool IsSecondary = false, bool IsItalic = false, WorktreeChanges? Changes = null,
    string Author = "", string Date = "", IReadOnlyList<RefBadge>? Badges = null);

/// <summary>Rows given as lists (<see cref="GraphCanvas.SetRows"/>): <c>commits[i]</c> is row i's commit, named after
/// its subject; a synthetic row or a row past the commits has no name.</summary>
internal sealed class GraphListSource(IReadOnlyList<GraphRow> rows, IReadOnlyList<Commit> commits) : GraphRowSource
{
    public IReadOnlyList<GraphRow> Rows => rows;

    public override long Count => rows.Count;

    public override GraphRow RowAt(long row) => rows[(int)row];

    public override string NameOf(long row) =>
        row < commits.Count && !rows[(int)row].Node.IsSynthetic ? commits[(int)row].Subject : "";
}

/// <summary>
/// The commit graph, virtualized: a viewport-sized Win2D canvas (never one as tall as the data) that draws only the
/// visible rows, and its own vertical scroll bar over their right edge (<see cref="GraphScrollBar"/>). The scroll
/// offset is a row index and a pixel offset inside that row, so a million rows times the row height never goes through
/// a float; every drawing coordinate is relative to the viewport.
/// <para>
/// Without <see cref="Columns"/> (the spike harness) it draws the graph in a column fitted to the visible rows' lanes
/// and the subject after it; with them (<see cref="GraphView"/>) each column where the layout puts it: the graph, the
/// message, the author and the date, the selected row's fill from its node to the right edge under them.
/// </para>
/// <para>
/// Wheel and Page Up, Page Down, Home, End scroll; Up and Down move the selection by one row and scroll it into view; a
/// press selects the row under the pointer and the highlight is drawn in the same frame. Each visible row's texts are
/// drawn with shared text formats, so no per-row text object is made while scrolling.
/// </para>
/// <para>
/// The scroll bar is drawn in the same Draw pass, so a scroll step changes no XAML element (updating a XAML ScrollBar
/// on every step made the framework induce blocking gen-2 GCs). Its thumb shows while scrolling and while the pointer
/// is over the right <see cref="GraphScrollBar.ZoneWidth"/> epx, and fades out about a second after the last scroll; a
/// press on the thumb drags it, a press above or below it pages by one viewport, and no press there selects a row.
/// </para>
/// </summary>
public sealed partial class GraphCanvas : UserControl
{
    /// <summary>Rows per wheel notch (120 units).</summary>
    private const double WheelRows = 3;

    /// <summary>Between the graph column and the subject, and after the subject.</summary>
    private const float TextGap = 8;

    /// <summary>The scroll bar's thumb stays fully shown this long after the last scroll, then fades out.</summary>
    private static readonly TimeSpan ThumbHold = TimeSpan.FromSeconds(1);

    private static readonly TimeSpan ThumbFade = TimeSpan.FromMilliseconds(250);

    /// <summary>The fade's redraw interval (only while it fades).</summary>
    private static readonly TimeSpan ThumbFadeFrame = TimeSpan.FromMilliseconds(16);

    private readonly GraphRowRenderer _renderer = new(GraphMetrics.Regular);
    private readonly RefBadgeRenderer _badges = new();

    private static readonly GraphListSource Empty = new([], []);
    private readonly CanvasControl _canvas;

    /// <summary>Redraws the thumb's fade; one-shot, armed again from its own tick, never per scroll step.</summary>
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _fadeTimer;

    private GraphRowSource _source = Empty;
    private long _count;
    private GraphColumnLayout? _columns;
    private int _logLanes;

    // The scroll offset: the top row and how far it is scrolled off (0 <= _pixelInRow < RowHeight).
    private long _firstRow;
    private double _pixelInRow;

    /// <summary>The most lanes a drawn row has used since the rows were set: the column only widens while scrolling.</summary>
    private int _columnLanes = 1;

    /// <summary>The last scroll, or the end of the last hover or drag (a Stopwatch timestamp); 0 = never.</summary>
    private long _thumbActivity;

    /// <summary>The fade timer is armed (kept here so a scroll step reads no WinRT property).</summary>
    private bool _fadeTimerArmed;

    /// <summary>The pointer is over the scroll bar's zone.</summary>
    private bool _thumbHover;

    /// <summary>The thumb is dragged: the pointer is captured.</summary>
    private bool _thumbDrag;

    /// <summary>While dragging: the pointer's Y less the thumb's top at the press.</summary>
    private double _thumbGrab;

    public GraphCanvas()
    {
        IsTabStop = true;

        _canvas = new CanvasControl();
        _canvas.Draw += OnDraw;
        _canvas.CreateResources += OnCreateResources;
        _canvas.SizeChanged += (_, _) => OnViewportChanged();

        _fadeTimer = DispatcherQueue.CreateTimer();
        _fadeTimer.IsRepeating = false;
        _fadeTimer.Tick += OnFadeTick;

        // A background, even transparent, makes the whole area hit-testable.
        var root = new Grid { Background = new SolidColorBrush(Colors.Transparent) };
        root.Children.Add(_canvas);
        Content = root;

        Unloaded += (_, _) =>
        {
            // Hidden until the next scroll or hover: no timer runs while unloaded.
            _fadeTimer.Stop();
            _fadeTimerArmed = false;
            _thumbActivity = 0;
            _thumbHover = false;
            ReleaseDeviceResources();
        };
    }

    /// <summary>Raised at the end of every Draw, with its time and what it drew.</summary>
    public event EventHandler<GraphDrawInfo>? DrawCompleted;

    /// <summary>The user selected a row (a press, Up or Down, UI Automation), already drawn selected; -1 for none.</summary>
    internal event Action<long>? RowSelected;

    public double RowHeight => _renderer.Metrics.RowHeight;

    /// <summary>The row height, band and lane sizes and lane colors; a change keeps the top row and redraws.</summary>
    internal GraphMetrics Metrics
    {
        get => _renderer.Metrics;
        set
        {
            if (value == _renderer.Metrics)
                return;
            double fraction = _pixelInRow / RowHeight;
            _renderer.SetMetrics(value);
            _pixelInRow = 0;
            SetOffset(_firstRow, fraction * RowHeight);
            _canvas.Invalidate();
        }
    }

    /// <summary>Where the columns are (<see cref="GraphView"/>); null draws the graph and the subject only.</summary>
    internal GraphColumnLayout? Columns
    {
        get => _columns;
        set
        {
            if (Equals(value, _columns))
                return;
            _columns = value;
            _canvas.Invalidate();
        }
    }

    /// <summary>The commit nodes' avatars (<see cref="GraphView"/>); none while null.</summary>
    internal AvatarRenderer? Avatars { get; set; }

    /// <summary>The most lanes a row of the log draws in: a graph column too narrow for them folds them.</summary>
    internal int LogLanes
    {
        get => _logLanes;
        set
        {
            if (value == _logLanes)
                return;
            _logLanes = value;
            _canvas.Invalidate();
        }
    }

    public long RowCount => _count;

    /// <summary>Draws the rows' subjects (default); the spike harness turns it off to measure without text.</summary>
    internal bool DrawSubjects { get; set; } = true;

#if HISTQ_QA
    /// <summary>
    /// QA bisect switch: while true, <see cref="GraphAutomationPeer"/> creates no row peers and reports no children
    /// (the spike harness's scroll probe only).
    /// </summary>
    internal bool QaNoAutomation { get; set; }

    /// <summary>QA counter: UI Automation children requests answered by <see cref="GraphAutomationPeer"/>.</summary>
    internal int QaAutomationEventsCount { get; set; }

    /// <summary>QA counter: row peers <see cref="GraphAutomationPeer"/> created.</summary>
    internal int QaAutomationRowPeersCreated { get; set; }
#endif

    /// <summary>The selected row, -1 for none.</summary>
    public long SelectedRow { get; private set; } = -1;

    /// <summary>The top row of the viewport (maybe partly scrolled off).</summary>
    public long FirstRow => _firstRow;

    /// <summary>How far <see cref="FirstRow"/> is scrolled off the top, 0 up to <see cref="RowHeight"/>.</summary>
    public double PixelInRow => _pixelInRow;

    /// <summary>The height the rows are drawn in, in epx.</summary>
    public double ViewportHeight => Math.Max(0, _canvas.ActualHeight);

    /// <summary>The width the rows are drawn in (the scroll bar is drawn over their right edge), in epx.</summary>
    public double ViewportWidth => Math.Max(0, _canvas.ActualWidth);

    /// <summary>The top row on screen, -1 when there is none.</summary>
    public long FirstVisibleRow => _count == 0 ? -1 : _firstRow;

    /// <summary>The bottom row on screen (maybe partly), -1 when there is none.</summary>
    public long LastVisibleRow => LastVisibleRowIn(ViewportHeight);

    /// <summary>Not every row fits in the viewport: there is something to scroll.</summary>
    internal bool CanScroll
    {
        get
        {
            (long maxFirst, double maxPixel) = MaxOffset();
            return maxFirst > 0 || maxPixel > 0;
        }
    }

    /// <summary>
    /// The offset as a fraction of the scroll range: 0 at the top, exactly 1 when the last row's bottom edge is on the
    /// viewport's bottom edge, 0 when nothing scrolls. The offset in rows is a double, exact to far below a pixel for any
    /// row count a log has.
    /// </summary>
    internal double ScrollFraction
    {
        get
        {
            (long maxFirst, double maxPixel) = MaxOffset();
            if (maxFirst == 0 && maxPixel == 0)
                return 0;
            if (_firstRow > maxFirst || (_firstRow == maxFirst && _pixelInRow >= maxPixel))
                return 1;
            double rh = RowHeight;
            return Math.Clamp((_firstRow + _pixelInRow / rh) / (maxFirst + maxPixel / rh), 0, 1);
        }
    }

    /// <summary>The part of the rows the viewport shows, 0 to 1 (1 when every row fits).</summary>
    internal double ViewFraction =>
        _count == 0 ? 1 : Math.Clamp(ViewportHeight / (_count * RowHeight), 0, 1);

    /// <summary>
    /// Shows <paramref name="rows"/>, with <paramref name="commits"/>[i] the commit of row i (a shorter list leaves the
    /// rest without subject). O(1): the lists are read at draw time, so append-only lists can grow and be set again to
    /// show the new count; the offset and selection stay where they are, clamped. Call on the UI thread, and never
    /// change a list the canvas holds from another thread.
    /// </summary>
    public void SetRows(IReadOnlyList<GraphRow> rows, IReadOnlyList<Commit> commits)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(commits);
        if (_source is not GraphListSource list || !ReferenceEquals(rows, list.Rows))
            _columnLanes = 1;
        SetSource(new GraphListSource(rows, commits));
    }

    /// <summary>
    /// Shows <paramref name="source"/>'s rows. O(1): the source is read at draw time. The offset and selection stay
    /// where they are, clamped (the caller moves them to follow the rows). UI thread.
    /// </summary>
    internal void SetSource(GraphRowSource source)
    {
        _source = source;
        _count = source.Count;
        if (SelectedRow >= _count)
            SelectedRow = -1;
        SetOffset(_firstRow, _pixelInRow);
        _canvas.Invalidate();
    }

    /// <summary>
    /// The graph is gone for good (its repo layout was unmounted): drops its rows and takes its Win2D canvas out of the
    /// tree, as Win2D asks of a control that is not reused (its event handlers would otherwise keep it alive). Call on
    /// the UI thread, outside a layout pass; the graph draws nothing after it.
    /// </summary>
    internal void Release()
    {
        _fadeTimer.Stop();
        _fadeTimerArmed = false;
        _source = Empty;
        _count = 0;
        _badges.Dispose();
        SelectedRow = -1;
        _canvas.RemoveFromVisualTree();
    }

    /// <summary>Scrolls <paramref name="row"/> to the top of the viewport, or as near as the end allows.</summary>
    public void ScrollToRow(long row) => SetOffset(Math.Clamp(row, 0, Math.Max(0, _count - 1)), 0);

    /// <summary>Scrolls to the end: the last row's bottom edge on the viewport's bottom edge.</summary>
    public void ScrollToEnd()
    {
        (long first, double pixel) = MaxOffset();
        SetOffset(first, pixel);
    }

    /// <summary>Scrolls to <paramref name="first"/> at the top, <paramref name="pixel"/> epx of it scrolled off,
    /// clamped to the rows.</summary>
    internal void ScrollTo(long first, double pixel) => SetOffset(first, pixel);

    /// <summary>Scrolls just enough for <paramref name="row"/> to be wholly on screen.</summary>
    internal void ScrollIntoView(long row)
    {
        if (row < 0 || row >= _count)
            return;
        double top = TopOfRow(row);
        if (top < 0)
            SetOffset(row, 0);
        else if (top + RowHeight > ViewportHeight)
            ScrollByPixels(top + RowHeight - ViewportHeight);
    }

    /// <summary>Scrolls by <paramref name="dy"/> epx, down when positive, clamped to the rows.</summary>
    public void ScrollByPixels(double dy)
    {
        if (double.IsFinite(dy))
            SetOffset(_firstRow, _pixelInRow + dy);
    }

    /// <summary>
    /// Scrolls to <paramref name="fraction"/> of the scroll range: 0 or less is the top, 1 or more exactly the end (the
    /// last row's bottom edge on the viewport's bottom edge), in between proportionally.
    /// </summary>
    internal void ScrollToFraction(double fraction)
    {
        if (double.IsNaN(fraction))
            return;
        if (fraction <= 0)
        {
            SetOffset(0, 0);
            return;
        }

        (long maxFirst, double maxPixel) = MaxOffset();
        if (fraction >= 1)
        {
            SetOffset(maxFirst, maxPixel);
            return;
        }

        double rh = RowHeight;
        double rows = fraction * (maxFirst + maxPixel / rh);
        double first = Math.Floor(rows);
        SetOffset((long)first, (rows - first) * rh);
    }

    /// <summary>Scrolls one viewport up (<paramref name="direction"/> -1) or down (+1).</summary>
    internal void ScrollByPage(int direction) => ScrollByPixels(Math.Sign(direction) * ViewportHeight);

    /// <summary>The row under <paramref name="y"/> (epx from the viewport's top), -1 when there is none.</summary>
    public long HitTest(double y)
    {
        if (!(y >= 0 && y < ViewportHeight) || _count == 0)
            return -1;
        long row = _firstRow + (long)Math.Floor((y + _pixelInRow) / RowHeight);
        return row < _count ? row : -1;
    }

    /// <summary>
    /// The top edge of <paramref name="row"/> in epx from the viewport's top (negative above it). The row difference is
    /// taken in integers first, so it is exact for any row of a large log.
    /// </summary>
    public double TopOfRow(long row) => (row - _firstRow) * RowHeight - _pixelInRow;

    /// <summary>Selects <paramref name="row"/> (-1 for none) and redraws in the same frame.</summary>
    public void Select(long row)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(row, -1);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(row, Math.Max(_count, 0));
        if (row == SelectedRow)
            return;
        SelectedRow = row;
        _canvas.Invalidate();
    }

    /// <summary>A left press on the rows (not the scroll bar) at <paramref name="row"/> (-1: none under the pointer):
    /// the graph takes the focus and the row is selected, drawn in the same frame.</summary>
    internal void PressRow(long row)
    {
        Focus(FocusState.Pointer);
        if (row >= 0)
            SelectByUser(row);
    }

    /// <summary>Draws again (what the source tells changed, e.g. the search's dimming).</summary>
    internal void Redraw() => _canvas.Invalidate();

    /// <summary>
    /// Scrolls <paramref name="row"/> to the middle of the rows' area when it is not wholly in it; the bottom
    /// <paramref name="bottomInset"/> epx (the open search bar) count as hidden.
    /// </summary>
    internal void CenterIfHidden(long row, double bottomInset)
    {
        if (row < 0 || row >= _count)
            return;
        double top = TopOfRow(row);
        double visible = Math.Max(RowHeight, ViewportHeight - bottomInset);
        if (top >= 0 && top + RowHeight <= visible)
            return;
        ScrollByPixels(top + RowHeight / 2 - visible / 2);
    }

    /// <summary>Selects <paramref name="row"/> as the user did (<see cref="RowSelected"/>).</summary>
    internal void SelectByUser(long row)
    {
        // The selected row again (a click on it): nothing changes, as on the Mac.
        if (row < -1 || row >= _count || row == SelectedRow)
            return;
        Select(row);
        RowSelected?.Invoke(row);
    }

    /// <summary>The name of <paramref name="row"/> (its message); empty outside the rows.</summary>
    public string SubjectOf(long row) => row < 0 || row >= _count ? "" : _source.NameOf(row);

    /// <summary>The lane of <paramref name="row"/>'s node; -1 outside the rows.</summary>
    internal int LaneOf(long row) => row < 0 || row >= _count ? -1 : _source.RowAt(row).Lane;

    protected override AutomationPeer OnCreateAutomationPeer() => new GraphAutomationPeer(this);

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(_canvas);
        var position = point.Position;
        if (position.X < 0 || position.X >= _canvas.ActualWidth)
        {
            base.OnPointerPressed(e);
            return;
        }

        if (InScrollBarZone(position.X, position.Y))
        {
            if (point.Properties.IsLeftButtonPressed)
                PressScrollBar(position.Y, e.Pointer);
            e.Handled = true;
            return;
        }

        PressRow(HitTest(position.Y));
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerRoutedEventArgs e)
    {
        var position = e.GetCurrentPoint(_canvas).Position;
        if (_thumbDrag)
        {
            (_, double length, double track) = Thumb();
            ScrollToFraction(GraphScrollBar.FractionAt(position.Y - _thumbGrab, track, length));
            e.Handled = true;
            return;
        }

        SetThumbHover(InScrollBarZone(position.X, position.Y));
        base.OnPointerMoved(e);
    }

    protected override void OnPointerReleased(PointerRoutedEventArgs e)
    {
        if (!_thumbDrag)
        {
            base.OnPointerReleased(e);
            return;
        }

        EndThumbDrag();
        ReleasePointerCapture(e.Pointer);
        var position = e.GetCurrentPoint(_canvas).Position;
        SetThumbHover(InScrollBarZone(position.X, position.Y));
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e)
    {
        if (_thumbDrag)
            EndThumbDrag();
        base.OnPointerCaptureLost(e);
    }

    protected override void OnPointerExited(PointerRoutedEventArgs e)
    {
        if (!_thumbDrag)
            SetThumbHover(false);
        base.OnPointerExited(e);
    }

    protected override void OnPointerWheelChanged(PointerRoutedEventArgs e)
    {
        var properties = e.GetCurrentPoint(this).Properties;
        if (properties.IsHorizontalMouseWheel)
        {
            base.OnPointerWheelChanged(e);
            return;
        }

        ScrollByPixels(-properties.MouseWheelDelta / 120.0 * WheelRows * RowHeight);
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        double page = Math.Max(RowHeight, ViewportHeight - RowHeight);
        switch (e.Key)
        {
            case VirtualKey.Up:
                MoveSelection(-1);
                break;
            case VirtualKey.Down:
                MoveSelection(1);
                break;
            case VirtualKey.PageUp:
                ScrollByPixels(-page);
                break;
            case VirtualKey.PageDown:
                ScrollByPixels(page);
                break;
            case VirtualKey.Home:
                ScrollToRow(0);
                break;
            case VirtualKey.End:
                ScrollToEnd();
                break;
            default:
                base.OnKeyDown(e);
                return;
        }

        e.Handled = true;
    }

    /// <summary>
    /// Up or Down: selects the row above or below the selected one (with none, the top row on screen) and scrolls it
    /// into view.
    /// </summary>
    private void MoveSelection(int direction)
    {
        if (_count == 0)
            return;
        long row = SelectedRow < 0
            ? Math.Max(0, TopOfRow(_firstRow) < 0 && _firstRow + 1 < _count ? _firstRow + 1 : _firstRow)
            : Math.Clamp(SelectedRow + direction, 0, _count - 1);
        if (row != SelectedRow)
            SelectByUser(row);
        ScrollIntoView(row);
    }

    /// <summary>The bottom row on screen in a viewport <paramref name="height"/> tall, -1 when there is none.</summary>
    private long LastVisibleRowIn(double height)
    {
        if (_count == 0 || height <= 0)
            return -1;
        long rows = (long)Math.Ceiling((height + _pixelInRow) / RowHeight);
        return Math.Min(_count - 1, _firstRow + Math.Max(1, rows) - 1);
    }

    /// <summary>
    /// The largest offset: the last row's bottom edge on the viewport's bottom edge, or the top when every row fits.
    /// Computed from the viewport in rows, so no large product is involved.
    /// </summary>
    private (long First, double Pixel) MaxOffset()
    {
        double rh = RowHeight;
        double height = ViewportHeight;
        if (height <= 0)
            return (Math.Max(0, _count - 1), 0);

        long fullRows = (long)Math.Floor(height / rh);
        double rest = height - fullRows * rh;
        long first = rest > 0 ? _count - fullRows - 1 : _count - fullRows;
        if (first < 0)
            return (0, 0);
        return (first, rest > 0 ? rh - rest : 0);
    }

    /// <summary>Moves to (<paramref name="first"/>, <paramref name="pixel"/>), normalized and clamped, and redraws.</summary>
    private void SetOffset(long first, double pixel)
    {
        double rh = RowHeight;
        if (!double.IsFinite(pixel))
            return;

        if (pixel < 0 || pixel >= rh)
        {
            // Never more rows than the log has: anything past it clamps below.
            double rows = Math.Clamp(Math.Floor(pixel / rh), -(double)(_count + 1), _count + 1);
            first += (long)rows;
            pixel = Math.Clamp(pixel - rows * rh, 0, rh);
            if (pixel >= rh)
            {
                first++;
                pixel = 0;
            }
        }

        (long maxFirst, double maxPixel) = MaxOffset();
        if (first < 0)
            (first, pixel) = (0, 0);
        else if (first > maxFirst || (first == maxFirst && pixel > maxPixel))
            (first, pixel) = (maxFirst, maxPixel);

        if (first == _firstRow && pixel == _pixelInRow)
            return;
        _firstRow = first;
        _pixelInRow = pixel;
        ShowThumb();
        _canvas.Invalidate();
    }

    private void OnViewportChanged() => SetOffset(_firstRow, _pixelInRow);

    /// <summary>The point (canvas epx) is over the scroll bar's zone, the canvas's right strip.</summary>
    private bool InScrollBarZone(double x, double y) =>
        y >= 0 && y < ViewportHeight && x < ViewportWidth && x >= ViewportWidth - GraphScrollBar.ZoneWidth;

    /// <summary>The thumb's top and length, and the track's length, for the current offset and viewport.</summary>
    private (double Top, double Length, double Track) Thumb()
    {
        double track = GraphScrollBar.TrackLength(ViewportHeight);
        double length = GraphScrollBar.ThumbLength(track, ViewFraction);
        return (GraphScrollBar.ThumbTop(track, length, ScrollFraction), length, track);
    }

    /// <summary>A press at <paramref name="y"/> in the scroll bar's zone: drags the thumb, or pages above or below it.</summary>
    private void PressScrollBar(double y, Pointer pointer)
    {
        if (!CanScroll)
            return;
        (double top, double length, double track) = Thumb();
        if (track <= 0)
            return;
        if (y < top)
        {
            ScrollByPage(-1);
        }
        else if (y >= top + length)
        {
            ScrollByPage(1);
        }
        else if (CapturePointer(pointer))
        {
            _thumbDrag = true;
            _thumbGrab = y - top;
            _canvas.Invalidate();
        }
    }

    private void EndThumbDrag()
    {
        _thumbDrag = false;
        _thumbHover = false;
        ShowThumb();
        _canvas.Invalidate();
    }

    /// <summary>Records the hover over the zone; its end starts the fade. Redraws only when it changes.</summary>
    private void SetThumbHover(bool hover)
    {
        if (hover == _thumbHover)
            return;
        _thumbHover = hover;
        if (!hover)
            ShowThumb();
        _canvas.Invalidate();
    }

    /// <summary>
    /// Shows the thumb fully for <see cref="ThumbHold"/> from now, then lets it fade. Called on every scroll step, so it
    /// only stamps the time and arms the timer when it is not armed already (one Start per burst of scrolling).
    /// </summary>
    private void ShowThumb()
    {
        _thumbActivity = Stopwatch.GetTimestamp();
        if (!_fadeTimerArmed)
            ArmFadeTimer(ThumbHold);
    }

    private void ArmFadeTimer(TimeSpan interval)
    {
        _fadeTimerArmed = true;
        _fadeTimer.Interval = interval;
        _fadeTimer.Start();
    }

    /// <summary>Waits out the hold, then redraws every <see cref="ThumbFadeFrame"/> until the thumb is gone.</summary>
    private void OnFadeTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        _fadeTimerArmed = false;
        if (_thumbHover || _thumbDrag)
            return;

        TimeSpan since = Stopwatch.GetElapsedTime(_thumbActivity);
        if (since < ThumbHold)
        {
            ArmFadeTimer(ThumbHold - since);
            return;
        }

        _canvas.Invalidate();
        if (since < ThumbHold + ThumbFade)
            ArmFadeTimer(ThumbFadeFrame);
    }

    /// <summary>The thumb's opacity now, 0 to 1: full while hovered, dragged or held, then fading out.</summary>
    private double ThumbOpacity()
    {
        if (_thumbHover || _thumbDrag)
            return 1;
        if (_thumbActivity == 0)
            return 0;
        TimeSpan since = Stopwatch.GetElapsedTime(_thumbActivity);
        if (since < ThumbHold)
            return 1;
        return Math.Max(0, 1 - (since - ThumbHold) / ThumbFade);
    }

    private void DrawScrollBar(CanvasDrawingSession ds, double width)
    {
        double opacity = ThumbOpacity();
        if (opacity <= 0 || !CanScroll)
            return;
        (double top, double length, double track) = Thumb();
        if (track <= 0)
            return;
        GraphScrollBar.Draw(ds, width, top, length, _thumbHover || _thumbDrag, opacity);
    }

    private void OnCreateResources(CanvasControl sender, CanvasCreateResourcesEventArgs args) =>
        ReleaseDeviceResources();

    private void ReleaseDeviceResources()
    {
        _renderer.ResetDeviceResources();
        Avatars?.Reset();
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        long started = Stopwatch.GetTimestamp();
        CanvasDrawingSession ds = args.DrawingSession;
        double rh = RowHeight;
        double height = sender.ActualHeight;
        float width = (float)sender.ActualWidth;
        long first = _count == 0 ? -1 : _firstRow;
        long last = LastVisibleRowIn(height);
        bool lastFull = false;

        if (last >= 0)
        {
            if (_columns is { } columns)
                DrawColumns(ds, columns, first, last, width);
            else
                DrawGraphAndSubjects(ds, first, last, width);
            lastFull = (last - first + 1) * rh - _pixelInRow <= height + 0.001;
        }

        DrawScrollBar(ds, width);

        DrawCompleted?.Invoke(
            this,
            new GraphDrawInfo(Stopwatch.GetElapsedTime(started).TotalMilliseconds, first, last, lastFull, SelectedRow));
    }

    /// <summary>Without columns: the graph in a column fitted to the lanes seen so far, the subject after it.</summary>
    private void DrawGraphAndSubjects(CanvasDrawingSession ds, long first, long last, float width)
    {
        double rh = RowHeight;
        for (long r = first; r <= last; r++)
            _columnLanes = Math.Max(_columnLanes, _source.RowAt(r).Width);

        GraphMetrics m = _renderer.Metrics;
        float column = (float)Math.Min(m.Width(_columnLanes), Math.Max(m.MinColumnWidth, width * 0.5));
        float textX = column + TextGap;
        float textWidth = width - textX - TextGap;
        bool drawText = DrawSubjects && textWidth > 0;

        for (long r = first; r <= last; r++)
        {
            // Viewport coordinates: the integer row difference first, so the float stays small.
            float top = (float)((r - first) * rh - _pixelInRow);
            bool selected = r == SelectedRow;
            GraphRow row = _source.RowAt(r);
            _renderer.DrawRow(ds, row, top, column, selected, _columnLanes);
            if (drawText && _source.NameOf(r) is { Length: > 0 } subject)
                _renderer.DrawSubject(ds, subject, textX, top, textWidth, selected);
        }
    }

    /// <summary>
    /// With columns: each row's selection fill (from its node to the right edge), its graph part in the graph column,
    /// then its message, author and date in theirs. A faded row (another worktree's) draws its node, band and texts
    /// faded. The badges go in the refs column, their line on to the node; a commit's node shows its author's avatar.
    /// </summary>
    private void DrawColumns(CanvasDrawingSession ds, GraphColumnLayout columns, long first, long last, float width)
    {
        double rh = RowHeight;
        GraphMetrics m = _renderer.Metrics;
        GraphColumnSpan graph = columns[GraphColumn.Graph];
        float graphX = (float)graph.X;
        float graphWidth = (float)graph.Width;
        int lanes = Math.Max(1, _logLanes);
        Matrix3x2 identity = ds.Transform;

        for (long r = first; r <= last; r++)
        {
            float top = (float)((r - first) * rh - _pixelInRow);
            bool selected = r == SelectedRow;
            GraphRow row = _source.RowAt(r);
            bool faded = _source.IsFaded(r);
            GraphRowText text = _source.TextOf(r);
            IReadOnlyList<RefBadge> badges = text.Badges ?? [];
            GraphColumnSpan refs = columns[GraphColumn.Refs];

            if (selected)
            {
                float start = Math.Clamp(graphX + (float)m.DrawnX(row.Lane, graphWidth), 0, width);
                ds.FillRectangle(
                    start, top + (float)m.BandInset, width - start, (float)m.BandHeight, GraphPalette.Selection);
            }

            float nodeAlpha = faded ? GraphPalette.OtherWorktreeAlpha : 1;
            bool hasRefs = badges.Count > 0 && refs.IsShown;
            if (hasRefs)
                _badges.Draw(ds, badges, (float)refs.X, top, (float)refs.Width, row.Color, m, nodeAlpha);

            if (graph.IsShown)
            {
                ICanvasImage? avatar = Avatars is { } avatars && _source.CommitOf(r) is { IsMerge: false } commit
                    ? avatars.Avatar(ds, commit.AuthorEmail, commit.AuthorName, _renderer.AvatarDiameter)
                    : null;
                ds.Transform = Matrix3x2.CreateTranslation(graphX, 0) * identity;
                _renderer.DrawRow(
                    ds, row, top, graphWidth, selected, lanes, _source, nodeAlpha,
                    new GraphNodeDecor(avatar, hasRefs, hasRefs && RefBadgeRenderer.HasHead(badges)));
                ds.Transform = identity;
            }

            if (!DrawSubjects)
                continue;
            float alpha = faded || _source.IsDimmed(r) ? GraphPalette.DimmedTextAlpha : 1;
            Color primary = GraphPalette.Faded(
                selected ? GraphPalette.SelectedSubjectText : GraphPalette.SubjectText, alpha);
            Color secondary = GraphPalette.Faded(
                selected ? GraphPalette.SelectedSubjectText : GraphPalette.SecondaryText, alpha);

            if (TextRect(columns[GraphColumn.Message], out float x, out float w) && text.Message.Length > 0)
            {
                Color color = text.IsSecondary ? secondary : primary;
                if (text.Changes is { IsEmpty: false } changes)
                    _renderer.DrawChanges(ds, text.Message, changes, x, top, w, color, text.IsItalic);
                else
                    _renderer.DrawText(ds, text.Message, x, top, w, color, text.IsItalic);
            }

            if (TextRect(columns[GraphColumn.Author], out x, out w) && text.Author.Length > 0)
                _renderer.DrawText(ds, text.Author, x, top, w, secondary, false);
            if (TextRect(columns[GraphColumn.Date], out x, out w) && text.Date.Length > 0)
                _renderer.DrawText(ds, text.Date, x, top, w, secondary, false);
        }
    }

    /// <summary>A text column's text area: its span less the padding on both sides; false when hidden or too narrow.</summary>
    private static bool TextRect(GraphColumnSpan span, out float x, out float width)
    {
        x = (float)(span.X + GraphRowRenderer.TextPadding);
        width = (float)(span.Width - 2 * GraphRowRenderer.TextPadding);
        return span.IsShown && width >= 1;
    }
}

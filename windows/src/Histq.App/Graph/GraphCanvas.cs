using System.Diagnostics;
using Histq.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

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
/// The commit graph, virtualized: a viewport-sized Win2D canvas (never one as tall as the data) that draws only the
/// visible rows, and its own vertical scroll bar. The scroll offset is a row index and a pixel offset inside that row,
/// so a million rows times the row height never goes through a float; every drawing coordinate is relative to the
/// viewport.
/// <para>
/// Wheel and keys (Up, Down, Page Up, Page Down, Home, End) scroll; a press selects the row under the pointer and the
/// highlight is drawn in the same frame. Each visible row's subject is drawn with one shared text format, so no
/// per-row text object is made while scrolling.
/// </para>
/// </summary>
public sealed partial class GraphCanvas : UserControl
{
    /// <summary>Rows per wheel notch (120 units).</summary>
    private const double WheelRows = 3;

    /// <summary>Between the graph column and the subject, and after the subject.</summary>
    private const float TextGap = 8;

    private readonly GraphRowRenderer _renderer = new(GraphMetrics.Regular);
    private readonly CanvasControl _canvas;
    private readonly ScrollBar _scrollBar;

    private IReadOnlyList<GraphRow> _rows = [];
    private IReadOnlyList<Commit> _commits = [];
    private long _count;

    // The scroll offset: the top row and how far it is scrolled off (0 <= _pixelInRow < RowHeight).
    private long _firstRow;
    private double _pixelInRow;

    /// <summary>The most lanes a drawn row has used since the rows were set: the column only widens while scrolling.</summary>
    private int _columnLanes = 1;

    /// <summary>Set while the code moves the scroll bar, so its ValueChanged does not scroll back.</summary>
    private bool _settingScrollBar;

    public GraphCanvas()
    {
        IsTabStop = true;

        _canvas = new CanvasControl();
        _canvas.Draw += OnDraw;
        _canvas.CreateResources += OnCreateResources;
        _canvas.SizeChanged += (_, _) => OnViewportChanged();

        // A standalone ScrollBar shows nothing until it has an indicator mode.
        _scrollBar = new ScrollBar
        {
            Orientation = Orientation.Vertical,
            IndicatorMode = ScrollingIndicatorMode.MouseIndicator,
            Minimum = 0,
            Maximum = 0,
            SmallChange = 1,
            IsEnabled = false,
        };
        _scrollBar.ValueChanged += OnScrollBarValueChanged;
        Grid.SetColumn(_scrollBar, 1);

        // A background, even transparent, makes the whole area hit-testable.
        var root = new Grid { Background = new SolidColorBrush(Colors.Transparent) };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.Children.Add(_canvas);
        root.Children.Add(_scrollBar);
        Content = root;

        Unloaded += (_, _) => ReleaseDeviceResources();
    }

    /// <summary>Raised at the end of every Draw, with its time and what it drew.</summary>
    public event EventHandler<GraphDrawInfo>? DrawCompleted;

    public double RowHeight => _renderer.Metrics.RowHeight;

    public long RowCount => _count;

    /// <summary>Draws the rows' subjects (default); the spike harness turns it off to measure without text.</summary>
    internal bool DrawSubjects { get; set; } = true;

    /// <summary>The selected row, -1 for none.</summary>
    public long SelectedRow { get; private set; } = -1;

    /// <summary>The top row of the viewport (maybe partly scrolled off).</summary>
    public long FirstRow => _firstRow;

    /// <summary>How far <see cref="FirstRow"/> is scrolled off the top, 0 up to <see cref="RowHeight"/>.</summary>
    public double PixelInRow => _pixelInRow;

    /// <summary>The height the rows are drawn in, in epx.</summary>
    public double ViewportHeight => Math.Max(0, _canvas.ActualHeight);

    /// <summary>The width the rows are drawn in (the scroll bar is right of it), in epx.</summary>
    public double ViewportWidth => Math.Max(0, _canvas.ActualWidth);

    /// <summary>The top row on screen, -1 when there is none.</summary>
    public long FirstVisibleRow => _count == 0 ? -1 : _firstRow;

    /// <summary>The bottom row on screen (maybe partly), -1 when there is none.</summary>
    public long LastVisibleRow => LastVisibleRowIn(ViewportHeight);

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
        if (!ReferenceEquals(rows, _rows))
            _columnLanes = 1;

        _rows = rows;
        _commits = commits;
        _count = rows.Count;
        if (SelectedRow >= _count)
            SelectedRow = -1;
        SetOffset(_firstRow, _pixelInRow);
        UpdateScrollBar();
        _canvas.Invalidate();
    }

    /// <summary>Scrolls <paramref name="row"/> to the top of the viewport, or as near as the end allows.</summary>
    public void ScrollToRow(long row) => SetOffset(Math.Clamp(row, 0, Math.Max(0, _count - 1)), 0);

    /// <summary>Scrolls to the end: the last row's bottom edge on the viewport's bottom edge.</summary>
    public void ScrollToEnd()
    {
        (long first, double pixel) = MaxOffset();
        SetOffset(first, pixel);
    }

    /// <summary>Scrolls by <paramref name="dy"/> epx, down when positive, clamped to the rows.</summary>
    public void ScrollByPixels(double dy)
    {
        if (double.IsFinite(dy))
            SetOffset(_firstRow, _pixelInRow + dy);
    }

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

    /// <summary>The subject of <paramref name="row"/>'s commit; empty for a synthetic row or a row without one.</summary>
    public string SubjectOf(long row)
    {
        if (row < 0 || row >= _count || row >= _commits.Count || _rows[(int)row].Node.IsSynthetic)
            return "";
        return _commits[(int)row].Subject;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new GraphAutomationPeer(this);

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        var position = e.GetCurrentPoint(_canvas).Position;
        if (position.X < 0 || position.X >= _canvas.ActualWidth)
        {
            base.OnPointerPressed(e);
            return;
        }

        Focus(FocusState.Pointer);
        long row = HitTest(position.Y);
        if (row >= 0)
            Select(row);
        e.Handled = true;
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
                ScrollByPixels(-RowHeight);
                break;
            case VirtualKey.Down:
                ScrollByPixels(RowHeight);
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
    private void SetOffset(long first, double pixel, bool syncScrollBar = true)
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
        if (syncScrollBar)
            UpdateScrollBar();
        _canvas.Invalidate();
    }

    private void OnViewportChanged()
    {
        SetOffset(_firstRow, _pixelInRow);
        UpdateScrollBar();
    }

    /// <summary>The scroll bar counts rows: its value is the top row plus the fraction scrolled off it.</summary>
    private void UpdateScrollBar()
    {
        double rh = RowHeight;
        (long maxFirst, double maxPixel) = MaxOffset();
        double maximum = maxFirst + maxPixel / rh;
        double viewportRows = ViewportHeight / rh;
        _settingScrollBar = true;
        try
        {
            _scrollBar.Maximum = maximum;
            _scrollBar.ViewportSize = viewportRows;
            _scrollBar.LargeChange = Math.Max(1, viewportRows - 1);
            _scrollBar.Value = Math.Min(maximum, _firstRow + _pixelInRow / rh);
            _scrollBar.IsEnabled = maximum > 0;
        }
        finally
        {
            _settingScrollBar = false;
        }
    }

    private void OnScrollBarValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_settingScrollBar)
            return;

        // The end of the bar is exactly the last row, whatever rounding the value went through.
        if (e.NewValue >= _scrollBar.Maximum)
        {
            (long first, double pixel) = MaxOffset();
            SetOffset(first, pixel, syncScrollBar: false);
            return;
        }

        double row = Math.Floor(Math.Max(0, e.NewValue));
        SetOffset((long)row, (Math.Max(0, e.NewValue) - row) * RowHeight, syncScrollBar: false);
    }

    private void OnCreateResources(CanvasControl sender, CanvasCreateResourcesEventArgs args) =>
        ReleaseDeviceResources();

    private void ReleaseDeviceResources() => _renderer.ResetDeviceResources();

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
            for (long r = first; r <= last; r++)
                _columnLanes = Math.Max(_columnLanes, _rows[(int)r].Width);

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
                GraphRow row = _rows[(int)r];
                _renderer.DrawRow(ds, row, top, column, selected);
                if (drawText && SubjectOf(r) is { Length: > 0 } subject)
                    _renderer.DrawSubject(ds, subject, textX, top, textWidth, selected);
            }

            lastFull = (last - first + 1) * rh - _pixelInRow <= height + 0.001;
        }

        DrawCompleted?.Invoke(
            this,
            new GraphDrawInfo(Stopwatch.GetElapsedTime(started).TotalMilliseconds, first, last, lastFull, SelectedRow));
    }
}

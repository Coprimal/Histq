using System.Numerics;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Windows.UI;

namespace Histq.App.Graph;

/// <summary>
/// Sizes of the graph from the row height (ported from GraphMetrics in App/Graph/GraphRowDrawing.swift at 6fa6d40, the
/// Regular density with the Vivid lane colors). The band, the selection and the node share one height, centered in the
/// row with a 3 epx gap above and below where the lane lines run between two rows.
/// </summary>
internal sealed record GraphMetrics(double RowHeight)
{
    /// <summary>The default density: 30 epx rows.</summary>
    public static GraphMetrics Regular { get; } = new(30);

    /// <summary>Before lane 0.</summary>
    public const double Leading = 6;

    /// <summary>After the last lane at the column's widest.</summary>
    public const double Trailing = 24;

    /// <summary>The least gap between a node's right edge and the column's right edge.</summary>
    public const double MinTrailing = 6;

    /// <summary>Vivid lines: 1.5 epx.</summary>
    public const float LineWidth = 1.5f;

    public double BandHeight => RowHeight - 6;

    /// <summary>A commit's node: as tall as the band.</summary>
    public double NodeDiameter => BandHeight;

    /// <summary>From one lane's center to the next: a node and a small gap.</summary>
    public double LaneWidth => NodeDiameter + 4;

    /// <summary>A merge commit's dot: scales with the node, kept even so it centers on whole pixels.</summary>
    public double MergeDotDiameter => 2 * Math.Round(NodeDiameter * 0.2, MidpointRounding.AwayFromZero);

    /// <summary>The radius of a line's bend into or out of a node: a third of the node, at most half a row.</summary>
    public double BendRadius => Math.Min(Math.Round(NodeDiameter / 3, MidpointRounding.AwayFromZero), RowHeight / 2);

    /// <summary>The narrowest graph column: lane 0's node and <see cref="MinTrailing"/> after it.</summary>
    public double MinColumnWidth => X(0) + NodeDiameter / 2 + MinTrailing;

    /// <summary>The center of <paramref name="lane"/>, from the graph column's left edge.</summary>
    public double X(int lane) => Leading + lane * LaneWidth + LaneWidth / 2;

    /// <summary>The graph column's width that shows <paramref name="lanes"/> lanes.</summary>
    public double Width(int lanes) => Leading + lanes * LaneWidth + Trailing;

    /// <summary>
    /// <paramref name="lane"/>'s node has room in a column <paramref name="columnWidth"/> wide. Lane 0 always has; a lane
    /// that does not is left out (the macOS fold, which slides such nodes left, comes with the real graph view).
    /// </summary>
    public bool Fits(int lane, double columnWidth) =>
        lane == 0 || X(lane) <= columnWidth - MinTrailing - NodeDiameter / 2 + 0.001;
}

/// <summary>
/// The graph's Vivid colors by palette index (App/GlassStyle.swift at 6fa6d40): lines and nodes, the faint row band
/// and the selected row's band; the grey of stash rows and other worktrees' WIP rows. Read once from Theme/Palette.xaml
/// on the first draw (the UI thread), so no draw call looks a resource up.
/// </summary>
internal static class GraphPalette
{
    private static ColorSet? _colors;

    private static ColorSet Current => _colors ??= new ColorSet();

    /// <summary>The inside of a hollow node (WIP, stash), so the lines under it do not show.</summary>
    public static Color Surface => Current.Surface;

    /// <summary>A row's subject: white at 0.85, full white on the selected row.</summary>
    public static Color SubjectText => Current.SubjectText;

    public static Color SelectedSubjectText => Current.SelectedSubjectText;

    /// <summary>The scroll thumb at rest, and hovered or dragged.</summary>
    public static Color ScrollThumbRest => Current.ScrollThumbRest;

    public static Color ScrollThumbActive => Current.ScrollThumbActive;

    /// <summary>A <see cref="GraphRow"/> or <see cref="GraphSegment"/> color: its lane color, or the stash grey.</summary>
    public static Color Lane(int color)
    {
        ColorSet colors = Current;
        return color == GraphLayout.StashColor
            ? colors.Stash
            : colors.Lines[(int)((uint)color % (uint)colors.Lines.Length)];
    }

    /// <summary>The band of a row of <paramref name="color"/>, brighter on the selected row.</summary>
    public static Color Band(int color, bool selected)
    {
        ColorSet colors = Current;
        if (color == GraphLayout.StashColor)
            return selected ? colors.StashSelectedBand : colors.StashBand;
        Color[] bands = selected ? colors.SelectedBands : colors.Bands;
        return bands[(int)((uint)color % (uint)bands.Length)];
    }

    private static Color WithAlpha(Color color, double alpha) =>
        ColorHelper.FromArgb((byte)Math.Round(alpha * 255), color.R, color.G, color.B);

    private static Color[] WithAlpha(Color[] colors, double alpha) =>
        Array.ConvertAll(colors, color => WithAlpha(color, alpha));

    private sealed class ColorSet
    {
        // Blue, orange, green, pink, cyan, yellow, purple, red.
        public readonly Color[] Lines =
            Enumerable.Range(0, 8).Select(i => PaletteResources.Color($"Lane{i}Color")).ToArray();

        public readonly Color Stash = PaletteResources.Color("GraphStashColor");
        public readonly Color Surface = PaletteResources.Color("SheetCardOpaqueColor");
        public readonly Color SubjectText = PaletteResources.Color("GraphSubjectTextColor");
        public readonly Color SelectedSubjectText = PaletteResources.Color("GraphSelectedSubjectTextColor");
        public readonly Color ScrollThumbRest = PaletteResources.Color("ScrollThumbRestColor");
        public readonly Color ScrollThumbActive = PaletteResources.Color("ScrollThumbActiveColor");
        public readonly Color[] Bands;
        public readonly Color[] SelectedBands;
        public readonly Color StashBand;
        public readonly Color StashSelectedBand;

        public ColorSet()
        {
            double band = PaletteResources.Double("GraphBandOpacity");
            double selectedBand = PaletteResources.Double("GraphSelectedBandOpacity");
            Bands = WithAlpha(Lines, band);
            SelectedBands = WithAlpha(Lines, selectedBand);
            StashBand = WithAlpha(Stash, band);
            StashSelectedBand = WithAlpha(Stash, selectedBand);
        }
    }
}

/// <summary>
/// Draws one graph row with Win2D (ported from App/Graph/GraphRowDrawing.swift at 6fa6d40): the faint band from the
/// node to the column's edge, ending in a 2 epx bar in the lane color; the lane lines, rounded where they bend into or
/// out of the node; the node; and the subject. Coordinates are relative to the row's top, so the caller's scroll offset
/// never reaches a float beyond the viewport.
/// <para>
/// Nothing here allocates per frame (but the cut copy of a subject over 512 chars): lines are drawn as such, the four
/// quarter arcs of a bend are built once per device and drawn at an offset, and the stroke styles and text format are
/// shared. It needs only a drawing session and a
/// resource creator, so it draws the same on any Win2D host.
/// </para>
/// </summary>
internal sealed class GraphRowRenderer : IDisposable
{
    /// <summary>The subject is cut here before it is drawn: a hostile repository's huge subject stays cheap.</summary>
    private const int MaxSubjectLength = 512;

    // The quarter arcs of a bend, by direction (see Bend).
    private const int BendInRight = 0;
    private const int BendInLeft = 1;
    private const int BendOutRight = 2;
    private const int BendOutLeft = 3;

    private readonly CanvasStrokeStyle _solid = new()
    {
        StartCap = CanvasCapStyle.Round,
        EndCap = CanvasCapStyle.Round,
        LineJoin = CanvasLineJoin.Round,
    };

    // A synthetic row's line to its base: 3 on, 3 off at 1.5 epx (dash lengths are in stroke widths).
    private readonly CanvasStrokeStyle _dashed = new()
    {
        StartCap = CanvasCapStyle.Round,
        EndCap = CanvasCapStyle.Round,
        DashCap = CanvasCapStyle.Round,
        LineJoin = CanvasLineJoin.Round,
        CustomDashStyle = [2f, 2f],
    };

    // A WIP or stash node's outline: 2.5 on, 2.5 off at 1.5 epx.
    private readonly CanvasStrokeStyle _nodeDashed = new() { CustomDashStyle = [2.5f / 1.5f, 2.5f / 1.5f] };

    private readonly CanvasTextFormat _subjectFormat = new()
    {
        FontFamily = "Segoe UI Variable Text",
        FontSize = 13,
        WordWrapping = CanvasWordWrapping.NoWrap,
        VerticalAlignment = CanvasVerticalAlignment.Center,
        TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
        TrimmingSign = CanvasTrimmingSign.Ellipsis,
    };

    private readonly CanvasGeometry?[] _bends = new CanvasGeometry?[4];

    public GraphRowRenderer(GraphMetrics metrics) => Metrics = metrics;

    public GraphMetrics Metrics { get; }

    /// <summary>Drops the geometries built on the current device (device lost, unload); they are rebuilt on use.</summary>
    public void ResetDeviceResources()
    {
        for (int i = 0; i < _bends.Length; i++)
        {
            _bends[i]?.Dispose();
            _bends[i] = null;
        }
    }

    public void Dispose()
    {
        ResetDeviceResources();
        _solid.Dispose();
        _dashed.Dispose();
        _nodeDashed.Dispose();
        _subjectFormat.Dispose();
    }

    /// <summary>
    /// Draws <paramref name="row"/>'s graph part in the column from x 0 to <paramref name="columnWidth"/>, the row's
    /// top at <paramref name="top"/>. <paramref name="selected"/> draws the band brighter.
    /// </summary>
    public void DrawRow(CanvasDrawingSession ds, in GraphRow row, float top, float columnWidth, bool selected)
    {
        GraphMetrics m = Metrics;
        float mid = top + (float)(m.RowHeight / 2);
        bool nodeFits = m.Fits(row.Lane, columnWidth);
        float nodeX = (float)m.X(row.Lane);
        Color laneColor = GraphPalette.Lane(row.Color);

        // The band, from the node to the column's edge, ending in a 2 epx bar in the lane color.
        if (nodeFits && columnWidth > nodeX)
        {
            float bandHeight = (float)m.BandHeight;
            float bandTop = mid - bandHeight / 2;
            ds.FillRectangle(nodeX, bandTop, columnWidth - nodeX, bandHeight, GraphPalette.Band(row.Color, selected));
            ds.FillRectangle(columnWidth - 2, bandTop, 2, bandHeight, laneColor);
        }

        if (!row.Top.IsDefault)
        {
            foreach (GraphSegment segment in row.Top)
            {
                if (m.Fits(segment.From, columnWidth) && m.Fits(segment.To, columnWidth))
                    DrawSegment(ds, segment, topHalf: true, top, mid);
            }
        }

        if (!row.Bottom.IsDefault)
        {
            foreach (GraphSegment segment in row.Bottom)
            {
                if (m.Fits(segment.From, columnWidth) && m.Fits(segment.To, columnWidth))
                    DrawSegment(ds, segment, topHalf: false, top, mid);
            }
        }

        if (nodeFits)
            DrawNode(ds, row, new Vector2(nodeX, mid), laneColor);
    }

    /// <summary>
    /// Draws <paramref name="subject"/> from <paramref name="x"/>, <paramref name="width"/> wide (more than 0), on one
    /// line vertically centered in the row, ending in an ellipsis when cut. No text layout object is kept: each call
    /// draws with the shared format, so scrolling makes no managed wrapper per row.
    /// </summary>
    public void DrawSubject(CanvasDrawingSession ds, string subject, float x, float top, float width, bool selected)
    {
        string text = subject;
        if (text.Length > MaxSubjectLength)
        {
            // Cut on a surrogate boundary: never half a pair.
            int length = char.IsHighSurrogate(text[MaxSubjectLength - 1]) ? MaxSubjectLength - 1 : MaxSubjectLength;
            text = text[..length];
        }

        ds.DrawText(
            text,
            new Windows.Foundation.Rect(x, top, width, Metrics.RowHeight),
            selected ? GraphPalette.SelectedSubjectText : GraphPalette.SubjectText,
            _subjectFormat);
    }

    /// <summary>
    /// One line piece. Top half: from the row's top edge at lane <c>From</c> to the center at lane <c>To</c>. Bottom
    /// half: from the center at <c>From</c> to the bottom edge at <c>To</c>. Bends turn with <see cref="GraphMetrics.BendRadius"/>.
    /// </summary>
    private void DrawSegment(CanvasDrawingSession ds, GraphSegment segment, bool topHalf, float top, float mid)
    {
        GraphMetrics m = Metrics;
        float fromX = (float)m.X(segment.From);
        float toX = (float)m.X(segment.To);
        float bottom = top + (float)m.RowHeight;
        float radius = (float)m.BendRadius;
        float width = GraphMetrics.LineWidth;
        Color color = GraphPalette.Lane(segment.Color);
        CanvasStrokeStyle style = segment.IsDashed ? _dashed : _solid;
        bool bends = Math.Abs(toX - fromX) >= radius && radius > 0;
        float sign = toX > fromX ? 1 : -1;

        switch (segment.Shape)
        {
            case GraphSegmentShape.BendIn when bends:
                // Down lane From, then across to the node.
                ds.DrawLine(fromX, top, fromX, mid - radius, color, width, style);
                ds.DrawGeometry(
                    Bend(ds, sign > 0 ? BendInRight : BendInLeft), new Vector2(fromX, mid - radius), color, width, style);
                ds.DrawLine(fromX + sign * radius, mid, toX, mid, color, width, style);
                break;
            case GraphSegmentShape.BendOut when bends:
                // Across from the node, then down lane To.
                ds.DrawLine(fromX, mid, toX - sign * radius, mid, color, width, style);
                ds.DrawGeometry(
                    Bend(ds, sign > 0 ? BendOutRight : BendOutLeft), new Vector2(toX - sign * radius, mid), color, width,
                    style);
                ds.DrawLine(toX, mid + radius, toX, bottom, color, width, style);
                break;
            case GraphSegmentShape.BendIn:
                ds.DrawLine(fromX, top, fromX, mid, color, width, style);
                ds.DrawLine(fromX, mid, toX, mid, color, width, style);
                break;
            case GraphSegmentShape.BendOut:
                ds.DrawLine(fromX, mid, toX, mid, color, width, style);
                ds.DrawLine(toX, mid, toX, bottom, color, width, style);
                break;
            default:
                if (topHalf)
                    ds.DrawLine(fromX, top, toX, mid, color, width, style);
                else
                    ds.DrawLine(fromX, mid, toX, bottom, color, width, style);
                break;
        }
    }

    /// <summary>
    /// A bend's quarter arc from (0, 0), built once per device. In: heading down, then turning to the node (right or
    /// left). Out: heading across from the node, then turning down.
    /// </summary>
    private CanvasGeometry Bend(ICanvasResourceCreator resourceCreator, int kind)
    {
        if (_bends[kind] is { } cached)
            return cached;

        float r = (float)Metrics.BendRadius;
        (Vector2 end, CanvasSweepDirection direction) = kind switch
        {
            BendInRight => (new Vector2(r, r), CanvasSweepDirection.CounterClockwise),
            BendInLeft => (new Vector2(-r, r), CanvasSweepDirection.Clockwise),
            BendOutRight => (new Vector2(r, r), CanvasSweepDirection.Clockwise),
            _ => (new Vector2(-r, r), CanvasSweepDirection.CounterClockwise),
        };
        using var builder = new CanvasPathBuilder(resourceCreator);
        builder.BeginFigure(Vector2.Zero);
        builder.AddArc(end, r, r, 0, direction, CanvasArcSize.Small);
        builder.EndFigure(CanvasFigureLoop.Open);
        CanvasGeometry geometry = CanvasGeometry.CreatePath(builder);
        _bends[kind] = geometry;
        return geometry;
    }

    /// <summary>
    /// The node: a commit's filled circle (its avatar and initials come with the real graph view), a merge's small
    /// dot, a WIP row's dashed circle, a stash's dashed rounded square.
    /// </summary>
    private void DrawNode(CanvasDrawingSession ds, in GraphRow row, Vector2 center, Color color)
    {
        GraphMetrics m = Metrics;
        float diameter = (float)m.NodeDiameter;
        if (row.Node.SyntheticRow is { } synthetic)
        {
            float hollow = diameter - 2;
            Color band = GraphPalette.Band(row.Color, selected: false);
            if (synthetic.Kind == GraphSyntheticRowKind.Stash)
            {
                var rect = new Windows.Foundation.Rect(
                    center.X - hollow / 2, center.Y - hollow / 2, hollow, hollow);
                ds.FillRoundedRectangle(rect, 2, 2, GraphPalette.Surface);
                ds.FillRoundedRectangle(rect, 2, 2, band);
                ds.DrawRoundedRectangle(rect, 2, 2, color, GraphMetrics.LineWidth, _nodeDashed);
            }
            else
            {
                ds.FillCircle(center, hollow / 2, GraphPalette.Surface);
                ds.FillCircle(center, hollow / 2, band);
                ds.DrawCircle(center, hollow / 2, color, GraphMetrics.LineWidth, _nodeDashed);
            }
        }
        else if (row.Node.IsMerge)
        {
            ds.FillCircle(center, (float)(m.MergeDotDiameter / 2), color);
        }
        else
        {
            ds.FillCircle(center, diameter / 2, color);
        }
    }
}

/// <summary>
/// The graph's overlay scroll bar, drawn by <see cref="GraphCanvas"/> over the right edge of its rows, so scrolling
/// changes no XAML element: no track, only a thin rounded white thumb, 4 epx wide at rest and 8 epx while hovered or
/// dragged. The geometry is plain double math on a fraction of the scroll range (0 = the top, 1 = exactly the end); the
/// canvas maps that fraction to and from its (row, pixel) offset.
/// </summary>
internal static class GraphScrollBar
{
    /// <summary>The canvas's right strip that is the scroll bar: hovering shows the thumb, a press never selects.</summary>
    public const double ZoneWidth = 12;

    public const double RestWidth = 4;

    public const double ActiveWidth = 8;

    /// <summary>Between the thumb and the canvas's right, top and bottom edges.</summary>
    public const double Inset = 2;

    public const double MinThumbLength = 24;

    /// <summary>The track's length in a canvas <paramref name="height"/> tall: the height less the insets.</summary>
    public static double TrackLength(double height) => Math.Max(0, height - 2 * Inset);

    /// <summary>
    /// The thumb's length on a track <paramref name="trackLength"/> long when the viewport shows
    /// <paramref name="viewFraction"/> of the rows: at least <see cref="MinThumbLength"/>, at most the track.
    /// </summary>
    public static double ThumbLength(double trackLength, double viewFraction) =>
        Math.Min(trackLength, Math.Max(MinThumbLength, trackLength * Math.Clamp(viewFraction, 0, 1)));

    /// <summary>The thumb's top at scroll <paramref name="fraction"/>: the track's start at 0, its end at 1.</summary>
    public static double ThumbTop(double trackLength, double thumbLength, double fraction) =>
        Inset + Math.Clamp(fraction, 0, 1) * Math.Max(0, trackLength - thumbLength);

    /// <summary>The scroll fraction of a thumb whose top is at <paramref name="thumbTop"/>, clamped to 0 and 1.</summary>
    public static double FractionAt(double thumbTop, double trackLength, double thumbLength)
    {
        double travel = trackLength - thumbLength;
        return travel > 0 ? Math.Clamp((thumbTop - Inset) / travel, 0, 1) : 0;
    }

    /// <summary>
    /// Draws the thumb at the right edge of a canvas <paramref name="width"/> wide, wider and brighter when
    /// <paramref name="active"/> (hovered or dragged), at <paramref name="opacity"/> (0 to 1) of its color.
    /// </summary>
    public static void Draw(
        CanvasDrawingSession ds, double width, double thumbTop, double thumbLength, bool active, double opacity)
    {
        double thumbWidth = active ? ActiveWidth : RestWidth;
        Color color = active ? GraphPalette.ScrollThumbActive : GraphPalette.ScrollThumbRest;
        byte alpha = (byte)Math.Round(color.A * Math.Clamp(opacity, 0, 1));
        float radius = (float)(thumbWidth / 2);
        ds.FillRoundedRectangle(
            new Windows.Foundation.Rect(width - Inset - thumbWidth, thumbTop, thumbWidth, thumbLength),
            radius,
            radius,
            ColorHelper.FromArgb(alpha, color.R, color.G, color.B));
    }
}

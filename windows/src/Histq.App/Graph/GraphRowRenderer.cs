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
/// Sizes of the graph from the row height (the rowDensity preference) and its lane colors (ported from GraphMetrics in
/// App/Graph/GraphRowDrawing.swift at 6fa6d40, at the Regular text size). The band, the selection and the node share
/// one height, centered in the row with a 3 epx gap above and below where the lane lines run between two rows. A graph
/// column too narrow for its lanes folds them continuously (<see cref="DrawnX"/>).
/// </summary>
/// <param name="Gradient">The Gradient lane colors (laneColors), one per column, with 2 epx lines; else Vivid.</param>
internal sealed record GraphMetrics(double RowHeight, bool Gradient = false)
{
    /// <summary>The default density: 30 epx rows, Vivid.</summary>
    public static GraphMetrics Regular { get; } = new(30);

    /// <summary>Before lane 0.</summary>
    public const double Leading = 6;

    /// <summary>After the last lane at the column's widest.</summary>
    public const double Trailing = 24;

    /// <summary>The least gap between a node's right edge and the column's right edge.</summary>
    public const double MinTrailing = 6;

    /// <summary>A WIP or stash node's dashed outline.</summary>
    public const float NodeLineWidth = 1.5f;

    /// <summary>"compact" 26, "comfortable" 34, anything else regular (30).</summary>
    public static GraphMetrics For(string? density, bool gradient) => new(
        density switch
        {
            "compact" => 26,
            "comfortable" => 34,
            _ => 30,
        },
        gradient);

    /// <summary>Vivid lines 1.5 epx, Gradient 2.</summary>
    public float LineWidth => Gradient ? 2f : 1.5f;

    public double BandHeight => RowHeight - 6;

    /// <summary>The band's and the selection's inset from the row's top and bottom.</summary>
    public double BandInset => (RowHeight - BandHeight) / 2;

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

    /// <summary>The right-most node center a column <paramref name="width"/> wide has room for, never left of lane
    /// 0's.</summary>
    public double FoldLimit(double width) => Math.Max(X(0), width - MinTrailing - NodeDiameter / 2);

    /// <summary>Where <paramref name="lane"/>'s node is drawn in a column <paramref name="width"/> wide: its own center,
    /// or the fold limit when the column has no room for it (the right-most nodes slide left, onto their neighbours'
    /// lines, down to lane 0).</summary>
    public double DrawnX(int lane, double width) => Math.Min(X(lane), FoldLimit(width));

    /// <summary><paramref name="lane"/> has no room in a column <paramref name="width"/> wide: its node is pushed left
    /// and its lines are not drawn. Lane 0 never is.</summary>
    public bool IsPinned(int lane, double width) => X(lane) > FoldLimit(width) + 0.001;

    /// <summary>The lane lines' opacity in a column <paramref name="width"/> wide for a log of
    /// <paramref name="logLanes"/> lanes: 1 until lane 1 is pinned, then fading to 0 as lane 1's nodes slide onto lane
    /// 0, so the narrowest column draws no lane line. A one-lane log keeps its line.</summary>
    public double LineAlpha(double width, int logLanes) =>
        logLanes <= 1 ? 1 : Math.Clamp((FoldLimit(width) - X(0)) / LaneWidth, 0, 1);
}

/// <summary>
/// The graph's colors by palette index (App/GlassStyle.swift and GraphRowDrawing.swift at 6fa6d40): the Vivid or
/// Gradient lines and nodes, the faint row band and the selected row's band; the grey of stash rows and other worktrees'
/// WIP rows; the texts and the selection. Read once from Theme/Palette.xaml on the first draw (the UI thread), so no
/// draw call looks a resource up.
/// </summary>
internal static class GraphPalette
{
    /// <summary>Another worktree's faded row, node and lines (Palette.graphOtherWorktreeAlpha).</summary>
    public const float OtherWorktreeAlpha = 0.45f;

    /// <summary>A faded row's text.</summary>
    public const float DimmedTextAlpha = 0.35f;

    private static ColorSet? _colors;

    private static ColorSet Current => _colors ??= new ColorSet();

    /// <summary>The inside of a hollow node (WIP, stash), so the lines under it do not show.</summary>
    public static Color Surface => Current.Surface;

    /// <summary>A row's subject: white at 0.85, full white on the selected row.</summary>
    public static Color SubjectText => Current.SubjectText;

    public static Color SelectedSubjectText => Current.SelectedSubjectText;

    /// <summary>The author, the date, a stash's and another worktree's label.</summary>
    public static Color SecondaryText => Current.SecondaryText;

    /// <summary>The selected row's fill, from its node to the right edge.</summary>
    public static Color Selection => Current.Selection;

    /// <summary>The scroll bar's thumb at rest, and hovered or dragged.</summary>
    public static Color ScrollThumbRest => Current.ScrollThumbRest;

    public static Color ScrollThumbActive => Current.ScrollThumbActive;

    /// <summary>A badge's text and icons, and a tag's (and the "+N" chip's) neutral fill.</summary>
    public static Color BadgeText => Current.BadgeText;

    public static Color TagFill => Current.TagFill;

    /// <summary>A WIP row's edited, added and deleted counts' glyphs: orange, green, red.</summary>
    public static Color Edited => Current.Vivid.Lines[1];

    public static Color Added => Current.Vivid.Lines[2];

    public static Color Deleted => Current.Vivid.Lines[7];

    /// <summary>A <see cref="GraphRow"/> or <see cref="GraphSegment"/> color: its lane color, or the stash grey.</summary>
    public static Color Lane(int color, bool gradient)
    {
        ColorSet colors = Current;
        if (color == GraphLayout.StashColor)
            return colors.Stash;
        Color[] lines = (gradient ? colors.Gradient : colors.Vivid).Lines;
        return lines[(int)((uint)color % (uint)lines.Length)];
    }

    /// <summary>The band of a row of <paramref name="color"/>, brighter on the selected row.</summary>
    public static Color Band(int color, bool gradient, bool selected)
    {
        ColorSet colors = Current;
        if (color == GraphLayout.StashColor)
            return selected ? colors.StashSelectedBand : colors.StashBand;
        LaneSet set = gradient ? colors.Gradient : colors.Vivid;
        Color[] bands = selected ? set.SelectedBands : set.Bands;
        return bands[(int)((uint)color % (uint)bands.Length)];
    }

    /// <summary>A branch or HEAD badge's fill on a row of <paramref name="color"/>: its lane color at 0.38, the
    /// checked-out branch's at 0.6; the stash grey's on a stash or other worktree's row.</summary>
    public static Color BadgeFill(int color, bool gradient, bool head)
    {
        ColorSet colors = Current;
        if (color == GraphLayout.StashColor)
            return colors.StashBadgeFill;
        LaneSet set = gradient ? colors.Gradient : colors.Vivid;
        Color[] fills = head ? set.HeadBadgeFills : set.BadgeFills;
        return fills[(int)((uint)color % (uint)fills.Length)];
    }

    /// <summary><paramref name="color"/> at <paramref name="alpha"/> of its own alpha.</summary>
    public static Color Faded(Color color, float alpha) =>
        alpha >= 1 ? color : ColorHelper.FromArgb((byte)Math.Round(color.A * Math.Clamp(alpha, 0, 1)), color.R, color.G, color.B);

    private static Color WithAlpha(Color color, double alpha) =>
        ColorHelper.FromArgb((byte)Math.Round(alpha * 255), color.R, color.G, color.B);

    private static Color[] WithAlpha(Color[] colors, double alpha) =>
        Array.ConvertAll(colors, color => WithAlpha(color, alpha));

    /// <summary>One lane color set: lines and nodes, row bands, selected row bands, badge fills.</summary>
    private sealed class LaneSet(Color[] lines, double band, double selectedBand, double badge, double headBadge)
    {
        public readonly Color[] Lines = lines;
        public readonly Color[] Bands = WithAlpha(lines, band);
        public readonly Color[] SelectedBands = WithAlpha(lines, selectedBand);
        public readonly Color[] BadgeFills = WithAlpha(lines, badge);
        public readonly Color[] HeadBadgeFills = WithAlpha(lines, headBadge);
    }

    private sealed class ColorSet
    {
        public readonly Color Stash = PaletteResources.Color("GraphStashColor");
        public readonly Color Surface = PaletteResources.Color("SheetCardOpaqueColor");
        public readonly Color SubjectText = PaletteResources.Color("GraphSubjectTextColor");
        public readonly Color SelectedSubjectText = PaletteResources.Color("GraphSelectedSubjectTextColor");
        public readonly Color SecondaryText = PaletteResources.Color("GraphSecondaryTextColor");
        public readonly Color Selection = PaletteResources.Color("GraphSelectionColor");
        public readonly Color ScrollThumbRest = PaletteResources.Color("ScrollThumbRestColor");
        public readonly Color ScrollThumbActive = PaletteResources.Color("ScrollThumbActiveColor");
        public readonly Color BadgeText = PaletteResources.Color("GraphBadgeTextColor");
        public readonly Color TagFill = PaletteResources.Color("GraphTagFillColor");
        public readonly LaneSet Vivid;
        public readonly LaneSet Gradient;
        public readonly Color StashBand;
        public readonly Color StashSelectedBand;
        public readonly Color StashBadgeFill;

        public ColorSet()
        {
            double band = PaletteResources.Double("GraphBandOpacity");
            double selectedBand = PaletteResources.Double("GraphSelectedBandOpacity");
            double badge = PaletteResources.Double("BadgeFillOpacity");
            double headBadge = PaletteResources.Double("HeadBadgeFillOpacity");
            // Vivid: blue, orange, green, pink, cyan, yellow, purple, red. Gradient: 10 hues in order.
            Vivid = new LaneSet(
                Enumerable.Range(0, 8).Select(i => PaletteResources.Color($"Lane{i}Color")).ToArray(), band, selectedBand,
                badge, headBadge);
            Gradient = new LaneSet(
                Enumerable.Range(0, 10).Select(i => PaletteResources.Color($"GradientLane{i}Color")).ToArray(), band,
                selectedBand, badge, headBadge);
            StashBand = WithAlpha(Stash, band);
            StashSelectedBand = WithAlpha(Stash, selectedBand);
            StashBadgeFill = WithAlpha(Stash, badge);
        }
    }
}

/// <summary>What a row's graph part draws besides its lanes (GraphCellView in GraphRowDrawing.swift at 6fa6d40).</summary>
/// <param name="Avatar">A commit node's avatar (<see cref="AvatarRenderer"/>), drawn inside a ring of the lane color;
/// null for a plain node.</param>
/// <param name="HasRefs">The row has badges: the line from the column's left edge (where the badges' line ends) runs to
/// the node.</param>
/// <param name="HeadRef">One of them is the checked-out branch (or a detached HEAD): that line is full.</param>
internal readonly record struct GraphNodeDecor(ICanvasImage? Avatar = null, bool HasRefs = false, bool HeadRef = false);

/// <summary>
/// Draws one graph row with Win2D (ported from App/Graph/GraphRowDrawing.swift at 6fa6d40): the faint band from the
/// node to the column's edge, ending in a 2 epx bar in the lane color; the lane lines, rounded where they bend into or
/// out of the node; the node; and the row's texts. Coordinates are relative to the graph column's left edge and the
/// row's top, so the caller's scroll offset never reaches a float beyond the viewport. A column too narrow for the
/// log's lanes folds them (<see cref="GraphMetrics.DrawnX"/>): the right-most nodes slide left, a pinned lane's lines are
/// not drawn, and as lane 1 folds onto lane 0 the lines fade out (<see cref="GraphMetrics.LineAlpha"/>; each line is
/// faded on its own, where the Mac fades them through one layer).
/// <para>
/// Nothing here allocates per frame (but the cut copy of a text over 512 chars, and a WIP row's text with its change
/// counts): lines are drawn as such, the four quarter arcs of a bend are built once per device and drawn at an offset,
/// and the stroke styles and text formats are shared. It needs only a drawing session and a resource creator, so it
/// draws the same on any Win2D host.
/// </para>
/// </summary>
internal sealed class GraphRowRenderer : IDisposable
{
    /// <summary>A text is cut here before it is drawn: a hostile repository's huge subject stays cheap.</summary>
    private const int MaxTextLength = 512;

    /// <summary>A text cell's padding, left and right.</summary>
    public const float TextPadding = 8;

    // The quarter arcs of a bend, by direction (see Bend).
    private const int BendInRight = 0;
    private const int BendInLeft = 1;
    private const int BendOutRight = 2;
    private const int BendOutLeft = 3;

    // A WIP row's change count glyphs (Segoe Fluent Icons): edit, add, remove.
    private const string IconFont = "Segoe Fluent Icons";
    private const char EditedGlyph = '\uE70F';
    private const char AddedGlyph = '\uE710';
    private const char DeletedGlyph = '\uE738';

    private readonly CanvasStrokeStyle _solid = new()
    {
        StartCap = CanvasCapStyle.Round,
        EndCap = CanvasCapStyle.Round,
        LineJoin = CanvasLineJoin.Round,
    };

    // A WIP or stash node's outline: 2.5 on, 2.5 off at 1.5 epx.
    private readonly CanvasStrokeStyle _nodeDashed = new() { CustomDashStyle = [2.5f / 1.5f, 2.5f / 1.5f] };

    private readonly CanvasTextFormat _textFormat = NewTextFormat(italic: false);

    private readonly CanvasTextFormat _italicFormat = NewTextFormat(italic: true);

    private readonly CanvasGeometry?[] _bends = new CanvasGeometry?[4];

    // A synthetic row's line to its base: 3 on, 3 off (dash lengths are in stroke widths, so it follows the metrics).
    private CanvasStrokeStyle _dashed;

    public GraphRowRenderer(GraphMetrics metrics)
    {
        Metrics = metrics;
        _dashed = NewDashed(metrics.LineWidth);
    }

    public GraphMetrics Metrics { get; private set; }

    /// <summary>Draws with <paramref name="metrics"/> from now on (a row density or lane color change). UI thread,
    /// between two draws.</summary>
    public void SetMetrics(GraphMetrics metrics)
    {
        if (metrics == Metrics)
            return;
        bool lineChanged = metrics.LineWidth != Metrics.LineWidth;
        Metrics = metrics;
        ResetDeviceResources();
        if (lineChanged)
        {
            _dashed.Dispose();
            _dashed = NewDashed(metrics.LineWidth);
        }
    }

    /// <summary>Drops the geometries built on the current device (device lost, unload, new metrics); they are rebuilt
    /// on use.</summary>
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
        _textFormat.Dispose();
        _italicFormat.Dispose();
    }

    /// <summary>
    /// Draws <paramref name="row"/>'s graph part in the column from x 0 to <paramref name="columnWidth"/>, the row's
    /// top at <paramref name="top"/>, for a log of <paramref name="logLanes"/> lanes. <paramref name="selected"/> draws
    /// the band brighter; <paramref name="nodeAlpha"/> fades the row's own band and node (another worktree's row), and
    /// <paramref name="fade"/> tells, by <see cref="GraphSegment.Owner"/>, the lines drawn faded.
    /// </summary>
    public void DrawRow(
        CanvasDrawingSession ds, in GraphRow row, float top, float columnWidth, bool selected, int logLanes,
        GraphRowSource? fade = null, float nodeAlpha = 1, GraphNodeDecor decor = default)
    {
        GraphMetrics m = Metrics;
        float mid = top + (float)(m.RowHeight / 2);
        float nodeX = (float)m.DrawnX(row.Lane, columnWidth);
        Color laneColor = GraphPalette.Lane(row.Color, m.Gradient);

        // The band, from the node to the column's edge, ending in a 2 epx bar in the lane color.
        if (columnWidth > nodeX)
        {
            float bandHeight = (float)m.BandHeight;
            float bandTop = mid - bandHeight / 2;
            ds.FillRectangle(
                nodeX, bandTop, columnWidth - nodeX, bandHeight,
                GraphPalette.Faded(GraphPalette.Band(row.Color, m.Gradient, selected), nodeAlpha));
            ds.FillRectangle(columnWidth - 2, bandTop, 2, bandHeight, GraphPalette.Faded(laneColor, nodeAlpha));
        }

        // The badges' line, on from the column's left edge to the node.
        if (decor.HasRefs && nodeX > 0)
        {
            ds.DrawLine(
                0, mid, nodeX, mid,
                GraphPalette.Faded(laneColor, nodeAlpha * RefBadgeRenderer.RefsLineAlpha(decor.HeadRef)),
                RefBadgeRenderer.RefsLineWidth(decor.HeadRef));
        }

        // The same for every row of the column, so the lines never break between rows.
        float lineAlpha = (float)m.LineAlpha(columnWidth, logLanes);
        if (lineAlpha > 0.01f)
        {
            // A segment's edge end (top or bottom) must be on an unpinned lane; its center end may also be the node.
            if (!row.Top.IsDefault)
            {
                foreach (GraphSegment segment in row.Top)
                {
                    if (!m.IsPinned(segment.From, columnWidth) && Shows(segment.To, row.Lane, columnWidth))
                        DrawSegment(ds, segment, topHalf: true, top, mid, columnWidth, lineAlpha * SegmentAlpha(segment, fade));
                }
            }

            if (!row.Bottom.IsDefault)
            {
                foreach (GraphSegment segment in row.Bottom)
                {
                    if (Shows(segment.From, row.Lane, columnWidth) && !m.IsPinned(segment.To, columnWidth))
                        DrawSegment(ds, segment, topHalf: false, top, mid, columnWidth, lineAlpha * SegmentAlpha(segment, fade));
                }
            }
        }

        DrawNode(ds, row, new Vector2(nodeX, mid), laneColor, nodeAlpha, decor.Avatar);
    }

    /// <summary>The diameter of a commit node's avatar: inside a ring of the lane color as thick as the lines.</summary>
    public float AvatarDiameter => (float)Metrics.NodeDiameter - 2 * Metrics.LineWidth;

    /// <summary>
    /// Draws <paramref name="subject"/> from <paramref name="x"/>, <paramref name="width"/> wide, in the subject's
    /// color (full white on the selected row).
    /// </summary>
    public void DrawSubject(CanvasDrawingSession ds, string subject, float x, float top, float width, bool selected) =>
        DrawText(ds, subject, x, top, width, selected ? GraphPalette.SelectedSubjectText : GraphPalette.SubjectText, false);

    /// <summary>
    /// Draws <paramref name="text"/> from <paramref name="x"/>, <paramref name="width"/> wide (more than 0), on one line
    /// vertically centered in the row, ending in an ellipsis when cut. No text layout object is kept: each call draws
    /// with a shared format, so scrolling makes no managed wrapper per row.
    /// </summary>
    public void DrawText(
        CanvasDrawingSession ds, string text, float x, float top, float width, Color color, bool italic)
    {
        ds.DrawText(
            Cut(text), new Windows.Foundation.Rect(x, top, width, Metrics.RowHeight), color,
            italic ? _italicFormat : _textFormat);
    }

    /// <summary>
    /// A WIP row's text: <paramref name="label"/>, then each kind of change of <paramref name="changes"/> as its glyph
    /// in its color (edited orange, added green, deleted red) and its count, as <see cref="DrawText"/>. Builds a text
    /// layout: only the few WIP rows on screen draw it.
    /// </summary>
    public void DrawChanges(
        CanvasDrawingSession ds, string label, WorktreeChanges changes, float x, float top, float width, Color color,
        bool italic)
    {
        var text = new System.Text.StringBuilder(Cut(label));
        var glyphs = new List<(int Index, Color Color)>(3);
        foreach ((int count, char glyph, Color glyphColor) in new[]
                 {
                     (changes.Edited, EditedGlyph, GraphPalette.Edited),
                     (changes.Added, AddedGlyph, GraphPalette.Added),
                     (changes.Deleted, DeletedGlyph, GraphPalette.Deleted),
                 })
        {
            if (count <= 0)
                continue;
            text.Append("   ");
            glyphs.Add((text.Length, glyphColor));
            text.Append(glyph).Append(' ').Append(count.ToString(System.Globalization.CultureInfo.CurrentCulture));
        }

        using var layout = new CanvasTextLayout(
            ds, text.ToString(), italic ? _italicFormat : _textFormat, width, (float)Metrics.RowHeight);
        foreach ((int index, Color glyphColor) in glyphs)
        {
            layout.SetFontFamily(index, 1, IconFont);
            layout.SetFontStyle(index, 1, Windows.UI.Text.FontStyle.Normal);
            layout.SetFontSize(index, 1, 11);
            layout.SetColor(index, 1, glyphColor);
        }

        ds.DrawTextLayout(layout, x, top, color);
    }

    private static CanvasTextFormat NewTextFormat(bool italic) => new()
    {
        FontFamily = "Segoe UI Variable Text",
        FontSize = 13,
        FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
        WordWrapping = CanvasWordWrapping.NoWrap,
        VerticalAlignment = CanvasVerticalAlignment.Center,
        TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
        TrimmingSign = CanvasTrimmingSign.Ellipsis,
    };

    private static CanvasStrokeStyle NewDashed(float lineWidth) => new()
    {
        StartCap = CanvasCapStyle.Round,
        EndCap = CanvasCapStyle.Round,
        DashCap = CanvasCapStyle.Round,
        LineJoin = CanvasLineJoin.Round,
        CustomDashStyle = [3 / lineWidth, 3 / lineWidth],
    };

    /// <summary>The text cut at <see cref="MaxTextLength"/> on a surrogate boundary (never half a pair).</summary>
    private static string Cut(string text)
    {
        if (text.Length <= MaxTextLength)
            return text;
        int length = char.IsHighSurrogate(text[MaxTextLength - 1]) ? MaxTextLength - 1 : MaxTextLength;
        return text[..length];
    }

    /// <summary>A segment's center end at <paramref name="lane"/> shows: an unpinned lane, or the row's own node.</summary>
    private bool Shows(int lane, int nodeLane, float columnWidth) =>
        lane == nodeLane || !Metrics.IsPinned(lane, columnWidth);

    private static float SegmentAlpha(in GraphSegment segment, GraphRowSource? fade) =>
        fade is not null && segment.Owner >= 0 && fade.IsSegmentFaded(segment.Owner) ? GraphPalette.OtherWorktreeAlpha : 1;

    /// <summary>
    /// One line piece. Top half: from the row's top edge at lane <c>From</c> to the center at lane <c>To</c>. Bottom
    /// half: from the center at <c>From</c> to the bottom edge at <c>To</c>. Lanes are at their drawn x; bends turn with
    /// <see cref="GraphMetrics.BendRadius"/> (a straight corner when the lanes are closer than that).
    /// </summary>
    private void DrawSegment(
        CanvasDrawingSession ds, GraphSegment segment, bool topHalf, float top, float mid, float columnWidth, float alpha)
    {
        GraphMetrics m = Metrics;
        float fromX = (float)m.DrawnX(segment.From, columnWidth);
        float toX = (float)m.DrawnX(segment.To, columnWidth);
        float bottom = top + (float)m.RowHeight;
        float radius = (float)m.BendRadius;
        float width = m.LineWidth;
        Color color = GraphPalette.Faded(GraphPalette.Lane(segment.Color, m.Gradient), alpha);
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
    /// The node: a commit's filled circle with its avatar inside a ring of the lane color, a merge's small dot, a WIP
    /// row's dashed circle, a stash's dashed rounded square. A faded node (<paramref name="alpha"/> under 1) first
    /// covers the lines under it with the card's surface, so they do not show through.
    /// </summary>
    private void DrawNode(
        CanvasDrawingSession ds, in GraphRow row, Vector2 center, Color color, float alpha, ICanvasImage? avatar)
    {
        GraphMetrics m = Metrics;
        float diameter = (float)m.NodeDiameter;
        float hollow = diameter - 2;
        Color full = color;
        if (alpha < 0.99f)
        {
            ds.FillCircle(center, hollow / 2, GraphPalette.Surface);
            color = GraphPalette.Faded(color, alpha);
        }

        if (row.Node.SyntheticRow is { } synthetic)
        {
            Color band = GraphPalette.Faded(GraphPalette.Band(row.Color, m.Gradient, selected: false), alpha);
            if (synthetic.Kind == GraphSyntheticRowKind.Stash)
            {
                var rect = new Windows.Foundation.Rect(
                    center.X - hollow / 2, center.Y - hollow / 2, hollow, hollow);
                ds.FillRoundedRectangle(rect, 2, 2, GraphPalette.Surface);
                ds.FillRoundedRectangle(rect, 2, 2, band);
                ds.DrawRoundedRectangle(rect, 2, 2, color, GraphMetrics.NodeLineWidth, _nodeDashed);
            }
            else
            {
                ds.FillCircle(center, hollow / 2, GraphPalette.Surface);
                ds.FillCircle(center, hollow / 2, band);
                ds.DrawCircle(center, hollow / 2, color, GraphMetrics.NodeLineWidth, _nodeDashed);
            }
        }
        else if (row.Node.IsMerge)
        {
            ds.FillCircle(center, (float)(m.MergeDotDiameter / 2), color);
        }
        else if (avatar is not null && alpha < 0.99f)
        {
            // A faded node with its avatar: faded as a whole (one layer), so the ring does not show through the avatar.
            // Bounded to the node: no full-target layer per faded node.
            using (ds.CreateLayer(alpha, new Windows.Foundation.Rect(
                       center.X - diameter / 2 - 1, center.Y - diameter / 2 - 1, diameter + 2, diameter + 2)))
                DrawAvatarNode(ds, center, full, avatar);
        }
        else
        {
            if (avatar is not null)
                DrawAvatarNode(ds, center, color, avatar);
            else
                ds.FillCircle(center, diameter / 2, color);
        }
    }

    /// <summary>A commit's node: a disc of the lane color, the avatar inside it, a ring as thick as the lines left.</summary>
    private void DrawAvatarNode(CanvasDrawingSession ds, Vector2 center, Color color, ICanvasImage avatar)
    {
        ds.FillCircle(center, (float)Metrics.NodeDiameter / 2, color);
        float inner = AvatarDiameter;
        ds.DrawImage(
            avatar, new Windows.Foundation.Rect(center.X - inner / 2, center.Y - inner / 2, inner, inner),
            new Windows.Foundation.Rect(0, 0, inner, inner));
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

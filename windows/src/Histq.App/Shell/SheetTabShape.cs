using System.Numerics;
using Histq.App.Theme;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Histq.App.Shell;

/// <summary>
/// The page sheet and the selected tab joined to it as ONE closed figure (design header-and-tab-row.md §1.2, §3.2;
/// ported from TabSheetShape, App/Window/TabStrip.swift): the tab's top corners are rounded by half its height, and
/// at each bottom corner a concave flare runs out into the sheet's straight top edge. One filled figure has no inner
/// edge, so no seam can show between the tab and the sheet at any scale. The tab row draws the same tab shape as an
/// open outline (a grouped or popped-out archived tab) and cuts it out of the shapes behind the tabs (a worktree box,
/// the pinned well), so the translucent selected tab never sits on their fill (TabGroups.swift WorktreeBoxShape).
/// With the tabs on the left (design §4, VerticalTabSheetShape in App/Window/VerticalTabsPanel.swift) the selected row
/// joins the sheet's left edge instead: its leading corners rounded by half its height, a concave flare at each
/// trailing corner running out into the sheet's straight left edge.
/// </summary>
internal static class SheetTabShape
{
    // Palette.xaml values, read on each use: resources cannot be read in a static initializer.

    /// <summary>The sheet's inset from the window's left, right and bottom edges.</summary>
    public static double SheetInset => PaletteResources.Double("SheetInset");

    /// <summary>The sheet's outer corner radius.</summary>
    public static double SheetRadius => PaletteResources.Double("SheetRadius");

    /// <summary>The selected tab's top corner radius (half the 36 epx tab height).</summary>
    public static double TabRadius => PaletteResources.Double("TabRadius");

    /// <summary>The concave flare at each bottom corner of the selected tab, outside the tab's own width.</summary>
    public static double Flare => PaletteResources.Double("TabFlare");

    /// <summary>
    /// The joined geometry, in the coordinates of the element that draws it, or null when the sheet is empty.
    /// </summary>
    /// <param name="sheet">The sheet's rect; its top edge is the title bar's bottom edge.</param>
    /// <param name="tab">
    /// The selected tab's rect (flares excluded), standing on the sheet's top edge; its bottom is taken as the sheet's
    /// top. Left out when null or when the tab and its flares do not fit on the sheet's straight top edge.
    /// </param>
    /// <param name="joinedLeft">The tab is a vertical row beside the sheet's left edge (its right is taken as the
    /// sheet's left), left out when it and its flares do not fit on that edge's straight part.</param>
    public static Geometry? Create(Rect sheet, Rect? tab, bool joinedLeft = false)
    {
        if (sheet.Width <= 0 || sheet.Height <= 0)
            return null;

        double tabRadius = TabRadius;
        double flare = Flare;
        double left = sheet.X;
        double top = sheet.Y;
        double right = sheet.X + sheet.Width;
        double bottom = sheet.Y + sheet.Height;
        double radius = Math.Min(SheetRadius, Math.Min(sheet.Width, sheet.Height) / 2);

        // Traced clockwise (y down): the sheet corners and the tab's top corners turn clockwise, the flares counter.
        var figure = new PathFigure { StartPoint = new Point(left, top + radius), IsClosed = true, IsFilled = true };
        figure.Segments.Add(Arc(left + radius, top, radius, SweepDirection.Clockwise));

        if (!joinedLeft && tab is { } t && Fits(t, left + radius, right - radius, top, tabRadius, flare))
            AddTab(figure, t.X, t.X + t.Width, t.Y, top, tabRadius, flare);

        figure.Segments.Add(Line(right - radius, top));
        figure.Segments.Add(Arc(right, top + radius, radius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(right, bottom - radius));
        figure.Segments.Add(Arc(right - radius, bottom, radius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(left + radius, bottom));
        figure.Segments.Add(Arc(left, bottom - radius, radius, SweepDirection.Clockwise));

        // Up the left edge: the row's part, then the figure closes back to the top-left corner.
        if (joinedLeft && tab is { } row && FitsLeft(row, top + radius, bottom - radius, left, flare))
            AddRow(figure, row.X, row.Y, row.Y + row.Height, left, row.Height / 2, flare);

        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    /// <summary>
    /// The selected vertical row's outline without its trailing edge (the vertical <see cref="Outline"/>): from the end
    /// of the lower flare on the sheet's edge, round the leading side, to the end of the upper flare, inset half of
    /// <paramref name="thickness"/> on the row's top, bottom and leading side.
    /// </summary>
    /// <param name="row">The row's rect, flares excluded; its right is the sheet's left edge.</param>
    public static Geometry LeftOutline(Rect row, double thickness)
    {
        double flare = Flare;
        double edge = row.X + row.Width;
        double top = row.Y + thickness / 2;
        double bottom = row.Y + row.Height - thickness / 2;
        var figure = new PathFigure { StartPoint = new Point(edge, bottom + flare), IsClosed = false, IsFilled = false };
        AddRow(figure, row.X + thickness / 2, top, bottom, edge, row.Height / 2 - thickness / 2, flare);
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    /// <summary>
    /// The selected tab's outline without its bottom edge (TabSheetShape with <c>closed: false</c>): from the end of the
    /// left flare up, over the top and down to the end of the right flare, inset half of <paramref name="thickness"/>
    /// top and bottom so its stroke meets a line of that thickness along the row's bottom.
    /// </summary>
    /// <param name="tab">The tab's rect, flares excluded; its bottom is the row's bottom.</param>
    public static Geometry Outline(Rect tab, double thickness)
    {
        double tabRadius = TabRadius;
        double flare = Flare;
        double top = tab.Y + thickness / 2;
        double bottom = tab.Y + tab.Height - thickness / 2;
        var figure = new PathFigure { StartPoint = new Point(tab.X - flare, bottom), IsClosed = false, IsFilled = false };
        AddTab(figure, tab.X, tab.X + tab.Width, top, bottom, tabRadius, flare);
        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    /// <summary>
    /// A rounded rect (a capsule when <paramref name="radius"/> reaches half its height), or only its 1 epx inner edge,
    /// with the selected tab's shape (flares included, down to <paramref name="hole"/>'s bottom) cut out of it when the
    /// two meet. Null when the rect is empty or the hole covers all of it.
    /// </summary>
    /// <param name="joinedLeft">The hole is a vertical row joined on its right (flares above and below its trailing
    /// end), as <see cref="Create"/> draws it with the tabs on the left.</param>
    public static Geometry? Box(Rect box, double radius, bool edgeOnly, Rect? hole, bool joinedLeft = false)
    {
        if (box.Width <= 0 || box.Height <= 0)
            return null;
        double corner = Math.Min(radius, Math.Min(box.Width, box.Height) / 2);
        double flare = Flare;
        double alongFlare = joinedLeft ? 0 : flare;
        double acrossFlare = joinedLeft ? flare : 0;
        if (hole is not { } tab || !(tab.X - alongFlare < box.X + box.Width && tab.X + tab.Width + alongFlare > box.X
            && tab.Y - acrossFlare < box.Y + box.Height && tab.Y + tab.Height + acrossFlare > box.Y))
            return Uncut(box, corner, edgeOnly);

        // Drawn while laying out and on every selection slide frame, where an exception would end the app: should the
        // Win2D interop fail, the box is drawn whole (the selected tab then sits on its fill) and the failure is logged.
        try
        {
            return CutOut(box, corner, edgeOnly, tab, joinedLeft);
        }
        catch (Exception error)
        {
            CrashLog.Recovered("SheetTabShape.Box cut-out (box drawn without it)", error);
            return Uncut(box, corner, edgeOnly);
        }
    }

    /// <summary>The box, or its 1 epx inner edge, whole.</summary>
    private static Geometry Uncut(Rect box, double corner, bool edgeOnly)
    {
        if (!edgeOnly || box.Width <= 2 || box.Height <= 2)
            return RoundedRect(box, corner);
        // The inner rect lies wholly inside the outer one, so even-odd leaves the 1 epx ring.
        var ring = new GeometryGroup { FillRule = FillRule.EvenOdd };
        ring.Children.Add(RoundedRect(box, corner));
        ring.Children.Add(RoundedRect(
            new Rect(box.X + 1, box.Y + 1, box.Width - 2, box.Height - 2), Math.Max(corner - 1, 0)));
        return ring;
    }

    /// <summary>The box, or its 1 epx inner edge, with the selected tab's shape cut out: Win2D does the boolean work
    /// (XAML geometry has none) and its outline comes back as a XAML path.</summary>
    private static Geometry CutOut(Rect box, double corner, bool edgeOnly, Rect tab, bool joinedLeft)
    {
        CanvasDevice device = CanvasDevice.GetSharedDevice();
        CanvasGeometry shape = CanvasGeometry.CreateRoundedRectangle(
            device, (float)box.X, (float)box.Y, (float)box.Width, (float)box.Height, (float)corner, (float)corner);
        try
        {
            if (edgeOnly && box.Width > 2 && box.Height > 2)
            {
                using CanvasGeometry inner = CanvasGeometry.CreateRoundedRectangle(
                    device, (float)box.X + 1, (float)box.Y + 1, (float)box.Width - 2, (float)box.Height - 2,
                    (float)Math.Max(corner - 1, 0), (float)Math.Max(corner - 1, 0));
                CanvasGeometry ring = shape.CombineWith(inner, Matrix3x2.Identity, CanvasGeometryCombine.Exclude);
                shape.Dispose();
                shape = ring;
            }

            using (CanvasGeometry tabShape = joinedLeft ? RowShape(device, tab) : TabShape(device, tab))
            {
                CanvasGeometry rest = shape.CombineWith(tabShape, Matrix3x2.Identity, CanvasGeometryCombine.Exclude);
                shape.Dispose();
                shape = rest;
            }

            var receiver = new XamlPathReceiver();
            shape.SendPathTo(receiver);
            return receiver.Geometry;
        }
        finally
        {
            shape.Dispose();
        }
    }

    /// <summary>A rounded rect, its corners at most half its shorter side.</summary>
    public static Geometry RoundedRect(Rect box, double radius)
    {
        double corner = Math.Max(0, Math.Min(radius, Math.Min(box.Width, box.Height) / 2));
        // RectangleGeometry has no corner radius in WinUI: a path with arcs instead.
        if (corner <= 0 || box.Width <= 0 || box.Height <= 0)
            return new RectangleGeometry { Rect = box };
        double left = box.X;
        double top = box.Y;
        double right = box.X + box.Width;
        double bottom = box.Y + box.Height;
        var figure = new PathFigure { StartPoint = new Point(left, top + corner), IsClosed = true, IsFilled = true };
        figure.Segments.Add(Arc(left + corner, top, corner, SweepDirection.Clockwise));
        figure.Segments.Add(Line(right - corner, top));
        figure.Segments.Add(Arc(right, top + corner, corner, SweepDirection.Clockwise));
        figure.Segments.Add(Line(right, bottom - corner));
        figure.Segments.Add(Arc(right - corner, bottom, corner, SweepDirection.Clockwise));
        figure.Segments.Add(Line(left + corner, bottom));
        figure.Segments.Add(Arc(left, bottom - corner, corner, SweepDirection.Clockwise));
        var path = new PathGeometry();
        path.Figures.Add(figure);
        return path;
    }

    /// <summary>The tab's part of a figure: from its left flare's start (the current point) to its right flare's end
    /// on <paramref name="baseline"/>, its top at <paramref name="tabTop"/>.</summary>
    private static void AddTab(
        PathFigure figure, double tabLeft, double tabRight, double tabTop, double baseline, double tabRadius,
        double flare)
    {
        figure.Segments.Add(Line(tabLeft - flare, baseline));
        figure.Segments.Add(Arc(tabLeft, baseline - flare, flare, SweepDirection.Counterclockwise));
        figure.Segments.Add(Line(tabLeft, tabTop + tabRadius));
        figure.Segments.Add(Arc(tabLeft + tabRadius, tabTop, tabRadius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(tabRight - tabRadius, tabTop));
        figure.Segments.Add(Arc(tabRight, tabTop + tabRadius, tabRadius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(tabRight, baseline - flare));
        figure.Segments.Add(Arc(tabRight + flare, baseline, flare, SweepDirection.Counterclockwise));
    }

    /// <summary>A vertical row's part of a figure going up the sheet's left edge <paramref name="edge"/>: from its lower
    /// flare's start (the current point, below the row on the edge) round its leading side to its upper flare's end on
    /// the edge, its leading corners rounded by <paramref name="rowRadius"/>.</summary>
    private static void AddRow(
        PathFigure figure, double rowLeft, double rowTop, double rowBottom, double edge, double rowRadius, double flare)
    {
        figure.Segments.Add(Line(edge, rowBottom + flare));
        figure.Segments.Add(Arc(edge - flare, rowBottom, flare, SweepDirection.Counterclockwise));
        figure.Segments.Add(Line(rowLeft + rowRadius, rowBottom));
        figure.Segments.Add(Arc(rowLeft, rowBottom - rowRadius, rowRadius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(rowLeft, rowTop + rowRadius));
        figure.Segments.Add(Arc(rowLeft + rowRadius, rowTop, rowRadius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(edge - flare, rowTop));
        figure.Segments.Add(Arc(edge, rowTop - flare, flare, SweepDirection.Counterclockwise));
    }

    /// <summary>The selected vertical row's closed shape, flares included, as a Win2D geometry (the hole cut out of a
    /// box with the tabs on the left).</summary>
    private static CanvasGeometry RowShape(CanvasDevice device, Rect row)
    {
        float flare = (float)Flare;
        float radius = (float)(row.Height / 2);
        float left = (float)row.X;
        float edge = (float)(row.X + row.Width);
        float top = (float)row.Y;
        float bottom = (float)(row.Y + row.Height);
        using var builder = new CanvasPathBuilder(device);
        builder.BeginFigure(edge, bottom + flare);
        builder.AddArc(new Vector2(edge - flare, bottom), flare, flare, 0, CanvasSweepDirection.CounterClockwise,
            CanvasArcSize.Small);
        builder.AddLine(left + radius, bottom);
        builder.AddArc(new Vector2(left, bottom - radius), radius, radius, 0, CanvasSweepDirection.Clockwise,
            CanvasArcSize.Small);
        builder.AddLine(left, top + radius);
        builder.AddArc(new Vector2(left + radius, top), radius, radius, 0, CanvasSweepDirection.Clockwise,
            CanvasArcSize.Small);
        builder.AddLine(edge - flare, top);
        builder.AddArc(new Vector2(edge, top - flare), flare, flare, 0, CanvasSweepDirection.CounterClockwise,
            CanvasArcSize.Small);
        builder.EndFigure(CanvasFigureLoop.Closed);
        return CanvasGeometry.CreatePath(builder);
    }

    /// <summary>The selected tab's closed shape, flares included, as a Win2D geometry (the hole cut out of a box).</summary>
    private static CanvasGeometry TabShape(CanvasDevice device, Rect tab)
    {
        float tabRadius = (float)TabRadius;
        float flare = (float)Flare;
        float left = (float)tab.X;
        float right = (float)(tab.X + tab.Width);
        float top = (float)tab.Y;
        float bottom = (float)(tab.Y + tab.Height);
        using var builder = new CanvasPathBuilder(device);
        builder.BeginFigure(left - flare, bottom);
        builder.AddArc(new Vector2(left, bottom - flare), flare, flare, 0, CanvasSweepDirection.CounterClockwise,
            CanvasArcSize.Small);
        builder.AddLine(left, top + tabRadius);
        builder.AddArc(new Vector2(left + tabRadius, top), tabRadius, tabRadius, 0, CanvasSweepDirection.Clockwise,
            CanvasArcSize.Small);
        builder.AddLine(right - tabRadius, top);
        builder.AddArc(new Vector2(right, top + tabRadius), tabRadius, tabRadius, 0, CanvasSweepDirection.Clockwise,
            CanvasArcSize.Small);
        builder.AddLine(right, bottom - flare);
        builder.AddArc(new Vector2(right + flare, bottom), flare, flare, 0, CanvasSweepDirection.CounterClockwise,
            CanvasArcSize.Small);
        builder.EndFigure(CanvasFigureLoop.Closed);
        return CanvasGeometry.CreatePath(builder);
    }

    /// <summary>
    /// True when the tab, flares included, lies on the straight part of the sheet's top edge and is tall and wide
    /// enough for its corners.
    /// </summary>
    private static bool Fits(Rect tab, double edgeLeft, double edgeRight, double sheetTop, double tabRadius, double flare) =>
        tab.Width >= 2 * tabRadius
        && sheetTop - tab.Y >= tabRadius + flare
        && tab.X - flare >= edgeLeft
        && tab.X + tab.Width + flare <= edgeRight;

    /// <summary>
    /// True when the row, flares included, lies on the straight part of the sheet's left edge (from
    /// <paramref name="edgeTop"/> to <paramref name="edgeBottom"/>), its right on the edge, and is wide enough for its
    /// leading corners and flares.
    /// </summary>
    private static bool FitsLeft(Rect row, double edgeTop, double edgeBottom, double sheetLeft, double flare) =>
        row.Height > 0
        && Math.Abs(row.X + row.Width - sheetLeft) < 0.5
        && row.Width >= row.Height / 2 + flare
        && row.Y - flare >= edgeTop
        && row.Y + row.Height + flare <= edgeBottom;

    private static LineSegment Line(double x, double y) => new() { Point = new Point(x, y) };

    private static ArcSegment Arc(double x, double y, double radius, SweepDirection direction) => new()
    {
        Point = new Point(x, y),
        Size = new Size(radius, radius),
        SweepDirection = direction,
        IsLargeArc = false,
    };
}

/// <summary>Turns a Win2D geometry's outline (<see cref="CanvasGeometry.SendPathTo"/>) into a XAML path.</summary>
internal sealed partial class XamlPathReceiver : ICanvasPathReceiver
{
    private readonly PathGeometry _geometry = new();
    private PathFigure? _figure;

    public Geometry Geometry => _geometry;

    public void BeginFigure(Vector2 startPoint, CanvasFigureFill figureFill)
    {
        _figure = new PathFigure { StartPoint = ToPoint(startPoint), IsFilled = true };
        _geometry.Figures.Add(_figure);
    }

    public void AddArc(
        Vector2 endPoint, float radiusX, float radiusY, float rotationAngle, CanvasSweepDirection sweepDirection,
        CanvasArcSize arcSize) =>
        _figure?.Segments.Add(new ArcSegment
        {
            Point = ToPoint(endPoint),
            Size = new Size(radiusX, radiusY),
            RotationAngle = rotationAngle * 180 / Math.PI,
            SweepDirection = sweepDirection == CanvasSweepDirection.Clockwise
                ? SweepDirection.Clockwise
                : SweepDirection.Counterclockwise,
            IsLargeArc = arcSize == CanvasArcSize.Large,
        });

    public void AddCubicBezier(Vector2 controlPoint1, Vector2 controlPoint2, Vector2 endPoint) =>
        _figure?.Segments.Add(new BezierSegment
        {
            Point1 = ToPoint(controlPoint1),
            Point2 = ToPoint(controlPoint2),
            Point3 = ToPoint(endPoint),
        });

    public void AddLine(Vector2 endPoint) => _figure?.Segments.Add(new LineSegment { Point = ToPoint(endPoint) });

    public void AddQuadraticBezier(Vector2 controlPoint, Vector2 endPoint) =>
        _figure?.Segments.Add(new QuadraticBezierSegment { Point1 = ToPoint(controlPoint), Point2 = ToPoint(endPoint) });

    public void SetFilledRegionDetermination(CanvasFilledRegionDetermination filledRegionDetermination) =>
        _geometry.FillRule = filledRegionDetermination == CanvasFilledRegionDetermination.Winding
            ? FillRule.Nonzero
            : FillRule.EvenOdd;

    public void SetSegmentOptions(CanvasFigureSegmentOptions figureSegmentOptions)
    {
    }

    public void EndFigure(CanvasFigureLoop figureLoop)
    {
        if (_figure is not null)
            _figure.IsClosed = figureLoop == CanvasFigureLoop.Closed;
        _figure = null;
    }

    private static Point ToPoint(Vector2 point) => new(point.X, point.Y);
}

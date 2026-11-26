using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Histq.App.Shell;

/// <summary>
/// The page sheet and the selected tab joined to it as ONE closed figure (design header-and-tab-row.md §1.2, §3.2;
/// ported from TabSheetShape, App/Window/TabStrip.swift): the tab's top corners are rounded by half its height, and
/// at each bottom corner a concave flare runs out into the sheet's straight top edge. One filled figure has no inner
/// edge, so no seam can show between the tab and the sheet at any scale.
/// </summary>
internal static class SheetTabShape
{
    /// <summary>The sheet's inset from the window's left, right and bottom edges.</summary>
    public const double SheetInset = 8;

    /// <summary>The sheet's outer corner radius.</summary>
    public const double SheetRadius = 22;

    /// <summary>The selected tab's top corner radius (half the 36 epx tab height).</summary>
    public const double TabRadius = 18;

    /// <summary>The concave flare at each bottom corner of the selected tab, outside the tab's own width.</summary>
    public const double Flare = 9;

    /// <summary>
    /// The joined geometry, in the coordinates of the element that draws it, or null when the sheet is empty.
    /// </summary>
    /// <param name="sheet">The sheet's rect; its top edge is the title bar's bottom edge.</param>
    /// <param name="tab">
    /// The selected tab's rect (flares excluded), standing on the sheet's top edge; its bottom is taken as the sheet's
    /// top. Left out when null or when the tab and its flares do not fit on the sheet's straight top edge.
    /// </param>
    public static Geometry? Create(Rect sheet, Rect? tab)
    {
        if (sheet.Width <= 0 || sheet.Height <= 0)
            return null;

        double left = sheet.X;
        double top = sheet.Y;
        double right = sheet.X + sheet.Width;
        double bottom = sheet.Y + sheet.Height;
        double radius = Math.Min(SheetRadius, Math.Min(sheet.Width, sheet.Height) / 2);

        // Traced clockwise (y down): the sheet corners and the tab's top corners turn clockwise, the flares counter.
        var figure = new PathFigure { StartPoint = new Point(left, top + radius), IsClosed = true, IsFilled = true };
        figure.Segments.Add(Arc(left + radius, top, radius, SweepDirection.Clockwise));

        if (tab is { } t && Fits(t, left + radius, right - radius, top))
        {
            double tabLeft = t.X;
            double tabRight = t.X + t.Width;
            double tabTop = t.Y;
            figure.Segments.Add(Line(tabLeft - Flare, top));
            figure.Segments.Add(Arc(tabLeft, top - Flare, Flare, SweepDirection.Counterclockwise));
            figure.Segments.Add(Line(tabLeft, tabTop + TabRadius));
            figure.Segments.Add(Arc(tabLeft + TabRadius, tabTop, TabRadius, SweepDirection.Clockwise));
            figure.Segments.Add(Line(tabRight - TabRadius, tabTop));
            figure.Segments.Add(Arc(tabRight, tabTop + TabRadius, TabRadius, SweepDirection.Clockwise));
            figure.Segments.Add(Line(tabRight, top - Flare));
            figure.Segments.Add(Arc(tabRight + Flare, top, Flare, SweepDirection.Counterclockwise));
        }

        figure.Segments.Add(Line(right - radius, top));
        figure.Segments.Add(Arc(right, top + radius, radius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(right, bottom - radius));
        figure.Segments.Add(Arc(right - radius, bottom, radius, SweepDirection.Clockwise));
        figure.Segments.Add(Line(left + radius, bottom));
        figure.Segments.Add(Arc(left, bottom - radius, radius, SweepDirection.Clockwise));

        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    /// <summary>
    /// True when the tab, flares included, lies on the straight part of the sheet's top edge and is tall and wide
    /// enough for its corners.
    /// </summary>
    private static bool Fits(Rect tab, double edgeLeft, double edgeRight, double sheetTop) =>
        tab.Width >= 2 * TabRadius
        && sheetTop - tab.Y >= TabRadius + Flare
        && tab.X - Flare >= edgeLeft
        && tab.X + tab.Width + Flare <= edgeRight;

    private static LineSegment Line(double x, double y) => new() { Point = new Point(x, y) };

    private static ArcSegment Arc(double x, double y, double radius, SweepDirection direction) => new()
    {
        Point = new Point(x, y),
        Size = new Size(radius, radius),
        SweepDirection = direction,
        IsLargeArc = false,
    };
}

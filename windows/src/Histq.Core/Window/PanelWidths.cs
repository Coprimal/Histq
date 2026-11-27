// The repo layout's sizes and its side panels' widths (ported from RepoLayoutMetrics and PanelWidths, App/Repo/
// RepoLayoutView.swift at 6fa6d40, the Classic layout's part): the sidebar and the detail have a width range, the
// commit graph between them takes what they leave and keeps a minimum; the two widths are stored as "sidebar,detail" in
// PrefKey.PanelWidths.
using System.Globalization;

namespace Histq.Core;

/// <summary>Sizes of the repo layout, in epx. The middle panel (the commit graph) takes what the side panels leave.</summary>
public static class RepoLayoutMetrics
{
    /// <summary>Between two panels: the divider's grab area.</summary>
    public const double Gap = 8;

    public const double SidebarMin = 200;
    public const double SidebarMax = 420;
    public const double DetailMin = 320;
    public const double DetailMax = 640;
    public const double GraphMin = 360;

    /// <summary>The sidebar's default keeps its tab picker's titles beside the icons.</summary>
    public static PanelWidths Defaults { get; } = new(252, 360);
}

/// <summary>The side panels' widths, stored as "sidebar,detail" in <see cref="PrefKey.PanelWidths"/>.</summary>
public readonly record struct PanelWidths(double Sidebar, double Detail)
{
    /// <summary>
    /// Decodes the stored value: its comma-separated parts that read as finite numbers (others are skipped, as the Mac's
    /// compactMap does) must be exactly two; else (empty, malformed) <see cref="RepoLayoutMetrics.Defaults"/>.
    /// </summary>
    public static PanelWidths Decode(string? encoded)
    {
        var values = new List<double>(2);
        foreach (var part in (encoded ?? "").Split(','))
        {
            if (double.TryParse(part, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                && double.IsFinite(value))
            {
                values.Add(value);
            }
        }

        return values.Count == 2 ? new PanelWidths(values[0], values[1]) : RepoLayoutMetrics.Defaults;
    }

    /// <summary>"sidebar,detail", each rounded to a whole number (halves away from zero, as Swift's rounded()).</summary>
    public string Encoded => string.Create(
        CultureInfo.InvariantCulture,
        $"{(long)Math.Round(Sidebar, MidpointRounding.AwayFromZero)},{(long)Math.Round(Detail, MidpointRounding.AwayFromZero)}");

    /// <summary>
    /// Clamped to their ranges, then fitted in <paramref name="available"/> (the width of the three panels) so the graph
    /// keeps <see cref="RepoLayoutMetrics.GraphMin"/>: the side panels give up their width above their minimums in
    /// proportion to it. Below the sum of the minimums (a screen smaller than the window's minimum), all three shrink in
    /// proportion to them.
    /// </summary>
    public PanelWidths Fitted(double available)
    {
        var sidebar = ClampSidebar(Sidebar);
        var detail = ClampDetail(Detail);
        var overflow = sidebar + detail + RepoLayoutMetrics.GraphMin - available;
        if (!(overflow > 0))
        {
            return new PanelWidths(sidebar, detail);
        }

        var sidebarSpare = sidebar - RepoLayoutMetrics.SidebarMin;
        var detailSpare = detail - RepoLayoutMetrics.DetailMin;
        var spare = sidebarSpare + detailSpare;
        if (overflow <= spare)
        {
            return new PanelWidths(sidebar - overflow * sidebarSpare / spare, detail - overflow * detailSpare / spare);
        }

        var minimums = RepoLayoutMetrics.SidebarMin + RepoLayoutMetrics.DetailMin + RepoLayoutMetrics.GraphMin;
        var scale = Math.Max(available, 0) / minimums;
        return new PanelWidths(RepoLayoutMetrics.SidebarMin * scale, RepoLayoutMetrics.DetailMin * scale);
    }

    /// <summary>
    /// The widths while the divider after the sidebar is dragged <paramref name="dx"/> epx (right is positive) from
    /// these widths (the ones shown when the drag began): the sidebar grows by it, at most to what leaves the detail and
    /// the graph's minimum in <paramref name="available"/>, within its range.
    /// </summary>
    public PanelWidths DraggingSidebar(double dx, double available)
    {
        var limit = available - Detail - RepoLayoutMetrics.GraphMin;
        return this with { Sidebar = ClampSidebar(Math.Min(Sidebar + dx, limit)) };
    }

    /// <summary>As <see cref="DraggingSidebar"/>, for the divider before the detail: the detail grows as it moves left.</summary>
    public PanelWidths DraggingDetail(double dx, double available)
    {
        var limit = available - Sidebar - RepoLayoutMetrics.GraphMin;
        return this with { Detail = ClampDetail(Math.Min(Detail - dx, limit)) };
    }

    private static double ClampSidebar(double width) =>
        Math.Clamp(width, RepoLayoutMetrics.SidebarMin, RepoLayoutMetrics.SidebarMax);

    private static double ClampDetail(double width) =>
        Math.Clamp(width, RepoLayoutMetrics.DetailMin, RepoLayoutMetrics.DetailMax);
}

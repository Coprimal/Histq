using System.Globalization;
using Histq.Core;

namespace Histq.App.Graph;

/// <summary>The graph's columns, left to right (GraphColumn in App/Graph/GraphView.swift at 6fa6d40).</summary>
internal enum GraphColumn
{
    Refs,
    Graph,
    Message,
    Author,
    Date,
}

/// <summary>
/// The columns' names, titles and widths (GraphColumn in App/Graph/GraphView.swift at 6fa6d40). Widths are resizable
/// and saved in the graphColumnWidths preference (<c>"refs:150,graph:142,…"</c>); the message column takes what the
/// others leave. The message, author and date columns can be hidden (graphShowMessage, graphShowAuthor, graphShowDate).
/// </summary>
internal static class GraphColumns
{
    public static IReadOnlyList<GraphColumn> All { get; } =
        [GraphColumn.Refs, GraphColumn.Graph, GraphColumn.Message, GraphColumn.Author, GraphColumn.Date];

    /// <summary>The stored name (the Mac's raw value), also the column header's UI Automation name.</summary>
    public static string Key(GraphColumn column) => column switch
    {
        GraphColumn.Refs => "refs",
        GraphColumn.Graph => "graph",
        GraphColumn.Message => "message",
        GraphColumn.Author => "author",
        _ => "date",
    };

    public static string Title(GraphColumn column) => column switch
    {
        GraphColumn.Refs => "Branch / Tag",
        GraphColumn.Graph => "Graph",
        GraphColumn.Message => "Commit message",
        GraphColumn.Author => "Author",
        _ => "Time",
    };

    /// <summary>The header menu's toggle of a column that can be hidden (the Mac's palette names).</summary>
    public static string MenuTitle(GraphColumn column) => column switch
    {
        GraphColumn.Message => "Commit Message Column",
        GraphColumn.Author => "Author Column",
        _ => "Time Column",
    };

    public static bool CanHide(GraphColumn column) => column is GraphColumn.Message or GraphColumn.Author or GraphColumn.Date;

    public static double MinWidth(GraphColumn column) => column switch
    {
        GraphColumn.Refs => 40,
        GraphColumn.Graph => 32,
        GraphColumn.Message => 80,
        GraphColumn.Author => 40,
        _ => 60,
    };

    /// <summary>A column's width before the user drags it: a 20-character branch name, four lanes at the regular row
    /// density, "12/31/25 @ 23:00".</summary>
    public static double DefaultWidth(GraphColumn column) => column switch
    {
        GraphColumn.Refs => 150,
        GraphColumn.Graph => GraphMetrics.Regular.Width(4),
        GraphColumn.Message => 240,
        GraphColumn.Author => 76,
        _ => 120,
    };

    /// <summary>
    /// The widths of <paramref name="encoded"/> (the graphColumnWidths preference), each at least its column's minimum,
    /// and the default for every column it does not name; unknown or malformed entries are skipped.
    /// </summary>
    public static Dictionary<GraphColumn, double> Widths(string encoded)
    {
        var widths = All.ToDictionary(column => column, DefaultWidth);
        foreach (string entry in encoded.Split(','))
        {
            string[] parts = entry.Split(':');
            if (parts.Length != 2 || Parse(parts[0]) is not { } column
                || !double.TryParse(parts[1], NumberStyles.Float, CultureInfo.InvariantCulture, out double width)
                || !double.IsFinite(width))
            {
                continue;
            }

            widths[column] = Math.Max(MinWidth(column), width);
        }

        return widths;
    }

    private static GraphColumn? Parse(string key)
    {
        foreach (GraphColumn column in All)
        {
            if (string.Equals(Key(column), key, StringComparison.Ordinal))
                return column;
        }

        return null;
    }

    /// <summary>The graphColumnWidths preference for <paramref name="widths"/>: every column, whole epx.</summary>
    public static string Encode(IReadOnlyDictionary<GraphColumn, double> widths) =>
        string.Join(",", All.Select(column => string.Create(
            CultureInfo.InvariantCulture,
            $"{Key(column)}:{(int)Math.Round(widths.TryGetValue(column, out double width) ? width : DefaultWidth(column))}")));
}

/// <summary>The graph columns' preferences, kept by <see cref="Shell.WindowManager"/> for every graph.</summary>
/// <param name="EncodedWidths">graphColumnWidths: each column's own width (the message column's is ignored, it
/// fills; the graph column's is the one the user wants, which a log with fewer lanes narrows).</param>
internal sealed record GraphColumnSettings(string EncodedWidths, bool ShowMessage, bool ShowAuthor, bool ShowDate)
{
    public static GraphColumnSettings Read(Preferences preferences) => new(
        preferences.Get<string>(PrefKey.GraphColumnWidths),
        preferences.Get<bool>(PrefKey.GraphShowMessage),
        preferences.Get<bool>(PrefKey.GraphShowAuthor),
        preferences.Get<bool>(PrefKey.GraphShowDate));

    public bool IsShown(GraphColumn column) => column switch
    {
        GraphColumn.Message => ShowMessage,
        GraphColumn.Author => ShowAuthor,
        GraphColumn.Date => ShowDate,
        _ => true,
    };

    public GraphColumnSettings Showing(GraphColumn column, bool shown) => column switch
    {
        GraphColumn.Message => this with { ShowMessage = shown },
        GraphColumn.Author => this with { ShowAuthor = shown },
        GraphColumn.Date => this with { ShowDate = shown },
        _ => this,
    };
}

/// <summary>One column's place in the graph view, in epx from its left edge; a hidden column has no width.</summary>
internal readonly record struct GraphColumnSpan(double X, double Width)
{
    public bool IsShown => Width > 0;

    public double Right => X + Width;
}

/// <summary>
/// Where the columns are in a graph view of a given width (GraphTableView.tile and fitGraphColumn in
/// App/Graph/GraphView.swift at 6fa6d40): the shown columns left to right at their own widths, the fill column (the
/// message column, else the last shown one) taking what the others leave, at least its minimum. The graph column shows
/// its wanted width within the log's lanes: at least lane 0's node, at most every lane
/// (<see cref="GraphMetrics.Width"/>), unless it fills (every text column hidden).
/// </summary>
internal sealed record GraphColumnLayout(IReadOnlyList<GraphColumnSpan> Spans, GraphColumn Fill)
{
    public GraphColumnSpan this[GraphColumn column] => Spans[(int)column];

    /// <param name="width">The view's width.</param>
    /// <param name="widths">Each column's own width.</param>
    /// <param name="logLanes">The most lanes a row of the log draws in; 0 while unknown (no maximum then).</param>
    public static GraphColumnLayout Compute(
        double width, IReadOnlyDictionary<GraphColumn, double> widths, GraphColumnSettings settings, GraphMetrics metrics,
        int logLanes)
    {
        GraphColumn[] shown = GraphColumns.All.Where(settings.IsShown).ToArray();
        GraphColumn fill = settings.ShowMessage ? GraphColumn.Message : shown[^1];
        double Own(GraphColumn column) => column == GraphColumn.Graph
            ? GraphWidth(widths[GraphColumn.Graph], metrics, logLanes)
            : widths[column];

        double others = shown.Where(column => column != fill).Sum(Own);
        var spans = new GraphColumnSpan[GraphColumns.All.Count];
        double x = 0;
        foreach (GraphColumn column in shown)
        {
            double w = column == fill ? Math.Max(GraphColumns.MinWidth(column), width - others) : Own(column);
            spans[(int)column] = new GraphColumnSpan(x, w);
            x += w;
        }

        return new GraphColumnLayout(spans, fill);
    }

    /// <summary>The graph column's width for <paramref name="wanted"/>: within lane 0's node and every lane of the
    /// log (no maximum while <paramref name="logLanes"/> is 0).</summary>
    public static double GraphWidth(double wanted, GraphMetrics metrics, int logLanes)
    {
        double min = metrics.MinColumnWidth;
        double max = logLanes > 0 ? Math.Max(min, metrics.Width(logLanes)) : double.MaxValue;
        return Math.Clamp(wanted, min, max);
    }
}

/// <summary>
/// The text of the date column: the dateFormat preference (a Unicode pattern, <see cref="IcuDateFormat"/>) in the
/// user's culture, local time.
/// </summary>
internal sealed class GraphDateFormatter(string pattern)
{
    private readonly string _format = IcuDateFormat.ToDotNet(pattern);

    public string Format(DateTimeOffset date)
    {
        try
        {
            return date.ToLocalTime().ToString(_format, CultureInfo.CurrentCulture);
        }
        catch (FormatException)
        {
            return date.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
        }
        catch (ArgumentOutOfRangeException)
        {
            // A date the culture's calendar cannot show.
            return "";
        }
    }
}

/// <summary>
/// How the graphs look: the row density (rowDensity: "compact", "regular", "comfortable"), the lane colors (laneColors:
/// "gradient", else Vivid), the date format (dateFormat), whether other worktrees' commits fade
/// (graphFadeOtherWorktrees), the avatars (avatarMode) and the authors' emojis (authorEmojis, by identity). Read once at
/// launch (Windows has no Settings page for them yet, and the graph menu that sets an emoji comes in task 16.2).
/// </summary>
internal sealed record GraphLook(
    string RowDensity, bool Gradient, string DateFormat, bool FadeOtherWorktrees, string AvatarMode,
    IReadOnlyDictionary<string, string> AuthorEmojis)
{
    public static GraphLook Read(Preferences preferences) => new(
        preferences.Get<string>(PrefKey.RowDensity),
        RepoLoader.ColoringFrom(preferences.Get<string>(PrefKey.LaneColors)) == GraphLayout.Coloring.Column,
        preferences.Get<string>(PrefKey.DateFormat),
        preferences.Get<bool>(PrefKey.GraphFadeOtherWorktrees),
        preferences.Get<string>(PrefKey.AvatarMode),
        preferences.Get<Dictionary<string, string>>(PrefKey.AuthorEmojis));

    public GraphMetrics Metrics => GraphMetrics.For(RowDensity, Gradient);
}

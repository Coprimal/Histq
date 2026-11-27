// The rows of the tab row's All Tabs and archive lists, filtered by their search field (TabListPopover and
// ArchiveListPopover in App/Window/TabStrip.swift at 6fa6d40).
using System.Globalization;

namespace Histq.Core;

/// <summary>
/// The tab lists' search: a row matches when its title or its folder contains the query, ignoring case and diacritics
/// (the Mac's localizedStandardContains); a query of only spaces (or none) matches every row.
/// </summary>
public static class TabListSearch
{
    private const CompareOptions Loose = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace
        | CompareOptions.IgnoreKanaType | CompareOptions.IgnoreWidth;

    /// <summary>One row of the All Tabs list.</summary>
    public abstract record Row(string Title, string? Path)
    {
        /// <summary>A tab of the window (the popped-out archived tab included).</summary>
        public sealed record Open(WindowTabs.Tab Tab) : Row(Tab.Title, Tab.Path);

        /// <summary>A stowed archived tab, by its index in <see cref="WindowTabs.ArchivedTabs"/>.</summary>
        public sealed record Archived(int Index, SavedTab Entry) : Row(Entry.Title, Entry.Path);

        /// <summary>A closed group's tab, by its offset in the group.</summary>
        public sealed record Closed(SavedClosedTabGroup Group, int Index) : Row(Group.Tabs[Index].Title, Group.Tabs[Index].Path);
    }

    /// <summary>The All Tabs rows matching <paramref name="query"/>: the window's tabs, then the stowed archived tabs,
    /// then the closed groups' tabs, each in its own order.</summary>
    public static IReadOnlyList<Row> AllTabs(WindowTabs model, string? query)
    {
        IEnumerable<Row> rows = model.Tabs.Select(tab => (Row)new Row.Open(tab))
            .Concat(model.ArchivedTabs.Select((entry, index) => (Row)new Row.Archived(index, entry)))
            .Concat(model.ClosedGroups.SelectMany(group =>
                Enumerable.Range(0, group.Tabs.Count).Select(index => (Row)new Row.Closed(group, index))));
        return rows.Where(row => Matches(row.Title, row.Path, query)).ToList();
    }

    /// <summary>The stowed archived tabs matching <paramref name="query"/>, each with its index in
    /// <see cref="WindowTabs.ArchivedTabs"/>, most recently archived first.</summary>
    public static IReadOnlyList<(int Index, SavedTab Entry)> Archived(WindowTabs model, string? query) =>
        model.ArchivedTabs.Select((entry, index) => (index, entry))
            .Where(item => Matches(item.entry.Title, item.entry.Path, query)).ToList();

    /// <summary>Whether <paramref name="title"/> or <paramref name="path"/> contains the trimmed
    /// <paramref name="query"/>, ignoring case and diacritics; true for an empty one.</summary>
    public static bool Matches(string title, string? path, string? query)
    {
        string text = query?.Trim() ?? string.Empty;
        if (text.Length == 0)
            return true;
        CompareInfo compare = CultureInfo.InvariantCulture.CompareInfo;
        return compare.IndexOf(title, text, Loose) >= 0 || (path is not null && compare.IndexOf(path, text, Loose) >= 0);
    }
}

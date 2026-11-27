// The sidebar's sections as the user orders and hides them (ported from App/Sidebar/SidebarSections.swift at 6fa6d40;
// PrefKey.SidebarSectionOrder, PrefKey.HiddenSidebarSections): the Branches tab's cards (Submodules only in a repo that
// has some), the Tags card and the PRs tab's lists. A section moves only inside its tab; a tab with nothing left to
// show goes away, except Branches, which then says all its sections are hidden. Also the cards' filter (FileSearch.matches
// in App/Detail/FileListView.swift).
using System.Globalization;
using System.Text;
using Histq.Core;

namespace Histq.App.Sidebar;

/// <summary>A sidebar tab. The PRs tab comes with the hosting integrations (M8): its lists' ids are kept already.</summary>
internal enum SidebarTab
{
    Branches,
    Tags,
    Prs,
}

/// <summary>A sidebar section, by its id in the prefs (<see cref="SidebarSectionIds.Name"/>), in the default order.</summary>
internal enum SidebarSectionId
{
    Local,
    Remote,
    Worktrees,
    Submodules,
    Tags,
    Mine,
    ReviewRequested,
    AllOpen,
    Assigned,
}

internal static class SidebarSectionIds
{
    /// <summary>Every id, in the default order.</summary>
    public static IReadOnlyList<SidebarSectionId> All { get; } = Enum.GetValues<SidebarSectionId>();

    /// <summary>The id in the prefs, as on the Mac: <c>local</c>, <c>reviewRequested</c>.</summary>
    public static string Name(this SidebarSectionId id)
    {
        string name = id.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    public static SidebarTab Tab(this SidebarSectionId id) => id switch
    {
        SidebarSectionId.Local or SidebarSectionId.Remote or SidebarSectionId.Worktrees
            or SidebarSectionId.Submodules => SidebarTab.Branches,
        SidebarSectionId.Tags => SidebarTab.Tags,
        _ => SidebarTab.Prs,
    };

    /// <summary>The id named <paramref name="name"/> (spaces around it ignored); null for an unknown one.</summary>
    public static SidebarSectionId? Parse(string name)
    {
        string trimmed = name.Trim();
        foreach (SidebarSectionId id in All)
        {
            if (string.Equals(id.Name(), trimmed, StringComparison.Ordinal))
                return id;
        }

        return null;
    }
}

/// <summary>The visible sidebar sections in their order, parsed from the two prefs.</summary>
internal sealed class SidebarSections
{
    /// <summary>
    /// Unknown and repeated ids are dropped. An id missing from <paramref name="order"/> goes back after the nearest
    /// section that precedes it by default and is listed, else to the front.
    /// </summary>
    public SidebarSections(string order, string hidden)
    {
        var ids = new List<SidebarSectionId>();
        foreach (SidebarSectionId id in ParseList(order))
        {
            if (!ids.Contains(id))
                ids.Add(id);
        }

        IReadOnlyList<SidebarSectionId> defaults = SidebarSectionIds.All;
        for (int index = 0; index < defaults.Count; index++)
        {
            SidebarSectionId id = defaults[index];
            if (ids.Contains(id))
                continue;
            int before = -1;
            for (int earlier = index - 1; earlier >= 0 && before < 0; earlier--)
                before = ids.IndexOf(defaults[earlier]);
            ids.Insert(before + 1, id);
        }

        var hiddenIds = ParseList(hidden).ToHashSet();
        Visible = ids.Where(id => !hiddenIds.Contains(id)).ToList();
    }

    public IReadOnlyList<SidebarSectionId> Visible { get; }

    /// <summary>The sections as <paramref name="preferences"/> have them (read where the app reads its other prefs at
    /// launch, never on a UI thread that may wait on a write).</summary>
    public static SidebarSections Read(Preferences preferences) => new(
        preferences.Get<string>(PrefKey.SidebarSectionOrder), preferences.Get<string>(PrefKey.HiddenSidebarSections));

    /// <summary>The visible sections of <paramref name="tab"/>, in order.</summary>
    public IReadOnlyList<SidebarSectionId> Ids(SidebarTab tab) => Visible.Where(id => id.Tab() == tab).ToList();

    /// <summary>The tabs with a visible section, Branches always; the PRs tab not yet (M8).</summary>
    public IReadOnlyList<SidebarTab> Tabs =>
        [SidebarTab.Branches, .. Ids(SidebarTab.Tags).Count > 0 ? [SidebarTab.Tags] : Array.Empty<SidebarTab>()];

    /// <summary>The tab the sidebar shows for <paramref name="tab"/>: Branches when that one is hidden.</summary>
    public SidebarTab ShownTab(SidebarTab tab) => Tabs.Contains(tab) ? tab : SidebarTab.Branches;

    private static IEnumerable<SidebarSectionId> ParseList(string list) =>
        list.Split(',').Select(SidebarSectionIds.Parse).OfType<SidebarSectionId>();
}

/// <summary>
/// A sidebar card's filter (FileSearch.matches): a row matches when its text holds every word of the query, in any
/// order, case- and diacritic-insensitive, with spaces, "-", "_" and "/" alike.
/// </summary>
internal static class SidebarFilter
{
    /// <summary><paramref name="text"/> folded for <see cref="Matches"/>: lower case, no diacritics, each run of
    /// separators one space.</summary>
    public static string Fold(string text)
    {
        string lower = text.ToLowerInvariant();
        string decomposed;
        try
        {
            decomposed = lower.Normalize(NormalizationForm.FormD);
        }
        catch (ArgumentException)
        {
            // A lone surrogate (half an emoji) cannot be normalized.
            decomposed = lower;
        }

        var builder = new StringBuilder(decomposed.Length);
        bool separator = false;
        foreach (char character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) == UnicodeCategory.NonSpacingMark)
                continue;
            if (character is '-' or '_' or '/' || char.IsWhiteSpace(character))
            {
                separator = true;
                continue;
            }

            if (separator && builder.Length > 0)
                builder.Append(' ');
            separator = false;
            builder.Append(character);
        }

        return builder.ToString();
    }

    /// <summary>Whether <paramref name="folded"/> (a <see cref="Fold"/>ed text) holds every word of
    /// <paramref name="words"/> (the folded query split at spaces); true for no words.</summary>
    public static bool Matches(string folded, IReadOnlyList<string> words) =>
        words.All(word => folded.Contains(word, StringComparison.Ordinal));

    /// <summary>The words of <paramref name="query"/>, folded.</summary>
    public static string[] Words(string query) =>
        Fold(query).Split(' ', StringSplitOptions.RemoveEmptyEntries);
}

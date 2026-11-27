using System.Globalization;
using Histq.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI;

namespace Histq.App.Graph;

/// <summary>The kind of a <see cref="RefBadge"/>.</summary>
internal enum RefBadgeKind
{
    /// <summary>A local branch (laptop icon, with the cloud when its upstream is at the same commit) or a remote
    /// branch not merged into a local badge (cloud icon).</summary>
    Branch,
    Tag,

    /// <summary>A detached HEAD.</summary>
    Head,

    /// <summary>Another worktree's WIP row: the worktree's folder name.</summary>
    Worktree,
}

/// <summary>
/// One label in the Branch / Tag column (RefBadge in App/Graph/GraphCells.swift at 6fa6d40). Pull request chips, the
/// faded badge of a selected commit's branch and the remote owners' logos are not ported yet.
/// </summary>
/// <param name="Name">The full ref name (<c>origin/feature</c>), as git has it (raw).</param>
/// <param name="Label">The name drawn and read by UI Automation, sanitized: a remote branch without its remote when the
/// repo has one remote.</param>
/// <param name="IsOtherWorktree">A local branch checked out in another worktree: the worktree icon in front.</param>
/// <param name="IsLinkedWorktree">A local branch checked out in a linked worktree: the folder in place of the laptop.</param>
internal sealed record RefBadge(
    RefBadgeKind Kind, string Name, string Label, bool IsLocal = false, bool IsRemote = false, bool IsHead = false,
    int Ahead = 0, int Behind = 0, bool IsOtherWorktree = false, bool IsLinkedWorktree = false)
{
    /// <summary>
    /// The badges of every labeled commit, by commit hash, in row order: HEAD's branch (or a detached HEAD) first, then
    /// local branches, remote branches that are not merged into a local badge (a local branch whose upstream is at the
    /// same commit carries it as its cloud), then tags.
    /// </summary>
    /// <param name="otherWorktreeBranches">The full refs (<c>refs/heads/wt</c>) checked out in the other worktrees.</param>
    /// <param name="linkedWorktreeBranches">The full refs checked out in the linked worktrees (not the main one).</param>
    public static Dictionary<string, RefBadge[]> For(
        Refs refs, IReadOnlySet<string> otherWorktreeBranches, IReadOnlySet<string> linkedWorktreeBranches)
    {
        var byCommit = new Dictionary<string, List<RefBadge>>(StringComparer.Ordinal);
        void Add(string commit, RefBadge badge)
        {
            if (!byCommit.TryGetValue(commit, out List<RefBadge>? list))
                byCommit[commit] = list = [];
            list.Add(badge);
        }

        string? single = SingleRemote(refs);
        var remotes = new Dictionary<string, RemoteBranch>(StringComparer.Ordinal);
        foreach (RemoteBranch remote in refs.RemoteBranches)
            remotes.TryAdd(remote.Name, remote);
        var merged = new HashSet<string>(StringComparer.Ordinal);
        if (refs.Head is Head.Detached detached && detached.Commit is { } detachedCommit)
            Add(detachedCommit, new RefBadge(RefBadgeKind.Head, "HEAD", "HEAD", IsHead: true));

        foreach (LocalBranch branch in refs.LocalBranches.OrderBy(branch => branch.IsHead ? 0 : 1))
        {
            bool tracked = branch.Upstream is { } upstream && remotes.TryGetValue(upstream, out RemoteBranch? remote)
                && string.Equals(remote.Commit, branch.Commit, StringComparison.Ordinal);
            if (tracked)
                merged.Add(branch.Upstream!);
            Add(branch.Commit, new RefBadge(
                RefBadgeKind.Branch, branch.Name, DisplayText.Sanitize(branch.Name), IsLocal: true, IsRemote: tracked,
                IsHead: branch.IsHead, Ahead: branch.Ahead, Behind: branch.Behind,
                IsOtherWorktree: otherWorktreeBranches.Contains(branch.RefName),
                IsLinkedWorktree: linkedWorktreeBranches.Contains(branch.RefName)));
        }

        foreach (RemoteBranch remote in refs.RemoteBranches)
        {
            if (!merged.Contains(remote.Name))
            {
                Add(remote.Commit, new RefBadge(
                    RefBadgeKind.Branch, remote.Name, DisplayText.Sanitize(RemoteLabel(remote, single) ?? remote.Name),
                    IsRemote: true));
            }
        }

        foreach (TagRef tag in refs.Tags)
            Add(tag.Commit ?? tag.Target, new RefBadge(RefBadgeKind.Tag, tag.Name, DisplayText.Sanitize(tag.Name)));

        return byCommit.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray(), StringComparer.Ordinal);
    }

    /// <summary>Another worktree's WIP row's badge: its folder's name (raw, sanitized here).</summary>
    public static RefBadge ForWorktree(string name) =>
        new(RefBadgeKind.Worktree, name, DisplayText.Sanitize(name));

    /// <summary>The most badges <see cref="Describe"/> names; the others are counted.</summary>
    private const int MaxDescribed = 8;

    /// <summary>The badges in words for UI Automation: "main (HEAD, local, remote); origin/feature (remote); v1.0 (tag)",
    /// the first <see cref="MaxDescribed"/> only, then "+N more".</summary>
    public static string Describe(IReadOnlyList<RefBadge> badges) =>
        string.Join("; ", badges.Take(MaxDescribed).Select(badge => badge.Kind switch
        {
            RefBadgeKind.Tag => badge.Label + " (tag)",
            RefBadgeKind.Head => "HEAD (detached)",
            RefBadgeKind.Worktree => badge.Label + " (worktree)",
            _ => badge.Label + " (" + string.Join(", ", new[]
            {
                badge.IsHead ? "HEAD" : null,
                badge.IsLocal ? "local" : null,
                badge.IsRemote ? "remote" : null,
                badge.IsOtherWorktree ? "in another worktree" : null,
            }.OfType<string>()) + ")",
        }))
        + (badges.Count > MaxDescribed
            ? "; +" + (badges.Count - MaxDescribed).ToString(CultureInfo.InvariantCulture) + " more"
            : "");

    /// <summary>The repo's only remote, from its remote branches; null when it has several or none.</summary>
    private static string? SingleRemote(Refs refs)
    {
        string? single = null;
        foreach (RemoteBranch remote in refs.RemoteBranches)
        {
            if (single is null)
                single = remote.Remote;
            else if (!string.Equals(single, remote.Remote, StringComparison.Ordinal))
                return null;
        }

        return single;
    }

    /// <summary>A remote branch's text with a single remote: its name without the remote (<c>feature</c> for
    /// <c>origin/feature</c>, the cloud telling it is remote); null (the full name) otherwise.</summary>
    private static string? RemoteLabel(RemoteBranch branch, string? singleRemote)
    {
        if (singleRemote is null)
            return null;
        string prefix = singleRemote + "/";
        return branch.Name.StartsWith(prefix, StringComparison.Ordinal) && branch.Name.Length > prefix.Length
            ? branch.Name[prefix.Length..]
            : null;
    }
}

/// <summary>
/// Draws a row's badges in the Branch / Tag column with Win2D (RefBadgeCellView in App/Graph/GraphCells.swift at
/// 6fa6d40): from the left, as many as fit whole, then "+N" for the rest. When even the first does not fit whole it
/// steps down in the room "+N" leaves: its name cut with "…" (at least 3 characters), then its icons alone, then HEAD's
/// check alone. A badge's fill is its row's lane color (brighter for the checked-out branch), a tag's a neutral white;
/// its icons are Segoe Fluent glyphs (HEAD's check, the laptop, the cloud, the tag, the worktree folder), then ↑↓
/// counts. A line in the lane color runs from the last badge to the column's right edge, where the graph column
/// continues it to the node.
/// <para>
/// Text widths are measured once per text (a text layout on a miss, then the cache), so scrolling makes no text object
/// per row. Not ported yet: the hover stack of every badge, pull request chips, ghost badges, remote owner logos.
/// </para>
/// </summary>
internal sealed class RefBadgeRenderer : IDisposable
{
    private const float Leading = 6;
    private const float Padding = 7;
    private const float Gap = 4;
    private const float IconGap = 3;
    private const float RefIcon = 15;
    private const float HeadIcon = 16;
    private const float Radius = 5;
    private const float MaxHeight = 22;
    private const float Trailing = 8;

    /// <summary>The measured widths kept at most; the cache starts again past it.</summary>
    private const int MaxMeasured = 4096;

    // Segoe Fluent Icons: completed (solid), laptop, cloud, tag, folder.
    private const string IconFont = "Segoe Fluent Icons";
    private const string CheckGlyph = "\uEC61";
    private const string LaptopGlyph = "\uE7F8";
    private const string CloudGlyph = "\uE753";
    private const string TagGlyph = "\uE8EC";
    private const string WorktreeGlyph = "\uE8B7";

    private readonly CanvasTextFormat _name = Format("Segoe UI Variable Text", 11.5f);
    private readonly CanvasTextFormat _headName = Format("Segoe UI Variable Text", 12.5f);
    private readonly CanvasTextFormat _count = Format("Segoe UI Variable Text", 11f);
    private readonly CanvasTextFormat _chip = Format("Segoe UI Variable Text", 11f, centered: true);
    private readonly CanvasTextFormat _icon = Format(IconFont, 12f, centered: true);
    private readonly CanvasTextFormat _headIcon = Format(IconFont, 13.5f, centered: true);

    private readonly Dictionary<(string Text, CanvasTextFormat Format), float> _widths = [];

    /// <summary>Each badge's icons, counts and widths, by badge (a load makes new badges, so the cache starts again).</summary>
    private readonly Dictionary<RefBadge, Sized> _sized = new(ReferenceEqualityComparer.Instance);

    /// <summary>The "+N" chips' texts and widths, by N.</summary>
    private readonly Dictionary<int, (string Text, float Width)> _chips = [];

    /// <summary>How much of a badge is drawn.</summary>
    private enum Level
    {
        Full,
        Name,
        Icon,
        Check,
    }

    public void Dispose()
    {
        _name.Dispose();
        _headName.Dispose();
        _count.Dispose();
        _chip.Dispose();
        _icon.Dispose();
        _headIcon.Dispose();
    }

    /// <summary>
    /// Draws <paramref name="badges"/> (at least one) in the column from <paramref name="x"/>, <paramref name="width"/>
    /// wide, in the row whose top is <paramref name="top"/> and whose lane color is <paramref name="color"/>, at
    /// <paramref name="alpha"/> (another worktree's faded row), with the line to the column's right edge.
    /// </summary>
    public void Draw(
        CanvasDrawingSession ds, IReadOnlyList<RefBadge> badges, float x, float top, float width, int color,
        GraphMetrics metrics, float alpha)
    {
        float height = (float)Math.Min(MaxHeight, metrics.BandHeight);
        float y = top + (float)(metrics.RowHeight - height) / 2;
        float available = width - Leading - Trailing;
        bool head = HasHead(badges);

        // How many badges fit whole from the left, keeping room for "+N" when some are left out, at least one (as the
        // Mac's loop, which drops badges from the end down to the first): only the badges walked are sized, so a
        // commit with thousands of refs costs what fits.
        int shown = 0;
        float used = 0;
        while (shown < badges.Count)
        {
            float next = used + (shown > 0 ? Gap : 0) + Size(ds, badges[shown]).Full;
            int rest = badges.Count - shown - 1;
            if (next + (rest > 0 ? Gap + Chip(ds, rest).Width : 0) > available)
                break;
            used = next;
            shown++;
        }

        shown = Math.Max(1, shown);
        float left = x + Leading;
        bool showsChip = shown < badges.Count;
        bool drawn = true;
        if (shown > 1 || (shown == badges.Count && Size(ds, badges[0]).Full <= available))
        {
            for (int i = 0; i < shown; i++)
            {
                float full = Size(ds, badges[i]).Full;
                DrawBadge(ds, badges[i], Level.Full, left, y, full, height, color, metrics.Gradient, alpha);
                left += full + Gap;
            }
        }
        else
        {
            // Only the first badge, not whole: it steps down in the room "+N" leaves it; "+N" always stays. A lone
            // badge has no "+N".
            float chip = showsChip ? Chip(ds, badges.Count - 1).Width + Gap : 0;
            if (Fit(ds, badges[0], available - chip, height) is { } fit)
            {
                DrawBadge(ds, badges[0], fit.Level, left, y, fit.Width, height, color, metrics.Gradient, alpha);
                left += fit.Width + Gap;
                shown = 1;
            }
            else
            {
                // Not even its icons fit: "+N" counts it too, when there is a "+N"; else only the line is drawn.
                shown = 0;
                drawn = showsChip;
            }
        }

        if (showsChip)
        {
            (string text, float chipWidth) = Chip(ds, badges.Count - shown);
            if (left + chipWidth <= x + width)
            {
                ds.FillRoundedRectangle(left, y, chipWidth, height, Radius, Radius, GraphPalette.Faded(GraphPalette.TagFill, alpha));
                ds.DrawText(
                    text, new Windows.Foundation.Rect(left, y, chipWidth, height),
                    GraphPalette.Faded(GraphPalette.BadgeText, alpha), _chip);
                left += chipWidth + Gap;
            }
        }

        // The line to the node, full on the checked-out branch's row, thinner and fainter on the others.
        float lineStart = drawn ? left - Gap : x + Leading;
        float lineEnd = x + width;
        if (lineStart >= lineEnd)
            return;
        float mid = top + (float)metrics.RowHeight / 2;
        ds.DrawLine(
            lineStart, mid, lineEnd, mid,
            GraphPalette.Faded(GraphPalette.Lane(color, metrics.Gradient), alpha * RefsLineAlpha(head)),
            RefsLineWidth(head));
    }

    /// <summary>One of <paramref name="badges"/> is the checked-out branch or a detached HEAD.</summary>
    public static bool HasHead(IReadOnlyList<RefBadge> badges)
    {
        for (int i = 0; i < badges.Count; i++)
        {
            if (badges[i].IsHead)
                return true;
        }

        return false;
    }

    /// <summary>The line from a row's badges to its node: 1.5 epx on the checked-out branch's row, 1 on the others.</summary>
    public static float RefsLineWidth(bool head) => head ? 1.5f : 1f;

    public static float RefsLineAlpha(bool head) => head ? 1f : 0.7f;

    private static CanvasTextFormat Format(string family, float size, bool centered = false) => new()
    {
        FontFamily = family,
        FontSize = size,
        WordWrapping = CanvasWordWrapping.NoWrap,
        VerticalAlignment = CanvasVerticalAlignment.Center,
        HorizontalAlignment = centered ? CanvasHorizontalAlignment.Center : CanvasHorizontalAlignment.Left,
        TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
        TrimmingSign = CanvasTrimmingSign.Ellipsis,
    };

    /// <summary>The badge's icons before and after its name.</summary>
    private static (string[] Leading, string[] Trailing) Icons(RefBadge badge) => badge.Kind switch
    {
        RefBadgeKind.Tag => ([TagGlyph], []),
        RefBadgeKind.Head => ([CheckGlyph], []),
        RefBadgeKind.Worktree => ([WorktreeGlyph], []),
        _ => (
            new[] { badge.IsHead ? CheckGlyph : null, badge.IsOtherWorktree ? WorktreeGlyph : null }.OfType<string>().ToArray(),
            new[] { badge.IsLocal ? badge.IsLinkedWorktree ? WorktreeGlyph : LaptopGlyph : null, badge.IsRemote ? CloudGlyph : null }
                .OfType<string>().ToArray()),
    };

    private static float IconWidth(string glyph) => glyph == CheckGlyph ? HeadIcon : RefIcon;

    private static float IconsWidth(IReadOnlyList<string> glyphs) =>
        glyphs.Sum(IconWidth) + IconGap * Math.Max(0, glyphs.Count - 1);

    private static string? Counts(RefBadge badge)
    {
        if (badge.Ahead <= 0 && badge.Behind <= 0)
            return null;
        string ahead = badge.Ahead > 0 ? "↑" + badge.Ahead.ToString(CultureInfo.CurrentCulture) : "";
        string behind = badge.Behind > 0 ? "↓" + badge.Behind.ToString(CultureInfo.CurrentCulture) : "";
        return ahead.Length > 0 && behind.Length > 0 ? ahead + " " + behind : ahead + behind;
    }

    private CanvasTextFormat NameFormat(RefBadge badge) => badge.IsHead ? _headName : _name;

    /// <summary><paramref name="badge"/>'s icons, counts and widths, worked out once.</summary>
    private Sized Size(CanvasDrawingSession ds, RefBadge badge)
    {
        if (_sized.TryGetValue(badge, out Sized? sized))
            return sized;
        if (_sized.Count >= MaxMeasured)
            _sized.Clear();
        (string[] leading, string[] trailing) = Icons(badge);
        string? counts = Counts(badge);
        float countsWidth = counts is null ? 0 : IconGap + Measure(ds, counts, _count);
        // Padding, icons with their gaps, ↑↓.
        float chrome = 2 * Padding + leading.Concat(trailing).Sum(glyph => IconWidth(glyph) + IconGap) + countsWidth;
        sized = new Sized(leading, trailing, counts, countsWidth, chrome, Measure(ds, badge.Label, NameFormat(badge)));
        _sized[badge] = sized;
        return sized;
    }

    /// <summary>The "+N" chip's text and width for <paramref name="count"/> badges left out, made once per count.</summary>
    private (string Text, float Width) Chip(CanvasDrawingSession ds, int count)
    {
        if (_chips.TryGetValue(count, out (string Text, float Width) chip))
            return chip;
        if (_chips.Count >= MaxMeasured)
            _chips.Clear();
        chip = ("+" + count.ToString(CultureInfo.CurrentCulture), ChipWidth(ds, count));
        _chips[count] = chip;
        return chip;
    }

    private float ChipWidth(CanvasDrawingSession ds, int count) =>
        2 * Padding + Measure(ds, "+" + count.ToString(CultureInfo.CurrentCulture), _count);

    /// <summary>The badge's level and width in <paramref name="room"/>; null when not even its icons fit.</summary>
    private (Level Level, float Width)? Fit(CanvasDrawingSession ds, RefBadge badge, float room, float height)
    {
        Sized sized = Size(ds, badge);
        float chrome = sized.Chrome;
        float name = sized.Name;
        if (chrome + name <= room)
            return (Level.Full, chrome + name);
        // At least the first 3 characters and "…" (all of a shorter name).
        float least = badge.Label.Length > 3
            ? Math.Min(name, Measure(ds, badge.Label[..3] + "…", NameFormat(badge)) + 1)
            : name;
        if (chrome + least <= room)
            return (Level.Name, Math.Min(room, chrome + name));
        // As much room around the icons as a single one has in its square.
        float icons = IconsWidth([.. sized.Leading, .. sized.Trailing]) + height - RefIcon + sized.CountsWidth;
        if (icons <= room)
            return (Level.Icon, icons);
        float check = HeadIcon + height - RefIcon;
        return badge.IsHead && check <= room ? (Level.Check, check) : null;
    }

    private void DrawBadge(
        CanvasDrawingSession ds, RefBadge badge, Level level, float x, float y, float width, float height, int color,
        bool gradient, float alpha)
    {
        Color fill = badge.Kind == RefBadgeKind.Tag
            ? GraphPalette.TagFill
            : GraphPalette.BadgeFill(color, gradient, badge.IsHead);
        ds.FillRoundedRectangle(x, y, width, height, Radius, Radius, GraphPalette.Faded(fill, alpha));
        Color text = GraphPalette.Faded(GraphPalette.BadgeText, alpha);
        Sized sized = Size(ds, badge);
        (string[] leading, string[] trailing, string? counts) = (sized.Leading, sized.Trailing, sized.Counts);

        if (level is Level.Icon or Level.Check)
        {
            string[] glyphs = level == Level.Check ? [CheckGlyph] : [.. leading, .. trailing];
            float countsWidth = level == Level.Icon ? sized.CountsWidth : 0;
            float left = x + (width - IconsWidth(glyphs) - countsWidth) / 2;
            foreach (string glyph in glyphs)
            {
                DrawIcon(ds, glyph, left, y, height, text);
                left += IconWidth(glyph) + IconGap;
            }

            if (level == Level.Icon && counts is not null)
                ds.DrawText(counts, new Windows.Foundation.Rect(left, y, countsWidth, height), text, _count);
            return;
        }

        float start = x + Padding;
        foreach (string glyph in leading)
        {
            DrawIcon(ds, glyph, start, y, height, text);
            start += IconWidth(glyph) + IconGap;
        }

        float end = x + width - Padding;
        for (int i = trailing.Length - 1; i >= 0; i--)
        {
            end -= IconWidth(trailing[i]);
            DrawIcon(ds, trailing[i], end, y, height, text);
            end -= IconGap;
        }

        if (counts is not null)
        {
            float countWidth = sized.CountsWidth - IconGap;
            end -= countWidth;
            ds.DrawText(counts, new Windows.Foundation.Rect(end, y, countWidth + 1, height), text, _count);
            end -= IconGap;
        }

        if (end - start >= 1)
            ds.DrawText(badge.Label, new Windows.Foundation.Rect(start, y, end - start, height), text, NameFormat(badge));
    }

    private void DrawIcon(CanvasDrawingSession ds, string glyph, float x, float y, float height, Color color) =>
        ds.DrawText(
            glyph, new Windows.Foundation.Rect(x, y, IconWidth(glyph), height), color,
            glyph == CheckGlyph ? _headIcon : _icon);

    /// <summary>The width <paramref name="text"/> takes in <paramref name="format"/>, rounded up; measured once.</summary>
    private float Measure(CanvasDrawingSession ds, string text, CanvasTextFormat format)
    {
        if (_widths.TryGetValue((text, format), out float width))
            return width;
        if (_widths.Count >= MaxMeasured)
            _widths.Clear();
        using var layout = new CanvasTextLayout(ds, text, format, 100_000, 100);
        width = (float)Math.Ceiling(layout.LayoutBounds.Width);
        _widths[(text, format)] = width;
        return width;
    }

    /// <summary>A badge's icons before and after its name, its ↑↓ text and room (gap included), its width without
    /// its name, and its name's width.</summary>
    private sealed record Sized(
        string[] Leading, string[] Trailing, string? Counts, float CountsWidth, float Chrome, float Name)
    {
        public float Full => Chrome + Name;
    }
}

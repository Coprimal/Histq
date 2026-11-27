// What the graph leaves out and pins, resolved from the saved view (hidden, soloed and pinned branches, "hide stale
// branches") against the refs just read: the hidden and soloed refs become LogReader's arguments (`--exclude` per
// hidden ref, `<solo refs> HEAD` in solo mode, see `LogReader.ArgumentsFor`) and the pinned tips GraphLayout's pins.
// Ported from LogFilter and logFilter(view:refs:) in App/Repo/RepoSession.swift at 6fa6d40.
using System.Collections.Frozen;

namespace Histq.Core;

/// <summary>What the graph leaves out and pins, from a <see cref="RepoViewState"/> against the refs (<see cref="For"/>).</summary>
public sealed record LogFilter(
    IReadOnlySet<string>? Hidden = null, IReadOnlyList<string>? Solo = null, IReadOnlyList<string>? Pinned = null)
{
    /// <summary>Branches whose tip is older than this (its committer date) are stale.</summary>
    public static readonly TimeSpan StaleAge = TimeSpan.FromDays(90);

    public static LogFilter None { get; } = new();

    /// <summary>
    /// Full ref names left out of the graph (its log, its badges): the hidden branches and tags, the own upstreams of
    /// the hidden local branches and, with "hide stale branches" on, the stale branches. Never the current branch, nor
    /// its upstream unless hidden itself. Compared as a set.
    /// </summary>
    public IReadOnlySet<string> Hidden { get; init; } = Hidden ?? FrozenSet<string>.Empty;

    /// <summary>Full ref names: when any, the graph reads only them and HEAD.</summary>
    public IReadOnlyList<string> Solo { get; init; } = Solo ?? [];

    /// <summary>The pinned branches' tip hashes, in pin order, one each: <see cref="GraphLayout"/>'s pins.</summary>
    public IReadOnlyList<string> Pinned { get; init; } = Pinned ?? [];

    /// <summary>
    /// <paramref name="view"/> against <paramref name="refs"/>. Hidden: the hidden branches and tags that exist but the
    /// current branch, each hidden local branch's own upstream (<see cref="TracksOwnName"/>) and, with "hide stale
    /// branches" on, every local or remote branch whose tip is older than <see cref="StaleAge"/>; the last two never hide
    /// the current branch's upstream, and stale never a pinned branch. A tag is hidden only by hand. Solo: the soloed
    /// branches that exist; none on an unborn branch (git cannot read its HEAD). Pinned: the tips of the pinned branches
    /// that are shown (in solo mode only the soloed ones and the current branch), each tip once.
    /// </summary>
    /// <param name="now">The time stale is measured from; the current time when null.</param>
    public static LogFilter For(RepoViewState view, Refs refs, DateTimeOffset? now = null)
    {
        var remotes = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var remote in refs.RemoteBranches)
        {
            remotes.TryAdd(remote.Name, remote.RefName);
        }

        string? UpstreamOf(LocalBranch local) =>
            local.Upstream is { } upstream && remotes.TryGetValue(upstream, out var refName) ? refName : null;

        var head = refs.LocalBranches.FirstOrDefault(local => local.IsHead);
        var kept = new HashSet<string>(StringComparer.Ordinal);
        if (head is not null)
        {
            kept.Add(head.RefName);
            if (UpstreamOf(head) is { } headUpstream)
            {
                kept.Add(headUpstream);
            }
        }

        var hiddenNames = view.Hidden.ToHashSet(StringComparer.Ordinal);
        var pinnedNames = view.Pinned.ToHashSet(StringComparer.Ordinal);
        var cutoff = (now ?? DateTimeOffset.Now) - StaleAge;
        bool IsStale(string refName, DateTimeOffset? date) =>
            view.HideStale && !kept.Contains(refName) && !pinnedNames.Contains(refName) && date < cutoff;

        var hidden = new HashSet<string>(StringComparer.Ordinal);
        foreach (var local in refs.LocalBranches)
        {
            if (hiddenNames.Contains(local.RefName))
            {
                hidden.Add(local.RefName);
                if (TracksOwnName(local) && UpstreamOf(local) is { } upstream && !kept.Contains(upstream))
                {
                    hidden.Add(upstream);
                }
            }
            else if (IsStale(local.RefName, local.TipDate))
            {
                hidden.Add(local.RefName);
            }
        }

        foreach (var remote in refs.RemoteBranches)
        {
            if (hiddenNames.Contains(remote.RefName) || IsStale(remote.RefName, remote.TipDate))
            {
                hidden.Add(remote.RefName);
            }
        }

        // A tag is only ever hidden by hand: never stale, soloed or pinned.
        foreach (var tag in refs.Tags)
        {
            if (hiddenNames.Contains(tag.RefName))
            {
                hidden.Add(tag.RefName);
            }
        }

        // The current branch shows even when hidden before it was checked out.
        if (head is not null)
        {
            hidden.Remove(head.RefName);
        }

        var tips = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (refName, commit) in refs.LocalBranches.Select(local => (local.RefName, local.Commit))
                     .Concat(refs.RemoteBranches.Select(remote => (remote.RefName, remote.Commit))))
        {
            tips.TryAdd(refName, commit);
        }

        var solo = refs.Head.Commit is null ? [] : view.Solo.Where(tips.ContainsKey).ToList();
        var pinned = new List<string>();
        foreach (var refName in view.Pinned)
        {
            if (!hidden.Contains(refName)
                && (solo.Count == 0 || solo.Contains(refName, StringComparer.Ordinal)
                    || string.Equals(refName, head?.RefName, StringComparison.Ordinal))
                && tips.TryGetValue(refName, out var tip) && !pinned.Contains(tip, StringComparer.Ordinal))
            {
                pinned.Add(tip);
            }
        }

        return new LogFilter(hidden, solo, pinned);
    }

    /// <summary>
    /// <paramref name="local"/>'s upstream is its own remote counterpart (<c>feature</c> → <c>origin/feature</c>), which
    /// hiding <paramref name="local"/> hides too; not a branch others may track as well (<c>feature</c> made from
    /// <c>origin/main</c>).
    /// </summary>
    public static bool TracksOwnName(LocalBranch local)
    {
        if (local.Upstream is not { } upstream)
        {
            return false;
        }

        var slash = upstream.IndexOf('/', StringComparison.Ordinal);
        var rest = slash < 0 ? "" : upstream[(slash + 1)..];
        return string.Equals(rest, local.Name, StringComparison.Ordinal);
    }

    public bool Equals(LogFilter? other) =>
        other is not null && Hidden.SetEquals(other.Hidden)
        && Solo.SequenceEqual(other.Solo, StringComparer.Ordinal)
        && Pinned.SequenceEqual(other.Pinned, StringComparer.Ordinal);

    public override int GetHashCode() => HashCode.Combine(Hidden.Count, Solo.Count, Pinned.Count);
}

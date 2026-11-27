// A working tree's change counts (the graph's WIP rows show them) and a worktree of the repo with its own changes, as
// the graph's other-worktree rows need them. Ported from WorktreeChanges and WorktreeInfo in App/Repo/RepoSession.swift
// at 6fa6d40.
namespace Histq.Core;

/// <summary>
/// A working tree's change counts: unstaged and staged files (untracked and conflicted files count as unstaged), and
/// the WIP row's edited, added and deleted files (each file once, staged or not). Ignored files never count.
/// </summary>
/// <param name="Edited">Modified, renamed, copied, type-changed or conflicted files.</param>
/// <param name="Added">New files: added (staged, or <c>git add -N</c>) or untracked.</param>
public sealed record WorktreeChanges(int Unstaged, int Staged, int Edited, int Added, int Deleted)
{
    /// <summary>No unstaged and no staged file: the working tree has no changes.</summary>
    public bool IsEmpty => Unstaged == 0 && Staged == 0;

    /// <summary>"5 edited · 1 added": the WIP row's counts as text (its UI Automation name).</summary>
    public string KindSummary
    {
        get
        {
            var parts = new List<string>(3);
            if (Edited > 0)
            {
                parts.Add($"{Edited} edited");
            }

            if (Added > 0)
            {
                parts.Add($"{Added} added");
            }

            if (Deleted > 0)
            {
                parts.Add($"{Deleted} deleted");
            }

            return string.Join(" · ", parts);
        }
    }

    public static WorktreeChanges Of(WorkingStatus status)
    {
        int unstaged = 0, staged = 0, edited = 0, added = 0, deleted = 0;
        foreach (var entry in status.Entries)
        {
            if (entry.Kind == StatusEntryKind.Ignored)
            {
                continue;
            }

            if (entry.IsStaged)
            {
                staged++;
            }

            if (entry.IsUnstaged || entry.Kind is StatusEntryKind.Untracked or StatusEntryKind.Unmerged)
            {
                unstaged++;
            }

            // A conflict's letters are both sides' (`DU`, `AA`): it is edited.
            if (entry.Kind == StatusEntryKind.Unmerged)
            {
                edited++;
            }
            else if (entry.Index == StatusEntryChange.Deleted || entry.Worktree == StatusEntryChange.Deleted)
            {
                deleted++;
            }
            else if (entry.Kind == StatusEntryKind.Untracked || entry.Index == StatusEntryChange.Added
                     || entry.Worktree == StatusEntryChange.Added)
            {
                added++;
            }
            else
            {
                edited++;
            }
        }

        return new WorktreeChanges(unstaged, staged, edited, added, deleted);
    }
}

/// <summary>A worktree of the repo, as a tab's graph sees it.</summary>
/// <param name="IsCurrent">The tab's own worktree: its changes are the tab's status, never read here.</param>
/// <param name="Changes">Another worktree's uncommitted changes; null for the current one, a bare or missing one, or
/// one whose status could not be read.</param>
public sealed record WorktreeInfo(Worktree Worktree, bool IsCurrent, WorktreeChanges? Changes)
{
    public string Path => Worktree.Path;

    /// <summary>The folder's name (raw: sanitize it before showing it): the graph row's label.</summary>
    public string Name => PathFlavor.Host.LastComponent(Worktree.Path);

    /// <summary>Another worktree with uncommitted changes: it gets a graph row.</summary>
    public bool IsDirty => Changes is { IsEmpty: false };
}

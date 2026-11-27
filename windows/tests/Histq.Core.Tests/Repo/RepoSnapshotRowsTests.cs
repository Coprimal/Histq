// Key feature tests for the graph's row mapping of a RepoSnapshot (ported from LogSnapshot.entry(at:),
// row(ofCommit:) and row(where:) of RepoSession.swift at 6fa6d40): the WIP row on top, the hung worktree and stash rows
// right above their base commits, the commits in between; each row's item found again by its row and back.
using System.Collections.Immutable;

namespace Histq.Core.Tests;

public sealed class RepoSnapshotRowsTests
{
    private static GraphRow Row(GraphNode node) => new(node, 0, 0, [], [], 1);

    private static GraphSyntheticRow Synthetic(GraphSyntheticRowKind kind, string id, string? @base) =>
        new(kind, id, @base);

    private static Commit Commit(string hash) =>
        new(hash, [], "A", "a@example.com", DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, hash, "");

    // WIP on top; c0, then a worktree row and a stash both above c1, c1, c2, then a stash above c3, c3.
    private static RepoSnapshot Snapshot()
    {
        var wip = Synthetic(GraphSyntheticRowKind.Wip, "wip", "c0");
        var worktree = Synthetic(GraphSyntheticRowKind.WorktreeWip, "/wt", "c1");
        var stash1 = Synthetic(GraphSyntheticRowKind.Stash, "s1", "c1");
        var stash2 = Synthetic(GraphSyntheticRowKind.Stash, "s2", "c3");
        string[] hashes = ["c0", "c1", "c2", "c3"];
        return new RepoSnapshot
        {
            Commits = hashes.Select(Commit).ToList(),
            Rows = hashes.Select(hash => Row(GraphNode.Commit(hash, false))).ToList(),
            SyntheticRows = [Row(GraphNode.Synthetic(wip))],
            Hung =
            [
                new GraphHungRow(1, worktree, Row(GraphNode.Synthetic(worktree))),
                new GraphHungRow(1, stash1, Row(GraphNode.Synthetic(stash1))),
                new GraphHungRow(3, stash2, Row(GraphNode.Synthetic(stash2))),
            ],
        };
    }

    [Fact]
    public void MapsEveryRowToItsItemAndBack()
    {
        var snapshot = Snapshot();
        Assert.Equal(8, snapshot.RowCount);

        string Label(long row) => snapshot.EntryAt(row) is { } entry
            ? entry.Synthetic?.Id ?? snapshot.Commits[entry.CommitIndex].Hash
            : "-";
        Assert.Equal(
            ["wip", "c0", "/wt", "s1", "c1", "c2", "s2", "c3"],
            Enumerable.Range(0, 8).Select(row => Label(row)).ToArray());
        Assert.Null(snapshot.EntryAt(-1));
        Assert.Null(snapshot.EntryAt(8));

        Assert.Equal([1L, 4, 5, 7], Enumerable.Range(0, 4).Select(snapshot.RowOfCommit).ToArray());
        Assert.Equal(0, snapshot.RowOfSynthetic(GraphSyntheticRowKind.Wip, "wip"));
        Assert.Equal(2, snapshot.RowOfSynthetic(GraphSyntheticRowKind.WorktreeWip, "/wt"));
        Assert.Equal(6, snapshot.RowOfSynthetic(GraphSyntheticRowKind.Stash, "s2"));
        Assert.Equal(-1, snapshot.RowOfSynthetic(GraphSyntheticRowKind.Stash, "/wt"));
    }
}

public sealed class WorktreeChangesTests
{
    // Each file counts once among edited / added / deleted, staged or not; untracked and conflicted files are unstaged.
    [Fact]
    public void CountsEachFileOnceByKind()
    {
        var status = new WorkingStatus(
            new WorkingStatusBranch("c0", "main", null, null, null),
            [
                new StatusEntry(StatusEntryKind.Ordinary, "m", Index: StatusEntryChange.Modified, Worktree: StatusEntryChange.Modified),
                new StatusEntry(StatusEntryKind.Ordinary, "a", Index: StatusEntryChange.Added),
                new StatusEntry(StatusEntryKind.Untracked, "u"),
                new StatusEntry(StatusEntryKind.Ordinary, "d", Worktree: StatusEntryChange.Deleted),
                new StatusEntry(StatusEntryKind.Unmerged, "x", Index: StatusEntryChange.Deleted, Worktree: StatusEntryChange.Unmerged),
                new StatusEntry(StatusEntryKind.Ignored, "i"),
            ]);

        var changes = WorktreeChanges.Of(status);

        Assert.Equal(new WorktreeChanges(Unstaged: 4, Staged: 2, Edited: 2, Added: 2, Deleted: 1), changes);
        Assert.Equal("2 edited · 2 added · 1 deleted", changes.KindSummary);
        Assert.True(WorktreeChanges.Of(new WorkingStatus(status.Branch, [new StatusEntry(StatusEntryKind.Ignored, "i")])).IsEmpty);
    }
}

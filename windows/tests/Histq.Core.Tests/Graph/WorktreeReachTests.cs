// WorktreeReach: each worktree's HEAD reaches its own branch and the history it shares; two worktrees sharing a stretch
// both own it. Ported from WorktreeReachTests.swift at 6fa6d40.
namespace Histq.Core.Tests;

public sealed class WorktreeReachTests
{
    // Each tip reaches its own branch and the shared history below it.
    [Fact]
    public void MasksFromForkPoint()
    {
        // HEAD at h2; worktree A at a2 forks at r; worktree B at b1 forks from a1; worktree C at r (behind HEAD).
        Commit[] commits =
        [
            Make("b1", "a1"), Make("h2", "h1"), Make("a2", "a1"), Make("a1", "r"), Make("h1", "r"), Make("r"),
        ];
        var index = commits.Select((commit, position) => (commit.Hash, position))
            .ToDictionary(pair => pair.Hash, pair => pair.position, StringComparer.Ordinal);

        var masks = WorktreeReach.Masks(commits, index, ["a2", "b1", "r", null, "h2"], TestContext.Current.CancellationToken);

        Assert.Equal([0b00010UL, 0b10000UL, 0b00001UL, 0b00011UL, 0b10000UL, 0b10111UL], masks);
    }

    private static Commit Make(string hash, params string[] parents) =>
        new(hash, parents, "A", "a@histq.invalid", DateTimeOffset.MinValue, DateTimeOffset.MinValue, hash, "");
}

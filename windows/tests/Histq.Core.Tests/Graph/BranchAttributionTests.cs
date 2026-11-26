// Key feature tests for BranchAttribution: HEAD's branch claims its first-parent chain before a branch that sorts first,
// a merged-and-deleted side branch's commits take the branch it was merged into, and a commit only a remote branch
// reaches is named after that remote branch. Ported from BranchAttributionTests.swift at 6fa6d40.
namespace Histq.Core.Tests;

public sealed class BranchAttributionTests
{
    // HEAD's branch wins its first-parent chain over another branch that also contains it.
    [Fact]
    public void HeadBranchWinsItsChain()
    {
        // `feature` (sorts before `main`) sits on top of main's tip: both contain main's chain.
        Commit[] commits = [Make("f1", "m2"), Make("m2", "m1"), Make("m1")];
        var refs = new Refs(
            new Head.Branch("main", "m2"), [Local("feature", "f1"), Local("main", "m2", isHead: true)], [], []);

        var map = BranchAttribution.Map(commits, refs, ct: TestContext.Current.CancellationToken);

        Assert.Equal(Expected(("f1", "feature"), ("m2", "main"), ("m1", "main")), map);
    }

    // A merged-and-deleted side branch's commits take the branch it was merged into.
    [Fact]
    public void DeletedSideBranchInheritsTheMerge()
    {
        // M merges S2 (whose branch is gone) into main; S1 forks from B.
        Commit[] commits = [Make("m", "a", "s2"), Make("s2", "s1"), Make("a", "b"), Make("s1", "b"), Make("b")];
        var refs = new Refs(new Head.Branch("main", "m"), [Local("main", "m", isHead: true)], [], []);

        var map = BranchAttribution.Map(commits, refs, ct: TestContext.Current.CancellationToken);

        Assert.Equal(
            Expected(("m", "main"), ("a", "main"), ("b", "main"), ("s2", "main"), ("s1", "main")), map);
    }

    // A commit only a remote branch reaches gets the remote branch's name.
    [Fact]
    public void RemoteOnlyCommitGetsTheRemote()
    {
        // origin/main is one commit ahead of the local main.
        Commit[] commits = [Make("r", "m"), Make("m", "root"), Make("root")];
        var refs = new Refs(
            new Head.Branch("main", "m"), [Local("main", "m", isHead: true)],
            [new RemoteBranch("origin/main", "refs/remotes/origin/main", "origin", "r")], []);

        var map = BranchAttribution.Map(commits, refs, ct: TestContext.Current.CancellationToken);

        Assert.Equal(Expected(("r", "origin/main"), ("m", "main"), ("root", "main")), map);
    }

    // Helpers.

    private static Commit Make(string hash, params string[] parents) =>
        new(hash, parents, "A", "a@histq.invalid", DateTimeOffset.MinValue, DateTimeOffset.MinValue, hash, "");

    private static LocalBranch Local(string name, string commit, bool isHead = false) =>
        new(name, $"refs/heads/{name}", commit, null, 0, 0, false, isHead);

    private static Dictionary<string, string> Expected(params (string Hash, string Branch)[] pairs) =>
        pairs.ToDictionary(pair => pair.Hash, pair => pair.Branch, StringComparer.Ordinal);
}

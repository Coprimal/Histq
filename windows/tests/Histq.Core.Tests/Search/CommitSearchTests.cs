// Key feature tests for the graph's commit search: a subject matches whatever its case, every query word must be in the
// message in any order, separators and diacritics fold, the body is searched, and a hash prefix (or any other part of
// it) finds its commit from 4 hex characters on, never from 3. Ported from CommitSearchTests.swift at 6fa6d40.
namespace Histq.Core.Tests;

public sealed class CommitSearchTests
{
    private static int[] Find(Commit[] commits, string query) =>
        CommitSearch.Matches(commits, query, TestContext.Current.CancellationToken);

    private static Commit Make(string hash, string subject, string body = "") =>
        new(hash, [], "Jane", "jane@example.com", DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, subject, body);

    // A subject matches regardless of case, in log order.
    [Fact]
    public void SubjectMatchIgnoresCase()
    {
        Commit[] commits =
        [
            Make("1111111111111111111111111111111111111111", "Series step 2"),
            Make("2222222222222222222222222222222222222222", "Add config"),
            Make("3333333333333333333333333333333333333333", "SERIES finale"),
        ];
        Assert.Equal([0, 2], Find(commits, "series"));
    }

    // Spaces, tabs, -, _ and / match each other, a run of them as one; diacritics fold.
    [Fact]
    public void SeparatorsMatchEachOther()
    {
        Commit[] commits =
        [
            Make("1111111111111111111111111111111111111111",
                "Merge pull request #79 from IdetaAutomation/urgent-fix-conv-url-in-cluster"),
            Make("2222222222222222222222222222222222222222", "Urgent  fix for the café"),
            Make("3333333333333333333333333333333333333333", "Urgent release"),
        ];
        Assert.Equal([0, 1], Find(commits, "urgent fix"));
        Assert.Equal([0, 1], Find(commits, "URGENT_fix"));
        Assert.Equal([0], Find(commits, "automation urgent"));
        Assert.Equal([1], Find(commits, "fix-for the cafe"));
    }

    // Every word of the query must be in the subject, in any order, also inside a longer word.
    [Fact]
    public void EveryWordInAnyOrder()
    {
        Commit[] commits =
        [
            Make("1111111111111111111111111111111111111111", "Refactored imports from lib updates"),
            Make("2222222222222222222222222222222222222222", "Update lib versions"),
            Make("3333333333333333333333333333333333333333", "Update docs"),
            Make("4444444444444444444444444444444444444444", "Move library code"),
        ];
        Assert.Equal([0, 1], Find(commits, "update lib"));
        Assert.Equal([0, 1], Find(commits, "lib  update"));
        Assert.Empty(Find(commits, "update lib docs"));
        Assert.Equal([0, 1, 3], Find(commits, "lib"));
    }

    // The body is searched too, its line breaks as spaces, a word never spanning two commits.
    [Fact]
    public void BodyIsSearched()
    {
        Commit[] commits =
        [
            Make("1111111111111111111111111111111111111111", "Fix crash",
                "The cluster URL was wrong.\n\nConv\nurl now built per cluster."),
            Make("2222222222222222222222222222222222222222", "Add docs"),
        ];
        Assert.Equal([0], Find(commits, "cluster url"));
        Assert.Equal([0], Find(commits, "conv url"));
        Assert.Equal([0], Find(commits, "crash cluster"));
        Assert.Empty(Find(commits, "cluster docs"));
    }

    // 4 hex characters find the commit by hash prefix; 3 do not.
    [Fact]
    public void HashPrefixNeedsFourCharacters()
    {
        Commit[] commits =
        [
            Make("5a5baf0c0ffee000000000000000000000000000", "Polish feature"),
            Make("af780d0000000000000000000000000000000000", "Update changelog"),
        ];
        Assert.Equal([0], Find(commits, "5a5b"));
        Assert.Empty(Find(commits, "5a5"));
    }

    // 4 hex characters find the commit by any part of its hash, not only its start.
    [Fact]
    public void HashPartMatchesAnywhere()
    {
        Commit[] commits =
        [
            Make("5a5baf0c0ffee000000000000000000000000000", "Polish feature"),
            Make("af780d0000000000000000000000000000000000", "Update changelog"),
            Make("00000000000000000000000000000000c0ffee12", "Release"),
        ];
        Assert.Equal([0, 2], Find(commits, "c0ffee"));
        Assert.Equal([1], Find(commits, "780D"));
        Assert.Equal([2], Find(commits, "ee12"));
    }

    // Bug regression: a buffer that would grow past what one array holds is refused (the index stops there) instead of
    // overflowing int or throwing; below that it doubles, clamped to Array.MaxLength.
    [Fact]
    public void BufferGrowthNeverOverflows()
    {
        Assert.Equal(64, CommitSearch.GrownCapacity(64, 10));
        Assert.Equal(128, CommitSearch.GrownCapacity(64, 65));
        Assert.Equal(1000, CommitSearch.GrownCapacity(64, 1000));
        Assert.Equal(Array.MaxLength, CommitSearch.GrownCapacity(1 << 30, (1L << 30) + 1));
        Assert.Equal(Array.MaxLength, CommitSearch.GrownCapacity(int.MaxValue / 2 + 1, Array.MaxLength));
        Assert.Equal(-1, CommitSearch.GrownCapacity(1 << 30, Array.MaxLength + 1L));
        Assert.Equal(-1, CommitSearch.GrownCapacity(Array.MaxLength, (long)int.MaxValue + int.MaxValue));
        Assert.False(new CommitSearch.Index([Make("1111111111111111111111111111111111111111", "Fix")]).IsTruncated);
    }
}

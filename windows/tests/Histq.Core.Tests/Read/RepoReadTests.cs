// Key feature tests for the readers on a private copy of the `graph` fixture: the history the graph lays out (merges
// keep both parents, stash internals never become rows), the ref labels with their upstream counts and peeled tags, the
// working tree status, and the stash and worktree rows. Ported from RepoReadTests.swift at 6fa6d40 (the DiffReader
// cases come with the diff milestone).
namespace Histq.Core.Tests;

public sealed class RepoReadTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    /// <summary>The fixture copy, its <c>graph</c> repo and the read environment for it (as every automatic read uses).</summary>
    private sealed class Graph : IDisposable
    {
        private Graph(FixtureCopy copy, string repo, Dictionary<string, string> env)
        {
            Copy = copy;
            Repo = repo;
            Env = env;
        }

        public FixtureCopy Copy { get; }

        public string Repo { get; }

        public Dictionary<string, string> Env { get; }

        public GitRunner Runner => Copy.Runner;

        public static async Task<Graph> CreateAsync()
        {
            var copy = await Fixtures.CopyAsync();
            try
            {
                var repo = copy.Repo("graph");
                var env = await GitInvocation.ReadEnvironmentAsync(null, copy.Base, copy.Runner, repo, ct: Token);
                return new Graph(copy, repo, env);
            }
            catch
            {
                copy.Dispose();
                throw;
            }
        }

        /// <summary>The read environment for another repo of the copy (each folder gets its own filter listing).</summary>
        public Task<Dictionary<string, string>> ReadEnvironmentAsync(string repo) =>
            GitInvocation.ReadEnvironmentAsync(null, Copy.Base, Copy.Runner, repo, ct: Token);

        public void Dispose() => Copy.Dispose();
    }

    // The log streams every commit in pages, a merge keeps both parents, and stash internals are no rows.
    [Fact]
    public async Task LogKeepsMergesAndHidesStashInternals()
    {
        using var graph = await Graph.CreateAsync();

        var pages = new List<IReadOnlyList<Commit>>();
        await foreach (var page in LogReader.PagesAsync(graph.Runner, graph.Repo, graph.Env, pageSize: 4, ct: Token))
        {
            pages.Add(page);
        }

        var commits = pages.SelectMany(page => page).ToList();
        var hashes = commits.Select(c => c.Hash).ToHashSet(StringComparer.Ordinal);
        Assert.True(pages.Count > 1);
        Assert.All(pages.SkipLast(1), page => Assert.Equal(4, page.Count));
        Assert.Equal(commits.Count, hashes.Count); // No commit twice.
        var expected = await graph.Copy.GitAsync(["rev-list", "--count", "--exclude=refs/stash", "--all"], graph.Repo, ct: Token);
        Assert.Equal(expected, commits.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));

        var merge = Assert.Single(commits, c => c.Subject == "Merge branch 'develop'");
        var mergeParents = await graph.Copy.GitAsync(["rev-parse", "v1.0^1", "v1.0^2"], graph.Repo, ct: Token);
        Assert.Equal(mergeParents.Split('\n'), merge.Parents);
        Assert.Equal("Histq Fixture", merge.AuthorName);
        Assert.Equal("fixture@histq.invalid", merge.AuthorEmail);

        // The stash's base (main's tip) is a row; the stash commit and its index and untracked commits are not.
        var stashCommits = (await graph.Copy.GitAsync(
            ["rev-parse", "stash@{0}^1", "stash@{0}", "stash@{0}^2", "stash@{0}^3"], graph.Repo, ct: Token)).Split('\n');
        Assert.Equal(4, stashCommits.Length);
        Assert.Contains(stashCommits[0], hashes);
        foreach (var hidden in stashCommits.Skip(1))
        {
            Assert.False(hashes.Contains(hidden), $"stash internal {hidden} is a log row");
        }
    }

    // Refs carry HEAD (branch or detached), upstream ahead/behind counts and the annotated tag's peeled commit.
    [Fact]
    public async Task RefsCarryTrackingAndPeeledTags()
    {
        using var graph = await Graph.CreateAsync();
        var refs = await RefReader.ReadAsync(graph.Runner, graph.Repo, graph.Env, Token);
        var mainTip = await graph.Copy.GitAsync(["rev-parse", "main"], graph.Repo, ct: Token);

        Assert.Equal(new Head.Branch("main", mainTip), refs.Head);
        var branches = refs.LocalBranches.ToDictionary(branch => branch.Name, StringComparer.Ordinal);
        Assert.Equal(
            new HashSet<string>(["main", "develop", "feature", "series", "wt"], StringComparer.Ordinal),
            branches.Keys.ToHashSet(StringComparer.Ordinal));
        var main = branches["main"];
        Assert.True(main.IsHead && main.Upstream == "origin/main" && main.Ahead == 0 && main.Behind == 0);
        var develop = branches["develop"];
        Assert.True(develop.Upstream == "origin/develop" && develop.Ahead == 1 && develop.Behind == 0);
        var feature = branches["feature"];
        Assert.True(feature.Upstream == "origin/feature" && feature.Ahead == 0 && feature.Behind == 1);
        Assert.Null(branches["series"].Upstream);

        Assert.Equal(
            new HashSet<string>(["origin/main", "origin/develop", "origin/feature"], StringComparer.Ordinal),
            refs.RemoteBranches.Select(branch => branch.Name).ToHashSet(StringComparer.Ordinal));
        Assert.All(refs.RemoteBranches, branch => Assert.True(branch.Remote == "origin" && branch.TipDate is not null));
        var mainTime = await graph.Copy.GitAsync(["log", "-1", "--format=%ct", "main"], graph.Repo, ct: Token);
        Assert.NotNull(main.TipDate);
        Assert.Equal(
            DateTimeOffset.FromUnixTimeSeconds(long.Parse(mainTime, System.Globalization.CultureInfo.InvariantCulture)),
            main.TipDate);

        var tags = refs.Tags.ToDictionary(tag => tag.Name, StringComparer.Ordinal);
        var annotated = tags["v1.0"];
        var tagObject = await graph.Copy.GitAsync(["rev-parse", "refs/tags/v1.0"], graph.Repo, ct: Token);
        var tagCommit = await graph.Copy.GitAsync(["rev-parse", "v1.0^{commit}"], graph.Repo, ct: Token);
        Assert.True(annotated.IsAnnotated && annotated.Target == tagObject && annotated.Commit == tagCommit);
        Assert.NotEqual(tagObject, tagCommit);
        var lightweight = tags["v0.1"];
        var lightCommit = await graph.Copy.GitAsync(["rev-parse", "v0.1"], graph.Repo, ct: Token);
        Assert.True(!lightweight.IsAnnotated && lightweight.Target == lightCommit && lightweight.Commit == lightCommit);

        // A rebase stopped on a conflict leaves HEAD detached.
        var rebasing = graph.Copy.Repo("conflict-rebase");
        var rebasingRefs = await RefReader.ReadAsync(
            graph.Runner, rebasing, await graph.ReadEnvironmentAsync(rebasing), Token);
        var rebasingHead = await graph.Copy.GitAsync(["rev-parse", "HEAD"], rebasing, ct: Token);
        Assert.Equal(new Head.Detached(rebasingHead), rebasingRefs.Head);
        Assert.DoesNotContain(rebasingRefs.LocalBranches, branch => branch.IsHead);
    }

    // Status covers staged, unstaged, untracked, the staged rename, a file named -rf and conflicts.
    [Fact]
    public async Task StatusCoversEveryKind()
    {
        using var graph = await Graph.CreateAsync();
        var status = await StatusReader.ReadAsync(graph.Runner, graph.Repo, graph.Env, Token);

        Assert.Equal("main", status.Branch.Name);
        Assert.True(status.Branch.Upstream == "origin/main" && status.Branch.Ahead == 0 && status.Branch.Behind == 0);
        var byPath = status.Entries.ToDictionary(entry => entry.Path, StringComparer.Ordinal);

        var app = byPath["src/app.swift"];
        Assert.True(app.Kind == StatusEntryKind.Ordinary && app.Index == StatusEntryChange.Modified
                    && app.Worktree == StatusEntryChange.Modified);
        Assert.Equal(StatusEntryChange.Added, byPath["staged.txt"].Index);
        Assert.Equal(StatusEntryChange.Modified, byPath["README.md"].Worktree);
        Assert.Equal(StatusEntryChange.Unmodified, byPath["README.md"].Index);
        var rename = byPath["new-name.txt"];
        Assert.True(rename.Kind == StatusEntryKind.Renamed && rename.OriginalPath == "old-name.txt" && rename.Similarity == 100);
        Assert.Equal(StatusEntryChange.Renamed, rename.Index);
        Assert.Equal(StatusEntryKind.Untracked, byPath["-rf"].Kind);
        Assert.Equal(StatusEntryKind.Untracked, byPath["untracked.txt"].Kind);

        Assert.Equal(Paths("src/app.swift", "staged.txt", "new-name.txt"), Paths(status.Staged));
        Assert.Equal(Paths("src/app.swift", "README.md", "no-newline.txt", "image.bin"), Paths(status.Unstaged));
        Assert.Equal(Paths("-rf", "untracked.txt"), Paths(status.Untracked));
        Assert.Empty(status.Conflicted);

        // A merge stopped on conflicts: both-modified, modified/deleted and add/add.
        var conflict = graph.Copy.Repo("conflict");
        var merging = await StatusReader.ReadAsync(graph.Runner, conflict, await graph.ReadEnvironmentAsync(conflict), Token);
        var codes = merging.Conflicted.ToDictionary(
            entry => entry.Path, entry => $"{(char)entry.Index}{(char)entry.Worktree}", StringComparer.Ordinal);
        Assert.Equal(
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["long.txt"] = "UU", ["gone.txt"] = "UD", ["add.txt"] = "AA",
            },
            codes);
        Assert.True(merging.Entries.Count == 3 && merging.Staged.Count == 0 && merging.Unstaged.Count == 0);

        // The same conflicts mid-rebase: HEAD is detached.
        var rebasing = graph.Copy.Repo("conflict-rebase");
        var rebaseStatus = await StatusReader.ReadAsync(
            graph.Runner, rebasing, await graph.ReadEnvironmentAsync(rebasing), Token);
        Assert.True(rebaseStatus.Branch.Name is null && rebaseStatus.Branch.Commit is not null);
        Assert.Equal(3, rebaseStatus.Conflicted.Count);
    }

    // Stashes come with their base commit and the linked worktree is found.
    [Fact]
    public async Task StashBasesAndWorktrees()
    {
        using var graph = await Graph.CreateAsync();
        var stashes = await StashWorktreeReader.StashesAsync(graph.Runner, graph.Repo, graph.Env, Token);
        Assert.Equal(2, stashes.Count);
        foreach (var stash in stashes)
        {
            var expected = await graph.Copy.GitAsync(
                ["rev-parse", stash.Selector, $"{stash.Selector}^1"], graph.Repo, ct: Token);
            Assert.Equal(expected, stash.Hash + "\n" + stash.Base);
        }

        Assert.True(stashes[0].Message.EndsWith("scratch with untracked", StringComparison.Ordinal)
                    && stashes[0].OtherParents.Count == 2);
        Assert.True(stashes[1].Message.EndsWith("guide tweaks", StringComparison.Ordinal)
                    && stashes[1].OtherParents.Count == 1);

        var worktrees = await StashWorktreeReader.WorktreesAsync(graph.Runner, graph.Repo, graph.Env, Token);
        Assert.Equal(2, worktrees.Count);
        Assert.True(worktrees[0].IsMain);
        AssertSamePath(graph.Repo, worktrees[0].Path);
        Assert.Equal("refs/heads/main", worktrees[0].Branch);
        var linked = worktrees[1];
        var wtTip = await graph.Copy.GitAsync(["rev-parse", "wt"], graph.Repo, ct: Token);
        Assert.False(linked.IsMain);
        AssertSamePath(graph.Copy.Repo("graph-wt"), linked.Path);
        Assert.True(linked.Branch == "refs/heads/wt" && linked.Head == wtTip && !linked.IsDetached);
    }

    private static HashSet<string> Paths(params string[] paths) => paths.ToHashSet(StringComparer.Ordinal);

    private static HashSet<string> Paths(IEnumerable<StatusEntry> entries) =>
        entries.Select(entry => entry.Path).ToHashSet(StringComparer.Ordinal);

    /// <summary>
    /// The same folder: full paths compared exactly, case-insensitively on Windows (git may report another drive letter
    /// case). The fixture copy's folder has its links resolved and, on Windows, its long name, as git reports it.
    /// </summary>
    private static void AssertSamePath(string expected, string actual)
    {
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var left = Path.TrimEndingDirectorySeparator(Path.GetFullPath(expected));
        var right = Path.TrimEndingDirectorySeparator(Path.GetFullPath(actual));
        Assert.True(string.Equals(left, right, comparison), $"{actual} is not {expected}");
    }
}

// Key feature tests for RepoLoader: a reload that reads only the new commits gives the same log and graph (rows, order,
// colors, the WIP and stash rows) as reading the whole history again; the saved view's hidden and soloed branches
// (LogFilter) leave commits out of the log, keep HEAD's, and never hide the current branch. Ported from the incremental
// reload and logFilter(view:refs:) of RepoSession.swift at 6fa6d40.
namespace Histq.Core.Tests;

public sealed class RepoLoaderTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    // After a commit dated after the tip, the incremental reload equals a full read: same commits in the same order,
    // same rows (lanes and colors), same top and hung rows, tips and width.
    [Theory]
    [InlineData(GraphLayout.Coloring.Branch)]
    [InlineData(GraphLayout.Coloring.Column)]
    public async Task ReloadAfterNewerCommitEqualsFullRead(GraphLayout.Coloring coloring)
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var tree = await sandbox.GitAsync(["rev-parse", "HEAD^{tree}"], repo);
        // A commit of `tree` on `parents`, authored and committed `seconds` after 1970 (unique dates: no tie).
        async Task<string> CommitAsync(string subject, int seconds, params string[] parents)
        {
            var date = $"@{seconds} +0000";
            var env = new Dictionary<string, string>(sandbox.Base, GitRunner.EnvironmentKeyComparer)
            {
                ["GIT_AUTHOR_DATE"] = date,
                ["GIT_COMMITTER_DATE"] = date,
            };
            var result = await sandbox.Runner.RunAsync(
                ["commit-tree", .. parents.SelectMany(parent => new[] { "-p", parent }), "-m", subject, tree], repo, env,
                timeout: TimeSpan.FromSeconds(30), ct: Token);
            return result.Text.Trim();
        }

        // main: initial -> M1 -> M2 -> merge of side (off M1); topic off M1, not merged and pinned.
        var initial = await CommitAsync("initial", 100);
        var m1 = await CommitAsync("M1", 200, initial);
        var side = await CommitAsync("side", 250, m1);
        var m2 = await CommitAsync("M2", 300, m1);
        var topic = await CommitAsync("topic", 350, m1);
        var merge = await CommitAsync("merge side", 400, m2, side);
        await sandbox.GitAsync(["update-ref", "refs/heads/main", merge], repo);
        await sandbox.GitAsync(["update-ref", "refs/heads/topic", topic], repo);
        // A stash (its row hangs above main's tip) and a changed file (the WIP row).
        await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "stashed\n", Token);
        await sandbox.GitAsync(["stash", "push", "-q"], repo);
        await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "changed\n", Token);

        var loader = new RepoLoader(sandbox.Runner, repo, sandbox.Base);
        var filter = new LogFilter(Pinned: [topic]);
        var order = LogReader.Order.Date;
        var firstPages = new List<RepoSnapshot>();
        var previous = await loader.LoadAsync(
            1, filter, [], order, coloring, first => { firstPages.Add(first); return Task.CompletedTask; }, Token);
        Assert.True(previous.IsComplete);
        var firstPage = Assert.Single(firstPages); // The streamed first page, before the log was complete.
        Assert.False(firstPage.IsComplete);
        Assert.Equal(1, firstPage.Generation);

        var newest = await CommitAsync("newest", 500, merge);
        await sandbox.GitAsync(["update-ref", "refs/heads/main", newest], repo);

        var reloaded = await loader.ReloadIncrementallyAsync(previous, 2, filter, [], Token);
        var full = await loader.LoadAsync(3, filter, [], order, coloring, ct: Token);
        var reload = await loader.ReloadAsync(previous, 4, filter, [], order, coloring, Token);

        Assert.NotNull(reloaded); // Read incrementally, not by falling back to a full read.
        Assert.Equal(previous.Commits.Count + 1, reloaded.Commits.Count);
        Assert.Equal(full.Commits.Select(c => c.Hash), reloaded.Commits.Select(c => c.Hash));
        Assert.Equal(full.Commits, reloaded.Commits);
        Assert.Equal(full.Rows, reloaded.Rows);
        Assert.Equal(full.SyntheticRows, reloaded.SyntheticRows);
        Assert.Equal(full.Hung, reloaded.Hung);
        Assert.Equal(full.Synthetic, reloaded.Synthetic);
        Assert.Equal(full.Tips.ToHashSet(StringComparer.Ordinal), reloaded.Tips.ToHashSet(StringComparer.Ordinal));
        Assert.Equal(full.CommitIndex.OrderBy(pair => pair.Value), reloaded.CommitIndex.OrderBy(pair => pair.Value));
        Assert.Equal(full.Lanes, reloaded.Lanes);
        Assert.True(reloaded.IsComplete);
        Assert.Equal(2, reloaded.Generation);
        // The public reload takes the same path.
        Assert.Equal(full.Commits, reload.Commits);
        Assert.Equal(full.Rows, reload.Rows);
        Assert.Equal(full.SyntheticRows, reload.SyntheticRows);
        Assert.Equal(full.Hung, reload.Hung);
        // The fixture is not trivial: the WIP row on top, the stash row hung, the pinned topic in lane 0.
        Assert.Single(full.SyntheticRows);
        Assert.Single(full.Hung);
        Assert.Equal(0, full.Rows[full.CommitIndex[topic]].Lane);
        Assert.True(full.Lanes >= 3);
    }

    // A hidden branch's own commit leaves the log; soloing another branch keeps HEAD's commits (the WIP row's base).
    [Fact]
    public async Task HiddenRefIsExcludedAndSoloKeepsHeadsBase()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        async Task<string> CommitOnAsync(string branch, string subject)
        {
            await sandbox.GitAsync(["checkout", "-q", branch], repo);
            await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", subject], repo);
            return await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
        }

        await sandbox.GitAsync(["branch", "side"], repo);
        await sandbox.GitAsync(["branch", "topic"], repo);
        var sideOnly = await CommitOnAsync("side", "side only");
        var topicOnly = await CommitOnAsync("topic", "topic only");
        var mainOnly = await CommitOnAsync("main", "main only");
        await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "changed\n", Token);
        var env = await GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, repo, ct: Token);
        var refs = await RefReader.ReadAsync(sandbox.Runner, repo, env, Token);
        var loader = new RepoLoader(sandbox.Runner, repo, sandbox.Base);
        async Task<RepoSnapshot> LoadAsync(RepoViewState view) => await loader.LoadAsync(
            1, LogFilter.For(view, refs), [], LogReader.Order.Date, GraphLayout.Coloring.Branch, ct: Token);

        var hidden = await LoadAsync(new RepoViewState(Hidden: ["refs/heads/side"]));
        Assert.Equal(["refs/heads/side"], hidden.Filter.Hidden);
        Assert.DoesNotContain(sideOnly, hidden.CommitIndex.Keys);
        Assert.Contains(topicOnly, hidden.CommitIndex.Keys);
        Assert.Contains(mainOnly, hidden.CommitIndex.Keys);

        var soloed = await LoadAsync(new RepoViewState(Solo: ["refs/heads/topic"]));
        Assert.Equal(["refs/heads/topic"], soloed.Filter.Solo);
        Assert.Contains(topicOnly, soloed.CommitIndex.Keys);
        Assert.DoesNotContain(sideOnly, soloed.CommitIndex.Keys);
        Assert.Contains(mainOnly, soloed.CommitIndex.Keys); // HEAD is read with the soloed branch.
        var wip = Assert.Single(soloed.Synthetic, row => row.Kind == GraphSyntheticRowKind.Wip);
        Assert.Equal(mainOnly, wip.Base);
    }

    // Hiding a branch that tracks its own name hides that upstream too; the current branch is never hidden, its
    // upstream not by that rule, but a hand-hidden upstream of the current branch stays hidden.
    [Fact]
    public void HidingKeepsTheCurrentBranch()
    {
        var tip = new string('a', 40);
        var refs = new Refs(
            new Head.Branch("main", tip),
            [
                new LocalBranch("feature", "refs/heads/feature", tip, "origin/feature", 0, 0, false, false),
                new LocalBranch("main", "refs/heads/main", tip, "origin/main", 0, 0, false, true),
            ],
            [
                new RemoteBranch("origin/feature", "refs/remotes/origin/feature", "origin", tip),
                new RemoteBranch("origin/main", "refs/remotes/origin/main", "origin", tip),
            ],
            []);

        var byHand = LogFilter.For(new RepoViewState(Hidden: ["refs/heads/feature", "refs/heads/main"]), refs);
        Assert.Equal(
            new HashSet<string>(["refs/heads/feature", "refs/remotes/origin/feature"], StringComparer.Ordinal),
            byHand.Hidden.ToHashSet(StringComparer.Ordinal));

        var upstream = LogFilter.For(new RepoViewState(Hidden: ["refs/remotes/origin/main"]), refs);
        Assert.Equal(["refs/remotes/origin/main"], upstream.Hidden);
    }

    // A bare repo (no worktree: no status, no stash list, no top folder) loads its commits with no WIP or stash row; a
    // reload reads the whole log again (the common dir is not trusted for an incremental read); the status and stashes
    // read between loads equal the snapshot's.
    [Fact]
    public async Task BareRepoLoadsItsCommits()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "second\n", Token);
        await sandbox.GitAsync(["commit", "-q", "-am", "second"], repo);
        var bare = Path.Combine(sandbox.Root, "bare.git");
        await sandbox.GitAsync(["clone", "-q", "--bare", repo, bare], sandbox.Root);

        var loader = new RepoLoader(sandbox.Runner, bare, sandbox.Base);
        var snapshot = await loader.LoadAsync(
            1, LogFilter.None, [], LogReader.Order.Date, GraphLayout.Coloring.Branch, ct: Token);
        var reloaded = await loader.ReloadAsync(
            snapshot, 2, LogFilter.None, [], LogReader.Order.Date, GraphLayout.Coloring.Branch, Token);

        Assert.Equal(["second", "initial"], snapshot.Commits.Select(commit => commit.Subject));
        Assert.Empty(snapshot.SyntheticRows);
        Assert.Empty(snapshot.Hung);
        Assert.Empty(snapshot.Stashes);
        Assert.Equal(snapshot.Commits.Select(c => c.Hash), reloaded.Commits.Select(c => c.Hash));

        // The checks between loads read the same: no change, so a bare repo's tab never reloads for nothing.
        var (status, stashes) = await loader.StatusAndStashesAsync(Token);
        Assert.Equal(snapshot.Status, status);
        Assert.Empty(stashes);
    }

    // A shallow clone (its common dir read beside the log, the shallow check made once the first page comes) loads as
    // shallow, and a reload never reads it incrementally: the whole log again.
    [Fact]
    public async Task ShallowCloneLoadsAsShallowAndReloadsWhole()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        foreach (var subject in new[] { "second", "third" })
        {
            await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), subject + "\n", Token);
            await sandbox.GitAsync(["commit", "-q", "-am", subject], repo);
        }

        var shallow = Path.Combine(sandbox.Root, "shallow");
        await sandbox.GitAsync(["clone", "-q", "--depth", "2", new Uri(repo).AbsoluteUri, shallow], sandbox.Root);

        var loader = new RepoLoader(sandbox.Runner, shallow, sandbox.Base);
        var firstPages = new List<RepoSnapshot>();
        var snapshot = await loader.LoadAsync(
            1, LogFilter.None, [], LogReader.Order.Date, GraphLayout.Coloring.Branch,
            first => { firstPages.Add(first); return Task.CompletedTask; }, Token);
        var incremental = await loader.ReloadIncrementallyAsync(snapshot, 2, LogFilter.None, [], Token);
        var reloaded = await loader.ReloadAsync(
            snapshot, 3, LogFilter.None, [], LogReader.Order.Date, GraphLayout.Coloring.Branch, Token);

        Assert.True(snapshot.IsComplete);
        Assert.True(snapshot.IsShallow);
        Assert.True(Assert.Single(firstPages).IsShallow);
        Assert.Equal(["third", "second"], snapshot.Commits.Select(commit => commit.Subject));
        Assert.Null(incremental); // In doubt: ReloadAsync falls back to the whole log.
        Assert.True(reloaded.IsShallow);
        Assert.Equal(snapshot.Commits.Select(c => c.Hash), reloaded.Commits.Select(c => c.Hash));
    }
}

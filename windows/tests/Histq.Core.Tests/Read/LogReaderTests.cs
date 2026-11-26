// Security tests for LogReader: commit text comes from the repo, so a crafted author name or message must not forge
// graph rows, and a repo's output encoding must not break the NUL-terminated records. Key feature tests: the log
// arguments for hidden and soloed branches, built from full ref names only, a real log of the `graph` fixture with a
// branch hidden and with a branch soloed, and the incremental reload (tips, new commits, the date-order merge).
// Ported from LogReaderTests.swift at 6fa6d40.
using System.Text;

namespace Histq.Core.Tests;

public sealed class LogReaderTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    // A name or body holding a crafted record separator and fields gives no extra row and keeps the body.
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CraftedRecordIsNoRow(bool inAuthorName)
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var root = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
        var tree = await sandbox.GitAsync(["rev-parse", "HEAD^{tree}"], repo);
        // A forged record of the old `\x1e`-terminated format that repeats the root commit's hash.
        var forged = $"\u001E{root}\u001F\u001F1\u001F1\u001FForger\u001Fforger@histq.invalid\u001Fforged\u001Fforged body";
        var author = inAuthorName ? "Real" + forged : "Real Author";
        var body = inAuthorName ? "plain body" : $"line one\n{forged}\n\u001E\n{forged}\u001Etail";
        var raw = string.Join('\n',
            $"tree {tree}",
            $"parent {root}",
            $"author {author} <real@histq.invalid> 1700000000 +0000",
            "committer Real Committer <committer@histq.invalid> 1700000100 +0000",
            "",
            "crafted subject",
            "",
            body,
            "");
        var commit = await sandbox.GitAsync(
            ["hash-object", "-t", "commit", "-w", "--stdin"], repo, Encoding.UTF8.GetBytes(raw));
        await sandbox.GitAsync(["update-ref", "refs/heads/main", commit], repo);

        var env = await GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, repo, ct: Token);
        var commits = await AllAsync(LogReader.PagesAsync(sandbox.Runner, repo, env, ct: Token));

        Assert.Equal([commit, root], commits.Select(c => c.Hash)); // Exactly the two real commits, in order.
        var crafted = commits[0];
        Assert.Equal([root], crafted.Parents);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), crafted.AuthorDate);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_100), crafted.CommitterDate);
        if (!inAuthorName)
        {
            Assert.Equal("Real Author", crafted.AuthorName);
            Assert.Equal("real@histq.invalid", crafted.AuthorEmail);
            Assert.Equal("Real Committer", crafted.CommitterName);
            Assert.Equal("committer@histq.invalid", crafted.CommitterEmail);
            Assert.Equal("crafted subject", crafted.Subject);
            Assert.Equal(body, crafted.Body); // The full, unmodified body.
        }
    }

    // A repo's i18n.logOutputEncoding cannot put NUL bytes into the log records.
    [Fact]
    public async Task RepoOutputEncodingIsIgnored()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["config", "i18n.logOutputEncoding", "UTF-16LE"], repo);
        var head = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);

        var env = await GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, repo, ct: Token);
        var commits = await AllAsync(LogReader.PagesAsync(sandbox.Runner, repo, env, ct: Token));

        Assert.Equal([head], commits.Select(c => c.Hash));
        Assert.Equal("initial", commits[0].Subject);
    }

    // A hidden ref's own commits leave the log, shared ones stay, a remote's HEAD does not keep them, a tag does until
    // hidden; a glob or non-refs/ entry is ignored.
    [Fact]
    public async Task HiddenRefLeavesTheLog()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var shared = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
        await sandbox.GitAsync(["checkout", "-q", "-b", "side"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "side only"], repo);
        var sideOnly = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
        await sandbox.GitAsync(["checkout", "-q", "main"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main only"], repo);

        var env = await GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, repo, ct: Token);
        // The hashes of the whole log read with `hidden`.
        async Task<HashSet<string>> Hashes(string[] hidden) =>
            (await AllAsync(LogReader.PagesAsync(sandbox.Runner, repo, env, hidden: hidden, ct: Token)))
            .Select(c => c.Hash).ToHashSet(StringComparer.Ordinal);

        var all = await Hashes([]);
        Assert.True(all.Contains(sideOnly) && all.Contains(shared) && all.Count == 3);
        var hidden = await Hashes(["refs/heads/side"]);
        Assert.DoesNotContain(sideOnly, hidden); // The side branch's own commit is gone.
        Assert.Contains(shared, hidden); // Main still reaches the shared commit.
        Assert.Equal(2, hidden.Count);
        Assert.Equal(all, await Hashes(["refs/heads/*"])); // A glob would hide every branch.
        Assert.Equal(all, await Hashes(["heads/side", "side"])); // Only full refs/ names count.

        // A remote's HEAD is a symref the user cannot hide: hiding its branch must still drop the branch's commits.
        await sandbox.GitAsync(["update-ref", "refs/remotes/origin/main", sideOnly], repo);
        await sandbox.GitAsync(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], repo);
        var remoteHidden = await Hashes(["refs/heads/side", "refs/remotes/origin/main"]);
        Assert.DoesNotContain(sideOnly, remoteHidden); // origin/HEAD does not bring back the hidden origin/main.
        Assert.Equal(2, remoteHidden.Count);

        // A tag on the side commit keeps it, until the tag is hidden too.
        await sandbox.GitAsync(["tag", "side-tag", sideOnly], repo);
        string[] refs = ["refs/heads/side", "refs/remotes/origin/main"];
        Assert.Contains(sideOnly, await Hashes(refs)); // The tag still reaches the side commit.
        Assert.DoesNotContain(sideOnly, await Hashes([.. refs, "refs/tags/side-tag"])); // A hidden tag does not.
    }

    // No hidden or soloed ref gives the shipped arguments, with the extra revisions at the end as before.
    [Fact]
    public void EmptyHideAndSoloKeepArguments()
    {
        Assert.Equal(LogReader.Arguments, LogReader.ArgumentsFor([], []));
        var hash = new string('a', 40);
        Assert.Equal([.. LogReader.Arguments, hash], LogReader.ArgumentsFor([], [], [hash]));
        // Date order reaches git.
        Assert.Equal(
            LogReader.Arguments.Select(argument => argument == "--topo-order" ? "--date-order" : argument),
            LogReader.ArgumentsFor([], [], order: LogReader.Order.Date));
    }

    // Hidden refs, tags too, are excludes after the stash, notes, prefetch and remote HEAD excludes and before --all.
    [Fact]
    public void HiddenRefsPrecedeAll()
    {
        string[] hidden = ["--exclude=refs/heads/series", "--exclude=refs/remotes/origin/main", "--exclude=refs/tags/v1.0"];
        var args = LogReader.ArgumentsFor(["refs/heads/series", "refs/remotes/origin/main", "refs/tags/v1.0"], []);
        var all = args.ToList().IndexOf("--all");
        Assert.True(all >= 0);
        Assert.Equal(
            [
                "--exclude=refs/stash", "--exclude=refs/notes/*", "--exclude=refs/prefetch/*",
                "--exclude=refs/remotes/*/HEAD", .. hidden,
            ],
            args.Take(all).TakeLast(7));
        Assert.Equal(LogReader.Arguments, args.Where(argument => !hidden.Contains(argument)));
    }

    // Soloed refs drop --all and come after every option and --end-of-options, then HEAD, extras and --.
    [Fact]
    public void SoloRefsComeLast()
    {
        var hash = new string('b', 40);
        var args = LogReader.ArgumentsFor(
            ["refs/heads/old"], ["refs/heads/series", "refs/remotes/origin/feature"], [hash, "-x"]).ToList();
        Assert.DoesNotContain("--all", args);
        var end = args.IndexOf("--end-of-options");
        Assert.True(end >= 0);
        var options = args.Take(end).ToList();
        Assert.Contains("--topo-order", options);
        Assert.Contains(options, argument => argument.StartsWith("--format=", StringComparison.Ordinal));
        Assert.Contains("--exclude=refs/heads/old", options);
        Assert.Equal(
            ["--end-of-options", "refs/heads/series", "refs/remotes/origin/feature", "HEAD", hash, "--"],
            args.Skip(end));
    }

    // Names that are not full branch, remote or tag refs, or that git forbids, are dropped.
    [Fact]
    public void InvalidRefsAreDropped()
    {
        string[] invalid =
        [
            "main", "refs/tags/", "refs/tags/-x", "refs/tags/v1..0", "refs/heads/", "refs/heads/-x", "refs/heads/a..b",
            "refs/heads/a b",
            "refs/heads/x.lock", "refs/heads/a@{1}", "refs/heads/a~1", "refs/heads/a^", "refs/heads/a:b",
            "refs/heads/a?", "refs/heads/a*", "refs/heads/a[", "refs/heads/a\\b", "refs/heads/a\u0007",
            "refs/heads/x/", "refs/heads/a//b", "refs/heads/.x", "refs/heads/x.", "refs/remotes/origin",
            "--all", "refs/heads/a..́b", "refs/heads/a~́1",
        ];
        Assert.Equal(LogReader.Arguments, LogReader.ArgumentsFor(invalid, []));
        Assert.Equal(LogReader.Arguments, LogReader.ArgumentsFor([], invalid)); // No valid solo ref: all refs.
        Assert.Equal(
            ["--end-of-options", "refs/heads/ok", "HEAD", "--"],
            LogReader.ArgumentsFor([], [.. invalid, "refs/heads/ok"]).TakeLast(4));
        // A tag can be hidden but not soloed.
        Assert.Equal(LogReader.Arguments, LogReader.ArgumentsFor([], ["refs/tags/v1.0"]));
    }

    // Graph fixture: a hidden branch's own commits are no rows; a soloed branch shows only it and HEAD.
    [Fact]
    public async Task HideAndSoloOnGraphFixture()
    {
        using var copy = await Fixtures.CopyAsync();
        var repo = copy.Repo("graph");
        var env = await GitInvocation.ReadEnvironmentAsync(null, copy.Base, copy.Runner, repo, ct: Token);
        // A file named HEAD in the worktree must not make the soloed log's HEAD ambiguous.
        await File.WriteAllTextAsync(Path.Combine(repo, "HEAD"), "not a revision\n", Token);
        async Task<HashSet<string>> Subjects(string[]? hidden = null, string[]? solo = null) =>
            (await AllAsync(LogReader.PagesAsync(copy.Runner, repo, env, hidden: hidden, solo: solo, ct: Token)))
            .Select(c => c.Subject).ToHashSet(StringComparer.Ordinal);

        var all = await Subjects();
        var hidden = await Subjects(hidden: ["refs/heads/series"]);
        Assert.Contains("Series step 5", all);
        Assert.Equal(
            Enumerable.Range(1, 5).Select(step => $"Series step {step}").ToHashSet(StringComparer.Ordinal),
            all.Except(hidden, StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal));

        var solo = await Subjects(solo: ["refs/heads/series"]);
        Assert.Contains("Series step 5", solo);
        Assert.Contains("Bump version", solo); // HEAD (main) is kept.
        Assert.DoesNotContain("Update changelog (not pushed)", solo);
        Assert.DoesNotContain("Polish feature (pushed)", solo);
    }

    // Incremental reload.

    // Tips are the commits no other commit lists as a parent, across a merge and two branches.
    [Fact]
    public async Task TipsOfMergeAndBranches()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["checkout", "-q", "-b", "feature"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "feature one"], repo);
        await sandbox.GitAsync(["checkout", "-q", "main"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main one"], repo);
        await sandbox.GitAsync(["merge", "-q", "--no-ff", "-m", "merge", "feature"], repo);
        await sandbox.GitAsync(["checkout", "-q", "-b", "side", "HEAD~1"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "side one"], repo);
        var main = await sandbox.GitAsync(["rev-parse", "main"], repo);
        var side = await sandbox.GitAsync(["rev-parse", "side"], repo);

        var commits = await ReadAllAsync(sandbox, repo);
        var tips = LogReader.Tips(commits, Index(commits));

        Assert.Equal(5, commits.Count);
        // The merged feature branch is no tip.
        Assert.Equal(new HashSet<string>([main, side], StringComparer.Ordinal), tips.ToHashSet(StringComparer.Ordinal));
        Assert.Equal(2, tips.Count);
    }

    // A new commit on the current branch is the only new commit, and with the old ones makes a full read.
    [Fact]
    public async Task NewCommitOnCurrentBranch()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["checkout", "-q", "-b", "side"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "side one"], repo);
        await sandbox.GitAsync(["checkout", "-q", "main"], repo);
        var old = await ReadAllAsync(sandbox, repo);
        var tips = LogReader.Tips(old, Index(old));
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main two"], repo);
        var head = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);

        var delta = await NewCommitsAsync(sandbox, repo, tips);

        Assert.NotNull(delta);
        Assert.Equal([head], delta.Select(c => c.Hash));
        Assert.Equal("main two", delta[0].Subject);
        var fresh = await ReadAllAsync(sandbox, repo);
        Assert.Equal(
            fresh.Select(c => c.Hash).ToHashSet(StringComparer.Ordinal),
            delta.Concat(old).Select(c => c.Hash).ToHashSet(StringComparer.Ordinal));
        Assert.Equal(fresh.Count, delta.Count + old.Count);
    }

    // A new branch of two commits off an old commit gives both, children before parents.
    [Fact]
    public async Task NewBranchOffOldCommit()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main two"], repo);
        var tips = await TipsOfFullReadAsync(sandbox, repo);
        await sandbox.GitAsync(["checkout", "-q", "-b", "topic", "HEAD~1"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "topic one"], repo);
        var first = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "topic two"], repo);
        var second = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);

        var delta = await NewCommitsAsync(sandbox, repo, tips);

        Assert.NotNull(delta);
        Assert.Equal([second, first], delta.Select(c => c.Hash));
        Assert.Equal([first], delta[0].Parents);
    }

    // Tips updated from a delta equal the tips of the whole log.
    [Fact]
    public async Task TipsFromDelta()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["checkout", "-q", "-b", "side"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "side one"], repo);
        await sandbox.GitAsync(["checkout", "-q", "-b", "other", "main"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "other one"], repo);
        await sandbox.GitAsync(["checkout", "-q", "main"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main two"], repo);
        var oldTips = await TipsOfFullReadAsync(sandbox, repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main three"], repo);
        await sandbox.GitAsync(["merge", "-q", "--no-ff", "-m", "merge side", "side"], repo);
        await sandbox.GitAsync(["checkout", "-q", "-b", "topic", "HEAD~2"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "topic one"], repo);

        var delta = await NewCommitsAsync(sandbox, repo, oldTips);
        Assert.NotNull(delta);
        var tips = LogReader.TipsAdding(delta, oldTips);

        var fresh = await TipsOfFullReadAsync(sandbox, repo);
        Assert.Equal(3, oldTips.Count);
        Assert.Equal(3, delta.Count);
        // The merged side tip and the old main tip are gone, other stays.
        Assert.Equal(fresh.ToHashSet(StringComparer.Ordinal), tips.ToHashSet(StringComparer.Ordinal));
        Assert.Equal(fresh.Count, tips.Count);
    }

    // Date order: fetched commits older than the local tip merge where a fresh read puts them; a clock-skewed child
    // stays above its parent.
    [Fact]
    public async Task DateOrderMergesNewCommits()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var tree = await sandbox.GitAsync(["rev-parse", "HEAD^{tree}"], repo);
        // A commit of `tree` on `parent`, authored and committed `seconds` after 1970.
        async Task<string> CommitAsync(string subject, int seconds, string? parent = null)
        {
            var date = $"@{seconds} +0000";
            var env = new Dictionary<string, string>(sandbox.Base, GitRunner.EnvironmentKeyComparer)
            {
                ["GIT_AUTHOR_DATE"] = date,
                ["GIT_COMMITTER_DATE"] = date,
            };
            string[] parents = parent is null ? [] : ["-p", parent];
            var result = await sandbox.Runner.RunAsync(
                ["commit-tree", .. parents, "-m", subject, tree], repo, env, timeout: TimeSpan.FromSeconds(30), ct: Token);
            return result.Text.Trim();
        }

        // main: initial(100) -> M1(250) -> M2(450), replacing the sandbox commit dated now.
        var initial = await CommitAsync("initial", 100);
        var m1 = await CommitAsync("M1", 250, initial);
        var m2 = await CommitAsync("M2", 450, m1);
        await sandbox.GitAsync(["update-ref", "refs/heads/main", m2], repo);
        var old = await ReadAllAsync(sandbox, repo, order: LogReader.Order.Date);
        Assert.Equal([m2, m1, initial], old.Select(c => c.Hash));
        // Fetched: R1(200) -> R2(300) off initial, both older than the local tip.
        var r1 = await CommitAsync("R1", 200, initial);
        var r2 = await CommitAsync("R2", 300, r1);
        await sandbox.GitAsync(["update-ref", "refs/remotes/origin/main", r2], repo);

        var oldIndex = Index(old);
        var delta = await NewCommitsAsync(sandbox, repo, LogReader.Tips(old, oldIndex), order: LogReader.Order.Date);
        Assert.NotNull(delta);
        var merged = LogReader.MergedByDate(delta, old, oldIndex);

        string[] expected = [m2, r2, m1, r1, initial];
        // A fresh read, by date.
        Assert.Equal(expected, (await ReadAllAsync(sandbox, repo, order: LogReader.Order.Date)).Select(c => c.Hash));
        Assert.Equal(expected, merged.Select(c => c.Hash));

        // S(50), a child of M2 dated before it: still above M2, though a fresh read may list it elsewhere.
        var skewed = await CommitAsync("S", 50, m2);
        await sandbox.GitAsync(["update-ref", "refs/heads/main", skewed], repo);
        var mergedIndex = Index(merged);
        var next = await NewCommitsAsync(
            sandbox, repo, LogReader.Tips(merged, mergedIndex), order: LogReader.Order.Date);
        Assert.NotNull(next);
        var again = LogReader.MergedByDate(next, merged, mergedIndex);

        var fresh = await ReadAllAsync(sandbox, repo, order: LogReader.Order.Date);
        Assert.Equal(
            fresh.Select(c => c.Hash).ToHashSet(StringComparer.Ordinal),
            again.Select(c => c.Hash).ToHashSet(StringComparer.Ordinal));
        Assert.Equal(fresh.Count, again.Count);
        var row = Index(again);
        for (var position = 0; position < again.Count; position++)
        {
            foreach (var parent in again[position].Parents)
            {
                Assert.True(row.TryGetValue(parent, out var parentRow), "every parent is listed");
                Assert.True(parentRow > position, $"{again[position].Subject} above its parent");
            }
        }
    }

    // Nothing new gives no commit, not null.
    [Fact]
    public async Task NothingChanged()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main two"], repo);
        var tips = await TipsOfFullReadAsync(sandbox, repo);

        var delta = await NewCommitsAsync(sandbox, repo, tips);

        Assert.NotNull(delta);
        Assert.Empty(delta);
    }

    // A commit no ref reaches any more gives null: a deleted branch, a hard reset.
    [Fact]
    public async Task UnreachableOldCommit()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["checkout", "-q", "-b", "side"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "side one"], repo);
        await sandbox.GitAsync(["checkout", "-q", "main"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main two"], repo);
        var tips = await TipsOfFullReadAsync(sandbox, repo);
        await sandbox.GitAsync(["branch", "-q", "-D", "side"], repo);

        Assert.Null(await NewCommitsAsync(sandbox, repo, tips)); // The deleted branch's commit.

        var afterDelete = await TipsOfFullReadAsync(sandbox, repo);
        await sandbox.GitAsync(["reset", "-q", "--hard", "HEAD~1"], repo);

        Assert.Null(await NewCommitsAsync(sandbox, repo, afterDelete)); // The reset commit.
        Assert.Null(await NewCommitsAsync(sandbox, repo, [])); // No previous tip.
        Assert.Null(await NewCommitsAsync(sandbox, repo, ["--all"])); // A tip that is no hash.
    }

    // A stash whose base only the stash holds: no new commit while it is there, null once it is dropped.
    [Fact]
    public async Task DroppedStashBase()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["checkout", "-q", "-b", "temp"], repo);
        await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "base\n", Token);
        await sandbox.GitAsync(["commit", "-q", "-am", "stash base"], repo);
        var stashBase = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
        await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "changed\n", Token);
        await sandbox.GitAsync(["stash", "-q"], repo);
        await sandbox.GitAsync(["checkout", "-q", "main"], repo);
        await sandbox.GitAsync(["branch", "-q", "-D", "temp"], repo);
        var tips = await TipsOfFullReadAsync(sandbox, repo, [stashBase]);
        Assert.Contains(stashBase, tips); // The stash base is a tip of the old read.

        var delta = await NewCommitsAsync(sandbox, repo, tips, [stashBase]);
        Assert.NotNull(delta);
        Assert.Empty(delta);

        await sandbox.GitAsync(["stash", "drop", "-q"], repo);

        Assert.Null(await NewCommitsAsync(sandbox, repo, tips));
    }

    // A commit only a prefetch ref reaches is no row and no new commit.
    [Fact]
    public async Task PrefetchRefIsHidden()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var tips = await TipsOfFullReadAsync(sandbox, repo);
        await sandbox.GitAsync(["checkout", "-q", "-b", "side"], repo);
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "fetched"], repo);
        var fetched = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
        await sandbox.GitAsync(["update-ref", "refs/prefetch/remotes/origin/side", fetched], repo);
        await sandbox.GitAsync(["checkout", "-q", "main"], repo);
        await sandbox.GitAsync(["branch", "-q", "-D", "side"], repo);

        Assert.DoesNotContain(await ReadAllAsync(sandbox, repo), c => c.Hash == fetched);
        var delta = await NewCommitsAsync(sandbox, repo, tips);
        Assert.NotNull(delta);
        Assert.Empty(delta);
    }

    // A replace ref gives null: it can give an old commit other parents.
    [Fact]
    public async Task ReplaceRef()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["commit", "-q", "--allow-empty", "-m", "main two"], repo);
        var tips = await TipsOfFullReadAsync(sandbox, repo);
        await sandbox.GitAsync(["replace", "--graft", "HEAD"], repo);

        Assert.Null(await NewCommitsAsync(sandbox, repo, tips));
    }

    // A tip of fullwidth digits is no hash.
    [Fact]
    public async Task FullwidthTip()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");

        Assert.Null(await NewCommitsAsync(sandbox, repo, ["１２"]));
    }

    // Helpers.

    /// <summary>Every page of <paramref name="pages"/>, joined.</summary>
    internal static async Task<List<Commit>> AllAsync(IAsyncEnumerable<IReadOnlyList<Commit>> pages)
    {
        var commits = new List<Commit>();
        await foreach (var page in pages)
        {
            commits.AddRange(page);
        }

        return commits;
    }

    /// <summary>A full history read of <paramref name="repo"/> in <paramref name="order"/>, all pages joined.</summary>
    private static async Task<List<Commit>> ReadAllAsync(
        Sandbox sandbox, string repo, string[]? alsoFrom = null, LogReader.Order order = LogReader.Order.Branch)
    {
        var env = await GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, repo, ct: Token);
        return await AllAsync(LogReader.PagesAsync(sandbox.Runner, repo, env, alsoFrom: alsoFrom, order: order, ct: Token));
    }

    /// <summary>The tips of a full read of <paramref name="repo"/>, as the app takes them from its log.</summary>
    private static async Task<IReadOnlyList<string>> TipsOfFullReadAsync(
        Sandbox sandbox, string repo, string[]? alsoFrom = null)
    {
        var commits = await ReadAllAsync(sandbox, repo, alsoFrom);
        return LogReader.Tips(commits, Index(commits));
    }

    /// <summary><see cref="LogReader.NewCommitsAsync"/> for <paramref name="repo"/> with its read environment.</summary>
    private static async Task<IReadOnlyList<Commit>?> NewCommitsAsync(
        Sandbox sandbox, string repo, IReadOnlyList<string> previousTips, string[]? alsoFrom = null,
        LogReader.Order order = LogReader.Order.Branch)
    {
        var env = await GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, repo, ct: Token);
        return await LogReader.NewCommitsAsync(
            sandbox.Runner, repo, env, previousTips, alsoFrom, order: order, ct: Token);
    }

    /// <summary><paramref name="commits"/>' index of each hash, as the app's log keeps it.</summary>
    private static Dictionary<string, int> Index(IReadOnlyList<Commit> commits) =>
        commits.Select((commit, position) => (commit.Hash, position))
            .ToDictionary(pair => pair.Hash, pair => pair.position, StringComparer.Ordinal);
}

// Key feature tests for RepoWatcher on a linked worktree (its git dir differs from the common dir): the folders come
// from rev-parse run with the read environment; a change in the worktree, the git dir or the common dir's refs gives
// exactly one debounced refresh of the right scope; objects, git's lock files and Histq's own state folder are
// ignored. Security: a git dir or common dir on a network share or device path (the repo's `.git` or `commondir` file
// names it) is refused before any file system call. Ported from RepoWatcher.swift at 6fa6d40.
using System.Collections.Concurrent;

namespace Histq.Core.Tests;

public sealed class RepoWatcherTests
{
    /// <summary>Long enough for the file system to deliver a change and the 250 ms debounce to pass, with margin.</summary>
    private static readonly TimeSpan Settle = TimeSpan.FromSeconds(2);

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    [Fact]
    public async Task WatchesWorktreeGitDirAndCommonDir()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var linked = Path.Combine(sandbox.Root, "linked");
        await sandbox.GitAsync(["worktree", "add", "-q", "-b", "linked", linked], repo);
        var env = await GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, linked, ct: Token);
        var directories = await RepoDirectories.ResolveAsync(sandbox.Runner, linked, env, Token);
        var commonDir = Path.Combine(repo, ".git");
        Assert.Equal(new RepoDirectories(linked, Path.Combine(commonDir, "worktrees", "linked"), commonDir), directories);

        var state = Path.Combine(linked, "state");
        Directory.CreateDirectory(state);
        var events = new ConcurrentQueue<(RefreshScope Scope, IReadOnlyList<string>? Paths)>();
        using var watcher = new RepoWatcher(state);
        watcher.Start(directories, (scope, paths) => events.Enqueue((scope, paths)));
        await Task.Delay(Settle, Token); // The watchers are running before the first write.
        events.Clear();

        // Ignored: an object, git's lock files, Histq's own files.
        Directory.CreateDirectory(Path.Combine(commonDir, "objects", "ab"));
        await File.WriteAllTextAsync(Path.Combine(commonDir, "objects", "ab", "cdef"), "x", Token);
        await File.WriteAllTextAsync(Path.Combine(commonDir, "refs", "heads", "main.lock"), "x", Token);
        await File.WriteAllTextAsync(Path.Combine(directories.GitDir, "index.lock"), "x", Token);
        await File.WriteAllTextAsync(Path.Combine(state, "refresh.log"), "x", Token);
        await Task.Delay(Settle, Token);
        Assert.Empty(events);

        // One worktree file written in a burst: one status refresh naming it.
        var file = Path.Combine(linked, "notes.txt");
        for (var i = 0; i < 3; i++)
        {
            await File.WriteAllTextAsync(file, $"draft {i}\n", Token);
            await Task.Delay(30, Token);
        }

        var change = await OneAsync(events);
        Assert.Equal(RefreshScope.Status, change.Scope);
        Assert.Equal(["notes.txt"], change.Paths);

        // The linked worktree's own git dir: its HEAD.
        var head = Path.Combine(directories.GitDir, "HEAD");
        await File.WriteAllTextAsync(head, await File.ReadAllTextAsync(head, Token), Token);
        Assert.Equal(RefreshScope.Refs, (await OneAsync(events)).Scope);

        // The common dir: a ref, then packed-refs.
        var main = Path.Combine(commonDir, "refs", "heads", "main");
        await File.WriteAllTextAsync(main, await File.ReadAllTextAsync(main, Token), Token);
        Assert.Equal(RefreshScope.Refs, (await OneAsync(events)).Scope);
        await File.WriteAllTextAsync(Path.Combine(commonDir, "packed-refs"), "# pack-refs with: peeled\n", Token);
        Assert.Equal(RefreshScope.Refs, (await OneAsync(events)).Scope);
    }

    // A UNC or device path in rev-parse's output, or a real path that leads to one, is refused; the share is never
    // touched.
    [Theory]
    [InlineData(@"\\server\share\main\.git\worktrees\w", @"C:/main/.git", null)]
    [InlineData("//server/share/main/.git/worktrees/w", @"C:/main/.git", null)]
    [InlineData(@"C:/main/.git/worktrees/w", @"\\?\C:\main\.git", null)]
    [InlineData(@"C:/main/.git/worktrees/w", @"\\.\pipe\x", null)]
    [InlineData(@"C:/main/.git/worktrees/w", @"C:/main/.git", @"\\server\share\main\.git")]
    public void RefusesNetworkGitDirs(string gitDir, string commonDir, string? linkedTo)
    {
        var probed = new List<string>();
        string? RealPath(string path)
        {
            probed.Add(path);
            return linkedTo is not null && path == StashWorktreeReader.NativePath(commonDir) ? linkedTo : path;
        }

        var output = $"C:/w\n{gitDir}\n{commonDir}\n";
        Assert.Throws<GitError>(() => RepoDirectories.Parse(output, 0, PathFlavor.Windows, RealPath));
        Assert.DoesNotContain(probed, path => PathFlavor.Windows.IsUncOrDevice(path));
        // The same layout on local paths resolves (made native on Windows).
        Assert.Equal(
            new RepoDirectories(
                StashWorktreeReader.NativePath("C:/w"), StashWorktreeReader.NativePath("C:/main/.git/worktrees/w"),
                StashWorktreeReader.NativePath("C:/main/.git")),
            RepoDirectories.Parse("C:/w\nC:/main/.git/worktrees/w\nC:/main/.git\n", 0, PathFlavor.Windows, path => path));
    }

    /// <summary>Waits for the next refresh, then checks no second one follows for the same change.</summary>
    private static async Task<(RefreshScope Scope, IReadOnlyList<string>? Paths)> OneAsync(
        ConcurrentQueue<(RefreshScope Scope, IReadOnlyList<string>? Paths)> events)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (events.IsEmpty && DateTime.UtcNow < deadline)
        {
            await Task.Delay(50, Token);
        }

        await Task.Delay(Settle, Token);
        var change = Assert.Single(events);
        events.Clear();
        return change;
    }
}

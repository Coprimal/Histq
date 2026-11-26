// Security tests for GitInvocation: the profile reaches git and ssh intact, and an automatic read in a hostile repo
// (its `.git/config`, `.git/info/attributes`, hooks, submodules) runs none of the commands the repo configures. Every
// marker case first proves, with the plain (write) environment, that its repo does run the marker script, so a passing
// guard means the override works, not that the fixture never fires. The read environment cache must never return
// drivers that are out of date. Ported from GitInvocationTests.swift at 6fa6d40 (read and write cases only; the network,
// token, credential and terminal cases come with the network milestone).
using System.Globalization;
using System.Text;

namespace Histq.Core.Tests;

public sealed class GitInvocationTests
{
    internal static readonly Profile TestProfile =
        new("Work", "#E5B13A", new ProfileIdentity("Profile Person", "profile@histq.invalid"));

    /// <summary>The automatic status read (StatusReader) and the WIP diff (the diff loaders).</summary>
    private static IReadOnlyList<string> StatusRead => StatusReader.Arguments;

    private static readonly string[] WipDiffRead = ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty"];

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    // Profile injection.

    // The profile identity wins over the repo's own user.*, author.* and committer.* config.
    [Fact]
    public async Task ProfileIdentityWinsOverRepoConfig()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        await sandbox.GitAsync(["config", "author.name", "Repo Author"], repo);
        await sandbox.GitAsync(["config", "committer.email", "committer@repo.invalid"], repo);

        var plain = GitInvocation.Environment(null, sandbox.Base);
        var repoAuthor = (await sandbox.Runner.RunAsync(["var", "GIT_AUTHOR_IDENT"], repo, plain, ct: Token)).Text;
        Assert.StartsWith("Repo Author <local@histq.invalid> ", repoAuthor, StringComparison.Ordinal);

        var write = GitInvocation.Environment(TestProfile, sandbox.Base);
        var read = await GitInvocation.ReadEnvironmentAsync(TestProfile, sandbox.Base, sandbox.Runner, repo, ct: Token);
        foreach (var env in new[] { write, read })
        {
            foreach (var variable in new[] { "GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT" })
            {
                var ident = (await sandbox.Runner.RunAsync(["var", variable], repo, env, ct: Token)).Text;
                Assert.True(
                    ident.StartsWith("Profile Person <profile@histq.invalid> ", StringComparison.Ordinal),
                    $"{variable}: {ident}");
            }
        }
    }

    /// <summary>The identity keys of <paramref name="env"/>'s command-scope config, in order.</summary>
    private static List<string> IdentityEntries(IReadOnlyDictionary<string, string> env) =>
        ConfigEntries(env).Where(entry =>
            new[] { "user.name=", "user.email=", "author.", "committer." }
                .Any(prefix => entry.StartsWith(prefix, StringComparison.Ordinal))).ToList();

    /// <summary>The command-scope config entries of <paramref name="env"/>, in order, as <c>key=value</c>.</summary>
    internal static List<string> ConfigEntries(IReadOnlyDictionary<string, string> env)
    {
        var count = env.TryGetValue("GIT_CONFIG_COUNT", out var text)
                    && int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : 0;
        return Enumerable.Range(0, count)
            .Select(index => $"{env.GetValueOrDefault($"GIT_CONFIG_KEY_{index}")}={env.GetValueOrDefault($"GIT_CONFIG_VALUE_{index}")}")
            .ToList();
    }

    public static TheoryData<string, string, string[]> IdentityCases => new()
    {
        { "", "", [] },
        { " \t", "\n ", [] },
        { "Profile Person", "", ["user.name=Profile Person", "author.name=Profile Person", "committer.name=Profile Person"] },
        {
            "  ", "profile@histq.invalid",
            ["user.email=profile@histq.invalid", "author.email=profile@histq.invalid", "committer.email=profile@histq.invalid"]
        },
        {
            "Profile Person", "profile@histq.invalid",
            [
                "user.name=Profile Person", "user.email=profile@histq.invalid",
                "author.name=Profile Person", "author.email=profile@histq.invalid",
                "committer.name=Profile Person", "committer.email=profile@histq.invalid",
            ]
        },
    };

    // An empty or blank profile name or email passes no key for it in the write environment.
    [Theory]
    [MemberData(nameof(IdentityCases))]
    public void IdentityConfigSkipsEmptyFields(string name, string email, string[] expected)
    {
        var profile = new Profile("Work", "#E5B13A", new ProfileIdentity(name, email));
        var write = GitInvocation.Environment(profile, new Dictionary<string, string>());
        Assert.Equal(expected, IdentityEntries(write));
    }

    // Git falls back to its own config for what the profile leaves empty, never an empty ident.
    [Fact]
    public async Task EmptyProfileIdentityFallsBackToGitConfig()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        (string Name, string Email, string Ident)[] cases =
        [
            ("", "", "Repo Local <local@histq.invalid> "),
            ("Profile Person", " ", "Profile Person <local@histq.invalid> "),
            ("", "profile@histq.invalid", "Repo Local <profile@histq.invalid> "),
        ];
        foreach (var (name, email, expected) in cases)
        {
            var profile = new Profile("Work", "#E5B13A", new ProfileIdentity(name, email));
            var env = GitInvocation.Environment(profile, sandbox.Base);
            foreach (var variable in new[] { "GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT" })
            {
                var ident = (await sandbox.Runner.RunAsync(["var", variable], repo, env, ct: Token)).Text;
                Assert.True(
                    ident.StartsWith(expected, StringComparison.Ordinal), $"{variable} for ({name}, {email}): {ident}");
            }
        }
    }

    // An SSH key path with a space and a single quote reaches ssh as one -i argument.
    [Fact]
    public async Task SshKeyPathIsOneArgument()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var keyPath = Path.Combine(sandbox.Root, "my key's dir", "id_ed25519");
        var profile = TestProfile with { Ssh = new ProfileSshKey.KeyFile(keyPath) };
        var env = GitInvocation.Environment(profile, sandbox.Base);
        var command = env["GIT_SSH_COMMAND"];

        // Git runs GIT_SSH_COMMAND through its sh (`sh -c`); a fake `ssh` function prints its argv NUL-separated.
        var shell = new GitRunner(OperatingSystem.IsWindows() ? await Fixtures.BashAsync() : "/bin/sh");
        var output = await shell.RunAsync(
            ["-c", "ssh() { printf '%s\\0' \"$@\"; }\n" + command], sandbox.Root, sandbox.Base,
            timeout: TimeSpan.FromSeconds(10), ct: Token);
        var argv = output.Text.Split('\0')[..^1];
        Assert.Equal(["-o", "BatchMode=yes", "-i", Fixtures.ShellPath(keyPath), "-o", "IdentitiesOnly=yes"], argv);
    }

    public static TheoryData<string, string> BlankSigningKeys => new()
    {
        { "gpg", "" }, { "gpg", "  " }, { "ssh", "" }, { "ssh", " \n" },
    };

    // A signing method with a blank key and sign-by-default gives git no user.signingKey and no signing.
    [Theory]
    [MemberData(nameof(BlankSigningKeys))]
    public async Task BlankSigningKeyDoesNotSign(string method, string key)
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        ProfileSigning signing = method == "gpg" ? new ProfileSigning.Gpg(key) : new ProfileSigning.Ssh(key);
        var profile = TestProfile with { Signing = signing, SignByDefault = true };
        var env = GitInvocation.Environment(profile, sandbox.Base);

        // Exit 1: the key is not set in any scope.
        var signingKey = await sandbox.Runner.RunAsync(
            ["config", "--get", "user.signingKey"], repo, env, allowedExitCodes: [0, 1], ct: Token);
        Assert.True(signingKey.ExitCode == 1, $"user.signingKey: {signingKey.Text}");
        var sign = await sandbox.Runner.RunAsync(["config", "--get", "commit.gpgSign"], repo, env, ct: Token);
        Assert.Equal("false", sign.Text.Trim());
    }

    // Untrusted repo config.

    // A repo's core.fsmonitor hook does not run during a read.
    [Fact]
    public Task FsmonitorHookDoesNotRun() =>
        ExpectReadsRunNothing(
            controls: [_ => ["status"]], reads: [_ => StatusRead],
            build: async sandbox =>
            {
                var repo = await sandbox.MakeRepoAsync("repo");
                await sandbox.GitAsync(["config", "core.fsmonitor", sandbox.EvilCommand], repo);
                return new Built(repo);
            });

    // A filter driver named by .git/info/attributes does not run on a stat-dirty file during a read.
    [Theory]
    [InlineData("clean", "evil")]
    [InlineData("process", "evil")]
    [InlineData("clean", "́evil.x")]
    public Task FilterDriverDoesNotRun(string variable, string driver) =>
        ExpectReadsRunNothing(
            controls: [_ => ["status"], _ => ["diff"]], reads: [_ => StatusRead, _ => WipDiffRead],
            build: async sandbox =>
            {
                var repo = await sandbox.MakeRepoAsync("repo");
                await sandbox.GitAsync(["config", $"filter.{driver}.{variable}", sandbox.EvilCommand], repo);
                await File.WriteAllTextAsync(Path.Combine(repo, ".git", "info", "attributes"), $"* filter={driver}\n", Token);
                Sandbox.MakeStatDirty(Path.Combine(repo, "tracked.txt"));
                return new Built(repo);
            });

    // A read fails closed when the config names a filter or diff driver that is not valid UTF-8.
    [Theory]
    [InlineData("filter", GitInvocation.ReadSafetyErrorKind.FilterDriverNotUTF8)]
    [InlineData("diff", GitInvocation.ReadSafetyErrorKind.DiffDriverNotUTF8)]
    public async Task NonUTF8DriverFailsClosed(string section, GitInvocation.ReadSafetyErrorKind kind)
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        // No environment string can carry this name, so its override cannot be expressed.
        using (var config = new FileStream(Path.Combine(repo, ".git", "config"), FileMode.Append))
        {
            config.Write(Encoding.UTF8.GetBytes($"[{section} \""));
            config.Write([0xFF, 0xFE]);
            config.Write("\"]\n\tx = y\n"u8);
        }

        foreach (var cache in new[] { null, new ReadEnvironmentCache() })
        {
            var error = await Assert.ThrowsAsync<GitInvocation.ReadSafetyError>(() =>
                GitInvocation.ReadEnvironmentAsync(TestProfile, sandbox.Base, sandbox.Runner, repo, cache, Token));
            Assert.Equal(kind, error.Kind);
        }
    }

    // A populated submodule's own clean filter does not run during a read.
    [Fact]
    public Task SubmoduleFilterDoesNotRun() =>
        // The control drops --ignore-submodules=dirty: that flag is the guard here, since the submodule's filters are
        // not configured in the superproject and so are not listed by the read environment.
        ExpectReadsRunNothing(
            controls: [_ => ["status"], _ => ["diff"]], reads: [_ => StatusRead, _ => WipDiffRead],
            build: async sandbox =>
            {
                var source = await sandbox.MakeRepoAsync("sub-source");
                await File.WriteAllTextAsync(Path.Combine(source, ".gitattributes"), "* filter=evil\n", Token);
                await sandbox.GitAsync(["add", ".gitattributes"], source);
                await sandbox.GitAsync(["commit", "-q", "-m", "attributes"], source);
                var repo = await sandbox.MakeRepoAsync("super");
                var sub = await sandbox.AddSubmoduleAsync(source, "sub", repo);
                await sandbox.GitAsync(["config", "filter.evil.clean", sandbox.EvilCommand], sub);
                Sandbox.MakeStatDirty(Path.Combine(sub, "tracked.txt"));
                return new Built(repo);
            });

    // A repo's gpg.program does not run for a signed stash commit with log.showSignature set.
    [Fact]
    public Task SignatureProgramDoesNotRun()
    {
        Func<Built, IReadOnlyList<string>> show = built => ["show", "--no-ext-diff", "--no-textconv", built.Revs[0]];
        return ExpectReadsRunNothing(
            controls: [_ => ["stash", "list"], show], reads: [_ => ["stash", "list"], show],
            build: async sandbox =>
            {
                var repo = await sandbox.MakeRepoAsync("repo");
                await sandbox.GitAsync(["config", "log.showSignature", "true"], repo);
                await sandbox.GitAsync(["config", "gpg.program", sandbox.EvilCommand], repo);
                var tree = await sandbox.GitAsync(["rev-parse", "HEAD^{tree}"], repo);
                var parent = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
                var commit = string.Join('\n',
                    $"tree {tree}",
                    $"parent {parent}",
                    "author Repo Local <local@histq.invalid> 1700000000 +0000",
                    "committer Repo Local <local@histq.invalid> 1700000000 +0000",
                    "gpgsig -----BEGIN PGP SIGNATURE-----",
                    " iQEzBAABCAAdFiEEZmFrZWZha2VmYWtlZmFrZWZha2U=",
                    " =fake",
                    " -----END PGP SIGNATURE-----",
                    "",
                    "On main: signed stash",
                    "");
                var sha = await sandbox.GitAsync(
                    ["hash-object", "-t", "commit", "-w", "--stdin"], repo, Encoding.UTF8.GetBytes(commit));
                await sandbox.GitAsync(
                    ["update-ref", "--create-reflog", "-m", "On main: signed stash", "refs/stash", sha], repo);
                return new Built(repo, [sha]);
            });
    }

    // A submodule's diff.external does not run when the superproject sets diff.submodule=diff.
    [Fact]
    public Task SubmoduleExternalDiffDoesNotRun()
    {
        Func<Built, IReadOnlyList<string>> show = built => ["show", "--no-ext-diff", "--no-textconv", built.Revs[1]];
        Func<Built, IReadOnlyList<string>> diff =
            built => ["diff", "--no-ext-diff", "--no-textconv", built.Revs[0], built.Revs[1]];
        return ExpectReadsRunNothing(
            controls: [show, diff], reads: [show, diff],
            build: async sandbox =>
            {
                var source = await sandbox.MakeRepoAsync("sub-source");
                var repo = await sandbox.MakeRepoAsync("super");
                var sub = await sandbox.AddSubmoduleAsync(source, "sub", repo);
                var before = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
                await sandbox.GitAsync(["config", "user.name", "Repo Local"], sub);
                await sandbox.GitAsync(["config", "user.email", "local@histq.invalid"], sub);
                await File.WriteAllTextAsync(Path.Combine(sub, "tracked.txt"), "changed\n", Token);
                await sandbox.GitAsync(["commit", "-q", "-a", "-m", "change"], sub);
                await sandbox.GitAsync(["commit", "-q", "-a", "-m", "bump sub"], repo);
                var after = await sandbox.GitAsync(["rev-parse", "HEAD"], repo);
                await sandbox.GitAsync(["config", "diff.submodule", "diff"], repo);
                await sandbox.GitAsync(["config", "diff.external", sandbox.EvilCommand], sub);
                return new Built(repo, [before, after]);
            });
    }

    // A repo's diff.external does not run for a porcelain diff during a read.
    [Fact]
    public Task ExternalDiffDoesNotRun() =>
        // The read omits --no-ext-diff, so the override is the guard (the read then fails: it may).
        ExpectReadsRunNothing(
            controls: [_ => ["diff"]], reads: [_ => ["diff"]], readsMayFail: true,
            build: async sandbox =>
            {
                var repo = await sandbox.MakeRepoAsync("repo");
                await sandbox.GitAsync(["config", "diff.external", sandbox.EvilCommand], repo);
                await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "changed\n", Token);
                return new Built(repo);
            });

    // A diff driver named by .git/info/attributes does not run during a read.
    [Theory]
    [InlineData("textconv", "evil")]
    [InlineData("command", "evil")]
    [InlineData("textconv", "́evil.x")]
    public Task DiffDriverDoesNotRun(string variable, string driver)
    {
        // The reads omit --no-ext-diff and --no-textconv, so the overrides are the guard (a read may fail).
        Func<Built, IReadOnlyList<string>> show = _ => ["show", "HEAD"];
        List<Func<Built, IReadOnlyList<string>>> controls = [_ => ["diff"]];
        if (variable == "textconv")
        {
            controls.Add(show);
        }

        return ExpectReadsRunNothing(
            controls: [.. controls], reads: [_ => ["diff"], show, _ => ["log", "-p"]], readsMayFail: true,
            build: async sandbox =>
            {
                var repo = await sandbox.MakeRepoAsync("repo");
                await sandbox.GitAsync(["config", $"diff.{driver}.{variable}", sandbox.EvilCommand], repo);
                await File.WriteAllTextAsync(Path.Combine(repo, ".git", "info", "attributes"), $"* diff={driver}\n", Token);
                await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "changed\n", Token);
                return new Built(repo);
            });
    }

    // A filter driver and a diff driver in the repo config are both disabled by one read environment.
    [Fact]
    public Task FilterAndDiffDriversFromOneListing()
    {
        // Each control fires one driver only: status runs the clean filter on the stat-dirty file, show runs the
        // textconv; the reads omit --no-ext-diff and --no-textconv, so the overrides are the guard.
        Func<Built, IReadOnlyList<string>> show = _ => ["show", "HEAD"];
        return ExpectReadsRunNothing(
            controls: [_ => ["status"], show], reads: [_ => StatusRead, show, _ => ["diff"]], readsMayFail: true,
            build: async sandbox =>
            {
                var repo = await sandbox.MakeRepoAsync("repo");
                await sandbox.GitAsync(["config", "filter.evilfilter.clean", sandbox.EvilCommand], repo);
                await sandbox.GitAsync(["config", "diff.evildiff.textconv", sandbox.EvilCommand], repo);
                await File.WriteAllTextAsync(
                    Path.Combine(repo, ".git", "info", "attributes"), "* filter=evilfilter diff=evildiff\n", Token);
                Sandbox.MakeStatDirty(Path.Combine(repo, "tracked.txt"));
                return new Built(repo);
            });
    }

    // A partial clone's promisor remote does not fetch a missing blob or branch tip through its uploadpack during a
    // read, with each guard alone too.
    [Theory]
    [InlineData(null)]
    [InlineData("GIT_NO_LAZY_FETCH")]
    [InlineData("GIT_ALLOW_PROTOCOL")]
    public Task LazyFetchDoesNotRun(string? withoutVariable)
    {
        // Each guard alone must hold: without GIT_NO_LAZY_FETCH (as on git < 2.44) the transport block stops the fetch,
        // and without the transport block GIT_NO_LAZY_FETCH does. The repo allows the file protocol itself, which beats
        // a command-scope `protocol.allow=never`. The read fails on the missing objects: it may. The shipped log and
        // ref reads touch the branch whose tip is missing.
        Func<Built, IReadOnlyList<string>> show = built => ["show", "--no-ext-diff", "--no-textconv", built.Revs[0]];
        Func<Built, IReadOnlyList<string>>[] shipped = [_ => LogReader.Arguments, _ => RefReader.Arguments];
        return ExpectReadsRunNothing(
            controls: [show, .. shipped], reads: [show, .. shipped], readsMayFail: true,
            withoutVariable: withoutVariable,
            build: async sandbox =>
            {
                var source = await sandbox.MakeRepoAsync("source");
                await File.WriteAllTextAsync(Path.Combine(source, "remote-only.txt"), "only in the source\n", Token);
                await sandbox.GitAsync(["add", "remote-only.txt"], source);
                await sandbox.GitAsync(["commit", "-q", "-m", "remote only"], source);
                var blob = await sandbox.GitAsync(["rev-parse", "HEAD:remote-only.txt"], source);
                var repo = await sandbox.MakeRepoAsync("repo");
                foreach (var (key, value) in new[]
                         {
                             ("core.repositoryformatversion", "1"), ("extensions.partialClone", "origin"),
                             ("remote.origin.url", Fixtures.ShellPath(source)), ("remote.origin.promisor", "true"),
                             ("remote.origin.uploadpack", sandbox.EvilCommand), ("protocol.file.allow", "always"),
                         })
                {
                    await sandbox.GitAsync(["config", key, value], repo);
                }

                var tree = await sandbox.GitAsync(
                    ["mktree", "--missing"], repo, Encoding.UTF8.GetBytes($"100644 blob {blob}\tremote-only.txt\n"));
                var commit = await sandbox.GitAsync(["commit-tree", "-m", "missing blob", tree], repo);
                // A branch whose tip commit only the source has (`update-ref` would refuse it).
                var sourceHead = await sandbox.GitAsync(["rev-parse", "HEAD"], source);
                await File.WriteAllTextAsync(Path.Combine(repo, ".git", "refs", "heads", "gone"), sourceHead + "\n", Token);
                return new Built(repo, [commit]);
            });
    }

    // A post-index-change hook does not run and the index is not written by a read on a stat-dirty file.
    [Fact]
    public Task IndexIsNotRefreshedByRead() =>
        ExpectReadsRunNothing(
            controls: [_ => ["diff"]], reads: [_ => StatusRead, _ => WipDiffRead],
            build: async sandbox =>
            {
                var repo = await sandbox.MakeRepoAsync("repo");
                Fixtures.WriteScript(
                    $"touch '{Fixtures.ShellPath(sandbox.Marker)}'", Path.Combine(repo, ".git", "hooks", "post-index-change"));
                Sandbox.MakeStatDirty(Path.Combine(repo, "tracked.txt"));
                return new Built(repo);
            });

    // Harness.

    /// <summary>
    /// For each control, a fresh repo from <paramref name="build"/> runs the marker with the plain (write) environment.
    /// Then a fresh repo runs every read, in order, with the read environment (less <paramref name="withoutVariable"/>,
    /// to test one guard alone): no marker after any of them, each exits 0 (any code if <paramref name="readsMayFail"/>),
    /// and <c>.git/index</c> is never rewritten.
    /// </summary>
    private static async Task ExpectReadsRunNothing(
        Func<Built, IReadOnlyList<string>>[] controls, Func<Built, IReadOnlyList<string>>[] reads,
        Func<Sandbox, Task<Built>> build, bool readsMayFail = false, string? withoutVariable = null)
    {
        foreach (var control in controls)
        {
            using var controlSandbox = await Sandbox.CreateAsync();
            var controlBuilt = await build(controlSandbox);
            var args = control(controlBuilt);
            Assert.False(controlSandbox.MarkerExists, "the setup itself ran the marker");
            var plain = GitInvocation.Environment(TestProfile, controlSandbox.Base);
            // A control may fail once its marker script exits 1; only the marker matters.
            try
            {
                await controlSandbox.Runner.RunAsync(
                    args, controlBuilt.Repo, plain, timeout: TimeSpan.FromSeconds(30), allowedExitCodes: Sandbox.AnyExit,
                    ct: Token);
            }
            catch (GitError)
            {
            }

            Assert.True(controlSandbox.MarkerExists, $"positive control: `git {string.Join(' ', args)}` must run the marker");
        }

        using var sandbox = await Sandbox.CreateAsync();
        var built = await build(sandbox);
        var index = Path.Combine(built.Repo, ".git", "index");
        var indexDate = File.GetLastWriteTimeUtc(index);
        var env = await GitInvocation.ReadEnvironmentAsync(TestProfile, sandbox.Base, sandbox.Runner, built.Repo, ct: Token);
        // The cache's own listing (`--show-origin --list`) must find the same drivers.
        var cached = await GitInvocation.ReadEnvironmentAsync(
            TestProfile, sandbox.Base, sandbox.Runner, built.Repo, new ReadEnvironmentCache(), Token);
        AssertSameEnvironment(env, cached, "the cached read environment differs from the listed one");
        if (withoutVariable is not null)
        {
            Assert.True(env.Remove(withoutVariable), $"the read environment sets {withoutVariable}");
        }

        foreach (var read in reads)
        {
            var args = read(built);
            await sandbox.Runner.RunAsync(
                args, built.Repo, env, timeout: TimeSpan.FromSeconds(30), allowedExitCodes: readsMayFail ? Sandbox.AnyExit : [0],
                ct: Token);
            Assert.False(sandbox.MarkerExists, $"`git {string.Join(' ', args)}` ran the marker");
            Assert.True(File.GetLastWriteTimeUtc(index) == indexDate, $"`git {string.Join(' ', args)}` wrote the index");
        }
    }

    /// <summary>The two environments hold the same variables with the same values.</summary>
    internal static void AssertSameEnvironment(
        IReadOnlyDictionary<string, string> expected, IReadOnlyDictionary<string, string> actual, string message)
    {
        var differing = expected.Keys.Concat(actual.Keys).Distinct(StringComparer.Ordinal)
            .Where(key => !(expected.TryGetValue(key, out var left) && actual.TryGetValue(key, out var right)
                            && string.Equals(left, right, StringComparison.Ordinal)))
            .ToList();
        Assert.True(differing.Count == 0, $"{message}: {string.Join(", ", differing)}");
    }
}

/// <summary>
/// Read environment cache tests: a hit runs no git process, and anything that could change the drivers (a config
/// written later, an include, a branch switch, a broken git dir, a repointed link) is a miss. Their own class, so their
/// 2 s waits (a file changed less than 2 s before a listing is never cached) run beside the other tests.
/// </summary>
public sealed class ReadEnvironmentCacheTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private static readonly TimeSpan RaceMargin = TimeSpan.FromMilliseconds(2100);

    /// <summary>Where a filter driver configured after the cache was filled comes from.</summary>
    public enum DriverOrigin
    {
        RepoConfig,
        WorktreeConfig,
        GlobalCreated,
        RelativeInclude,
        IncludeIfGitdir,
        OnBranchInclude,
    }

    // A cache hit runs no git process, and a filter driver configured after the fill is still neutralised.
    [Theory]
    [InlineData(DriverOrigin.RepoConfig)]
    [InlineData(DriverOrigin.WorktreeConfig)]
    [InlineData(DriverOrigin.GlobalCreated)]
    [InlineData(DriverOrigin.RelativeInclude)]
    [InlineData(DriverOrigin.IncludeIfGitdir)]
    [InlineData(DriverOrigin.OnBranchInclude)]
    public async Task CacheSeesNewDriver(DriverOrigin origin)
    {
        using var sandbox = await Sandbox.CreateAsync();
        var (counted, count) = sandbox.CountingRunner();
        var repo = await sandbox.MakeRepoAsync("repo");
        var evil = sandbox.EvilCommand;
        var @base = new Dictionary<string, string>(sandbox.Base, GitRunner.EnvironmentKeyComparer);
        var cwd = repo;
        string Named(string name) => Path.Combine(sandbox.Root, name);
        switch (origin)
        {
            case DriverOrigin.RepoConfig:
                break;
            case DriverOrigin.WorktreeConfig:
                await sandbox.GitAsync(["config", "extensions.worktreeConfig", "true"], repo);
                cwd = Path.Combine(sandbox.Root, "linked");
                await sandbox.GitAsync(["worktree", "add", "-q", cwd], repo);
                break;
            case DriverOrigin.GlobalCreated:
                @base.Remove("GIT_CONFIG_GLOBAL");
                break;
            case DriverOrigin.RelativeInclude:
                await sandbox.GitAsync(["config", "-f", Named("included.cfg"), "core.abbrev", "12"], sandbox.Root);
                await sandbox.GitAsync(["config", "include.path", "../../included.cfg"], repo);
                break;
            case DriverOrigin.IncludeIfGitdir:
                // The target is absent when the cache is filled: creating it must invalidate. A pattern, since the
                // temp folder's path and the git dir's real path may differ (the Mac's /private).
                await sandbox.GitAsync(
                    ["config", "includeIf.gitdir:**/repo/.git.path", Fixtures.ShellPath(Named("gitdir.cfg"))], repo);
                break;
            case DriverOrigin.OnBranchInclude:
                await sandbox.GitAsync(["config", "-f", Named("branch.cfg"), "filter.evil.clean", evil], sandbox.Root);
                await sandbox.GitAsync(["config", "includeIf.onbranch:x.path", "../../branch.cfg"], repo);
                break;
        }

        // A file changed less than 2 s before a listing is never cached.
        await Task.Delay(RaceMargin, Token);
        var cache = new ReadEnvironmentCache();
        Task<Dictionary<string, string>> Read() =>
            GitInvocation.ReadEnvironmentAsync(null, @base, counted, cwd, cache, Token);
        var filled = await Read();
        Assert.False(filled.ContainsValue("filter.evil.clean"));
        var processes = count();
        Assert.True(processes > 0);
        GitInvocationTests.AssertSameEnvironment(filled, await Read(), "a hit returns the same environment");
        Assert.True(count() == processes, "a hit runs no git process");

        switch (origin)
        {
            case DriverOrigin.RepoConfig:
                await sandbox.GitAsync(["config", "filter.evil.clean", evil], repo);
                break;
            case DriverOrigin.WorktreeConfig:
                await sandbox.GitAsync(["config", "--worktree", "filter.evil.clean", evil], cwd);
                break;
            case DriverOrigin.GlobalCreated:
                await sandbox.GitAsync(
                    ["config", "-f", Path.Combine(sandbox.Root, "home", ".gitconfig"), "filter.evil.clean", evil],
                    sandbox.Root);
                break;
            case DriverOrigin.RelativeInclude:
                await sandbox.GitAsync(["config", "-f", Named("included.cfg"), "filter.evil.clean", evil], sandbox.Root);
                break;
            case DriverOrigin.IncludeIfGitdir:
                await sandbox.GitAsync(["config", "-f", Named("gitdir.cfg"), "filter.evil.clean", evil], sandbox.Root);
                break;
            case DriverOrigin.OnBranchInclude:
                await sandbox.GitAsync(["checkout", "-q", "-b", "x"], repo);
                break;
        }

        var changed = await Read();
        Assert.True(changed.ContainsValue("filter.evil.clean"), "the new driver is neutralised");

        // The plain environment runs the new driver on a stat-dirty file; the cached read environment does not.
        await File.WriteAllTextAsync(Path.Combine(cwd, ".gitattributes"), "* filter=evil\n", Token);
        Sandbox.MakeStatDirty(Path.Combine(cwd, "tracked.txt"));
        var plain = GitInvocation.Environment(null, @base);
        try
        {
            await sandbox.Runner.RunAsync(
                ["status"], cwd, plain, timeout: TimeSpan.FromSeconds(30), allowedExitCodes: Sandbox.AnyExit, ct: Token);
        }
        catch (GitError)
        {
        }

        Assert.True(sandbox.MarkerExists, "positive control: the plain status runs the new driver");
        File.Delete(sandbox.Marker);
        Sandbox.MakeStatDirty(Path.Combine(cwd, "tracked.txt"));
        await sandbox.Runner.RunAsync(
            StatusReader.Arguments, cwd, changed, timeout: TimeSpan.FromSeconds(30), allowedExitCodes: Sandbox.AnyExit,
            ct: Token);
        Assert.False(sandbox.MarkerExists, "the read ran the new driver");
    }

    // A cached read environment is not shared between a superproject and its submodule.
    [Fact]
    public async Task CacheKeyedByFolder()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var source = await sandbox.MakeRepoAsync("sub-source");
        var repo = await sandbox.MakeRepoAsync("super");
        var sub = await sandbox.AddSubmoduleAsync(source, "sub", repo);
        await sandbox.GitAsync(["config", "filter.evil.clean", sandbox.EvilCommand], sub);
        // Past the 2 s race margin, so the superproject's entry is cached and a shared key would be a stale hit.
        await Task.Delay(RaceMargin, Token);
        var (counted, count) = sandbox.CountingRunner();
        var cache = new ReadEnvironmentCache();
        Task<Dictionary<string, string>> Read(string cwd) =>
            GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, counted, cwd, cache, Token);
        var superEnv = await Read(repo);
        Assert.False(superEnv.ContainsValue("filter.evil.clean"));
        var processes = count();
        GitInvocationTests.AssertSameEnvironment(superEnv, await Read(repo), "a hit returns the same environment");
        Assert.True(count() == processes, "the superproject's second read is a hit");
        Assert.True((await Read(sub)).ContainsValue("filter.evil.clean"));
    }

    // A nested repo whose git dir breaks after the fill gives the drivers of the repo git falls back to.
    [Fact]
    public async Task CacheMissesWhenGitDirBreaks()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var outer = await sandbox.MakeRepoAsync("outer");
        await sandbox.GitAsync(["config", "filter.evil.clean", sandbox.EvilCommand], outer);
        var inner = await sandbox.MakeRepoAsync(Path.Combine("outer", "inner"));
        // Past the 2 s race margin, so the inner repo's entry is cached.
        await Task.Delay(RaceMargin, Token);
        var cache = new ReadEnvironmentCache();
        Task<Dictionary<string, string>> Read() =>
            GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, sandbox.Runner, inner, cache, Token);
        Assert.False((await Read()).ContainsValue("filter.evil.clean"));
        // Without HEAD the folder is no git dir, so git searches the parent folders and finds the outer repo.
        File.Delete(Path.Combine(inner, ".git", "HEAD"));
        Assert.True((await Read()).ContainsValue("filter.evil.clean"));
    }

    // A folder symlink repointed to another repo after the fill gives that repo's drivers.
    [Fact]
    public async Task CacheFollowsRepointedSymlink()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var first = await sandbox.MakeRepoAsync("first");
        var second = await sandbox.MakeRepoAsync("second");
        await sandbox.GitAsync(["config", "filter.evil.clean", sandbox.EvilCommand], second);
        var link = Path.Combine(sandbox.Root, "link");
        try
        {
            Directory.CreateSymbolicLink(link, first);
        }
        catch (Exception error) when (OperatingSystem.IsWindows() && error is IOException or UnauthorizedAccessException)
        {
            Assert.Skip($"Windows refused a folder symlink (no Developer Mode or admin): {error.Message}");
        }

        // Past the 2 s race margin, so the first read is cached and the second would be a stale hit.
        await Task.Delay(RaceMargin, Token);
        var (counted, count) = sandbox.CountingRunner();
        var cache = new ReadEnvironmentCache();
        Task<Dictionary<string, string>> Read() =>
            GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, counted, link, cache, Token);
        Assert.False((await Read()).ContainsValue("filter.evil.clean"));
        var processes = count();
        await Read();
        Assert.True(count() == processes, "the second read through the link is a hit");
        Directory.Delete(link);
        Directory.CreateSymbolicLink(link, second);
        Assert.True((await Read()).ContainsValue("filter.evil.clean"));
    }

    /// <summary>
    /// Listings a fake <c>git config --show-origin --list</c> prints, and the error the read must fail with (none: it
    /// lists <c>filter.bare</c> from a key without a value and <c>diff.d</c> from the record after it).
    /// </summary>
    public static TheoryData<string, GitInvocation.ReadSafetyErrorKind?> Listings => new()
    {
        { "file:.git/config\0filter.bare.required\0file:.git/config\0diff.d.textconv\nx\0", null },
        { "file:.git/config\0filter.cut.clean\nx", GitInvocation.ReadSafetyErrorKind.ConfigListingMalformed },
        { "file:.git/config\0filter.odd.clean\nx\0file:.git/config\0", GitInvocation.ReadSafetyErrorKind.ConfigListingMalformed },
    };

    // The cache reads its config listing as whole records and fails closed on anything else.
    [Theory]
    [MemberData(nameof(Listings))]
    public async Task CacheListingRecords(string listing, GitInvocation.ReadSafetyErrorKind? kind)
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), "The fake git is a shell script, which Windows cannot run as git.exe.");
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var output = Path.Combine(sandbox.Root, "listing");
        await File.WriteAllBytesAsync(output, Encoding.UTF8.GetBytes(listing), Token);
        var script = Path.Combine(sandbox.Root, "bin", "listing-git");
        var git = await Fixtures.GitAsync();
        Fixtures.WriteScript(
            $"if [ \"$1\" = config ] && [ \"$3\" = --show-origin ]; then cat '{output}'; exit 0; fi\n"
            + $"exec '{git}' \"$@\"", script);
        Task<Dictionary<string, string>> Read() =>
            GitInvocation.ReadEnvironmentAsync(
                null, sandbox.Base, new GitRunner(script), repo, new ReadEnvironmentCache(), Token);
        if (kind is { } expected)
        {
            var error = await Assert.ThrowsAsync<GitInvocation.ReadSafetyError>(Read);
            Assert.Equal(expected, error.Kind);
        }
        else
        {
            var env = await Read();
            Assert.True(env.ContainsValue("filter.bare.clean"));
            Assert.True(env.ContainsValue("diff.d.textconv"));
        }
    }

    // A read environment whose config includes a path the cache cannot resolve is never cached.
    [Fact]
    public async Task UnresolvableIncludeIsNotCached()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var (counted, count) = sandbox.CountingRunner();
        var repo = await sandbox.MakeRepoAsync("repo");
        // Git expands `%(prefix)/` to its own install folder; the cache does not resolve it.
        await sandbox.GitAsync(["config", "include.path", "%(prefix)/histq-absent.cfg"], repo);
        // Past the 2 s race margin, so only the include keeps it out of the cache.
        await Task.Delay(RaceMargin, Token);
        var cache = new ReadEnvironmentCache();
        Task<Dictionary<string, string>> Read() =>
            GitInvocation.ReadEnvironmentAsync(null, sandbox.Base, counted, repo, cache, Token);
        await Read();
        var processes = count();
        await Read();
        Assert.True(count() > processes, "the second read listed again");
    }
}

/// <summary>A repo built for a marker test and the revisions its commands use.</summary>
internal sealed record Built(string Repo, IReadOnlyList<string> Revs)
{
    public Built(string repo)
        : this(repo, [])
    {
    }
}

/// <summary>
/// A temp folder with its own HOME, hermetic environment and marker script (<c>bin/evil.sh</c>, which touches
/// <c>marker</c> and exits 1). Dispose it to remove it.
/// </summary>
internal sealed class Sandbox : IDisposable
{
    public static readonly int[] AnyExit = Enumerable.Range(0, 256).ToArray();

    private Sandbox(string root, Dictionary<string, string> @base, GitRunner runner)
    {
        Root = root;
        Base = @base;
        Runner = runner;
    }

    public string Root { get; }

    public IReadOnlyDictionary<string, string> Base { get; }

    public GitRunner Runner { get; }

    public string Marker => Path.Combine(Root, "marker");

    public string Evil => Path.Combine(Root, "bin", "evil.sh");

    /// <summary><see cref="Evil"/> as a config value git runs (forward slashes on Windows, for git's sh).</summary>
    public string EvilCommand => Fixtures.ShellPath(Evil);

    public bool MarkerExists => File.Exists(Marker);

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public static async Task<Sandbox> CreateAsync()
    {
        var root = Fixtures.MakeTempDirectory("HistqInvocation");
        try
        {
            var home = Path.Combine(root, "home");
            Directory.CreateDirectory(home);
            var sandbox = new Sandbox(root, Fixtures.HermeticEnvironment(home), new GitRunner(await Fixtures.GitAsync()));
            Fixtures.WriteScript($"touch '{Fixtures.ShellPath(sandbox.Marker)}'\nexit 1", sandbox.Evil);
            return sandbox;
        }
        catch
        {
            Fixtures.RemoveTempDirectory(root);
            throw;
        }
    }

    public void Dispose() => Fixtures.RemoveTempDirectory(Root);

    /// <summary>A runner of the same git that counts the processes it started, and the number started so far.</summary>
    public (GitRunner Runner, Func<int> Count) CountingRunner()
    {
        var count = 0;
        var runner = new GitRunner(Runner.Executable, _ => Interlocked.Increment(ref count));
        return (runner, () => Volatile.Read(ref count));
    }

    /// <summary>Runs a setup command with the hermetic environment; returns its trimmed stdout.</summary>
    public async Task<string> GitAsync(IReadOnlyList<string> args, string dir, byte[]? stdin = null)
    {
        var result = await Runner.RunAsync(args, dir, Base, stdin, TimeSpan.FromSeconds(30), ct: Token);
        return result.Text.Trim();
    }

    /// <summary>A repo with a repo-local identity and one commit of <c>tracked.txt</c>.</summary>
    public async Task<string> MakeRepoAsync(string name)
    {
        var repo = Path.Combine(Root, name);
        await GitAsync(["init", "-q", "-b", "main", repo], Root);
        await GitAsync(["config", "user.name", "Repo Local"], repo);
        await GitAsync(["config", "user.email", "local@histq.invalid"], repo);
        await File.WriteAllTextAsync(Path.Combine(repo, "tracked.txt"), "hello\n", Token);
        await GitAsync(["add", "tracked.txt"], repo);
        await GitAsync(["commit", "-q", "-m", "initial"], repo);
        return repo;
    }

    /// <summary>Clones <paramref name="source"/> as the populated submodule <paramref name="path"/> of <paramref name="repo"/> and commits it; returns its folder.</summary>
    public async Task<string> AddSubmoduleAsync(string source, string path, string repo)
    {
        await GitAsync(["-c", "protocol.file.allow=always", "submodule", "add", "-q", Fixtures.ShellPath(source), path], repo);
        await GitAsync(["commit", "-q", "-m", $"add {path}"], repo);
        return Path.Combine(repo, path);
    }

    /// <summary>Changes the file's mtime but not its content, so git must re-read it to know it is unchanged.</summary>
    public static void MakeStatDirty(string file) =>
        File.SetLastWriteTimeUtc(file, DateTimeOffset.FromUnixTimeSeconds(1_000_000_000).UtcDateTime);
}

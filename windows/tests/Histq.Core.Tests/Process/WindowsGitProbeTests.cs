// Probes of the POSIX git strings on Git for Windows (roadmap "POSIX git strings"), run on the Windows CI runners only:
// (a) security: the read environment's core.hooksPath (GitInvocation.NoHooksPath, NUL on Windows) keeps a repo's hook
// from running, while the same hook does run without it; (b) LC_ALL=C keeps a non-ASCII commit subject and path intact
// through the -z log and status bytes; (c) an empty-valued variable reaches git as set-but-empty (the read environment
// relies on that for its empty GIT_CONFIG_VALUE_n overrides and GIT_ALLOW_PROTOCOL).
using System.Globalization;
using System.Text;

namespace Histq.Core.Tests;

[Trait("Category", "WindowsGit")]
public sealed class WindowsGitProbeTests
{
    private const string WindowsOnly = "A probe of Git for Windows.";

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    // (a) A hook in .git/hooks runs with the plain environment but not with the read environment.
    [Fact]
    public async Task ReadEnvironmentRunsNoHook()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), WindowsOnly);
        using var copy = await Fixtures.CopyAsync();
        var repo = copy.Repo("graph");
        var marker = Path.Combine(copy.Folder, "hook-ran");
        Fixtures.WriteScript($"touch '{Fixtures.ShellPath(marker)}'", Path.Combine(repo, ".git", "hooks", "pre-commit"));
        string[] run = ["hook", "run", "--ignore-missing", "pre-commit"];

        // Control: the hook can run at all.
        var plain = await copy.Runner.RunAsync(
            run, repo, copy.Base, timeout: TimeSpan.FromSeconds(30), allowedExitCodes: Sandbox.AnyExit, ct: Token);
        Assert.True(File.Exists(marker), $"control: the hook did not run (exit {plain.ExitCode}: {plain.StderrTail})");
        File.Delete(marker);

        var env = await GitInvocation.ReadEnvironmentAsync(null, copy.Base, copy.Runner, repo, ct: Token);
        Assert.Equal(GitInvocation.NoHooksPath, ConfigValue(env, "core.hooksPath"));
        var read = await copy.Runner.RunAsync(
            run, repo, env, timeout: TimeSpan.FromSeconds(30), allowedExitCodes: Sandbox.AnyExit, ct: Token);
        Assert.False(File.Exists(marker), "the read environment ran the hook");
        Assert.True(read.ExitCode == 0, $"exit {read.ExitCode}: {read.StderrTail}");
    }

    // (b) A non-ASCII subject (from stdin) and path (from the file system) come back byte for byte from the -z log and
    // status, and through LogReader and StatusReader.
    [Fact]
    public async Task NonAsciiSubjectAndPathRoundTrip()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), WindowsOnly);
        using var copy = await Fixtures.CopyAsync();
        var repo = Path.Combine(copy.Root, "unicode");
        await copy.GitAsync(["init", "-q", "-b", "main", repo], copy.Root, ct: Token);
        await copy.GitAsync(["config", "user.name", "Histq Probe"], repo, ct: Token);
        await copy.GitAsync(["config", "user.email", "probe@histq.invalid"], repo, ct: Token);
        // CJK, ß and an emoji (a UTF-16 surrogate pair): no decomposed forms, so no normalization can change them.
        const string subject = "提交 Straße 😀";
        const string folder = "日本語";
        const string name = "straße-😀.txt";
        var path = folder + "/" + name;
        Directory.CreateDirectory(Path.Combine(repo, folder));
        await File.WriteAllTextAsync(Path.Combine(repo, folder, name), "one\n", Token);
        await copy.GitAsync(["add", "-A"], repo, ct: Token);
        await copy.GitAsync(["commit", "-q", "-F", "-"], repo, Encoding.UTF8.GetBytes(subject + "\n"), Token);

        var env = await GitInvocation.ReadEnvironmentAsync(null, copy.Base, copy.Runner, repo, ct: Token);
        var log = await copy.Runner.RunAsync(["log", "-z", "-1", "--format=%s"], repo, env, ct: Token);
        Assert.Equal(Encoding.UTF8.GetBytes(subject), log.Stdout.AsSpan().TrimEnd((byte)0).ToArray());
        var files = await copy.Runner.RunAsync(
            ["diff-tree", "-z", "-r", "--root", "--name-only", "--no-commit-id", "HEAD"], repo, env, ct: Token);
        Assert.Equal(Encoding.UTF8.GetBytes(path + "\0"), files.Stdout);
        var commits = await LogReaderTests.AllAsync(LogReader.PagesAsync(copy.Runner, repo, env, ct: Token));
        Assert.Equal(subject, Assert.Single(commits).Subject);

        await File.WriteAllTextAsync(Path.Combine(repo, folder, name), "two\n", Token);
        var status = await copy.Runner.RunAsync(StatusReader.Arguments, repo, env, ct: Token);
        Assert.True(
            status.Stdout.AsSpan().IndexOf(Encoding.UTF8.GetBytes(path + "\0")) >= 0,
            $"status bytes: {Convert.ToHexString(status.Stdout)}");
        var entry = Assert.Single((await StatusReader.ReadAsync(copy.Runner, repo, env, Token)).Entries);
        Assert.Equal(path, entry.Path);
        Assert.Equal(StatusEntryChange.Modified, entry.Worktree);
    }

    // (c) An empty-valued variable survives the process start: git reads GIT_CONFIG_VALUE_n="" as an empty value (exit 0,
    // an empty line), while without the variable it refuses the config (the probe can tell set-but-empty from unset).
    [Fact]
    public async Task EmptyVariableReachesGit()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), WindowsOnly);
        using var copy = await Fixtures.CopyAsync();
        var count = int.Parse(copy.Base["GIT_CONFIG_COUNT"], CultureInfo.InvariantCulture);
        var env = new Dictionary<string, string>(copy.Base, GitRunner.EnvironmentKeyComparer)
        {
            ["GIT_CONFIG_COUNT"] = (count + 1).ToString(CultureInfo.InvariantCulture),
            [$"GIT_CONFIG_KEY_{count}"] = "histq.probe",
            [$"GIT_CONFIG_VALUE_{count}"] = "",
        };
        string[] get = ["config", "--get", "histq.probe"];

        var result = await copy.Runner.RunAsync(get, copy.Root, env, allowedExitCodes: Sandbox.AnyExit, ct: Token);
        Assert.True(result.ExitCode == 0, $"exit {result.ExitCode}: {result.StderrTail}");
        Assert.Equal("\n", result.Text);

        env.Remove($"GIT_CONFIG_VALUE_{count}");
        var unset = await copy.Runner.RunAsync(get, copy.Root, env, allowedExitCodes: Sandbox.AnyExit, ct: Token);
        Assert.True(unset.ExitCode != 0, "git took a missing GIT_CONFIG_VALUE_n as set");
    }

    /// <summary>The last command-scope value of <paramref name="key"/> in <paramref name="env"/> (the one git uses).</summary>
    private static string? ConfigValue(IReadOnlyDictionary<string, string> env, string key) =>
        GitInvocationTests.ConfigEntries(env)
            .LastOrDefault(entry => entry.StartsWith(key + "=", StringComparison.Ordinal))?[(key.Length + 1)..];
}

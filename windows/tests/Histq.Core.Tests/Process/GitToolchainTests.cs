// Where git comes from: the gitPath override, else the first git in an ordered list of folders (fully qualified ones
// only), checked to be at least 2.36. The Windows folder order is pure string work and is tested on every OS; the
// rules that need Windows paths or .exe files run on Windows only. Automatic reads need no login shell: the whole read
// setup runs on the resolved git and the base environment, and the read environment keeps every read-safety key.
namespace Histq.Core.Tests;

public sealed class GitToolchainTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    // Version.

    // git --version output parses on every platform's format; anything else is null.
    [Fact]
    public void VersionParsesEveryPlatformFormat()
    {
        Assert.Equal(new GitVersion(2, 39, 5), GitVersion.Parse("git version 2.39.5 (Apple Git-154)\n"));
        Assert.Equal(new GitVersion(2, 47, 0), GitVersion.Parse("git version 2.47.0.rc1"));
        Assert.Equal(new GitVersion(2, 45, 0), GitVersion.Parse("git version 2.45.0.windows.1"));
        Assert.Equal(new GitVersion(2, 50, 0), GitVersion.Parse("git version 2.50"));
        Assert.Null(GitVersion.Parse("bash: git: command not found"));
        Assert.Null(GitVersion.Parse("git version two"));
    }

    // The minimum is 2.36: 2.35.x is older, 2.36.0 is enough.
    [Fact]
    public void MinimumVersionIs236()
    {
        Assert.Equal(new GitVersion(2, 36), GitExecutable.MinimumVersion);
        Assert.True(new GitVersion(2, 35, 9) < GitExecutable.MinimumVersion);
        Assert.True(new GitVersion(2, 36, 0) >= GitExecutable.MinimumVersion);
        Assert.True(new GitVersion(3, 0) > new GitVersion(2, 99, 99));
    }

    // Reads.

    // The whole read setup (git, base environment, read environment, status) runs on the resolved git and the base
    // environment alone, with the fixed PATH off Windows.
    [Fact]
    public async Task ReadSetupNeedsNoLoginShell()
    {
        using var sandbox = await Sandbox.CreateAsync();
        var repo = await sandbox.MakeRepoAsync("repo");
        var git = await GitExecutable.ResolveAsync(ct: Token);
        var runner = new GitRunner(git.ExecutablePath);
        var @base = GitInvocation.BaseEnvironment(gitExecutable: git.ExecutablePath);
        var read = await GitInvocation.ReadEnvironmentAsync(null, @base, runner, repo, ct: Token);
        await StatusReader.ReadAsync(runner, repo, read, Token);

        Assert.Equal(@base["PATH"], read["PATH"]);
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(GitExecutable.FixedPath, @base["PATH"]);
        }
    }

    // The read environment keeps every read-safety key, with the fixed PATH and only the agent variables inherited.
    [Fact]
    public void ReadSafetyKeysAreUnchanged()
    {
        var @base = GitInvocation.PosixBaseEnvironment(
            GitExecutable.FixedPath, "/Users/someone",
            new Dictionary<string, string> { ["SSH_AUTH_SOCK"] = "/tmp/agent", ["USER"] = "someone", ["SECRET"] = "no" });
        var read = GitInvocation.Environment(null, @base, GitInvocation.Access.Read(["lfs"], ["img"]));
        (string Key, string Value)[] config =
        [
            ("core.fsmonitor", "false"), ("log.showSignature", "false"), ("diff.submodule", "short"),
            ("diff.autoRefreshIndex", "false"), ("core.hooksPath", GitInvocation.NoHooksPath), ("diff.external", ""),
            ("i18n.logOutputEncoding", "UTF-8"),
            ("filter.lfs.clean", ""), ("filter.lfs.smudge", ""), ("filter.lfs.process", ""),
            ("filter.lfs.required", "false"), ("diff.img.textconv", ""), ("diff.img.command", ""),
        ];
        var expected = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ["HOME"] = "/Users/someone", ["SSH_AUTH_SOCK"] = "/tmp/agent", ["USER"] = "someone",
            ["GIT_TERMINAL_PROMPT"] = "0", ["LC_ALL"] = "C", ["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes",
            ["GIT_OPTIONAL_LOCKS"] = "0", ["GIT_NO_LAZY_FETCH"] = "1", ["GIT_ALLOW_PROTOCOL"] = "",
            ["GIT_CONFIG_COUNT"] = config.Length.ToString(System.Globalization.CultureInfo.InvariantCulture),
        };
        for (var index = 0; index < config.Length; index++)
        {
            expected[$"GIT_CONFIG_KEY_{index}"] = config[index].Key;
            expected[$"GIT_CONFIG_VALUE_{index}"] = config[index].Value;
        }

        GitInvocationTests.AssertSameEnvironment(expected, read, "the read environment changed");
    }

    // Fixed-folder git.

    // Resolve takes the first folder with an executable git, skipping missing, non-executable and relative ones.
    [Fact]
    public async Task ResolveSearchesTheFoldersInOrder()
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), "Fake gits are shell scripts, which Windows cannot run as git.exe.");
        var root = Fixtures.MakeTempDirectory();
        try
        {
            var empty = Path.Combine(root, "empty");
            Directory.CreateDirectory(empty);
            var plainFile = Path.Combine(root, "plain", "git");
            Directory.CreateDirectory(Path.GetDirectoryName(plainFile)!);
            await File.WriteAllTextAsync(plainFile, "echo 'git version 2.50.0'\n", Token);
            var second = Path.Combine(root, "second", "git");
            var third = Path.Combine(root, "third", "git");
            Fixtures.WriteScript("echo 'git version 2.40.1'", second);
            Fixtures.WriteScript("echo 'git version 2.41.0'", third);
            string[] folders =
            [
                empty, Path.GetDirectoryName(plainFile)!, "relative", Path.GetDirectoryName(second)!,
                Path.GetDirectoryName(third)!,
            ];

            var found = await GitExecutable.ResolveAsync(directories: folders, ct: Token);
            Assert.Equal(second, found.ExecutablePath);
            Assert.Equal(new GitVersion(2, 40, 1), found.Version);

            var overridden = await GitExecutable.ResolveAsync(overridePath: third, directories: folders, ct: Token);
            Assert.Equal(third, overridden.ExecutablePath); // The gitPath override beats the folders.

            var error = await Assert.ThrowsAsync<GitExecutableError>(() =>
                GitExecutable.ResolveAsync(directories: [empty], ct: Token));
            Assert.Equal(GitExecutableError.NotFound(), error);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(root);
        }
    }

    // No git in any folder (relative ones ignored) is NotFound.
    [Fact]
    public async Task ResolveWithoutGitIsNotFound()
    {
        var root = Fixtures.MakeTempDirectory();
        try
        {
            var error = await Assert.ThrowsAsync<GitExecutableError>(() =>
                GitExecutable.ResolveAsync(directories: [root, "relative", "."], ct: Token));
            Assert.Equal(GitExecutableErrorKind.NotFound, error.Kind);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(root);
        }
    }

    // A relative gitPath override is refused, never searched for, even when it would be executable.
    [Fact]
    public async Task RelativeOverrideIsRefused()
    {
        var error = await Assert.ThrowsAsync<GitExecutableError>(() =>
            GitExecutable.ResolveAsync(overridePath: Path.Combine("bin", "git"), isExecutable: _ => true, ct: Token));
        Assert.Equal(GitExecutableError.NotExecutable(Path.Combine("bin", "git")), error);
    }

    // The default folders off Windows are Homebrew (Apple silicon, then Intel), then /usr/bin.
    [Fact]
    public void DefaultSearchOrder()
    {
        Assert.Equal(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"], GitExecutable.SearchDirectories);
    }

    // The Windows folders are the PATH entries (unquoted, empty ones dropped, relative ones kept for Resolve to skip),
    // then Git for Windows' usual cmd folders, skipping those whose variable is unset.
    [Fact]
    public void WindowsSearchOrder()
    {
        const string path = @"C:\Tools\bin; ;""C:\Program Files\Git\cmd"";relative;;C:\Windows\System32";
        var variables = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["ProgramFiles"] = @"C:\Program Files",
            ["LOCALAPPDATA"] = @"C:\Users\me\AppData\Local\",
            ["USERPROFILE"] = @"C:\Users\me",
        };

        var folders = GitExecutable.WindowsSearchDirectories(path, name => variables.GetValueOrDefault(name));

        Assert.Equal(
        [
            @"C:\Tools\bin", @"C:\Program Files\Git\cmd", "relative", @"C:\Windows\System32",
            @"C:\Program Files\Git\cmd", @"C:\Users\me\AppData\Local\Programs\Git\cmd",
            @"C:\Users\me\scoop\apps\git\current\cmd",
        ], folders);
        Assert.Empty(GitExecutable.WindowsSearchDirectories(null, _ => null));
    }

    // Windows only.

    // On Windows the candidates are git.exe in each fully qualified folder, once each (case-insensitive); relative,
    // drive-relative and rooted-without-drive folders are skipped.
    [Fact]
    public void WindowsCandidatesSkipFoldersThatAreNotFullyQualified()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Windows paths are fully qualified only on Windows.");
        string[] folders = [@"C:\a", "relative", ".", @"\rooted", @"C:drive-relative", @"C:\b", @"c:\B"];

        var candidates = GitExecutable.Candidates(folders, _ => true).ToList();

        Assert.Equal([@"C:\a\git.exe", @"C:\b\git.exe"], candidates);
    }

    // On Windows, resolve skips relative and empty folders and finds the real git.exe.
    [Fact]
    public async Task WindowsResolveFindsGitAfterSkippedFolders()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "Needs Git for Windows.");
        var git = await Fixtures.GitAsync();
        var empty = Fixtures.MakeTempDirectory();
        try
        {
            var found = await GitExecutable.ResolveAsync(
                directories: ["relative", ".", empty, Path.GetDirectoryName(git)!], ct: Token);
            Assert.Equal(git, found.ExecutablePath, ignoreCase: true);
            Assert.True(found.Version >= GitExecutable.MinimumVersion);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(empty);
        }
    }

    // On Windows only an .exe counts as executable: a git.cmd override is refused (cmd.exe would re-parse arguments).
    [Fact]
    public async Task WindowsOverrideMustBeAnExe()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "The .exe rule is Windows only.");
        var folder = Fixtures.MakeTempDirectory();
        try
        {
            var script = Path.Combine(folder, "git.cmd");
            await File.WriteAllTextAsync(script, "@echo git version 2.50.0\r\n", Token);

            var error = await Assert.ThrowsAsync<GitExecutableError>(() =>
                GitExecutable.ResolveAsync(overridePath: script, ct: Token));
            Assert.Equal(GitExecutableError.NotExecutable(script), error);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }
}

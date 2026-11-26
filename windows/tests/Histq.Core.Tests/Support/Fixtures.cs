// Shared test support: temp folders, the hermetic base environment every test git call must use (so the user's
// global config (signing, hooks, pull settings) and the system config never affect Core tests), and the fixture repos
// of `scripts/make-fixtures.sh`, built once per test run and copied for each test.
namespace Histq.Core.Tests;

internal static class Fixtures
{
    /// <summary>The null device: <c>NUL</c> on Windows, else <c>/dev/null</c>.</summary>
    public static string NullDevice => OperatingSystem.IsWindows() ? "NUL" : "/dev/null";

    private static readonly Lazy<Task<string>> ResolvedGit = new(ResolveGitAsync);

    private static readonly Lazy<Task<string>> ResolvedBash = new(ResolveBashAsync);

    private static readonly Lazy<Task<string>> Built = new(BuildAsync);

    /// <summary>
    /// The git the tests run: Apple's on the Mac (the Command Line Tools are required to build anyway), the git
    /// <see cref="GitExecutable.ResolveAsync"/> finds on Windows.
    /// </summary>
    public static Task<string> GitAsync() => ResolvedGit.Value;

    /// <summary>
    /// The bash that runs scripts: /bin/bash on the Mac; on Windows the <c>bin\bash.exe</c> of the Git install that
    /// holds <see cref="GitAsync"/> (found from <c>cmd\git.exe</c>, <c>bin\git.exe</c> or <c>mingw64\bin\git.exe</c>).
    /// </summary>
    public static Task<string> BashAsync() => ResolvedBash.Value;

    /// <summary><paramref name="path"/> as bash takes it: <c>C:/...</c> on Windows (forward slashes), unchanged elsewhere.</summary>
    public static string ShellPath(string path) => OperatingSystem.IsWindows() ? path.Replace('\\', '/') : path;

    /// <summary>A new empty folder under the system temp folder, links resolved. Remove it with <see cref="RemoveTempDirectory"/>.</summary>
    public static string MakeTempDirectory(string prefix = "HistqTests")
    {
        var path = Path.Combine(Path.GetTempPath(), $"{prefix}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return ResolveLinks(path);
    }

    /// <summary>Deletes <paramref name="path"/> and everything in it; best effort (git objects are read-only on Windows).</summary>
    public static void RemoveTempDirectory(string path)
    {
        try
        {
            if (!Directory.Exists(path))
            {
                return;
            }

            if (OperatingSystem.IsWindows())
            {
                foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
                {
                    File.SetAttributes(file, FileAttributes.Normal);
                }
            }

            Directory.Delete(path, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>
    /// No global or system config, HOME in <paramref name="home"/>, no prompts, signing off (as command-scope config,
    /// so GitInvocation appends after it). On Windows the system variables a process needs to start (SystemRoot,
    /// ComSpec, TEMP, TMP) and PATH (git and Git Bash's tools) are kept; elsewhere PATH is the fixed system one.
    /// </summary>
    public static Dictionary<string, string> HermeticEnvironment(string home)
    {
        var environment = new Dictionary<string, string>(GitRunner.EnvironmentKeyComparer)
        {
            ["HOME"] = home,
            ["GIT_CONFIG_GLOBAL"] = NullDevice,
            ["GIT_CONFIG_SYSTEM"] = NullDevice,
            ["GIT_CONFIG_NOSYSTEM"] = "1",
            ["GIT_TERMINAL_PROMPT"] = "0",
            ["LC_ALL"] = "C",
            ["GIT_CONFIG_COUNT"] = "2",
            ["GIT_CONFIG_KEY_0"] = "commit.gpgSign",
            ["GIT_CONFIG_VALUE_0"] = "false",
            ["GIT_CONFIG_KEY_1"] = "tag.gpgSign",
            ["GIT_CONFIG_VALUE_1"] = "false",
        };
        if (!OperatingSystem.IsWindows())
        {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin";
            return environment;
        }

        environment["USERPROFILE"] = home;
        foreach (var name in new[] { "SystemRoot", "ComSpec", "TEMP", "TMP", "PATH" })
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrEmpty(value))
            {
                environment[name] = value;
            }
        }

        return environment;
    }

    /// <summary>Writes a <c>#!/bin/sh</c> script, executable off Windows.</summary>
    public static void WriteScript(string body, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "#!/bin/sh\n" + body + "\n");
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(path, (UnixFileMode)0b111_101_101); // 0755
        }
    }

    // Fixture repos.

    /// <summary>
    /// A private copy of the whole fixture root (<c>graph</c>, <c>graph-origin.git</c>, <c>graph-wt</c>,
    /// <c>conflict</c>, <c>conflict-rebase</c>, <c>conflict-pr</c>, <c>conflict-pr-origin.git</c>, <c>expected</c>):
    /// the relative remotes and the relative worktree link only resolve next to their siblings. Dispose it to remove it.
    /// </summary>
    public static async Task<FixtureCopy> CopyAsync()
    {
        var source = await Built.Value.ConfigureAwait(false);
        var git = await GitAsync().ConfigureAwait(false);
        var folder = MakeTempDirectory("HistqFixtureCopy");
        try
        {
            var root = Path.Combine(folder, "fx");
            CopyDirectory(source, root);
            var home = Path.Combine(folder, "home");
            Directory.CreateDirectory(home);
            // Never the real app folders: state lives in this copy's folder.
            var state = StatePaths.Resolve([StatePaths.StateDirFlag, Path.Combine(folder, "state")], _ => null);
            return new FixtureCopy(folder, root, HermeticEnvironment(home), state, new GitRunner(git));
        }
        catch
        {
            RemoveTempDirectory(folder);
            throw;
        }
    }

    /// <summary>
    /// The fixture root of this test run, built on first use (tests run in parallel; the Lazy runs it once) and
    /// removed when the test process exits.
    /// </summary>
    private static async Task<string> BuildAsync()
    {
        var script = FindScript();
        var bash = await BashAsync().ConfigureAwait(false);
        var root = MakeTempDirectory("HistqFixtures");
        AppDomain.CurrentDomain.ProcessExit += (_, _) => RemoveTempDirectory(root);
        var home = MakeTempDirectory("HistqFixturesHome");
        try
        {
            var output = Path.Combine(root, "fx");
            await new GitRunner(bash).RunAsync(
                [ShellPath(script), ShellPath(output)], root, HermeticEnvironment(home),
                timeout: TimeSpan.FromSeconds(120)).ConfigureAwait(false);
            return output;
        }
        finally
        {
            RemoveTempDirectory(home);
        }
    }

    /// <summary><c>scripts/make-fixtures.sh</c> of the repository that holds the test assembly.</summary>
    private static string FindScript()
    {
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            var script = Path.Combine(folder.FullName, "scripts", "make-fixtures.sh");
            if (File.Exists(script))
            {
                return script;
            }
        }

        throw new FileNotFoundException($"No scripts/make-fixtures.sh above {AppContext.BaseDirectory}.");
    }

    private static async Task<string> ResolveGitAsync() =>
        OperatingSystem.IsWindows()
            ? (await GitExecutable.ResolveAsync().ConfigureAwait(false)).ExecutablePath
            : "/usr/bin/git";

    private static async Task<string> ResolveBashAsync()
    {
        if (!OperatingSystem.IsWindows())
        {
            return "/bin/bash";
        }

        var git = await GitAsync().ConfigureAwait(false);
        for (var folder = Directory.GetParent(git); folder is not null; folder = folder.Parent)
        {
            var bash = Path.Combine(folder.FullName, "bin", "bash.exe");
            if (File.Exists(Path.Combine(folder.FullName, "git-bash.exe")) || File.Exists(bash))
            {
                return File.Exists(bash) ? bash : throw new FileNotFoundException($"No bin\\bash.exe in {folder.FullName}.");
            }
        }

        throw new FileNotFoundException($"No Git install with bin\\bash.exe above {git}.");
    }

    /// <summary><paramref name="path"/> with every link in it resolved (the Mac's /var is /private/var); unchanged on Windows.</summary>
    private static string ResolveLinks(string path)
    {
        var full = Path.GetFullPath(path);
        if (OperatingSystem.IsWindows())
        {
            return full;
        }

        var current = Path.GetPathRoot(full)!;
        foreach (var part in full[current.Length..].Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if (new DirectoryInfo(current).ResolveLinkTarget(returnFinalTarget: true) is { } target)
            {
                current = target.FullName;
            }
        }

        return current;
    }

    private static void CopyDirectory(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
        {
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)));
        }

        foreach (var folder in Directory.EnumerateDirectories(source))
        {
            CopyDirectory(folder, Path.Combine(destination, Path.GetFileName(folder)));
        }
    }
}

/// <summary>One test's copy of the fixture root, with the hermetic base environment its git calls must use.</summary>
/// <param name="Folder">The copy's temp folder (fixture root, home and state inside).</param>
/// <param name="Root">The copied fixture root, holding <c>graph</c>, <c>graph-origin.git</c>, <c>conflict</c>, ...</param>
/// <param name="Base"><see cref="Fixtures.HermeticEnvironment"/> with HOME in this copy's own folder.</param>
/// <param name="State">State paths inside <paramref name="Folder"/>, never the real app folders.</param>
internal sealed record FixtureCopy(
    string Folder, string Root, IReadOnlyDictionary<string, string> Base, StatePaths State, GitRunner Runner)
    : IDisposable
{
    public string Repo(string name) => Path.Combine(Root, name);

    /// <summary>Runs git with the hermetic base environment and returns its stdout without the final newline.</summary>
    public async Task<string> GitAsync(
        IReadOnlyList<string> args, string repo, byte[]? stdin = null, CancellationToken ct = default)
    {
        var text = (await Runner.RunAsync(args, repo, Base, stdin, TimeSpan.FromSeconds(30), ct: ct)
            .ConfigureAwait(false)).Text;
        return text.EndsWith('\n') ? text[..^1] : text;
    }

    public void Dispose() => Fixtures.RemoveTempDirectory(Folder);
}

// Finds the git binary Histq runs: the path set in Settings, else the first git in an ordered list of folders, so no
// read waits for a shell. On Windows the folders are the PATH entries, then Git for Windows' usual cmd folders; on
// other systems (the Mac, where the tests also run) the fixed Swift list (Homebrew on Apple silicon, then Intel, then
// /usr/bin). Only fully qualified folders are searched and the result is always an absolute path, so a git(.exe) in a
// repository or the current directory is never run. On the Mac /usr/bin/git is only a shim: without the Command Line
// Tools it pops the installer, so it is never run before `xcode-select -p` succeeds; then the real binary in the
// developer folder it names runs instead. Git older than 2.36 is rejected: GIT_CONFIG_COUNT needs 2.31,
// `worktree list --porcelain -z` and a boolean core.fsmonitor need 2.36.
using System.Globalization;
using System.Text;
using IOPath = System.IO.Path;

namespace Histq.Core;

/// <summary>A git version such as <c>2.39.5</c>.</summary>
public readonly record struct GitVersion(int Major, int Minor, int Patch = 0) : IComparable<GitVersion>
{
    private const string Marker = "git version ";

    /// <summary>
    /// Parses <c>git --version</c> output: <c>git version 2.39.5 (Apple Git-154)</c>, <c>git version 2.47.0.rc1</c>,
    /// <c>git version 2.45.0.windows.1</c>. Null when it is not one.
    /// </summary>
    public static GitVersion? Parse(string output)
    {
        var marker = output.IndexOf(Marker, StringComparison.Ordinal);
        if (marker < 0)
        {
            return null;
        }

        var rest = output.AsSpan(marker + Marker.Length);
        var end = 0;
        while (end < rest.Length && !char.IsWhiteSpace(rest[end]))
        {
            end++;
        }

        var numbers = rest[..end].ToString().Split('.').Take(3).Select(LeadingNumber).ToList();
        if (numbers.Count < 2 || numbers[0] is not int major || numbers[1] is not int minor)
        {
            return null;
        }

        return new GitVersion(major, minor, numbers.Count == 3 ? numbers[2] ?? 0 : 0);
    }

    /// <summary>The ASCII digits <paramref name="part"/> starts with as a number; null when there are none.</summary>
    private static int? LeadingNumber(string part)
    {
        var digits = 0;
        while (digits < part.Length && char.IsAsciiDigit(part[digits]))
        {
            digits++;
        }

        return int.TryParse(part.AsSpan(0, digits), NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
    }

    public int CompareTo(GitVersion other)
    {
        var major = Major.CompareTo(other.Major);
        if (major != 0)
        {
            return major;
        }

        var minor = Minor.CompareTo(other.Minor);
        return minor != 0 ? minor : Patch.CompareTo(other.Patch);
    }

    public static bool operator <(GitVersion left, GitVersion right) => left.CompareTo(right) < 0;

    public static bool operator >(GitVersion left, GitVersion right) => left.CompareTo(right) > 0;

    public static bool operator <=(GitVersion left, GitVersion right) => left.CompareTo(right) <= 0;

    public static bool operator >=(GitVersion left, GitVersion right) => left.CompareTo(right) >= 0;

    public override string ToString() => string.Create(CultureInfo.InvariantCulture, $"{Major}.{Minor}.{Patch}");
}

/// <summary>Why no usable git was found (the cases of <see cref="GitExecutableError"/>).</summary>
public enum GitExecutableErrorKind
{
    /// <summary>Only /usr/bin/git is available (Mac) and the Command Line Tools are not installed.</summary>
    CommandLineToolsMissing,

    /// <summary>No git in any of the searched folders.</summary>
    NotFound,

    /// <summary>The path set in Settings is not an absolute path to an executable file (or could not be started).</summary>
    NotExecutable,

    /// <summary>The git found is older than <see cref="GitExecutable.MinimumVersion"/>.</summary>
    TooOld,

    /// <summary><c>git --version</c> failed or printed something unexpected.</summary>
    UnrecognizedVersion,
}

/// <summary>Why no usable git was found. Equal when the kind and its value are equal.</summary>
public sealed class GitExecutableError : Exception, IEquatable<GitExecutableError>
{
    private GitExecutableError(
        GitExecutableErrorKind kind, string message, string? executablePath = null, GitVersion? version = null,
        string? output = null)
        : base(message)
    {
        Kind = kind;
        ExecutablePath = executablePath;
        Version = version;
        Output = output;
    }

    public GitExecutableErrorKind Kind { get; }

    /// <summary>The path that is not executable (<see cref="GitExecutableErrorKind.NotExecutable"/>).</summary>
    public string? ExecutablePath { get; }

    /// <summary>The version that is too old (<see cref="GitExecutableErrorKind.TooOld"/>).</summary>
    public GitVersion? Version { get; }

    /// <summary>The trimmed <c>git --version</c> output (<see cref="GitExecutableErrorKind.UnrecognizedVersion"/>).</summary>
    public string? Output { get; }

    public static GitExecutableError CommandLineToolsMissing() =>
        new(GitExecutableErrorKind.CommandLineToolsMissing, "The Command Line Tools are not installed.");

    public static GitExecutableError NotFound() => new(GitExecutableErrorKind.NotFound, "Git was not found.");

    public static GitExecutableError NotExecutable(string path) =>
        new(GitExecutableErrorKind.NotExecutable, $"{path} is not an executable git.", executablePath: path);

    public static GitExecutableError TooOld(GitVersion version) =>
        new(GitExecutableErrorKind.TooOld,
            $"Git {version} is too old: Histq needs {GitExecutable.MinimumVersion} or later.", version: version);

    public static GitExecutableError UnrecognizedVersion(string output) =>
        new(GitExecutableErrorKind.UnrecognizedVersion, $"Unrecognized git version: {output}", output: output);

    public bool Equals(GitExecutableError? other) =>
        other is not null && Kind == other.Kind && Version == other.Version
        && string.Equals(ExecutablePath, other.ExecutablePath, StringComparison.Ordinal)
        && string.Equals(Output, other.Output, StringComparison.Ordinal);

    public override bool Equals(object? obj) => Equals(obj as GitExecutableError);

    public override int GetHashCode() => HashCode.Combine(
        Kind, Version, ExecutablePath is null ? 0 : StringComparer.Ordinal.GetHashCode(ExecutablePath),
        Output is null ? 0 : StringComparer.Ordinal.GetHashCode(Output));
}

/// <summary>A git binary that was checked to run and to be recent enough.</summary>
/// <param name="ExecutablePath">The absolute path of the git binary.</param>
public sealed record GitExecutable(string ExecutablePath, GitVersion Version)
{
    public static readonly GitVersion MinimumVersion = new(2, 36);

    internal const string AppleGitPath = "/usr/bin/git";

    /// <summary>Where <see cref="ResolveAsync"/> looks for git off Windows, in order, when no override is set.</summary>
    public static IReadOnlyList<string> SearchDirectories { get; } = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"];

    /// <summary>The fixed PATH of automatic reads off Windows.</summary>
    public const string FixedPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

    /// <summary>The file name searched for in each folder: <c>git.exe</c> on Windows, else <c>git</c>.</summary>
    public static string FileName => OperatingSystem.IsWindows() ? "git.exe" : "git";

    /// <summary>
    /// The folders searched when none are given: <see cref="WindowsSearchDirectories"/> of this process's PATH and
    /// environment on Windows, else <see cref="SearchDirectories"/>.
    /// </summary>
    public static IReadOnlyList<string> DefaultDirectories() =>
        OperatingSystem.IsWindows()
            ? WindowsSearchDirectories(Environment.GetEnvironmentVariable("PATH"), Environment.GetEnvironmentVariable)
            : SearchDirectories;

    /// <summary>
    /// The Windows search order: each entry of <paramref name="path"/> (<c>;</c>-separated, quotes and spaces around
    /// it removed, empty ones dropped), then <c>%ProgramFiles%\Git\cmd</c>, <c>%ProgramFiles(x86)%\Git\cmd</c>,
    /// <c>%LOCALAPPDATA%\Programs\Git\cmd</c> and <c>%USERPROFILE%\scoop\apps\git\current\cmd</c> (skipped when the
    /// variable is unset). Pure string work, so it runs on any OS; <see cref="ResolveAsync"/> then skips every folder
    /// that is not fully qualified (relative, <c>.</c>, drive-relative <c>\x</c>).
    /// </summary>
    public static IReadOnlyList<string> WindowsSearchDirectories(string? path, Func<string, string?> environment)
    {
        var folders = new List<string>();
        foreach (var entry in (path ?? "").Split(';'))
        {
            var folder = entry.Trim().Trim('"').Trim();
            if (folder.Length > 0)
            {
                folders.Add(folder);
            }
        }

        (string Variable, string Folder)[] fixedFolders =
        [
            ("ProgramFiles", @"Git\cmd"),
            ("ProgramFiles(x86)", @"Git\cmd"),
            ("LOCALAPPDATA", @"Programs\Git\cmd"),
            ("USERPROFILE", @"scoop\apps\git\current\cmd"),
        ];
        foreach (var (variable, folder) in fixedFolders)
        {
            var root = environment(variable)?.Trim().TrimEnd('\\', '/');
            if (!string.IsNullOrEmpty(root))
            {
                folders.Add(root + @"\" + folder);
            }
        }

        return folders;
    }

    /// <summary>
    /// <paramref name="overridePath"/> (a path from Settings, <c>~</c> allowed) when set, else the first executable
    /// git in <paramref name="directories"/> (<see cref="DefaultDirectories"/> by default; folders that are not fully
    /// qualified are skipped). An override that is not an absolute path to an executable throws instead of falling
    /// back, so Settings can show the problem. On the Mac a /usr/bin/git found while the Command Line Tools are
    /// missing is skipped; if nothing else is found the error is
    /// <see cref="GitExecutableErrorKind.CommandLineToolsMissing"/>. <paramref name="isExecutable"/> replaces the file
    /// check (tests). It takes one <c>git --version</c> (and <c>xcode-select -p</c> for the Mac's /usr/bin/git).
    /// </summary>
    public static async Task<GitExecutable> ResolveAsync(
        string? overridePath = null, IReadOnlyList<string>? directories = null, Func<string, bool>? isExecutable = null,
        CancellationToken ct = default)
    {
        isExecutable ??= IsExecutable;
        var trimmed = overridePath?.Trim();
        if (!string.IsNullOrEmpty(trimmed))
        {
            var path = ExpandTilde(trimmed);
            if (!IOPath.IsPathFullyQualified(path) || !isExecutable(path))
            {
                throw GitExecutableError.NotExecutable(path);
            }

            return await ValidateAsync(path, ct).ConfigureAwait(false);
        }

        var toolsMissing = false;
        foreach (var candidate in Candidates(directories ?? DefaultDirectories(), isExecutable))
        {
            try
            {
                return await ValidateAsync(candidate, ct).ConfigureAwait(false);
            }
            catch (GitExecutableError error) when (error.Kind == GitExecutableErrorKind.CommandLineToolsMissing)
            {
                toolsMissing = true;
            }
        }

        throw toolsMissing ? GitExecutableError.CommandLineToolsMissing() : GitExecutableError.NotFound();
    }

    /// <summary>
    /// The absolute paths <see cref="ResolveAsync"/> tries, in order: <see cref="FileName"/> in each fully qualified
    /// folder of <paramref name="directories"/> (each folder once) for which <paramref name="isExecutable"/> holds.
    /// </summary>
    internal static IEnumerable<string> Candidates(IReadOnlyList<string> directories, Func<string, bool> isExecutable)
    {
        var seen = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        foreach (var directory in directories)
        {
            if (!IOPath.IsPathFullyQualified(directory) || !seen.Add(directory))
            {
                continue;
            }

            var candidate = IOPath.Combine(directory, FileName);
            if (isExecutable(candidate))
            {
                yield return candidate;
            }
        }
    }

    /// <summary>
    /// Checks the git at <paramref name="path"/>: on the Mac the Command Line Tools first when it is /usr/bin/git
    /// (links resolved), which is then replaced by the git of the developer folder <c>xcode-select -p</c> names when
    /// there is one; then <c>git --version</c> against <see cref="MinimumVersion"/>.
    /// </summary>
    public static async Task<GitExecutable> ValidateAsync(string path, CancellationToken ct = default)
    {
        if (OperatingSystem.IsMacOS() && string.Equals(ResolveLinks(path), AppleGitPath, StringComparison.Ordinal))
        {
            var developer = await DeveloperDirectoryAsync(ct).ConfigureAwait(false)
                            ?? throw GitExecutableError.CommandLineToolsMissing();
            var real = IOPath.Combine(developer, "usr/bin/git");
            if (IsExecutable(real))
            {
                path = real;
            }
        }

        var outcome = await ChildProcess.CaptureAsync(path, ["--version"], MinimalEnvironment(), TimeSpan.FromSeconds(5), ct)
                          .ConfigureAwait(false)
                      ?? throw GitExecutableError.NotExecutable(path);
        var output = Encoding.UTF8.GetString(outcome.Stdout);
        if (outcome.TimedOut || outcome.ExitCode != 0 || GitVersion.Parse(output) is not GitVersion version)
        {
            throw GitExecutableError.UnrecognizedVersion(output.Trim());
        }

        if (version < MinimumVersion)
        {
            throw GitExecutableError.TooOld(version);
        }

        return new GitExecutable(path, version);
    }

    /// <summary>
    /// The environment of <c>git --version</c> and <c>xcode-select -p</c>: on Windows the system folders git.exe needs
    /// to start, elsewhere a fixed system PATH; plus the home folder and <c>LC_ALL=C</c>.
    /// </summary>
    private static Dictionary<string, string> MinimalEnvironment()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!OperatingSystem.IsWindows())
        {
            return new(StringComparer.Ordinal) { ["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin", ["HOME"] = home, ["LC_ALL"] = "C" };
        }

        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["LC_ALL"] = "C" };
        foreach (var name in new[] { "SystemRoot", "windir", "TEMP", "TMP" })
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrEmpty(value))
            {
                environment[name] = value;
            }
        }

        if (environment.TryGetValue("SystemRoot", out var systemRoot))
        {
            environment["PATH"] = IOPath.Combine(systemRoot, "System32") + ";" + systemRoot;
        }

        if (home.Length > 0)
        {
            environment["USERPROFILE"] = home;
            environment["HOME"] = home;
        }

        return environment;
    }

    /// <summary>
    /// The developer folder <c>xcode-select -p</c> prints (the Command Line Tools' or Xcode's); null when neither is
    /// installed. It never runs the installer, unlike the /usr/bin/git shim.
    /// </summary>
    internal static async Task<string?> DeveloperDirectoryAsync(CancellationToken ct = default)
    {
        var outcome = await ChildProcess.CaptureAsync(
            "/usr/bin/xcode-select", ["-p"], MinimalEnvironment(), TimeSpan.FromSeconds(5), ct).ConfigureAwait(false);
        if (outcome is null || outcome.TimedOut || outcome.ExitCode != 0)
        {
            return null;
        }

        var path = Encoding.UTF8.GetString(outcome.Stdout).Trim();
        return path.StartsWith('/') ? path : null;
    }

    /// <summary><paramref name="path"/> with a leading <c>~</c> (alone or before a separator) as the home folder.</summary>
    private static string ExpandTilde(string path)
    {
        if (path == "~")
        {
            return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        var separated = path.StartsWith("~/", StringComparison.Ordinal)
                        || (OperatingSystem.IsWindows() && path.StartsWith(@"~\", StringComparison.Ordinal));
        return separated
            ? IOPath.Join(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path[2..])
            : path;
    }

    /// <summary>The final target of <paramref name="path"/> when it is a link, else the path itself.</summary>
    private static string ResolveLinks(string path)
    {
        try
        {
            return File.ResolveLinkTarget(path, returnFinalTarget: true)?.FullName ?? path;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return path;
        }
    }

    /// <summary>
    /// A file (not a folder) that can run: on Windows an <c>.exe</c> (a <c>.bat</c> or <c>.cmd</c> would run through
    /// cmd.exe, which re-parses the arguments), elsewhere one with an execute bit.
    /// </summary>
    private static bool IsExecutable(string path)
    {
        if (!File.Exists(path))
        {
            return false;
        }

        if (OperatingSystem.IsWindows())
        {
            return string.Equals(IOPath.GetExtension(path), ".exe", StringComparison.OrdinalIgnoreCase);
        }

        try
        {
            const UnixFileMode execute = UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute;
            return (File.GetUnixFileMode(path) & execute) != 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}

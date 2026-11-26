// Remembers the filter and diff driver names `GitInvocation.ReadEnvironmentAsync` lists in a folder, so a repeated read
// there runs no `git config` process. Those names are a security guard (a read must never run a filter or textconv
// the repo configures), so the rule is that every doubt is a miss: a stale hit would let a read run without a newly
// configured driver neutralised.
//
// A miss runs one `git config -z --show-origin --list` (both driver lists, and the file every entry came from) and
// one `git rev-parse` (the work tree's root, its git dir, config, `config.worktree` and HEAD). The entry is kept with
// a signature (kind; for a file its size, write time, creation time and, off Windows, its mode; for a folder its
// creation time and mode; or "absent") of every file whose change could change that listing:
// - every `file:` origin it shows (each must exist: git just read it);
// - the repo config, `config.worktree`, the git dir's `commondir` and the root's `.git` (a folder by creation time and
//   mode only, since its times move with every lock file; a gitfile in full);
// - the global and system config paths git itself names (`git var GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`, git
//   2.42 and later), the `share/git-core/gitconfig` next to git's `--exec-path` and `/etc/gitconfig` (on Windows
//   `%ProgramData%\Git\config`, which Git for Windows reads before its system config), absent ones as absent; these
//   are memoized per git (its real path) and environment;
// - the target of every `include.path` and `includeIf.<condition>.path`, taken or not: absolute, `~/` (against HOME)
//   or relative to the file that holds it;
// - the per-worktree HEAD when an `includeIf` condition is `onbranch:`;
// - what makes the git dir a git dir (else git searches the parent folders for another repo): its HEAD (present as a
//   file) and the common dir's `objects` and `refs` folders.
// The repo config, when it is a non-empty file, must be among the listing's origins (the listing and rev-parse saw
// the same repo). Entries are keyed on the git binary's real path and signature, so an updated git lists again.
// A hit re-reads every signature and checks that the folder's real path (links resolved) is still the root the entry
// was listed for, and runs nothing. Nothing is cached when the folder's real path is not a work tree's root (relative
// origins are relative to the root), a file is on a volume that is not local (a network volume may serve stale
// attributes while git reads fresh content, and stamps times with the server's clock), an include cannot be
// resolved (`~user/`, `%(prefix)/`, a relative path from the command line, a root- or drive-relative Windows path), an
// origin is not a file, the command line, standard input or a blob, `onbranch:` meets a ref storage setting (HEAD may
// then be a stub), a file is not a regular file (but the null device), a file cannot be read, a git older than 2.42
// cannot name its config paths, or a present file was written or created less than 2 s before the listing started or
// later (a margin for a clock stepped back or a coarse file system clock).
//
// Unlike the Mac (stat: device, inode, owner, ctime), .NET has no portable file identity or change time, so the
// signature uses what every OS gives: size, write time, creation time (git rewrites a config through a new lock file,
// so every edit also gives it a new creation time) and the Unix mode. Paths are compared in git's form (forward
// slashes on Windows, where they are compared case-insensitively).
using System.Text;

namespace Histq.Core;

/// <summary>
/// The driver names of recent read environments, one entry per folder, git and listing environment. Safe to share
/// between tasks; pass it to <see cref="GitInvocation.ReadEnvironmentAsync"/>.
/// </summary>
public sealed class ReadEnvironmentCache
{
    /// <summary>The most entries it keeps; the least recently used goes first.</summary>
    internal const int Capacity = 32;

    /// <summary>How long before the listing a file change still counts as "during the listing", in ticks.</summary>
    internal static readonly long RaceMargin = TimeSpan.FromSeconds(2).Ticks;

    /// <summary>
    /// What an entry is for: the full folder path, the git binary (real path and signature) and the exact listing
    /// environment, so a different base, profile or git (or an updated one) never shares an entry.
    /// </summary>
    internal sealed record Key(string Cwd, string Executable, string Env)
    {
        /// <summary>The key of the global and system config paths, which depend on the git and the environment only.</summary>
        public Key Scope => this with { Cwd = "" };
    }

    /// <summary>One file whose change could change the listing, as it was when the entry was filled.</summary>
    /// <param name="KindOnly">Only its kind (absent, file, device, folder) must stay the same, not its size or times.</param>
    internal sealed record Validator(string Path, FileSignature Signature, bool KindOnly = false)
    {
        /// <summary>Whether the file still looks as it did.</summary>
        public bool Holds =>
            FileSignature.At(Path) is { } now && (KindOnly ? now.Kind == Signature.Kind : now == Signature);
    }

    /// <summary>The listed driver names, the work tree root they were listed for and the files they depend on.</summary>
    internal sealed record Entry(
        string Root, IReadOnlyList<string> Filters, IReadOnlyList<string> Diffs, IReadOnlyList<Validator> Validators);

    private readonly Lock _lock = new();

    private readonly Dictionary<Key, Entry> _entries = [];

    /// <summary>The keys of <see cref="_entries"/> in use order, oldest first.</summary>
    private readonly List<Key> _order = [];

    /// <summary>
    /// The memoized global and system config paths per git and environment (null: that git cannot name them, so
    /// nothing is cached).
    /// </summary>
    private readonly Dictionary<Key, IReadOnlyList<string>?> _scopePaths = [];

    /// <summary>
    /// The filter and diff driver names git lists in <paramref name="cwd"/> with <paramref name="env"/>: the cached
    /// ones while every validator file is unchanged, else a new listing (cached when nothing is in doubt). Throws as
    /// <see cref="GitInvocation.DriversAsync"/> does.
    /// </summary>
    internal async Task<(IReadOnlyList<string> Filters, IReadOnlyList<string> Diffs)> DriversAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct = default)
    {
        if (RealPath(runner.Executable) is not { } git || FileSignature.At(git) is not { Kind: FileKind.File } binary)
        {
            return await GitInvocation.DriversAsync(runner, cwd, env, ct).ConfigureAwait(false);
        }

        var key = new Key(Path.GetFullPath(cwd), $"{git}\n{binary}", EnvironmentKey(env));
        Entry? entry;
        lock (_lock)
        {
            _entries.TryGetValue(key, out entry);
        }

        if (entry is not null)
        {
            // A linked folder repointed elsewhere keeps its key but not its root.
            if (SamePath(RootOf(cwd), entry.Root) && entry.Validators.All(validator => validator.Holds))
            {
                lock (_lock)
                {
                    Touch(key);
                }

                return (entry.Filters, entry.Diffs);
            }

            lock (_lock)
            {
                Remove(key);
            }
        }

        // A git that cannot name its config paths never gets an entry: list as without a cache, no rev-parse.
        bool unnameable;
        lock (_lock)
        {
            unnameable = _scopePaths.TryGetValue(key.Scope, out var known) && known is null;
        }

        if (unnameable)
        {
            return await GitInvocation.DriversAsync(runner, cwd, env, ct).ConfigureAwait(false);
        }

        return await FillAsync(key, runner, cwd, env, ct).ConfigureAwait(false);
    }

    /// <summary>Lists the drivers and, when nothing is in doubt, keeps them under <paramref name="key"/>.</summary>
    private async Task<(IReadOnlyList<string> Filters, IReadOnlyList<string> Diffs)> FillAsync(
        Key key, GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct)
    {
        var start = DateTime.UtcNow.Ticks;
        var rootBefore = RootOf(cwd);
        var listing = runner.RunAsync(
            ["config", "-z", "--show-origin", "--list"], cwd, env, timeout: TimeSpan.FromSeconds(10), ct: ct);
        var located = Located.FindAsync(runner, cwd, env, ct);
        var scopes = ScopePathsAsync(key, runner, cwd, env, ct);
        // Every task finishes before an error (the listing's first) is thrown.
        await Task.WhenAll(listing, located, scopes).ConfigureAwait(false);
        var records = ConfigRecord.Parse((await listing.ConfigureAwait(false)).Stdout);
        var drivers = GitInvocation.Drivers(records.Select(record => record.Key).ToList());
        if (await located.ConfigureAwait(false) is { } where && await scopes.ConfigureAwait(false) is { } scopePaths
            && SamePath(rootBefore, where.Root) && SamePath(RootOf(cwd), where.Root)
            && Validators(records, where, scopePaths, env, start) is { } validators)
        {
            var entry = new Entry(where.Root, drivers.Filters, drivers.Diffs, validators);
            lock (_lock)
            {
                Store(entry, key);
            }
        }

        return drivers;
    }

    /// <summary>
    /// The global and system config paths git names for <paramref name="env"/> (<c>git var</c>, git 2.42 and later)
    /// and the <c>share/git-core/gitconfig</c> next to its <c>--exec-path</c>, once per git and environment
    /// (<c>key.Scope</c>). Null when that git cannot name them (memoized) or a command failed (not memoized: the next
    /// miss asks again).
    /// </summary>
    private async Task<IReadOnlyList<string>?> ScopePathsAsync(
        Key key, GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct)
    {
        lock (_lock)
        {
            if (_scopePaths.TryGetValue(key.Scope, out var known))
            {
                return known;
            }
        }

        // Named even when `GIT_CONFIG_NOSYSTEM` hides it: reading one file more never makes a hit stale.
        var systemEnv = new Dictionary<string, string>(GitRunner.EnvironmentKeyComparer);
        foreach (var (name, value) in env)
        {
            systemEnv[name] = value;
        }

        systemEnv.Remove("GIT_CONFIG_NOSYSTEM");
        IReadOnlyList<string>? paths;
        try
        {
            var timeout = TimeSpan.FromSeconds(10);
            var system = runner.RunAsync(["var", "GIT_CONFIG_SYSTEM"], cwd, systemEnv, timeout: timeout, ct: ct);
            var global = runner.RunAsync(["var", "GIT_CONFIG_GLOBAL"], cwd, env, timeout: timeout, ct: ct);
            var execPath = runner.RunAsync(["--exec-path"], cwd, env, timeout: timeout, ct: ct);
            await Task.WhenAll(system, global, execPath).ConfigureAwait(false);
            var named = GitInvocation.DecodeUTF8((await system.ConfigureAwait(false)).Stdout) is { } systemText
                        && GitInvocation.DecodeUTF8((await global.ConfigureAwait(false)).Stdout) is { } globalText
                ? (systemText + globalText).Split('\n', StringSplitOptions.RemoveEmptyEntries)
                : null;
            var exec = GitInvocation.DecodeUTF8((await execPath.ConfigureAwait(false)).Stdout)?.Trim('\n', '\r');
            // A carriage return would make a path that never exists, so a config created there later goes unseen.
            if (named is null
                || !named.All(line => !line.Contains('\r', StringComparison.Ordinal) && (IsAbsolute(line) || IsNullDevice(line)))
                || exec is null
                || RealPath(exec) is not { } real
                || Path.GetDirectoryName(Path.GetDirectoryName(real)) is not { Length: > 0 } prefix)
            {
                return null;
            }

            // `<prefix>/libexec/git-core` -> `<prefix>/share/git-core/gitconfig`.
            var share = Path.Combine(prefix, "share", "git-core", "gitconfig");
            paths = [.. named.Select(Normalize), Normalize(share)];
        }
        catch (GitError error) when (error.ExitCode == 129)
        {
            // `git var` printed its usage: this git (older than 2.42) has no such variable, now or next time.
            paths = null;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            return null;
        }

        lock (_lock)
        {
            if (_scopePaths.Count >= Capacity)
            {
                _scopePaths.Clear();
            }

            _scopePaths[key.Scope] = paths;
        }

        return paths;
    }

    /// <summary>
    /// Every file whose change could change <paramref name="records"/>, with its signature now; null when anything is
    /// in doubt. <paramref name="start"/> is when the listing started, in UTC ticks.
    /// </summary>
    internal static List<Validator>? Validators(
        IReadOnlyList<ConfigRecord> records, Located located, IReadOnlyList<string> scopes,
        IReadOnlyDictionary<string, string> env, long start)
    {
        var mustExist = new List<string>();
        var paths = new List<string>(scopes);
        paths.AddRange(SystemConfigFiles(env));
        paths.AddRange([located.Config, located.WorktreeConfig, located.GitDir + "/commondir"]);
        var onBranch = false;
        var refStorage = false;
        env.TryGetValue("HOME", out var home);
        foreach (var record in records)
        {
            string? holder;
            switch (record.Origin)
            {
                case ConfigOrigin.File file:
                    var absolute = IsAbsolute(file.Path) ? Normalize(file.Path) : located.Root + "/" + Normalize(file.Path);
                    mustExist.Add(absolute);
                    holder = absolute;
                    break;
                case ConfigOrigin.CommandLine or ConfigOrigin.StandardInput or ConfigOrigin.Blob:
                    holder = null;
                    break;
                default:
                    return null;
            }

            var key = Encoding.UTF8.GetString(record.Key.Span).ToLowerInvariant();
            if (key == "extensions.refstorage")
            {
                refStorage = true;
            }

            if (key.StartsWith("includeif.onbranch:", StringComparison.Ordinal))
            {
                onBranch = true;
            }

            var isInclude = key == "include.path"
                            || (key.StartsWith("includeif.", StringComparison.Ordinal)
                                && key.EndsWith(".path", StringComparison.Ordinal));
            if (!isInclude)
            {
                continue;
            }

            if (record.Value is not { } value || GitInvocation.DecodeUTF8(value.Span) is not { } text
                || IncludeTarget(text, holder, home) is not { } target)
            {
                return null;
            }

            paths.Add(target);
        }

        if (onBranch)
        {
            // With reftable, HEAD is a stub that never changes while the branch does.
            if (refStorage)
            {
                return null;
            }

            paths.Add(located.Head);
        }

        // A non-empty repo config that is not among the origins: the listing did not read the repo rev-parse found.
        if (FileSignature.At(located.Config) is { Kind: FileKind.File, Size: > 0 }
            && !mustExist.Contains(located.Config, PathComparer))
        {
            return null;
        }

        var since = start - RaceMargin;
        var validators = new List<Validator>();
        var seen = new HashSet<string>(PathComparer);
        if (!IsLocal(located.Root) || !IsLocal(located.GitDir))
        {
            return null;
        }

        foreach (var path in mustExist.Concat(paths))
        {
            if (!seen.Add(path))
            {
                continue;
            }

            if (FileSignature.At(path) is not { } signature)
            {
                return null;
            }

            if (signature.Kind != FileKind.Absent && !IsLocal(path))
            {
                return null;
            }

            switch (signature.Kind)
            {
                case FileKind.Absent:
                    if (mustExist.Contains(path, PathComparer))
                    {
                        return null;
                    }

                    break;
                case FileKind.File:
                    // Changed while it was listed: the listing may have seen either version.
                    if (signature.ChangedSince(since))
                    {
                        return null;
                    }

                    break;
                case FileKind.Device:
                    if (!IsNullDevice(path))
                    {
                        return null;
                    }

                    break;
                default:
                    return null;
            }

            validators.Add(new Validator(path, signature));
        }

        // The root's `.git`: a folder (its times move with every lock file, so which one it is) or a gitfile.
        var anchor = located.Root + "/.git";
        if (!seen.Add(anchor) || FileSignature.At(anchor) is not { } anchorSignature || !IsLocal(anchor))
        {
            return null;
        }

        var anchorHolds = anchorSignature.Kind == FileKind.Directory
                          || (anchorSignature.Kind == FileKind.File && !anchorSignature.ChangedSince(since));
        if (!anchorHolds)
        {
            return null;
        }

        validators.Add(new Validator(anchor, anchorSignature));
        // What makes the git dir a git dir: a HEAD file (rewritten by every checkout, so its kind only) and the
        // common dir's `objects` and `refs` folders.
        (string Path, FileKind Kind)[] markers =
        [
            (located.GitDir + "/HEAD", FileKind.File),
            (located.CommonDir + "/objects", FileKind.Directory),
            (located.CommonDir + "/refs", FileKind.Directory),
        ];
        foreach (var (path, kind) in markers)
        {
            if (FileSignature.At(path) is not { } signature || signature.Kind != kind || !IsLocal(path))
            {
                return null;
            }

            validators.Add(new Validator(path, signature, KindOnly: kind == FileKind.File));
        }

        return validators;
    }

    /// <summary>
    /// The system config files git reads that <c>git var</c> does not name: <c>/etc/gitconfig</c>, on Windows
    /// <c>%ProgramData%\Git\config</c> (from the listing environment) instead.
    /// </summary>
    private static IEnumerable<string> SystemConfigFiles(IReadOnlyDictionary<string, string> env)
    {
        if (!OperatingSystem.IsWindows())
        {
            yield return "/etc/gitconfig";
        }
        else if (env.TryGetValue("ProgramData", out var programData) && IsAbsolute(programData))
        {
            yield return Normalize(Path.Combine(programData, "Git", "config"));
        }
    }

    /// <summary>
    /// The file an include <paramref name="value"/> held by the file <paramref name="holder"/> (null: not a file)
    /// names, as git opens it: absolute, <c>~/</c> against <paramref name="home"/>, or relative to the holder's folder.
    /// Null for anything else (<c>~user/</c>, <c>%(prefix)/</c>, a relative path without a file, and on Windows a root-
    /// or drive-relative path).
    /// </summary>
    internal static string? IncludeTarget(string value, string? holder, string? home)
    {
        if (value.StartsWith("~/", StringComparison.Ordinal))
        {
            return home is not null && IsAbsolute(home) ? Normalize(home) + value[1..] : null;
        }

        if (IsAbsolute(value))
        {
            return Normalize(value);
        }

        if (value.Length == 0 || value.StartsWith('~') || value.StartsWith("%(", StringComparison.Ordinal)
            || holder is null)
        {
            return null;
        }

        // `\x`, `/x` and `C:x` are absolute to git on Windows but depend on its current drive or folder.
        if (OperatingSystem.IsWindows() && (value[0] is '/' or '\\' || (value.Length > 1 && value[1] == ':')))
        {
            return null;
        }

        var folder = Normalize(holder);
        var slash = folder.LastIndexOf('/');
        return slash < 0 ? null : folder[..(slash + 1)] + Normalize(value);
    }

    // Paths.

    /// <summary>How paths are compared: case-insensitively on Windows, else exactly.</summary>
    internal static StringComparer PathComparer { get; } =
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    /// <summary><paramref name="path"/> in git's form: forward slashes on Windows, unchanged elsewhere.</summary>
    internal static string Normalize(string path) => OperatingSystem.IsWindows() ? path.Replace('\\', '/') : path;

    /// <summary>Whether <paramref name="path"/> is absolute: <c>/x</c>, on Windows <c>C:/x</c>, <c>C:\x</c> or a UNC path.</summary>
    internal static bool IsAbsolute(string path) =>
        OperatingSystem.IsWindows() ? Path.IsPathFullyQualified(path) : path.StartsWith('/');

    /// <summary>Whether <paramref name="path"/> names the null device: <c>/dev/null</c>, on Windows <c>NUL</c> too.</summary>
    internal static bool IsNullDevice(string path) =>
        path == "/dev/null" || (OperatingSystem.IsWindows() && string.Equals(path, "NUL", StringComparison.OrdinalIgnoreCase));

    private static bool SamePath(string? left, string? right) =>
        left is not null && right is not null && PathComparer.Equals(Normalize(left), Normalize(right));

    /// <summary>The real path of <paramref name="cwd"/> in git's form, as git reports a work tree's root.</summary>
    private static string? RootOf(string cwd) => RealPath(cwd) is { } real ? Normalize(real) : null;

    /// <summary>
    /// <paramref name="path"/> made absolute with every link resolved (each component, as realpath(3) does); null when
    /// it does not exist or cannot be resolved. Windows short (8.3) names are kept as they are.
    /// </summary>
    internal static string? RealPath(string path)
    {
        string full;
        try
        {
            full = Path.GetFullPath(path);
        }
        catch (Exception error) when (error is ArgumentException or IOException or NotSupportedException)
        {
            return null;
        }

        char[] separators = OperatingSystem.IsWindows() ? ['\\', '/'] : ['/'];
        if (Path.GetPathRoot(full) is not { Length: > 0 } current)
        {
            return null;
        }

        var pending = new Stack<string>();
        PushParts(pending, full[current.Length..], separators);
        var links = 0;
        while (pending.TryPop(out var part))
        {
            if (part == ".")
            {
                continue;
            }

            if (part == "..")
            {
                current = Path.GetDirectoryName(current) ?? current;
                continue;
            }

            var next = Path.Join(current, part);
            string? target;
            try
            {
                target = new FileInfo(next).LinkTarget;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                return null;
            }

            if (target is null)
            {
                current = next;
                continue;
            }

            // As realpath(3): a loop of links (ELOOP) does not resolve.
            if (++links > 40)
            {
                return null;
            }

            if (Path.IsPathRooted(target))
            {
                if (!Path.IsPathFullyQualified(target) || Path.GetPathRoot(target) is not { Length: > 0 } root)
                {
                    return null;
                }

                current = root;
                target = target[root.Length..];
            }

            PushParts(pending, target, separators);
        }

        return Directory.Exists(current) || File.Exists(current) ? current : null;
    }

    private static void PushParts(Stack<string> pending, string path, char[] separators)
    {
        var parts = path.Split(separators, StringSplitOptions.RemoveEmptyEntries);
        for (var i = parts.Length - 1; i >= 0; i--)
        {
            pending.Push(parts[i]);
        }
    }

    /// <summary>
    /// Whether <paramref name="path"/> is on a local volume (not a network share or a file system whose kind is
    /// unknown, such as a user-space mount). A UNC path is never local.
    /// </summary>
    internal static bool IsLocal(string path)
    {
        if (IsNullDevice(path))
        {
            return true;
        }

        try
        {
            var drive = path;
            if (OperatingSystem.IsWindows())
            {
                var root = Path.GetPathRoot(Path.GetFullPath(path));
                if (string.IsNullOrEmpty(root) || root.StartsWith(@"\\", StringComparison.Ordinal))
                {
                    return false;
                }

                drive = root;
            }

            return new DriveInfo(drive).DriveType is DriveType.Fixed or DriveType.Removable or DriveType.Ram
                or DriveType.CDRom;
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException
                                          or NotSupportedException)
        {
            return false;
        }
    }

    /// <summary>The listing environment as one string, keys in ordinal order.</summary>
    private static string EnvironmentKey(IReadOnlyDictionary<string, string> env)
    {
        var builder = new StringBuilder();
        foreach (var (name, value) in env.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            builder.Append(name).Append('=').Append(value).Append('\0');
        }

        return builder.ToString();
    }

    // Entries (called with the lock held).

    /// <summary>Marks <paramref name="key"/> as the most recently used.</summary>
    private void Touch(Key key)
    {
        var index = _order.IndexOf(key);
        if (index < 0)
        {
            return;
        }

        _order.RemoveAt(index);
        _order.Add(key);
    }

    /// <summary>Drops the entry of <paramref name="key"/>.</summary>
    private void Remove(Key key)
    {
        _entries.Remove(key);
        _order.Remove(key);
    }

    /// <summary>Keeps <paramref name="entry"/> under <paramref name="key"/> as the most recently used, dropping the oldest beyond the capacity.</summary>
    private void Store(Entry entry, Key key)
    {
        Remove(key);
        _entries[key] = entry;
        _order.Add(key);
        while (_order.Count > Capacity)
        {
            _entries.Remove(_order[0]);
            _order.RemoveAt(0);
        }
    }
}

/// <summary>What a <see cref="FileSignature"/> is of.</summary>
internal enum FileKind
{
    /// <summary>No such file (or a path component is not a folder, which git also reads as no file).</summary>
    Absent,

    /// <summary>A regular file.</summary>
    File,

    /// <summary>The null device: its times move with every write, so only that it is the null device.</summary>
    Device,

    /// <summary>A folder: its times move with every entry added or removed, so only which folder it is.</summary>
    Directory,
}

/// <summary>
/// How a file looked: compared as a whole, so any change (absent and present included) is a difference. Times are UTC
/// ticks; <see cref="Mode"/> is the Unix mode (0 on Windows). A folder has no size or write time.
/// </summary>
internal sealed record FileSignature(FileKind Kind, long Size = 0, long WriteTime = 0, long CreationTime = 0, int Mode = 0)
{
    private static readonly FileSignature Absent = new(FileKind.Absent);

    private static readonly FileSignature NullDevice = new(FileKind.Device);

    /// <summary>Whether it was written or created at <paramref name="since"/> (UTC ticks) or later.</summary>
    public bool ChangedSince(long since) => WriteTime >= since || CreationTime >= since;

    /// <summary>
    /// The signature of <paramref name="path"/> now, following links as git does when it opens it; null when it cannot
    /// be read (other than missing) or may not be a regular file, a folder or the null device (no portable API tells a
    /// device or a pipe from a file, so off Windows everything under <c>/dev/</c> but <c>/dev/null</c> is in doubt, on
    /// Windows every device path and reserved device name).
    /// </summary>
    public static FileSignature? At(string path)
    {
        if (ReadEnvironmentCache.IsNullDevice(path))
        {
            return NullDevice;
        }

        try
        {
            var target = File.ResolveLinkTarget(path, returnFinalTarget: true)?.FullName ?? path;
            if (IsDevicePath(target))
            {
                return null;
            }

            var folder = new DirectoryInfo(target);
            if (folder.Exists)
            {
                return new(FileKind.Directory, CreationTime: folder.CreationTimeUtc.Ticks, Mode: ModeOf(target));
            }

            var file = new FileInfo(target);
            if (!file.Exists)
            {
                return Absent;
            }

            return new(FileKind.File, file.Length, file.LastWriteTimeUtc.Ticks, file.CreationTimeUtc.Ticks, ModeOf(target));
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return Absent;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException
                                          or NotSupportedException)
        {
            return null;
        }
    }

    private static int ModeOf(string path) => OperatingSystem.IsWindows() ? 0 : (int)File.GetUnixFileMode(path);

    /// <summary>A path that may name a device rather than a file or folder.</summary>
    private static bool IsDevicePath(string path)
    {
        if (!OperatingSystem.IsWindows())
        {
            return path.StartsWith("/dev/", StringComparison.Ordinal);
        }

        if (path.StartsWith(@"\\.\", StringComparison.Ordinal) || path.StartsWith(@"\\?\", StringComparison.Ordinal)
            || path.StartsWith("//./", StringComparison.Ordinal) || path.StartsWith("//?/", StringComparison.Ordinal))
        {
            return true;
        }

        var name = Path.GetFileName(path.TrimEnd('\\', '/'));
        var dot = name.IndexOf('.', StringComparison.Ordinal);
        var stem = (dot < 0 ? name : name[..dot]).TrimEnd(' ').ToUpperInvariant();
        return stem is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$"
               || (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal)
                                        || stem.StartsWith("LPT", StringComparison.Ordinal))
                                    && stem[3] is >= '0' and <= '9' or '¹' or '²' or '³');
    }
}

/// <summary>Where git read a config entry.</summary>
internal abstract record ConfigOrigin
{
    private ConfigOrigin()
    {
    }

    /// <summary>A config file, its path as git opened it (relative paths are relative to the work tree's root).</summary>
    public sealed record File(string Path) : ConfigOrigin;

    /// <summary><c>GIT_CONFIG_COUNT</c>, <c>GIT_CONFIG_PARAMETERS</c> or <c>-c</c>: part of the cache key.</summary>
    public sealed record CommandLine : ConfigOrigin;

    /// <summary><c>--file -</c>.</summary>
    public sealed record StandardInput : ConfigOrigin;

    /// <summary><c>--blob</c>.</summary>
    public sealed record Blob : ConfigOrigin;

    /// <summary>Anything else, or a field that is not UTF-8.</summary>
    public sealed record Unknown : ConfigOrigin;

    /// <summary>
    /// The origin git printed: <c>file:&lt;path&gt;</c>, <c>command line:</c>, <c>standard input:</c> or
    /// <c>blob:&lt;name&gt;</c>.
    /// </summary>
    public static ConfigOrigin Parse(ReadOnlySpan<byte> field)
    {
        var text = GitInvocation.DecodeUTF8(field) ?? "";
        if (text.StartsWith("file:", StringComparison.Ordinal) && text.Length > 5)
        {
            return new File(text[5..]);
        }

        return text switch
        {
            "command line:" => new CommandLine(),
            "standard input:" => new StandardInput(),
            _ when text.StartsWith("blob:", StringComparison.Ordinal) => new Blob(),
            _ => new Unknown(),
        };
    }
}

/// <summary>
/// One entry of <c>git config -z --show-origin --list</c>: <c>&lt;origin&gt;\0&lt;key&gt;\n&lt;value&gt;\0</c>, or
/// <c>&lt;origin&gt;\0&lt;key&gt;\0</c> for a key without a value.
/// </summary>
internal sealed record ConfigRecord(ConfigOrigin Origin, ReadOnlyMemory<byte> Key, ReadOnlyMemory<byte>? Value)
{
    /// <summary>
    /// The records of a listing. Throws <see cref="GitInvocation.ReadSafetyErrorKind.ConfigListingMalformed"/> unless
    /// it is whole records, so a driver name is never read from the wrong field.
    /// </summary>
    public static List<ConfigRecord> Parse(byte[] data)
    {
        if (data.Length == 0)
        {
            return [];
        }

        if (data[^1] != 0)
        {
            throw new GitInvocation.ReadSafetyError(GitInvocation.ReadSafetyErrorKind.ConfigListingMalformed);
        }

        var fields = new List<ReadOnlyMemory<byte>>();
        var start = 0;
        for (var i = 0; i < data.Length; i++)
        {
            if (data[i] == 0)
            {
                fields.Add(data.AsMemory(start, i - start));
                start = i + 1;
            }
        }

        if (fields.Count % 2 != 0)
        {
            throw new GitInvocation.ReadSafetyError(GitInvocation.ReadSafetyErrorKind.ConfigListingMalformed);
        }

        var records = new List<ConfigRecord>(fields.Count / 2);
        for (var i = 0; i < fields.Count; i += 2)
        {
            var entry = fields[i + 1];
            var newline = entry.Span.IndexOf((byte)'\n');
            records.Add(newline < 0
                ? new ConfigRecord(ConfigOrigin.Parse(fields[i].Span), entry, null)
                : new ConfigRecord(ConfigOrigin.Parse(fields[i].Span), entry[..newline], entry[(newline + 1)..]));
        }

        return records;
    }
}

/// <summary>What <c>git rev-parse</c> says about a work tree, for a folder that is its root; paths in git's form.</summary>
/// <param name="Root">The work tree's root (git's own folder while it lists).</param>
/// <param name="GitDir">The worktree's own git dir (<c>.git/worktrees/&lt;name&gt;</c> for a linked worktree).</param>
/// <param name="CommonDir">The git dir shared by every worktree (the main one's <c>.git</c>).</param>
/// <param name="Config">The repo config (the common one for a linked worktree).</param>
/// <param name="WorktreeConfig">The worktree's <c>config.worktree</c>, read when <c>extensions.worktreeConfig</c> is on.</param>
/// <param name="Head">The worktree's own HEAD.</param>
internal sealed record Located(string Root, string GitDir, string CommonDir, string Config, string WorktreeConfig, string Head)
{
    /// <summary>
    /// Asks git, in the listing environment (it runs nothing); null when <paramref name="cwd"/> is not a work tree's
    /// root or git fails (a bare repo, no repo).
    /// </summary>
    public static async Task<Located?> FindAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct)
    {
        string[] args =
        [
            "rev-parse", "--path-format=absolute", "--show-toplevel", "--show-prefix", "--absolute-git-dir",
            "--git-common-dir", "--git-path", "config", "--git-path", "config.worktree", "--git-path", "HEAD",
        ];
        GitResult result;
        try
        {
            result = await runner.RunAsync(args, cwd, env, timeout: TimeSpan.FromSeconds(10), ct: ct).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            return null;
        }

        if (GitInvocation.DecodeUTF8(result.Stdout) is not { } text)
        {
            return null;
        }

        var lines = text.Split('\n');
        // Seven lines and the final newline; an empty prefix means `cwd` is the root.
        if (lines.Length != 8 || lines[7].Length != 0 || lines[1].Length != 0
            || !new[] { lines[0], lines[2], lines[3], lines[4], lines[5], lines[6] }.All(ReadEnvironmentCache.IsAbsolute))
        {
            return null;
        }

        var paths = lines.Select(ReadEnvironmentCache.Normalize).ToArray();
        return new Located(paths[0], paths[2], paths[3], paths[4], paths[5], paths[6]);
    }
}

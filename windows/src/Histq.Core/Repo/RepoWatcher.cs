// Watches a repo's worktree and git dirs and asks for a refresh of what changed: `Status` for the worktree and the
// index, `Refs` for HEAD, refs and packed-refs. Objects and lock files are ignored, and a burst of changes becomes one
// refresh 250 ms after the last one. Ported from RepoWatcher.swift at 6fa6d40, with FileSystemWatcher in place of
// FSEvents (a watcher error, such as its buffer overflowing, stands for FSEvents' "must scan subdirs").
namespace Histq.Core;

/// <summary>What a refresh reloads. <see cref="Refs"/> also reloads the log when a ref moved.</summary>
[Flags]
public enum RefreshScope
{
    None = 0,
    Status = 1 << 0,
    Refs = 1 << 1,
    Log = 1 << 2,
}

/// <summary>The folders a repo's watcher covers, from <c>git rev-parse</c> run with the read environment.</summary>
/// <param name="Worktree">The worktree's top folder.</param>
/// <param name="GitDir">The worktree's git dir (<c>.git</c>, or <c>&lt;common&gt;/worktrees/&lt;name&gt;</c> for a
/// linked worktree): HEAD and the index.</param>
/// <param name="CommonDir">The repo's shared git dir: refs and packed-refs (the same as <paramref name="GitDir"/>
/// outside a linked worktree).</param>
public sealed record RepoDirectories(string Worktree, string GitDir, string CommonDir)
{
    /// <summary>
    /// Resolves the folders of the repo at <paramref name="cwd"/>, each as its real path (every link resolved, as the
    /// file system reports changes). <paramref name="env"/> is the read environment for <paramref name="cwd"/>. Throws
    /// <see cref="GitError"/> when <paramref name="cwd"/> is not in a worktree (a plain folder, a bare repo) or a folder
    /// is a network (UNC) or device path (see <see cref="Parse"/>).
    /// </summary>
    public static async Task<RepoDirectories> ResolveAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct = default)
    {
        var result = await runner.RunAsync(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"], cwd, env,
            timeout: TimeSpan.FromSeconds(10), ct: ct).ConfigureAwait(false);
        return Parse(result.Text, result.ExitCode, PathFlavor.Host, WorkspaceDisk.Host.RealPath);
    }

    /// <summary>
    /// The folders in <c>rev-parse</c>'s <paramref name="output"/>, each made native and resolved with
    /// <paramref name="realPath"/>. The repo is untrusted: a <c>.git</c> file (<c>gitdir: //host/share/x</c>) or a
    /// <c>commondir</c> file can name a network share, and watching or probing a share sends the user's credentials
    /// to its host. So a UNC or device path (<paramref name="flavor"/>'s rules) throws <see cref="GitError"/>, checked
    /// before any file system call and again on the real path (a link can lead to a share); so does a folder whose real
    /// path cannot be had.
    /// </summary>
    internal static RepoDirectories Parse(
        string output, int exitCode, PathFlavor flavor, Func<string, string?> realPath)
    {
        GitError Refused() => GitError.Other(exitCode, "unexpected rev-parse output");
        var lines = output.Split('\n');
        if (lines.Length < 3)
        {
            throw Refused();
        }

        var folders = new string[3];
        for (var i = 0; i < folders.Length; i++)
        {
            if (flavor.IsUncOrDevice(lines[i]))
            {
                throw Refused();
            }

            var native = StashWorktreeReader.NativePath(lines[i]);
            if (flavor.IsUncOrDevice(native) || !flavor.IsAbsolute(native)
                || realPath(native) is not { } real || flavor.IsUncOrDevice(real))
            {
                throw Refused();
            }

            folders[i] = real;
        }

        return new RepoDirectories(folders[0], folders[1], folders[2]);
    }
}

/// <summary>
/// File system watchers on a repo's worktree and git dirs. Changes are classified (<see cref="ScopeOf"/>) and
/// debounced; the callback gets each coalesced scope and the worktree paths behind its <see cref="RefreshScope.Status"/>
/// on a thread-pool thread (callers marshal to their UI thread). Reads by Histq write nothing in these folders (no
/// optional locks, no index refresh), so a refresh never triggers another one. Dispose it when the repo closes: at
/// most one callback already in flight may still run after it returns, none starts later.
/// </summary>
/// <param name="ownStateDir">Histq's own state folder (its logs), whose changes never count: a repo that contains it
/// (a dotfiles repo in the home folder, a QA run on the Histq checkout) must not refresh on them.</param>
public sealed class RepoWatcher(string? ownStateDir = null) : IDisposable
{
    /// <summary>The quiet time after the last change before the refresh runs.</summary>
    public static readonly TimeSpan DebounceInterval = TimeSpan.FromMilliseconds(250);

    /// <summary>The most worktree paths handed on with a change; more are not listed (null).</summary>
    public const int MaxPaths = 200;

    /// <summary>Each watcher's buffer: the largest the OS allows, so a burst (a checkout) overflows it rarely.</summary>
    public const int BufferSize = 64 * 1024;

    private readonly string? _ownFiles = ownStateDir is null ? null : WorkspaceDisk.Host.RealPath(ownStateDir) ?? ownStateDir;

    // Every field below is guarded by `_lock`.
    private readonly Lock _lock = new();
    private readonly List<FileSystemWatcher> _watchers = [];
    private Timer? _debounce;
    private RepoDirectories? _directories;
    private Action<RefreshScope, IReadOnlyList<string>?>? _onChange;
    private RefreshScope _pending;

    /// <summary>
    /// The worktree paths (relative to it, with <c>/</c>) behind the pending <see cref="RefreshScope.Status"/>; null when
    /// it came from anything else (the index, a submodule's state, an overflow) or more than <see cref="MaxPaths"/> paths
    /// changed.
    /// </summary>
    private HashSet<string>? _pendingPaths = new(StringComparer.Ordinal);

    /// <summary>When the last counted change arrived (<see cref="Environment.TickCount64"/>).</summary>
    private long _lastChange;

    private bool _stopped;

    /// <summary>
    /// Starts watching <paramref name="directories"/> (once; later calls are ignored): one watcher, with its
    /// subfolders, per folder not already inside another (the git dir usually is in the worktree).
    /// <paramref name="onChange"/> gets each coalesced scope and the worktree paths behind its status (null when not
    /// only worktree paths, or too many); it must not throw. Throws when a folder cannot be watched.
    /// </summary>
    public void Start(RepoDirectories directories, Action<RefreshScope, IReadOnlyList<string>?> onChange)
    {
        var roots = new List<string>();
        foreach (var path in new[] { directories.Worktree, directories.GitDir, directories.CommonDir })
        {
            if (!roots.Any(root => IsInside(path, root)))
            {
                roots.RemoveAll(root => IsInside(root, path));
                roots.Add(path);
            }
        }

        lock (_lock)
        {
            if (_stopped || _directories is not null)
            {
                return;
            }

            _directories = directories;
            _onChange = onChange;
            _debounce = new Timer(_ => Fire());
            foreach (var root in roots)
            {
                var watcher = new FileSystemWatcher(root)
                {
                    IncludeSubdirectories = true,
                    InternalBufferSize = BufferSize,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite
                        | NotifyFilters.Size | NotifyFilters.Attributes,
                };
                // A folder's own "changed" (Windows reports one for the folder a file was added to or removed from) is
                // no change of its own: the file's event counts, so a lock file made in refs/heads stays ignored.
                watcher.Changed += (_, e) =>
                {
                    if (!Directory.Exists(e.FullPath))
                    {
                        Received(e.FullPath);
                    }
                };
                watcher.Created += (_, e) => Received(e.FullPath);
                watcher.Deleted += (_, e) => Received(e.FullPath);
                watcher.Renamed += (_, e) =>
                {
                    Received(e.OldFullPath);
                    Received(e.FullPath);
                };
                // Changes were dropped (the buffer overflowed) or the folder went away: reload everything.
                watcher.Error += (_, _) => Received(null);
                _watchers.Add(watcher);
                watcher.EnableRaisingEvents = true;
            }
        }
    }

    /// <summary>Stops the watchers and drops a pending refresh. Idempotent; also stops a later <see cref="Start"/>.</summary>
    public void Dispose()
    {
        List<FileSystemWatcher> watchers;
        Timer? debounce;
        lock (_lock)
        {
            _stopped = true;
            _onChange = null;
            watchers = [.. _watchers];
            _watchers.Clear();
            debounce = _debounce;
            _debounce = null;
        }

        // Outside the lock: a handler in flight waits for it.
        foreach (var watcher in watchers)
        {
            watcher.Dispose();
        }

        debounce?.Dispose();
    }

    /// <summary>
    /// The refresh a change at <paramref name="path"/> needs: git-dir paths first (only HEAD, refs, packed-refs, the
    /// index, the merge, cherry-pick and revert heads and a submodule's state count; objects, logs, worktrees and the
    /// rest are ignored), then any other worktree path is <see cref="RefreshScope.Status"/>. git's lock files
    /// (<c>*.lock</c> in a git dir) never count: git renames a lock over the real file, which is the event that matters.
    /// A worktree file such as <c>Cargo.lock</c> does. Histq's own files (<paramref name="ownFiles"/>) never count.
    /// </summary>
    internal static RefreshScope ScopeOf(string path, RepoDirectories directories, string? ownFiles)
    {
        if (ownFiles is not null && IsInside(path, ownFiles))
        {
            return RefreshScope.None;
        }

        foreach (var dir in new[] { directories.GitDir, directories.CommonDir })
        {
            if (RelativePath(path, dir) is not { } relative)
            {
                continue;
            }

            if (relative.EndsWith(".lock", StringComparison.Ordinal))
            {
                return RefreshScope.None;
            }

            switch (relative)
            {
                case "HEAD" or "packed-refs":
                    return RefreshScope.Refs;
                case "index":
                    return RefreshScope.Status;
                // A merge, cherry-pick or revert started or ended: the status shows the conflicts.
                case "MERGE_HEAD" or "CHERRY_PICK_HEAD" or "REVERT_HEAD":
                    return RefreshScope.Status;
                default:
                    if (relative.StartsWith("refs/", StringComparison.Ordinal))
                    {
                        return RefreshScope.Refs;
                    }

                    // A submodule's HEAD, index or refs moved: its row's state changes. Only in this worktree's git dir
                    // (a linked worktree keeps its own `modules/`).
                    return string.Equals(dir, directories.GitDir, StringComparison.Ordinal) && IsSubmoduleState(relative)
                        ? RefreshScope.Status
                        : RefreshScope.None;
            }
        }

        return IsInside(path, directories.Worktree) ? RefreshScope.Status : RefreshScope.None;
    }

    /// <summary>Adds the scope of <paramref name="path"/> (null: everything) and restarts the debounce.</summary>
    private void Received(string? path)
    {
        lock (_lock)
        {
            if (_stopped || _directories is not { } directories || _debounce is null)
            {
                return;
            }

            if (path is null)
            {
                _pending |= RefreshScope.Status | RefreshScope.Refs;
                _pendingPaths = null;
            }
            else
            {
                var found = ScopeOf(path, directories, _ownFiles);
                if (found == RefreshScope.None)
                {
                    return;
                }

                _pending |= found;
                if (found.HasFlag(RefreshScope.Status) && _pendingPaths is { } paths)
                {
                    // A worktree file, not the index or a submodule's state in a git dir. An ignore or attributes file
                    // changes other paths' status even when it is ignored itself, and a leading `:` would be read as
                    // pathspec magic by `git check-ignore`: these are not listed.
                    var inGitDir = IsInside(path, directories.GitDir) || IsInside(path, directories.CommonDir);
                    var name = Path.GetFileName(path);
                    if (!inGitDir && name is not (".gitignore" or ".gitattributes")
                        && RelativePath(path, directories.Worktree) is { Length: > 0 } relative
                        && !relative.StartsWith(':') && paths.Count < MaxPaths)
                    {
                        paths.Add(relative);
                    }
                    else
                    {
                        _pendingPaths = null;
                    }
                }
            }

            _lastChange = Environment.TickCount64;
            _debounce.Change(DebounceInterval, Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>On a timer thread: hands the coalesced scope on once the changes have been quiet for the interval.</summary>
    private void Fire()
    {
        Action<RefreshScope, IReadOnlyList<string>?>? onChange;
        RefreshScope scope;
        List<string>? paths;
        lock (_lock)
        {
            if (_stopped || _pending == RefreshScope.None || _onChange is null || _debounce is null)
            {
                return;
            }

            // A change that came in while this tick was already queued: wait for the rest of its quiet time.
            var quiet = Environment.TickCount64 - _lastChange;
            if (quiet < (long)DebounceInterval.TotalMilliseconds)
            {
                _debounce.Change(DebounceInterval - TimeSpan.FromMilliseconds(quiet), Timeout.InfiniteTimeSpan);
                return;
            }

            scope = _pending;
            paths = _pendingPaths?.Order(StringComparer.Ordinal).ToList();
            onChange = _onChange;
            _pending = RefreshScope.None;
            _pendingPaths = new HashSet<string>(StringComparer.Ordinal);
        }

        onChange(scope, paths);
    }

    /// <summary>
    /// <c>modules/&lt;name&gt;/HEAD</c>, <c>modules/&lt;name&gt;/index</c> or <c>modules/&lt;name&gt;/refs/…</c>, nested
    /// submodules' too (<c>&lt;name&gt;</c> may hold slashes, so no depth is assumed). Their reflogs (<c>logs/HEAD</c>,
    /// <c>logs/refs/…</c>) match too: git writes them with the HEAD or ref they follow, inside the same debounce.
    /// </summary>
    private static bool IsSubmoduleState(string relative)
    {
        if (!relative.StartsWith("modules/", StringComparison.Ordinal))
        {
            return false;
        }

        var parts = relative.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts[^1] is "HEAD" or "index" || parts[..^1].Contains("refs", StringComparer.Ordinal);
    }

    /// <summary>
    /// <paramref name="path"/> relative to <paramref name="root"/>, with <c>/</c> between its parts ("" for the root
    /// itself), or null when it is outside.
    /// </summary>
    private static string? RelativePath(string path, string root)
    {
        if (string.Equals(path, root, StringComparison.Ordinal))
        {
            return "";
        }

        var separator = Path.DirectorySeparatorChar;
        var prefix = root.EndsWith(separator) ? root : root + separator;
        if (!path.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }

        var relative = path[prefix.Length..];
        return separator == '/' ? relative : relative.Replace(separator, '/');
    }

    /// <summary>Whether <paramref name="path"/> is <paramref name="root"/> or inside it.</summary>
    private static bool IsInside(string path, string root) => RelativePath(path, root) is not null;
}

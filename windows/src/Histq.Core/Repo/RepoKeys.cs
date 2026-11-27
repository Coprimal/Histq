// The keys a worktree's state files are named by (its undo journal, its saved graph view): the same on the Mac and
// here for the same real path, so no path character ever reaches a file name. Ported from RepoSession.stateKey and
// ProfileStore.repoKey at 6fa6d40.
using System.Security.Cryptography;
using System.Text;

namespace Histq.Core;

public static class RepoKeys
{
    /// <summary>
    /// <paramref name="path"/>'s real path (every link resolved, as realpath(3); the Mac's <c>/var</c> becomes
    /// <c>/private/var</c>), or its standardized path when it cannot be resolved (it does not exist).
    /// </summary>
    public static string RepoKey(string path)
    {
        var standardized = PathFlavor.Host.Standardized(path);
        return WorkspaceDisk.Host.RealPath(standardized) ?? standardized;
    }

    /// <summary>
    /// A file name for the worktree's state: the first 16 bytes of the SHA-256 of the UTF-8 bytes of its
    /// <see cref="RepoKey"/>, as 32 lowercase hex digits, so each worktree of a repo has its own state.
    /// </summary>
    public static string StateKey(string path) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(RepoKey(path))).AsSpan(0, 16));
}

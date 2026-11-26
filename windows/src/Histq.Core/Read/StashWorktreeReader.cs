// Reads the stashes (each with the commit it was made on, where the graph attaches its row) and the worktrees of a
// repository. git prints a worktree's path in its own form (`C:/Users/...` on Windows); it becomes a native path here.
using System.Globalization;
using System.Text;

namespace Histq.Core;

/// <param name="Index"><c>n</c> of <c>stash@{n}</c>; 0 is the newest.</param>
/// <param name="Hash">The stash commit (<c>stash@{n}</c>).</param>
/// <param name="Base">The commit the stash was made on (<c>stash@{n}^1</c>).</param>
/// <param name="OtherParents">The index commit (<c>^2</c>) and, for <c>stash -u</c>/<c>-a</c>, the untracked files
/// commit (<c>^3</c>).</param>
/// <param name="Message">The reflog message, e.g. <c>On main: guide tweaks</c> or <c>WIP on main: &lt;subject&gt;</c>.</param>
public sealed record Stash(
    int Index, string Hash, string Base, IReadOnlyList<string> OtherParents, string Message, DateTimeOffset Date)
{
    public string Id => Hash;

    /// <summary>The ref selector for commands (<c>stash@{n}</c>).</summary>
    public string Selector => string.Create(CultureInfo.InvariantCulture, $"stash@{{{Index}}}");

    public bool Equals(Stash? other) =>
        other is not null
        && Index == other.Index
        && string.Equals(Hash, other.Hash, StringComparison.Ordinal)
        && string.Equals(Base, other.Base, StringComparison.Ordinal)
        && OtherParents.SequenceEqual(other.OtherParents, StringComparer.Ordinal)
        && string.Equals(Message, other.Message, StringComparison.Ordinal)
        && Date == other.Date;

    public override int GetHashCode() =>
        HashCode.Combine(Index, StringComparer.Ordinal.GetHashCode(Hash), OtherParents.Count, Date);
}

/// <param name="Path">The absolute path git reports, as a native path (backslashes on Windows).</param>
/// <param name="Head">The checked-out commit; null for a bare repository or an unborn branch.</param>
/// <param name="Branch">The full branch ref, e.g. <c>refs/heads/wt</c>; null when detached or bare.</param>
/// <param name="LockReason">The lock reason when locked (empty when no reason was given), null when not locked.</param>
/// <param name="PrunableReason">Why git could prune it (its folder is gone), null when it is fine.</param>
/// <param name="IsMain">The main worktree (git lists it first).</param>
public sealed record Worktree(
    string Path,
    string? Head,
    string? Branch,
    bool IsDetached,
    bool IsBare,
    string? LockReason,
    string? PrunableReason,
    bool IsMain)
{
    public bool IsLocked => LockReason is not null;

    public bool IsPrunable => PrunableReason is not null;
}

public static class StashWorktreeReader
{
    /// <summary><c>stash list</c> walks the <c>refs/stash</c> reflog (and handles a repo without stashes). The message
    /// comes last: reflog messages are single-line.</summary>
    public static IReadOnlyList<string> StashArguments { get; } = ["stash", "list", "--format=%H%x1f%P%x1f%ct%x1f%gs"];

    public static IReadOnlyList<string> WorktreeArguments { get; } = ["worktree", "list", "--porcelain", "-z"];

    /// <summary>
    /// The stashes, newest first. <paramref name="env"/> must be the read environment built by
    /// <see cref="GitInvocation.ReadEnvironmentAsync"/> for this <paramref name="cwd"/>. Throws <see cref="GitError"/>.
    /// </summary>
    public static async Task<IReadOnlyList<Stash>> StashesAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct = default) =>
        ParseStashes((await runner.RunAsync(StashArguments, cwd, env, ct: ct).ConfigureAwait(false)).Text);

    /// <summary>
    /// The worktrees, the main one first. <paramref name="env"/> must be the read environment built by
    /// <see cref="GitInvocation.ReadEnvironmentAsync"/> for this <paramref name="cwd"/>. Throws <see cref="GitError"/>.
    /// </summary>
    public static async Task<IReadOnlyList<Worktree>> WorktreesAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct = default) =>
        ParseWorktrees((await runner.RunAsync(WorktreeArguments, cwd, env, ct: ct).ConfigureAwait(false)).Stdout);

    internal static IReadOnlyList<Stash> ParseStashes(string output)
    {
        var stashes = new List<Stash>();
        foreach (var line in ReadParsing.SplitText(output, '\n'))
        {
            var fields = ReadParsing.SplitText(line, '\u001F', maxSplits: 3, omitEmpty: false);
            if (fields.Count != 4 || !LogParser.IsHash(fields[0]))
            {
                continue;
            }

            var parents = ReadParsing.SplitText(fields[1], ' ');
            if (parents.Count == 0)
            {
                continue;
            }

            var date = ReadParsing.UnixDate(ReadParsing.Seconds(fields[2]) ?? 0);
            stashes.Add(new Stash(stashes.Count, fields[0], parents[0], parents[1..], fields[3], date));
        }

        return stashes;
    }

    /// <summary>Each attribute ends with NUL and an empty attribute ends a worktree.</summary>
    internal static IReadOnlyList<Worktree> ParseWorktrees(ReadOnlySpan<byte> output)
    {
        var worktrees = new List<Worktree>();
        var attributes = new List<byte[]>();
        foreach (var range in ReadParsing.Split(output, (byte)0, omitEmpty: false))
        {
            var field = output[range];
            if (field.IsEmpty)
            {
                if (MakeWorktree(attributes, isMain: worktrees.Count == 0) is { } worktree)
                {
                    worktrees.Add(worktree);
                }

                attributes.Clear();
            }
            else
            {
                attributes.Add(field.ToArray());
            }
        }

        if (MakeWorktree(attributes, isMain: worktrees.Count == 0) is { } last)
        {
            worktrees.Add(last);
        }

        return worktrees;
    }

    /// <summary>
    /// <paramref name="path"/> as git printed it, made native: on Windows <see cref="System.IO.Path.GetFullPath(string)"/>
    /// (<c>C:/Users/x</c> becomes <c>C:\Users\x</c>); unchanged elsewhere, and unchanged when it is empty or cannot be
    /// made a full path.
    /// </summary>
    internal static string NativePath(string path)
    {
        if (!OperatingSystem.IsWindows() || path.Length == 0)
        {
            return path;
        }

        try
        {
            return System.IO.Path.GetFullPath(path);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException
                                          or IOException or System.Security.SecurityException)
        {
            return path;
        }
    }

    /// <summary>An attribute is <c>&lt;key&gt;</c> or <c>&lt;key&gt; &lt;value&gt;</c>, split as bytes so a value keeps
    /// every character.</summary>
    private static Worktree? MakeWorktree(List<byte[]> attributes, bool isMain)
    {
        string? path = null;
        string? head = null;
        string? branch = null;
        var detached = false;
        var bare = false;
        string? lockReason = null;
        string? prunableReason = null;
        foreach (var attribute in attributes)
        {
            ReadOnlySpan<byte> bytes = attribute;
            var parts = ReadParsing.Split(bytes, (byte)' ', maxSplits: 1, omitEmpty: false);
            var key = Encoding.UTF8.GetString(bytes[parts[0]]);
            var value = parts.Count > 1 ? Encoding.UTF8.GetString(bytes[parts[1]]) : "";
            switch (key)
            {
                case "worktree":
                    path = value;
                    break;
                case "HEAD":
                    head = value.All(c => c == '0') ? null : value;
                    break;
                case "branch":
                    branch = value;
                    break;
                case "detached":
                    detached = true;
                    break;
                case "bare":
                    bare = true;
                    break;
                case "locked":
                    lockReason = value;
                    break;
                case "prunable":
                    prunableReason = value;
                    break;
            }
        }

        return path is null
            ? null
            : new Worktree(NativePath(path), head, branch, detached, bare, lockReason, prunableReason, isMain);
    }
}

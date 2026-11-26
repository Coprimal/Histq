// Reads the working tree status (`git status --porcelain=v2 -z`): the branch header and one entry per changed, renamed,
// conflicted or untracked path. Paths are taken byte for byte (NUL-separated, never quoted), so names such as `-rf` or
// names with spaces come through unchanged. Paths stay as git prints them (forward slashes, relative to the root).
using System.Text;

namespace Histq.Core;

/// <summary>The branch header of a status.</summary>
/// <param name="Commit">The HEAD commit; null on an unborn branch (<c>(initial)</c>).</param>
/// <param name="Name">The branch name; null when HEAD is detached.</param>
/// <param name="Upstream">The short upstream name, e.g. <c>origin/main</c>.</param>
/// <param name="Ahead">Commits ahead of the upstream; null without one (or when it is gone).</param>
/// <param name="Behind">Commits behind the upstream; null without one (or when it is gone).</param>
public sealed record WorkingStatusBranch(string? Commit, string? Name, string? Upstream, int? Ahead, int? Behind);

/// <param name="Entries">In git's order.</param>
public sealed record WorkingStatus(WorkingStatusBranch Branch, IReadOnlyList<StatusEntry> Entries)
{
    public IReadOnlyList<StatusEntry> Conflicted => Entries.Where(entry => entry.Kind == StatusEntryKind.Unmerged).ToList();

    /// <summary>Entries with a change in the index (staged).</summary>
    public IReadOnlyList<StatusEntry> Staged => Entries.Where(entry => entry.IsStaged).ToList();

    /// <summary>Tracked entries with a change in the working tree (unstaged), conflicts excluded.</summary>
    public IReadOnlyList<StatusEntry> Unstaged => Entries.Where(entry => entry.IsUnstaged).ToList();

    public IReadOnlyList<StatusEntry> Untracked =>
        Entries.Where(entry => entry.Kind == StatusEntryKind.Untracked).ToList();

    public bool Equals(WorkingStatus? other) =>
        other is not null && Branch == other.Branch && Entries.SequenceEqual(other.Entries);

    public override int GetHashCode() => HashCode.Combine(Branch, Entries.Count);
}

/// <summary>The kind of a <see cref="StatusEntry"/>.</summary>
public enum StatusEntryKind
{
    Ordinary,

    /// <summary>Staged rename or copy (<c>git mv</c>, or detected in the index); <see cref="StatusEntry.OriginalPath"/> is set.</summary>
    Renamed,
    Copied,

    /// <summary>A conflict; <see cref="StatusEntry.Index"/>/<see cref="StatusEntry.Worktree"/> hold git's two letters
    /// (<c>UU</c>, <c>AA</c>, <c>DU</c>, <c>UD</c>, <c>AU</c>, <c>UA</c>, <c>DD</c>).</summary>
    Unmerged,
    Untracked,
    Ignored,
}

/// <summary>git's one-letter change code for one side of an entry; <c>(char)change</c> is the letter.</summary>
public enum StatusEntryChange : ushort
{
    Unmodified = '.',
    Modified = 'M',
    TypeChanged = 'T',
    Added = 'A',
    Deleted = 'D',
    Renamed = 'R',
    Copied = 'C',
    Unmerged = 'U',
}

/// <param name="OriginalPath">The path before a rename or copy.</param>
/// <param name="Index">The staged side (<c>X</c>). <see cref="StatusEntryChange.Unmodified"/> for untracked and ignored
/// entries.</param>
/// <param name="Worktree">The working tree side (<c>Y</c>). <see cref="StatusEntryChange.Unmodified"/> for untracked
/// and ignored entries.</param>
/// <param name="IsSubmodule">A submodule (<c>S...</c> in git's <c>&lt;sub&gt;</c> field).</param>
/// <param name="Similarity">The rename or copy score, e.g. <c>R100</c> gives 100.</param>
public sealed record StatusEntry(
    StatusEntryKind Kind,
    string Path,
    string? OriginalPath = null,
    StatusEntryChange Index = StatusEntryChange.Unmodified,
    StatusEntryChange Worktree = StatusEntryChange.Unmodified,
    bool IsSubmodule = false,
    int? Similarity = null)
{
    /// <summary>Untracked and ignored entries are unmodified on both sides, so neither is staged nor unstaged.</summary>
    public bool IsStaged => Kind != StatusEntryKind.Unmerged && Index != StatusEntryChange.Unmodified;

    public bool IsUnstaged => Kind != StatusEntryKind.Unmerged && Worktree != StatusEntryChange.Unmodified;
}

public static class StatusReader
{
    /// <summary>
    /// <c>--ignore-submodules=dirty</c>: git never recurses into a submodule's working tree (whose config could name
    /// other filters); submodule commit changes still show.
    /// </summary>
    public static IReadOnlyList<string> Arguments { get; } =
    [
        "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=dirty",
    ];

    /// <summary>
    /// Reads the status of the worktree at <paramref name="cwd"/>. <paramref name="env"/> must be the read environment
    /// built by <see cref="GitInvocation.ReadEnvironmentAsync"/> for this <paramref name="cwd"/>. Throws
    /// <see cref="GitError"/>.
    /// </summary>
    public static async Task<WorkingStatus> ReadAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct = default) =>
        Parse((await runner.RunAsync(Arguments, cwd, env, ct: ct).ConfigureAwait(false)).Stdout);

    internal static WorkingStatus Parse(ReadOnlySpan<byte> output)
    {
        string? commit = null;
        string? name = null;
        string? upstream = null;
        int? ahead = null;
        int? behind = null;
        var entries = new List<StatusEntry>();
        var fields = ReadParsing.Split(output, (byte)0, omitEmpty: false);
        for (var next = 0; next < fields.Count;)
        {
            var field = output[fields[next++]];
            if (field.IsEmpty)
            {
                continue;
            }

            switch (field[0])
            {
                case (byte)'#':
                {
                    var parts = ReadParsing.SplitText(Text(field), ' ', maxSplits: 2);
                    if (parts.Count != 3)
                    {
                        continue;
                    }

                    switch (parts[1])
                    {
                        case "branch.oid":
                            commit = parts[2] == "(initial)" ? null : parts[2];
                            break;
                        case "branch.head":
                            name = parts[2] == "(detached)" ? null : parts[2];
                            break;
                        case "branch.upstream":
                            upstream = parts[2];
                            break;
                        case "branch.ab":
                            var counts = ReadParsing.SplitText(parts[2], ' ');
                            if (counts.Count == 2)
                            {
                                ahead = ReadParsing.Integer(DropFirst(counts[0]));
                                behind = ReadParsing.Integer(DropFirst(counts[1]));
                            }

                            break;
                    }

                    break;
                }

                case (byte)'1':
                {
                    // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                    var parts = Split(field, 9);
                    if (parts.Count != 9)
                    {
                        continue;
                    }

                    entries.Add(Entry(StatusEntryKind.Ordinary, field[parts[1]], field[parts[2]], field[parts[8]]));
                    break;
                }

                case (byte)'2':
                {
                    // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>, then <origPath> as the next field
                    var parts = Split(field, 10);
                    var original = next < fields.Count ? Text(output[fields[next++]]) : null;
                    if (parts.Count != 10)
                    {
                        continue;
                    }

                    var score = field[parts[8]];
                    var kind = !score.IsEmpty && score[0] == (byte)'C' ? StatusEntryKind.Copied : StatusEntryKind.Renamed;
                    entries.Add(Entry(
                        kind, field[parts[1]], field[parts[2]], field[parts[9]], original,
                        ReadParsing.Integer(Text(score.IsEmpty ? score : score[1..]))));
                    break;
                }

                case (byte)'u':
                {
                    // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                    var parts = Split(field, 11);
                    if (parts.Count != 11)
                    {
                        continue;
                    }

                    entries.Add(Entry(StatusEntryKind.Unmerged, field[parts[1]], field[parts[2]], field[parts[10]]));
                    break;
                }

                case (byte)'?' or (byte)'!':
                    if (field.Length <= 2)
                    {
                        continue;
                    }

                    entries.Add(new StatusEntry(
                        field[0] == (byte)'?' ? StatusEntryKind.Untracked : StatusEntryKind.Ignored, Text(field[2..])));
                    break;
            }
        }

        return new WorkingStatus(new WorkingStatusBranch(commit, name, upstream, ahead, behind), entries);
    }

    private static StatusEntry Entry(
        StatusEntryKind kind, ReadOnlySpan<byte> xy, ReadOnlySpan<byte> sub, ReadOnlySpan<byte> path,
        string? originalPath = null, int? similarity = null) =>
        new(kind, Text(path), originalPath,
            xy.Length == 2 ? Change(xy[0]) : StatusEntryChange.Unmodified,
            xy.Length == 2 ? Change(xy[1]) : StatusEntryChange.Unmodified,
            !sub.IsEmpty && sub[0] == (byte)'S', similarity);

    /// <summary>The change git's letter <paramref name="code"/> stands for; unmodified for any other byte.</summary>
    private static StatusEntryChange Change(byte code) => code switch
    {
        (byte)'M' => StatusEntryChange.Modified,
        (byte)'T' => StatusEntryChange.TypeChanged,
        (byte)'A' => StatusEntryChange.Added,
        (byte)'D' => StatusEntryChange.Deleted,
        (byte)'R' => StatusEntryChange.Renamed,
        (byte)'C' => StatusEntryChange.Copied,
        (byte)'U' => StatusEntryChange.Unmerged,
        _ => StatusEntryChange.Unmodified,
    };

    /// <summary>Splits a record on spaces into at most <paramref name="count"/> parts; the last part (the path) keeps its
    /// spaces.</summary>
    private static List<Range> Split(ReadOnlySpan<byte> field, int count) =>
        ReadParsing.Split(field, (byte)' ', maxSplits: count - 1, omitEmpty: false);

    /// <summary>The text without its first character (Swift's <c>dropFirst()</c>).</summary>
    private static string DropFirst(string text) => text.Length == 0 ? text : text[1..];

    /// <summary><paramref name="bytes"/> decoded as UTF-8, invalid bytes replaced.</summary>
    private static string Text(ReadOnlySpan<byte> bytes) => Encoding.UTF8.GetString(bytes);
}

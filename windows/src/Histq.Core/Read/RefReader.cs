// Reads the refs the graph labels: local branches with their upstream and ahead/behind counts, remote branches, tags
// (annotated ones peeled to their commit) and HEAD.
namespace Histq.Core;

/// <param name="Name">The short name, e.g. <c>main</c> or <c>fix/login</c>.</param>
/// <param name="RefName">The full ref, e.g. <c>refs/heads/main</c>.</param>
/// <param name="Upstream">The short upstream name, e.g. <c>origin/main</c>; null without an upstream.</param>
/// <param name="UpstreamGone">The upstream is configured but its ref no longer exists (deleted on the remote, then
/// pruned).</param>
/// <param name="IsHead">HEAD of the worktree the read ran in points at this branch.</param>
/// <param name="TipDate">The tip commit's committer date; null when git gave none.</param>
public sealed record LocalBranch(
    string Name,
    string RefName,
    string Commit,
    string? Upstream,
    int Ahead,
    int Behind,
    bool UpstreamGone,
    bool IsHead,
    DateTimeOffset? TipDate = null);

/// <param name="Name">The short name, e.g. <c>origin/main</c>.</param>
/// <param name="RefName">The full ref, e.g. <c>refs/remotes/origin/main</c>.</param>
/// <param name="Remote">The first path component of <paramref name="Name"/> (a remote whose own name contains
/// <c>/</c> is cut at the first one).</param>
/// <param name="TipDate">The tip commit's committer date; null when git gave none.</param>
public sealed record RemoteBranch(
    string Name, string RefName, string Remote, string Commit, DateTimeOffset? TipDate = null);

/// <summary>A tag.</summary>
/// <param name="Target">The object the ref points at: the tag object for an annotated tag, else the tagged object
/// itself.</param>
/// <param name="Commit">The commit the tag finally points at (peeled); null for a tag of a tree or blob.</param>
public sealed record TagRef(string Name, string RefName, string Target, bool IsAnnotated, string? Commit);

/// <summary>Where HEAD is: <see cref="Branch"/>, <see cref="Detached"/> or <see cref="Unborn"/>.</summary>
public abstract record Head
{
    private Head()
    {
    }

    /// <summary>The commit HEAD is at; null on an unborn branch.</summary>
    public abstract string? Commit { get; }

    /// <summary>On a branch (short name) at <paramref name="commit"/>.</summary>
    public sealed record Branch : Head
    {
        public Branch(string name, string commit)
        {
            Name = name;
            Commit = commit;
        }

        public string Name { get; }

        public override string? Commit { get; }
    }

    public sealed record Detached : Head
    {
        public Detached(string commit)
        {
            Commit = commit;
        }

        public override string? Commit { get; }
    }

    /// <summary>On a branch that has no commit yet (a new repository or an orphan branch).</summary>
    public sealed record Unborn : Head
    {
        public Unborn(string name)
        {
            Name = name;
        }

        public string Name { get; }

        public override string? Commit => null;
    }
}

/// <param name="LocalBranches">Sorted by ref name, like every list here.</param>
/// <param name="RemoteBranches">Symbolic remote refs (<c>origin/HEAD</c>) are left out.</param>
public sealed record Refs(
    Head Head,
    IReadOnlyList<LocalBranch> LocalBranches,
    IReadOnlyList<RemoteBranch> RemoteBranches,
    IReadOnlyList<TagRef> Tags)
{
    public bool Equals(Refs? other) =>
        other is not null
        && Head == other.Head
        && LocalBranches.SequenceEqual(other.LocalBranches)
        && RemoteBranches.SequenceEqual(other.RemoteBranches)
        && Tags.SequenceEqual(other.Tags);

    public override int GetHashCode() =>
        HashCode.Combine(Head, LocalBranches.Count, RemoteBranches.Count, Tags.Count);
}

public static class RefReader
{
    /// <summary>
    /// Fields separated by <c>\x1f</c> (<c>%1f</c>); ref names cannot contain control characters or newlines.
    /// <c>%(*objectname)</c>/<c>%(*objecttype)</c> are the peeled object of an annotated tag (empty otherwise).
    /// <c>%(committerdate:unix)</c> comes last and is empty for an annotated tag.
    /// </summary>
    public static IReadOnlyList<string> Arguments { get; } =
    [
        "for-each-ref",
        "--format=%(refname)%1f%(objectname)%1f%(objecttype)%1f%(*objectname)%1f%(*objecttype)%1f"
        + "%(upstream:short)%1f%(upstream:track,nobracket)%1f%(symref)%1f%(committerdate:unix)",
        "refs/heads", "refs/remotes", "refs/tags",
    ];

    /// <summary>The newline characters Swift's <c>CharacterSet.newlines</c> holds.</summary>
    private static readonly char[] Newlines = ['\n', '\u000B', '\u000C', '\r', '\u0085', '\u2028', '\u2029'];

    /// <summary>
    /// Reads the refs and HEAD of the repository (worktree) at <paramref name="cwd"/>. <paramref name="env"/> must be
    /// the read environment built by <see cref="GitInvocation.ReadEnvironmentAsync"/> for this <paramref name="cwd"/>.
    /// Throws <see cref="GitError"/>.
    /// </summary>
    public static async Task<Refs> ReadAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, CancellationToken ct = default)
    {
        // The three run at once; awaited in this order, so a failure throws the same error as one after another. When
        // one fails, the others are cancelled and awaited before the error is thrown.
        using var others = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var refs = runner.RunAsync(Arguments, cwd, env, ct: others.Token);
        var symbolic = runner.RunAsync(
            ["symbolic-ref", "-q", "HEAD"], cwd, env, allowedExitCodes: [0, 1], ct: others.Token);
        var verified = runner.RunAsync(
            ["rev-parse", "-q", "--verify", "HEAD"], cwd, env, allowedExitCodes: [0, 1], ct: others.Token);
        try
        {
            var output = (await refs.ConfigureAwait(false)).Text;
            var headRef = (await symbolic.ConfigureAwait(false)).Text.Trim(Newlines);
            var headCommit = (await verified.ConfigureAwait(false)).Text.Trim(Newlines);
            return Parse(output, headRef, headCommit);
        }
        catch
        {
            await others.CancelAsync().ConfigureAwait(false);
            try
            {
                await Task.WhenAll(refs, symbolic, verified).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Only observed: the error of the first failed read, in Swift's order, is the one thrown.
            }

            throw;
        }
    }

    /// <summary>
    /// <paramref name="headRef"/> is the output of <c>symbolic-ref -q HEAD</c> (empty when detached),
    /// <paramref name="headCommit"/> that of <c>rev-parse -q --verify HEAD</c> (empty when unborn).
    /// </summary>
    internal static Refs Parse(string output, string headRef, string headCommit)
    {
        var locals = new List<LocalBranch>();
        var remotes = new List<RemoteBranch>();
        var tags = new List<TagRef>();
        foreach (var line in ReadParsing.SplitText(output, '\n'))
        {
            var f = ReadParsing.SplitText(line, '\u001F', omitEmpty: false);
            if (f.Count < 8)
            {
                continue;
            }

            var (refName, @object, type, peeled, peeledType, upstream, track, symref) =
                (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]);
            var tipDate = f.Count > 8 && ReadParsing.Seconds(f[8]) is { } seconds
                ? ReadParsing.UnixDate(seconds)
                : (DateTimeOffset?)null;
            if (DropPrefix(refName, "refs/heads/") is { } localName)
            {
                var counts = ParseTrack(track);
                locals.Add(new LocalBranch(
                    localName, refName, @object, upstream.Length == 0 ? null : upstream, counts.Ahead, counts.Behind,
                    counts.Gone, string.Equals(refName, headRef, StringComparison.Ordinal), tipDate));
            }
            else if (DropPrefix(refName, "refs/remotes/") is { } remoteName)
            {
                if (symref.Length > 0)
                {
                    continue;
                }

                var remote = ReadParsing.SplitText(remoteName, '/', maxSplits: 1).FirstOrDefault() ?? remoteName;
                remotes.Add(new RemoteBranch(remoteName, refName, remote, @object, tipDate));
            }
            else if (DropPrefix(refName, "refs/tags/") is { } tagName)
            {
                var annotated = string.Equals(type, "tag", StringComparison.Ordinal);
                var commit = annotated
                    ? (string.Equals(peeledType, "commit", StringComparison.Ordinal) ? peeled : null)
                    : (string.Equals(type, "commit", StringComparison.Ordinal) ? @object : null);
                tags.Add(new TagRef(tagName, refName, @object, annotated, commit));
            }
        }

        Head head = DropPrefix(headRef, "refs/heads/") is { } branch
            ? headCommit.Length == 0 ? new Head.Unborn(branch) : new Head.Branch(branch, headCommit)
            : new Head.Detached(headCommit);
        return new Refs(head, locals, remotes, tags);
    }

    /// <summary><c>ahead N</c>, <c>behind N</c>, <c>ahead N, behind M</c>, <c>gone</c> or empty (in sync or no upstream).</summary>
    internal static (int Ahead, int Behind, bool Gone) ParseTrack(string track)
    {
        if (string.Equals(track, "gone", StringComparison.Ordinal))
        {
            return (0, 0, true);
        }

        var ahead = 0;
        var behind = 0;
        foreach (var part in ReadParsing.SplitText(track, ','))
        {
            var words = ReadParsing.SplitText(part, ' ');
            if (words.Count != 2 || ReadParsing.Integer(words[1]) is not { } count)
            {
                continue;
            }

            if (string.Equals(words[0], "ahead", StringComparison.Ordinal))
            {
                ahead = count;
            }
            else if (string.Equals(words[0], "behind", StringComparison.Ordinal))
            {
                behind = count;
            }
        }

        return (ahead, behind, false);
    }

    /// <summary>The rest of <paramref name="text"/> after <paramref name="prefix"/>, or null when it does not start with
    /// it (compared ordinally, so a name starting with a combining mark still matches).</summary>
    private static string? DropPrefix(string text, string prefix) =>
        text.StartsWith(prefix, StringComparison.Ordinal) ? text[prefix.Length..] : null;
}

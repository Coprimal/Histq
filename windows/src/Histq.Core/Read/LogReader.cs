// Streams the commit history for the graph: every ref but the stash and notes, children before parents (by date or
// by branch, `LogReader.Order`), parsed as git writes it and published in pages so the first rows can show before git
// has finished.
//
// Also holds `ReadParsing`, the Swift-compatible splitting and number parsing every reader shares (Swift's `split`
// omits empty pieces unless told not to, and its empty pieces do not count toward `maxSplits`).
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;

namespace Histq.Core;

/// <summary>One commit of the history. Text fields come from the repo and are untrusted.</summary>
/// <param name="Parents">First parent first; empty for a root commit, two or more for a merge.</param>
public sealed record Commit(
    string Hash,
    IReadOnlyList<string> Parents,
    string AuthorName,
    string AuthorEmail,
    DateTimeOffset AuthorDate,
    DateTimeOffset CommitterDate,
    string Subject,
    string Body,
    string CommitterName = "",
    string CommitterEmail = "")
{
    public string Id => Hash;

    public bool IsMerge => Parents.Count > 1;

    public bool Equals(Commit? other) =>
        other is not null
        && string.Equals(Hash, other.Hash, StringComparison.Ordinal)
        && Parents.SequenceEqual(other.Parents, StringComparer.Ordinal)
        && string.Equals(AuthorName, other.AuthorName, StringComparison.Ordinal)
        && string.Equals(AuthorEmail, other.AuthorEmail, StringComparison.Ordinal)
        && AuthorDate == other.AuthorDate
        && CommitterDate == other.CommitterDate
        && string.Equals(Subject, other.Subject, StringComparison.Ordinal)
        && string.Equals(Body, other.Body, StringComparison.Ordinal)
        && string.Equals(CommitterName, other.CommitterName, StringComparison.Ordinal)
        && string.Equals(CommitterEmail, other.CommitterEmail, StringComparison.Ordinal);

    public override int GetHashCode() =>
        HashCode.Combine(StringComparer.Ordinal.GetHashCode(Hash), Parents.Count, AuthorDate, CommitterDate);
}

public static class LogReader
{
    public const int DefaultPageSize = 500;

    /// <summary>The order of the log's commits; both list every commit above its parents.</summary>
    public enum Order
    {
        /// <summary>
        /// <c>git log --date-order</c>: newest committer date first, every commit still above its parents, so the
        /// branches interleave.
        /// </summary>
        Date,

        /// <summary><c>git log --topo-order</c>: a line of history is listed whole before the next.</summary>
        Branch,
    }

    /// <summary>
    /// <c>--exclude</c> must come before <c>--all</c> (git applies it to the next <c>--all</c>/<c>--branches</c>/...),
    /// so stash internals (<c>stash@{n}</c> and its index and untracked commits), notes and <c>git maintenance</c>'s
    /// prefetch refs (hidden copies of the remotes) never become rows. A remote's HEAD
    /// (<c>refs/remotes/&lt;remote&gt;/HEAD</c>) is a symref to one of its branches, which <c>--all</c> reads anyway,
    /// so leaving it out changes nothing until that branch is hidden (the user cannot hide the symref itself,
    /// <see cref="RefReader"/> leaves it out), and then it cannot bring the hidden branch's commits back. <c>-z</c> ends
    /// every record with NUL, which git cannot emit inside a name or message (its formatter stops at a NUL, and the
    /// read environment pins UTF-8 output), so no commit text can start a record of its own. Fields are separated by
    /// <c>\x1f</c>, which git does not escape: the fixed-format fields come first and the body last, so a stray
    /// <c>\x1f</c> in a name or message cannot shift the hash, parents or dates (see <see cref="LogParser"/>).
    /// </summary>
    public static IReadOnlyList<string> Arguments { get; } =
    [
        "log", "-z", "--exclude=refs/stash", "--exclude=refs/notes/*", "--exclude=refs/prefetch/*",
        "--exclude=refs/remotes/*/HEAD", "--all",
        "--topo-order",
        "--format=%H%x1f%P%x1f%at%x1f%ct%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s%x1f%b",
    ];

    /// <summary>
    /// <see cref="Arguments"/> with refs hidden or branches soloed, and with the <paramref name="alsoFrom"/> hashes (see
    /// <see cref="PagesAsync"/>); with no hidden or soloed ref it is <see cref="Arguments"/> followed by those hashes.
    /// Hide puts an <c>--exclude</c> per ref before <c>--all</c>. Solo drops <c>--all</c> and ends the command with
    /// <c>--end-of-options &lt;refs&gt; HEAD &lt;hashes&gt; --</c>: HEAD keeps the WIP row's base, and the trailing
    /// <c>--</c> keeps a worktree file named <c>HEAD</c> (or a hash) from being read as a path. A ref both hidden and
    /// soloed is shown: its <c>--exclude</c> is still passed, but git applies it only to a following <c>--all</c>, which
    /// solo mode has not. Only full ref names that git would accept are passed, the rest are dropped: hidden ones under
    /// <c>refs/heads/</c>, <c>refs/remotes/</c> or <c>refs/tags/</c>, soloed ones under the first two; if no soloed ref
    /// is left, every ref is read. <see cref="Order.Date"/> puts <c>--date-order</c> in place of <c>--topo-order</c>.
    /// Only non-empty ASCII hex strings of <paramref name="alsoFrom"/> are passed.
    /// </summary>
    public static IReadOnlyList<string> ArgumentsFor(
        IReadOnlyList<string> hidden, IReadOnlyList<string> solo, IReadOnlyList<string>? alsoFrom = null,
        Order order = Order.Branch)
    {
        var revisions = (alsoFrom ?? []).Where(IsHex).ToList();
        var excludes = hidden.Where(IsHideableRef).Select(name => "--exclude=" + name).ToList();
        var soloed = solo.Where(IsBranchRef).ToList();
        var command = Arguments.ToList();
        if (order == Order.Date && command.IndexOf("--topo-order") is var topo and >= 0)
        {
            command[topo] = "--date-order";
        }

        var all = command.IndexOf("--all");
        if (soloed.Count == 0)
        {
            command.InsertRange(all, excludes);
            command.AddRange(revisions);
            return command;
        }

        command.RemoveAt(all);
        command.InsertRange(all, excludes);
        command.Add("--end-of-options");
        command.AddRange(soloed);
        command.Add("HEAD");
        command.AddRange(revisions);
        command.Add("--");
        return command;
    }

    /// <summary>
    /// A full branch or remote-tracking ref name git accepts (<c>git check-ref-format</c>), checked on its UTF-8 bytes
    /// so a combining character cannot hide a forbidden one. The name after the prefix cannot start with <c>-</c>.
    /// </summary>
    internal static bool IsBranchRef(string name) => IsRef(name, ["refs/heads/", "refs/remotes/"]);

    /// <summary>A full branch, remote-tracking or tag ref name git accepts, as <see cref="IsBranchRef"/> checks it.</summary>
    internal static bool IsHideableRef(string name) => IsRef(name, ["refs/heads/", "refs/remotes/", "refs/tags/"]);

    /// <summary><paramref name="name"/> starts with one of <paramref name="prefixes"/> and git accepts it; a
    /// remote-tracking name needs a remote and a branch.</summary>
    private static bool IsRef(string name, string[] prefixes)
    {
        var prefix = prefixes.FirstOrDefault(candidate => name.StartsWith(candidate, StringComparison.Ordinal));
        if (prefix is null)
        {
            return false;
        }

        ReadOnlySpan<byte> rest = Encoding.UTF8.GetBytes(name)[Encoding.UTF8.GetByteCount(prefix)..];
        if (!rest.IsEmpty && (rest[0] == (byte)'-'))
        {
            return false;
        }

        if (!rest.IsEmpty && rest[^1] == (byte)'.')
        {
            return false;
        }

        foreach (var b in rest)
        {
            if (b < 0x20 || b == 0x7F || " ~^:?*[\\"u8.Contains(b))
            {
                return false;
            }
        }

        if (rest.IndexOf(".."u8) >= 0 || rest.IndexOf("@{"u8) >= 0)
        {
            return false;
        }

        if (prefix == "refs/remotes/" && !rest.Contains((byte)'/'))
        {
            return false;
        }

        foreach (var part in ReadParsing.Split(rest, (byte)'/', omitEmpty: false))
        {
            var component = rest[part];
            if (component.IsEmpty || component[0] == (byte)'.' || component.EndsWith(".lock"u8))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// Streams the history of the repository at <paramref name="cwd"/> in pages of up to <paramref name="pageSize"/>
    /// commits (the last page may be shorter; an empty repository yields no page). Each page is a new list.
    /// <paramref name="env"/> must be the read environment built by <see cref="GitInvocation.ReadEnvironmentAsync"/>
    /// for this <paramref name="cwd"/>. git starts on the first <c>MoveNextAsync</c>. The enumeration throws
    /// <see cref="GitError"/> when git fails. Ending the enumeration early stops git; cancelling
    /// <paramref name="ct"/> stops it too and throws <see cref="OperationCanceledException"/> (the last, partial page
    /// is never yielded then).
    /// </summary>
    /// <param name="alsoFrom">Commit hashes whose history is read too, e.g. the stashes' bases, so a stash made on a
    /// commit no branch holds any more still has its base in the log. Anything but a hex hash is left out, so it can
    /// never be read as an option.</param>
    /// <param name="hidden">Full ref names, see <see cref="ArgumentsFor"/>.</param>
    /// <param name="solo">Full ref names, see <see cref="ArgumentsFor"/>.</param>
    /// <param name="order">The order of the commits.</param>
    public static async IAsyncEnumerable<IReadOnlyList<Commit>> PagesAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, int pageSize = DefaultPageSize,
        IReadOnlyList<string>? alsoFrom = null, IReadOnlyList<string>? hidden = null,
        IReadOnlyList<string>? solo = null, Order order = Order.Branch,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var command = ArgumentsFor(hidden ?? [], solo ?? [], alsoFrom, order);
        var capacity = Math.Clamp(pageSize, 0, DefaultPageSize * 4);
        var page = new List<Commit>(capacity);
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        await foreach (var line in runner.StreamAsync(command, cwd, env, delimiter: 0, ct: ct).ConfigureAwait(false))
        {
            if (line.Source != GitRunner.LineSource.Stdout || LogParser.Parse(line.Text, names) is not { } commit)
            {
                continue;
            }

            page.Add(commit);
            if (page.Count >= pageSize)
            {
                yield return page;
                page = new List<Commit>(capacity);
            }
        }

        ct.ThrowIfCancellationRequested();
        if (page.Count > 0)
        {
            yield return page;
        }
    }

    /// <summary>
    /// The hashes of the commits of <paramref name="commits"/> that no other commit of it lists as a parent, in
    /// <paramref name="commits"/>' order: the tips a history read from them reaches every commit of
    /// <paramref name="commits"/> from. <paramref name="index"/> is <paramref name="commits"/>' index of each hash.
    /// </summary>
    public static IReadOnlyList<string> Tips(IReadOnlyList<Commit> commits, IReadOnlyDictionary<string, int> index)
    {
        var isParent = new bool[commits.Count];
        foreach (var commit in commits)
        {
            foreach (var parent in commit.Parents)
            {
                if (index.TryGetValue(parent, out var position))
                {
                    isParent[position] = true;
                }
            }
        }

        var tips = new List<string>();
        for (var i = 0; i < commits.Count; i++)
        {
            if (!isParent[i])
            {
                tips.Add(commits[i].Hash);
            }
        }

        return tips;
    }

    /// <summary>
    /// The tips of a history after <paramref name="delta"/> (the commits new since a read whose tips were
    /// <paramref name="previous"/>, <see cref="NewCommitsAsync"/>) comes on top of it, as <see cref="Tips"/> would give
    /// for the whole history: the delta commits no other delta commit lists as a parent, then the previous tips no
    /// delta commit lists as a parent. (Swift's <c>tips(adding:to:)</c>.)
    /// </summary>
    public static IReadOnlyList<string> TipsAdding(IReadOnlyList<Commit> delta, IReadOnlyList<string> previous)
    {
        var parents = new HashSet<string>(StringComparer.Ordinal);
        foreach (var commit in delta)
        {
            parents.UnionWith(commit.Parents);
        }

        return delta.Select(commit => commit.Hash).Where(hash => !parents.Contains(hash))
            .Concat(previous.Where(hash => !parents.Contains(hash)))
            .ToList();
    }

    /// <summary>
    /// The commits of a reload in <c>--date-order</c>: <paramref name="delta"/> (the commits new since
    /// <paramref name="previous"/>, <see cref="NewCommitsAsync"/> in date order) merged into <paramref name="previous"/>
    /// (a read in date order, <paramref name="index"/> its position of each hash) by committer date, newest first: a new
    /// commit comes first when the next old one is not newer (a tie included) or is a parent of a new commit not listed
    /// yet. O(n). The same commits as a fresh read, and in the same order when committer dates are unique and no commit
    /// is older than a parent; otherwise (clock skew, equal seconds) every commit is still above its parents, but the
    /// order may differ from a fresh read until the next full read. No commit of <paramref name="delta"/> may be in
    /// <paramref name="previous"/> or be an ancestor of one of its commits (the caller checks).
    /// </summary>
    public static IReadOnlyList<Commit> MergedByDate(
        IReadOnlyList<Commit> delta, IReadOnlyList<Commit> previous, IReadOnlyDictionary<string, int> index)
    {
        // Per old commit, how many new commits not listed yet name it as a parent: it waits for them.
        var children = new int[previous.Count];
        foreach (var commit in delta)
        {
            foreach (var parent in commit.Parents)
            {
                if (index.TryGetValue(parent, out var position))
                {
                    children[position]++;
                }
            }
        }

        var merged = new List<Commit>(delta.Count + previous.Count);
        var old = 0;
        foreach (var commit in delta)
        {
            while (old < previous.Count && children[old] == 0 && previous[old].CommitterDate > commit.CommitterDate)
            {
                merged.Add(previous[old]);
                old++;
            }

            merged.Add(commit);
            foreach (var parent in commit.Parents)
            {
                if (index.TryGetValue(parent, out var position))
                {
                    children[position]--;
                }
            }
        }

        for (; old < previous.Count; old++)
        {
            merged.Add(previous[old]);
        }

        return merged;
    }

    /// <summary>
    /// The commits a history read (<see cref="PagesAsync"/>) would list now that are not in a previous read whose tips
    /// were <paramref name="previousTips"/> (<see cref="Tips"/>), in git's order (children before parents); empty when
    /// none. Null when this cannot be proven to be the whole difference, so the caller reads the whole history again: no
    /// previous tip, a previous tip that is not an ASCII hex hash, a replace ref (<c>git replace</c> can give an old
    /// commit other parents), or a commit of the previous read that the refs and <paramref name="alsoFrom"/> no longer
    /// reach (a branch deleted, a reset, a force-push, a stash dropped, a ref hidden since). <paramref name="env"/>,
    /// <paramref name="alsoFrom"/>, <paramref name="hidden"/> and <paramref name="order"/> are as in
    /// <see cref="PagesAsync"/> (the previous read must have had the same <paramref name="hidden"/> and
    /// <paramref name="order"/>; there is no solo mode here: a soloed log is read whole); anything in
    /// <paramref name="alsoFrom"/> but a hex hash is left out. Throws <see cref="GitError"/>, and
    /// <see cref="OperationCanceledException"/> when <paramref name="ct"/> is cancelled.
    /// <para>
    /// The new commits and the previous ones are exactly the commits a fresh read lists, children before parents (a new
    /// commit is never an ancestor of an old one). In branch order the new commits come on top of the old ones, which
    /// keep their order: not always the order of a fresh read, which after a commit on a branch other than the newest
    /// one lists that branch's whole line first. In date order they are merged by date (<see cref="MergedByDate"/>).
    /// Not valid across a change of the shallow boundary (a deepened clone gives old commits new parents): the caller
    /// reads the whole history of a shallow repo.
    /// </para>
    /// </summary>
    public static async Task<IReadOnlyList<Commit>?> NewCommitsAsync(
        GitRunner runner, string cwd, IReadOnlyDictionary<string, string> env, IReadOnlyList<string> previousTips,
        IReadOnlyList<string>? alsoFrom = null, IReadOnlyList<string>? hidden = null, Order order = Order.Branch,
        CancellationToken ct = default)
    {
        if (previousTips.Count == 0 || !previousTips.All(IsHex))
        {
            return null;
        }

        var extra = (alsoFrom ?? []).Where(IsHex).ToList();
        // The log's own command, so the delta leaves out what a full read leaves out (stash, notes, prefetch refs, a
        // remote's HEAD, the hidden refs).
        var command = ArgumentsFor(hidden ?? [], [], extra, order);
        var excludes = command.Where(argument => argument.StartsWith("--exclude=", StringComparison.Ordinal));
        var replaced = await runner.RunAsync(
            ["for-each-ref", "--count=1", "--format=%(refname)", "refs/replace/"], cwd, env, ct: ct)
            .ConfigureAwait(false);
        if (replaced.Text.Trim().Length > 0)
        {
            return null;
        }

        // Every previous commit must still be reachable. `--stdin` comes before `--not`, and git reads the revisions on
        // stdin as given whatever `--not` says on the command line, so the previous tips count as positive and the refs
        // (with the same exclusions as the log) and `extra` as negative.
        var check = await runner.RunAsync(
            ["rev-list", "--count", "--stdin", "--not", .. excludes, "--all", .. extra], cwd, env,
            stdin: Encoding.UTF8.GetBytes(string.Concat(previousTips.Select(tip => tip + "\n"))), ct: ct)
            .ConfigureAwait(false);
        if (!string.Equals(check.Text.Trim(), "0", StringComparison.Ordinal))
        {
            return null;
        }

        var commits = new List<Commit>();
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        var lines = runner.StreamAsync(
            [.. command, "--stdin"], cwd, env,
            stdin: Encoding.UTF8.GetBytes(string.Concat(previousTips.Select(tip => "^" + tip + "\n"))), delimiter: 0,
            ct: ct);
        await foreach (var line in lines.ConfigureAwait(false))
        {
            if (line.Source == GitRunner.LineSource.Stdout && LogParser.Parse(line.Text, names) is { } commit)
            {
                commits.Add(commit);
            }
        }

        ct.ThrowIfCancellationRequested();
        return commits;
    }

    /// <summary>A non-empty string of ASCII hex digits (either case).</summary>
    private static bool IsHex(string text) => text.Length > 0 && text.All(char.IsAsciiHexDigit);
}

/// <summary>
/// Turns NUL-terminated records of <see cref="LogReader.Arguments"/>' format into commits, one record each. Public so
/// a log dump in that format can be parsed without git.
/// </summary>
public static class LogParser
{
    /// <summary>Strings of at most this many UTF-8 bytes are not interned.</summary>
    private const int InternMinBytes = 15;

    /// <summary>The most names <see cref="Intern"/> keeps.</summary>
    private const int InternCapacity = 10_000;

    /// <summary>
    /// The commit of one record (without its NUL), or null when it is no commit. A record needs a hash, parents and
    /// both dates. The body takes everything after the ninth <c>\x1f</c>, so a stray <c>\x1f</c> in a name, email or
    /// subject only misplaces text. <paramref name="names"/> is the stream's cache of names and emails
    /// (<see cref="Intern"/>), so the commits of one author share one string: start each stream with a new
    /// <c>Dictionary&lt;string, string&gt;(StringComparer.Ordinal)</c>.
    /// </summary>
    public static Commit? Parse(ReadOnlySpan<char> record, Dictionary<string, string> names)
    {
        Span<Range> fields = stackalloc Range[10];
        var count = ReadParsing.SplitInto(record, '\u001F', fields);
        if (count < 4 || !IsHash(record[fields[0]])
            || ReadParsing.Seconds(record[fields[2]]) is not { } authorTime
            || ReadParsing.Seconds(record[fields[3]]) is not { } commitTime)
        {
            return null;
        }

        var parentField = record[fields[1]];
        var parentRanges = ReadParsing.Split(parentField, ' ');
        foreach (var range in parentRanges)
        {
            if (!IsHash(parentField[range]))
            {
                return null;
            }
        }

        var parents = new string[parentRanges.Count];
        for (var i = 0; i < parents.Length; i++)
        {
            parents[i] = parentField[parentRanges[i]].ToString();
        }

        var body = Text(record, fields, count, 9);
        // Swift compares Characters here: `\r\n` is one Character that is not `\n`, so it stays.
        var end = body.Length;
        while (end > 0 && body[end - 1] == '\n' && !(end > 1 && body[end - 2] == '\r'))
        {
            end--;
        }

        return new Commit(
            record[fields[0]].ToString(), parents, Intern(Text(record, fields, count, 4), names),
            Intern(Text(record, fields, count, 5), names), ReadParsing.UnixDate(authorTime),
            ReadParsing.UnixDate(commitTime), Text(record, fields, count, 8).ToString(), body[..end].ToString(),
            Intern(Text(record, fields, count, 6), names), Intern(Text(record, fields, count, 7), names));
    }

    /// <summary>
    /// <paramref name="field"/> as the string <paramref name="names"/> already holds for it, so equal names and emails
    /// share one string. Fields of up to 15 UTF-8 bytes are not cached (as on the Mac, where they are stored inline);
    /// <paramref name="names"/> stops growing at 10,000 entries. Compared ordinally (byte for byte).
    /// </summary>
    internal static string Intern(ReadOnlySpan<char> field, Dictionary<string, string> names)
    {
        if (field.Length <= InternMinBytes && Encoding.UTF8.GetByteCount(field) <= InternMinBytes)
        {
            return field.ToString();
        }

        if (names.TryGetAlternateLookup<ReadOnlySpan<char>>(out var lookup))
        {
            if (lookup.TryGetValue(field, out var known))
            {
                return known;
            }
        }
        else if (names.TryGetValue(field.ToString(), out var found))
        {
            return found;
        }

        var value = field.ToString();
        if (names.Count < InternCapacity)
        {
            names[value] = value;
        }

        return value;
    }

    /// <summary>A full SHA-1 (40) or SHA-256 (64) object name in lowercase hex.</summary>
    public static bool IsHash(ReadOnlySpan<char> text)
    {
        if (text.Length != 40 && text.Length != 64)
        {
            return false;
        }

        foreach (var c in text)
        {
            if (c is not (>= '0' and <= '9' or >= 'a' and <= 'f'))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Field <paramref name="index"/> of the record, empty when it has fewer fields.</summary>
    private static ReadOnlySpan<char> Text(ReadOnlySpan<char> record, Span<Range> fields, int count, int index) =>
        index < count ? record[fields[index]] : [];
}

/// <summary>The Swift-compatible parsing the readers share.</summary>
internal static class ReadParsing
{
    private const NumberStyles SecondsStyle =
        NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent;

    private static readonly long MinTicks = (DateTimeOffset.MinValue - DateTimeOffset.UnixEpoch).Ticks;

    private static readonly long MaxTicks = (DateTimeOffset.MaxValue - DateTimeOffset.UnixEpoch).Ticks;

    /// <summary>
    /// Swift's <c>split(separator:maxSplits:omittingEmptySubsequences:)</c>: the ranges of the pieces of
    /// <paramref name="source"/> between <paramref name="separator"/>s. With <paramref name="omitEmpty"/> (Swift's
    /// default) empty pieces are dropped and do not count toward <paramref name="maxSplits"/>; after
    /// <paramref name="maxSplits"/> splits the rest is the last piece, as it is (separators at its start included).
    /// </summary>
    internal static List<Range> Split<T>(
        ReadOnlySpan<T> source, T separator, int maxSplits = int.MaxValue, bool omitEmpty = true)
        where T : IEquatable<T>
    {
        var result = new List<Range>();
        var start = 0;
        if (maxSplits == 0 || source.IsEmpty)
        {
            if (!(omitEmpty && source.IsEmpty))
            {
                result.Add(0..source.Length);
            }

            return result;
        }

        for (var end = 0; end < source.Length; end++)
        {
            if (!source[end].Equals(separator))
            {
                continue;
            }

            var appended = !(omitEmpty && start == end);
            if (appended)
            {
                result.Add(start..end);
            }

            start = end + 1;
            if (appended && result.Count == maxSplits)
            {
                break;
            }
        }

        if (start != source.Length || !omitEmpty)
        {
            result.Add(start..source.Length);
        }

        return result;
    }

    /// <summary>
    /// Swift's <c>split(separator:maxSplits:omittingEmptySubsequences: false)</c> with <c>maxSplits</c> one less than
    /// <paramref name="destination"/>'s length, into <paramref name="destination"/>: returns the number of pieces.
    /// </summary>
    internal static int SplitInto<T>(ReadOnlySpan<T> source, T separator, Span<Range> destination)
        where T : IEquatable<T>
    {
        var count = 0;
        var start = 0;
        for (var end = 0; end < source.Length && count < destination.Length - 1; end++)
        {
            if (source[end].Equals(separator))
            {
                destination[count++] = start..end;
                start = end + 1;
            }
        }

        destination[count++] = start..source.Length;
        return count;
    }

    /// <summary>Swift's <c>Split</c> on a string, the pieces as strings.</summary>
    internal static List<string> SplitText(string source, char separator, int maxSplits = int.MaxValue, bool omitEmpty = true) =>
        Split(source.AsSpan(), separator, maxSplits, omitEmpty).Select(range => source[range]).ToList();

    /// <summary>
    /// A number of seconds as git prints it (Swift's <c>TimeInterval(_:)</c> for decimal input: an optional sign, digits,
    /// a decimal point and an exponent, no spaces); null when it is no finite number.
    /// </summary>
    internal static double? Seconds(ReadOnlySpan<char> text) =>
        double.TryParse(text, SecondsStyle, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value)
            ? value
            : null;

    /// <summary>
    /// The date <paramref name="seconds"/> after 1970, clamped to the dates .NET can hold (years 1 to 9999): a crafted
    /// commit's timestamp must not fail the read.
    /// </summary>
    internal static DateTimeOffset UnixDate(double seconds)
    {
        var ticks = seconds * TimeSpan.TicksPerSecond;
        if (ticks <= MinTicks)
        {
            return DateTimeOffset.MinValue;
        }

        return ticks >= MaxTicks ? DateTimeOffset.MaxValue : DateTimeOffset.UnixEpoch.AddTicks((long)ticks);
    }

    /// <summary>Swift's <c>Int(_:)</c>: an optional sign and decimal digits, nothing else; null otherwise.</summary>
    internal static int? Integer(ReadOnlySpan<char> text) =>
        int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) ? value : null;
}

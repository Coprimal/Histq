// The graph's commit search (Ctrl+F): which commits of the log a query finds, by message, subject and body (every word
// of the query, in any order; case- and diacritic-insensitive; spaces, line breaks, "-", "_" and "/" alike) or, for a
// query of 4 or more hex characters, by any part of the hash. Pure and synchronous, so the app runs it off the UI
// thread. A per-commit culture-aware compare is slow on a big log, so the messages are folded once into one UTF-8 byte
// buffer (`Index`, built once per log) and each query word is a vectorized ordinal span scan of it.
// Ported from CommitSearch.swift at 6fa6d40.
using System.Globalization;
using System.Text;

namespace Histq.Core;

public static class CommitSearch
{
    /// <summary>The shortest query that also matches part of a hash: shorter hex strings hit too many messages' words and hashes.</summary>
    public const int MinimumHashPrefix = 4;

    /// <summary>
    /// The most bytes the messages buffer starts with: it grows as messages come, so a huge log does not ask for gigabytes
    /// up front.
    /// </summary>
    private const int InitialCapacityLimit = 1 << 28;

    /// <summary>
    /// A log's messages (subject and body) folded (lowercase, no diacritics, each run of separators one space) and
    /// joined by newlines, with where each starts; and the hashes, fixed width. Build it once per log snapshot, off the
    /// UI thread.
    /// </summary>
    public sealed class Index
    {
        /// <summary>The folded messages, each followed by a newline; only the first <see cref="MessagesLength"/> bytes count.</summary>
        internal byte[] Messages { get; }

        internal int MessagesLength { get; }

        /// <summary><see cref="Messages"/>' offset of each commit's message, in log order.</summary>
        internal int[] Starts { get; }

        /// <summary>Every hash, as git wrote it, <see cref="HashWidth"/> bytes each (a shorter one is padded with NUL).</summary>
        internal byte[] Hashes { get; }

        internal int HashWidth { get; }

        /// <summary>The commits indexed: the first <see cref="Count"/> of the log.</summary>
        public int Count => Starts.Length;

        /// <summary>
        /// The log was too big to index whole (its messages or hashes past what one array holds): only the first
        /// <see cref="Count"/> commits are searched, by message and by hash.
        /// </summary>
        public bool IsTruncated { get; }

        /// <summary>
        /// Indexes <paramref name="commits"/> in one pass. A cancelled token gives an empty index. A log too big for one
        /// array is indexed up to the last commit that fits (<see cref="IsTruncated"/>); building never throws for size.
        /// </summary>
        public Index(IReadOnlyList<Commit> commits, CancellationToken ct = default)
        {
            var hashWidth = commits.Count > 0 ? Encoding.UTF8.GetByteCount(commits[0].Hash) : 40;
            var count = hashWidth > 0 ? (int)Math.Min(commits.Count, Array.MaxLength / hashWidth) : commits.Count;
            var truncated = count < commits.Count;
            var messages = new byte[Math.Clamp((long)count * 64, 64, InitialCapacityLimit)];
            var length = 0;
            var starts = new int[count];
            var hashes = new byte[count * hashWidth];
            for (var position = 0; position < count; position++)
            {
                if ((position & 0x3FF) == 0 && ct.IsCancellationRequested)
                {
                    (messages, length, starts, hashes, truncated) = ([], 0, [], [], false);
                    break;
                }

                var commit = commits[position];
                starts[position] = length;
                if (!AppendMessage(commit, ref messages, ref length))
                {
                    // Too big for one array: keep the commits before it, with no part of its message.
                    length = starts[position];
                    Array.Resize(ref starts, position);
                    truncated = true;
                    break;
                }
                // git writes hashes in lowercase; every hash of a repo has the same width (SHA-1 or SHA-256).
                var slot = hashes.AsSpan(position * hashWidth, hashWidth);
                if (!Encoding.UTF8.TryGetBytes(commit.Hash, slot, out _))
                {
                    Encoding.UTF8.GetBytes(commit.Hash).AsSpan(0, hashWidth).CopyTo(slot);
                }
            }

            Messages = messages;
            MessagesLength = length;
            Starts = starts;
            Hashes = hashes;
            HashWidth = hashWidth;
            IsTruncated = truncated;
        }

        /// <summary>Appends the commit's folded subject and body and a newline; false when they do not fit.</summary>
        private static bool AppendMessage(Commit commit, ref byte[] messages, ref int length)
        {
            if (!AppendFolded(commit.Subject, ref messages, ref length))
            {
                return false;
            }

            if (commit.Body.Length > 0
                && !(Append(0x20, ref messages, ref length) && AppendFolded(commit.Body, ref messages, ref length)))
            {
                return false;
            }

            return Append(0x0A, ref messages, ref length);
        }
    }

    /// <summary>
    /// The indices into <paramref name="commits"/> of the commits <paramref name="query"/> finds, in log order, each
    /// once: the message (subject and body) contains every word of the trimmed query, in any order (case- and
    /// diacritic-insensitive), or the query is at least <see cref="MinimumHashPrefix"/> hex characters and the hash
    /// contains it (anywhere, not only at its start). An empty or whitespace-only query finds nothing. A cancelled token
    /// gives an empty list. Searching a log more than once: build its <see cref="Index"/> once and use
    /// <see cref="Matches(Index, string, CancellationToken)"/>.
    /// </summary>
    public static int[] Matches(IReadOnlyList<Commit> commits, string query, CancellationToken ct = default) =>
        Matches(new Index(commits, ct), query, ct);

    /// <summary><see cref="Matches(IReadOnlyList{Commit}, string, CancellationToken)"/> on an index of the commits.</summary>
    public static int[] Matches(Index index, string query, CancellationToken ct = default)
    {
        var needle = query.Trim();
        if (needle.Length == 0)
        {
            return [];
        }

        var byMessage = MessageMatches(index, needle, ct);
        var isHash = needle.Length >= MinimumHashPrefix && needle.All(char.IsAsciiHexDigit);
        if (ct.IsCancellationRequested)
        {
            return [];
        }

        if (!isHash)
        {
            return byMessage;
        }

        return Merged(byMessage, HashMatches(index, Encoding.ASCII.GetBytes(needle.ToLowerInvariant())));
    }

    /// <summary>
    /// The commits whose folded message contains every word of the folded <paramref name="needle"/>, in any order and
    /// each anywhere (also inside a longer word): "update lib" finds "Refactored imports from lib updates".
    /// </summary>
    private static int[] MessageMatches(Index index, string needle, CancellationToken ct)
    {
        var folded = new byte[Math.Clamp((long)needle.Length * 3, 16, InitialCapacityLimit)];
        var length = 0;
        if (!AppendFolded(needle, ref folded, ref length))
        {
            return [];
        }

        int[]? found = null;
        foreach (var range in folded.AsSpan(0, length).Split((byte)0x20))
        {
            if (range.Start.Value == range.End.Value)
            {
                continue;
            }

            var hits = WordMatches(index, folded.AsSpan(range), ct);
            found = found is null ? hits : Intersected(found, hits);
            if (found.Length == 0)
            {
                break;
            }
        }

        return found is null || ct.IsCancellationRequested ? [] : found;
    }

    /// <summary>
    /// The commits whose folded message contains <paramref name="word"/> (which holds no newline, so a hit never spans
    /// two messages): one span scan per hit, the next scan starting at the next message, so a message counts once.
    /// </summary>
    private static int[] WordMatches(Index index, ReadOnlySpan<byte> word, CancellationToken ct)
    {
        var found = new List<int>();
        var haystack = index.Messages.AsSpan(0, index.MessagesLength);
        var offset = 0;
        while (offset < haystack.Length)
        {
            if ((found.Count & 0x3FF) == 0 && ct.IsCancellationRequested)
            {
                return [];
            }

            var hit = haystack[offset..].IndexOf(word);
            if (hit < 0)
            {
                break;
            }

            var commit = CommitIndex(offset + hit, index.Starts);
            found.Add(commit);
            offset = commit + 1 < index.Starts.Length ? index.Starts[commit + 1] : haystack.Length;
        }

        return [.. found];
    }

    /// <summary>The commits whose hash contains <paramref name="part"/> (lowercase bytes): one scan per hash, so a hit never spans two.</summary>
    private static int[] HashMatches(Index index, byte[] part)
    {
        if (part.Length > index.HashWidth)
        {
            return [];
        }

        var found = new List<int>();
        for (var commit = 0; commit < index.Count; commit++)
        {
            if (index.Hashes.AsSpan(commit * index.HashWidth, index.HashWidth).IndexOf(part) >= 0)
            {
                found.Add(commit);
            }
        }

        return [.. found];
    }

    /// <summary>The commit whose message holds byte <paramref name="position"/>: the last start at or before it.</summary>
    private static int CommitIndex(int position, int[] starts)
    {
        var low = 0;
        var high = starts.Length;
        while (high - low > 1)
        {
            var middle = (low + high) / 2;
            if (starts[middle] <= position)
            {
                low = middle;
            }
            else
            {
                high = middle;
            }
        }

        return low;
    }

    /// <summary>The indices in both ascending lists, ascending.</summary>
    private static int[] Intersected(int[] lhs, int[] rhs)
    {
        var result = new List<int>(Math.Min(lhs.Length, rhs.Length));
        var left = 0;
        var right = 0;
        while (left < lhs.Length && right < rhs.Length)
        {
            if (lhs[left] < rhs[right])
            {
                left++;
            }
            else if (lhs[left] > rhs[right])
            {
                right++;
            }
            else
            {
                result.Add(lhs[left]);
                left++;
                right++;
            }
        }

        return [.. result];
    }

    /// <summary>Two ascending index lists as one, each index once.</summary>
    private static int[] Merged(int[] lhs, int[] rhs)
    {
        if (rhs.Length == 0)
        {
            return lhs;
        }

        if (lhs.Length == 0)
        {
            return rhs;
        }

        var result = new List<int>(lhs.Length + rhs.Length);
        var left = 0;
        var right = 0;
        while (left < lhs.Length || right < rhs.Length)
        {
            if (right == rhs.Length || (left < lhs.Length && lhs[left] < rhs[right]))
            {
                result.Add(lhs[left]);
                left++;
            }
            else
            {
                if (left < lhs.Length && lhs[left] == rhs[right])
                {
                    left++;
                }

                result.Add(rhs[right]);
                right++;
            }
        }

        return [.. result];
    }

    /// <summary>Appends one byte; false when the buffer cannot grow to hold it.</summary>
    private static bool Append(byte value, ref byte[] buffer, ref int length)
    {
        if (!EnsureCapacity(ref buffer, length + 1L))
        {
            return false;
        }

        buffer[length++] = value;
        return true;
    }

    /// <summary>Grows <paramref name="buffer"/> to hold <paramref name="needed"/> bytes; false when no array can.</summary>
    private static bool EnsureCapacity(ref byte[] buffer, long needed)
    {
        var capacity = GrownCapacity(buffer.Length, needed);
        if (capacity < 0)
        {
            return false;
        }

        if (capacity > buffer.Length)
        {
            Array.Resize(ref buffer, capacity);
        }

        return true;
    }

    /// <summary>
    /// The size a buffer of <paramref name="current"/> bytes grows to so it holds <paramref name="needed"/> bytes:
    /// itself when it already does, else double (at least <paramref name="needed"/>, at most
    /// <see cref="Array.MaxLength"/>); -1 when <paramref name="needed"/> is past what one array holds.
    /// </summary>
    internal static int GrownCapacity(int current, long needed)
    {
        if (needed <= current)
        {
            return current;
        }

        if (needed > Array.MaxLength)
        {
            return -1;
        }

        return (int)Math.Min(Math.Max(needed, current * 2L), Array.MaxLength);
    }

    /// <summary>
    /// Appends <paramref name="text"/> lowercased and without diacritics, as UTF-8: an ASCII text byte by byte (most
    /// messages), any other through <see cref="Fold"/>. Each run of word separators (spaces, tabs, line breaks, "-",
    /// "_", "/") becomes one space, so "urgent fix", "urgent-fix" and "URGENT_fix" find each other.
    /// </summary>
    private static bool AppendFolded(string text, ref byte[] buffer, ref int length)
    {
        var source = Ascii.IsValid(text) ? text : Fold(text);
        // Encoding.GetMaxByteCount's bound, in long: it throws for a text past int.MaxValue / 3 characters.
        if (!EnsureCapacity(ref buffer, length + ((long)source.Length + 1) * 3))
        {
            return false;
        }

        var written = Encoding.UTF8.GetBytes(source, buffer.AsSpan(length));
        length += Normalize(buffer.AsSpan(length, written));
        return true;
    }

    /// <summary>
    /// <paramref name="text"/> lowercased (invariant) and without diacritics: decomposed (FormD), its non-spacing marks
    /// dropped, then recomposed (FormC), so "Café" folds to "cafe" and "Ångström" to "angstrom". A text holding a lone
    /// surrogate (half an emoji typed in the search box) cannot be normalized and is only lowercased.
    /// </summary>
    private static string Fold(string text)
    {
        var lower = text.ToLowerInvariant();
        string decomposed;
        try
        {
            decomposed = lower.Normalize(NormalizationForm.FormD);
        }
        catch (ArgumentException)
        {
            return lower;
        }

        var builder = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark)
            {
                builder.Append(character);
            }
        }

        return builder.ToString().Normalize(NormalizationForm.FormC);
    }

    /// <summary>
    /// Lowercases the ASCII letters of <paramref name="bytes"/> and turns each run of separators into one space, in
    /// place; non-ASCII bytes are kept as they are. Returns the new length.
    /// </summary>
    private static int Normalize(Span<byte> bytes)
    {
        var write = 0;
        var afterSeparator = false;
        foreach (var value in bytes)
        {
            // Space, tab, line feed, carriage return, "-", "_", "/".
            if (value is 0x20 or 0x09 or 0x0A or 0x0D or 0x2D or 0x5F or 0x2F)
            {
                if (afterSeparator)
                {
                    continue;
                }

                afterSeparator = true;
                bytes[write++] = 0x20;
            }
            else
            {
                afterSeparator = false;
                bytes[write++] = value is >= 0x41 and <= 0x5A ? (byte)(value | 0x20) : value;
            }
        }

        return write;
    }
}

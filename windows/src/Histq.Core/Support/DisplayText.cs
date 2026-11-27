using System.Globalization;
using System.Text;

namespace Histq.Core;

/// <summary>
/// Untrusted names (a tab's alias or folder name, a group name, a path, an error text) made safe to show and to hand to
/// UI Automation: no bidi override, embedding, isolate or mark (which could reorder the visible text and disguise one
/// repo as another), no control or line-breaking character (each run becomes one space), and at most a cap of text
/// elements, an ellipsis ending a cut one. Display only: stored names keep their text.
/// </summary>
public static class DisplayText
{
    /// <summary>The cap for a name or path shown in the UI or read by UI Automation.</summary>
    public const int MaxLength = 512;

    /// <summary>The longest text element kept, in UTF-16 units: far above any emoji sequence (a family with skin tones
    /// is under 30).</summary>
    public const int MaxElementLength = 64;

    private const string Ellipsis = "…";

    /// <summary>
    /// <paramref name="text"/> without bidi formatting characters (U+061C, U+200E, U+200F, U+202A-U+202E,
    /// U+2066-U+2069), each run of control characters and line or paragraph separators turned into one space, then cut
    /// to <paramref name="maxLength"/> text elements, ellipsis included (a surrogate pair, a flag or an emoji ZWJ
    /// sequence is never split). A text element longer than <see cref="MaxElementLength"/> UTF-16 units (a base
    /// character under thousands of combining marks) ends the text there. Only the text up to the cap is read; a text
    /// that needs no change comes back as is.
    /// </summary>
    public static string Sanitize(string? text, int maxLength = MaxLength)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxLength, 1);
        if (string.IsNullOrEmpty(text))
            return string.Empty;

        // Made at the first character to drop or replace, holding the text before it.
        StringBuilder? output = null;
        bool spaced = false;
        int elements = 0;
        int index = 0;
        while (index < text.Length)
        {
            int length = NextElementLength(text, index);
            int before = output?.Length ?? index;
            if (length > MaxElementLength)
                return Cut(output, text, before, maxLength);

            bool shows = false;
            for (int offset = index; offset < index + length; offset++)
            {
                char character = text[offset];
                if (IsBidi(character) || IsBreak(character))
                {
                    output ??= new StringBuilder().Append(text, 0, offset);
                    if (IsBreak(character) && !spaced)
                    {
                        output.Append(' ');
                        spaced = true;
                        shows = true;
                    }
                }
                else
                {
                    output?.Append(character);
                    spaced = false;
                    shows = true;
                }
            }

            if (shows && ++elements > maxLength)
                return Cut(output, text, before, maxLength);
            index += length;
        }

        return output?.ToString() ?? text;
    }

    /// <summary>
    /// <paramref name="text"/> cut to its first <paramref name="maxLength"/> text elements, with no ellipsis and nothing
    /// removed (the cap a rename puts on a stored name); it also stops before a text element longer than
    /// <see cref="MaxElementLength"/>. Only the text up to the cap is read.
    /// </summary>
    public static string Capped(string text, int maxLength = MaxLength)
    {
        ArgumentNullException.ThrowIfNull(text);
        int index = 0;
        for (int elements = 0; elements < maxLength && index < text.Length; elements++)
        {
            int length = NextElementLength(text, index);
            if (length > MaxElementLength)
                break;
            index += length;
        }

        return index < text.Length ? text[..index] : text;
    }

    /// <summary>The kept text (the first <paramref name="kept"/> characters of the output, or of the text while nothing
    /// changed) cut to <paramref name="maxLength"/> - 1 text elements, and the ellipsis.</summary>
    private static string Cut(StringBuilder? output, string text, int kept, int maxLength) =>
        Capped(output is null ? text[..kept] : output.ToString(0, kept), maxLength - 1).TrimEnd() + Ellipsis;

    /// <summary>The length of the text element at <paramref name="index"/>, reading at most one unit past
    /// <see cref="MaxElementLength"/>.</summary>
    private static int NextElementLength(string text, int index) =>
        StringInfo.GetNextTextElementLength(text.AsSpan(index, Math.Min(text.Length - index, MaxElementLength + 1)));

    private static bool IsBidi(char character) =>
        character is '\u061C' or '\u200E' or '\u200F' or (>= '\u202A' and <= '\u202E') or (>= '\u2066' and <= '\u2069');

    private static bool IsBreak(char character) =>
        char.IsControl(character) || character is '\u2028' or '\u2029';
}

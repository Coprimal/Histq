// The dateFormat preference is a Unicode (ICU) date pattern, as the Mac's DateFormatter takes it ("MM/dd/yy @ HH:mm",
// "MMM d, yyyy h:mm a"); .NET's custom date and time format strings differ in a few letters and treat "/" and ":" as the
// culture's separators. This turns one into the other.
using System.Text;

namespace Histq.Core;

public static class IcuDateFormat
{
    /// <summary>The dateFormat preference's default (24 h).</summary>
    public const string DefaultPattern = "MM/dd/yy @ HH:mm";

    /// <summary>
    /// <paramref name="pattern"/> as a .NET custom format string for <see cref="DateTimeOffset.ToString(string?, IFormatProvider?)"/>.
    /// Year, month, day, hour, minute and second fields map to their .NET letters (<c>y</c> alone is the full year), weekday
    /// names (<c>E</c>, and <c>eee</c> / <c>ccc</c> and longer) to <c>ddd</c> / <c>dddd</c>, the period (<c>a</c>) to
    /// <c>tt</c>; a field .NET has no letter for (a numeric weekday <c>e</c> / <c>c</c>, a time zone, ...) is left out.
    /// Every other character, and quoted text (<c>'at'</c>, <c>''</c> for a quote), is kept as written, never read as a
    /// culture's separator. A pattern with no field .NET can show gives <see cref="DefaultPattern"/>'s format.
    /// </summary>
    public static string ToDotNet(string pattern)
    {
        ArgumentNullException.ThrowIfNull(pattern);
        var output = new StringBuilder(pattern.Length + 8);
        var fields = false;
        var index = 0;
        while (index < pattern.Length)
        {
            var c = pattern[index];
            if (c == '\'')
            {
                index = Quoted(pattern, index, output);
                continue;
            }

            if (!char.IsAsciiLetter(c))
            {
                Literal(c, output);
                index++;
                continue;
            }

            var run = 1;
            while (index + run < pattern.Length && pattern[index + run] == c)
            {
                run++;
            }

            var field = Field(c, run);
            fields |= field.Length > 0;
            output.Append(field);
            index += run;
        }

        if (!fields)
        {
            return ToDotNet(DefaultPattern);
        }

        // A single letter alone would be read as a standard format ("d" is the short date).
        return output.Length == 1 ? "%" + output : output.ToString();
    }

    /// <summary>The .NET letters of an ICU field of <paramref name="count"/> <paramref name="letter"/>s.</summary>
    private static string Field(char letter, int count) => letter switch
    {
        'y' or 'u' => count == 2 ? "yy" : "yyyy",
        'M' or 'L' => new string('M', Math.Min(count, 4)),
        'd' => new string('d', Math.Min(count, 2)),
        'E' => count >= 4 ? "dddd" : "ddd",
        // One or two: the weekday's number, which .NET has no letter for.
        'c' or 'e' => count >= 4 ? "dddd" : count == 3 ? "ddd" : "",
        'H' or 'h' or 'm' or 's' => new string(letter, Math.Min(count, 2)),
        'k' => new string('H', Math.Min(count, 2)),
        'K' => new string('h', Math.Min(count, 2)),
        'a' or 'b' or 'B' => "tt",
        _ => "",
    };

    /// <summary>Copies the quoted text starting at <paramref name="start"/> (its opening quote) as literals; returns
    /// the index after its closing quote (the end for an unclosed one). <c>''</c> is one quote, inside or outside.</summary>
    private static int Quoted(string pattern, int start, StringBuilder output)
    {
        if (start + 1 < pattern.Length && pattern[start + 1] == '\'')
        {
            Literal('\'', output);
            return start + 2;
        }

        var index = start + 1;
        while (index < pattern.Length)
        {
            if (pattern[index] == '\'')
            {
                if (index + 1 < pattern.Length && pattern[index + 1] == '\'')
                {
                    Literal('\'', output);
                    index += 2;
                    continue;
                }

                return index + 1;
            }

            Literal(pattern[index], output);
            index++;
        }

        return index;
    }

    /// <summary>A character .NET copies as is: escaped, so no letter, separator or quote is read as a field.</summary>
    private static void Literal(char c, StringBuilder output) => output.Append('\\').Append(c);
}

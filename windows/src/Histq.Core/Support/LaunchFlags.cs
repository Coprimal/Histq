using System.Globalization;

namespace Histq.Core;

/// <summary>
/// Launch flags in the Mac's argument-domain style: a <c>-HistqName value</c> pair, the first occurrence winning
/// (<c>-HistqWindowSize 1280,800</c>). A flag without a value, or one whose value does not parse, reads as absent.
/// Numbers are read in the invariant culture.
/// </summary>
public sealed class LaunchFlags(IReadOnlyList<string> arguments)
{
    private const NumberStyles Whitespace = NumberStyles.AllowLeadingWhite | NumberStyles.AllowTrailingWhite;

    /// <summary>
    /// The positional arguments (a folder or a workspace file to open, as the Mac's <c>open -a Histq &lt;folder&gt;</c>):
    /// every argument that neither starts with <c>-</c> nor is the value after one, which is a flag's (launch flags are
    /// <c>-Name value</c> pairs, so a flag's value is never opened, whatever it looks like; a flag followed by another
    /// flag has no value). Empty ones are left out.
    /// </summary>
    public static IReadOnlyList<string> Positional(IReadOnlyList<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var positional = new List<string>();
        for (var i = 0; i < arguments.Count; i++)
        {
            var argument = arguments[i];
            if (argument.StartsWith('-'))
            {
                if (i + 1 < arguments.Count && !arguments[i + 1].StartsWith('-'))
                {
                    i++;
                }
            }
            else if (!string.IsNullOrWhiteSpace(argument))
            {
                positional.Add(argument);
            }
        }

        return positional;
    }

    /// <summary>The value after the first <paramref name="name"/>, or null.</summary>
    public string? String(string name) => StatePaths.LaunchFlag(arguments, name);

    /// <summary>The value as an integer, or null.</summary>
    public int? Int(string name) =>
        int.TryParse(String(name), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;

    /// <summary>The value as a finite number, or null.</summary>
    public double? Double(string name) =>
        double.TryParse(String(name), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
        && double.IsFinite(value)
            ? value
            : null;

    /// <summary>A <c>W,H</c> value of two positive integers (<c>1280,800</c>), or null.</summary>
    public (int Width, int Height)? Size(string name)
    {
        var parts = String(name)?.Split(',');
        if (parts is not { Length: 2 }
            || !int.TryParse(parts[0], Whitespace, CultureInfo.InvariantCulture, out var width)
            || !int.TryParse(parts[1], Whitespace, CultureInfo.InvariantCulture, out var height)
            || width <= 0 || height <= 0)
        {
            return null;
        }

        return (width, height);
    }
}

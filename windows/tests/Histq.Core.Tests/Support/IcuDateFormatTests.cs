// Key feature test for IcuDateFormat: the Mac's date format choices (Unicode patterns) give the same text in .NET, with
// "/" and ":" kept as written whatever the culture's separators.
using System.Globalization;

namespace Histq.Core.Tests;

public sealed class IcuDateFormatTests
{
    [Theory]
    [InlineData("MM/dd/yy @ HH:mm", "12/31/25 @ 23:58")]
    [InlineData("MM/dd/yyyy @ h:mm a", "12/31/2025 @ 11:58 PM")]
    [InlineData("dd/MM/yyyy HH:mm", "31/12/2025 23:58")]
    [InlineData("yyyy-MM-dd HH:mm", "2025-12-31 23:58")]
    [InlineData("MMM d, yyyy h:mm a", "Dec 31, 2025 11:58 PM")]
    [InlineData("d MMM yyyy HH:mm", "31 Dec 2025 23:58")]
    [InlineData("EEEE 'at' HH:mm", "Wednesday at 23:58")]
    [InlineData("d", "31")]
    public void FormatsLikeTheMac(string pattern, string expected)
    {
        var date = new DateTimeOffset(2025, 12, 31, 23, 58, 0, TimeSpan.Zero);

        Assert.Equal(expected, date.ToString(IcuDateFormat.ToDotNet(pattern), CultureInfo.InvariantCulture));
    }

    // A culture with other separators (Finnish writes times with ".") keeps the pattern's.
    [Fact]
    public void KeepsThePatternsSeparators()
    {
        var date = new DateTimeOffset(2025, 12, 31, 23, 58, 0, TimeSpan.Zero);

        Assert.Equal("23:58", date.ToString(IcuDateFormat.ToDotNet("HH:mm"), new CultureInfo("fi-FI")));
    }

    // A numeric weekday (e, ee, c, cc) has no .NET letter: it is left out; the long forms are the weekday's name. A
    // pattern with no field .NET can show falls back to the default format, never to .NET's general one.
    [Theory]
    [InlineData("e d", "31")]
    [InlineData("eeee", "Wednesday")]
    [InlineData("ccc", "Wed")]
    [InlineData("ee", "12/31/25 @ 23:58")]
    [InlineData("zzzz 'x'", "12/31/25 @ 23:58")]
    public void LeavesOutWhatDotNetCannotShow(string pattern, string expected)
    {
        var date = new DateTimeOffset(2025, 12, 31, 23, 58, 0, TimeSpan.Zero);

        Assert.Equal(expected, date.ToString(IcuDateFormat.ToDotNet(pattern), CultureInfo.InvariantCulture).Trim());
    }
}

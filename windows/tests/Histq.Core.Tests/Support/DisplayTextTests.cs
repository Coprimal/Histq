// DisplayText: untrusted names made safe to show and to read through UI Automation (no bidi reordering, no line
// breaks or control characters, a cap by text element that never splits a surrogate pair, a flag or a ZWJ sequence).
namespace Histq.Core.Tests;

public sealed class DisplayTextTests
{
    [Theory]
    [InlineData("\u202Egpj.exe", "gpj.exe")]
    [InlineData("a\u202Ab\u202Bc\u202Cd\u202De", "abcde")]
    [InlineData("\u2066repo\u2069\u2067x\u2068y", "repoxy")]
    [InlineData("\u200Ename\u200F\u061C", "name")]
    public void DropsBidiFormattingCharacters(string text, string expected) =>
        Assert.Equal(expected, DisplayText.Sanitize(text));

    [Theory]
    [InlineData("line1\nline2", "line1 line2")]
    [InlineData("a\r\n\tb", "a b")]
    [InlineData("a\u0000\u0007b", "a b")]
    [InlineData("a\u2028b\u2029c\u0085d", "a b c d")]
    public void TurnsEachRunOfControlCharactersIntoOneSpace(string text, string expected) =>
        Assert.Equal(expected, DisplayText.Sanitize(text));

    [Fact]
    public void ReturnsACleanShortTextAsIs()
    {
        const string text = "histq-deep-demo \U0001F525";
        Assert.Same(text, DisplayText.Sanitize(text));
    }

    [Fact]
    public void KeepsZwjSequencesAndVariationSelectors()
    {
        const string family = "\U0001F468\u200D\U0001F469\u200D\U0001F467";
        const string heart = "\u2764\uFE0F";
        Assert.Equal(family + heart, DisplayText.Sanitize(family + heart));
    }

    [Fact]
    public void CapsByTextElementWithTheEllipsisIncluded()
    {
        Assert.Equal("abcd…", DisplayText.Sanitize("abcdefgh", 5));
        Assert.Equal("abcde", DisplayText.Sanitize("abcde", 5));
    }

    [Fact]
    public void NeverSplitsASurrogatePairOrAZwjSequence()
    {
        const string family = "\U0001F468\u200D\U0001F469\u200D\U0001F467";
        const string pair = "\U0001F525";
        Assert.Equal(family + family + "…", DisplayText.Sanitize(family + family + family + family, 3));
        Assert.Equal(pair + pair + "…", DisplayText.Sanitize(pair + pair + pair + pair, 3));
    }

    [Fact]
    public void CapsAMultiMegabyteText()
    {
        string text = "\u202E" + new string('x', 4_000_000);
        string shown = DisplayText.Sanitize(text);
        Assert.Equal(DisplayText.MaxLength, shown.Length);
        Assert.EndsWith("…", shown, StringComparison.Ordinal);
        Assert.DoesNotContain('\u202E', shown);
    }

    [Fact]
    public void StopsBeforeAnOversizedTextElement()
    {
        string marks = new string('\u0301', 4_000_000);
        Assert.Equal("ab…", DisplayText.Sanitize("ab" + "x" + marks));
        Assert.Equal("ab", DisplayText.Capped("ab" + "x" + marks));
        Assert.Equal("e\u0301", DisplayText.Sanitize("e\u0301"));
    }

    [Fact]
    public void RemovedCharactersDoNotCountTowardTheCap() =>
        Assert.Equal("abc", DisplayText.Sanitize("\u202Ea\u202Eb\u202Ec\u202E", 3));

    [Fact]
    public void NullAndEmptyGiveEmpty()
    {
        Assert.Equal(string.Empty, DisplayText.Sanitize(null));
        Assert.Equal(string.Empty, DisplayText.Sanitize(string.Empty));
    }

    [Fact]
    public void CappedCutsByTextElementAndKeepsEverythingElse()
    {
        const string family = "\U0001F468\u200D\U0001F469\u200D\U0001F467";
        Assert.Equal("\u202Ea" + family, DisplayText.Capped("\u202Ea" + family + "bc", 3));
        Assert.Equal("ab", DisplayText.Capped("ab", 3));
    }
}

// The repo layout's side panel widths (PanelWidths in App/Repo/RepoLayoutView.swift at 6fa6d40, private there and
// untested on the Mac): the stored "sidebar,detail" value, the fit that keeps the graph's minimum, and the divider drags.
namespace Histq.Core.Tests;

public sealed class PanelWidthsTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("300")]
    [InlineData("1,2,3")]
    [InlineData("a,b")]
    [InlineData("NaN,400")]
    public void MalformedValueDecodesToTheDefaults(string? encoded) =>
        Assert.Equal(RepoLayoutMetrics.Defaults, PanelWidths.Decode(encoded));

    [Fact]
    public void DecodeSkipsPartsThatAreNotNumbers()
    {
        Assert.Equal(new PanelWidths(300, 400), PanelWidths.Decode("300,400"));
        Assert.Equal(new PanelWidths(300, 400), PanelWidths.Decode("300,x,400"));
    }

    [Fact]
    public void EncodedRoundsHalvesAwayFromZero()
    {
        Assert.Equal("253,360", new PanelWidths(252.5, 359.6).Encoded);
        Assert.Equal(new PanelWidths(253, 360), PanelWidths.Decode(new PanelWidths(252.5, 359.6).Encoded));
    }

    [Fact]
    public void FittedClampsToTheRangesWhenThereIsRoom()
    {
        Assert.Equal(new PanelWidths(420, 320), new PanelWidths(900, 10).Fitted(5000));
        Assert.Equal(new PanelWidths(252, 360), RepoLayoutMetrics.Defaults.Fitted(1200));
    }

    [Fact]
    public void FittedShrinksTheSidePanelsInProportionToTheirSpare()
    {
        // 400 + 480 + 360 = 1240 in 1140: 100 over, spare 200 + 160 = 360.
        var fitted = new PanelWidths(400, 480).Fitted(1140);

        Assert.Equal(400 - 100 * 200 / 360.0, fitted.Sidebar, 9);
        Assert.Equal(480 - 100 * 160 / 360.0, fitted.Detail, 9);
        Assert.Equal(1140 - RepoLayoutMetrics.GraphMin, fitted.Sidebar + fitted.Detail, 9);
    }

    [Fact]
    public void FittedScalesTheMinimumsBelowTheirSum()
    {
        // The minimums sum to 880; in 440 every panel gets half of its minimum.
        Assert.Equal(new PanelWidths(100, 160), new PanelWidths(400, 600).Fitted(440));
        Assert.Equal(new PanelWidths(0, 0), new PanelWidths(400, 600).Fitted(-10));
    }

    [Fact]
    public void DraggingTheSidebarKeepsTheGraphMinimumAndTheRange()
    {
        var start = new PanelWidths(252, 360);

        Assert.Equal(new PanelWidths(302, 360), start.DraggingSidebar(50, 2000));
        // 1000 - 360 - 360 = 280 at most.
        Assert.Equal(new PanelWidths(280, 360), start.DraggingSidebar(400, 1000));
        Assert.Equal(new PanelWidths(200, 360), start.DraggingSidebar(-400, 2000));
        Assert.Equal(new PanelWidths(420, 360), start.DraggingSidebar(1000, 5000));
    }

    [Fact]
    public void DraggingTheDetailGrowsItLeftward()
    {
        var start = new PanelWidths(252, 360);

        Assert.Equal(new PanelWidths(252, 410), start.DraggingDetail(-50, 2000));
        Assert.Equal(new PanelWidths(252, 320), start.DraggingDetail(200, 2000));
        // 1000 - 252 - 360 = 388 at most.
        Assert.Equal(new PanelWidths(252, 388), start.DraggingDetail(-400, 1000));
        Assert.Equal(new PanelWidths(252, 640), start.DraggingDetail(-1000, 5000));
    }
}

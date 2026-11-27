// Key feature test for the tab lists' search (All Tabs and the archive): rows come in the window's order, then the
// archive's, then the closed groups'; a query matches a title or a folder, ignoring case and diacritics.
namespace Histq.Core.Tests;

public sealed class TabListSearchTests
{
    [Fact]
    public void AllTabsListsOpenThenArchivedThenClosedGroupTabsMatchingTitleOrPath()
    {
        var model = new WindowTabs(PathFlavor.Posix, _ => true);
        foreach (var path in new[] { "/r/api", "/r/web", "/r/docs", "/r/café", "/x/lib" })
        {
            model.OpenTab(path);
        }

        Guid Id(string path) => model.Tabs.Single(tab => string.Equals(tab.Path, path, StringComparison.Ordinal)).Id;
        model.ArchiveTab(Id("/r/web"));
        var group = model.CreateGroup([Id("/r/docs")])!.Value;
        model.CloseGroup(group);

        Assert.Equal(
            ["open /r/api", "open /r/café", "open /x/lib", "archived 0 /r/web", "closed 0 /r/docs"],
            TabListSearch.AllTabs(model, "  ").Select(Describe));
        Assert.Equal(["archived 0 /r/web"], TabListSearch.AllTabs(model, " WEB ").Select(Describe));
        Assert.Equal(["open /r/café"], TabListSearch.AllTabs(model, "Cafe").Select(Describe));
        Assert.Equal(["open /r/api", "open /r/café", "archived 0 /r/web", "closed 0 /r/docs"],
            TabListSearch.AllTabs(model, "/r/").Select(Describe));
        Assert.Empty(TabListSearch.AllTabs(model, "nothing"));

        var archived = Assert.Single(TabListSearch.Archived(model, "we"));
        Assert.Equal((0, "/r/web"), (archived.Index, archived.Entry.Path));
        Assert.Empty(TabListSearch.Archived(model, "api"));
    }

    private static string Describe(TabListSearch.Row row) =>
        row switch
        {
            TabListSearch.Row.Open open => $"open {open.Tab.Path}",
            TabListSearch.Row.Archived archived => $"archived {archived.Index} {archived.Entry.Path}",
            TabListSearch.Row.Closed closed => $"closed {closed.Index} {closed.Group.Tabs[closed.Index].Path}",
            _ => "?",
        };
}

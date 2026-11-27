// "Repo not found"'s Locate (WindowModel.locate at 6fa6d40, untested on the Mac; these follow its documented
// behaviour): the missing tab takes the picked folder in place, or gives way to the tab or archive entry that has it.
namespace Histq.Core.Tests;

public sealed class WindowTabsLocateTests
{
    private static WindowTabs Open(params string[] paths)
    {
        var model = new WindowTabs(PathFlavor.Posix, _ => true);
        foreach (var path in paths)
        {
            model.OpenTab(path);
        }

        return model;
    }

    private static Guid Id(WindowTabs model, string path) =>
        model.Tabs.Single(tab => string.Equals(tab.Path, path, StringComparison.Ordinal)).Id;

    private static Guid Missing(WindowTabs model, string path)
    {
        var id = Id(model, path);
        model.ApplyFolderChecks([(id, path, false)]);
        Assert.True(model.Tabs.Single(tab => tab.Id == id).IsMissing);
        return id;
    }

    [Fact]
    public void LocateTakesThePathInPlace()
    {
        var model = Open("/r/a", "/r/gone");
        var id = Missing(model, "/r/gone");
        model.SetAlias("work", id);
        IReadOnlyList<(Guid Id, string Path)>? asked = null;
        model.RepoKeysNeeded = requests => asked = requests;

        Assert.True(model.Locate(id, "/r/moved/"));

        var tab = model.Tabs[1];
        Assert.Equal(id, tab.Id);
        Assert.Equal("/r/moved", tab.Path);
        Assert.False(tab.IsMissing);
        Assert.Null(tab.RepoKey);
        Assert.Equal("work", tab.Alias);
        Assert.Equal(id, model.SelectedTabId);
        Assert.Equal([(id, "/r/moved")], asked!);
    }

    [Fact]
    public void LocateOntoAnOpenRepoSelectsItAndClosesTheMissingTab()
    {
        var model = Open("/r/a", "/r/gone");
        var id = Missing(model, "/r/gone");

        Assert.False(model.Locate(id, "/r/a"));

        Assert.Equal(["/r/a"], model.Tabs.Select(tab => tab.Path));
        Assert.Equal(Id(model, "/r/a"), model.SelectedTabId);
        Assert.False(model.CanReopenClosedTab);
    }

    [Fact]
    public void LocateOntoAnArchivedRepoPopsItOut()
    {
        var model = Open("/r/a", "/r/x", "/r/gone");
        model.ArchiveTab(Id(model, "/r/x"));
        var id = Missing(model, "/r/gone");

        Assert.False(model.Locate(id, "/r/x"));

        Assert.Equal(["/r/a", "/r/x"], model.Tabs.Select(tab => tab.Path));
        Assert.True(model.Tabs[1].Archived);
        Assert.Equal(model.Tabs[1].Id, model.SelectedTabId);
        Assert.Empty(model.ArchivedTabs);
    }

    [Fact]
    public void LocateOfAnUnknownTabDoesNothing()
    {
        var model = Open("/r/a");

        Assert.False(model.Locate(Guid.NewGuid(), "/r/b"));

        Assert.Equal(["/r/a"], model.Tabs.Select(tab => tab.Path));
    }
}

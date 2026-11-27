// Key feature test for moving a tab between windows (Move Tab to Window ›, a tab dragged onto another window): the
// tab leaves its group and its window without going on the reopen stack, the source keeps a Welcome tab only when its
// archive or closed groups would otherwise be lost, and the destination puts it last, selected, in its repo's worktree
// box with the box's pin. The refusals follow the Mac's moveRefusal (App/HistqApp.swift at 6fa6d40), plus the Windows
// guard: a UNC or device folder never leaves a workspace window.
namespace Histq.Core.Tests;

public sealed class WindowMoveTests
{
    /// <summary>A model on POSIX rules where every folder exists, with one tab per path (the first fills the Welcome
    /// tab).</summary>
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

    private static string? SelectedPath(WindowTabs model) =>
        model.Tabs.Single(tab => tab.Id == model.SelectedTabId).Path;

    [Fact]
    public void DetachLeavesTheGroupSelectsTheNeighbourAndIsNotReopened()
    {
        var model = Open("/r/a", "/r/b", "/r/c");
        var group = model.CreateGroup([Id(model, "/r/b"), Id(model, "/r/c")])!.Value;
        model.SelectTab(Id(model, "/r/b"));

        var moved = model.DetachTab(Id(model, "/r/b"));

        Assert.NotNull(moved);
        Assert.Equal("/r/b", moved.Tab.Path);
        Assert.Null(moved.Tab.GroupId);
        Assert.Equal(["/r/a", "/r/c"], model.Tabs.Select(tab => tab.Path));
        Assert.Equal("/r/c", SelectedPath(model));
        Assert.Equal(group, model.Tabs[1].GroupId);
        Assert.False(model.CanReopenClosedTab);
    }

    [Fact]
    public void DetachOfTheLastTabKeepsAWelcomeTabOnlyForTheArchive()
    {
        var alone = Open("/r/a");
        Assert.NotNull(alone.DetachTab(Id(alone, "/r/a")));
        Assert.Empty(alone.Tabs);

        var archiving = Open("/r/a", "/r/b");
        archiving.ArchiveTab(Id(archiving, "/r/b"));
        Assert.NotNull(archiving.DetachTab(Id(archiving, "/r/a")));
        var welcome = Assert.Single(archiving.Tabs);
        Assert.Null(welcome.Path);
        Assert.Equal(welcome.Id, archiving.SelectedTabId);
        Assert.Single(archiving.ArchivedTabs);
    }

    [Fact]
    public void DetachRefusesThePoppedOutArchivedTab()
    {
        var model = Open("/r/a", "/r/b");
        model.ArchiveTab(Id(model, "/r/b"));
        model.OpenArchived(0);
        var popped = model.ArchivedOut!.Id;

        Assert.Null(model.DetachTab(popped));
        Assert.Equal(popped, model.SelectedTabId);
    }

    [Fact]
    public void AdoptPutsTheTabLastSelectedInItsBoxWithTheBoxPin()
    {
        var source = Open("/r/x-w2", "/r/s");
        source.ApplyRepoKeys([(Id(source, "/r/x-w2"), "/r/x-w2", "/r/x/.git")]);
        var destination = Open("/r/x", "/r/y");
        destination.ApplyRepoKeys([(Id(destination, "/r/x"), "/r/x", "/r/x/.git")]);
        destination.SetPinned(true, Id(destination, "/r/x"));

        destination.Adopt(source.DetachTab(Id(source, "/r/x-w2"))!);

        Assert.Equal(["/r/x", "/r/x-w2", "/r/y"], destination.Tabs.Select(tab => tab.Path));
        Assert.True(destination.Tabs[1].Pinned);
        Assert.Equal("/r/x-w2", SelectedPath(destination));
        Assert.Equal(["/r/s"], source.Tabs.Select(tab => tab.Path));
    }

    [Fact]
    public void AdoptSelectsTheDestinationsOwnTabOfTheRepo()
    {
        var source = Open("/r/a", "/r/b");
        var destination = Open("/r/a", "/r/c");

        destination.Adopt(source.DetachTab(Id(source, "/r/a"))!);

        Assert.Equal(["/r/a", "/r/c"], destination.Tabs.Select(tab => tab.Path));
        Assert.Equal("/r/a", SelectedPath(destination));
    }

    [Fact]
    public void MoveRefusalsFollowTheMacOrder()
    {
        var folder = Fixtures.MakeTempDirectory("HistqMove");
        try
        {
            var team = new WorkspaceDocument(Path.Join(folder, "team.histqws"));
            var source = Open("/r/a", "/r/b");
            var destination = Open("/r/c");
            var a = Id(source, "/r/a");

            Assert.Null(WindowTabs.MoveRefusal(a, source, null, 0, destination, null));
            Assert.Null(WindowTabs.MoveRefusal(a, source, team, 1, destination, null));
            Assert.Equal("The tab or the window is gone.", WindowTabs.MoveRefusal(a, source, null, 0, source, null));
            Assert.Equal("The tab or the window is gone.",
                WindowTabs.MoveRefusal(Guid.NewGuid(), source, null, 0, destination, null));

            // The last tab of a workspace's last window stays; with another window open it moves.
            var lone = Open("/r/l");
            Assert.Equal("Last tab of team \u2014 use Close Workspace",
                WindowTabs.MoveRefusal(Id(lone, "/r/l"), lone, team, 1, destination, null));
            Assert.Null(WindowTabs.MoveRefusal(Id(lone, "/r/l"), lone, team, 2, destination, null));
            Assert.Null(WindowTabs.MoveRefusal(Id(lone, "/r/l"), lone, null, 0, destination, null));

            // A file not being written refuses on either side.
            team.RecordWrite(new IOException("disk full"));
            Assert.Equal("team is not being saved", WindowTabs.MoveRefusal(a, source, null, 0, destination, team));
            Assert.Equal("team is not being saved", WindowTabs.MoveRefusal(a, source, team, 2, destination, null));
            team.RecordWrite(null);

            var missing = new WindowTabs(PathFlavor.Posix, _ => true);
            missing.Restore([new SavedTab("/r/gone"), new SavedTab("/r/d")], 0, new HashSet<string> { "/r/gone" });
            Assert.Equal("Locate the repo first",
                WindowTabs.MoveRefusal(Id(missing, "/r/gone"), missing, null, 0, destination, null));

            source.ArchiveTab(Id(source, "/r/b"));
            source.OpenArchived(0);
            Assert.Equal("Unarchive the tab to move it.",
                WindowTabs.MoveRefusal(source.ArchivedOut!.Id, source, null, 0, destination, null));

            var other = Open("/r/a");
            Assert.Equal("a is already open in that window", WindowTabs.MoveRefusal(a, source, null, 0, other, null));
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    [Fact]
    public void ReadOnlyWorkspaceRefusesMovesInAndOut()
    {
        var folder = Fixtures.MakeTempDirectory("HistqMove");
        try
        {
            var path = Path.Join(folder, "future.histqws");
            File.WriteAllText(path, """{"future":1,"version":1,"windows":[{"id":"5E5510A0-0000-4000-8000-000000000011","tabs":[{}]}],"repos":[],"profiles":[]}""");
            var future = WorkspaceDocument.Open(path, folder, _ => false).Document;
            Assert.True(future.IsReadOnly);
            var source = Open("/r/a", "/r/b");

            Assert.Equal("future is read-only",
                WindowTabs.MoveRefusal(Id(source, "/r/a"), source, null, 0, Open("/r/c"), future));
            Assert.Equal("future is read-only",
                WindowTabs.MoveRefusal(Id(source, "/r/a"), source, future, 2, Open("/r/c"), null));
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }

    [Theory]
    [InlineData(@"\\server\share\repo")]
    [InlineData(@"\\?\C:\repo")]
    public void NetworkFolderNeverLeavesAWorkspaceWindow(string path)
    {
        var folder = Fixtures.MakeTempDirectory("HistqMove");
        try
        {
            var team = new WorkspaceDocument(Path.Join(folder, "team.histqws"));
            // Found, as a tab reopened in a workspace window shows until its folder check returns.
            var source = new WindowTabs(PathFlavor.Windows, _ => true);
            source.OpenTab(path);
            source.OpenTab("C:/r/b");
            var id = source.Tabs[0].Id;
            var destination = new WindowTabs(PathFlavor.Windows, _ => true);

            Assert.Equal("A network folder stays in its workspace",
                WindowTabs.MoveRefusal(id, source, team, 2, destination, null));
            Assert.Equal("A network folder stays in its workspace",
                WindowTabs.MoveRefusal(id, source, team, 2, destination, team));
            // The user's own network folder in an Untitled window moves.
            Assert.Null(WindowTabs.MoveRefusal(id, source, null, 0, destination, null));
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }
}

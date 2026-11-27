// Key feature test for workspace windows (format contract with the Mac): a workspace window comes back with the tab
// session.json saved as selected and its collapsed groups collapsed (machine-local, never in the .histqws), session.json
// keeps a closed workspace's layout only while it is open or in Recent Workspaces, numbered after the live windows, and
// a workspace file holds only the views and embedded profiles of its tabs. Ported from restoreWindows, selectedTab(of:),
// currentSession and workspaceFile(for:) in App/HistqApp.swift at 6fa6d40.
namespace Histq.Core.Tests;

public sealed class WorkspaceLayoutsTests
{
    private static readonly Guid Docs = Guid.Parse("5E5510A0-0000-4000-8000-000000000021");
    private static readonly Guid Old = Guid.Parse("5E5510A0-0000-4000-8000-000000000022");
    private static readonly Guid WindowId = Guid.Parse("5E5510A0-0000-4000-8000-000000000023");

    private static WorkspaceFile.LiveWindow Window() =>
        new(WindowId,
            [new SavedTab("/r/docs", TabGroup: Docs), new SavedTab("/r/api", TabGroup: Docs), new SavedTab("/r/web"),
                new SavedTab("/r/old", Archived: true)],
            [new WorkspaceFile.TabGroup(Docs, 1, "Docs")]);

    [Fact]
    public void SelectedTabIsTheSavedPathElseTheFirstOutsideACollapsedGroup()
    {
        var none = new HashSet<Guid>();
        var collapsed = new HashSet<Guid> { Docs };

        Assert.Equal(2, WorkspaceLayouts.SelectedTab(Window(), "/r/web", collapsed));
        Assert.Equal(3, WorkspaceLayouts.SelectedTab(Window(), "/r/old", none));
        Assert.Equal(0, WorkspaceLayouts.SelectedTab(Window(), null, none));
        Assert.Equal(2, WorkspaceLayouts.SelectedTab(Window(), "/r/gone", collapsed));
    }

    [Fact]
    public void LayoutRoundTripKeepsSelectionAndCollapseOutOfTheFile()
    {
        var window = Window();
        var collapsed = new HashSet<Guid> { Docs };
        var model = new WindowTabs(PathFlavor.Posix, _ => true);
        model.Restore(window.Tabs, WorkspaceLayouts.SelectedTab(window, "/r/web", collapsed), new HashSet<string>(),
            WorkspaceLayouts.TabGroups(window, collapsed), window.ClosedTabGroups);

        Assert.True(model.IsCollapsed(Docs));
        var layout = model.LayoutWindow(WindowId, 10, 20, 1100, 700, group: 3);
        Assert.Equal(new WorkspaceLayout.Window(WindowId, 10, 20, 1100, 700, 3, 0, true, "/r/web", [Docs]), layout);

        // The file keeps the group, not its collapse; the archived tab stays last.
        var live = model.LiveWindow(WindowId);
        Assert.Equal([new WorkspaceFile.TabGroup(Docs, 1, "Docs")], live.TabGroups);
        Assert.Equal(window.Tabs, live.Tabs);

        model.ToggleGroup(Docs);
        Assert.Null(model.LayoutWindow(WindowId, 10, 20, 1100, 700, group: 3).CollapsedGroups);
    }

    [Fact]
    public void KeptLayoutsNeedOpenOrRecentAndFollowTheLiveWindows()
    {
        static WorkspaceLayout Layout(string path, bool open, params int[] groups) =>
            new(path, open, groups.Select(group => new WorkspaceLayout.Window(Guid.NewGuid(), 0, 0, 800, 600, group, 0, true)).ToList());

        IReadOnlyList<WorkspaceLayout> layouts =
        [
            Layout("/w/live.histqws", true, 0),
            Layout("/w/failed.histqws", true, 7),
            Layout("/w/recent.histqws", false, 2, 9),
            Layout("/w/forgotten.histqws", false, 4),
        ];

        var kept = WorkspaceLayouts.Kept(layouts, ["/w/live.histqws"], ["/w/./recent.histqws"], liveGroups: 3);

        Assert.Equal(["/w/failed.histqws", "/w/recent.histqws"], kept.Select(layout => layout.Path));
        Assert.Equal([4], kept[0].Windows.Select(window => window.Group));
        Assert.Equal([3, 5], kept[1].Windows.Select(window => window.Group));
    }

    [Fact]
    public void FileHoldsTheViewsOfItsTabsAndSaveAsRebindsFromACopy()
    {
        var folder = Fixtures.MakeTempDirectory("HistqLayouts");
        try
        {
            var path = Path.Join(folder, "team.histqws");
            var repo = Path.Join(folder, "repo");
            var document = new WorkspaceDocument(path);
            document.SetView(new RepoViewState(Hidden: ["refs/heads/x"]), repo);
            document.SetView(new RepoViewState(Hidden: ["refs/heads/y"]), Path.Join(folder, "closed"));

            var file = document.Build([new WorkspaceFile.LiveWindow(WindowId, [new SavedTab(repo)])], homePath: folder);

            var entry = Assert.Single(file.Repos);
            Assert.Equal("repo", entry.Path);
            Assert.Equal(["refs/heads/x"], entry.View?.Hidden);
            Assert.Equal("repo", Assert.Single(Assert.Single(file.Windows).Tabs).Path);

            var copyPath = Path.Join(folder, "sub", "copy.histqws");
            var rebinding = document.Copy().Rebound(copyPath, folder);
            Assert.Equal("team", document.Name);
            document.Rebind(rebinding);
            Assert.Equal("copy", document.Name);
            Assert.Equal(WorkspaceFile.IdentityKey(copyPath), document.Key);
            Assert.Equal("../repo", Assert.Single(Assert.Single(document.Build(
                [new WorkspaceFile.LiveWindow(WindowId, [new SavedTab(repo)])], homePath: folder).Windows).Tabs).Path);
        }
        finally
        {
            Fixtures.RemoveTempDirectory(folder);
        }
    }
}

// Key feature test for the window's tab model: closing the selected tab picks its neighbour; collapsing the selected
// tab's group selects the next shown tab, else the one before, else the popped-out archived tab, else a new Welcome
// tab; only one archived tab is ever popped out; reopening a closed group keeps its id, name and color and selects its
// first tab. RepoGroupKey puts a repo's main checkout and its worktrees under one key from small files (no git), and
// reads nothing under a UNC or device path. The tab mark setters and TabEmoji's last-emoji rule as on the Mac. The Mac
// has no tests of WindowModel at 6fa6d40; these follow its documented behaviour.
namespace Histq.Core.Tests;

public sealed class WindowTabsTests
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
    public void ClosingSelectedTabSelectsNextThenPrevious()
    {
        var model = Open("/r/a", "/r/b", "/r/c");
        model.SelectTab(Id(model, "/r/b"));

        Assert.True(model.CloseTab(Id(model, "/r/b")));
        Assert.Equal("/r/c", SelectedPath(model));

        Assert.True(model.CloseSelectedTab());
        Assert.Equal("/r/a", SelectedPath(model));
    }

    [Fact]
    public void CollapsingSelectedGroupSelectsNextShownTab()
    {
        var model = Open("/r/a", "/r/b", "/r/c", "/r/d");
        var group = model.CreateGroup([Id(model, "/r/b"), Id(model, "/r/c")])!.Value;
        model.SelectTab(Id(model, "/r/b"));

        model.ToggleGroup(group);

        Assert.True(model.IsCollapsed(group));
        Assert.Equal("/r/d", SelectedPath(model));
    }

    [Fact]
    public void CollapsingSelectedGroupSelectsPreviousWhenNoneAfter()
    {
        var model = Open("/r/a", "/r/b", "/r/c");
        var group = model.CreateGroup([Id(model, "/r/b"), Id(model, "/r/c")])!.Value;
        model.SelectTab(Id(model, "/r/c"));

        model.ToggleGroup(group);

        Assert.True(model.IsCollapsed(group));
        Assert.Equal("/r/a", SelectedPath(model));
    }

    [Fact]
    public void CollapsingSelectedGroupSelectsPoppedArchivedTab()
    {
        var model = Open("/r/b", "/r/c", "/r/x");
        model.ArchiveTab(Id(model, "/r/x"));
        var group = model.CreateGroup([Id(model, "/r/b"), Id(model, "/r/c")])!.Value;
        model.OpenArchived(0);
        model.SelectTab(Id(model, "/r/b"));

        model.ToggleGroup(group);

        Assert.True(model.IsCollapsed(group));
        Assert.Equal("/r/x", SelectedPath(model));
        Assert.True(model.Tabs[^1].Archived);
    }

    [Fact]
    public void CollapsingSelectedGroupOpensWelcomeWhenNothingElse()
    {
        var model = Open("/r/b", "/r/c");
        var group = model.CreateGroup([Id(model, "/r/b"), Id(model, "/r/c")])!.Value;
        model.SelectTab(Id(model, "/r/b"));

        model.ToggleGroup(group);

        Assert.True(model.IsCollapsed(group));
        Assert.Equal(3, model.Tabs.Count);
        Assert.Null(SelectedPath(model));
        Assert.Null(model.Tabs.Single(tab => tab.Id == model.SelectedTabId).GroupId);
    }

    [Fact]
    public void OnlyOneArchivedTabIsPoppedOut()
    {
        var model = Open("/r/a", "/r/b", "/r/c");
        model.ArchiveTab(Id(model, "/r/b"));
        model.ArchiveTab(Id(model, "/r/c"));
        Assert.Equal(["/r/c", "/r/b"], model.ArchivedTabs.Select(entry => entry.Path));

        model.OpenArchived(1);
        Assert.Equal("/r/b", model.ArchivedOut?.Path);

        model.OpenArchived(0);
        Assert.Single(model.Tabs, tab => tab.Archived);
        Assert.Equal("/r/c", model.ArchivedOut?.Path);
        Assert.Equal("/r/c", SelectedPath(model));
        Assert.Equal(["/r/a", "/r/c"], model.Tabs.Select(tab => tab.Path));
        Assert.Equal(["/r/b"], model.ArchivedTabs.Select(entry => entry.Path));
        Assert.True(model.ArchivedTabs[0].Archived);
    }

    [Fact]
    public void ReopeningClosedGroupKeepsItAndSelectsItsFirstTab()
    {
        var model = Open("/r/a", "/r/b", "/r/c", "/r/d", "/r/e");
        var work = model.CreateGroup([Id(model, "/r/b"), Id(model, "/r/c")])!.Value;
        model.SetGroupName(work, "Work");
        model.SetGroupColor(work, 3);
        var other = model.CreateGroup([Id(model, "/r/e")])!.Value;
        model.SelectTab(Id(model, "/r/a"));

        model.CloseGroup(work);
        model.CloseGroup(other);

        // The most recently closed group comes first.
        Assert.Equal([other, work], model.ClosedGroups.Select(group => group.Id));
        Assert.Equal(["/r/a", "/r/d"], model.Tabs.Select(tab => tab.Path));
        var closed = model.ClosedGroups[1];
        Assert.Equal(("Work", 3), (closed.Name, closed.Color));
        Assert.Equal(["/r/b", "/r/c"], closed.Tabs.Select(tab => tab.Path));
        Assert.All(closed.Tabs, tab => Assert.Null(tab.TabGroup));

        model.OpenClosedGroup(work);

        Assert.Equal("/r/b", SelectedPath(model));
        Assert.Equal(["/r/a", "/r/d", "/r/b", "/r/c"], model.Tabs.Select(tab => tab.Path));
        var reopened = Assert.Single(model.ManualGroups);
        Assert.Equal(new ManualTabGroup(work, "Work", 3, false), reopened.Group);
        Assert.Equal((2, 3), (reopened.First, reopened.Last));
        Assert.Equal([other], model.ClosedGroups.Select(group => group.Id));
    }

    [Fact]
    public void AliasEmojiAndIconColorSetters()
    {
        var model = Open("/r/a");
        var id = Id(model, "/r/a");
        var icon = CustomIcon.Ref(new string('a', 64) + ".png");

        model.SetAlias("  Main  ", id);
        model.SetEmoji("a😀b🔥", id);
        model.SetIconColor(4, id);
        var tab = model.Tabs.Single();
        Assert.Equal(("Main", "Main", "🔥", 4), (tab.Alias, tab.Title, tab.Emoji, tab.IconColor));

        model.SetAlias("   ", id);
        model.SetEmoji("plain text", id);
        model.SetIconColor(null, id);
        tab = model.Tabs.Single();
        Assert.Equal(((string?)null, "a", (string?)null, (int?)null), (tab.Alias, tab.Title, tab.Emoji, tab.IconColor));

        model.SetEmoji(icon, id);
        Assert.Equal(icon, model.Tabs.Single().Emoji);
        var saved = Assert.Single(model.SavedTabs);
        Assert.Equal((new string('a', 64) + ".png", (string?)null), (saved.Icon, saved.Emoji));
    }

    [Theory]
    [InlineData("a😀b🔥", "🔥")]
    [InlineData("  🙂  ", "🙂")]
    [InlineData("🇫🇷x", "🇫🇷")]
    [InlineData("x👨‍👩‍👧y", "👨‍👩‍👧")]
    [InlineData("I ❤️ it", "❤️")]
    [InlineData("👍🏽", "👍🏽")]
    [InlineData("1", null)]
    [InlineData("plain", null)]
    [InlineData("", null)]
    public void TabEmojiKeepsLastEmoji(string text, string? expected) =>
        Assert.Equal(expected, TabEmoji.Normalized(text));

    // RepoGroupKey.

    [Fact]
    public void RepoGroupKeyJoinsMainCheckoutAndWorktreeFromFiles()
    {
        var root = Fixtures.MakeTempDirectory();
        try
        {
            var main = Path.Combine(root, "main");
            var common = Path.Combine(main, ".git");
            var worktreeDir = Path.Combine(common, "worktrees", "feature");
            Directory.CreateDirectory(worktreeDir);
            File.WriteAllText(Path.Combine(worktreeDir, "commondir"), "../..\n");
            var linked = Path.Combine(root, "feature");
            Directory.CreateDirectory(linked);
            File.WriteAllText(Path.Combine(linked, ".git"), $"gitdir: {worktreeDir}\n");
            var relative = Path.Combine(root, "relative");
            Directory.CreateDirectory(relative);
            File.WriteAllText(Path.Combine(relative, ".git"), "gitdir: ../main/.git/worktrees/feature\n");

            var expected = PathFlavor.Host.Standardized(common);
            Assert.Equal(expected, RepoGroupKey.Of(main));
            Assert.Equal(expected, RepoGroupKey.Of(linked));
            Assert.Equal(expected, RepoGroupKey.Of(relative));
            Assert.Null(RepoGroupKey.Of(Path.Combine(root, "none")));
        }
        finally
        {
            Fixtures.RemoveTempDirectory(root);
        }
    }

    [Fact]
    public async Task RepoGroupKeyJoinsFixtureRepoAndItsWorktree()
    {
        using var copy = await Fixtures.CopyAsync();
        var key = RepoGroupKey.Of(copy.Repo("graph"));
        Assert.NotNull(key);
        Assert.Equal(key, RepoGroupKey.Of(copy.Repo("graph-wt")));
    }

    [Fact]
    public void RepoGroupKeyWithoutCommondirIsTheGitdir() =>
        Assert.Equal(
            @"C:\x\main\.git\worktrees\w",
            RepoGroupKey.Of(@"C:\x\w", PathFlavor.Windows, _ => false, path =>
                path == @"C:\x\w\.git" ? "gitdir: C:/x/main/.git/worktrees/w\r\n" : null));

    [Theory]
    [InlineData(@"\\server\share\repo")]
    [InlineData("//server/share/repo")]
    [InlineData(@"\\?\C:\repo")]
    public void RepoGroupKeyNeverProbesUncFolder(string folder)
    {
        var probed = new List<string>();
        Assert.Null(RepoGroupKey.Of(folder, PathFlavor.Windows, Record(probed, false), Record<string?>(probed, null)));
        Assert.Empty(probed);
    }

    [Theory]
    [InlineData(@"\\server\share\main\.git\worktrees\w")]
    [InlineData("//server/share/main/.git/worktrees/w")]
    [InlineData(@"\\?\C:\main\.git\worktrees\w")]
    [InlineData(@"\\.\pipe\x")]
    public void RepoGroupKeyRefusesUncGitdir(string target)
    {
        var probed = new List<string>();
        var key = RepoGroupKey.Of(@"C:\x\w", PathFlavor.Windows, Record(probed, false), path =>
        {
            probed.Add(path);
            return path == @"C:\x\w\.git" ? $"gitdir: {target}\n" : null;
        });

        Assert.Null(key);
        Assert.Equal([@"C:\x\w\.git", @"C:\x\w\.git"], probed);
    }

    [Theory]
    [InlineData(@"\\server\share\main\.git")]
    [InlineData("//server/share/main/.git")]
    public void RepoGroupKeyRefusesUncCommondir(string common)
    {
        var probed = new List<string>();
        var key = RepoGroupKey.Of(@"C:\x\w", PathFlavor.Windows, Record(probed, false), path =>
        {
            probed.Add(path);
            return path switch
            {
                @"C:\x\w\.git" => "gitdir: C:/x/main/.git/worktrees/w\n",
                @"C:\x\main\.git\worktrees\w\commondir" => common + "\n",
                _ => null,
            };
        });

        Assert.Null(key);
        Assert.DoesNotContain(probed, path => PathFlavor.Windows.IsUncOrDevice(path));
    }

    [Fact]
    public void RepoGroupKeyIgnoresOversizedGitFile()
    {
        var root = Fixtures.MakeTempDirectory();
        try
        {
            File.WriteAllText(
                Path.Combine(root, ".git"),
                "gitdir: " + root + "\n" + new string('x', RepoGroupKey.MaxFileBytes));
            Assert.Null(RepoGroupKey.Of(root));
        }
        finally
        {
            Fixtures.RemoveTempDirectory(root);
        }
    }

    [Fact]
    public void RepoGroupKeyIgnoresGitdirWithNul()
    {
        var root = Fixtures.MakeTempDirectory();
        try
        {
            File.WriteAllText(Path.Combine(root, ".git"), "gitdir: x\0y\n");
            Assert.Null(RepoGroupKey.Of(root));
        }
        finally
        {
            Fixtures.RemoveTempDirectory(root);
        }
    }

    private static Func<string, T> Record<T>(List<string> probed, T result) => path =>
    {
        probed.Add(path);
        return result;
    };
}

// Key feature test for the session store (format contract): a session round trip through session.json and the window
// model keeps the closed groups, the collapsed group and the popped-out archived tab. The same session is the VM's tab
// QA state, Fixtures/qa-session-tab-states.json (windows/README.md, "Cross-platform fixtures"): with
// HISTQ_WRITE_FIXTURES=1 the test writes it with the store's writer first; it always reads it back and checks it against
// the writer, so a stale file fails. Its tab paths are C:/HistqQA/fx/tabs/<name> and every id is fixed (the format has
// no date). Also: the 1 s debounce on a manual clock, the save on quit, the workspace writes, null elements refused,
// the repository checks for received and own paths, workspace layout keys, the .histqws size cap, preferences and
// recent lists.
using System.Text;
using System.Text.Json;

namespace Histq.Core.Tests;

public sealed class SessionStoreTests
{
    private const string TabsRoot = "C:/HistqQA/fx/tabs/";
    private static readonly Guid ScratchGroup = Guid.Parse("5E5510A0-0000-4000-8000-000000000001");
    private static readonly Guid PurpleGroup = Guid.Parse("5E5510A0-0000-4000-8000-000000000002");
    private static readonly Guid DocsGroup = Guid.Parse("5E5510A0-0000-4000-8000-000000000003");
    private static readonly Guid OldGroup = Guid.Parse("5E5510A0-0000-4000-8000-000000000004");

    // Fixture and round trip.

    [Fact]
    public void SessionRoundTripKeepsClosedGroupsCollapseAndPoppedArchivedTab()
    {
        var session = TabStatesSession();
        var path = FixturePath("qa-session-tab-states.json");
        if (string.Equals(Environment.GetEnvironmentVariable("HISTQ_WRITE_FIXTURES"), "1", StringComparison.Ordinal))
        {
            SessionStore.WriteSession(session, path);
        }

        using (var written = JsonDocument.Parse(File.ReadAllBytes(path)))
        using (var built = JsonDocument.Parse(SwiftJson.Serialize(session, SwiftJsonFormatting.PrettyPrinted | SwiftJsonFormatting.SortedKeys)))
        {
            Assert.True(
                JsonElement.DeepEquals(written.RootElement, built.RootElement),
                "Fixtures/qa-session-tab-states.json is stale: regenerate it with HISTQ_WRITE_FIXTURES=1 (windows/README.md).");
        }

        var loaded = SessionStore.Load(path, _ => true);
        Assert.NotNull(loaded);
        Assert.Equal(session, loaded.Session);
        Assert.Empty(loaded.Missing);

        var window = loaded.Session.Windows[0];
        var model = new WindowTabs(PathFlavor.Windows, _ => true);
        var repoKeys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (repo, worktree) in new[] { ("lib", "lib-w2"), ("api", "api-w2"), ("histq", "histq-w3") })
        {
            repoKeys[TabsRoot + repo] = TabsRoot + repo + "/.git";
            repoKeys[TabsRoot + worktree] = TabsRoot + repo + "/.git";
        }

        model.Restore(window.Tabs, window.SelectedTab, loaded.Missing, window.ManualTabGroups, window.ClosedTabGroups, repoKeys);

        Assert.Equal(TabsRoot + "web", model.ArchivedOut?.Path);
        Assert.Equal(model.ArchivedOut?.Id, model.SelectedTabId);
        Assert.True(model.IsCollapsed(PurpleGroup));
        Assert.False(model.IsCollapsed(DocsGroup));
        Assert.Equal(4, model.PinnedCount);
        Assert.Equal("Old", Assert.Single(model.ClosedGroups).Name);
        Assert.Equal(
            [(2, 3), (7, 8), (10, 11)], model.WorktreeBoxes.Select(box => (box.First, box.Last)).ToList());

        var saved = window with
        {
            Tabs = model.SavedTabs,
            SelectedTab = model.SavedSelectedIndex,
            ManualTabGroups = model.SavedTabGroups,
            ClosedTabGroups = model.SavedClosedGroups,
        };
        Assert.Equal(window, saved);
    }

    // Debounce, quit and atomic writes.

    [Fact]
    public async Task SaveRunsOneSecondAfterTheLastChange()
    {
        using var folder = new TempFolder();
        var clock = new ManualClock();
        var store = new SessionStore(folder.Path("session.json"), clock.Delay);
        var session = PlainSession("C:/r/a");
        var captures = 0;
        store.Schedule();
        store.Start(() =>
        {
            captures++;
            return new SessionStore.Snapshot(session, NoWorkspaces);
        });

        store.Schedule();
        clock.Advance(TimeSpan.FromMilliseconds(900));
        store.Schedule();
        clock.Advance(TimeSpan.FromMilliseconds(900));
        await store.Writes;
        Assert.Equal(0, captures);
        Assert.False(File.Exists(store.SessionFile));

        clock.Advance(TimeSpan.FromMilliseconds(100));
        await store.Writes;
        Assert.Equal(1, captures);
        Assert.Equal(session, SessionStore.Load(store.SessionFile, _ => true)?.Session);
        Assert.Equal(new[] { "session.json" }, Directory.GetFiles(folder.Root).Select(file => Path.GetFileName(file)));
    }

    [Fact]
    public void FlushSavesAtOnceAndStopsCapture()
    {
        using var folder = new TempFolder();
        var clock = new ManualClock();
        var store = new SessionStore(folder.Path("session.json"), clock.Delay);
        File.WriteAllText(store.SessionFile, "old");
        var captures = 0;
        store.Start(() =>
        {
            captures++;
            return new SessionStore.Snapshot(PlainSession("C:/r/a"), NoWorkspaces);
        });
        store.Schedule();

        store.Flush();
        Assert.Equal(1, captures);
        Assert.Equal(PlainSession("C:/r/a"), SessionStore.Load(store.SessionFile, _ => true)?.Session);
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(store.SessionFile));
        }

        clock.Advance(TimeSpan.FromSeconds(2));
        store.Schedule();
        clock.Advance(TimeSpan.FromSeconds(2));
        store.Flush();
        Assert.Equal(1, captures);
        Assert.Single(Directory.GetFiles(folder.Root));
    }

    [Fact]
    public async Task WorkspaceWritesSkipUnchangedReadOnlyAndEmptyFiles()
    {
        using var folder = new TempFolder();
        var clock = new ManualClock();
        var store = new SessionStore(folder.Path("session.json"), clock.Delay);
        var results = new List<(string Key, Exception? Error)>();
        store.WriteResult = (key, error) => results.Add((key, error));
        var team = WorkspaceFile.IdentityKey(folder.Path("team.histqws"));
        var shared = WorkspaceFile.IdentityKey(folder.Path("shared.histqws"));
        var empty = WorkspaceFile.IdentityKey(folder.Path("empty.histqws"));
        var model = Workspace("a");
        store.Start(() => new SessionStore.Snapshot(
            PlainSession("C:/r/a"),
            new Dictionary<string, (WorkspaceFile, bool)>
            {
                [team] = (model, false),
                [shared] = (Workspace("b"), true),
                [empty] = (new WorkspaceFile([]), false),
            }));

        await Pass(store, clock);
        Assert.Equal(model, WorkspaceFile.Read(team).File);
        Assert.False(File.Exists(shared));
        Assert.False(File.Exists(empty));
        Assert.True(File.Exists(store.SessionFile));
        var (writtenKey, error) = Assert.Single(results);
        Assert.Equal(team, writtenKey);
        Assert.Null(error);

        File.WriteAllText(team, "edited elsewhere");
        await Pass(store, clock);
        Assert.Equal("edited elsewhere", File.ReadAllText(team));
        Assert.Single(results);
    }

    [Fact]
    public async Task UnchangedWorkspaceAfterFailedWriteReportsSuccess()
    {
        using var folder = new TempFolder();
        var clock = new ManualClock();
        var store = new SessionStore(folder.Path("session.json"), clock.Delay);
        var results = new List<(string Key, Exception? Error)>();
        store.WriteResult = (key, error) => results.Add((key, error));
        var key = folder.Path("gone/team.histqws");
        var current = Workspace("a");
        store.Start(() => new SessionStore.Snapshot(
            PlainSession("C:/r/a"), new Dictionary<string, (WorkspaceFile, bool)> { [key] = (current, false) }));
        store.Seed(key, Workspace("a"));

        current = Workspace("b");
        await Pass(store, clock);
        Assert.NotNull(Assert.Single(results).Error);

        current = Workspace("a");
        await Pass(store, clock);
        Assert.Equal(2, results.Count);
        Assert.Null(results[1].Error);
        Assert.False(File.Exists(key));
    }

    [Fact]
    public async Task WriteNowCachesAndFinishWritesLastTime()
    {
        using var folder = new TempFolder();
        var clock = new ManualClock();
        var store = new SessionStore(folder.Path("session.json"), clock.Delay);
        var path = folder.Path("team.histqws");
        var key = WorkspaceFile.IdentityKey(path);
        Assert.ThrowsAny<IOException>(() => store.WriteNow(Workspace("a"), folder.Path("gone/x.histqws")));

        store.WriteNow(Workspace("a"), path);
        var current = Workspace("a");
        store.Start(() => new SessionStore.Snapshot(
            PlainSession("C:/r/a"), new Dictionary<string, (WorkspaceFile, bool)> { [key] = (current, false) }));
        File.WriteAllText(path, "untouched");
        await Pass(store, clock);
        Assert.Equal("untouched", File.ReadAllText(path));

        current = Workspace("b");
        store.Finish(key);
        await store.Writes;
        Assert.Equal(current, WorkspaceFile.Read(path).File);

        current = Workspace("c");
        await Pass(store, clock);
        Assert.Equal(Workspace("b"), WorkspaceFile.Read(path).File);
    }

    [Fact]
    public async Task WriteNowAsyncWritesOnTheChainCachesAndReopensAFinishedKey()
    {
        using var folder = new TempFolder();
        var clock = new ManualClock();
        var store = new SessionStore(folder.Path("session.json"), clock.Delay);
        var path = folder.Path("team.histqws");
        await Assert.ThrowsAnyAsync<IOException>(() => store.WriteNowAsync(Workspace("a"), folder.Path("gone/x.histqws")));

        var current = Workspace("a");
        string? captured = null;
        store.Start(() => new SessionStore.Snapshot(
            PlainSession("C:/r/a"),
            captured is null
                ? NoWorkspaces
                : new Dictionary<string, (WorkspaceFile, bool)> { [captured] = (current, false) }));
        var key = await store.WriteNowAsync(Workspace("a"), path);
        Assert.Equal(WorkspaceFile.IdentityKey(path), key);
        Assert.Equal(Workspace("a"), WorkspaceFile.Read(path).File);

        // Cached: the first capture of the same model does not write it again.
        captured = key;
        File.WriteAllText(path, "untouched");
        await Pass(store, clock);
        Assert.Equal("untouched", File.ReadAllText(path));

        // Finished, then written again (Save As back onto it): later passes write it.
        store.Finish(key);
        await store.Writes;
        await store.WriteNowAsync(Workspace("b"), path);
        current = Workspace("c");
        await Pass(store, clock);
        Assert.Equal(Workspace("c"), WorkspaceFile.Read(path).File);
    }

    // Reading session.json.

    [Theory]
    [InlineData("""{"version":1,"windows":[null]}""")]
    [InlineData("""{"version":1,"windows":[{WINDOW,"tabs":[null]}]}""")]
    [InlineData("""{"version":1,"windows":[{WINDOW,"tabs":[{}],"manualTabGroups":[null]}]}""")]
    [InlineData("""{"version":1,"windows":[{WINDOW,"tabs":[{}],"closedTabGroups":[null]}]}""")]
    [InlineData("""{"version":1,"windows":[{WINDOW,"tabs":[{}],"closedTabGroups":[{"id":"5E5510A0-0000-4000-8000-000000000004","color":0,"tabs":[null]}]}]}""")]
    [InlineData("""{"version":1,"windows":[],"workspaces":[null]}""")]
    [InlineData("""{"version":1,"windows":[],"workspaces":[{"path":"C:/w.histqws","open":true,"windows":[null]}]}""")]
    public void NullElementsAreRefused(string json)
    {
        var data = Encoding.UTF8.GetBytes(json.Replace(
            "WINDOW", "\"x\":0,\"y\":0,\"width\":800,\"height\":600,\"group\":0,\"tabIndex\":0,\"isSelectedInGroup\":true",
            StringComparison.Ordinal));
        Assert.Throws<JsonException>(() => SavedSession.Decode(data));

        using var folder = new TempFolder();
        File.WriteAllBytes(folder.Path("session.json"), data);
        Assert.Null(SessionStore.Load(folder.Path("session.json"), _ => true));
    }

    [Fact]
    public void LoadIgnoresOtherVersionsAndEmptySessionsAndMarksMissingTabs()
    {
        using var folder = new TempFolder();
        var file = folder.Path("session.json");
        Assert.Null(SessionStore.Load(file, _ => true));

        SessionStore.WriteSession(PlainSession("C:/r/a") with { Version = 2 }, file);
        Assert.Null(SessionStore.Load(file, _ => true));

        SessionStore.WriteSession(new SavedSession([]), file);
        Assert.Null(SessionStore.Load(file, _ => true));

        SessionStore.WriteSession(PlainSession("C:/r/here", "C:/r/gone"), file);
        var loaded = SessionStore.Load(file, path => path.EndsWith("here", StringComparison.Ordinal));
        Assert.Equal(["C:/r/gone"], loaded?.Missing);
    }

    // Repository checks: a received file's paths never reach a share; the user's own paths do.

    [Theory]
    [InlineData(@"\\wsl.localhost\Ubuntu\home\me\repo")]
    [InlineData(@"\\server\home$\me\repo")]
    public void OwnUncPathIsProbedButReceivedOneIsNot(string path)
    {
        var probed = new List<string>();
        bool Probe(string probe)
        {
            probed.Add(probe);
            return true;
        }

        Assert.False(SavedSession.IsRepository(path, PathFlavor.Windows, Probe, Probe));
        Assert.Empty(probed);

        Assert.True(SavedSession.IsRepository(path, PathFlavor.Windows, Probe, Probe, allowUncOrDevice: true));
        Assert.Contains(path, probed);
    }

    [Theory]
    [InlineData(@"\a\b")]
    [InlineData("/a/b")]
    [InlineData(@"C:a\b")]
    [InlineData("repo")]
    public void RelativePathIsNeverARepositoryAndNeverProbed(string path)
    {
        var probed = new List<string>();
        bool Probe(string probe)
        {
            probed.Add(probe);
            return true;
        }

        Assert.False(SavedSession.IsRepository(path, PathFlavor.Windows, Probe, Probe));
        Assert.False(SavedSession.IsRepository(path, PathFlavor.Windows, Probe, Probe, allowUncOrDevice: true));
        Assert.Empty(probed);
    }

    // Workspace layout keys.

    [Fact]
    public void LayoutsOfOneFileInAnotherCaseAreOneOnWindows()
    {
        var session = new SavedSession(
            [],
            [
                new WorkspaceLayout(@"C:\Work\Team.histqws", true, []),
                new WorkspaceLayout(@"c:\work\TEAM.histqws", false, []),
            ]);

        Assert.Equal(@"C:\Work\Team.histqws", Assert.Single(session.Normalized(PathFlavor.Windows).Workspaces!).Path);
        Assert.Equal(2, session.Normalized(PathFlavor.Posix).Workspaces!.Count);

        var layout = new WorkspaceLayout(@"C:\Work\Team.histqws", true, []);
        Assert.Equal(OperatingSystem.IsWindows(), layout.Equals(layout with { Path = @"c:\work\TEAM.histqws" }));
        Assert.Equal(layout, layout with { });
    }

    // Workspace documents.

    [Fact]
    public void WorkspaceReadStopsPastTheCapWhateverTheStreamLength()
    {
        Assert.Throws<WorkspaceTooLargeException>(() => WorkspaceDocument.ReadCapped(new EndlessStream()));
        using var small = new MemoryStream([1, 2, 3]);
        Assert.Equal([1, 2, 3], WorkspaceDocument.ReadCapped(small));

        using var folder = new TempFolder();
        var path = folder.Path("big.histqws");
        File.WriteAllBytes(path, new byte[WorkspaceDocument.MaxFileSize + 1]);
        Assert.Throws<WorkspaceTooLargeException>(() => WorkspaceDocument.Open(path, folder.Root, _ => true));
    }

    [Fact]
    public void OpenedWorkspaceIsReadOnlyWithUnknownKeysAndNeverEmpty()
    {
        using var folder = new TempFolder();
        var repo = folder.Path("repo");
        Directory.CreateDirectory(Path.Join(repo, ".git"));
        var path = folder.Path("team.histqws");
        Workspace("repo").Write(path);

        var opened = WorkspaceDocument.Open(path, folder.Root, _ => true);
        Assert.False(opened.Document.IsReadOnly);
        Assert.Equal("team", opened.Document.Name);
        Assert.Empty(opened.Document.Missing);
        Assert.Equal(PathFlavor.Host.Standardized(repo), Assert.Single(Assert.Single(opened.Resolved.Windows).Tabs).Path);

        var json = File.ReadAllText(path).Replace("\"version\"", "\"future\": 1, \"version\"", StringComparison.Ordinal);
        File.WriteAllText(path, json);
        var future = WorkspaceDocument.Open(path, folder.Root, _ => true).Document;
        Assert.True(future.IsReadOnly);
        future.RecordWrite(new IOException("disk full"));
        Assert.True(future.WriteFailed);
        future.Rebind(folder.Path("copy.histqws"), folder.Root);
        Assert.False(future.IsReadOnly);
        Assert.False(future.WriteFailed);
        Assert.Null(future.WriteError);
        Assert.Equal("copy", future.Name);

        File.WriteAllText(path, """{"version":1,"windows":[{"id":"5E5510A0-0000-4000-8000-000000000009","tabs":[]}],"repos":[],"profiles":[]}""");
        var empty = WorkspaceDocument.Open(path, folder.Root, _ => true);
        Assert.Null(Assert.Single(Assert.Single(empty.Resolved.Windows).Tabs).Path);
    }

    // Preferences and recent lists.

    [Fact]
    public void PreferencesUseMacNamesAndDefaults()
    {
        using var folder = new TempFolder();
        var file = folder.Path("preferences.json");
        var preferences = Preferences.Load(file);
        Assert.False(File.Exists(file));
        Assert.Equal("regular", preferences.Get<string>(PrefKey.RowDensity));
        Assert.Equal(3, preferences.Get<int>(PrefKey.AutoFetchMinutes));
        Assert.Equal(0.45, preferences.Get<double>(PrefKey.StackedSplit));
        Assert.Equal(-1, preferences.Get<int>(PrefKey.DefaultTabIconColor));
        Assert.True(preferences.Get<bool>(PrefKey.CardBorders));
        Assert.Empty(preferences.Get<string[]>(PrefKey.RecentRepos));
        Assert.Empty(preferences.Get<Dictionary<string, string[]>>(PrefKey.HiddenRefs));
        Assert.Equal("defaultProfileID", PrefKey.DefaultProfileID.Name);
        Assert.Equal("aiCustomBaseURL", PrefKey.AiCustomBaseURL.Name);
        Assert.All(Enum.GetValues<PrefKey>(), key => Assert.NotNull(key.Default));

        preferences.Set(PrefKey.RowDensity, "compact");
        File.WriteAllText(file, File.ReadAllText(file).Replace("{", """{ "laterKey": 7, "textSize": 3,""", StringComparison.Ordinal));
        var reread = Preferences.Load(file);
        Assert.Equal("compact", reread.Get<string>(PrefKey.RowDensity));
        Assert.Equal("regular", reread.Get<string>(PrefKey.TextSize));
        reread.Set(PrefKey.OnboardingDone, true);
        using var document = JsonDocument.Parse(File.ReadAllBytes(file));
        Assert.Equal(7, document.RootElement.GetProperty("laterKey").GetInt32());
        Assert.True(document.RootElement.GetProperty("onboardingDone").GetBoolean());
    }

    [Fact]
    public void ToastLevelOffBecomesErrors()
    {
        using var folder = new TempFolder();
        var file = folder.Path("preferences.json");
        File.WriteAllText(file, """{"toastLevel":"off"}""");
        Assert.Equal("errors", Preferences.Load(file).Get<string>(PrefKey.ToastLevel));
        Assert.Equal("errors", Preferences.Load(file).Get<string>(PrefKey.ToastLevel));
        Assert.Equal("all", Preferences.Load(folder.Path("none.json")).Get<string>(PrefKey.ToastLevel));
    }

    [Fact]
    public void PreferencesWithUtf8BomAreRead()
    {
        using var folder = new TempFolder();
        var file = folder.Path("preferences.json");
        File.WriteAllBytes(file, [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("""{"avatarMode":"initials"}""")]);
        Assert.Equal("initials", Preferences.Load(file).Get<string>(PrefKey.AvatarMode));
    }

    [Fact]
    public void InvalidPreferencesAreMovedAsideWithoutLosingAnEarlierBackup()
    {
        using var folder = new TempFolder();
        var file = folder.Path("preferences.json");
        byte[] first = Encoding.UTF8.GetBytes("""{"avatarMode":"initials",""");
        File.WriteAllBytes(file, first);
        Assert.Equal("generated", Preferences.Load(file).Get<string>(PrefKey.AvatarMode));
        Assert.False(File.Exists(file));
        Assert.Equal(first, File.ReadAllBytes(file + ".bak"));

        byte[] second = Encoding.UTF8.GetBytes("not json");
        File.WriteAllBytes(file, second);
        Assert.Equal("generated", Preferences.Load(file).Get<string>(PrefKey.AvatarMode));
        Assert.Equal(first, File.ReadAllBytes(file + ".bak"));
        string other = Assert.Single(Directory.GetFiles(Path.GetDirectoryName(file)!), path =>
            Path.GetFileName(path) is var name && name != "preferences.json.bak"
            && name.StartsWith("preferences.json.", StringComparison.Ordinal) && name.EndsWith(".bak", StringComparison.Ordinal));
        Assert.Equal(second, File.ReadAllBytes(other));
    }

    [Fact]
    public void RecentListKeepsTenMostRecentFirstWithoutTouchingTheDisk()
    {
        using var folder = new TempFolder();
        var preferences = Preferences.Load(folder.Path("preferences.json"));
        var recent = new RecentRepos(preferences, PrefKey.RecentRepos, PathFlavor.Windows);
        for (var i = 0; i < 12; i++)
        {
            recent.Add($"C:/r/{i}");
        }

        Assert.Equal(RecentRepos.Limit, recent.Paths.Count);
        Assert.Equal(@"C:\r\11", recent.Paths[0]);
        Assert.Equal(@"C:\r\2", recent.Paths[^1]);

        recent.Add("c:/R/5");
        Assert.Equal(@"C:\R\5", recent.Paths[0]);
        Assert.Equal(RecentRepos.Limit, recent.Paths.Count);
        Assert.Single(recent.Paths, path => PathFlavor.Windows.KeysEqual(path, @"C:\r\5"));

        // A share is listed as given; nothing here probes it.
        recent.Add(@"\\wsl.localhost\Ubuntu\home\me\repo");
        recent.Remove(@"C:\r\11");
        var reread = new RecentRepos(Preferences.Load(folder.Path("preferences.json")), PrefKey.RecentRepos, PathFlavor.Windows);
        Assert.Equal(@"\\wsl.localhost\Ubuntu\home\me\repo", reread.Paths[0]);
        Assert.DoesNotContain(@"C:\r\11", reread.Paths);
        Assert.Empty(new RecentRepos(preferences, PrefKey.RecentWorkspaces).Paths);

        reread.Clear();
        Assert.Empty(new RecentRepos(Preferences.Load(folder.Path("preferences.json")), PrefKey.RecentRepos).Paths);
    }

    // Helpers.

    private static readonly IReadOnlyDictionary<string, (WorkspaceFile File, bool IsReadOnly)> NoWorkspaces =
        new Dictionary<string, (WorkspaceFile, bool)>();

    /// <summary>The VM's tab QA state: one window with every tab state of the tab row.</summary>
    private static SavedSession TabStatesSession()
    {
        static SavedTab Tab(string name, bool pinned = false, Guid? group = null, bool archived = false) =>
            new(TabsRoot + name, Pinned: pinned ? true : null, Archived: archived ? true : null, TabGroup: group);

        List<SavedTab> tabs =
        [
            Tab("docs", pinned: true),
            Tab("notes", pinned: true),
            Tab("lib", pinned: true),
            Tab("lib-w2", pinned: true),
            Tab("scratch", group: ScratchGroup),
            Tab("tmp1", group: PurpleGroup),
            Tab("tmp2", group: PurpleGroup),
            Tab("api", group: DocsGroup),
            Tab("api-w2", group: DocsGroup),
            Tab("readme", group: DocsGroup),
            Tab("histq"),
            Tab("histq-w3"),
            .. Enumerable.Range(1, 6).Select(i => Tab($"t{i}")),
            Tab("web", archived: true),
        ];
        return new SavedSession(
        [
            new SavedWindow(
                X: 120, Y: 80, Width: 1100, Height: 700, Group: 0, TabIndex: 0, IsSelectedInGroup: true, Tabs: tabs,
                SelectedTab: tabs.Count - 1,
                ManualTabGroups:
                [
                    new SavedTabGroup(ScratchGroup, Color: 0, Name: "Scratch"),
                    new SavedTabGroup(PurpleGroup, Color: 7, Collapsed: true),
                    new SavedTabGroup(DocsGroup, Color: 1, Name: "Docs"),
                ],
                ClosedTabGroups: [new SavedClosedTabGroup(OldGroup, Color: 2, Tabs: [new SavedTab(TabsRoot + "old")], Name: "Old")]),
        ]);
    }

    private static SavedSession PlainSession(params string[] paths) =>
        new([new SavedWindow(0, 0, 800, 600, 0, 0, true, [.. paths.Select(path => new SavedTab(path))], SelectedTab: 0)]);

    private static WorkspaceFile Workspace(string tab) =>
        new([new WorkspaceFile.Window(Guid.Parse("5E5510A0-0000-4000-8000-000000000010"), [new WorkspaceFile.Tab(tab)])]);

    /// <summary>One debounced pass: a change, a second on the clock, then the queued writes.</summary>
    private static Task Pass(SessionStore store, ManualClock clock)
    {
        store.Schedule();
        clock.Advance(SessionStore.Debounce);
        return store.Writes;
    }

    /// <summary>A file in this project's Fixtures folder in the source tree (never bin/): found above the test assembly.</summary>
    private static string FixturePath(string name)
    {
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            if (File.Exists(Path.Combine(folder.FullName, "Histq.Core.Tests.csproj")))
            {
                return Path.Combine(folder.FullName, "Fixtures", name);
            }
        }

        throw new FileNotFoundException($"No Histq.Core.Tests.csproj above {AppContext.BaseDirectory}.");
    }

    /// <summary>Delays that run when the test moves the clock, never on their own.</summary>
    private sealed class ManualClock
    {
        private readonly List<(TimeSpan Due, Action Action, Handle Handle)> delays = [];
        private TimeSpan now;

        public IDisposable Delay(TimeSpan due, Action action)
        {
            var handle = new Handle();
            delays.Add((now + due, action, handle));
            return handle;
        }

        public void Advance(TimeSpan by)
        {
            now += by;
            foreach (var delay in delays.Where(delay => delay.Due <= now).ToList())
            {
                delays.Remove(delay);
                if (!delay.Handle.Disposed)
                {
                    delay.Action();
                }
            }
        }

        private sealed class Handle : IDisposable
        {
            public bool Disposed { get; private set; }

            public void Dispose() => Disposed = true;
        }
    }

    /// <summary>A stream of zeros that never ends and has no length, as a device or a pipe.</summary>
    private sealed class EndlessStream : Stream
    {
        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            Array.Clear(buffer, offset, count);
            return count;
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class TempFolder : IDisposable
    {
        public string Root { get; } = Fixtures.MakeTempDirectory("HistqSessionStore");

        public string Path(string relative) => System.IO.Path.Join(Root, relative);

        public void Dispose() => Fixtures.RemoveTempDirectory(Root);
    }
}

// Key-feature tests for workspace files, in a temp folder with fake repos (a folder with a `.git` folder) and a fake
// home inside it: the version-1 contract, session.json after the move, how stored `path` / `home` strings resolve and
// come back unchanged (an uploaded tab icon too), lossless reads, the writer's empty refusal, a write and paths through
// a symlink, Save As to another folder and the file's identity key. Ported from WorkspaceFileTests.swift at 6fa6d40;
// the symlink tests run off Windows only (creating a symlink there needs a privilege). Added for Windows: a UNC or
// device `path` / `home` counts as missing without any file-system call, keys compare case-insensitively and fresh
// strings are written with '/', and ids are written upper case.
using System.Text;
using System.Text.Json;

namespace Histq.Core.Tests;

public sealed class WorkspaceFileTests
{
    private const string SymlinkSkip = "Creating a symlink on Windows needs a privilege the test runner does not have.";

    private static readonly Guid GroupID = Guid.Parse("6A0B5C1E-2D3F-4A5B-8C7D-9E0F1A2B3C4D");
    private static readonly Guid WindowA = Guid.Parse("0D2A6B7C-1111-4222-8333-444455556666");
    private static readonly Guid WindowB = Guid.Parse("0D2A6B7C-7777-4888-9999-AAAABBBBCCCC");

    // Not in id order, so a fallback sort by id would change the file's order.
    private static readonly Profile Work = new(
        "Work", "#3A8EE5", new ProfileIdentity("Me", "me@work.invalid"), id: Guid.Parse("EEEEEEEE-0000-4000-8000-000000000001"));

    private static readonly Profile Personal = new(
        "Personal", "#E5B13A", new ProfileIdentity("Me", "me@histq.invalid"), ssh: new ProfileSshKey.KeyFile("~/.ssh/id_personal"),
        id: Guid.Parse("11111111-0000-4000-8000-000000000002"));

    public enum Move
    {
        /// <summary>The repos moved together with the file: <c>path</c> resolves, <c>home</c> does not.</summary>
        Together,

        /// <summary>The file moved alone: <c>path</c> does not resolve, <c>home</c> does.</summary>
        FileAlone,

        /// <summary>Neither resolves: every tab is missing and every <c>repos[]</c> entry is carried.</summary>
        Neither,
    }

    private static string Id(Guid id) => id.ToString("D").ToUpperInvariant();

    private static string Json(Profile profile) => Encoding.UTF8.GetString(SwiftJson.Serialize(profile, SwiftJsonFormatting.None));

    /// <summary>A version-1 file in the writer's form (no null, every repo with a full view): two windows, a named tab
    /// group, a Welcome tab, two repos (lib before app, not sorted by path) and two profiles (not sorted by id).</summary>
    private static string TeamFile() => $$"""
        {
          "version": 1,
          "windows": [
            { "id": "{{Id(WindowA)}}",
              "tabGroups": [ { "id": "{{Id(GroupID)}}", "name": "Release", "color": 3 } ],
              "tabs": [
                { "path": "../repos/app", "home": "~/git/repos/app", "profile": "{{Id(Work.Id)}}",
                  "alias": "App", "pinned": true, "iconColor": 2 },
                { "path": "../repos/lib", "home": "~/git/repos/lib", "profile": "none", "emoji": "📦",
                  "group": "{{Id(GroupID)}}" },
                { "path": "../repos/app", "home": "~/git/repos/app", "group": "{{Id(GroupID)}}" },
                {}
              ] },
            { "id": "{{Id(WindowB)}}",
              "tabs": [ { "path": "../repos/lib", "home": "~/git/repos/lib", "profile": "{{Id(Personal.Id)}}",
                          "archived": true } ] }
          ],
          "repos": [
            { "path": "../repos/lib", "home": "~/git/repos/lib",
              "view": { "hidden": ["refs/heads/old"], "solo": [], "pinned": ["refs/heads/main"], "hideStale": true } },
            { "path": "../repos/app", "home": "~/git/repos/app",
              "view": { "hidden": [], "solo": ["refs/heads/dev"], "pinned": [], "hideStale": false } }
          ],
          "profiles": [ {{Json(Work)}}, {{Json(Personal)}} ]
        }
        """;

    private static JsonElement Parse(string json) => JsonDocument.Parse(json).RootElement;

    private static JsonElement Parse(byte[] json) => JsonDocument.Parse(json).RootElement;

    // Contract.

    // A literal version-1 workspace decodes; a version-2 one is refused.
    [Fact]
    public void VersionOneDecodesVersionTwoIsRefused()
    {
        using var sandbox = new Sandbox();
        var file = sandbox.WriteFile("ws/team.histqws", TeamFile());
        var read = WorkspaceFile.Read(file);
        Assert.True(read.IsLossless);
        Assert.Equal(1, read.File.Version);
        Assert.Equal([WindowA, WindowB], read.File.Windows.Select(window => window.Id));
        Assert.Equal([new WorkspaceFile.TabGroup(GroupID, 3, "Release")], read.File.Windows[0].TabGroups!);
        Assert.Null(read.File.Windows[1].TabGroups);
        Assert.Equal(
            new WorkspaceFile.Tab("../repos/app", "~/git/repos/app", new SavedProfile(Work.Id), "App", Pinned: true, IconColor: 2),
            read.File.Windows[0].Tabs[0]);
        Assert.Equal(GroupID, read.File.Windows[0].Tabs[1].Group);
        Assert.Equal(SavedProfile.None, read.File.Windows[0].Tabs[1].Profile);
        Assert.Equal(new WorkspaceFile.Tab(), read.File.Windows[0].Tabs[3]);
        Assert.Equal(["../repos/lib", "../repos/app"], read.File.Repos.Select(repo => repo.Path));
        Assert.Equal([Work, Personal], read.File.Profiles);

        // A profile written by hand, as in profiles.json.
        var signed = sandbox.WriteFile("ws/signed.histqws", $$"""
            { "version": 1, "windows": [ { "id": "{{Id(WindowA)}}", "tabs": [ {} ] } ], "repos": [],
              "profiles": [ { "id": "{{Id(Work.Id)}}", "name": "Work", "color": "#3A8EE5",
                              "identity": { "name": "Me", "email": "me@work.invalid" },
                              "signing": { "gpg": { "keyID": "ABCD1234" } }, "signByDefault": true,
                              "ssh": { "keyFile": { "path": "~/.ssh/id_work" } },
                              "github": { "host": "github.com", "login": "me" } } ] }
            """);
        var work = new Profile(
            "Work", "#3A8EE5", new ProfileIdentity("Me", "me@work.invalid"), new ProfileSigning.Gpg("ABCD1234"),
            signByDefault: true, ssh: new ProfileSshKey.KeyFile("~/.ssh/id_work"), id: Work.Id)
            .WithAccount(new HostingAccount(HostingKind.GitHub, "github.com", "me"));
        Assert.Equal([work], WorkspaceFile.Read(signed).File.Profiles);

        var newer = sandbox.WriteFile("ws/newer.histqws", """{ "version": 2, "windows": [], "tiles": [] }""");
        var error = Assert.Throws<WorkspaceFileError>(() => WorkspaceFile.Read(newer));
        Assert.Equal(WorkspaceFileError.UnsupportedVersion(2), error);
    }

    // A version-1 session.json of an older build decodes and re-encodes as it was, its tab group included.
    [Fact]
    public void OlderSessionRoundTrips()
    {
        const string group = "C3D4E5F6-0000-4000-8000-0000000000AA";
        const string literal = $$"""
            {
              "version": 1,
              "windows": [ {
                "x": 120, "y": 80.5, "width": 1280, "height": 800, "group": 0, "tabIndex": 0, "isSelectedInGroup": true,
                "selectedTab": 1,
                "manualTabGroups": [ { "id": "{{group}}", "name": "Review", "color": 5, "collapsed": true } ],
                "tabs": [
                  { "path": "/Users/someone/git/app", "profile": "none", "pinned": true },
                  { "path": "/Users/someone/git/lib", "tabGroup": "{{group}}", "alias": "Lib" },
                  {}
                ]
              } ]
            }
            """;
        var session = SwiftJson.Deserialize<SavedSession>(Encoding.UTF8.GetBytes(literal));
        Assert.Null(session.Workspaces);
        Assert.Equal([new SavedTabGroup(Guid.Parse(group), 5, "Review", Collapsed: true)], session.Windows[0].ManualTabGroups!);
        Assert.Equal(Guid.Parse(group), session.Windows[0].Tabs[1].TabGroup);

        var encoded = Parse(SwiftJson.Serialize(session, SwiftJsonFormatting.None));
        Assert.False(encoded.TryGetProperty("workspaces", out _));
        Assert.True(JsonElement.DeepEquals(Parse(literal), encoded));
    }

    // Ids are written upper case, as Swift's uuidString, and read in either case (a tab's profile too).
    [Fact]
    public void IdsAreWrittenUpperCaseAndReadInEitherCase()
    {
        var lower = $$"""
            { "version": 1, "repos": [], "profiles": [],
              "windows": [ { "id": "{{Id(WindowA).ToLowerInvariant()}}",
                "tabs": [ { "profile": "{{Id(Work.Id).ToLowerInvariant()}}", "group": "{{Id(GroupID).ToLowerInvariant()}}" } ] } ] }
            """;
        var read = WorkspaceFile.Decode(Encoding.UTF8.GetBytes(lower));
        Assert.True(read.IsLossless);
        Assert.Equal(WindowA, read.File.Windows[0].Id);
        Assert.Equal(new SavedProfile(Work.Id), read.File.Windows[0].Tabs[0].Profile);

        var text = Encoding.UTF8.GetString(SwiftJson.Serialize(read.File, SwiftJsonFormatting.None));
        foreach (var id in new[] { WindowA, Work.Id, GroupID })
        {
            Assert.Contains($"\"{Id(id)}\"", text, StringComparison.Ordinal);
            Assert.DoesNotContain(Id(id).ToLowerInvariant(), text, StringComparison.Ordinal);
        }
    }

    // Resolving.

    // Stored path / home resolve to standardized keys and come back unchanged on the next save.
    [Theory]
    [InlineData(Move.Together)]
    [InlineData(Move.FileAlone)]
    [InlineData(Move.Neither)]
    public void RoundTripKeepsStoredStrings(Move move)
    {
        using var sandbox = new Sandbox();
        string fileURL;
        Dictionary<string, string> expected; // repo name -> resolved (or missing) key
        switch (move)
        {
            case Move.Together:
                fileURL = sandbox.WriteFile("moved/ws/team.histqws", TeamFile());
                sandbox.MakeRepo("moved/repos/app");
                sandbox.MakeRepo("moved/repos/lib");
                expected = new() { ["app"] = sandbox.Key("moved/repos/app"), ["lib"] = sandbox.Key("moved/repos/lib") };
                break;
            case Move.FileAlone:
                fileURL = sandbox.WriteFile("elsewhere/ws/team.histqws", TeamFile());
                sandbox.MakeRepo("home/git/repos/app");
                sandbox.MakeRepo("home/git/repos/lib");
                expected = new() { ["app"] = sandbox.Key("home/git/repos/app"), ["lib"] = sandbox.Key("home/git/repos/lib") };
                break;
            default:
                fileURL = sandbox.WriteFile("lonely/ws/team.histqws", TeamFile());
                expected = new() { ["app"] = sandbox.Key("home/git/repos/app"), ["lib"] = sandbox.Key("home/git/repos/lib") };
                break;
        }

        var read = WorkspaceFile.Read(fileURL);
        var resolved = read.File.Resolve(fileURL, sandbox.Home, SavedSession.IsRepository);

        var tabPaths = resolved.Windows.SelectMany(window => window.Tabs).Select(tab => tab.Path).ToList();
        Assert.Equal([expected["app"], expected["lib"], expected["app"], null, expected["lib"]], tabPaths);
        Assert.Equal([expected["lib"], expected["app"]], resolved.RepoOrder);
        Assert.Equal([Work.Id, Personal.Id], resolved.ProfileOrder);
        if (move == Move.Neither)
        {
            Assert.True(resolved.Missing.SetEquals(expected.Values));
            Assert.Empty(resolved.Views);
            Assert.True(resolved.Carried.Keys.ToHashSet().SetEquals(expected.Values));
        }
        else
        {
            Assert.Empty(resolved.Missing);
            Assert.Empty(resolved.Carried);
            Assert.True(resolved.Views[expected["lib"]].HideStale);
        }

        var keys = tabPaths.OfType<string>().Concat(resolved.Missing).Concat(resolved.Originals.Keys)
            .Concat(resolved.Views.Keys).Concat(resolved.Carried.Keys).Concat(resolved.RepoOrder);
        foreach (var key in keys)
        {
            Assert.Equal(PathFlavor.Host.Standardized(key), key);
            Assert.DoesNotContain("..", key, StringComparison.Ordinal);
        }

        var rebuilt = WorkspaceFile.Build(
            resolved.Windows, resolved.Views, [Personal, Work], resolved.Carried, resolved.Originals, resolved.RepoOrder,
            resolved.ProfileOrder, fileURL, sandbox.Home);
        Assert.Equal(read.File, rebuilt);
        Assert.True(JsonElement.DeepEquals(Parse(TeamFile()), Parse(SwiftJson.Serialize(rebuilt, SwiftJsonFormatting.None))));

        // An uploaded image on the emoji tab: written as `icon` without `emoji`, read back as the same mark.
        var iconName = string.Concat(Enumerable.Repeat("0123456789abcdef", 4)) + ".png";
        var reference = CustomIcon.Ref(iconName);
        var windows = resolved.Windows.ToList();
        var tabs = windows[0].Tabs.ToList();
        tabs[1] = tabs[1].WithMark(reference);
        windows[0] = windows[0] with { Tabs = tabs };
        var withIcon = WorkspaceFile.Build(
            windows, resolved.Views, [Personal, Work], resolved.Carried, resolved.Originals, resolved.RepoOrder,
            resolved.ProfileOrder, fileURL, sandbox.Home);
        withIcon.Write(fileURL);
        var written = Parse(File.ReadAllBytes(fileURL)).GetProperty("windows")[0].GetProperty("tabs")[1];
        Assert.Equal(iconName, written.GetProperty("icon").GetString());
        Assert.False(written.TryGetProperty("emoji", out _));
        var reread = WorkspaceFile.Read(fileURL);
        Assert.True(reread.IsLossless);
        var back = reread.File.Resolve(fileURL, sandbox.Home, SavedSession.IsRepository);
        Assert.Equal(reference, back.Windows[0].Tabs[1].Mark);
    }

    // A closed group's tabs resolve like open tabs and the file reads lossless and comes back unchanged.
    [Fact]
    public void ClosedGroupRoundTrips()
    {
        using var sandbox = new Sandbox();
        sandbox.MakeRepo("ws/repos/app");
        var fileURL = sandbox.WriteFile("ws/team.histqws", $$"""
            { "version": 1, "repos": [], "profiles": [],
              "windows": [ { "id": "{{Id(WindowA)}}", "tabs": [ {} ],
                "closedTabGroups": [ { "id": "{{Id(GroupID)}}", "name": "Later", "color": 2,
                  "tabs": [ { "path": "repos/app", "home": "~/git/app", "emoji": "🧪" },
                            { "path": "repos/gone", "home": "~/git/gone" } ] } ] } ] }
            """);

        var read = WorkspaceFile.Read(fileURL);
        Assert.True(read.IsLossless);
        var resolved = read.File.Resolve(fileURL, sandbox.Home, SavedSession.IsRepository);
        var closed = resolved.Windows[0].ClosedTabGroups![0];
        Assert.Equal((GroupID, "Later", 2), (closed.Id, closed.Name, closed.Color));
        Assert.Equal([sandbox.Key("ws/repos/app"), sandbox.Key("home/git/gone")], closed.Tabs.Select(tab => tab.Path));
        Assert.Equal("🧪", closed.Tabs[0].Emoji);

        var rebuilt = WorkspaceFile.Build(
            resolved.Windows, resolved.Views, [], resolved.Carried, resolved.Originals, resolved.RepoOrder,
            resolved.ProfileOrder, fileURL, sandbox.Home);
        Assert.Equal(read.File, rebuilt);
    }

    // Windows: a tab or repo whose stored path or home is a UNC or device path counts as missing, and neither the
    // existence check nor any other file-system call sees it, on resolve, on the next save and on Save As.
    [Fact]
    public void UncAndDevicePathsAreMissingWithoutFileSystemCalls()
    {
        const string fileURL = @"C:\HistqQA\data\team.histqws";
        const string home = @"C:\Users\me";
        var seen = new List<string>();
        bool IsRepository(string path)
        {
            seen.Add(path);
            return PathFlavor.Windows.KeysEqual(path, @"C:\HistqQA\fx\app");
        }

        // Every path counts as real as written, so a real-path comparison is tried wherever the code would try one.
        var disk = new WorkspaceDisk(
            path =>
            {
                seen.Add(path);
                return path;
            },
            path =>
            {
                seen.Add(path);
                return null;
            });
        var file = new WorkspaceFile(
            [
                new WorkspaceFile.Window(WindowA, [
                    new WorkspaceFile.Tab("../fx/app", "~/git/app"),
                    new WorkspaceFile.Tab(@"\\attacker\share\x"),
                    new WorkspaceFile.Tab(Home: "//attacker/share/y"),
                    new WorkspaceFile.Tab(@"\\?\C:\HistqQA\fx\app", @"\\.\pipe\z"),
                    new WorkspaceFile.Tab(@"\/attacker/share/w", "~/git/w"),
                ]),
            ],
            [new WorkspaceFile.Repo(@"\\attacker\share\x", View: RepoViewState.Empty)]);

        var resolved = file.Resolve(fileURL, home, IsRepository, PathFlavor.Windows, disk);

        Assert.Equal(
            [@"C:\HistqQA\fx\app", @"\\attacker\share\x", @"\\attacker\share\y", @"\\.\pipe\z", @"C:\Users\me\git\w"],
            resolved.Windows[0].Tabs.Select(tab => tab.Path));
        Assert.True(resolved.Missing.SetEquals(
            [@"\\attacker\share\x", @"\\attacker\share\y", @"\\.\pipe\z", @"C:\Users\me\git\w"]));
        Assert.True(resolved.Carried.ContainsKey(@"\\attacker\share\x"));

        var rebuilt = WorkspaceFile.Build(
            resolved.Windows, resolved.Views, [], resolved.Carried, resolved.Originals, resolved.RepoOrder,
            resolved.ProfileOrder, fileURL, home, PathFlavor.Windows, disk);
        Assert.Equal(file, rebuilt);
        var rebased = WorkspaceFile.Rebased(
            resolved.Originals, resolved.Missing, resolved.Carried, @"C:\Other\team.histqws", home, PathFlavor.Windows, disk);
        Assert.Equal(@"\\attacker\share\x", rebased.Originals[@"\\attacker\share\x"].Path);
        Assert.Equal(@"\\attacker\share\x", rebased.Carried[@"\\attacker\share\x"].Path);

        Assert.NotEmpty(seen);
        Assert.DoesNotContain(seen, path => PathFlavor.Windows.IsUncOrDevice(path));
        Assert.All(seen, path => Assert.StartsWith(@"C:\", path, StringComparison.OrdinalIgnoreCase));
    }

    // Windows: keys compare case-insensitively, so a tab the app holds in another case keeps its stored strings; fresh
    // strings are written with '/' and '~/', and a repo on another drive is stored by its absolute path.
    [Fact]
    public void WindowsKeysIgnoreCaseAndFreshStringsUseSlashes()
    {
        const string fileURL = @"C:\HistqQA\data\team.histqws";
        const string home = @"C:\Users\me";
        var file = new WorkspaceFile([new WorkspaceFile.Window(WindowA, [new WorkspaceFile.Tab(@"..\fx\App")])]);
        var resolved = file.Resolve(
            fileURL, home, path => PathFlavor.Windows.KeysEqual(path, @"c:\histqqa\FX\app"), PathFlavor.Windows, WorkspaceDisk.None);
        Assert.Equal(@"C:\HistqQA\fx\App", resolved.Windows[0].Tabs[0].Path);
        Assert.Empty(resolved.Missing);

        var live = new WorkspaceFile.LiveWindow(WindowA, [
            new SavedTab(@"c:\HISTQQA\fx\app"),
            new SavedTab(@"C:\Users\me\git\lib"),
            new SavedTab(@"D:\repo"),
        ]);
        var built = WorkspaceFile.Build(
            [live], new Dictionary<string, RepoViewState>(), [], new Dictionary<string, WorkspaceFile.Repo>(),
            resolved.Originals, [], [], fileURL, home, PathFlavor.Windows, WorkspaceDisk.None);
        Assert.Equal(
            [
                new WorkspaceFile.Tab(@"..\fx\App"),
                new WorkspaceFile.Tab("../../Users/me/git/lib", "~/git/lib"),
                new WorkspaceFile.Tab(@"D:\repo", @"D:\repo"),
            ],
            built.Windows[0].Tabs);
    }

    // Reading and writing.

    // An unknown key makes a read lossy; a null-valued optional key does not.
    [Fact]
    public void UnknownKeyIsLossyNullIsNot()
    {
        using var sandbox = new Sandbox();
        var withNulls = sandbox.WriteFile("ws/nulls.histqws", $$"""
            { "version": 1,
              "windows": [ { "id": "{{Id(WindowA)}}",
                "tabs": [ { "path": "../repos/app", "home": "~/git/repos/app", "profile": "none", "alias": "App",
                            "emoji": null, "pinned": true, "iconColor": 2, "archived": null },
                          { "path": null } ] } ],
              "repos": [ { "path": "../repos/app", "home": "~/git/repos/app",
                           "view": { "hidden": [], "solo": [], "pinned": [], "hideStale": false } } ],
              "profiles": [] }
            """);
        Assert.True(WorkspaceFile.Read(withNulls).IsLossless);

        // A later build's field on a tab.
        var withUnknown = sandbox.WriteFile("ws/unknown.histqws", $$"""
            { "version": 1,
              "windows": [ { "id": "{{Id(WindowA)}}",
                "tabs": [ { "path": "../repos/app", "home": "~/git/repos/app", "badge": "beta" } ] } ],
              "repos": [], "profiles": [] }
            """);
        Assert.False(WorkspaceFile.Read(withUnknown).IsLossless);
    }

    // A null element of any list in the file is refused as undecodable, as Swift's decoder does.
    [Theory]
    [InlineData("""{ "version": 1, "windows": [ null ], "repos": [], "profiles": [] }""")]
    [InlineData("""{ "version": 1, "windows": [ { "id": "ID", "tabs": [ null ] } ], "repos": [], "profiles": [] }""")]
    [InlineData("""{ "version": 1, "windows": [ { "id": "ID", "tabs": [ {} ], "tabGroups": [ null ] } ], "repos": [], "profiles": [] }""")]
    [InlineData("""{ "version": 1, "windows": [ { "id": "ID", "tabs": [ {} ], "closedTabGroups": [ null ] } ], "repos": [], "profiles": [] }""")]
    [InlineData("""{ "version": 1, "windows": [ { "id": "ID", "tabs": [ {} ], "closedTabGroups": [ { "id": "ID", "color": 0, "tabs": [ null ] } ] } ], "repos": [], "profiles": [] }""")]
    [InlineData("""{ "version": 1, "windows": [ { "id": "ID", "tabs": [ {} ] } ], "repos": [ null ], "profiles": [] }""")]
    [InlineData("""{ "version": 1, "windows": [ { "id": "ID", "tabs": [ {} ] } ], "repos": [ { "view": { "hidden": [ null ] } } ], "profiles": [] }""")]
    [InlineData("""{ "version": 1, "windows": [ { "id": "ID", "tabs": [ {} ] } ], "repos": [], "profiles": [ null ] }""")]
    public void NullElementIsUndecodable(string json)
    {
        var data = Encoding.UTF8.GetBytes(json.Replace("ID", Id(WindowA), StringComparison.Ordinal));
        Assert.Equal(WorkspaceFileError.Undecodable(), Assert.Throws<WorkspaceFileError>(() => WorkspaceFile.Decode(data)));
    }

    // A workspace with no window, or with a window without tabs, is never written.
    [Fact]
    public void WriteRefusesEmpty()
    {
        using var sandbox = new Sandbox();
        var target = sandbox.Url("empty.histqws");
        Assert.Equal(WorkspaceFileError.Empty(), Assert.Throws<WorkspaceFileError>(() => new WorkspaceFile([]).Write(target)));
        var emptyWindow = new WorkspaceFile([new WorkspaceFile.Window(WindowA, [new WorkspaceFile.Tab()]), new WorkspaceFile.Window(WindowB, [])]);
        Assert.Equal(WorkspaceFileError.Empty(), Assert.Throws<WorkspaceFileError>(() => emptyWindow.Write(target)));
        Assert.False(File.Exists(target));
        Assert.Equal(["home"], Directory.EnumerateFileSystemEntries(sandbox.Root).Select(entry => Path.GetFileName(entry)));
    }

    // Writing through a symlink replaces its target: mode 600, pretty-printed with sorted keys, read back equal.
    [Fact]
    public void WriteThroughSymlink()
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), SymlinkSkip);
        using var sandbox = new Sandbox();
        var target = sandbox.WriteFile("team/ws/team.histqws", "{}");
        var link = sandbox.MakeLink("desk/team.histqws", target);
        var file = SwiftJson.Deserialize<WorkspaceFile>(Encoding.UTF8.GetBytes(TeamFile()));

        file.Write(link);

        Assert.NotNull(new FileInfo(link).LinkTarget);
        if (!OperatingSystem.IsWindows())
        {
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(target));
        }

        Assert.Equal(["team.histqws"], Directory.EnumerateFileSystemEntries(Path.GetDirectoryName(target)!).Select(entry => Path.GetFileName(entry)));
        var text = File.ReadAllText(target);
        var keys = new[] { "\"profiles\"", "\"repos\"", "\"version\"", "\"windows\"" }
            .Select(key => text.IndexOf(key, StringComparison.Ordinal)).ToList();
        Assert.Contains("\n  ", text, StringComparison.Ordinal);
        Assert.DoesNotContain(-1, keys);
        Assert.Equal(keys.Order(), keys);
        var read = WorkspaceFile.Read(link);
        Assert.True(read.IsLossless);
        Assert.Equal(file, read.File);
    }

    // A symlinked file resolves and builds its paths from its target's folder, not the link's.
    [Fact]
    public void SymlinkUsesTargetFolder()
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), SymlinkSkip);
        using var sandbox = new Sandbox();
        var target = sandbox.WriteFile("team/ws/team.histqws", $$"""
            { "version": 1, "windows": [ { "id": "{{Id(WindowA)}}", "tabs": [ { "path": "../repos/app" } ] } ],
              "repos": [], "profiles": [] }
            """);
        sandbox.MakeRepo("team/repos/app");
        var link = sandbox.MakeLink("desk/team.histqws", target);

        var resolved = WorkspaceFile.Read(link).File.Resolve(link, sandbox.Home, SavedSession.IsRepository);
        Assert.Equal([sandbox.Key("team/repos/app")], resolved.Windows[0].Tabs.Select(tab => tab.Path));
        Assert.Empty(resolved.Missing);

        var live = new WorkspaceFile.LiveWindow(WindowA, [new SavedTab(sandbox.Key("team/repos/app"))]);
        var fresh = Build([live], link, sandbox.Home);
        Assert.Equal("../repos/app", fresh.Windows[0].Tabs[0].Path);
    }

    // A workspace under a symlinked folder keeps its paths short and resolves them in the link's path space.
    [Fact]
    public void SymlinkedAncestorKeepsLexicalPaths()
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), SymlinkSkip);
        using var sandbox = new Sandbox();
        Directory.CreateDirectory(sandbox.Url("real"));
        sandbox.MakeLink("linked", sandbox.Url("real"), directory: true);
        var fileURL = sandbox.WriteFile("linked/ws/team.histqws", "{}");
        sandbox.MakeRepo("linked/repos/app");

        string? Stored(string absolute) =>
            Build([new WorkspaceFile.LiveWindow(WindowA, [new SavedTab(absolute)])], fileURL, sandbox.Home).Windows[0].Tabs[0].Path;

        Assert.Equal("../repos/app", Stored(sandbox.Key("linked/repos/app"))); // The app's path, through the link.
        // The two forms share the temp folder, so the real one is kept as written, not compared by real path.
        Assert.Equal("../../real/repos/app", Stored(sandbox.Key("real/repos/app")));

        var file = new WorkspaceFile([new WorkspaceFile.Window(WindowA, [new WorkspaceFile.Tab("../repos/app")])]);
        var resolved = file.Resolve(fileURL, sandbox.Home, SavedSession.IsRepository);
        Assert.Equal([sandbox.Key("linked/repos/app")], resolved.Windows[0].Tabs.Select(tab => tab.Path));
        Assert.Empty(resolved.Missing);
    }

    // A repo folder that is a symlink to elsewhere keeps the path it has in the workspace's tree.
    [Fact]
    public void SymlinkedRepoKeepsLexicalPath()
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), SymlinkSkip);
        using var sandbox = new Sandbox();
        var fileURL = sandbox.WriteFile("team/ws/team.histqws", "{}");
        sandbox.MakeRepo("elsewhere/app");
        sandbox.MakeLink("team/repos/app", sandbox.Url("elsewhere/app"), directory: true);

        var live = new WorkspaceFile.LiveWindow(WindowA, [new SavedTab(sandbox.Key("team/repos/app"))]);
        var file = Build([live], fileURL, sandbox.Home);
        Assert.Equal("../repos/app", file.Windows[0].Tabs[0].Path);

        var resolved = file.Resolve(fileURL, sandbox.Home, SavedSession.IsRepository);
        Assert.Equal([sandbox.Key("team/repos/app")], resolved.Windows[0].Tabs.Select(tab => tab.Path));
        Assert.Empty(resolved.Missing);
    }

    // Save As.

    // Save As elsewhere keeps the home of missing tabs and carried repos, with a path from the new folder.
    [Fact]
    public void SaveAsRebasesUnresolvedEntries()
    {
        using var sandbox = new Sandbox();
        var oldURL = sandbox.WriteFile("home/old/ws/team.histqws", $$"""
            { "version": 1,
              "windows": [ { "id": "{{Id(WindowA)}}",
                "tabs": [ { "path": "../repos/app", "home": "~/stale/app" },
                          { "path": "../gone", "home": "~/git/gone" } ] } ],
              "repos": [ { "path": "../repos/app", "home": "~/stale/app",
                           "view": { "hidden": [], "solo": [], "pinned": [], "hideStale": false } },
                         { "path": "../lost", "home": "~/git/lost",
                           "view": { "hidden": ["refs/heads/x"], "solo": [], "pinned": [], "hideStale": false } } ],
              "profiles": [] }
            """);
        sandbox.MakeRepo("home/old/repos/app");
        var resolved = WorkspaceFile.Read(oldURL).File.Resolve(oldURL, sandbox.Home, SavedSession.IsRepository);
        Assert.True(resolved.Missing.SetEquals([sandbox.Key("home/git/gone")]));
        Assert.Equal([sandbox.Key("home/git/lost")], resolved.Carried.Keys);

        // One level deeper than the old file, so every relative path changes.
        var newURL = sandbox.Url("home/new/deep/team.histqws");
        var rebased = WorkspaceFile.Rebased(resolved.Originals, resolved.Missing, resolved.Carried, newURL, sandbox.Home);
        var saved = WorkspaceFile.Build(
            resolved.Windows, resolved.Views, [], rebased.Carried, rebased.Originals, resolved.RepoOrder,
            resolved.ProfileOrder, newURL, sandbox.Home);
        var file = SwiftJson.Deserialize<WorkspaceFile>(SwiftJson.Serialize(saved, SwiftJsonFormatting.None));

        var tabs = file.Windows[0].Tabs;
        Assert.Equal(("../../old/repos/app", "~/old/repos/app"), (tabs[0].Path, tabs[0].Home)); // Resolved: fresh.
        Assert.Equal(("../../git/gone", "~/git/gone"), (tabs[1].Path, tabs[1].Home)); // Missing: home kept.
        Assert.Equal(
            [
                new WorkspaceFile.Repo("../../old/repos/app", "~/old/repos/app", RepoViewState.Empty),
                new WorkspaceFile.Repo("../../git/lost", "~/git/lost", new RepoViewState(["refs/heads/x"])),
            ],
            file.Repos);
    }

    // Identity.

    // A file has the same key before and after it exists, and a new file is written there and reads back.
    [Fact]
    public void IdentityKeyIsStable()
    {
        using var sandbox = new Sandbox();
        var file = sandbox.Url("team.histqws");
        var before = WorkspaceFile.IdentityKey(file);
        var workspace = new WorkspaceFile([new WorkspaceFile.Window(WindowA, [new WorkspaceFile.Tab()])]);
        workspace.Write(file);
        Assert.Equal(before, WorkspaceFile.IdentityKey(file));
        Assert.Equal(workspace, WorkspaceFile.Read(file).File);
    }

    // A file and a symlink to it share one key.
    [Fact]
    public void IdentityKeyFollowsSymlink()
    {
        Assert.SkipWhen(OperatingSystem.IsWindows(), SymlinkSkip);
        using var sandbox = new Sandbox();
        var file = sandbox.Url("team.histqws");
        File.WriteAllText(file, "{}");
        var link = sandbox.Url("link.histqws");
        File.CreateSymbolicLink(link, file);
        Assert.Equal(WorkspaceFile.IdentityKey(file), WorkspaceFile.IdentityKey(link));
    }

    // A UNC or device path is never a repo on Windows, and no file-system call is made for it.
    [Theory]
    [InlineData(@"\\server\share\repo")]
    [InlineData("//server/share/repo")]
    [InlineData(@"\\?\C:\repo")]
    [InlineData(@"\\.\C:\repo")]
    public void IsRepositoryRefusesUncOrDevicePath(string path)
    {
        var probed = new List<string>();
        bool Probe(string probe)
        {
            probed.Add(probe);
            return true;
        }

        Assert.False(SavedSession.IsRepository(path, PathFlavor.Windows, Probe, Probe));
        Assert.Empty(probed);
    }

    // Walking up from a local Windows path to its root never probes a UNC or device path.
    [Theory]
    [InlineData(@"C:\a\b\c")]
    [InlineData(@"\a\b")]
    [InlineData("/a/b")]
    [InlineData(@"C:a\b")]
    public void IsRepositoryWalkNeverProbesUncOrDevicePath(string path)
    {
        var probed = new List<string>();
        bool PathExists(string probe)
        {
            probed.Add(probe);
            return false;
        }

        Assert.False(SavedSession.IsRepository(path, PathFlavor.Windows, _ => true, PathExists));
        Assert.NotEmpty(probed);
        Assert.DoesNotContain(probed, probe => PathFlavor.Windows.IsUncOrDevice(probe));
    }

    /// <summary>The file at <paramref name="fileURL"/> built from <paramref name="windows"/> with nothing stored before.</summary>
    private static WorkspaceFile Build(IReadOnlyList<WorkspaceFile.LiveWindow> windows, string fileURL, string home) =>
        WorkspaceFile.Build(
            windows, new Dictionary<string, RepoViewState>(), [], new Dictionary<string, WorkspaceFile.Repo>(),
            new Dictionary<string, WorkspaceFile.Original>(), [], [], fileURL, home);

    /// <summary>A temp folder with a fake home (<c>home/</c>) and helpers to place fake repos and workspace files.</summary>
    private sealed class Sandbox : IDisposable
    {
        public Sandbox()
        {
            Root = Fixtures.MakeTempDirectory("HistqWorkspaceFile");
            Directory.CreateDirectory(Home);
        }

        public string Root { get; }

        public string Home => Url("home");

        public string Url(string relative) => Path.Join(Root, relative);

        /// <summary>The standardized absolute path of <paramref name="relative"/>, the form every resolved key has.</summary>
        public string Key(string relative) => PathFlavor.Host.Standardized(Url(relative));

        /// <summary>A fake repo: a folder with a <c>.git</c> folder.</summary>
        public void MakeRepo(string relative) => Directory.CreateDirectory(Path.Join(Url(relative), ".git"));

        /// <summary>Writes <paramref name="json"/> at <paramref name="relative"/>, creating its folder.</summary>
        public string WriteFile(string relative, string json)
        {
            var file = Url(relative);
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file, json);
            return file;
        }

        /// <summary>A symlink at <paramref name="relative"/> to <paramref name="target"/>, creating its folder.</summary>
        public string MakeLink(string relative, string target, bool directory = false)
        {
            var link = Url(relative);
            Directory.CreateDirectory(Path.GetDirectoryName(link)!);
            if (directory)
            {
                Directory.CreateSymbolicLink(link, target);
            }
            else
            {
                File.CreateSymbolicLink(link, target);
            }

            return link;
        }

        public void Dispose() => Fixtures.RemoveTempDirectory(Root);
    }
}

// The state formats both ways between the Mac app and this port (windows/README.md, "Cross-platform fixtures").
// Fixtures/macos-fixtures.json is written by HistqCore (`fixture-bridge export`): every part must decode with the C#
// types and encode back to the same JSON. Fixtures/windows-fixtures.json is what this port writes, with Windows-made
// relative `path`s and `~` homes (PathFlavor.Windows, so it builds the same on the Mac); `fixture-bridge check` reads it
// with HistqCore. With HISTQ_WRITE_FIXTURES=1 the test writes that file first; it always checks the file against the
// writer, so a stale file fails. Every id is fixed and the formats hold no dates, so the file is the same on every run.
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Histq.Core.Tests;

public sealed class CrossPlatformFixtureTests
{
    private static readonly Guid WorkID = Guid.Parse("4B3C2D1E-0000-4000-8000-000000000001");
    private static readonly Guid PersonalID = Guid.Parse("4B3C2D1E-0000-4000-8000-000000000002");
    private static readonly Guid CoreGroup = Guid.Parse("8D2E3F40-0000-4000-8000-000000000011");
    private static readonly Guid LooseGroup = Guid.Parse("8D2E3F40-0000-4000-8000-000000000012");
    private static readonly Guid OldGroup = Guid.Parse("8D2E3F40-0000-4000-8000-000000000013");
    private static readonly Guid WindowA = Guid.Parse("B2C3D4E5-0000-4000-8000-000000000021");
    private static readonly Guid WindowB = Guid.Parse("B2C3D4E5-0000-4000-8000-000000000022");
    private static readonly string IconName = string.Concat(Enumerable.Repeat("0123456789abcdef", 4)) + ".png";

    [Fact]
    public void MacFixturesDecodeAndEncodeBackToTheSameJson()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(FixturePath("macos-fixtures.json")));
        var root = document.RootElement;
        Assert.Equal(
            ["profiles", "repoView", "session", "workspace"],
            root.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal));

        var workspaceJson = root.GetProperty("workspace");
        var read = WorkspaceFile.Decode(Encoding.UTF8.GetBytes(workspaceJson.GetRawText()));
        Assert.True(read.IsLossless);
        AssertSameJson(workspaceJson, read.File);
        Assert.Equal(2, read.File.Windows.Count);
        Assert.Equal("../src/beta", read.File.Windows[0].Tabs[1].Path);

        var sessionJson = root.GetProperty("session");
        var session = SwiftJson.Deserialize<SavedSession>(Encoding.UTF8.GetBytes(sessionJson.GetRawText()));
        AssertSameJson(sessionJson, session);
        Assert.Equal(2, session.Workspaces?.Count);

        var profilesJson = root.GetProperty("profiles");
        var profiles = SwiftJson.Deserialize<IReadOnlyList<Profile>>(Encoding.UTF8.GetBytes(profilesJson.GetRawText()));
        AssertSameJson(profilesJson, profiles);
        Assert.Equal(2, profiles[0].Accounts.Count);

        var viewJson = root.GetProperty("repoView");
        var view = SwiftJson.Deserialize<RepoViewState>(Encoding.UTF8.GetBytes(viewJson.GetRawText()));
        AssertSameJson(viewJson, view);
        Assert.True(view.HideStale);
    }

    [Fact]
    public void WindowsFixturesMatchTheWriter()
    {
        var fixtures = WindowsFixtures();
        var bytes = SwiftJson.Serialize(fixtures, SwiftJsonFormatting.PrettyPrinted | SwiftJsonFormatting.SortedKeys)
            .Concat("\n"u8.ToArray()).ToArray();
        var path = FixturePath("windows-fixtures.json");
        if (string.Equals(Environment.GetEnvironmentVariable("HISTQ_WRITE_FIXTURES"), "1", StringComparison.Ordinal))
        {
            File.WriteAllBytes(path, bytes);
        }

        var tabs = fixtures.Workspace.Windows[0].Tabs;
        Assert.Equal("repos/alpha", tabs[0].Path);
        Assert.Equal("~/Work/repos/alpha", tabs[0].Home);
        Assert.Equal("../src/beta", tabs[1].Path);
        Assert.Equal("~/src/beta", tabs[1].Home);

        using var written = JsonDocument.Parse(File.ReadAllBytes(path));
        using var built = JsonDocument.Parse(bytes);
        Assert.True(
            JsonElement.DeepEquals(written.RootElement, built.RootElement),
            "Fixtures/windows-fixtures.json is stale: regenerate it with HISTQ_WRITE_FIXTURES=1 (windows/README.md).");
    }

    /// <summary>The four state formats as this port writes them, for a workspace at C:\Users\qa\Work\team.histqws.</summary>
    private static WindowsFixtureFile WindowsFixtures()
    {
        var flavor = PathFlavor.Windows;
        const string home = @"C:\Users\qa";
        const string workspacePath = @"C:\Users\qa\Work\team.histqws";
        const string alpha = @"C:\Users\qa\Work\repos\alpha";
        const string beta = @"C:\Users\qa\src\beta";
        const string gamma = @"D:\Ext\gamma";
        const string delta = @"C:\Users\qa\Work\repos\delta";
        const string old = @"C:\Users\qa\Work\repos\old";

        var work = new Profile(
                "Work", "#3A8EE5", new ProfileIdentity("QA Work", "qa@work.invalid"), new ProfileSigning.Gpg("ABCDEF0123456789"),
                signByDefault: true, id: WorkID)
            .WithAccount(new HostingAccount(HostingKind.GitHub, "github.com", "qa-work"))
            .WithAccount(new HostingAccount(HostingKind.AzureDevOps, "dev.azure.com", "qa", BasePath: "/qa-org"));
        var personal = new Profile(
            "Personal", "#E5B13A", new ProfileIdentity("QA", "qa@histq.invalid"), new ProfileSigning.Ssh(@"C:\Users\qa\.ssh\id_ed25519.pub"),
            ssh: new ProfileSshKey.KeyFile(@"C:\Users\qa\.ssh\id_ed25519"), id: PersonalID);
        var view = new RepoViewState(["refs/heads/old", "refs/tags/v0.1"], ["refs/heads/main"], ["refs/remotes/origin/main"], HideStale: true);

        SavedTab[] tabs =
        [
            new(alpha, new SavedProfile(WorkID), Alias: "Alpha", Pinned: true),
            new(beta, SavedProfile.None, Emoji: "\U0001F680", IconColor: 3, TabGroup: CoreGroup),
            new(gamma, Icon: IconName, TabGroup: LooseGroup),
            new(),
            new(delta, Archived: true),
        ];
        var groups = new WorkspaceFile.TabGroup[] { new(CoreGroup, 2, "Core"), new(LooseGroup, 0) };
        var closed = new SavedClosedTabGroup[] { new(OldGroup, 5, [new SavedTab(old)], "Old") };
        var workspace = WorkspaceFile.Build(
            [new WorkspaceFile.LiveWindow(WindowA, tabs, groups, closed), new WorkspaceFile.LiveWindow(WindowB, [new SavedTab(@"C:\Users\qa\Work")])],
            new Dictionary<string, RepoViewState>(flavor.KeyComparer) { [alpha] = view, [beta] = RepoViewState.Empty },
            [work],
            new Dictionary<string, WorkspaceFile.Repo>(flavor.KeyComparer),
            new Dictionary<string, WorkspaceFile.Original>(flavor.KeyComparer),
            [alpha, beta],
            [WorkID],
            workspacePath,
            home,
            flavor,
            WorkspaceDisk.None);

        var session = new SavedSession(
            [
                new SavedWindow(
                    120.5, 80, 1280, 800.25, 0, 0, true, tabs, SelectedTab: 1,
                    ManualTabGroups: [new SavedTabGroup(CoreGroup, 2, "Core", Collapsed: true), new SavedTabGroup(LooseGroup, 0)],
                    ClosedTabGroups: closed),
                new SavedWindow(-40, 0, 900, 600, 1, 0, false, [new SavedTab()]),
            ],
            [
                new WorkspaceLayout(workspacePath, true,
                [
                    new WorkspaceLayout.Window(WindowA, 10, 20.75, 1100, 700, 2, 0, true, alpha, [CoreGroup]),
                    new WorkspaceLayout.Window(WindowB, 30, 40, 800, 500, 2, 1, false),
                ]),
                new WorkspaceLayout(@"C:\Users\qa\Old\old.histqws", false, []),
            ]);

        return new WindowsFixtureFile(workspace, session, [work, personal], view);
    }

    /// <summary>Requires <paramref name="value"/> to encode to the same JSON value as <paramref name="original"/>.</summary>
    private static void AssertSameJson<T>(JsonElement original, T value)
    {
        var encoded = SwiftJson.Serialize(value, SwiftJsonFormatting.None);
        using var again = JsonDocument.Parse(encoded);
        Assert.True(
            JsonElement.DeepEquals(original, again.RootElement),
            $"The C# round trip changed {typeof(T).Name}:\n{original.GetRawText()}\n---\n{Encoding.UTF8.GetString(encoded)}");
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

    private sealed record WindowsFixtureFile(
        [property: JsonPropertyName("workspace")] WorkspaceFile Workspace,
        [property: JsonPropertyName("session")] SavedSession Session,
        [property: JsonPropertyName("profiles")] IReadOnlyList<Profile> Profiles,
        [property: JsonPropertyName("repoView")] RepoViewState RepoView);
}

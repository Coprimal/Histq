// The saved shape of the open windows and their app tabs: `session.json` (the app's SessionStore). Plain values, so
// the file format lives beside the code that reads and writes workspace files. A key the Swift type leaves out when nil
// is left out here too (SwiftJson). Ported from SavedSession.swift at 6fa6d40.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Histq.Core;

/// <summary>What the last run had open: one entry per document window, front group first.</summary>
public sealed record SavedSession
{
    /// <summary>The file format; a file of another version is ignored.</summary>
    public const int CurrentVersion = 1;

    public SavedSession(IReadOnlyList<SavedWindow> windows, IReadOnlyList<WorkspaceLayout>? workspaces = null)
        : this(CurrentVersion, windows, workspaces)
    {
    }

    [JsonConstructor]
    public SavedSession(int version, IReadOnlyList<SavedWindow> windows, IReadOnlyList<WorkspaceLayout>? workspaces = null)
    {
        Version = version;
        Windows = windows;
        Workspaces = workspaces;
    }

    [JsonPropertyName("version")]
    public int Version { get; init; }

    /// <summary>The Untitled windows: those in no workspace.</summary>
    [JsonPropertyName("windows")]
    public IReadOnlyList<SavedWindow> Windows { get; init; }

    /// <summary>The layouts of open and recently closed workspaces, one per file; null when none, so the key stays
    /// absent. Absent from files of older builds.</summary>
    [JsonPropertyName("workspaces")]
    public IReadOnlyList<WorkspaceLayout>? Workspaces { get; init; }

    /// <summary>The windows by native tab group, groups front first, each group in its tab order.</summary>
    [JsonIgnore]
    public IReadOnlyList<IReadOnlyList<SavedWindow>> Groups =>
        Windows.Select(window => window.Group).Distinct().Order()
            .Select(group => (IReadOnlyList<SavedWindow>)Windows.Where(window => window.Group == group)
                .OrderBy(window => window.TabIndex).ToList())
            .ToList();

    /// <summary>
    /// Decodes <c>session.json</c>. Throws <see cref="JsonException"/> when it is not a session, or a list in it (windows,
    /// tabs, manual groups, closed groups and their tabs, workspaces and their windows) holds a null element, as
    /// Swift's decoder does. The version is not checked here.
    /// </summary>
    public static SavedSession Decode(ReadOnlySpan<byte> data)
    {
        var session = SwiftJson.Deserialize<SavedSession>(data);
        return session.HasNullElement() ? throw new JsonException("A list of the session holds null.") : session;
    }

    /// <summary>The session as read: one workspace layout per <c>path</c> (the first kept, paths compared as keys of
    /// this OS: case-insensitively on Windows), and null for an empty list.</summary>
    public SavedSession Normalized() => Normalized(PathFlavor.Host);

    /// <summary><see cref="Normalized()"/> with the path keys of <paramref name="flavor"/>.</summary>
    internal SavedSession Normalized(PathFlavor flavor)
    {
        var paths = new HashSet<string>(flavor.KeyComparer);
        var layouts = Workspaces?.Where(layout => paths.Add(layout.Path)).ToList();
        return new SavedSession(Version, Windows, layouts is { Count: > 0 } ? layouts : null);
    }

    /// <summary>
    /// Whether <paramref name="path"/> still opens as a repo: a folder inside a work tree (<c>.git</c> is a folder, or a
    /// file for a linked worktree or a submodule, in it or in a parent), or a bare repository. File checks only, no git;
    /// none on a relative path, or on a UNC or device path, which is never a repository here: the check for paths read
    /// from a received <c>.histqws</c>. Paths the user gave this machine use <see cref="IsUserRepository"/>.
    /// </summary>
    public static bool IsRepository(string path) => IsRepository(path, PathFlavor.Host, Directory.Exists, Path.Exists);

    /// <summary>
    /// <see cref="IsRepository(string)"/> for a path the user gave this machine: a tab of their own
    /// <c>session.json</c>, a folder they picked, dropped or chose from a recent list. A UNC or device path
    /// (<c>\\wsl.localhost\Ubuntu\home\me\repo</c>, a redirected home share) is probed too. Never for a path read
    /// from a received <c>.histqws</c>.
    /// </summary>
    public static bool IsUserRepository(string path) =>
        IsRepository(path, PathFlavor.Host, Directory.Exists, Path.Exists, allowUncOrDevice: true);

    /// <summary><see cref="IsRepository(string)"/> with the path rules of <paramref name="flavor"/> and the given
    /// file-system probes, so tests check the Windows guard on any host. Parents of a path that is not UNC or device
    /// never are, so the walk stays local. <paramref name="allowUncOrDevice"/> lifts the UNC and device refusal
    /// (<see cref="IsUserRepository"/>).</summary>
    internal static bool IsRepository(
        string path, PathFlavor flavor, Func<string, bool> directoryExists, Func<string, bool> pathExists,
        bool allowUncOrDevice = false)
    {
        if (!flavor.IsAbsolute(path) || (!allowUncOrDevice && flavor.IsUncOrDevice(path)) || !directoryExists(path))
        {
            return false;
        }

        var folder = flavor.Standardized(path);
        if (new[] { "HEAD", "objects", "refs" }.All(name => pathExists(flavor.Resolve(folder, name))))
        {
            return true;
        }

        for (var current = folder; ; current = flavor.Parent(current))
        {
            if (pathExists(flavor.Resolve(current, ".git")))
            {
                return true;
            }

            if (string.Equals(flavor.Parent(current), current, StringComparison.Ordinal))
            {
                return false;
            }
        }
    }

    public bool Equals(SavedSession? other) =>
        other is not null && Version == other.Version && Windows.SequenceEqual(other.Windows)
        && SequenceEquality.Equal(Workspaces, other.Workspaces);

    public override int GetHashCode() => HashCode.Combine(Version, Windows.Count, Workspaces?.Count);

    /// <summary>Whether a list holds a null element, which SwiftJson does not reject for these types but Swift's
    /// decoder does.</summary>
    private bool HasNullElement() =>
        Windows.Any(window => window is null
            || window.Tabs.Any(tab => tab is null)
            || (window.ManualTabGroups?.Any(group => group is null) ?? false)
            || (window.ClosedTabGroups?.Any(group => group is null || group.Tabs.Any(tab => tab is null)) ?? false))
        || (Workspaces?.Any(layout => layout is null || layout.Windows.Any(window => window is null)) ?? false);
}

/// <summary>A document window: its frame, its place in a native tab group, and its app tabs.</summary>
/// <param name="X">Screen points, origin at the bottom left on the Mac (<c>NSWindow.frame</c>).</param>
/// <param name="Group">Windows with the same group are native tabs of one window; groups are numbered front to back.</param>
/// <param name="TabIndex">The window's place in its group's tab bar.</param>
/// <param name="IsSelectedInGroup">The native tab its group shows.</param>
/// <param name="SelectedTab">The selected app tab's index.</param>
/// <param name="ManualTabGroups">The window's manual tab groups, in order; null when it has none.</param>
/// <param name="ClosedTabGroups">The window's closed groups, most recently closed first; null when it has none.</param>
public sealed record SavedWindow(
    [property: JsonPropertyName("x")] double X,
    [property: JsonPropertyName("y")] double Y,
    [property: JsonPropertyName("width")] double Width,
    [property: JsonPropertyName("height")] double Height,
    [property: JsonPropertyName("group")] int Group,
    [property: JsonPropertyName("tabIndex")] int TabIndex,
    [property: JsonPropertyName("isSelectedInGroup")] bool IsSelectedInGroup,
    [property: JsonPropertyName("tabs")] IReadOnlyList<SavedTab> Tabs,
    [property: JsonPropertyName("selectedTab")] int? SelectedTab = null,
    [property: JsonPropertyName("manualTabGroups")] IReadOnlyList<SavedTabGroup>? ManualTabGroups = null,
    [property: JsonPropertyName("closedTabGroups")] IReadOnlyList<SavedClosedTabGroup>? ClosedTabGroups = null)
{
    public bool Equals(SavedWindow? other) =>
        other is not null && X.Equals(other.X) && Y.Equals(other.Y) && Width.Equals(other.Width)
        && Height.Equals(other.Height) && Group == other.Group && TabIndex == other.TabIndex
        && IsSelectedInGroup == other.IsSelectedInGroup && Tabs.SequenceEqual(other.Tabs)
        && SelectedTab == other.SelectedTab && SequenceEquality.Equal(ManualTabGroups, other.ManualTabGroups)
        && SequenceEquality.Equal(ClosedTabGroups, other.ClosedTabGroups);

    public override int GetHashCode() => HashCode.Combine(X, Y, Width, Height, Group, TabIndex, Tabs.Count);
}

/// <summary>An app tab: a repo folder with its profile, or a Welcome tab.</summary>
/// <param name="Path">The repo folder; null for a Welcome tab.</param>
/// <param name="Profile">The tab's profile as chosen in that session; null when it was not known yet.</param>
/// <param name="Alias">The tab's alias; null shows the folder's name.</param>
/// <param name="Emoji">The tab's emoji; null shows none.</param>
/// <param name="Icon">The uploaded image's file name in the Icons folder (<see cref="CustomIcon"/>), set instead of
/// <paramref name="Emoji"/>; null for none.</param>
/// <param name="Pinned">Null reads as false; an unpinned tab is written as null.</param>
/// <param name="IconColor">The book icon color, an index into the graph lane palette; null for the default.</param>
/// <param name="Archived">The tab is in the window's archive; null reads as false. Archived entries come after every
/// other tab.</param>
/// <param name="TabGroup">The manual group it is in (<see cref="SavedWindow.ManualTabGroups"/>); null for none.</param>
public sealed record SavedTab(
    [property: JsonPropertyName("path")] string? Path = null,
    [property: JsonPropertyName("profile")] SavedProfile? Profile = null,
    [property: JsonPropertyName("alias")] string? Alias = null,
    [property: JsonPropertyName("emoji")] string? Emoji = null,
    [property: JsonPropertyName("icon")] string? Icon = null,
    [property: JsonPropertyName("pinned")] bool? Pinned = null,
    [property: JsonPropertyName("iconColor")] int? IconColor = null,
    [property: JsonPropertyName("archived")] bool? Archived = null,
    [property: JsonPropertyName("tabGroup")] Guid? TabGroup = null)
{
    /// <summary>
    /// The tab's icon slot as the app holds it: an uploaded image's reference (<see cref="CustomIcon.Ref"/>) when
    /// <see cref="Icon"/> is a valid file name, else the emoji.
    /// </summary>
    [JsonIgnore]
    public string? Mark =>
        Icon is not null && CustomIcon.IsValidFileName(Icon) ? CustomIcon.Ref(Icon) : Emoji;

    /// <summary>The alias, else the repo folder's name, or "New Tab" for a Welcome tab.</summary>
    [JsonIgnore]
    public string Title => Alias ?? (Path is null ? "New Tab" : PathFlavor.Host.LastComponent(Path));

    /// <summary>This tab with <paramref name="mark"/> in its icon slot: a valid reference stores its file name in
    /// <see cref="Icon"/> and clears <see cref="Emoji"/>; anything else goes to <see cref="Emoji"/> and clears
    /// <see cref="Icon"/>.</summary>
    public SavedTab WithMark(string? mark) =>
        (mark is null ? null : CustomIcon.FileName(mark)) is { } name
            ? this with { Icon = name, Emoji = null }
            : this with { Emoji = mark, Icon = null };
}

/// <summary>A manual tab group of a window.</summary>
/// <param name="Color">Its swatch: 0 is grey, 1-8 a lane color; clamped to 0...8 on restore.</param>
/// <param name="Name">The name the user gave it; null for none.</param>
/// <param name="Collapsed">The group shows only its chip; null reads as false, and an expanded group is written as null.</param>
public sealed record SavedTabGroup(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("color")] int Color,
    [property: JsonPropertyName("name")] string? Name = null,
    [property: JsonPropertyName("collapsed")] bool? Collapsed = null);

/// <summary>A manual tab group stowed by its Close Group, with its tabs, until it opens again.</summary>
/// <param name="Color">Its swatch, as <see cref="SavedTabGroup.Color"/>.</param>
/// <param name="Tabs">Its tabs in order, each with <c>tabGroup</c>, <c>pinned</c> and <c>archived</c> null.</param>
/// <param name="Name">The name the user gave it; null for none.</param>
public sealed record SavedClosedTabGroup(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("color")] int Color,
    [property: JsonPropertyName("tabs")] IReadOnlyList<SavedTab> Tabs,
    [property: JsonPropertyName("name")] string? Name = null)
{
    public bool Equals(SavedClosedTabGroup? other) =>
        other is not null && Id == other.Id && Color == other.Color && Tabs.SequenceEqual(other.Tabs)
        && string.Equals(Name, other.Name, StringComparison.Ordinal);

    public override int GetHashCode() => HashCode.Combine(Id, Color, Tabs.Count);
}

/// <summary>
/// A tab's profile choice, stored as one string: a profile id (upper case, read in either case), or <c>"none"</c>
/// (git uses the user's own config). Any string that is not a UUID reads as none; anything but a string is an error.
/// </summary>
[JsonConverter(typeof(SavedProfileJsonConverter))]
public readonly record struct SavedProfile(Guid? ProfileId)
{
    /// <summary>No profile: git uses the user's own config.</summary>
    public static SavedProfile None => default;

    private sealed class SavedProfileJsonConverter : JsonConverter<SavedProfile>
    {
        public override SavedProfile Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType != JsonTokenType.String)
            {
                throw new JsonException("A tab's profile is a string.");
            }

            return Guid.TryParseExact(reader.GetString(), "D", out var id) ? new SavedProfile(id) : None;
        }

        public override void Write(Utf8JsonWriter writer, SavedProfile value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ProfileId?.ToString("D").ToUpperInvariant() ?? "none");
    }
}

/// <summary>Element-wise equality of optional lists, for the records that hold them.</summary>
internal static class SequenceEquality
{
    public static bool Equal<T>(IReadOnlyList<T>? a, IReadOnlyList<T>? b) =>
        a is null ? b is null : b is not null && a.SequenceEqual(b);
}

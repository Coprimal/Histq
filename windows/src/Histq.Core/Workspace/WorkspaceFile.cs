// A workspace file (`*.histqws`): a working set of windows, their app tabs, the profiles those tabs use and each
// repo's graph view. Paths are stored twice: `path` relative to the file's folder and `home` in the `~/...` form, so
// the file opens on another machine or after a move. The app works with absolute paths: `Resolve` maps the file to
// them, `Build` maps them back, reusing the stored strings of every path the file already had, so an unchanged
// workspace encodes to the same model on every launch and every machine. Files can come from a download or a cloned
// repo: nothing read here is trusted, and a path only counts when the caller's `isRepository` holds. On Windows a
// stored `path` or `home` that is a UNC or device path counts as missing without any file-system call (no SMB access,
// so no automatic NTLM authentication to a share a received file names); the user can still open such a folder
// explicitly. Path rules come from an explicit PathFlavor; the file-system calls besides `isRepository` (a file's
// own symlinks, real paths) go through a WorkspaceDisk. Ported from WorkspaceFile.swift at 6fa6d40.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Histq.Core;

public sealed record WorkspaceFile
{
    /// <summary>The file format; a file of another version is refused.</summary>
    public const int CurrentVersion = 1;

    public WorkspaceFile(IReadOnlyList<Window> windows, IReadOnlyList<Repo>? repos = null, IReadOnlyList<Profile>? profiles = null)
        : this(CurrentVersion, windows, repos ?? [], profiles ?? [])
    {
    }

    [JsonConstructor]
    public WorkspaceFile(int version, IReadOnlyList<Window> windows, IReadOnlyList<Repo> repos, IReadOnlyList<Profile> profiles)
    {
        Version = version;
        Windows = windows;
        Repos = repos;
        Profiles = profiles;
    }

    [JsonPropertyName("version")]
    public int Version { get; init; }

    [JsonPropertyName("windows")]
    public IReadOnlyList<Window> Windows { get; init; }

    [JsonPropertyName("repos")]
    public IReadOnlyList<Repo> Repos { get; init; }

    [JsonPropertyName("profiles")]
    public IReadOnlyList<Profile> Profiles { get; init; }

    public bool Equals(WorkspaceFile? other) =>
        other is not null && Version == other.Version && Windows.SequenceEqual(other.Windows)
        && Repos.SequenceEqual(other.Repos) && Profiles.SequenceEqual(other.Profiles);

    public override int GetHashCode() => HashCode.Combine(Version, Windows.Count, Repos.Count, Profiles.Count);

    /// <summary>A window: its manual tab groups (null when none), its app tabs, archived ones last, and its closed
    /// groups (null when none).</summary>
    public sealed record Window(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("tabs")] IReadOnlyList<Tab> Tabs,
        [property: JsonPropertyName("tabGroups")] IReadOnlyList<TabGroup>? TabGroups = null,
        [property: JsonPropertyName("closedTabGroups")] IReadOnlyList<ClosedTabGroup>? ClosedTabGroups = null)
    {
        public bool Equals(Window? other) =>
            other is not null && Id == other.Id && Tabs.SequenceEqual(other.Tabs)
            && SequenceEquality.Equal(TabGroups, other.TabGroups)
            && SequenceEquality.Equal(ClosedTabGroups, other.ClosedTabGroups);

        public override int GetHashCode() => HashCode.Combine(Id, Tabs.Count);
    }

    /// <summary>A manual tab group stowed by its Close Group, as <see cref="SavedClosedTabGroup"/>, with its tabs
    /// stored as <see cref="Tab"/>.</summary>
    /// <param name="Color">0 is grey, 1-8 a lane color, as <see cref="SavedTabGroup.Color"/>.</param>
    public sealed record ClosedTabGroup(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("color")] int Color,
        [property: JsonPropertyName("tabs")] IReadOnlyList<Tab> Tabs,
        [property: JsonPropertyName("name")] string? Name = null)
    {
        public bool Equals(ClosedTabGroup? other) =>
            other is not null && Id == other.Id && Color == other.Color && Tabs.SequenceEqual(other.Tabs)
            && string.Equals(Name, other.Name, StringComparison.Ordinal);

        public override int GetHashCode() => HashCode.Combine(Id, Color, Tabs.Count);
    }

    /// <summary>A manual tab group. Whether it is collapsed is machine-local
    /// (<see cref="WorkspaceLayout.Window.CollapsedGroups"/>).</summary>
    /// <param name="Color">0 is grey, 1-8 a lane color, as <see cref="SavedTabGroup.Color"/>.</param>
    public sealed record TabGroup(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("color")] int Color,
        [property: JsonPropertyName("name")] string? Name = null);

    /// <summary>An app tab, as <see cref="SavedTab"/> with the repo stored as <c>path</c> / <c>home</c>; both null for
    /// a Welcome tab.</summary>
    /// <param name="Icon">The uploaded image's file name, set instead of <paramref name="Emoji"/>; null for none.</param>
    /// <param name="Group">The id of its window's manual tab group; null for none.</param>
    public sealed record Tab(
        [property: JsonPropertyName("path")] string? Path = null,
        [property: JsonPropertyName("home")] string? Home = null,
        [property: JsonPropertyName("profile")] SavedProfile? Profile = null,
        [property: JsonPropertyName("alias")] string? Alias = null,
        [property: JsonPropertyName("emoji")] string? Emoji = null,
        [property: JsonPropertyName("icon")] string? Icon = null,
        [property: JsonPropertyName("pinned")] bool? Pinned = null,
        [property: JsonPropertyName("iconColor")] int? IconColor = null,
        [property: JsonPropertyName("archived")] bool? Archived = null,
        [property: JsonPropertyName("group")] Guid? Group = null);

    /// <summary>A repo's graph view.</summary>
    public sealed record Repo(
        [property: JsonPropertyName("path")] string? Path = null,
        [property: JsonPropertyName("home")] string? Home = null,
        [property: JsonPropertyName("view")] RepoViewState? View = null);

    /// <summary>A window with absolute paths, as the app holds it: what <see cref="Resolve"/> returns and
    /// <see cref="Build"/> takes.</summary>
    /// <param name="Tabs">The tabs with absolute repo paths (<see cref="SavedTab.TabGroup"/> is the tab's group).</param>
    /// <param name="ClosedTabGroups">The closed groups, their tabs with absolute repo paths.</param>
    public sealed record LiveWindow(
        Guid Id, IReadOnlyList<SavedTab> Tabs, IReadOnlyList<TabGroup>? TabGroups = null,
        IReadOnlyList<SavedClosedTabGroup>? ClosedTabGroups = null)
    {
        public bool Equals(LiveWindow? other) =>
            other is not null && Id == other.Id && Tabs.SequenceEqual(other.Tabs)
            && SequenceEquality.Equal(TabGroups, other.TabGroups)
            && SequenceEquality.Equal(ClosedTabGroups, other.ClosedTabGroups);

        public override int GetHashCode() => HashCode.Combine(Id, Tabs.Count);
    }

    /// <summary>The <c>path</c> / <c>home</c> strings a tab or repo was stored with.</summary>
    public sealed record Original(string? Path, string? Home);

    // Identity.

    /// <summary>
    /// The one key of a workspace file (an absolute path): its real path when it exists, else the real path of its
    /// folder plus its name, so a symlink and the file before and after it is created share one key.
    /// </summary>
    public static string IdentityKey(string path)
    {
        var flavor = PathFlavor.Host;
        var disk = new GuardedDisk(flavor, WorkspaceDisk.Host);
        var standardized = flavor.Standardized(path);
        if (disk.RealPath(standardized) is { } real)
        {
            return real;
        }

        var folder = flavor.Parent(standardized);
        return flavor.Resolve(disk.RealPath(folder) ?? folder, flavor.LastComponent(standardized));
    }

    // Reading.

    /// <summary>A decoded file and whether this build keeps everything in it.</summary>
    /// <param name="IsLossless">False when re-encoding drops a key the file has (a later build's field): the workspace
    /// opens read-only.</param>
    public sealed record ReadResult(WorkspaceFile File, bool IsLossless);

    /// <summary>Reads the file at <paramref name="path"/> (see <see cref="Decode"/>); a read failure throws its IO error.</summary>
    public static ReadResult Read(string path) => Decode(File.ReadAllBytes(path));

    /// <summary>
    /// Decodes a workspace. Throws <see cref="WorkspaceFileError"/> of kind
    /// <see cref="WorkspaceFileErrorKind.UnsupportedVersion"/> for another version and
    /// <see cref="WorkspaceFileErrorKind.Undecodable"/> for anything else that is not a workspace; duplicate ids in the
    /// file are normalized.
    /// </summary>
    public static ReadResult Decode(ReadOnlySpan<byte> data)
    {
        JsonDocument original;
        try
        {
            original = JsonDocument.Parse(data.ToArray());
        }
        catch (JsonException)
        {
            throw WorkspaceFileError.Undecodable();
        }

        using (original)
        {
            if (original.RootElement.ValueKind != JsonValueKind.Object
                || !original.RootElement.TryGetProperty("version", out var version)
                || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number))
            {
                throw WorkspaceFileError.Undecodable();
            }

            if (number != CurrentVersion)
            {
                throw WorkspaceFileError.UnsupportedVersion(number);
            }

            WorkspaceFile file;
            JsonElement encoded;
            try
            {
                file = original.RootElement.Deserialize<WorkspaceFile>(SwiftJson.Options)
                    ?? throw WorkspaceFileError.Undecodable();
                if (file.HasNullElement())
                {
                    throw WorkspaceFileError.Undecodable();
                }

                encoded = JsonSerializer.SerializeToElement(file, SwiftJson.Options);
            }
            catch (Exception error) when (error is JsonException or NotSupportedException or InvalidOperationException)
            {
                throw WorkspaceFileError.Undecodable();
            }

            return new ReadResult(file.Normalized(), Keeps(original.RootElement, encoded));
        }
    }

    /// <summary>Whether every key of <paramref name="original"/> (a null value counts as absent) is in
    /// <paramref name="encoded"/>, through objects and arrays.</summary>
    private static bool Keeps(JsonElement original, JsonElement encoded)
    {
        switch (original.ValueKind)
        {
            case JsonValueKind.Object:
                if (encoded.ValueKind != JsonValueKind.Object)
                {
                    return false;
                }

                foreach (var property in original.EnumerateObject())
                {
                    if (property.Value.ValueKind == JsonValueKind.Null)
                    {
                        continue;
                    }

                    if (!encoded.TryGetProperty(property.Name, out var kept) || !Keeps(property.Value, kept))
                    {
                        return false;
                    }
                }

                return true;
            case JsonValueKind.Array:
                return encoded.ValueKind == JsonValueKind.Array
                    && original.GetArrayLength() == encoded.GetArrayLength()
                    && original.EnumerateArray().Zip(encoded.EnumerateArray()).All(pair => Keeps(pair.First, pair.Second));
            default:
                return true;
        }
    }

    /// <summary>Whether a list of the file holds a null element, which SwiftJson does not reject for these types but
    /// Swift's decoder does (Profile's converter rejects its own).</summary>
    private bool HasNullElement() =>
        Repos.Any(repo => repo is null)
        || Windows.Any(window => window is null
            || window.Tabs.Any(tab => tab is null)
            || (window.TabGroups?.Any(group => group is null) ?? false)
            || (window.ClosedTabGroups?.Any(group => group is null || group.Tabs.Any(tab => tab is null)) ?? false));

    /// <summary>The file with untrusted duplicates removed: the first profile of an id, a fresh id for a window whose
    /// id an earlier window has, the first tab group and the first closed group of an id within a window.</summary>
    private WorkspaceFile Normalized()
    {
        var profileIDs = new HashSet<Guid>();
        var windowIDs = new HashSet<Guid>();
        var windows = Windows.Select(window =>
        {
            var id = window.Id;
            if (!windowIDs.Add(id))
            {
                id = Guid.NewGuid();
                windowIDs.Add(id);
            }

            var groupIDs = new HashSet<Guid>();
            var closedIDs = new HashSet<Guid>();
            return window with
            {
                Id = id,
                TabGroups = window.TabGroups?.Where(group => groupIDs.Add(group.Id)).ToList(),
                ClosedTabGroups = window.ClosedTabGroups?.Where(group => closedIDs.Add(group.Id)).ToList(),
            };
        }).ToList();
        return this with { Windows = windows, Profiles = Profiles.Where(profile => profileIDs.Add(profile.Id)).ToList() };
    }

    // Resolving.

    /// <summary>The file in absolute paths. Every key is standardized; dictionaries and sets compare keys as the
    /// flavor does (case-insensitively on Windows).</summary>
    public sealed class Resolved
    {
        /// <summary>The windows in file order.</summary>
        public required IReadOnlyList<LiveWindow> Windows { get; init; }

        /// <summary>The views of the repos that resolved, by absolute path; a repo stored without a view reads as empty.</summary>
        public required IReadOnlyDictionary<string, RepoViewState> Views { get; init; }

        /// <summary>The absolute paths of the tabs that did not resolve ("Repo not found").</summary>
        public required IReadOnlySet<string> Missing { get; init; }

        /// <summary>The <c>repos[]</c> entries that did not resolve, by absolute path, written back verbatim.</summary>
        public required IReadOnlyDictionary<string, Repo> Carried { get; init; }

        /// <summary>The stored strings of every tab and repo by the absolute path it resolved to, or its missing key.</summary>
        public required IReadOnlyDictionary<string, Original> Originals { get; init; }

        /// <summary>The absolute path of each <c>repos[]</c> entry, in file order.</summary>
        public required IReadOnlyList<string> RepoOrder { get; init; }

        /// <summary>The profile ids in file order.</summary>
        public required IReadOnlyList<Guid> ProfileOrder { get; init; }
    }

    /// <summary>
    /// Maps the file saved at <paramref name="filePath"/> to absolute paths: <c>path</c> first (relative to the file's
    /// folder), then <c>home</c> (<c>~</c> meaning <paramref name="homePath"/>); a candidate counts only when
    /// <paramref name="isRepository"/> holds. A tab or repo where neither holds is missing, keyed by its expanded
    /// <c>home</c> when it has one, else by its <c>path</c> against the file's folder. On Windows a stored UNC or device
    /// string is never a candidate, so <paramref name="isRepository"/> and <paramref name="disk"/> never see it.
    /// <paramref name="flavor"/> defaults to the host's; <paramref name="disk"/> to the real file system for the host
    /// flavor, none for another.
    /// </summary>
    public Resolved Resolve(
        string filePath, string homePath, Func<string, bool> isRepository, PathFlavor? flavor = null, WorkspaceDisk? disk = null)
    {
        var paths = new Base(filePath, homePath, flavor, disk);
        var file = Normalized();
        var originals = new Dictionary<string, Original>(paths.Comparer);
        var missing = new HashSet<string>(paths.Comparer);

        // The absolute path of a stored pair and whether it resolved; null when it names no path at all.
        (string Key, bool Found)? ResolvePair(string? path, string? home)
        {
            var candidates = new[]
            {
                path is null || paths.IsRefused(path) ? null : paths.FromPath(path),
                home is null || paths.IsRefused(home) ? null : paths.FromHome(home),
            };
            (string Key, bool Found)? key = candidates.FirstOrDefault(candidate => candidate is not null && isRepository(candidate)) is { } found
                ? (found, true)
                : paths.MissingKey(path, home) is { } absent ? (absent, false) : null;
            if (key is { } entry)
            {
                originals.TryAdd(entry.Key, new Original(path, home));
            }

            return key;
        }

        SavedTab Live(Tab tab)
        {
            var key = ResolvePair(tab.Path, tab.Home);
            if (key is { Found: false } absent)
            {
                missing.Add(absent.Key);
            }

            return new SavedTab(
                key?.Key, tab.Profile, tab.Alias, tab.Emoji, tab.Icon, tab.Pinned, tab.IconColor, tab.Archived, tab.Group);
        }

        var windows = file.Windows.Select(window => new LiveWindow(
            window.Id,
            window.Tabs.Select(Live).ToList(),
            window.TabGroups,
            window.ClosedTabGroups?.Select(group =>
                new SavedClosedTabGroup(group.Id, group.Color, group.Tabs.Select(Live).ToList(), group.Name)).ToList()))
            .ToList();

        var views = new Dictionary<string, RepoViewState>(paths.Comparer);
        var carried = new Dictionary<string, Repo>(paths.Comparer);
        var repoOrder = new List<string>();
        foreach (var repo in file.Repos)
        {
            if (ResolvePair(repo.Path, repo.Home) is not { } key || views.ContainsKey(key.Key) || carried.ContainsKey(key.Key))
            {
                continue;
            }

            repoOrder.Add(key.Key);
            if (key.Found)
            {
                views[key.Key] = repo.View ?? RepoViewState.Empty;
            }
            else
            {
                carried[key.Key] = repo;
            }
        }

        return new Resolved
        {
            Windows = windows,
            Views = views,
            Missing = missing,
            Carried = carried,
            Originals = originals,
            RepoOrder = repoOrder,
            ProfileOrder = file.Profiles.Select(profile => profile.Id).ToList(),
        };
    }

    // Building.

    /// <summary>
    /// Builds the file saved at <paramref name="filePath"/> from absolute paths. A path in <paramref name="originals"/>
    /// keeps its stored strings; any other gets fresh ones: <c>path</c> relative to the file's folder (written with
    /// <c>/</c>; the absolute path when no relative one exists, as for another drive), <c>home</c> as <c>~/...</c>
    /// under <paramref name="homePath"/>, else absolute. <c>repos</c> holds one entry per key of
    /// <paramref name="views"/> and <paramref name="carried"/> (a live view wins), in <paramref name="repoOrder"/>, new
    /// ones appended sorted by <c>path</c>; <c>profiles</c> follow <paramref name="profileOrder"/>, new ones appended
    /// sorted by id.
    /// </summary>
    public static WorkspaceFile Build(
        IReadOnlyList<LiveWindow> windows, IReadOnlyDictionary<string, RepoViewState> views, IReadOnlyList<Profile> profiles,
        IReadOnlyDictionary<string, Repo> carried, IReadOnlyDictionary<string, Original> originals,
        IReadOnlyList<string> repoOrder, IReadOnlyList<Guid> profileOrder, string filePath, string homePath,
        PathFlavor? flavor = null, WorkspaceDisk? disk = null)
    {
        var paths = new Base(filePath, homePath, flavor, disk);
        var known = new Dictionary<string, Original>(paths.Comparer);
        foreach (var (key, original) in originals)
        {
            known.TryAdd(key, original);
        }

        Original Stored(string absolute)
        {
            var key = paths.Flavor.Standardized(absolute);
            return known.TryGetValue(key, out var original) ? original : paths.Fresh(key);
        }

        Tab FileTab(SavedTab tab)
        {
            var strings = tab.Path is null ? null : Stored(tab.Path);
            return new Tab(
                strings?.Path, strings?.Home, tab.Profile, tab.Alias, tab.Emoji, tab.Icon, tab.Pinned, tab.IconColor,
                tab.Archived, tab.TabGroup);
        }

        var fileWindows = windows.Select(window => new Window(
            window.Id,
            window.Tabs.Select(FileTab).ToList(),
            window.TabGroups is { Count: > 0 } ? window.TabGroups : null,
            window.ClosedTabGroups is { Count: > 0 }
                ? window.ClosedTabGroups.Select(group =>
                    new ClosedTabGroup(group.Id, group.Color, group.Tabs.Select(FileTab).ToList(), group.Name)).ToList()
                : null))
            .ToList();

        var repos = new Dictionary<string, Repo>(paths.Comparer);
        foreach (var (key, repo) in carried)
        {
            repos[paths.Flavor.Standardized(key)] = repo;
        }

        foreach (var (key, view) in views)
        {
            var strings = Stored(key);
            repos[paths.Flavor.Standardized(key)] = new Repo(strings.Path, strings.Home, view);
        }

        var ordered = new List<Repo>();
        foreach (var key in repoOrder)
        {
            if (repos.Remove(paths.Flavor.Standardized(key), out var repo))
            {
                ordered.Add(repo);
            }
        }

        ordered.AddRange(repos.Values
            .OrderBy(repo => repo.Path ?? "", Comparer<string>.Create(SwiftJson.CompareScalars))
            .ThenBy(repo => repo.Home ?? "", Comparer<string>.Create(SwiftJson.CompareScalars)));

        var byID = new Dictionary<Guid, Profile>();
        foreach (var profile in profiles)
        {
            byID.TryAdd(profile.Id, profile);
        }

        var orderedProfiles = new List<Profile>();
        foreach (var id in profileOrder)
        {
            if (byID.Remove(id, out var profile))
            {
                orderedProfiles.Add(profile);
            }
        }

        orderedProfiles.AddRange(byID.Values.OrderBy(profile => profile.Id.ToString("D").ToUpperInvariant(), StringComparer.Ordinal));

        return new WorkspaceFile(fileWindows, ordered, orderedProfiles);
    }

    /// <summary>
    /// The stored strings for a workspace saved again at <paramref name="filePath"/> (Save As): the entries of resolved
    /// paths are dropped (they get fresh strings), and each missing tab and carried repo keeps its <c>home</c> and gets
    /// a <c>path</c> from its absolute path relative to the new folder. Only the keys in <paramref name="missing"/> stay
    /// in <c>Originals</c>.
    /// </summary>
    public static (IReadOnlyDictionary<string, Original> Originals, IReadOnlyDictionary<string, Repo> Carried) Rebased(
        IReadOnlyDictionary<string, Original> originals, IReadOnlySet<string> missing, IReadOnlyDictionary<string, Repo> carried,
        string filePath, string homePath, PathFlavor? flavor = null, WorkspaceDisk? disk = null)
    {
        var paths = new Base(filePath, homePath, flavor, disk);
        var missingKeys = new HashSet<string>(missing, paths.Comparer);
        var newOriginals = new Dictionary<string, Original>(paths.Comparer);
        foreach (var (key, original) in originals)
        {
            if (missingKeys.Contains(key))
            {
                newOriginals[key] = new Original(paths.Relative(key), original.Home);
            }
        }

        var newCarried = new Dictionary<string, Repo>(paths.Comparer);
        foreach (var (key, repo) in carried)
        {
            newCarried[key] = repo with { Path = paths.Relative(key) };
        }

        return (newOriginals, newCarried);
    }

    // Writing.

    /// <summary>
    /// Writes the file to <paramref name="path"/>, or to its target when it is a symlink, atomically (a temp file in the
    /// same folder, then a rename over it), with mode 600 off Windows. Throws <see cref="WorkspaceFileError"/> of kind
    /// <see cref="WorkspaceFileErrorKind.Empty"/> for no window or a window with no tab.
    /// </summary>
    public void Write(string path)
    {
        if (Windows.Count == 0 || Windows.Any(window => window.Tabs.Count == 0))
        {
            throw WorkspaceFileError.Empty();
        }

        var data = SwiftJson.Serialize(this, SwiftJsonFormatting.PrettyPrinted | SwiftJsonFormatting.SortedKeys);
        var flavor = PathFlavor.Host;
        var file = IdentityKey(path);
        var temp = flavor.Resolve(
            flavor.Parent(file), $".{flavor.LastComponent(file)}.{Guid.NewGuid().ToString("D").ToUpperInvariant()}.tmp");
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows())
        {
            options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        }

        try
        {
            using (var stream = new FileStream(temp, options))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temp, file, overwrite: true);
        }
        catch
        {
            try
            {
                File.Delete(temp);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
            }

            throw;
        }
    }

    /// <summary>
    /// The file's folder and the home folder, for mapping stored strings to absolute paths and back. The folder is the
    /// lexical (standardized, not real) parent of the file after following only the file's own symlinks, so a symlinked
    /// file uses its target's folder and resolved keys stay in the app's path space when an ancestor folder is a
    /// symlink.
    /// </summary>
    private sealed class Base
    {
        private readonly GuardedDisk _disk;
        private readonly string _folder;
        private readonly string _home;

        public Base(string filePath, string homePath, PathFlavor? flavor, WorkspaceDisk? disk)
        {
            Flavor = flavor ?? PathFlavor.Host;
            _disk = new GuardedDisk(Flavor, disk ?? (Flavor == PathFlavor.Host ? WorkspaceDisk.Host : WorkspaceDisk.None));
            var path = Flavor.Standardized(filePath);
            for (var hop = 0; hop < 16; hop++)
            {
                if (_disk.LinkTarget(path) is not { } target)
                {
                    break;
                }

                path = Flavor.Resolve(Flavor.Parent(path), target);
            }

            _folder = Flavor.Parent(path);
            _home = Flavor.Standardized(homePath);
        }

        public PathFlavor Flavor { get; }

        public StringComparer Comparer => Flavor.KeyComparer;

        /// <summary>A stored string that never becomes a candidate: a UNC or device path on Windows.</summary>
        public bool IsRefused(string stored) => Flavor.IsUncOrDevice(stored);

        /// <summary>A stored <c>path</c>: <c>~</c> is the home folder, an absolute path stays, anything else is under
        /// the file's folder.</summary>
        public string FromPath(string path) => Flavor.ExpandHome(_home, path) ?? Flavor.Resolve(_folder, path);

        /// <summary>A stored <c>home</c>: only <c>~</c>, <c>~/...</c> or an absolute path; null for anything else.</summary>
        public string? FromHome(string home) =>
            Flavor.ExpandHome(_home, home) ?? (Flavor.IsAbsolute(home) ? Flavor.Standardized(home) : null);

        /// <summary>The key of a pair that did not resolve; string work only, never the file system.</summary>
        public string? MissingKey(string? path, string? home) =>
            (home is null ? null : FromHome(home)) ?? (path is null ? null : FromPath(path));

        /// <summary>Fresh strings for an absolute path.</summary>
        public Original Fresh(string absolute) => new(Relative(absolute), Flavor.Tilde(_home, absolute));

        /// <summary>
        /// <paramref name="absolute"/> relative to the file's folder, by components; <c>.</c> for the folder itself.
        /// The standardized forms are compared, so a symlink inside the shared tree is kept as written. Only when they
        /// share no more than the root are their real paths compared instead, when both exist and share more. With no
        /// relative form at all (another drive or share), the absolute path.
        /// </summary>
        public string Relative(string absolute)
        {
            var target = Flavor.Standardized(absolute);
            var lexical = Flavor.RelativeWithCommon(_folder, target);
            if (lexical.Common <= 1 && _disk.RealPath(_folder) is { } realFolder && _disk.RealPath(target) is { } realTarget)
            {
                var real = Flavor.RelativeWithCommon(realFolder, realTarget);
                if (real.Common > 1)
                {
                    return real.Path!;
                }
            }

            return lexical.Path ?? target;
        }
    }

    /// <summary>A <see cref="WorkspaceDisk"/> that never sees a UNC or device path on Windows.</summary>
    private sealed class GuardedDisk(PathFlavor flavor, WorkspaceDisk disk)
    {
        public string? RealPath(string path) => flavor.IsUncOrDevice(path) ? null : disk.RealPath(path);

        public string? LinkTarget(string path) => flavor.IsUncOrDevice(path) ? null : disk.LinkTarget(path);
    }
}

/// <summary>
/// The file-system calls workspace paths make besides the existence check: the real path of an existing path (every
/// symlink in it resolved; null when it does not exist) and the target of a symlink as stored (null when the path is
/// not one). <see cref="Host"/> is the real file system, <see cref="None"/> makes no call.
/// </summary>
public sealed record WorkspaceDisk(Func<string, string?> RealPath, Func<string, string?> LinkTarget)
{
    public static WorkspaceDisk Host { get; } = new(HostRealPath, HostLinkTarget);

    public static WorkspaceDisk None { get; } = new(_ => null, _ => null);

    private static string? HostLinkTarget(string path)
    {
        try
        {
            return new FileInfo(path).LinkTarget;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>Resolves the links of <paramref name="path"/> component by component, as realpath(3); at most 40 links.</summary>
    private static string? HostRealPath(string path)
    {
        var flavor = PathFlavor.Host;
        var pending = flavor.Standardized(path);
        if (!Path.Exists(pending))
        {
            return null;
        }

        for (var hops = 0; hops <= 40; hops++)
        {
            var (root, parts) = flavor.RootAndParts(pending);
            var current = root;
            string? relinked = null;
            for (var index = 0; index < parts.Count && relinked is null; index++)
            {
                current = flavor.Resolve(current, parts[index]);
                if (HostLinkTarget(current) is { } target)
                {
                    var rest = string.Join('/', parts.Skip(index + 1));
                    relinked = flavor.Resolve(flavor.Resolve(flavor.Parent(current), target), rest);
                    if (flavor.IsUncOrDevice(relinked))
                    {
                        return null;
                    }
                }
            }

            if (relinked is null)
            {
                return flavor.Standardized(current);
            }

            pending = relinked;
        }

        return null;
    }
}

/// <summary>Why a workspace file was refused.</summary>
public enum WorkspaceFileErrorKind
{
    /// <summary>The file is not a workspace this build can decode.</summary>
    Undecodable,

    /// <summary>The file has another <c>version</c> (<see cref="WorkspaceFileError.Version"/>).</summary>
    UnsupportedVersion,

    /// <summary>A workspace is never written with no window, or with a window that has no tab.</summary>
    Empty,
}

/// <summary>A workspace file that cannot be read or written. Equal when the kind and version are equal.</summary>
public sealed class WorkspaceFileError : Exception, IEquatable<WorkspaceFileError>
{
    private WorkspaceFileError(WorkspaceFileErrorKind kind, int? version, string message)
        : base(message)
    {
        Kind = kind;
        Version = version;
    }

    public WorkspaceFileErrorKind Kind { get; }

    /// <summary>The file's version for <see cref="WorkspaceFileErrorKind.UnsupportedVersion"/>, else null.</summary>
    public int? Version { get; }

    public static WorkspaceFileError Undecodable() =>
        new(WorkspaceFileErrorKind.Undecodable, null, "The file is not a workspace.");

    public static WorkspaceFileError UnsupportedVersion(int version) =>
        new(WorkspaceFileErrorKind.UnsupportedVersion, version, $"The workspace has version {version}; this build reads version {WorkspaceFile.CurrentVersion}.");

    public static WorkspaceFileError Empty() =>
        new(WorkspaceFileErrorKind.Empty, null, "A workspace needs a window with a tab.");

    public bool Equals(WorkspaceFileError? other) => other is not null && Kind == other.Kind && Version == other.Version;

    public override bool Equals(object? obj) => Equals(obj as WorkspaceFileError);

    public override int GetHashCode() => HashCode.Combine(Kind, Version);
}

/// <summary>
/// The machine-local layout of an open or recently closed workspace, kept in <c>session.json</c>: window frames, native
/// tab groups, selection and collapsed manual groups, so arranging windows never rewrites the shared file.
/// </summary>
/// <param name="Path">The workspace file's identity key (<see cref="WorkspaceFile.IdentityKey"/>).</param>
/// <param name="Open">The workspace was open when the app quit, so the next launch reopens it.</param>
public sealed record WorkspaceLayout(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("open")] bool Open,
    [property: JsonPropertyName("windows")] IReadOnlyList<WorkspaceLayout.Window> Windows)
{
    public bool Equals(WorkspaceLayout? other) =>
        other is not null && string.Equals(Path, other.Path, StringComparison.Ordinal) && Open == other.Open
        && Windows.SequenceEqual(other.Windows);

    public override int GetHashCode() => HashCode.Combine(StringComparer.Ordinal.GetHashCode(Path), Open, Windows.Count);

    /// <summary>A workspace window by its id in the file.</summary>
    /// <param name="X">Screen points, as <see cref="SavedWindow"/>.</param>
    /// <param name="Group">The native tab group, numbered with the Untitled windows' groups.</param>
    /// <param name="SelectedPath">The selected tab's absolute repo path; null for a Welcome tab or none.</param>
    /// <param name="CollapsedGroups">The ids of the window's collapsed manual tab groups; null when none.</param>
    public sealed record Window(
        [property: JsonPropertyName("id")] Guid Id,
        [property: JsonPropertyName("x")] double X,
        [property: JsonPropertyName("y")] double Y,
        [property: JsonPropertyName("width")] double Width,
        [property: JsonPropertyName("height")] double Height,
        [property: JsonPropertyName("group")] int Group,
        [property: JsonPropertyName("tabIndex")] int TabIndex,
        [property: JsonPropertyName("isSelectedInGroup")] bool IsSelectedInGroup,
        [property: JsonPropertyName("selectedPath")] string? SelectedPath = null,
        [property: JsonPropertyName("collapsedGroups")] IReadOnlyList<Guid>? CollapsedGroups = null)
    {
        public bool Equals(Window? other) =>
            other is not null && Id == other.Id && X.Equals(other.X) && Y.Equals(other.Y) && Width.Equals(other.Width)
            && Height.Equals(other.Height) && Group == other.Group && TabIndex == other.TabIndex
            && IsSelectedInGroup == other.IsSelectedInGroup
            && string.Equals(SelectedPath, other.SelectedPath, StringComparison.Ordinal)
            && SequenceEquality.Equal(CollapsedGroups, other.CollapsedGroups);

        public override int GetHashCode() => HashCode.Combine(Id, X, Y, Width, Height, Group, TabIndex);
    }
}

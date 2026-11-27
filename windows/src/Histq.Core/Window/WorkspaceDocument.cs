// An open workspace file (`*.histqws`): everything capture needs to write the file back as it was read: the stored path
// strings, the repos and profiles in file order, the repos that did not resolve, the graph views and the embedded
// profiles. The file is read and resolved off the UI thread (Open is synchronous; the app runs it on a worker). Ported
// from Workspace.swift at 6fa6d40; the profile baseline (it needs the profile library) and the pre-close snapshot stay
// in the app.
namespace Histq.Core;

/// <summary>One open workspace. Its windows point to it; capture builds its <see cref="WorkspaceFile"/> from them and
/// the state kept here, so an unchanged workspace writes the same model it was read as. Keys compare as the host's
/// paths do (case-insensitively on Windows).</summary>
public sealed class WorkspaceDocument
{
    /// <summary>The largest file <see cref="Open"/> reads.</summary>
    public const int MaxFileSize = 8 * 1024 * 1024;

    /// <summary>A workspace this build just wrote to <paramref name="filePath"/> (New Workspace, Save As from Untitled
    /// windows): writable, with no stored strings, carried repos, views or embedded profiles yet.</summary>
    public WorkspaceDocument(string filePath)
        : this(filePath, WorkspaceFile.IdentityKey(filePath), isReadOnly: false, [], [], [], [], [], [], [], [])
    {
    }

    private WorkspaceDocument(
        string filePath, string key, bool isReadOnly, IEnumerable<Profile> profiles,
        IEnumerable<KeyValuePair<string, WorkspaceFile.Original>> originals, IEnumerable<string> repoOrder,
        IEnumerable<Guid> profileOrder, IEnumerable<Guid> windowOrder,
        IEnumerable<KeyValuePair<string, WorkspaceFile.Repo>> repos, IEnumerable<string> missing,
        IEnumerable<KeyValuePair<string, RepoViewState>> views)
    {
        var comparer = PathFlavor.Host.KeyComparer;
        FilePath = filePath;
        Key = key;
        Name = NameOf(filePath);
        IsReadOnly = isReadOnly;
        Profiles = [.. profiles];
        Originals = new(originals, comparer);
        RepoOrder = [.. repoOrder];
        ProfileOrder = [.. profileOrder];
        WindowOrder = [.. windowOrder];
        Repos = new(repos, comparer);
        Missing = new(missing, comparer);
        Views = new(views, comparer);
    }

    /// <summary>A workspace as <see cref="Open"/> read it: the document, the file in absolute paths (each window with
    /// a tab), and the repo key (<see cref="RepoGroupKey"/>) of every resolved tab by its absolute path.</summary>
    public sealed record Opened(
        WorkspaceDocument Document, WorkspaceFile.Resolved Resolved, IReadOnlyDictionary<string, string> RepoKeys);

    /// <summary>A Save As target computed off the UI thread (<see cref="Rebound"/>): the new file, its identity key and
    /// the stored strings rebased to its folder.</summary>
    public sealed record Rebinding(
        string FilePath, string Key, IReadOnlyDictionary<string, WorkspaceFile.Original> Originals,
        IReadOnlyDictionary<string, WorkspaceFile.Repo> Carried);

    public string FilePath { get; private set; }

    /// <summary>The file's identity key (<see cref="WorkspaceFile.IdentityKey"/>).</summary>
    public string Key { get; private set; }

    /// <summary>The file name without its extension.</summary>
    public string Name { get; private set; }

    /// <summary>The file has keys this build would drop (<see cref="WorkspaceFile.ReadResult.IsLossless"/> false): it
    /// is never written. Save As makes a writable copy.</summary>
    public bool IsReadOnly { get; private set; }

    /// <summary>Close Workspace is under way: closing its windows captures nothing.</summary>
    public bool IsClosing { get; set; }

    /// <summary>The last write of the file failed; cleared by the next successful one.</summary>
    public bool WriteFailed { get; private set; }

    /// <summary>Why the last write failed (shown in the command bar); null once a write succeeds.</summary>
    public string? WriteError { get; private set; }

    /// <summary>The profiles embedded in the file, as read.</summary>
    public List<Profile> Profiles { get; }

    /// <summary>The stored <c>path</c> / <c>home</c> strings by absolute path (<see cref="WorkspaceFile.Resolved.Originals"/>).</summary>
    public Dictionary<string, WorkspaceFile.Original> Originals { get; private set; }

    /// <summary>The absolute path of each repo, in file order; repos added later are appended.</summary>
    public List<string> RepoOrder { get; }

    /// <summary>The profile ids in file order; profiles added later are appended.</summary>
    public List<Guid> ProfileOrder { get; }

    /// <summary>The window ids in file order; windows added later are appended.</summary>
    public List<Guid> WindowOrder { get; }

    /// <summary>The <c>repos[]</c> entries that did not resolve, by absolute path, written back verbatim.</summary>
    public Dictionary<string, WorkspaceFile.Repo> Repos { get; private set; }

    /// <summary>The absolute paths of the tabs that did not resolve ("Repo not found").</summary>
    public HashSet<string> Missing { get; }

    /// <summary>The graph views by absolute repo path: those read from the file, then each tab's as it is first shown
    /// or changes (<see cref="SetView"/>).</summary>
    public Dictionary<string, RepoViewState> Views { get; }

    /// <summary>The folder <c>~</c> stands for in the file's <c>home</c> strings.</summary>
    public static string HomePath => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>
    /// Reads and resolves the file at <paramref name="filePath"/> (call it off the UI thread). The file is read from one
    /// stream and refused past <see cref="MaxFileSize"/> bytes before it is parsed. Its paths are untrusted: a repo
    /// counts only when <paramref name="isRepository"/> holds (default <see cref="SavedSession.IsRepository(string)"/>,
    /// which never probes a UNC or device path). A window with no tab is dropped; a file left with no window gets one
    /// with a Welcome tab. Throws <see cref="WorkspaceTooLargeException"/>, <see cref="WorkspaceFileError"/> and the
    /// read's IO errors.
    /// </summary>
    public static Opened Open(string filePath, string? homePath = null, Func<string, bool>? isRepository = null)
    {
        var key = WorkspaceFile.IdentityKey(filePath);
        byte[] data;
        using (var stream = new FileStream(key, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            data = ReadCapped(stream);
        }

        var read = WorkspaceFile.Decode(data);
        var resolved = read.File.Resolve(filePath, homePath ?? HomePath, isRepository ?? SavedSession.IsRepository);
        var windows = resolved.Windows.Where(window => window.Tabs.Count > 0).ToList();
        if (windows.Count == 0)
        {
            windows.Add(new WorkspaceFile.LiveWindow(Guid.NewGuid(), [new SavedTab()]));
        }

        resolved = new WorkspaceFile.Resolved
        {
            Windows = windows,
            Views = resolved.Views,
            Missing = resolved.Missing,
            Carried = resolved.Carried,
            Originals = resolved.Originals,
            RepoOrder = resolved.RepoOrder,
            ProfileOrder = resolved.ProfileOrder,
        };

        var repoKeys = new Dictionary<string, string>(PathFlavor.Host.KeyComparer);
        foreach (var path in windows.SelectMany(window => window.Tabs).Select(tab => tab.Path).OfType<string>())
        {
            if (!resolved.Missing.Contains(path) && !repoKeys.ContainsKey(path) && RepoGroupKey.Of(path) is { } repoKey)
            {
                repoKeys[path] = repoKey;
            }
        }

        var document = new WorkspaceDocument(
            filePath, key, !read.IsLossless, read.File.Profiles, resolved.Originals, resolved.RepoOrder,
            resolved.ProfileOrder, windows.Select(window => window.Id), resolved.Carried, resolved.Missing, resolved.Views);
        return new Opened(document, resolved, repoKeys);
    }

    /// <summary>Every byte of <paramref name="stream"/>, read in chunks; throws <see cref="WorkspaceTooLargeException"/>
    /// as soon as it passes <see cref="MaxFileSize"/>, whatever the stream says its length is.</summary>
    internal static byte[] ReadCapped(Stream stream)
    {
        if (stream.CanSeek && stream.Length > MaxFileSize)
        {
            throw new WorkspaceTooLargeException();
        }

        using var memory = new MemoryStream();
        var chunk = new byte[81920];
        int count;
        while ((count = stream.Read(chunk)) > 0)
        {
            if (memory.Length + count > MaxFileSize)
            {
                throw new WorkspaceTooLargeException();
            }

            memory.Write(chunk, 0, count);
        }

        return memory.ToArray();
    }

    /// <summary>A tab moved in from another workspace with a profile this machine does not have: the file embeds
    /// <paramref name="profile"/>'s definition too. An id embedded already stays.</summary>
    public void AdoptProfile(Profile profile)
    {
        if (Profiles.Exists(embedded => embedded.Id == profile.Id))
        {
            return;
        }

        Profiles.Add(profile);
        if (!ProfileOrder.Contains(profile.Id))
        {
            ProfileOrder.Add(profile.Id);
        }
    }

    /// <summary>The graph view the workspace has for the repo at <paramref name="repoPath"/>; null when it has none.</summary>
    public RepoViewState? View(string repoPath) =>
        Views.TryGetValue(PathFlavor.Host.Standardized(repoPath), out var view) ? view : null;

    /// <summary>Sets the graph view of the repo at <paramref name="repoPath"/>; false when it was that already. The
    /// app schedules a save on true.</summary>
    public bool SetView(RepoViewState view, string repoPath)
    {
        var key = PathFlavor.Host.Standardized(repoPath);
        if (Views.TryGetValue(key, out var current) && current.Equals(view))
        {
            return false;
        }

        Views[key] = view;
        return true;
    }

    /// <summary>The outcome of a write of the file (<see cref="SessionStore.WriteResult"/>): an error sets
    /// <see cref="WriteFailed"/> and <see cref="WriteError"/>, a success clears them.</summary>
    public void RecordWrite(Exception? error)
    {
        WriteFailed = error is not null;
        WriteError = error?.Message;
    }

    /// <summary>Points the workspace at <paramref name="filePath"/> after Save As: the resolved paths get fresh strings
    /// relative to the new folder, the missing tabs and carried repos keep their <c>home</c> with a <c>path</c> from the
    /// new folder, and the new file is writable.</summary>
    public void Rebind(string filePath, string? homePath = null) => Rebind(Rebound(filePath, homePath));

    /// <summary>What <see cref="Rebind(string, string?)"/> sets for <paramref name="filePath"/>: the new identity key and
    /// the rebased stored strings. Reads the disk (call it off the UI thread, on a <see cref="Copy"/>); the document is
    /// not changed.</summary>
    public Rebinding Rebound(string filePath, string? homePath = null)
    {
        var (originals, carried) = WorkspaceFile.Rebased(Originals, Missing, Repos, filePath, homePath ?? HomePath);
        return new Rebinding(filePath, WorkspaceFile.IdentityKey(filePath), originals, carried);
    }

    /// <summary>Points the workspace at <paramref name="rebinding"/>'s file (<see cref="Rebound"/>), with no I/O.</summary>
    public void Rebind(Rebinding rebinding)
    {
        FilePath = rebinding.FilePath;
        Key = rebinding.Key;
        Name = NameOf(rebinding.FilePath);
        Originals = new(rebinding.Originals, PathFlavor.Host.KeyComparer);
        Repos = new(rebinding.Carried, PathFlavor.Host.KeyComparer);
        IsReadOnly = false;
        RecordWrite(null);
    }

    /// <summary>A copy of the document's state, for work off the UI thread (Save As builds and rebases on it) while the
    /// UI thread keeps the document.</summary>
    public WorkspaceDocument Copy() =>
        new(FilePath, Key, IsReadOnly, Profiles, Originals, RepoOrder, ProfileOrder, WindowOrder, Repos, Missing, Views);

    /// <summary>
    /// The workspace file as <paramref name="windows"/> have it now (their tabs and manual groups), saved at
    /// <paramref name="filePath"/> (default <see cref="FilePath"/>) with these stored strings and carried repos (default
    /// the document's): the stored strings of every unchanged path, the graph view of each tab's repo (closed groups'
    /// and archived tabs' too; a repo with no view gets no entry), and the embedded profiles the tabs use (this build
    /// has no profile library: an id the file does not embed is not written). Building may read the disk (the file's
    /// own links, a real path for another drive).
    /// </summary>
    public WorkspaceFile Build(
        IReadOnlyList<WorkspaceFile.LiveWindow> windows, string? filePath = null,
        IReadOnlyDictionary<string, WorkspaceFile.Original>? originals = null,
        IReadOnlyDictionary<string, WorkspaceFile.Repo>? carried = null, string? homePath = null)
    {
        var flavor = PathFlavor.Host;
        var tabs = windows.SelectMany(window =>
            window.Tabs.Concat((window.ClosedTabGroups ?? []).SelectMany(group => group.Tabs))).ToList();
        var used = tabs.Select(tab => tab.Profile?.ProfileId).OfType<Guid>().ToHashSet();
        var paths = tabs.Select(tab => tab.Path).OfType<string>().Select(path => flavor.Standardized(path))
            .ToHashSet(flavor.KeyComparer);
        var views = new Dictionary<string, RepoViewState>(flavor.KeyComparer);
        foreach (var (path, view) in Views)
        {
            if (paths.Contains(flavor.Standardized(path)))
            {
                views[path] = view;
            }
        }

        return WorkspaceFile.Build(
            windows, views, Profiles.Where(profile => used.Contains(profile.Id)).ToList(), carried ?? Repos,
            originals ?? Originals, RepoOrder, ProfileOrder, filePath ?? FilePath, homePath ?? HomePath);
    }

    private static string NameOf(string filePath) =>
        Path.GetFileNameWithoutExtension(PathFlavor.Host.LastComponent(filePath));
}

/// <summary>A file refused before it is parsed: larger than <see cref="WorkspaceDocument.MaxFileSize"/>, which no
/// workspace is.</summary>
public sealed class WorkspaceTooLargeException() : IOException("The file is too large to be a Histq workspace.");

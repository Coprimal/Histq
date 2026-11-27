// Session restore: the windows and their app tabs, saved as `session.json` under StatePaths.Root a second after each
// change and once more at quit (Flush), and read back off the UI thread at the next launch. A repo folder that is gone
// (or no longer a git repository) comes back as a "Repo not found" tab. The same writer saves every open workspace file,
// each before `session.json`. UI-free: the app hands it a capture of its windows. Ported from SessionStore.swift at
// 6fa6d40 (the AppKit frame helper and the launch-time load task stay in the app).
using System.Diagnostics;
using System.Text.Json;

namespace Histq.Core;

/// <summary>
/// Writes the session and every open workspace file on changes. Capture is off until <see cref="Start"/> (the launch has
/// opened its windows) and stops for good at <see cref="Flush"/> (quit): the closing windows must not save an empty
/// session (or fewer workspace windows) over the one quit wrote. Call it from one thread, the UI thread: the debounce
/// and <see cref="WriteResult"/> run on the <see cref="SynchronizationContext"/> it was made on (inline when there is
/// none), so capture reads the windows there; the writes run in call order off it, on one serial chain.
/// </summary>
public sealed class SessionStore
{
    public const string FileName = "session.json";

    /// <summary>How long after the last change a save runs.</summary>
    public static readonly TimeSpan Debounce = TimeSpan.FromSeconds(1);

    private readonly Func<TimeSpan, Action, IDisposable> delay;
    private readonly SynchronizationContext? context;

    /// <summary>Workspaces <see cref="Finish"/> wrote for the last time: no later pass writes them, until
    /// <see cref="Seed"/> or <see cref="WriteNow"/> opens the key again.</summary>
    private readonly HashSet<string> finished = new(PathFlavor.Host.KeyComparer);

    /// <summary>The last model written (or seeded) per workspace identity key, so an unchanged file is not written
    /// again. Only touched on the writer chain.</summary>
    private readonly Dictionary<string, WorkspaceFile> written = new(PathFlavor.Host.KeyComparer);

    /// <summary>The workspace keys whose last write failed, so a pass that finds the file back at its last written
    /// model (and skips it) still reports the success. Only touched on the writer chain.</summary>
    private readonly HashSet<string> failed = new(PathFlavor.Host.KeyComparer);

    private Func<Snapshot>? capture;
    private IDisposable? pending;
    private int generation;
    private bool isQuitting;
    private Task writer = Task.CompletedTask;

    /// <param name="sessionFile">The <c>session.json</c> to write (<see cref="In"/>).</param>
    /// <param name="delay">Runs an action once after a delay and cancels it on dispose; tests pass a manual clock.
    /// Null: a timer whose action runs on the current <see cref="SynchronizationContext"/>.</param>
    public SessionStore(string sessionFile, Func<TimeSpan, Action, IDisposable>? delay = null)
    {
        SessionFile = sessionFile;
        context = SynchronizationContext.Current;
        this.delay = delay ?? DelayOnContext;
    }

    /// <summary>A saved session read at launch, with the repo folders that are gone or no longer git repositories.</summary>
    public sealed record Loaded(SavedSession Session, IReadOnlySet<string> Missing);

    /// <summary>What capture returns: the session, and each open workspace's file by its identity key
    /// (<see cref="WorkspaceFile.IdentityKey"/>) with whether it is read-only (never written).</summary>
    public sealed record Snapshot(
        SavedSession Session, IReadOnlyDictionary<string, (WorkspaceFile File, bool IsReadOnly)> Workspaces);

    /// <summary>One write pass: the writable workspace files by identity key, then the session.</summary>
    private sealed record Pass(IReadOnlyList<(string Key, WorkspaceFile File)> Workspaces, SavedSession Session);

    public string SessionFile { get; }

    /// <summary>Each workspace write's outcome by identity key (null on success), on the store's context. Skipped files
    /// (unchanged, read-only, no window) report nothing, but an unchanged one whose last write failed reports success:
    /// the file holds that content.</summary>
    public Action<string, Exception?>? WriteResult { get; set; }

    /// <summary>A failed write of <c>session.json</c>. Called on the writer thread, not the store's context, so a failure
    /// during <see cref="Flush"/> (quit) is reported before Flush returns; the handler must be thread-safe.</summary>
    public Action<Exception>? SessionWriteFailed { get; set; }

    /// <summary>The writes queued so far; tests wait on it.</summary>
    internal Task Writes => writer;

    /// <summary><c>session.json</c> in the state folder.</summary>
    public static string In(StatePaths paths) => Path.Combine(paths.Root, FileName);

    /// <summary>
    /// The session saved in <paramref name="file"/>; null when there is none, it cannot be decoded, it has another
    /// version, or it has neither a window nor a workspace. Reads the disk: call it off the UI thread. The tabs' folders
    /// are the user's own, so a UNC one is checked too (<see cref="SavedSession.IsUserRepository"/>).
    /// </summary>
    public static Loaded? Load(string file) => Load(file, SavedSession.IsUserRepository);

    /// <summary><see cref="Load(string)"/> with the given repository check.</summary>
    internal static Loaded? Load(string file, Func<string, bool> isRepository)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(file);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        SavedSession decoded;
        try
        {
            decoded = SavedSession.Decode(data);
        }
        catch (Exception error) when (error is JsonException or NotSupportedException or InvalidOperationException)
        {
            Debug.WriteLine("session.json ignored: unreadable");
            return null;
        }

        if (decoded.Version != SavedSession.CurrentVersion)
        {
            Debug.WriteLine("session.json ignored: another version");
            return null;
        }

        var session = decoded.Normalized();
        // Closing the last window saves an empty session: a normal state, not a broken file.
        if (session.Windows.Count == 0 && session.Workspaces is null)
        {
            return null;
        }

        var paths = session.Windows.SelectMany(window => window.Tabs).Select(tab => tab.Path).OfType<string>()
            .ToHashSet(PathFlavor.Host.KeyComparer);
        paths.RemoveWhere(path => isRepository(path));
        return new Loaded(session, paths);
    }

    /// <summary>Turns capture on with <paramref name="capture"/> as the source; the launch calls it once its windows
    /// are open.</summary>
    public void Start(Func<Snapshot> capture) => this.capture = capture;

    /// <summary>Saves the session and the open workspaces <see cref="Debounce"/> after the last change, so a crash or a
    /// kill still finds a recent one.</summary>
    public void Schedule()
    {
        if (capture is null || isQuitting)
        {
            return;
        }

        pending?.Dispose();
        var ticket = ++generation;
        pending = delay(Debounce, () =>
        {
            if (ticket != generation || isQuitting || capture is null)
            {
                return;
            }

            pending = null;
            Enqueue(WritePass(capture()));
        });
    }

    /// <summary>Quit: stops the debounced writer and saves every changed file while the windows are still open,
    /// waiting for the writes. Later calls do nothing.</summary>
    public void Flush()
    {
        if (isQuitting)
        {
            return;
        }

        isQuitting = true;
        generation++;
        pending?.Dispose();
        pending = null;
        if (capture is null)
        {
            return;
        }

        Enqueue(WritePass(capture())).Wait();
    }

    /// <summary>Close Workspace: writes the workspace <paramref name="key"/> one last time (skipped when unchanged),
    /// with the other changed files, then forgets it. A second call, or one during quit, does nothing.</summary>
    public void Finish(string key)
    {
        if (isQuitting || finished.Contains(key) || capture is null)
        {
            return;
        }

        var pass = WritePass(capture());
        finished.Add(key);
        Enqueue(() =>
        {
            Write(pass);
            written.Remove(key);
        });
    }

    /// <summary>The model an open workspace's restored windows capture as, so its file is written only once it
    /// changes.</summary>
    public void Seed(string key, WorkspaceFile file)
    {
        finished.Remove(key);
        Enqueue(() => written[key] = file);
    }

    /// <summary>Writes <paramref name="file"/> to <paramref name="path"/> now, on the writer chain, throwing its error
    /// (Save As, New Workspace). On success the model is cached, so the first capture of the workspace does not write
    /// it again.</summary>
    public void WriteNow(WorkspaceFile file, string path)
    {
        var key = WorkspaceFile.IdentityKey(path);
        Enqueue(() =>
        {
            file.Write(path);
            written[key] = file;
        }).GetAwaiter().GetResult();
        finished.Remove(key);
    }

    /// <summary>
    /// <see cref="WriteNow"/> without blocking the caller: the identity key and the write run on the writer chain, off
    /// the store's context; the task ends (or throws the write's error) back on the caller's context, which must be the
    /// store's (the UI thread), where the key is opened again. Returns the file's identity key.
    /// </summary>
    public async Task<string> WriteNowAsync(WorkspaceFile file, string path)
    {
        string? key = null;
        await Enqueue(() =>
        {
            key = WorkspaceFile.IdentityKey(path);
            file.Write(path);
            written[key] = file;
        });
        finished.Remove(key!);
        return key!;
    }

    /// <summary>Writes <paramref name="session"/> to <paramref name="file"/> as the store does: pretty-printed with
    /// sorted keys, atomically, mode 600 off Windows (it lists the user's repo paths).</summary>
    internal static void WriteSession(SavedSession session, string file) =>
        AtomicFile.Write(file, SwiftJson.Serialize(session, SwiftJsonFormatting.PrettyPrinted | SwiftJsonFormatting.SortedKeys));

    private Pass WritePass(Snapshot snapshot) =>
        new(snapshot.Workspaces
                .Where(entry => !entry.Value.IsReadOnly && !finished.Contains(entry.Key))
                .OrderBy(entry => entry.Key, StringComparer.Ordinal)
                .Select(entry => (entry.Key, entry.Value.File))
                .ToList(),
            snapshot.Session);

    private Task Enqueue(Pass pass) => Enqueue(() => Write(pass));

    private Task Enqueue(Action work) =>
        writer = writer.ContinueWith(_ => work(), CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);

    /// <summary>
    /// Writes every workspace file of <paramref name="pass"/> whose model changed since its last write, each failure
    /// reported without stopping the others, then the session: a crash between the two never leaves windows that left
    /// <c>session.json</c> without their workspace file.
    /// </summary>
    private void Write(Pass pass)
    {
        foreach (var (key, file) in pass.Workspaces)
        {
            Exception? result = null;
            if (written.TryGetValue(key, out var last) && last.Equals(file))
            {
                if (!failed.Remove(key))
                {
                    continue;
                }
            }
            else
            {
                try
                {
                    file.Write(key);
                    written[key] = file;
                    failed.Remove(key);
                }
                catch (WorkspaceFileError error) when (error.Kind == WorkspaceFileErrorKind.Empty)
                {
                    Debug.WriteLine("workspace file skipped: it has no window, or a window with no tab");
                    continue;
                }
                catch (Exception error)
                {
                    Debug.WriteLine($"workspace file not saved: {error.Message}");
                    failed.Add(key);
                    result = error;
                }
            }

            Report(key, result);
        }

        try
        {
            WriteSession(pass.Session, SessionFile);
        }
        catch (Exception error)
        {
            Debug.WriteLine($"session.json not saved: {error.Message}");
            SessionWriteFailed?.Invoke(error);
        }
    }

    private void Report(string key, Exception? result)
    {
        if (context is null)
        {
            WriteResult?.Invoke(key, result);
        }
        else
        {
            context.Post(_ => WriteResult?.Invoke(key, result), null);
        }
    }

    private IDisposable DelayOnContext(TimeSpan due, Action action) =>
        new Timer(
            _ =>
            {
                if (context is null)
                {
                    action();
                }
                else
                {
                    context.Post(_ => action(), null);
                }
            },
            null, due, Timeout.InfiniteTimeSpan);
}

/// <summary>Writes a file atomically: a temp file in the same folder, then a rename over it.</summary>
internal static class AtomicFile
{
    /// <summary>Writes <paramref name="data"/> to <paramref name="file"/> (temp file, then <c>File.Move</c> with
    /// overwrite), mode 600 off Windows; creates the folder. The temp file is removed when anything fails.</summary>
    public static void Write(string file, byte[] data)
    {
        var full = Path.GetFullPath(file);
        var folder = Path.GetDirectoryName(full) ?? throw new IOException($"{file} has no folder.");
        Directory.CreateDirectory(folder);
        var temp = Path.Combine(folder, $".{Path.GetFileName(full)}.{Guid.NewGuid().ToString("D").ToUpperInvariant()}.tmp");
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

            File.Move(temp, full, overwrite: true);
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
}

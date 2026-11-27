using System.Diagnostics;
using Histq.Core;

namespace Histq.App.Repo;

/// <summary>
/// What a repo tab needs before its log can be read, started as early as the launch allows: the git executable (one
/// resolution, <c>git --version</c>, shared by every tab and the Welcome page's check) and, for a folder given at launch,
/// its whole session (<see cref="Prestart"/>: read environment, stashes, log), on a worker while XAML starts and the
/// window is made, as the phase 5 spike loaded its log beside the UI's start. Any thread unless said.
/// </summary>
internal static class GitWarmup
{
    private static readonly Lock Gate = new();
    private static readonly Dictionary<string, RepoTabSession> LaunchSessions = new(PathFlavor.Host.KeyComparer);

    /// <summary>The most launch folders whose session starts at launch; the others start when their tab mounts.</summary>
    private const int MaxLaunchSessions = 3;

    /// <summary>The launch's folders are open: no more launch session starts.</summary>
    private static bool _launchClosed;

    /// <summary>The launch sessions started (taken ones too).</summary>
    private static int _launchStarted;

    /// <summary>The last resolution and the gitPath preference it was for.</summary>
    private static (string Override, Task<GitExecutable> Task)? _git;

    /// <summary>
    /// The git of the gitPath preference <paramref name="overridePath"/>: the shared resolution while it is for the same
    /// preference and has not failed (its executable still there); else a new one. Throws as
    /// <see cref="GitExecutable.ResolveAsync"/>.
    /// </summary>
    public static Task<GitExecutable> GitAsync(string? overridePath, CancellationToken ct = default)
    {
        string key = overridePath?.Trim() ?? "";
        lock (Gate)
        {
            if (_git is not { } known || !string.Equals(known.Override, key, StringComparison.Ordinal)
                || known.Task.IsFaulted || known.Task.IsCanceled
                || (known.Task.IsCompletedSuccessfully && !File.Exists(known.Task.Result.ExecutablePath)))
            {
                _git = (key, Task.Run(() => GitExecutable.ResolveAsync(overridePath)));
            }

            return _git.Value.Task.WaitAsync(ct);
        }
    }

    /// <summary>
    /// Starts the session of a launch folder (a launch argument: an existing local folder) right away, on a worker while
    /// XAML starts and the window is made: git resolved, its read environment listed and its log read before its tab
    /// exists. The tab takes it (<see cref="TakeSession"/>) and attaches it to the UI thread, which then gets what it read
    /// meanwhile. Once per folder (as its tab names it: <see cref="PathFlavor.Standardized"/>, as
    /// <see cref="WindowTabs.OpenTab"/> stores it), for the first <see cref="MaxLaunchSessions"/> folders; nothing after
    /// <see cref="ReleaseLaunchSessions"/>. Never throws.
    /// </summary>
    public static void Prestart(string folder, Preferences preferences, string stateRoot)
    {
        if (PathFlavor.Host.IsUncOrDevice(folder))
            return;
        folder = PathFlavor.Host.Standardized(folder);
        lock (Gate)
        {
            if (_launchClosed || LaunchSessions.ContainsKey(folder) || _launchStarted >= MaxLaunchSessions)
                return;
            _launchStarted++;
            try
            {
                var session = new RepoTabSession(
                    folder, preferences, preferences.Get<bool>(PrefKey.GraphFadeOtherWorktrees), stateRoot, null);
                LaunchSessions[folder] = session;
                session.Start();
            }
            catch (Exception error)
            {
                Debug.WriteLine($"GitWarmup: {folder} not started at launch: {error.Message}");
            }
        }
    }

    /// <summary>The launch session of <paramref name="folder"/>, handed over once (the caller hooks its events, then
    /// attaches it); null when there is none. UI thread.</summary>
    public static RepoTabSession? TakeSession(string folder)
    {
        string key = PathFlavor.Host.Standardized(folder);
        lock (Gate)
            return LaunchSessions.Remove(key, out RepoTabSession? session) ? session : null;
    }

    /// <summary>The launch is over (its folders opened or skipped): the launch sessions no tab took stop, and no more
    /// start. UI thread.</summary>
    public static void ReleaseLaunchSessions()
    {
        List<RepoTabSession> left;
        lock (Gate)
        {
            _launchClosed = true;
            left = [.. LaunchSessions.Values];
            LaunchSessions.Clear();
        }

        foreach (RepoTabSession session in left)
            session.Dispose();
    }
}

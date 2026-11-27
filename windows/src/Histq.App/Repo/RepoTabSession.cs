using System.ComponentModel;
using System.Diagnostics;
using Histq.App.Shell;
using Histq.Core;
using Histq.Platform.SystemServices;
using Microsoft.UI.Dispatching;

namespace Histq.App.Repo;

/// <summary>
/// A repo tab's log load (ported from the entry of RepoSession's load pipeline, readLog in App/Repo/RepoSession.swift at
/// 6fa6d40, its log part only): off the UI thread it resolves git (<see cref="GitExecutable.ResolveAsync"/> with the
/// gitPath preference), builds the read environment (<see cref="GitInvocation.ReadEnvironmentAsync"/>, its driver
/// listing shared through one <see cref="ReadEnvironmentCache"/>), then streams <see cref="LogReader.PagesAsync"/> in the
/// commitOrder preference's order and lays each page out (<see cref="GraphLayout"/>) as it comes. Every git process
/// joins <see cref="ChildProcessJob.Shared"/>, so none outlives the app.
/// <para>
/// The rows reach the UI thread through <see cref="RowsChanged"/>: the first page as soon as it is laid out, then
/// whatever arrived meanwhile in one dispatcher callback at a time, so a large log never floods the UI thread. The lists
/// it hands out only grow, and only on the UI thread (<see cref="Graph.GraphCanvas.SetRows"/>' contract). Then
/// <see cref="Completed"/>, or <see cref="Failed"/> with a message to show in the graph area.
/// </para>
/// <para>
/// Not ported yet (M2+): the status and the WIP row, the stashes and their bases, the refs (hidden and soloed branches,
/// pinned tips), the other worktrees' rows, reloads. The subjects are sanitized for display here, off the UI thread
/// (<see cref="DisplayText.Sanitize"/>), so the canvas draws them as they are.
/// </para>
/// </summary>
internal sealed class RepoTabSession : IDisposable
{
    /// <summary>The driver listings of every tab's read environment (it is keyed by folder, git and environment).</summary>
    private static readonly ReadEnvironmentCache ReadCache = new();

    /// <summary>Puts every git process in the app's job; null when Windows refused to make the job (logged once).</summary>
    private static readonly Lazy<Action<Process>?> OnStarted = new(JoinJob);

    private readonly string _path;
    private readonly Preferences _preferences;
    private readonly DispatcherQueue _dispatcher;
    private readonly CancellationTokenSource _cancel = new();

    /// <summary>Guards the pending rows and outcome, which the load fills and <see cref="Drain"/> takes.</summary>
    private readonly Lock _gate = new();

    // The rows and commits laid out since the last drain, the load's outcome, and whether a drain is queued.
    private List<GraphRow> _pendingRows = [];
    private List<Commit> _pendingCommits = [];
    private Outcome _outcome;
    private string? _failure;
    private bool _drainQueued;

    // UI thread only: the lists the canvas holds, and whether the session was disposed.
    private readonly List<GraphRow> _rows = [];
    private readonly List<Commit> _commits = [];
    private bool _disposed;
    private bool _started;

    private enum Outcome
    {
        Loading,
        Completed,
        Failed,
    }

    /// <param name="path">The tab's folder: a repo tab that is not missing (and never a received UNC or device path,
    /// which <see cref="TabContentHost"/> shows as "Repo not found").</param>
    /// <param name="preferences">The app's preferences, read off the UI thread only.</param>
    /// <param name="dispatcher">The UI thread's queue, where every event is raised.</param>
    public RepoTabSession(string path, Preferences preferences, DispatcherQueue dispatcher)
    {
        _path = path;
        _preferences = preferences;
        _dispatcher = dispatcher;
    }

    /// <summary>New rows were appended: the lists (always the same two, grown) to show. UI thread.</summary>
    public event Action<IReadOnlyList<GraphRow>, IReadOnlyList<Commit>>? RowsChanged;

    /// <summary>The whole log is in (maybe empty). UI thread.</summary>
    public event Action? Completed;

    /// <summary>The load failed: the message to show (sanitized). UI thread.</summary>
    public event Action<string>? Failed;

    /// <summary>Starts the load on a worker; at most once. Call on the UI thread after hooking the events.</summary>
    public void Start()
    {
        if (_started || _disposed)
            return;
        _started = true;
        CancellationToken ct = _cancel.Token;
        _ = Task.Run(() => LoadAsync(ct), CancellationToken.None);
    }

    /// <summary>Stops the load (its git process is killed) and raises nothing more. UI thread; the tab closed, or its
    /// layout was unmounted (keep-alive) or its window closed.</summary>
    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        // Not disposed itself: the load may still read its token.
        _cancel.Cancel();
    }

    /// <summary>Never throws: a cancellation ends quietly, any other failure is handed out as a message.</summary>
    private async Task LoadAsync(CancellationToken ct)
    {
        try
        {
            string gitPath = _preferences.Get<string>(PrefKey.GitPath);
            LogReader.Order order = string.Equals(_preferences.Get<string>(PrefKey.CommitOrder), "branch", StringComparison.Ordinal)
                ? LogReader.Order.Branch
                : LogReader.Order.Date;
            GitExecutable git = await GitExecutable.ResolveAsync(gitPath, ct: ct).ConfigureAwait(false);
            var runner = new GitRunner(git.ExecutablePath, OnStarted.Value);
            Dictionary<string, string> @base = GitInvocation.BaseEnvironment(gitExecutable: git.ExecutablePath);
            Dictionary<string, string> env = await GitInvocation
                .ReadEnvironmentAsync(null, @base, runner, _path, ReadCache, ct).ConfigureAwait(false);

            var layout = new GraphLayout();
            await foreach (IReadOnlyList<Commit> page in LogReader.PagesAsync(runner, _path, env, order: order, ct: ct)
                               .ConfigureAwait(false))
            {
                GraphRow[] rows = layout.Append(page, ct);
                Post(rows, Sanitized(page), Outcome.Loading, null);
            }

            Post([], [], Outcome.Completed, null);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
        catch (Exception error)
        {
            if (!ct.IsCancellationRequested)
                Post([], [], Outcome.Failed, Message(error));
        }
    }

    /// <summary>Adds rows (and the outcome, once known) for the UI thread and queues one drain unless one is queued.
    /// Any thread.</summary>
    private void Post(GraphRow[] rows, Commit[] commits, Outcome outcome, string? failure)
    {
        lock (_gate)
        {
            _pendingRows.AddRange(rows);
            _pendingCommits.AddRange(commits);
            if (outcome != Outcome.Loading)
            {
                _outcome = outcome;
                _failure = failure;
            }

            if (_drainQueued)
                return;
            _drainQueued = true;
        }

        if (!_dispatcher.TryEnqueue(Drain))
        {
            // The UI thread is shutting down: nothing is shown any more.
            lock (_gate)
                _drainQueued = false;
        }
    }

    /// <summary>UI thread: appends the pending rows to the shown lists and raises the events, unless disposed.</summary>
    private void Drain()
    {
        List<GraphRow> rows;
        List<Commit> commits;
        Outcome outcome;
        string? failure;
        lock (_gate)
        {
            rows = _pendingRows;
            commits = _pendingCommits;
            _pendingRows = [];
            _pendingCommits = [];
            outcome = _outcome;
            failure = _failure;
            _outcome = Outcome.Loading;
            _drainQueued = false;
        }

        if (_disposed)
            return;
        try
        {
            if (rows.Count > 0)
            {
                _rows.AddRange(rows);
                _commits.AddRange(commits);
                RowsChanged?.Invoke(_rows, _commits);
            }

            if (outcome == Outcome.Completed)
                Completed?.Invoke();
            else if (outcome == Outcome.Failed)
                Failed?.Invoke(failure ?? "");
        }
        catch (Exception error)
        {
            // A dispatcher callback that throws ends the app; the graph keeps what it shows.
            CrashLog.Recovered("RepoTabSession.Drain (rows not shown)", error);
        }
    }

    /// <summary>The page with each subject made safe to draw and to read through UI Automation; a commit whose subject
    /// needs no change is kept as is.</summary>
    private static Commit[] Sanitized(IReadOnlyList<Commit> page)
    {
        var commits = new Commit[page.Count];
        for (int i = 0; i < page.Count; i++)
        {
            Commit commit = page[i];
            string subject = DisplayText.Sanitize(commit.Subject);
            commits[i] = ReferenceEquals(subject, commit.Subject) ? commit : commit with { Subject = subject };
        }

        return commits;
    }

    /// <summary>What the graph area says for a failed load (RepoSession.message(for:) at 6fa6d40, the kinds a log read
    /// can meet), sanitized line by line. An unexpected failure is logged to crash.log.</summary>
    private static string Message(Exception error)
    {
        string message = error switch
        {
            GitError { Kind: GitErrorKind.Other } git when git.StderrTail.Contains("not a git repository", StringComparison.Ordinal)
                => "This folder is not a git repository.",
            GitError git => string.IsNullOrWhiteSpace(git.StderrTail) ? "git failed." : git.StderrTail,
            GitExecutableError or GitInvocation.ReadSafetyError or GraphTooWideException => error.Message,
            _ => Unexpected(error),
        };
        IEnumerable<string> lines = message.Trim().Split('\n').Select(line => DisplayText.Sanitize(line.TrimEnd('\r')));
        return string.Join("\n", lines.Take(20));
    }

    private static string Unexpected(Exception error)
    {
        CrashLog.Recovered("RepoTabSession.Load (history not read)", error);
        return "Histq couldn't read the history: " + error.Message;
    }

    private static Action<Process>? JoinJob()
    {
        try
        {
            return ChildProcessJob.Shared.Assign;
        }
        catch (Win32Exception error)
        {
            CrashLog.Recovered("ChildProcessJob (git runs outside the job)", error);
            return null;
        }
    }
}

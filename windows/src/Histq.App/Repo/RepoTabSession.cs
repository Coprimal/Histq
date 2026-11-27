using System.ComponentModel;
using System.Diagnostics;
using Histq.App.Graph;
using Histq.App.Shell;
using Histq.Core;
using Histq.Platform.SystemServices;
using Microsoft.UI.Dispatching;

namespace Histq.App.Repo;

/// <summary>
/// A repo tab's log and graph rows (ported from RepoSession's load pipeline in App/Repo/RepoSession.swift at 6fa6d40:
/// loadLog, loadWorktrees, readWorktrees, refreshWorktrees). Off the UI thread it resolves git
/// (<see cref="GitExecutable.ResolveAsync"/> with the gitPath preference) and loads the log with
/// <see cref="RepoLoader"/> (the read base environment, its driver listing shared through one
/// <see cref="ReadEnvironmentCache"/>): the status and the stashes beside the history, the WIP, other worktrees' and stash
/// rows laid out around the commits, in the commitOrder preference's order and the laneColors preference's coloring.
/// Every git process joins <see cref="ChildProcessJob.Shared"/>, so none outlives the app.
/// <para>
/// The graph gets <see cref="GraphData"/> on the UI thread through <see cref="Loaded"/>: the first page's snapshot as
/// soon as it is laid out, then the complete one, then one per reload; only the latest one waiting is handed out. A
/// failure of the first load is <see cref="Failed"/> (a message for the graph area); a later failure keeps the graph.
/// </para>
/// <para>
/// The refs are read beside each load (<see cref="RefReader"/>, the same read environment) and become the commits'
/// badges (<see cref="RefBadge.For"/>), handed out with the rows: with the first page when they are read by then, with
/// the complete log always. The refs themselves, the worktree list and the snapshot's stashes go out in the same
/// <see cref="GraphData"/>, which the sidebar lists (no read of its own).
/// </para>
/// <para>
/// After the first log, the worktree list is read with each other worktree's change count, in its own folder with its
/// own read environment (never a bare, missing, network or device one); the other worktrees with changes get a WIP row
/// (a reload lays them out). After the first log the repo is watched (<see cref="RepoWatcher"/>, Histq's own state
/// folder ignored): a refs or log change is <see cref="RefreshRefs"/> (the log reloaded, the worktrees read again), a
/// status change <see cref="RefreshStatus"/>; while the tab is hidden (<see cref="SetShown"/>) they are held until it
/// shows, as on the Mac. <see cref="RefreshOnShow"/> (the tab shown again) runs them and reads the worktrees
/// again, as on the Mac (and, when the repo could not be watched, checks the status, the stashes and the refs). Requests
/// queue: one read runs at a time, and requests made meanwhile run once after it.
/// </para>
/// <para>
/// The graph's view (hidden, soloed and pinned branches, hide stale: <see cref="RepoViewState"/>) is the repo layout's:
/// a workspace's own is given at construction, else the folder's own file is read before the first load
/// (<see cref="ViewLoaded"/>); <see cref="SetView"/> hands a changed one over and reloads. Each load reads the log
/// through <see cref="LogFilter.For"/> of the view against the refs (read first when the view is not empty, so a hidden
/// branch never shows); when the refs read with it give another filter, the log is read once more. The badges leave the
/// hidden refs out; <see cref="GraphData.Refs"/> keeps them all (the sidebar lists them). The subjects are sanitized for display here, off the UI thread
/// (<see cref="DisplayText.Sanitize"/>), only for commits a previous snapshot did not have (an incremental reload reuses
/// its Commit objects); the badges' names when they are made; author names, stash messages and worktree names stay raw
/// in the data and are sanitized where the graph shows them.
/// </para>
/// </summary>
internal sealed partial class RepoTabSession : IDisposable
{
    /// <summary>The driver listings of every tab's read environment (it is keyed by folder, git and environment).</summary>
    private static readonly ReadEnvironmentCache ReadCache = new();

    /// <summary>Puts every git process in the app's job; null when Windows refused to make the job (logged once).</summary>
    private static readonly Lazy<Action<Process>?> OnStarted = new(JoinJob);

    /// <summary>The launch timeline's marks (QA builds: <c>QaTimeline</c>, the load probe's breakdown); null otherwise.</summary>
#if HISTQ_QA
    private static readonly Action<string>? Mark = QaTimeline.Mark;
#else
    private static readonly Action<string>? Mark = null;
#endif

    private readonly string _path;
    private readonly Preferences _preferences;
    private readonly bool _fadeWorktrees;
    private readonly string? _ownStateDir;

    /// <summary>The graph's view (under _gate): the layout's last one; null until given or read.</summary>
    private RepoViewState? _view;

    /// <summary>The folder's own view file was read (or not needed): the pump's.</summary>
    private bool _viewRead;

    /// <summary>The view read from the folder's file, waiting for the UI thread (under _gate).</summary>
    private RepoViewState? _pendingView;

    /// <summary>The filter the last log was read with (the pump's): the badges leave its hidden refs out.</summary>
    private LogFilter _filter = LogFilter.None;
    /// <summary>The UI thread's queue (under _gate); null for a session started before its tab exists, whose data waits
    /// until <see cref="Attach"/>.</summary>
    private DispatcherQueue? _dispatcher;
    private readonly CancellationTokenSource _cancel = new();

    /// <summary>Guards the requests and the data waiting for the UI thread.</summary>
    private readonly Lock _gate = new();

    // Requests (under _gate): what the next pass of the pump does, and whether it runs.
    private bool _loadWanted;
    private bool _worktreesWanted;
    private bool _checkWanted;
    private bool _statusWanted;

    // While the tab is hidden (under _gate): it is, and the watcher's refreshes held until it shows.
    private bool _hidden;
    private bool _heldLoad;
    private bool _heldStatus;

    /// <summary>The repo's watcher (under _gate): set once it watches; null before, or when it could not.</summary>
    private RepoWatcher? _watcher;
    private bool _pumping;

    // Waiting for the UI thread (under _gate): the latest data, or the first load's failure; a drain is queued.
    private GraphData? _pending;
    private string? _failure;
    private bool _drainQueued;

    // The pump's own (one pass at a time): git, the loader, the folders, the last complete snapshot and worktrees.
    private RepoLoader? _loader;
    private GitRunner? _runner;
    private IReadOnlyDictionary<string, string>? _base;
    private RepoDirectories? _directories;

    /// <summary>The repo's folders cannot be resolved (a bare or network repo): not tried again.</summary>
    private bool _noDirectories;
    private RepoSnapshot? _complete;
    private IReadOnlyList<WorktreeInfo> _worktrees = [];
    private bool _worktreesRead;
    private WorktreeFade? _fade;
    private Refs? _refs;
    private IReadOnlyDictionary<string, RefBadge[]>? _badges;
    private int _generation;
    private bool _shownAny;
    private bool _watchTried;

    // UI thread only (a launch session's Start runs on a worker before any UI thread sees it).
    private bool _disposed;
    private bool _started;

    /// <param name="path">The tab's folder: a repo tab that is not missing (and never a received UNC or device path,
    /// which <see cref="TabContentHost"/> shows as "Repo not found").</param>
    /// <param name="preferences">The app's preferences, read off the UI thread only.</param>
    /// <param name="fadeWorktrees">Other worktrees' commits fade (graphFadeOtherWorktrees): their reach is computed.</param>
    /// <param name="ownStateDir">Histq's own state folder: the watcher ignores its changes (a repo holding it).</param>
    /// <param name="dispatcher">The UI thread's queue, where every event is raised; null for a session started at launch,
    /// before its tab exists (<see cref="GitWarmup.Prestart"/>): nothing is raised until <see cref="Attach"/>.</param>
    /// <param name="view">The graph's view the workspace holds for this repo; null to read the folder's own file
    /// (<see cref="RepoViewState.FileFor"/> under <paramref name="ownStateDir"/>).</param>
    public RepoTabSession(
        string path, Preferences preferences, bool fadeWorktrees, string? ownStateDir, DispatcherQueue? dispatcher,
        RepoViewState? view = null)
    {
        _view = view;
        _path = path;
        _preferences = preferences;
        _fadeWorktrees = fadeWorktrees;
        _ownStateDir = ownStateDir;
        _dispatcher = dispatcher;
    }

    /// <summary>
    /// The UI thread's queue for a session started without one (at launch): what it read meanwhile is raised from now
    /// on. Hook the events first. UI thread; nothing for a session that has its queue.
    /// </summary>
    public void Attach(DispatcherQueue dispatcher)
    {
        bool queue;
        lock (_gate)
        {
            if (_dispatcher is not null)
                return;
            _dispatcher = dispatcher;
            queue = !_drainQueued && (_pending is not null || _failure is not null || _pendingView is not null);
            if (queue)
                _drainQueued = true;
        }

        if (queue)
            Enqueue();
    }

    /// <summary>The graph's rows, worktrees and fading: a first page, a complete log or a reload. UI thread.</summary>
    public event Action<GraphData>? Loaded;

    /// <summary>The first load failed: the message to show (sanitized). UI thread.</summary>
    public event Action<string>? Failed;

    /// <summary>The folder's own saved view, read before the first load when none was given (raised before the first
    /// <see cref="Loaded"/>); not raised when <see cref="SetView"/> came first. UI thread.</summary>
    public event Action<RepoViewState>? ViewLoaded;

    /// <summary>The graph's view changed (a Hide, Solo, Pin, Show All…): the log is read again through it. UI
    /// thread.</summary>
    public void SetView(RepoViewState view)
    {
        lock (_gate)
            _view = view;
        Request(load: true);
    }

    /// <summary>Starts the load on a worker; at most once. Call on the UI thread after hooking the events.</summary>
    public void Start()
    {
        if (_started || _disposed)
            return;
        _started = true;
        Mark?.Invoke("sessionStart");
        Request(load: true, worktrees: true);
    }

    /// <summary>The refs changed (a commit, a checkout, a branch or worktree added or removed): reloads the log and
    /// reads the worktrees again. Any thread.</summary>
    public void RefreshRefs() => Request(load: true, worktrees: true);

    /// <summary>The working tree or the index changed: reads the status and the stashes again; a WIP or stash row that
    /// comes or goes reloads the log, other changes only update the WIP row's counts. Any thread.</summary>
    public void RefreshStatus() => Request(status: true);

    /// <summary>The tab is shown again: reads the worktrees again (another worktree's files may have changed in its
    /// own tab; the watcher follows only this worktree's), as on the Mac. Without a watcher (it could not start), it also
    /// checks the status, the stashes and the refs. Any thread.</summary>
    public void RefreshOnShow()
    {
        bool watching, load, status;
        lock (_gate)
        {
            watching = _watcher is not null;
            (load, status) = (_heldLoad, _heldStatus);
            _heldLoad = _heldStatus = false;
        }

        Request(load: load, worktrees: true, check: !watching, status: status);
    }

    /// <summary>The tab is shown (true) or hidden: while hidden, the watcher's refreshes are held, as on the Mac, and
    /// run once <see cref="RefreshOnShow"/> comes. UI thread.</summary>
    public void SetShown(bool shown)
    {
        lock (_gate)
            _hidden = !shown;
    }

    /// <summary>Stops the reads (their git processes are killed) and raises nothing more. UI thread; the tab closed, or
    /// its layout was unmounted (keep-alive) or its window closed.</summary>
    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        RepoWatcher? watcher;
        lock (_gate)
        {
            // Not disposed itself: the pump may still read its token.
            _cancel.Cancel();
            watcher = _watcher;
            _watcher = null;
        }

        watcher?.Dispose();
    }

    private void Request(bool load = false, bool worktrees = false, bool check = false, bool status = false)
    {
        lock (_gate)
        {
            if (!_started || _cancel.IsCancellationRequested)
                return;
            _loadWanted |= load;
            _worktreesWanted |= worktrees;
            _checkWanted |= check;
            _statusWanted |= status;
            if (_pumping)
                return;
            _pumping = true;
        }

        CancellationToken ct = _cancel.Token;
        _ = Task.Run(() => PumpAsync(ct), CancellationToken.None);
    }

    /// <summary>Runs the requests one pass at a time until none is left. Never throws.</summary>
    private async Task PumpAsync(CancellationToken ct)
    {
        while (true)
        {
            bool load, worktrees, check, status;
            lock (_gate)
            {
                (load, worktrees, check, status) = (_loadWanted, _worktreesWanted, _checkWanted, _statusWanted);
                _loadWanted = _worktreesWanted = _checkWanted = _statusWanted = false;
                if (ct.IsCancellationRequested || !(load || worktrees || check || status))
                {
                    _pumping = false;
                    return;
                }
            }

            try
            {
                await PassAsync(load, worktrees, check, status, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
            }
            catch (Exception error)
            {
                if (ct.IsCancellationRequested)
                    continue;
                if (_complete is null && !_shownAny)
                    PostFailure(Message(error));
                else
                    Debug.WriteLine($"RepoTabSession: refresh failed: {error.Message}");
            }
        }
    }

    /// <summary>One pass: the log (first load or reload; the watcher starts beside the first one), the status check,
    /// then the worktrees; a change in the other worktrees with changes reloads the log once more.</summary>
    private async Task PassAsync(bool load, bool worktrees, bool check, bool status, CancellationToken ct)
    {
        await PrepareAsync(ct).ConfigureAwait(false);
        ReadView();
        if (_complete is null)
            load = true;
        if (!load && check && _complete is not null && await ChangedAsync(_complete, ct).ConfigureAwait(false))
            load = true;
        if (!load && status && _complete is not null && await StatusChangedAsync(_complete, ct).ConfigureAwait(false))
            load = true;
        // The watcher starts beside the first load, so a change made while it reads is queued for the next pass.
        Task watching = _watchTried ? Task.CompletedTask : StartWatcherAsync(ct);
        try
        {
            if (load)
                await LoadAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            await watching.ConfigureAwait(false);
        }

        if (!worktrees || _complete is null)
            return;
        // Null: this worktree's folder is not known this pass (a timeout); the list waits for the next read.
        if (await ReadWorktreesAsync(ct).ConfigureAwait(false) is not { } list)
            return;
        bool rowsChanged = !Dirty(list).SequenceEqual(_complete.Worktrees);
        // The first list read is handed out even when it is empty: the sidebar's Worktrees card waits for it.
        bool listChanged = !list.SequenceEqual(_worktrees) || !_worktreesRead;
        _worktrees = list;
        _worktreesRead = true;
        if (rowsChanged)
        {
            await LoadAsync(ct).ConfigureAwait(false);
        }
        else if (listChanged)
        {
            // Only counts or worktrees without a row changed: the same rows, other labels, badges and reach.
            _fade = Fade(_complete, ct);
            _badges = Badges();
            Post(Data(_complete, _fade));
        }
    }

    /// <summary>
    /// Resolves git (the app's shared resolution, <see cref="GitWarmup"/>, started at launch), its runner and the read
    /// base environment, once; then reads the folder's read environment once, so the log, the refs and the watcher that
    /// start next all find it cached instead of each listing it at the same time.
    /// </summary>
    private async Task PrepareAsync(CancellationToken ct)
    {
        if (_loader is not null)
            return;
        GitExecutable git = await GitWarmup.GitAsync(_preferences.Get<string>(PrefKey.GitPath), ct).ConfigureAwait(false);
        Mark?.Invoke("gitResolved");
        var runner = new GitRunner(git.ExecutablePath, OnStarted.Value);
        Dictionary<string, string> @base = GitInvocation.BaseEnvironment(gitExecutable: git.ExecutablePath);
        _runner = runner;
        _base = @base;
        await ReadEnvironmentAsync(_path, ct).ConfigureAwait(false);
        Mark?.Invoke("readEnv");
        _loader = new RepoLoader(runner, _path, @base, ReadCache, Mark);
    }

    /// <summary>Reads the folder's own view file once, unless a view was given or set; it goes to the UI thread before
    /// the first rows.</summary>
    private void ReadView()
    {
        if (_viewRead)
            return;
        _viewRead = true;
        lock (_gate)
        {
            if (_view is not null)
                return;
        }

        RepoViewState read = _ownStateDir is null
            ? RepoViewState.Empty
            : RepoViewState.Load(RepoViewState.FileFor(_ownStateDir, _path));
        lock (_gate)
        {
            if (_view is not null)
                return;
            _view = read;
            _pendingView = read;
            if (_drainQueued)
                return;
            _drainQueued = true;
        }

        Enqueue();
    }

    /// <summary>What the graph leaves out for <paramref name="view"/> against the last refs; none before they are read.</summary>
    private LogFilter FilterFor(RepoViewState view) =>
        view.Equals(RepoViewState.Empty) || _refs is not { } refs ? LogFilter.None : LogFilter.For(view, refs);

    /// <summary>
    /// Loads the log through the view's filter (<see cref="LoadOnceAsync"/>); when the refs read beside it give another
    /// filter (a branch made, deleted or moved), once more with the new one.
    /// </summary>
    private async Task LoadAsync(CancellationToken ct)
    {
        RepoViewState view;
        lock (_gate)
            view = _view ?? RepoViewState.Empty;
        LogFilter used = await LoadOnceAsync(view, ct).ConfigureAwait(false);
        if (!FilterFor(view).Equals(used))
            await LoadOnceAsync(view, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Loads the log once: the whole history the first time (its first page handed out as soon as it is laid out), else a
    /// reload from the last complete snapshot (only the new commits when that can be proven safe). Returns the filter it
    /// was read with.
    /// </summary>
    private async Task<LogFilter> LoadOnceAsync(RepoViewState view, CancellationToken ct)
    {
        int generation = ++_generation;
        LogReader.Order order = RepoLoader.OrderFrom(_preferences.Get<string>(PrefKey.CommitOrder));
        GraphLayout.Coloring coloring = RepoLoader.ColoringFrom(_preferences.Get<string>(PrefKey.LaneColors));
        IReadOnlyList<Worktree> dirty = Dirty(_worktrees);
        RepoSnapshot? previous = _complete;
        RepoSnapshot snapshot;
        // The refs beside the log: the first page has the badges only when they are read by then (it never waits for
        // them), the complete log always.
        Task<Refs?> refs = ReadRefsAsync(ct);
        // A saved view needs the refs before the log: a hidden branch never shows, even on the first page.
        if (!view.Equals(RepoViewState.Empty) && _refs is null)
            _refs = await refs.ConfigureAwait(false);
        LogFilter filter = FilterFor(view);
        _filter = filter;
        if (previous is null)
        {
            snapshot = await _loader!.LoadAsync(
                generation, filter, dirty, order, coloring,
                firstPage: page =>
                {
                    if (refs.IsCompletedSuccessfully)
                    {
                        _refs = refs.Result ?? _refs;
                        _badges = Badges();
                    }

                    _shownAny = true;
                    Post(Data(Sanitized(page, null), null));
                    return Task.CompletedTask;
                },
                ct).ConfigureAwait(false);
        }
        else
        {
            snapshot = await _loader!.ReloadAsync(previous, generation, filter, dirty, order, coloring, ct)
                .ConfigureAwait(false);
        }

        ct.ThrowIfCancellationRequested();
        _refs = await refs.ConfigureAwait(false) ?? _refs;
        _badges = Badges();
        _complete = Sanitized(snapshot, previous);
        _shownAny = true;
        _fade = Fade(_complete, ct);
        Post(Data(_complete, _fade));
        return filter;
    }

    /// <summary>The status, the stash list or the refs are not those <paramref name="snapshot"/> and its badges were
    /// made from.</summary>
    private async Task<bool> ChangedAsync(RepoSnapshot snapshot, CancellationToken ct)
    {
        // As the loader reads them: a bare repo's are an empty status and no stash, the same each time (the status
        // compares by value, entry by entry), so only its refs can tell a change.
        Task<(WorkingStatus Status, IReadOnlyList<Stash> Stashes)> read = _loader!.StatusAndStashesAsync(ct);
        Task<Refs?> refs = ReadRefsAsync(ct);
        await Task.WhenAll(read, refs).ConfigureAwait(false);
        (WorkingStatus status, IReadOnlyList<Stash> stashes) = await read.ConfigureAwait(false);
        return !Equals(status, snapshot.Status)
            || !stashes.SequenceEqual(snapshot.Stashes)
            || await refs.ConfigureAwait(false) is { } readRefs && !readRefs.Equals(_refs);
    }

    /// <summary>
    /// The status and stashes read again: true when the WIP or stash rows they give are not <paramref name="snapshot"/>'s
    /// (the log is reloaded); else a changed status (the WIP row's counts) is handed out with the same rows.
    /// </summary>
    private async Task<bool> StatusChangedAsync(RepoSnapshot snapshot, CancellationToken ct)
    {
        // As the loader reads them (a bare repo: an empty status, no stash).
        (WorkingStatus status, IReadOnlyList<Stash> stashes) =
            await _loader!.StatusAndStashesAsync(ct).ConfigureAwait(false);
        if (!RepoLoader.SyntheticRows(status, stashes, snapshot.Worktrees).SequenceEqual(snapshot.Synthetic)
            || !stashes.SequenceEqual(snapshot.Stashes))
        {
            return true;
        }

        if (!Equals(status, snapshot.Status))
        {
            _complete = snapshot with { Status = status };
            Post(Data(_complete, _fade));
        }

        return false;
    }

    /// <summary>
    /// Starts watching the repo's worktree and git dirs (<see cref="RepoWatcher"/>), once: a refs or log change reloads
    /// the log and the worktrees, a status change reads the status again. A repo that cannot be watched is not, without
    /// a word (as on the Mac); the tab then refreshes only when shown again. Folders not resolved this time (a timeout,
    /// git not started) are tried again by the next pass.
    /// </summary>
    private async Task StartWatcherAsync(CancellationToken ct)
    {
        _watchTried = true;
        try
        {
            Dictionary<string, string> env = await ReadEnvironmentAsync(_path, ct).ConfigureAwait(false);
            if (await DirectoriesAsync(env, ct).ConfigureAwait(false) is not { } directories)
            {
                // Not resolved this time (a timeout, git not started): the next pass tries again.
                _watchTried = _noDirectories;
                return;
            }

            var watcher = new RepoWatcher(_ownStateDir);
            watcher.Start(directories, OnWatcherChange);
            lock (_gate)
            {
                if (!_cancel.IsCancellationRequested)
                {
                    _watcher = watcher;
                    return;
                }
            }

            watcher.Dispose();
        }
        catch (Exception error) when (error is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            Debug.WriteLine($"RepoTabSession: the repo is not watched: {error.Message}");
        }
    }

    /// <summary>The watcher's callback (a pool thread; never throws): queues the refresh its scope needs.</summary>
    private void OnWatcherChange(RefreshScope scope, IReadOnlyList<string>? paths)
    {
        bool load = (scope & (RefreshScope.Refs | RefreshScope.Log)) != 0;
        bool status = !load && (scope & RefreshScope.Status) != 0;
        lock (_gate)
        {
            if (_hidden)
            {
                _heldLoad |= load;
                _heldStatus |= status;
                return;
            }
        }

        if (load)
            RefreshRefs();
        else if (status)
            RefreshStatus();
    }

    /// <summary>The refs and HEAD (<see cref="RefReader"/>) with the read environment; null when they could not be
    /// read (the graph keeps the last badges). Throws only a cancellation.</summary>
    private async Task<Refs?> ReadRefsAsync(CancellationToken ct)
    {
        try
        {
            Dictionary<string, string> env = await ReadEnvironmentAsync(_path, ct).ConfigureAwait(false);
            return await RefReader.ReadAsync(_runner!, _path, env, ct).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            Debug.WriteLine($"RepoTabSession: refs not read: {error.Message}");
            return null;
        }
    }

    /// <summary>The badges of the last refs read but those the log's filter hides, with the branches checked out in the
    /// other worktrees (and in the linked ones) marked; null before the refs are read.</summary>
    private IReadOnlyDictionary<string, RefBadge[]>? Badges()
    {
        if (_refs is not { } all)
            return null;
        IReadOnlySet<string> hidden = _filter.Hidden;
        Refs refs = hidden.Count == 0
            ? all
            : all with
            {
                LocalBranches = [.. all.LocalBranches.Where(branch => !hidden.Contains(branch.RefName))],
                RemoteBranches = [.. all.RemoteBranches.Where(branch => !hidden.Contains(branch.RefName))],
                Tags = [.. all.Tags.Where(tag => !hidden.Contains(tag.RefName))],
            };
        var other = new HashSet<string>(StringComparer.Ordinal);
        var linked = new HashSet<string>(StringComparer.Ordinal);
        foreach (WorktreeInfo info in _worktrees)
        {
            if (info.Worktree.Branch is not { } branch)
                continue;
            if (!info.IsCurrent)
                other.Add(branch);
            if (!info.Worktree.IsMain)
                linked.Add(branch);
        }

        return RefBadge.For(refs, other, linked);
    }

    /// <summary>
    /// <c>git worktree list</c> here, then each other worktree's status in its own folder, with the read environment
    /// built for that folder. A worktree whose status cannot be read gets no counts rather than failing the list; bare,
    /// missing (prunable), network and device ones are not read. The tab's own worktree is the one whose real path is
    /// this repo's top folder (none in a bare or network repo, whose top folder is not resolved).
    /// </summary>
    private async Task<IReadOnlyList<WorktreeInfo>?> ReadWorktreesAsync(CancellationToken ct)
    {
        Dictionary<string, string> env = await ReadEnvironmentAsync(_path, ct).ConfigureAwait(false);
        // A bare repo (no top folder) or a network one (never probed): no worktree is this tab's own. Folders not
        // resolved this time (a timeout): no list, rather than one with this tab's own worktree as another's.
        RepoDirectories? directories = await DirectoriesAsync(env, ct).ConfigureAwait(false);
        if (directories is null && !_noDirectories)
            return null;
        string? current = directories?.Worktree;
        IReadOnlyList<Worktree> list = await StashWorktreeReader.WorktreesAsync(_runner!, _path, env, ct)
            .ConfigureAwait(false);
        WorktreeInfo[] infos = await Task.WhenAll(list.Select(worktree => InfoAsync(worktree, current, ct)))
            .ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        return infos;
    }

    private async Task<WorktreeInfo> InfoAsync(Worktree worktree, string? current, CancellationToken ct)
    {
        PathFlavor flavor = PathFlavor.Host;
        // The list is the repo's own: a worktree on a share or a device is never probed (its folder would be opened).
        string? real = worktree.IsBare || worktree.IsPrunable || flavor.IsUncOrDevice(worktree.Path)
            ? null
            : WorkspaceDisk.Host.RealPath(worktree.Path);
        if (real is null || flavor.IsUncOrDevice(real))
            return new WorktreeInfo(worktree, false, null);
        if (current is not null && flavor.KeysEqual(real, current))
            return new WorktreeInfo(worktree, true, null);
        if (!Directory.Exists(real))
            return new WorktreeInfo(worktree, false, null);
        try
        {
            Dictionary<string, string> env = await ReadEnvironmentAsync(real, ct).ConfigureAwait(false);
            WorkingStatus status = await StatusReader.ReadAsync(_runner!, real, env, ct).ConfigureAwait(false);
            return new WorktreeInfo(worktree, false, WorktreeChanges.Of(status));
        }
        catch (Exception error) when (error is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            return new WorktreeInfo(worktree, false, null);
        }
    }

    /// <summary>
    /// The repo's folders (<see cref="RepoDirectories"/>), resolved once; null for a bare repo (no top folder) or a
    /// network or device one (refused, never probed), which is remembered for the session's life: it is not tried again.
    /// A timeout or a git that could not start is only this pass's null: the next pass tries again.
    /// </summary>
    private async Task<RepoDirectories?> DirectoriesAsync(IReadOnlyDictionary<string, string> env, CancellationToken ct)
    {
        if (_directories is not null || _noDirectories)
            return _directories;
        try
        {
            _directories = await RepoDirectories.ResolveAsync(_runner!, _path, env, ct).ConfigureAwait(false);
        }
        catch (GitError error) when (error.Kind is not (GitErrorKind.Timeout or GitErrorKind.LaunchFailed))
        {
            _noDirectories = true;
        }
        catch (GitError error)
        {
            Debug.WriteLine($"RepoTabSession: the repo's folders not resolved this time: {error.Message}");
        }

        return _directories;
    }

    private Task<Dictionary<string, string>> ReadEnvironmentAsync(string cwd, CancellationToken ct) =>
        GitInvocation.ReadEnvironmentAsync(null, _base!, _runner!, cwd, ReadCache, ct);

    /// <summary>The other worktrees whose changes get a graph row, in <c>git worktree list</c> order.</summary>
    private static List<Worktree> Dirty(IReadOnlyList<WorktreeInfo> worktrees) =>
        worktrees.Where(info => !info.IsCurrent && info.IsDirty).Select(info => info.Worktree).ToList();

    /// <summary>
    /// Which worktrees reach each commit of <paramref name="snapshot"/> (<see cref="WorktreeReach"/>), with this
    /// worktree's HEAD as the last tip: the graph fades the commits only another worktree reaches. Null when the fading
    /// is off, the log is not complete, or no other worktree has a HEAD (then nothing fades).
    /// </summary>
    private WorktreeFade? Fade(RepoSnapshot snapshot, CancellationToken ct)
    {
        if (!_fadeWorktrees || !snapshot.IsComplete)
            return null;
        List<string?> tips = _worktrees.Where(info => !info.IsCurrent && !info.Worktree.IsBare)
            .Take(WorktreeReach.MaxTips - 1).Select(info => info.Worktree.Head).ToList();
        if (!tips.Any(tip => tip is not null))
            return null;
        string? head = snapshot.Status?.Branch.Commit ?? _worktrees.FirstOrDefault(info => info.IsCurrent)?.Worktree.Head;
        int headBit = tips.Count;
        tips.Add(head);
        ulong[] masks = WorktreeReach.Masks(snapshot.Commits, snapshot.CommitIndex, tips, ct);
        return new WorktreeFade(masks, 1UL << headBit);
    }

    /// <summary><paramref name="snapshot"/> with each subject made safe to draw and to read through UI Automation; a
    /// commit <paramref name="previous"/> already holds (an incremental reload reuses it) or whose subject needs no
    /// change is kept as is.</summary>
    private static RepoSnapshot Sanitized(RepoSnapshot snapshot, RepoSnapshot? previous)
    {
        IReadOnlyList<Commit> commits = snapshot.Commits;
        Commit[]? sanitized = null;
        for (int i = 0; i < commits.Count; i++)
        {
            Commit commit = commits[i];
            if (previous is not null && previous.CommitIndex.TryGetValue(commit.Hash, out int at)
                && at < previous.Commits.Count && ReferenceEquals(previous.Commits[at], commit))
            {
                continue;
            }

            string subject = DisplayText.Sanitize(commit.Subject);
            if (ReferenceEquals(subject, commit.Subject))
                continue;
            sanitized ??= [.. commits];
            sanitized[i] = commit with { Subject = subject };
        }

        return sanitized is null ? snapshot : snapshot with { Commits = sanitized };
    }

    /// <summary>The graph's and the sidebar's data for <paramref name="snapshot"/>: the worktrees, badges and refs as
    /// read last.</summary>
    private GraphData Data(RepoSnapshot snapshot, WorktreeFade? fade) =>
        new(snapshot, _worktrees, fade, _badges, _refs, _worktreesRead);

    /// <summary>Hands <paramref name="data"/> to the UI thread, in place of any data still waiting. Any thread.</summary>
    private void Post(GraphData data)
    {
        lock (_gate)
        {
            _pending = data;
            if (_drainQueued)
                return;
            _drainQueued = true;
        }

        Enqueue();
    }

    private void PostFailure(string message)
    {
        lock (_gate)
        {
            _failure = message;
            if (_drainQueued)
                return;
            _drainQueued = true;
        }

        Enqueue();
    }

    private void Enqueue()
    {
        DispatcherQueue? dispatcher;
        lock (_gate)
        {
            dispatcher = _dispatcher;
            // No UI thread yet (a launch session): Attach queues the drain.
            if (dispatcher is null)
            {
                _drainQueued = false;
                return;
            }
        }

        if (!dispatcher.TryEnqueue(Drain))
        {
            // The UI thread is shutting down: nothing is shown any more.
            lock (_gate)
                _drainQueued = false;
        }
    }

    /// <summary>UI thread: raises the waiting data or failure, unless disposed.</summary>
    private void Drain()
    {
        GraphData? data;
        string? failure;
        RepoViewState? view;
        lock (_gate)
        {
            (data, failure, view) = (_pending, _failure, _pendingView);
            _pending = null;
            _failure = null;
            _pendingView = null;
            _drainQueued = false;
        }

        if (_disposed)
            return;
        try
        {
            if (view is not null)
                ViewLoaded?.Invoke(view);
            if (data is not null)
                Loaded?.Invoke(data);
            else if (failure is not null)
                Failed?.Invoke(failure);
        }
        catch (Exception error)
        {
            // A dispatcher callback that throws ends the app; the graph keeps what it shows.
            CrashLog.Recovered("RepoTabSession.Drain (rows not shown)", error);
        }
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

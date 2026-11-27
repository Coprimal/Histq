// Reads a repo's log and lays out its graph, off the UI thread: the first load streams the history page by page (the
// first page can be shown before git has finished), a reload first tries to read only the commits that are new since
// the last complete log and falls back to the whole history whenever that cannot be proven to give the same commits.
// Every git call runs with the read environment (filter and diff drivers disabled, no profile). Ported from readLog,
// readLogIncrementally, beginLayout, layOutAll, syntheticRows and the incremental reload's conditions of loadLog in
// App/Repo/RepoSession.swift at 6fa6d40.
namespace Histq.Core;

/// <summary>
/// One repo folder's log loads. Holds no UI state; safe to use from any thread, several loads at once (a newer load
/// cancels the older one through its token, the caller's job).
/// </summary>
/// <param name="runner">The git to run.</param>
/// <param name="cwd">The worktree's folder.</param>
/// <param name="base">The read base environment (<see cref="GitInvocation.BaseEnvironment"/>): never the write one,
/// and never with a profile, since an automatic read of an untrusted repo needs no identity, signing or SSH key.</param>
/// <param name="cache">The driver listings shared by every tab's reads; null lists them on every load.</param>
public sealed class RepoLoader(
    GitRunner runner, string cwd, IReadOnlyDictionary<string, string> @base, ReadEnvironmentCache? cache = null)
{
    /// <summary>The repo's common dir and bareness, resolved on first use; a race resolves them twice the same.</summary>
    private RepoInfo? _info;

    /// <summary>The order the commitOrder preference stores: <c>"branch"</c> is by branch, anything else by date.</summary>
    public static LogReader.Order OrderFrom(string? stored) =>
        string.Equals(stored, "branch", StringComparison.Ordinal) ? LogReader.Order.Branch : LogReader.Order.Date;

    /// <summary>
    /// The coloring of the laneColors preference: <c>"gradient"</c> colors by column, anything else (Vivid) by branch.
    /// </summary>
    public static GraphLayout.Coloring ColoringFrom(string? stored) =>
        string.Equals(stored, "gradient", StringComparison.Ordinal)
            ? GraphLayout.Coloring.Column
            : GraphLayout.Coloring.Branch;

    /// <summary>
    /// The synthetic rows: the WIP row when the working tree has changes (hanging from HEAD, above the commits), then
    /// one per other worktree with changes (right above its HEAD), then the stashes (each right above the commit it was
    /// made on), newest first.
    /// </summary>
    /// <param name="worktrees">The other worktrees with changes, in <c>git worktree list</c> order.</param>
    public static IReadOnlyList<GraphSyntheticRow> SyntheticRows(
        WorkingStatus status, IReadOnlyList<Stash> stashes, IReadOnlyList<Worktree> worktrees)
    {
        var rows = new List<GraphSyntheticRow>();
        if (status.Entries.Count > 0)
        {
            rows.Add(new GraphSyntheticRow(GraphSyntheticRowKind.Wip, "wip", status.Branch.Commit));
        }

        rows.AddRange(worktrees.Select(worktree =>
            new GraphSyntheticRow(GraphSyntheticRowKind.WorktreeWip, worktree.Path, worktree.Head)));
        rows.AddRange(stashes.Select(stash => new GraphSyntheticRow(GraphSyntheticRowKind.Stash, stash.Hash, stash.Base)));
        return rows;
    }

    /// <summary>
    /// Reads the whole log and lays it out below the WIP and stash rows (the status and the stashes are read alongside
    /// the common dir, before git walks the history). <paramref name="firstPage"/> gets a snapshot of the first page,
    /// laid out, as soon as it is ready (not complete; never for a repo without commits). Throws
    /// <see cref="GitError"/>, <see cref="GraphTooWideException"/>, and <see cref="OperationCanceledException"/> when
    /// <paramref name="ct"/> is cancelled.
    /// </summary>
    /// <param name="generation">The load's number, in both snapshots (<see cref="RepoSnapshot.Generation"/>).</param>
    /// <param name="filter">The hidden, soloed and pinned branches.</param>
    /// <param name="worktrees">The other worktrees with changes, see <see cref="SyntheticRows"/>.</param>
    public async Task<RepoSnapshot> LoadAsync(
        int generation, LogFilter filter, IReadOnlyList<Worktree> worktrees, LogReader.Order order,
        GraphLayout.Coloring coloring, Func<RepoSnapshot, Task>? firstPage = null, CancellationToken ct = default)
    {
        var env = await ReadEnvironmentAsync(ct).ConfigureAwait(false);
        // The status runs beside the stashes and the history: it is awaited only when the first rows are laid out.
        using var statusCancel = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var info = InfoAsync(env, ct);
        var status = StartStatus(env, info, statusCancel.Token);
        try
        {
            var (stashes, commonDir) = await StashesAndCommonDirAsync(env, info, ct).ConfigureAwait(false);
            var isShallow = IsShallow(commonDir);
            // The stashes' bases are read too, which no branch may hold any more (not in solo mode).
            var pages = LogReader.PagesAsync(
                runner, cwd, env, alsoFrom: filter.Solo.Count == 0 ? stashes.Select(stash => stash.Base).ToList() : [],
                hidden: Sorted(filter.Hidden), solo: filter.Solo, order: order, ct: ct);
            var index = new Dictionary<string, int>(StringComparer.Ordinal);
            IReadOnlyList<GraphSyntheticRow> synthetic = [];
            WorkingStatus? read = null;
            GraphLayout? layout = null;
            GraphLayout? top = null;
            List<GraphRow> syntheticRows = [];
            var commits = new List<Commit>();
            var rows = new List<GraphRow>();
            var lanes = 0;

            // Once git has started on the history (or ended without a commit): the status, then the top rows.
            async Task<GraphLayout> BeginAsync()
            {
                read = await status.ConfigureAwait(false);
                synthetic = SyntheticRows(read, stashes, worktrees);
                (layout, top, syntheticRows) = BeginLayout(synthetic, filter, coloring, isComplete: false, index);
                lanes = LanesOf(syntheticRows);
                return layout;
            }

            await foreach (var page in pages.ConfigureAwait(false))
            {
                var isFirst = layout is null;
                var pageLayout = layout ?? await BeginAsync().ConfigureAwait(false);
                for (var offset = 0; offset < page.Count; offset++)
                {
                    index[page[offset].Hash] = commits.Count + offset;
                }

                commits.AddRange(page);
                var pageRows = pageLayout.Append(page, ct);
                rows.AddRange(pageRows);
                lanes = Math.Max(lanes, Math.Max(LanesOf(pageRows), LanesOf(pageLayout.Hung.Select(hung => hung.Row))));
                if (isFirst && firstPage is not null)
                {
                    // Its own copies: the lists keep growing here while the first page is shown.
                    await firstPage(new RepoSnapshot
                    {
                        Commits = commits.ToArray(), Rows = rows.ToArray(), SyntheticRows = syntheticRows.ToArray(),
                        Hung = pageLayout.Hung.ToArray(), Synthetic = synthetic, Stashes = stashes,
                        CommitIndex = new Dictionary<string, int>(index, StringComparer.Ordinal), Lanes = lanes,
                        Worktrees = worktrees, IsShallow = isShallow, Generation = generation, Filter = filter,
                        Order = order, Coloring = coloring, Status = read,
                    }).ConfigureAwait(false);
                }
            }

            ct.ThrowIfCancellationRequested();
            var finalLayout = layout ?? await BeginAsync().ConfigureAwait(false);
            syntheticRows.AddRange(top!.Append(Unbased(finalLayout.Waiting)));
            return new RepoSnapshot
            {
                Commits = commits, Rows = rows, SyntheticRows = syntheticRows, Hung = finalLayout.Hung.ToArray(),
                Synthetic = synthetic, Stashes = stashes, CommitIndex = index, Tips = LogReader.Tips(commits, index),
                Lanes = Math.Max(lanes, LanesOf(syntheticRows)), Worktrees = worktrees, IsComplete = true,
                // Made shallow while git read the history: the next reload must not trust it.
                IsShallow = isShallow || IsShallow(commonDir), Generation = generation, Filter = filter,
                Order = order, Coloring = coloring, Status = read,
            };
        }
        finally
        {
            // A load that ended early stops a status read still running.
            await statusCancel.CancelAsync().ConfigureAwait(false);
        }
    }

    /// <summary>
    /// The log after a change: read incrementally from <paramref name="previous"/> when it is complete and was read with
    /// the same hidden branches, none soloed (in either), in the same order and coloring (<see cref="ReloadIncrementallyAsync"/>);
    /// else, or when that read is in doubt or fails, the whole log (<see cref="LoadAsync"/>, no first page). Hiding,
    /// showing or soloing a branch, or changing the order or the colors, reads the whole log again (a soloed log always).
    /// Throws as <see cref="LoadAsync"/>.
    /// </summary>
    public async Task<RepoSnapshot> ReloadAsync(
        RepoSnapshot previous, int generation, LogFilter filter, IReadOnlyList<Worktree> worktrees,
        LogReader.Order order, GraphLayout.Coloring coloring, CancellationToken ct = default)
    {
        if (previous.IsComplete && filter.Hidden.SetEquals(previous.Filter.Hidden) && filter.Solo.Count == 0
            && previous.Filter.Solo.Count == 0 && previous.Order == order && previous.Coloring == coloring)
        {
            try
            {
                if (await ReloadIncrementallyAsync(previous, generation, filter, worktrees, ct).ConfigureAwait(false)
                    is { } incremental)
                {
                    return incremental;
                }
            }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                // A failed incremental read is a doubt too: the whole log is read below. A cancellation is not.
            }
        }

        return await LoadAsync(generation, filter, worktrees, order, coloring, ct: ct).ConfigureAwait(false);
    }

    /// <summary>
    /// The log after a reload, from <paramref name="previous"/> (a complete snapshot) and only the commits that are new
    /// since it (<see cref="LogReader.NewCommitsAsync"/>), with the status and stashes read again and every row laid out
    /// again. Null when the new commits cannot be proven to be the whole difference (a commit of
    /// <paramref name="previous"/> no longer reachable, a shallow repo, a graft file or a replace ref): the caller reads
    /// the whole log. <paramref name="filter"/> must have <paramref name="previous"/>'s hidden branches and no soloed one,
    /// and the order and coloring are <paramref name="previous"/>'s (<see cref="ReloadAsync"/> checks); its pinned tips
    /// (which move with their branches) lay the rows out.
    /// <para>
    /// The result has the same commits as a fresh read, children before parents, the commits of
    /// <paramref name="previous"/> in their order. By branch the new ones come on top, not always where git's
    /// <c>--topo-order</c> puts them: after a commit on a branch other than the newest one, a fresh read would list that
    /// branch's whole line first. By date they are merged in by committer date (<see cref="LogReader.MergedByDate"/>),
    /// where a fresh <c>--date-order</c> read puts them unless committer dates are skewed (a child older than its
    /// parent) or equal.
    /// </para>
    /// </summary>
    internal async Task<RepoSnapshot?> ReloadIncrementallyAsync(
        RepoSnapshot previous, int generation, LogFilter filter, IReadOnlyList<Worktree> worktrees,
        CancellationToken ct)
    {
        if (!previous.IsComplete || previous.IsShallow)
        {
            return null;
        }

        var env = await ReadEnvironmentAsync(ct).ConfigureAwait(false);
        // The status runs beside the stashes and the new commits; it is awaited only for the top rows.
        using var statusCancel = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var info = InfoAsync(env, ct);
        var status = StartStatus(env, info, statusCancel.Token);
        try
        {
            return await ReloadIncrementallyAsync(previous, generation, filter, worktrees, env, info, status, ct)
                .ConfigureAwait(false);
        }
        finally
        {
            // A reload that ended early (in doubt, failed, cancelled) stops a status read still running.
            await statusCancel.CancelAsync().ConfigureAwait(false);
        }
    }

    /// <summary><see cref="ReloadIncrementallyAsync(RepoSnapshot, int, LogFilter, IReadOnlyList{Worktree}, CancellationToken)"/>
    /// with the read environment and the status read in flight.</summary>
    private async Task<RepoSnapshot?> ReloadIncrementallyAsync(
        RepoSnapshot previous, int generation, LogFilter filter, IReadOnlyList<Worktree> worktrees,
        IReadOnlyDictionary<string, string> env, Task<RepoInfo> info, Task<WorkingStatus> status, CancellationToken ct)
    {
        var (stashes, commonDir) = await StashesAndCommonDirAsync(env, info, ct).ConfigureAwait(false);
        if (commonDir is null || IsShallow(commonDir) || File.Exists(Path.Combine(commonDir, "info", "grafts")))
        {
            return null;
        }

        var order = previous.Order;
        var delta = await LogReader.NewCommitsAsync(
            runner, cwd, env, previous.Tips, stashes.Select(stash => stash.Base).ToList(), Sorted(filter.Hidden),
            order, ct).ConfigureAwait(false);
        if (delta is null || delta.Any(commit => previous.CommitIndex.ContainsKey(commit.Hash)))
        {
            return null;
        }

        ct.ThrowIfCancellationRequested();
        IReadOnlyList<Commit> commits;
        IReadOnlyDictionary<string, int> index;
        if (delta.Count == 0)
        {
            commits = previous.Commits;
            index = previous.CommitIndex;
        }
        else
        {
            commits = order == LogReader.Order.Date
                ? LogReader.MergedByDate(delta, previous.Commits, previous.CommitIndex)
                : [.. delta, .. previous.Commits];
            var newIndex = new Dictionary<string, int>(commits.Count, StringComparer.Ordinal);
            for (var position = 0; position < commits.Count; position++)
            {
                newIndex[commits[position].Hash] = position;
            }

            index = newIndex;
        }

        ct.ThrowIfCancellationRequested();
        // Laid out as complete: a WIP base or a hung row's base missing from the log goes on top without a line.
        var read = await status.ConfigureAwait(false);
        var synthetic = SyntheticRows(read, stashes, worktrees);
        var (layout, top, syntheticRows) = BeginLayout(synthetic, filter, previous.Coloring, isComplete: true, index);
        var rows = layout.Append(commits, ct);
        syntheticRows.AddRange(top.Append(Unbased(layout.Waiting)));
        var hung = layout.Hung.ToArray();
        ct.ThrowIfCancellationRequested();
        return new RepoSnapshot
        {
            Commits = commits, Rows = rows, SyntheticRows = syntheticRows, Hung = hung, Synthetic = synthetic,
            Stashes = stashes, CommitIndex = index, Tips = LogReader.TipsAdding(delta, previous.Tips),
            Lanes = Math.Max(LanesOf(syntheticRows), Math.Max(LanesOf(rows), LanesOf(hung.Select(row => row.Row)))),
            Worktrees = worktrees, IsComplete = true, Generation = generation, Filter = filter, Order = order,
            Coloring = previous.Coloring, Status = read,
        };
    }

    /// <summary>
    /// The status and the stashes now, read as a load reads them (the cached common dir and bareness): a bare repo has
    /// no changes (an empty status) and no stash. For the checks between loads, which compare them with a snapshot's.
    /// Throws <see cref="GitError"/> and <see cref="OperationCanceledException"/>.
    /// </summary>
    public async Task<(WorkingStatus Status, IReadOnlyList<Stash> Stashes)> StatusAndStashesAsync(
        CancellationToken ct = default)
    {
        var env = await ReadEnvironmentAsync(ct).ConfigureAwait(false);
        var info = InfoAsync(env, ct);
        var status = StartStatus(env, info, ct);
        var (stashes, _) = await StashesAndCommonDirAsync(env, info, ct).ConfigureAwait(false);
        return (await status.ConfigureAwait(false), stashes);
    }

    /// <summary>The read environment for this folder, built once per load (its driver listing cached in <c>cache</c>).</summary>
    private Task<Dictionary<string, string>> ReadEnvironmentAsync(CancellationToken ct) =>
        GitInvocation.ReadEnvironmentAsync(null, @base, runner, cwd, cache, ct);

    /// <summary>
    /// Starts reading the status. A failure is marked observed at once, so a load that ends before awaiting it (in doubt,
    /// failed, cancelled) leaves no unobserved task exception; a load that awaits it still gets the failure. A bare repo
    /// (no working tree, so git refuses the status) has no changes: no WIP row.
    /// </summary>
    private Task<WorkingStatus> StartStatus(
        IReadOnlyDictionary<string, string> env, Task<RepoInfo> info, CancellationToken ct)
    {
        var status = StatusOrNoneAsync(env, info, ct);
        _ = status.ContinueWith(
            static task => _ = task.Exception, CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        return status;
    }

    private async Task<WorkingStatus> StatusOrNoneAsync(
        IReadOnlyDictionary<string, string> env, Task<RepoInfo> info, CancellationToken ct)
    {
        try
        {
            return await StatusReader.ReadAsync(runner, cwd, env, ct).ConfigureAwait(false);
        }
        catch (GitError)
        {
            if ((await info.ConfigureAwait(false)).IsBare)
            {
                return new WorkingStatus(new WorkingStatusBranch(null, null, null, null, null), []);
            }

            throw;
        }
    }

    /// <summary>The stashes and the common dir, read side by side. A bare repo has no stash list (git refuses it
    /// without a working tree): no stash row.</summary>
    private async Task<(IReadOnlyList<Stash> Stashes, string? CommonDir)> StashesAndCommonDirAsync(
        IReadOnlyDictionary<string, string> env, Task<RepoInfo> info, CancellationToken ct)
    {
        IReadOnlyList<Stash> stashes;
        try
        {
            stashes = await StashWorktreeReader.StashesAsync(runner, cwd, env, ct).ConfigureAwait(false);
        }
        catch (GitError)
        {
            if (!(await info.ConfigureAwait(false)).IsBare)
            {
                throw;
            }

            stashes = [];
        }

        return (stashes, (await info.ConfigureAwait(false)).CommonDir);
    }

    /// <summary>
    /// The git dir every worktree of the repo shares (where <c>shallow</c> and <c>info/grafts</c> live) as its real
    /// path, and whether the repo is bare; read with <c>rev-parse</c> alone, which needs no working tree. The common dir
    /// is null when it cannot be had or is a network (UNC) or device path, which Histq never probes itself: the log is
    /// then read as if shallow (a reload reads it whole). Throws only a cancellation.
    /// </summary>
    private async Task<RepoInfo> InfoAsync(IReadOnlyDictionary<string, string> env, CancellationToken ct)
    {
        if (Volatile.Read(ref _info) is { } known)
        {
            return known;
        }

        RepoInfo resolved;
        try
        {
            var result = await runner.RunAsync(
                ["rev-parse", "--path-format=absolute", "--git-common-dir", "--is-bare-repository"], cwd, env,
                timeout: TimeSpan.FromSeconds(10), ct: ct).ConfigureAwait(false);
            var lines = result.Text.Split('\n');
            resolved = new RepoInfo(
                lines.Length > 0 ? LocalFolder(lines[0].TrimEnd('\r')) : null,
                lines.Length > 1 && string.Equals(lines[1].Trim(), "true", StringComparison.Ordinal));
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            return new RepoInfo(null, false);
        }

        Volatile.Write(ref _info, resolved);
        return resolved;
    }

    /// <summary><paramref name="output"/> (a folder git printed) as a local real path; null for a network or device
    /// path (checked before any file system call and again on the real path) or one that cannot be had.</summary>
    private static string? LocalFolder(string output)
    {
        var flavor = PathFlavor.Host;
        if (output.Length == 0 || flavor.IsUncOrDevice(output))
        {
            return null;
        }

        var native = StashWorktreeReader.NativePath(output);
        if (flavor.IsUncOrDevice(native) || !flavor.IsAbsolute(native))
        {
            return null;
        }

        var real = WorkspaceDisk.Host.RealPath(native);
        return real is null || flavor.IsUncOrDevice(real) ? null : real;
    }

    /// <summary>Whether the repo is a shallow clone now (<c>&lt;common dir&gt;/shallow</c> exists); an unknown common
    /// dir counts as shallow, so a reload never trusts the history it read.</summary>
    private static bool IsShallow(string? commonDir) =>
        commonDir is null || File.Exists(Path.Combine(commonDir, "shallow"));

    /// <summary>The repo's common dir (null when unknown or remote) and whether it is bare (<see cref="InfoAsync"/>).</summary>
    private sealed record RepoInfo(string? CommonDir, bool IsBare);

    /// <summary>
    /// Lays out the WIP row at the top and hangs the other worktrees' rows and the stashes above their bases (another
    /// worktree's changes sit on its HEAD, not above every commit). Returns the layout to feed the commits, the top rows'
    /// layout (the hung rows whose base never came are laid out with it once the log is complete, at the top without a
    /// line, so they open no lane and the commit rows stay as they are) and the top rows so far. The pinned branches
    /// take the leftmost lanes.
    /// </summary>
    private static (GraphLayout Layout, GraphLayout Top, List<GraphRow> SyntheticRows) BeginLayout(
        IReadOnlyList<GraphSyntheticRow> synthetic, LogFilter filter, GraphLayout.Coloring coloring, bool isComplete,
        IReadOnlyDictionary<string, int> index)
    {
        var layout = new GraphLayout(filter.Pinned, coloring);
        var wip = synthetic.Where(row => row.Kind == GraphSyntheticRowKind.Wip)
            .Select(row => isComplete && row.Base is { } baseHash && !index.ContainsKey(baseHash) ? row with { Base = null } : row)
            .ToList();
        var syntheticRows = new List<GraphRow>(layout.Append(wip));
        var top = layout.Copy();
        layout.Hang(synthetic.Where(row => row.Kind != GraphSyntheticRowKind.Wip).ToList());
        return (layout, top, syntheticRows);
    }

    /// <summary>The rows without their base, to go at the top without a line.</summary>
    private static List<GraphSyntheticRow> Unbased(IReadOnlyList<GraphSyntheticRow> rows) =>
        rows.Select(row => new GraphSyntheticRow(row.Kind, row.Id, null)).ToList();

    /// <summary>The most lanes one of <paramref name="rows"/> draws in (<see cref="RepoSnapshot.Lanes"/>).</summary>
    private static int LanesOf(IEnumerable<GraphRow> rows) => rows.Select(row => row.Width).DefaultIfEmpty(0).Max();

    /// <summary>The hidden refs in a fixed order, so the same set always gives the same git command.</summary>
    private static List<string> Sorted(IReadOnlySet<string> hidden) => hidden.Order(StringComparer.Ordinal).ToList();
}

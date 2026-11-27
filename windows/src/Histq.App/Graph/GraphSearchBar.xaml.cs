using System.Globalization;
using Histq.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;

namespace Histq.App.Graph;

/// <summary>
/// The graph's search bar (GraphSearchBar in App/Graph/GraphSearchBar.swift at 6fa6d40), over the bottom of the graph
/// card, hidden until <see cref="Open"/> (Ctrl+F). Typing searches (<see cref="GraphSearch"/>); Enter and the down
/// button go to the next match, Shift+Enter and the up button to the previous one, Esc and the close button close the
/// bar, clear the query and the dimming, keep the selection and give the graph the focus back.
/// </summary>
public sealed partial class GraphSearchBar : UserControl
{
    private readonly GraphView _graph;
    private readonly GraphSearch _search;

    internal GraphSearchBar(GraphView graph)
    {
        _graph = graph;
        InitializeComponent();
        Visibility = Visibility.Collapsed;
        _search = new GraphSearch(graph, DispatcherQueue.GetForCurrentThread(), () => IsOpen ? ActualHeight : 0);
        _search.Changed += ShowState;
    }

    /// <summary>The bar shows.</summary>
    internal bool IsOpen => Visibility == Visibility.Visible;

    /// <summary>Ctrl+F: shows the bar (or, while open, focuses it again), its query selected, and starts indexing the
    /// log so the first keystroke only searches.</summary>
    internal void Open()
    {
        Visibility = Visibility.Visible;
        _search.Open();
        // The bar is laid out on this turn: the field takes the focus on the next one.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!IsOpen)
                return;
            QueryBox.Focus(FocusState.Programmatic);
            QueryBox.SelectAll();
        });
    }

    /// <summary>Esc: hides the bar, clears the query and the dimming, keeps the selection; the graph gets the focus.</summary>
    internal void Close()
    {
        if (!IsOpen)
            return;
        Visibility = Visibility.Collapsed;
        QueryBox.Text = string.Empty;
        _search.Close();
        _graph.Canvas.Focus(FocusState.Programmatic);
    }

    /// <summary>The graph is gone: no search result is applied any more.</summary>
    internal void Release() => _search.Close();

    private void OnQueryChanged(object sender, TextChangedEventArgs e) => _search.SetQuery(QueryBox.Text);

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Enter:
                bool shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                    .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                if (shift)
                    _search.Previous();
                else
                    _search.Next();
                break;
            case VirtualKey.Escape:
                Close();
                break;
            default:
                return;
        }

        e.Handled = true;
    }

    private void OnPreviousClick(object sender, RoutedEventArgs e) => _search.Previous();

    private void OnNextClick(object sender, RoutedEventArgs e) => _search.Next();

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void ShowState()
    {
        SummaryText.Text = _search.Summary;
        bool any = _search.Matches.Count > 0;
        PreviousButton.IsEnabled = any;
        NextButton.IsEnabled = any;
    }
}

/// <summary>
/// A repo tab's graph search (GraphSearch in App/Graph/GraphSearchBar.swift at 6fa6d40). Each query change searches the
/// log's commits and stash messages off the UI thread (<see cref="CommitSearch"/>, on an index of the log built once per
/// snapshot) and cancels the search before it; a new snapshot searches again. A typed query goes to its first match at
/// or after the selected row (wrapping to the first); a new snapshot keeps the current match when its row is still
/// there. Going to a match selects its row as a click does and centres it when it is off screen; while a query has
/// matches the other rows' text dims. UI thread, but the searching.
/// </summary>
internal sealed class GraphSearch
{
    private readonly GraphView _graph;
    private readonly DispatcherQueue _dispatcher;
    private readonly Func<double> _bottomInset;

    private string _query = string.Empty;
    private bool _isOpen;

    /// <summary>The matches' rows in the searched snapshot, top first.</summary>
    private long[] _matchRows = [];

    /// <summary>The snapshot the matches were found in, and the one the index is (being) built for.</summary>
    private SnapshotKey? _searched;
    private SnapshotKey? _indexKey;
    private Task<CommitSearch.Index>? _index;
    private CancellationTokenSource? _indexCancel;
    private CancellationTokenSource? _cancel;

    /// <summary>New for each search; an older one's result is dropped.</summary>
    private int _generation;

    /// <summary>The current match, kept across a new snapshot.</summary>
    private GraphItem? _currentItem;

    /// <summary>The typed query has not gone to a match yet: the next result, also of a new snapshot, goes to its first.</summary>
    private bool _pendingJump;

    /// <param name="bottomInset">What the open bar covers of the graph's bottom: a match under it counts as hidden.</param>
    public GraphSearch(GraphView graph, DispatcherQueue dispatcher, Func<double> bottomInset)
    {
        _graph = graph;
        _dispatcher = dispatcher;
        _bottomInset = bottomInset;
        graph.DataChanged += OnDataChanged;
    }

    /// <summary>The matches, the current one or the summary changed.</summary>
    public event Action? Changed;

    /// <summary>The matching commits and stashes, top row first.</summary>
    public IReadOnlyList<GraphItem> Matches { get; private set; } = [];

    /// <summary><see cref="Matches"/>' index of the current match; null until the search goes to one.</summary>
    public int? Current { get; private set; }

    /// <summary><see cref="Matches"/> belong to the current query.</summary>
    public bool IsFresh { get; private set; } = true;

    /// <summary>"3 of 12", "No results", or nothing without a query; with " · loading" while the log is still read.</summary>
    public string Summary
    {
        get
        {
            if (string.IsNullOrWhiteSpace(_query))
                return string.Empty;
            string text = Matches.Count == 0
                ? (IsFresh ? "No results" : string.Empty)
                : string.Create(CultureInfo.CurrentCulture, $"{(Current ?? -1) + 1} of {Matches.Count}");
            bool loading = _graph.Data?.Snapshot.IsComplete == false;
            return loading ? (text.Length == 0 ? "loading" : text + " · loading") : text;
        }
    }

    public void Open()
    {
        _isOpen = true;
        if (_graph.Data is { } data)
            _ = Index(data.Snapshot);
    }

    public void Close()
    {
        if (!_isOpen)
            return;
        _isOpen = false;
        SetQuery(string.Empty);
        StopIndex();
    }

    public void SetQuery(string query)
    {
        if (string.Equals(query, _query, StringComparison.Ordinal))
            return;
        _query = query;
        Search(jump: true);
    }

    /// <summary>Enter: the next match, from the last to the first.</summary>
    public void Next()
    {
        // While a new query is searched, the matches are the last query's: its result goes to a match itself.
        if (!IsFresh || Matches.Count == 0)
            return;
        Go(Current is { } current ? (current + 1) % Matches.Count : FirstAtOrAfterSelection());
    }

    /// <summary>Shift+Enter: the previous match, from the first to the last.</summary>
    public void Previous()
    {
        if (!IsFresh || Matches.Count == 0)
            return;
        Go(Current is { } current ? (current - 1 + Matches.Count) % Matches.Count : FirstAtOrAfterSelection());
    }

    private void OnDataChanged(GraphData data)
    {
        if (_isOpen && new SnapshotKey(data.Snapshot) != _searched)
            Search(jump: _pendingJump);
    }

    /// <summary>The index of <paramref name="snapshot"/>'s commits, then its stashes (as commits with the stash's
    /// message): the one being built for this snapshot's rows, else a new build off the UI thread, which cancels the
    /// build for an older snapshot (only the latest is ever searched; a status-only update keeps the rows and the
    /// index).</summary>
    private Task<CommitSearch.Index> Index(RepoSnapshot snapshot)
    {
        var key = new SnapshotKey(snapshot);
        if (key == _indexKey && _index is { } built)
            return built;
        StopIndex();
        var cancel = new CancellationTokenSource();
        CancellationToken ct = cancel.Token;
        _indexCancel = cancel;
        _indexKey = key;
        _index = Task.Run(() =>
        {
            var commits = new List<Commit>(snapshot.Commits.Count + snapshot.Stashes.Count);
            commits.AddRange(snapshot.Commits);
            commits.AddRange(snapshot.Stashes.Select(stash =>
                new Commit(stash.Hash, [], "", "", stash.Date, stash.Date, stash.Message, "")));
            // Cancelled, it gives an empty index: a search on it is for an older snapshot, whose result is dropped.
            return new CommitSearch.Index(commits, ct);
        }, CancellationToken.None);
        return _index;
    }

    /// <summary>Cancels the index build in flight and forgets the index.</summary>
    private void StopIndex()
    {
        _indexCancel?.Cancel();
        _indexCancel?.Dispose();
        _indexCancel = null;
        _index = null;
        _indexKey = null;
    }

    /// <summary>Searches the shown snapshot for the query off the UI thread, cancelling the search before it.
    /// <paramref name="jump"/>: a typed query, which goes to its first match at or after the selection.</summary>
    private void Search(bool jump)
    {
        _generation++;
        _cancel?.Cancel();
        _cancel?.Dispose();
        _cancel = null;
        string query = _query;
        bool blank = string.IsNullOrWhiteSpace(query);
        if (jump || blank)
            _pendingJump = !blank;
        if (blank || _graph.Data is not { } data)
        {
            Matches = [];
            _matchRows = [];
            Current = null;
            _currentItem = null;
            _searched = null;
            IsFresh = true;
            _graph.SetDimming(null);
            Changed?.Invoke();
            return;
        }

        IsFresh = false;
        int generation = _generation;
        RepoSnapshot snapshot = data.Snapshot;
        Task<CommitSearch.Index> index = Index(snapshot);
        var cancel = new CancellationTokenSource();
        _cancel = cancel;
        CancellationToken ct = cancel.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                CommitSearch.Index built = await index.ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                Found found = Placed(CommitSearch.Matches(built, query, ct), snapshot);
                ct.ThrowIfCancellationRequested();
                _dispatcher.TryEnqueue(() => Adopt(found, new SnapshotKey(snapshot), generation, jump));
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception error)
            {
                System.Diagnostics.Debug.WriteLine($"GraphSearch: search failed: {error.Message}");
            }
        }, CancellationToken.None);
        Changed?.Invoke();
    }

    /// <summary>A search's matches as the graph shows them.</summary>
    private sealed record Found(GraphItem[] Items, long[] Rows, bool[] Matched, HashSet<string> Stashes);

    /// <summary>The index's matches (the commits, then the stashes) top row first, with their rows; a stash without a
    /// row yet (its base not read yet) is left out.</summary>
    private static Found Placed(int[] found, RepoSnapshot snapshot)
    {
        var placed = new List<(long Row, GraphItem Item)>(found.Length);
        var matched = new bool[snapshot.Commits.Count];
        var stashes = new HashSet<string>(StringComparer.Ordinal);
        foreach (int item in found)
        {
            if (item < snapshot.Commits.Count)
            {
                matched[item] = true;
                placed.Add((snapshot.RowOfCommit(item), new GraphItem(GraphItemKind.Commit, snapshot.Commits[item].Hash)));
            }
            else if (item - snapshot.Commits.Count < snapshot.Stashes.Count)
            {
                string hash = snapshot.Stashes[item - snapshot.Commits.Count].Hash;
                long row = snapshot.RowOfSynthetic(GraphSyntheticRowKind.Stash, hash);
                if (row < 0)
                    continue;
                stashes.Add(hash);
                placed.Add((row, new GraphItem(GraphItemKind.Stash, hash)));
            }
        }

        // Commits come in row order; a stash's row is among them.
        if (stashes.Count > 0)
            placed.Sort((a, b) => a.Row.CompareTo(b.Row));
        return new Found([.. placed.Select(p => p.Item)], [.. placed.Select(p => p.Row)], matched, stashes);
    }

    private void Adopt(Found found, SnapshotKey key, int generation, bool jump)
    {
        if (generation != _generation || !_isOpen || _graph.Data is not { } data || new SnapshotKey(data.Snapshot) != key)
            return;
        Matches = found.Items;
        _matchRows = found.Rows;
        _searched = key;
        IsFresh = true;
        _graph.SetDimming(found.Items.Length == 0
            ? null
            : new GraphDimming(key.Generation, key.Rows, found.Matched, found.Stashes));
        if (jump)
        {
            Current = null;
            _currentItem = null;
            if (found.Items.Length == 0)
            {
                // The whole log has no match: a later snapshot (a refresh) does not move the selection on its own.
                if (data.Snapshot.IsComplete)
                    _pendingJump = false;
            }
            else
            {
                Go(FirstAtOrAfterSelection());
                return;
            }
        }
        else
        {
            int index = _currentItem is { } item ? Array.IndexOf(found.Items, item) : -1;
            Current = index >= 0 ? index : null;
            if (Current is null)
                _currentItem = null;
        }

        Changed?.Invoke();
    }

    /// <summary>The first match at or after the selected row (the WIP row is above every match), else the first.</summary>
    private int FirstAtOrAfterSelection()
    {
        long anchor = _graph.SelectedItem is { Kind: GraphItemKind.Commit or GraphItemKind.Stash } selected
            ? Math.Max(0, _graph.RowOf(selected))
            : 0;
        int first = Array.FindIndex(_matchRows, row => row >= anchor);
        return first >= 0 ? first : 0;
    }

    /// <summary>Selects match <paramref name="position"/> as a click on its row does, centred when off screen.</summary>
    private void Go(int position)
    {
        if (position < 0 || position >= Matches.Count || _graph.Data is not { } data
            || new SnapshotKey(data.Snapshot) != _searched)
        {
            return;
        }

        GraphItem item = Matches[position];
        Current = position;
        _currentItem = item;
        _pendingJump = false;
        _graph.Select(item, _bottomInset());
        Changed?.Invoke();
    }

    /// <summary>What tells two snapshots' rows apart: their load, their commits and their rows (a stash whose base is
    /// not in the log gets its row only once the log is complete).</summary>
    private readonly record struct SnapshotKey(int Generation, int Count, long Rows)
    {
        public SnapshotKey(RepoSnapshot snapshot)
            : this(snapshot.Generation, snapshot.Commits.Count, snapshot.RowCount)
        {
        }
    }
}

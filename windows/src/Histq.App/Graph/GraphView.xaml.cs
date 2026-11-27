using Histq.App.Shell;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Histq.App.Graph;

/// <summary>What a graph row stands for (GraphItem in App/Graph/GraphView.swift at 6fa6d40): the selection follows it
/// across loads.</summary>
internal enum GraphItemKind
{
    Wip,
    Stash,
    Commit,
    Worktree,
}

/// <param name="Id">The stash's or commit's hash, the worktree's path; "wip" for the WIP row.</param>
internal readonly record struct GraphItem(GraphItemKind Kind, string Id);

/// <summary>
/// Which rows the graph search dims while its query has matches (GraphDimming in App/Graph/GraphSearchBar.swift at
/// 6fa6d40): the commits that do not match, the stashes that do not match, and the WIP and worktree rows; only for the
/// snapshot of <paramref name="Generation"/> and the commits the search saw.
/// </summary>
/// <param name="Matched"><c>Matched[i]</c>: <c>Commits[i]</c> matches.</param>
/// <param name="MatchedStashes">The matching stashes, by hash.</param>
internal sealed record GraphDimming(int Generation, long RowCount, bool[] Matched, IReadOnlySet<string> MatchedStashes);

/// <summary>Which worktrees reach each commit (<see cref="WorktreeReach.Masks"/>, by commit index) and this worktree's
/// bit: a commit only other worktrees reach is faded with its lines.</summary>
internal sealed record WorktreeFade(ulong[] Masks, ulong Head);

/// <summary>What a <see cref="GraphView"/> shows: a log snapshot, the repo's worktrees (another worktree's WIP row
/// shows its name and change counts), with graphFadeOtherWorktrees on which commits fade, and the commits' badges by
/// hash (<see cref="RefBadge.For"/>; none while the refs are not read). The sidebar reads the same data: the refs the
/// badges were made from (null while not read), and whether the worktree list was read yet.</summary>
internal sealed record GraphData(
    RepoSnapshot Snapshot, IReadOnlyList<WorktreeInfo> Worktrees, WorktreeFade? Fade,
    IReadOnlyDictionary<string, RefBadge[]>? Badges = null, Refs? Refs = null, bool WorktreesRead = false);

/// <summary>
/// The commit graph with its columns (ported from GraphView and GraphTableController, App/Graph/GraphView.swift at
/// 6fa6d40): the column titles over the rows, which <see cref="GraphCanvas"/> draws. The rows are the WIP row (when the
/// working tree has changes), a WIP row per other worktree with changes (labeled with its folder's name, grey and
/// faded), the stash rows, then the commits, as <see cref="RepoSnapshot.EntryAt"/> lays them.
/// <para>
/// Columns: their widths and the shown text columns are the app's (<see cref="WindowManager.GraphColumns"/>, the
/// graphColumnWidths and graphShow* preferences); the message column takes what the others leave, else the last shown
/// one; the graph column shows the width the user wants within the log's lanes. A drag of a title's right edge resizes
/// its column (the one right of the message column, and those after it, trade width with their right neighbour, as on
/// the Mac) and its end saves the widths for every graph; the header's context menu shows or hides the message, author
/// and date columns. Widths are set only from SizeChanged, pointer and settings events, never from a layout pass.
/// </para>
/// <para>
/// A new snapshot keeps the selected item (wip, stash, commit, worktree) selected wherever its row moved, and the top
/// rows on screen where they were (a new WIP row shows when the list was at its top). A right click on a row (or the
/// menu key on the selected one) asks for its menu (<see cref="RowMenuRequested"/>, <see cref="GraphMenus"/>); while
/// branches are left out a chip over the header's end says how many and shows them all (<see cref="ShowVisibility"/>).
/// The row density and the authors' emojis follow <see cref="WindowManager.GraphLookChanged"/> live; a row's UI
/// Automation name ends with its author's emoji when its avatar shows one. Not ported yet: several selected
/// rows, the lit worktree following the selection (this worktree's always is), the Open Worktree pill, the text size,
/// and the scroll position of a tab whose layout was unmounted (a kept layout keeps its own).
/// </para>
/// </summary>
public sealed partial class GraphView : UserControl
{
    private readonly WindowManager _manager;
    private readonly GraphDateFormatter _dates;
    private readonly Dictionary<GraphColumn, GraphColumnHeader> _headers = [];

    private GraphColumnSettings _settings;
    private Dictionary<GraphColumn, double> _widths;
    private GraphColumnLayout? _layout;
    private double _layoutWidth = -1;
    private int _logLanes;

    private SnapshotSource? _source;
    private GraphItem? _selected;
    private GraphDimming? _dimming;

    /// <summary>The dragged title's column, where the drag began (view X), the widths and layout then.</summary>
    private (GraphColumn Column, GraphColumnGrip Grip, double StartX, Dictionary<GraphColumn, double> Widths,
        GraphColumnLayout Layout)? _drag;

    private bool _released;

    /// <param name="name">The rows' name in UI Automation (the list of rows).</param>
    internal GraphView(WindowManager manager, string name)
    {
        _manager = manager;
        InitializeComponent();
        AutomationProperties.SetName(Rows, name);
        GraphLook look = manager.GraphLook;
        Rows.Metrics = look.Metrics;
        Rows.Avatars = new AvatarRenderer(look.AvatarMode, look.AuthorEmojis);
        _dates = new GraphDateFormatter(look.DateFormat);
        _settings = manager.GraphColumns;
        _widths = GraphColumns.Widths(_settings.EncodedWidths);

        foreach (GraphColumn column in GraphColumns.All)
        {
            HeaderGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0) });
            var header = new GraphColumnHeader(column);
            Grid.SetColumn(header, (int)column);
            header.Grip.PointerPressed += OnGripPressed;
            header.Grip.PointerMoved += OnGripMoved;
            header.Grip.PointerReleased += OnGripReleased;
            header.Grip.PointerCaptureLost += OnGripCaptureLost;
            HeaderGrid.Children.Add(header);
            _headers[column] = header;
        }

        Rows.RowSelected += OnRowSelected;
        Rows.RowContextRequested += OnRowContextRequested;
        Rows.ContextRequested += OnRowsContextRequested;
        SizeChanged += (_, e) =>
        {
            if (e.NewSize.Width != e.PreviousSize.Width)
                ApplyLayout();
        };
        _manager.GraphColumnsChanged += OnGraphColumnsChanged;
        _manager.GraphLookChanged += OnGraphLookChanged;
    }

    /// <summary>A row's menu is asked for (a right click, which selected it; the menu key or Shift+F10 on the selected
    /// one): its item and where in <see cref="Canvas"/> the menu opens (null: at the row). UI thread.</summary>
    internal event Action<GraphItem, Windows.Foundation.Point?>? RowMenuRequested;

    /// <summary>The visibility chip's Show All was clicked. UI thread.</summary>
    internal event Action? ShowAllRequested;

    /// <summary>The user selected a row: its item, null for none. UI thread.</summary>
    internal event Action<GraphItem?>? SelectionChanged;

    /// <summary>The selected row's item; null for none.</summary>
    internal GraphItem? SelectedItem => _selected;

    /// <summary>A new snapshot (or other data) is shown. UI thread.</summary>
    internal event Action<GraphData>? DataChanged;

    /// <summary>What the graph shows; null before the first data.</summary>
    internal GraphData? Data => _source?.Data;

    /// <summary>The rows' canvas (the probes press its rows).</summary>
    internal GraphCanvas Canvas => Rows;

    /// <summary>The row of <paramref name="item"/> in the shown data; -1 when it is not there.</summary>
    internal long RowOf(GraphItem item) => _source?.RowOf(item) ?? -1;

    /// <summary>The item of <paramref name="row"/>; null outside the rows.</summary>
    internal GraphItem? ItemAt(long row) => _source?.ItemAt(row);

    /// <summary>
    /// Selects <paramref name="item"/>'s row as a click does (<see cref="SelectionChanged"/> is raised when it is another
    /// row than the selected one) and scrolls it to the middle when it is not wholly in view above
    /// <paramref name="bottomInset"/> epx (the open search bar); false when the item has no row.
    /// </summary>
    internal bool Select(GraphItem item, double bottomInset = 0)
    {
        long row = RowOf(item);
        if (row < 0)
            return false;
        Rows.SelectByUser(row);
        Rows.CenterIfHidden(row, bottomInset);
        return true;
    }

    /// <summary>
    /// The chip over the header's end while branches are left out (GraphVisibilityChip): "2 hidden · Show All",
    /// "Solo · Show All" or both; hidden for none. Its UI Automation name is its text.
    /// </summary>
    internal void ShowVisibility(int hidden, bool solo)
    {
        string summary = string.Join(" · ", new[]
        {
            hidden > 0 ? hidden.ToString(System.Globalization.CultureInfo.InvariantCulture) + " hidden" : null,
            solo ? "Solo" : null,
        }.OfType<string>());
        Visibility shown = summary.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (!string.Equals(VisibilitySummary.Text, summary, StringComparison.Ordinal))
        {
            VisibilitySummary.Text = summary;
            AutomationProperties.SetName(VisibilityChip, summary + " · Show All");
        }

        if (VisibilityChip.Visibility != shown)
            VisibilityChip.Visibility = shown;
    }

    private void OnVisibilityChipClick(object sender, RoutedEventArgs e) => ShowAllRequested?.Invoke();

    private void OnRowContextRequested(long row, Windows.Foundation.Point position)
    {
        if (ItemAt(row) is { } item)
            RowMenuRequested?.Invoke(item, position);
    }

    /// <summary>The menu key or Shift+F10 (no pointer position): the selected row's menu. A pointer's right click is
    /// <see cref="GraphCanvas.RowContextRequested"/>.</summary>
    private void OnRowsContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if (e.TryGetPosition(Rows, out _))
            return;
        e.Handled = true;
        if (_selected is { } item)
            RowMenuRequested?.Invoke(item, null);
    }

    /// <summary>The row density or an author's emoji changed (<see cref="WindowManager.GraphLook"/>): the rows take the
    /// new height (the graph column its width) and the avatars are drawn again. Outside a draw and a layout pass.</summary>
    private void OnGraphLookChanged(object? sender, EventArgs e)
    {
        if (_released)
            return;
        GraphLook look = _manager.GraphLook;
        Rows.Metrics = look.Metrics;
        AvatarRenderer? old = Rows.Avatars;
        Rows.Avatars = new AvatarRenderer(look.AvatarMode, look.AuthorEmojis);
        old?.Dispose();
        _layoutWidth = -1;
        ApplyLayout();
        Rows.Redraw();
    }

    /// <summary>The search's dimming (null: none), kept for the snapshot it was made for.</summary>
    internal void SetDimming(GraphDimming? dimming)
    {
        _dimming = dimming;
        if (_source is not null)
        {
            _source.Dimming = dimming;
            Rows.Redraw();
        }
    }

    /// <summary>
    /// Shows <paramref name="data"/>: the selected item stays selected where its row is now (none when it is gone), and
    /// unless the list was at its top, the first row on screen that is still there stays where it was. UI thread.
    /// </summary>
    internal void Show(GraphData data)
    {
        if (_released)
            return;
        SnapshotSource? old = _source;
        (long Row, GraphItem Item)[] anchor = [];
        bool atTop = Rows.FirstRow == 0 && Rows.PixelInRow == 0;
        if (old is not null && !atTop)
        {
            // The rows on screen; only the top one while the canvas has no height (a hidden tab).
            long first = Rows.FirstRow;
            long last = Math.Max(first, Rows.LastVisibleRow);
            anchor = Enumerable.Range(0, (int)(last - first + 1))
                .Select(i => (Row: first + i, Item: old.ItemAt(first + i)))
                .Where(pair => pair.Item is not null)
                .Select(pair => (pair.Row, pair.Item!.Value))
                .ToArray();
        }

        var source = new SnapshotSource(data, _dates, commit => Rows.Avatars?.EmojiOf(commit.AuthorEmail, commit.AuthorName))
        {
            Dimming = _dimming,
        };
        _source = source;
        RepoSnapshot snapshot = data.Snapshot;
        // A load's first pages may need fewer lanes than the whole log: the column keeps the last log's until the load
        // completes, so it does not narrow and widen again on every refresh.
        _logLanes = snapshot.IsComplete ? snapshot.Lanes : Math.Max(snapshot.Lanes, _logLanes);
        double pixel = Rows.PixelInRow;
        long top = Rows.FirstRow;
        Rows.SetSource(source);
        foreach ((long row, GraphItem item) in anchor)
        {
            if (source.RowOf(item) is >= 0 and var moved)
            {
                Rows.ScrollTo(top + (moved - row), pixel);
                break;
            }
        }

        long selected = _selected is { } wanted ? source.RowOf(wanted) : -1;
        bool lost = selected < 0 && _selected is not null;
        if (selected < 0)
            _selected = null;
        Rows.Select(selected);
        ApplyLayout();
        DataChanged?.Invoke(data);
        if (lost)
            SelectionChanged?.Invoke(null);
    }

    /// <summary>The graph is gone for good (its repo layout was unmounted): stops following the settings and releases
    /// its canvas. UI thread, outside a layout pass.</summary>
    internal void Release()
    {
        if (_released)
            return;
        _released = true;
        _manager.GraphColumnsChanged -= OnGraphColumnsChanged;
        _manager.GraphLookChanged -= OnGraphLookChanged;
        _source = null;
        Rows.Release();
        Rows.Avatars?.Dispose();
        Rows.Avatars = null;
    }

    private void OnRowSelected(long row)
    {
        _selected = row >= 0 ? _source?.ItemAt(row) : null;
        SelectionChanged?.Invoke(_selected);
    }

    // Columns

    private void OnGraphColumnsChanged(object? sender, EventArgs e)
    {
        if (_released || _drag is not null)
            return;
        _settings = _manager.GraphColumns;
        _widths = GraphColumns.Widths(_settings.EncodedWidths);
        _layoutWidth = -1;
        ApplyLayout();
    }

    /// <summary>Lays the columns out in the view's width when anything they depend on changed: the titles' widths and
    /// grips, and the canvas's columns.</summary>
    private void ApplyLayout()
    {
        double width = ActualWidth;
        if (_released || width <= 0)
            return;
        GraphColumnLayout layout = GraphColumnLayout.Compute(width, _widths, _settings, Rows.Metrics, _logLanes);
        if (width == _layoutWidth && _layout is { } shown && layout.Fill == shown.Fill
            && layout.Spans.SequenceEqual(shown.Spans) && Rows.LogLanes == _logLanes)
        {
            return;
        }

        _layout = layout;
        _layoutWidth = width;
        GraphColumn? lastShown = GraphColumns.All.LastOrDefault(column => layout[column].IsShown);
        foreach (GraphColumn column in GraphColumns.All)
        {
            GraphColumnSpan span = layout[column];
            GraphColumnHeader header = _headers[column];
            HeaderGrid.ColumnDefinitions[(int)column].Width = new GridLength(span.Width);
            header.Visibility = span.IsShown ? Visibility.Visible : Visibility.Collapsed;
            header.Grip.Visibility = span.IsShown && column != lastShown ? Visibility.Visible : Visibility.Collapsed;
        }

        Rows.LogLanes = _logLanes;
        Rows.Columns = layout;
    }

    private void OnHeaderMenuOpening(object sender, object e)
    {
        ShowMessageItem.IsChecked = _settings.ShowMessage;
        ShowAuthorItem.IsChecked = _settings.ShowAuthor;
        ShowDateItem.IsChecked = _settings.ShowDate;
    }

    /// <summary>A column's toggle in the header menu: shown or hidden in every graph, and saved.</summary>
    private void OnShowColumnClick(object sender, RoutedEventArgs e)
    {
        if (sender is not ToggleMenuFlyoutItem item)
            return;
        GraphColumn column = ReferenceEquals(item, ShowMessageItem) ? GraphColumn.Message
            : ReferenceEquals(item, ShowAuthorItem) ? GraphColumn.Author
            : GraphColumn.Date;
        _manager.SetGraphColumns(_settings.Showing(column, item.IsChecked));
    }

    private void OnGripPressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is not GraphColumnGrip grip || _drag is not null || _layout is not { } layout
            || !e.GetCurrentPoint(grip).Properties.IsLeftButtonPressed || !grip.CapturePointer(e.Pointer))
        {
            return;
        }

        _drag = (grip.Column, grip, e.GetCurrentPoint(this).Position.X, new Dictionary<GraphColumn, double>(_widths), layout);
        e.Handled = true;
    }

    private void OnGripMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is not { } drag || !ReferenceEquals(sender, drag.Grip))
            return;
        double dx = e.GetCurrentPoint(this).Position.X - drag.StartX;
        if (!double.IsFinite(dx))
            return;
        _widths = Dragged(drag.Column, dx, drag.Widths, drag.Layout);
        ApplyLayout();
        e.Handled = true;
    }

    private void OnGripReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is not { } drag || !ReferenceEquals(sender, drag.Grip))
            return;
        EndDrag();
        drag.Grip.ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    private void OnGripCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_drag is { } drag && ReferenceEquals(sender, drag.Grip))
            EndDrag();
    }

    /// <summary>The drag ended: its widths become every graph's, and are saved.</summary>
    private void EndDrag()
    {
        _drag = null;
        if (_released)
            return;
        // From the app's settings now: a column shown or hidden in another window meanwhile stays so.
        _manager.SetGraphColumns(_manager.GraphColumns with { EncodedWidths = GraphColumns.Encode(_widths) });
        // With no net width change no event comes: take a toggle made elsewhere during the drag here too.
        if (_settings != _manager.GraphColumns)
            OnGraphColumnsChanged(this, EventArgs.Empty);
    }

    /// <summary>
    /// The widths after the right edge of <paramref name="column"/>'s title moved by <paramref name="dx"/> from where it
    /// was at the press (<paramref name="start"/>, <paramref name="layout"/>), as GraphTableView's border drags: left of
    /// the fill column the column itself resizes and the fill column takes the rest; the fill column's edge resizes the
    /// next shown column the other way; right of the fill column a column trades width with the next one. No column
    /// goes under its minimum, nor makes the fill column go under its own; the graph column stays within its lanes.
    /// </summary>
    private Dictionary<GraphColumn, double> Dragged(
        GraphColumn column, double dx, Dictionary<GraphColumn, double> start, GraphColumnLayout layout)
    {
        var widths = new Dictionary<GraphColumn, double>(start);
        GraphColumn[] shown = GraphColumns.All.Where(c => layout[c].IsShown).ToArray();
        int index = Array.IndexOf(shown, column);
        int fill = Array.IndexOf(shown, layout.Fill);
        if (index < 0 || index + 1 >= shown.Length)
            return widths;
        GraphColumn next = shown[index + 1];
        double fillRoom = layout[layout.Fill].Width - GraphColumns.MinWidth(layout.Fill);
        double width = layout[column].Width;
        if (index < fill)
        {
            double wanted = Math.Clamp(width + dx, GraphColumns.MinWidth(column), width + Math.Max(0, fillRoom));
            widths[column] = column == GraphColumn.Graph
                ? GraphColumnLayout.GraphWidth(wanted, Rows.Metrics, _logLanes)
                : wanted;
        }
        else if (index == fill)
        {
            double nextWidth = layout[next].Width;
            widths[next] = Math.Clamp(nextWidth - dx, GraphColumns.MinWidth(next), nextWidth + Math.Max(0, fillRoom));
        }
        else
        {
            double nextWidth = layout[next].Width;
            double most = Math.Max(GraphColumns.MinWidth(column), width + nextWidth - GraphColumns.MinWidth(next));
            double resized = Math.Clamp(width + dx, GraphColumns.MinWidth(column), most);
            widths[column] = resized;
            widths[next] = nextWidth - (resized - width);
        }

        return widths;
    }

    /// <summary>
    /// The rows of one <see cref="GraphData"/> as the canvas reads them: each row's graph part, its texts (made safe to
    /// show: author names, stash messages and worktree names are sanitized here, the subjects already are; formatted
    /// only for the rows drawn, kept for a few hundred rows), its fading, and the item it stands for.
    /// </summary>
    private sealed class SnapshotSource : GraphRowSource
    {
        private const int MaxCachedTexts = 512;

        private readonly RepoSnapshot _snapshot;
        private readonly GraphData _data;
        private readonly GraphDateFormatter _dates;
        private readonly WorktreeChanges? _wipChanges;
        private readonly Dictionary<long, GraphRowText> _texts = [];
        private readonly Func<Commit, string?> _emojiOf;
        private Dictionary<string, Stash>? _stashes;

        /// <param name="emojiOf">The emoji a commit's avatar shows now; null for none.</param>
        public SnapshotSource(GraphData data, GraphDateFormatter dates, Func<Commit, string?> emojiOf)
        {
            _emojiOf = emojiOf;
            Data = data;
            _data = data;
            _snapshot = data.Snapshot;
            _dates = dates;
            _wipChanges = _snapshot.Status is { } status ? WorktreeChanges.Of(status) : null;
        }

        public GraphData Data { get; }

        /// <summary>The search's dimming; applies only to the snapshot it was made for.</summary>
        public GraphDimming? Dimming { get; set; }

        public override long Count => _snapshot.RowCount;

        public override bool IsDimmed(long row)
        {
            if (Dimming is not { } dimming || dimming.Generation != _snapshot.Generation
                || dimming.RowCount != _snapshot.RowCount)
            {
                return false;
            }

            return _snapshot.EntryAt(row) switch
            {
                { Synthetic: null, CommitIndex: var index } => index < dimming.Matched.Length && !dimming.Matched[index],
                { Synthetic: { Kind: GraphSyntheticRowKind.Stash } stash } => !dimming.MatchedStashes.Contains(stash.Id),
                { Synthetic: not null } => true,
                _ => false,
            };
        }

        public override GraphRow RowAt(long row) => _snapshot.EntryAt(row)?.Row ?? default;

        /// <summary>The message, a WIP row's counts, then its badges in words ("Fix login [main (HEAD, local,
        /// remote); v1.0 (tag)]"), and the emoji its author's avatar shows ("· avatar 🔥"; only on a row that draws an
        /// avatar, not a merge), so UI Automation reads each row's refs and emoji.</summary>
        public override string NameOf(long row)
        {
            GraphRowText text = TextOf(row);
            string name = text.Changes is { KindSummary: { Length: > 0 } summary }
                ? text.Message + "  " + summary
                : text.Message;
            if (text.Badges is { Count: > 0 } badges)
                name += " [" + RefBadge.Describe(badges) + "]";
            return CommitOf(row) is { IsMerge: false } commit && _emojiOf(commit) is { } emoji
                ? name + " · avatar " + emoji
                : name;
        }

        public override Commit? CommitOf(long row) =>
            _snapshot.EntryAt(row) is { Synthetic: null, CommitIndex: var index } ? _snapshot.Commits[index] : null;

        public override GraphRowText TextOf(long row)
        {
            if (_texts.TryGetValue(row, out GraphRowText cached))
                return cached;
            if (_texts.Count >= MaxCachedTexts)
                _texts.Clear();
            GraphRowText text = MakeText(row);
            _texts[row] = text;
            return text;
        }

        /// <summary>Another worktree's WIP row always; a commit only another worktree reaches, with the fading on.</summary>
        public override bool IsFaded(long row) => _snapshot.EntryAt(row) switch
        {
            { Synthetic.Kind: GraphSyntheticRowKind.WorktreeWip } => true,
            { Synthetic: null, CommitIndex: var index } => IsSegmentFaded(index),
            _ => false,
        };

        public override bool IsSegmentFaded(int owner)
        {
            if (_data.Fade is not { } fade || owner < 0 || owner >= fade.Masks.Length)
                return false;
            ulong mask = fade.Masks[owner];
            return mask != 0 && (mask & fade.Head) == 0;
        }

        public GraphItem? ItemAt(long row) => _snapshot.EntryAt(row) switch
        {
            { Synthetic: { } synthetic } => synthetic.Kind switch
            {
                GraphSyntheticRowKind.Wip => new GraphItem(GraphItemKind.Wip, "wip"),
                GraphSyntheticRowKind.Stash => new GraphItem(GraphItemKind.Stash, synthetic.Id),
                _ => new GraphItem(GraphItemKind.Worktree, synthetic.Id),
            },
            { CommitIndex: var index } => new GraphItem(GraphItemKind.Commit, _snapshot.Commits[index].Hash),
            null => null,
        };

        /// <summary>The row of <paramref name="item"/>; -1 when it is not in the log.</summary>
        public long RowOf(GraphItem item) => item.Kind switch
        {
            GraphItemKind.Wip => _snapshot.RowOfSynthetic(GraphSyntheticRowKind.Wip, "wip"),
            GraphItemKind.Stash => _snapshot.RowOfSynthetic(GraphSyntheticRowKind.Stash, item.Id),
            GraphItemKind.Worktree => _snapshot.RowOfSynthetic(GraphSyntheticRowKind.WorktreeWip, item.Id),
            _ => _snapshot.CommitIndex.TryGetValue(item.Id, out int index) && index < _snapshot.Commits.Count
                ? _snapshot.RowOfCommit(index)
                : -1,
        };

        private GraphRowText MakeText(long row)
        {
            switch (_snapshot.EntryAt(row))
            {
                case { Synthetic: null, CommitIndex: var index }:
                    Commit commit = _snapshot.Commits[index];
                    return new GraphRowText(
                        commit.Subject, Author: DisplayText.Sanitize(commit.AuthorName),
                        Date: _dates.Format(commit.AuthorDate), Badges: _data.Badges?.GetValueOrDefault(commit.Hash));
                case { Synthetic: { Kind: GraphSyntheticRowKind.Stash } stash }:
                    Stash? found = Stash(stash.Id);
                    return new GraphRowText(
                        found is null ? "Stash" : DisplayText.Sanitize(found.Message), IsSecondary: true, IsItalic: true,
                        Date: found is null ? "" : _dates.Format(found.Date));
                case { Synthetic: { Kind: GraphSyntheticRowKind.WorktreeWip } worktree }:
                    WorktreeInfo? info = _data.Worktrees.FirstOrDefault(
                        w => string.Equals(w.Path, worktree.Id, StringComparison.Ordinal));
                    string folder = info?.Name ?? PathFlavor.Host.LastComponent(worktree.Id);
                    string name = DisplayText.Sanitize(folder);
                    // This tab's own WIP row stays "// WIP"; another worktree's says whose it is, and has its badge.
                    return new GraphRowText(
                        $"// WIP (on worktree {name})", IsSecondary: true, IsItalic: true, Changes: info?.Changes,
                        Badges: [RefBadge.ForWorktree(folder)]);
                case { Synthetic: not null }:
                    return new GraphRowText("// WIP", IsItalic: true, Changes: _wipChanges);
                default:
                    return new GraphRowText("");
            }
        }

        private Stash? Stash(string hash)
        {
            _stashes ??= _snapshot.Stashes.GroupBy(stash => stash.Hash, StringComparer.Ordinal)
                .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);
            return _stashes.GetValueOrDefault(hash);
        }
    }
}

/// <summary>
/// A column's title (GraphHeaderCell in App/Graph/GraphCells.swift at 6fa6d40): small uppercase secondary text, a
/// hairline at its right edge, and the grip that resizes the column. In UI Automation a header item named after the
/// column's stored name (refs, graph, message, author, date).
/// </summary>
internal sealed partial class GraphColumnHeader : Grid
{
    public GraphColumnHeader(GraphColumn column)
    {
        Column = column;
        Background = new SolidColorBrush(Colors.Transparent);
        AutomationProperties.SetName(this, GraphColumns.Key(column));
        ToolTipService.SetToolTip(this, GraphColumns.Title(column));

        var title = new TextBlock
        {
            Text = GraphColumns.Title(column).ToUpperInvariant(),
            FontSize = PaletteResources.Double("GraphHeaderFontSize"),
            FontWeight = FontWeights.SemiBold,
            CharacterSpacing = 57,
            Foreground = PaletteResources.Brush("GraphSecondaryTextBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 4, 0),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
        };
        AutomationProperties.SetAccessibilityView(title, AccessibilityView.Raw);
        Children.Add(title);
        Children.Add(new Border
        {
            Width = 1,
            Margin = new Thickness(0, 6, 0, 6),
            HorizontalAlignment = HorizontalAlignment.Right,
            Background = PaletteResources.Brush("GraphSeparatorBrush"),
            IsHitTestVisible = false,
        });
        Grip = new GraphColumnGrip(column);
        Children.Add(Grip);
    }

    public GraphColumn Column { get; }

    /// <summary>The right edge's resize handle; hidden on the last shown column.</summary>
    public GraphColumnGrip Grip { get; }

    protected override AutomationPeer OnCreateAutomationPeer() => new HeaderAutomationPeer(this);

    private sealed partial class HeaderAutomationPeer(GraphColumnHeader owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.HeaderItem;

        protected override string GetClassNameCore() => nameof(GraphColumnHeader);

        protected override bool IsControlElementCore() => true;
    }
}

/// <summary>A title's right edge, 6 epx wide, that drags the column's width: the column-resize pointer, hidden from UI
/// Automation.</summary>
internal sealed partial class GraphColumnGrip : Grid
{
    public GraphColumnGrip(GraphColumn column)
    {
        Column = column;
        Width = 6;
        HorizontalAlignment = HorizontalAlignment.Right;
        Background = new SolidColorBrush(Colors.Transparent);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
    }

    public GraphColumn Column { get; }
}

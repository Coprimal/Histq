using System.Globalization;
using Histq.App.Graph;
using Histq.App.Shell.Tabs;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;

namespace Histq.App.Sidebar;

/// <summary>What a sidebar row stands for.</summary>
internal enum SidebarRowKind
{
    Local,
    Remote,
    Tag,
    Worktree,
    Stash,
}

/// <summary>
/// A sidebar row as its template shows it: every text sanitized (<see cref="DisplayText.Sanitize"/>), and the graph
/// items a click reveals, the first one the graph has a row for (<see cref="Targets"/>). UI Automation names the row's
/// list item from <see cref="ToString"/>.
/// </summary>
public sealed partial class SidebarRow
{
    /// <summary>A row's name and icon, but the checked-out branch's and this tab's own worktree's (bright white).</summary>
    internal const double SecondaryOpacity = 0.72;

    private readonly string _spoken;

    internal SidebarRow(
        SidebarRowKind kind, string key, string name, string spoken, IReadOnlyList<GraphItem> targets, string search)
    {
        Kind = kind;
        Key = key;
        Name = name;
        _spoken = spoken;
        Targets = targets;
        Folded = SidebarFilter.Fold(search);
        Tooltip = name;
    }

    public string Name { get; }

    /// <summary>The trailing text: ahead/behind, a worktree's branch, a stash's selector.</summary>
    public string Detail { get; internal init; } = "";

    public string Glyph { get; internal init; } = "";

    public double NameOpacity { get; internal init; } = SecondaryOpacity;

    /// <summary>The pencil of a worktree with uncommitted changes.</summary>
    public Visibility ChangesVisibility { get; internal init; } = Visibility.Collapsed;

    /// <summary>A remote's branch sits one step in from its remote's row.</summary>
    public Thickness Indent { get; internal init; }

    public string Tooltip { get; internal init; }

    /// <summary>A branch's pin (pinned to the left lanes) and scope (soloed).</summary>
    public Visibility PinVisibility { get; internal init; } = Visibility.Collapsed;

    public Visibility SoloVisibility { get; internal init; } = Visibility.Collapsed;

    /// <summary>A hidden ref's eye, which shows it again; disabled for a branch hidden as stale.</summary>
    public Visibility ShowAgainVisibility { get; internal init; } = Visibility.Collapsed;

    public bool CanShowAgain { get; internal init; } = true;

    public string ShowAgainTooltip { get; internal init; } = "Show Again";

    /// <summary>The graph leaves the ref out (listed only while its card lists the hidden rows, dimmed).</summary>
    internal bool IsHidden { get; init; }

    internal SidebarRowKind Kind { get; }

    /// <summary>Its identity across reloads: the full ref name, the worktree's path, the stash's hash.</summary>
    internal string Key { get; }

    /// <summary>A remote branch's remote (raw); null otherwise.</summary>
    internal string? Group { get; init; }

    /// <summary>The graph rows a click reveals, in order of preference: the changes' row (this worktree's WIP, another
    /// worktree's row), then the commit.</summary>
    internal IReadOnlyList<GraphItem> Targets { get; }

    /// <summary>The text the card's filter searches, folded (<see cref="SidebarFilter.Fold"/>).</summary>
    internal string Folded { get; }

    public override string ToString() => _spoken;
}

/// <summary>A remote's branches in the Remote card, under the remote's row (its sanitized name).</summary>
public sealed partial class SidebarGroup : List<SidebarRow>
{
    internal SidebarGroup(string name, IEnumerable<SidebarRow> rows)
        : base(rows)
    {
        Name = name;
    }

    public string Name { get; }

    public override string ToString() => "Remote " + Name;
}

/// <summary>A sidebar section's card: a Group in UI Automation, named after its title.</summary>
public sealed partial class SidebarCard : Grid
{
    protected override AutomationPeer OnCreateAutomationPeer() => new SidebarCardAutomationPeer(this);

    private sealed partial class SidebarCardAutomationPeer(SidebarCard owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

        protected override string GetClassNameCore() => nameof(SidebarCard);

        protected override bool IsControlElementCore() => true;
    }
}

/// <summary>
/// A repo tab's sidebar (ported from SidebarView, App/Sidebar/SidebarView.swift at 6fa6d40, its Branches and Tags tabs):
/// the tab picker, then the shown tab's cards. Branches: Local (the checked-out branch with a check, ahead/behind or
/// "gone"), Remote (branches under their remote's row), Worktrees (this tab's own with a check; a pencil for uncommitted
/// changes; the branch, short HEAD or "missing"), in the order and visibility of <see cref="SidebarSections"/>, then
/// Stashes (collapsed at first); the Submodules card comes with the submodule reader (M6), and until then counts as a
/// repo without submodules. Tags: the Tags card. Each card is collapsible, counts its rows in its header and has a
/// filter (its search button opens the field; Esc closes it); a card with no rows stays collapsed. The cards show
/// capsule skeleton rows until their data first comes (<see cref="Show"/>: the graph's own data, no read here).
/// <para>
/// A click on a row (<see cref="RowInvoked"/>) selects it at once; the repo layout reveals its commit in the graph in the
/// same call. The branch and tag rows share one selection, kept across reloads and graph clicks (as the Mac's
/// sidebarSelection); a stash row is selected while its graph row is (<see cref="ShowGraphSelection"/>); worktree rows
/// are not selectable. The lists are virtualized ListViews, each in its card's share of the height.
/// </para>
/// <para>
/// The graph's view (<see cref="IRepoMenuHost"/>, the repo layout): a ref the graph leaves out is not listed, its card's
/// header then has an eye that lists the hidden rows dimmed (with a Show Again eye each, disabled for a branch hidden as
/// stale) or leaves them out again; a pinned branch has a pin, a soloed one a filter glyph; the words "hidden", "pinned",
/// "soloed" end their UI Automation names. A ref row's right click opens its menu (<see cref="RefMenus.Ref"/>), the Local
/// and Remote headers' "…" Hide Stale Branches and Show All Branches. Not ported yet: double-click checkout or open, the
/// operation items of the menus, the Remote and Worktrees cards' other header menus, the Submodules and PRs cards,
/// remotes with no fetched branch, owner avatars, the "Show Sections" button to Settings.
/// </para>
/// </summary>
public sealed partial class SidebarView : UserControl
{
    private const string CheckGlyph = "";
    private const string LocalGlyph = "";
    private const string RemoteGlyph = "";
    private const string TagGlyph = "";
    private const string WorktreeGlyph = "";
    private const string StashGlyph = "";
    private const string SearchGlyph = "";
    private const string ExpandedGlyph = "";
    private const string CollapsedGlyph = "";

    private const string EyeGlyph = "\uE7B3";
    private const string EyeSlashGlyph = "\uED1A";
    private const string MoreGlyph = "\uE712";

    /// <summary>A hidden ref's name and icon, listed while its card lists the hidden rows.</summary>
    private const double HiddenOpacity = 0.4;

    private readonly SidebarSections _sections;
    private readonly List<Card> _branchCards = [];
    private readonly Card _local;
    private readonly Card _remote;
    private readonly Card _worktrees;
    private readonly Card _stashes;
    private readonly Card _tags;

    // The data the cards were last made from.
    private Refs? _refs;
    private IReadOnlyList<WorktreeInfo> _worktreeList = [];
    private bool _worktreesRead;
    private WorktreeChanges? _ownChanges;
    private IReadOnlyList<Stash>? _stashList;

    /// <summary>The repo layout: the view and visibility the ref rows show, the menus' actions; null before it is set.</summary>
    private IRepoMenuHost? _host;

    /// <summary>The view and visibility the ref rows were last made with.</summary>
    private RepoViewState _view = RepoViewState.Empty;
    private LogFilter _visibility = LogFilter.None;

    /// <summary>The selected branch or tag row's full ref name; null for none.</summary>
    private string? _selectedRef;

    /// <summary>The graph's selected stash, by hash; null when the graph selects another row.</summary>
    private string? _graphStash;

    internal SidebarView(SidebarSections sections)
    {
        _sections = sections;
        InitializeComponent();
        _local = MakeCard(SidebarRowKind.Local, "Local", LocalGlyph, "No local branches", "branches", [0.45, 0.6, 0.35, 0.7, 0.5]);
        _remote = MakeCard(SidebarRowKind.Remote, "Remote", RemoteGlyph, "No remotes", "branches", [0.3, 0.55, 0.4]);
        _worktrees = MakeCard(SidebarRowKind.Worktree, "Worktrees", WorktreeGlyph, "No worktrees", "worktrees", [0.4, 0.55]);
        _stashes = MakeCard(SidebarRowKind.Stash, "Stashes", StashGlyph, "No stashes", "stashes", [0.5, 0.35]);
        _tags = MakeCard(SidebarRowKind.Tag, "Tags", TagGlyph, "No tags", "tags", [0.3, 0.45, 0.35, 0.5]);
        _stashes.Expanded = false;

        foreach (SidebarSectionId id in sections.Ids(SidebarTab.Branches))
        {
            switch (id)
            {
                case SidebarSectionId.Local: _branchCards.Add(_local); break;
                case SidebarSectionId.Remote: _branchCards.Add(_remote); break;
                case SidebarSectionId.Worktrees: _branchCards.Add(_worktrees); break;
            }
        }

        if (_branchCards.Count == 0)
        {
            // All the Branches tab's sections are hidden (Submodules counts as none): it says so, Stashes included.
            BranchesCards.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            BranchesCards.Children.Add(HiddenSectionsCard());
        }
        else
        {
            _branchCards.Add(_stashes);
            Stack(BranchesCards, _branchCards);
        }

        Stack(TagsCards, [_tags]);
        if (!sections.Tabs.Contains(SidebarTab.Tags))
        {
            TagsTab.Visibility = Visibility.Collapsed;
            Grid.SetColumnSpan(BranchesTab, 2);
        }
    }

    /// <summary>A row was clicked (or invoked with the keyboard): reveal it. UI thread.</summary>
    internal event Action<SidebarRow>? RowInvoked;

    /// <summary>The tab shown now.</summary>
    internal SidebarTab Tab { get; private set; } = SidebarTab.Branches;

    /// <summary>
    /// The graph's data came (a first page, the complete log, a reload, a status or worktree change): each card whose
    /// own data changed is made again, its filter and selection kept; the others are left as they are. UI thread.
    /// </summary>
    internal void Show(GraphData data)
    {
        Refs? previous = _refs;
        bool viewChanged = _host is { } host && !(host.View.Equals(_view) && host.Visibility.Equals(_visibility));
        if (viewChanged)
        {
            _view = _host!.View;
            _visibility = _host.Visibility;
        }

        bool refsChanged = data.Refs is { } refs && (viewChanged || !refs.Equals(previous));
        if (refsChanged)
            _refs = data.Refs;
        bool worktreesChanged = data.WorktreesRead && (!_worktreesRead || !data.Worktrees.SequenceEqual(_worktreeList));
        if (worktreesChanged)
        {
            _worktreeList = data.Worktrees;
            _worktreesRead = true;
        }

        WorktreeChanges? own = data.Snapshot.Status is { } status ? WorktreeChanges.Of(status) : null;
        bool ownChanged = !Equals(own, _ownChanges);
        _ownChanges = own;

        // Only the lists that changed are made again (a new source scrolls its list to the top).
        if (_refs is { } shown)
        {
            if (worktreesChanged || (refsChanged && (viewChanged || previous is null || !shown.LocalBranches.SequenceEqual(previous.LocalBranches))))
                SetRows(_local, LocalRows(shown));
            if (refsChanged && (viewChanged || previous is null || !shown.RemoteBranches.SequenceEqual(previous.RemoteBranches)))
                SetRows(_remote, RemoteRows(shown), [.. shown.RemoteBranches.Select(branch => branch.Remote).Distinct()]);
            if (refsChanged && (viewChanged || previous is null || !shown.Tags.SequenceEqual(previous.Tags)))
                SetRows(_tags, TagRows(shown));
        }

        if (_worktreesRead && (worktreesChanged || ownChanged))
            SetRows(_worktrees, WorktreeRows());
        if (_stashList is null || !data.Snapshot.Stashes.SequenceEqual(_stashList))
        {
            _stashList = data.Snapshot.Stashes;
            SetRows(_stashes, StashRows(_stashList));
        }
    }

    /// <summary>The repo layout, whose view and visibility the ref rows show and whose actions the menus run.</summary>
    internal void SetHost(IRepoMenuHost host) => _host = host;

    /// <summary>
    /// The graph's view or what it leaves out changed (a Hide, Solo, Pin, Show All, Hide Stale Branches; new refs): the
    /// Local, Remote and Tags rows are made again with their dimming, pins, scopes and eyes. UI thread.
    /// </summary>
    internal void ViewChanged()
    {
        if (_host is not { } host || (host.View.Equals(_view) && host.Visibility.Equals(_visibility)))
            return;
        _view = host.View;
        _visibility = host.Visibility;
        if (_refs is not { } refs)
            return;
        SetRows(_local, LocalRows(refs));
        SetRows(_remote, RemoteRows(refs), [.. refs.RemoteBranches.Select(branch => branch.Remote).Distinct()]);
        SetRows(_tags, TagRows(refs));
    }

    /// <summary><paramref name="refName"/> was hidden: its row is no longer selected (as on the Mac).</summary>
    internal void Deselect(string refName)
    {
        if (!string.Equals(_selectedRef, refName, StringComparison.Ordinal))
            return;
        _selectedRef = null;
        foreach (Card card in new[] { _local, _remote, _tags })
            RestoreSelection(card);
    }

    /// <summary>A ref row's look for the graph's view: hidden (dimmed, with its Show Again eye), pinned, soloed, and the
    /// same in words for UI Automation.</summary>
    private readonly record struct RefLook(bool Hidden, bool Pinned, bool Soloed, bool CanShowAgain)
    {
        public string Spoken => (Hidden ? ", hidden" : "") + (Pinned ? ", pinned" : "") + (Soloed ? ", soloed" : "");
    }

    private RefLook LookOf(string refName)
    {
        bool hidden = _visibility.Hidden.Contains(refName);
        return new RefLook(
            hidden, _view.Pinned.Contains(refName), _view.Solo.Contains(refName),
            !(hidden && _host is { } host && RefMenus.IsHiddenAsStale(refName, host)));
    }

    private static Visibility Shown(bool on) => on ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>The graph's selection changed: a stash row is selected while its graph row is. UI thread.</summary>
    internal void ShowGraphSelection(GraphItem? item)
    {
        _graphStash = item is { Kind: GraphItemKind.Stash } stash ? stash.Id : null;
        RestoreSelection(_stashes);
    }

    // Clicks

    /// <summary>A row's click (a pointer's, the keyboard's, a probe's): selects it at once, then asks for it to be
    /// revealed.</summary>
    internal void Click(SidebarRow row)
    {
        if (row.Kind is SidebarRowKind.Local or SidebarRowKind.Remote or SidebarRowKind.Tag)
        {
            _selectedRef = row.Key;
            foreach (Card card in new[] { _local, _remote, _tags })
                RestoreSelection(card);
        }

        RowInvoked?.Invoke(row);
    }

    private void OnTabClick(object sender, RoutedEventArgs e) =>
        ShowTab(ReferenceEquals(sender, TagsTab) ? SidebarTab.Tags : SidebarTab.Branches);

    /// <summary>Shows <paramref name="tab"/>'s cards (Branches when it is hidden); the capsules follow.</summary>
    internal void ShowTab(SidebarTab tab)
    {
        Tab = _sections.ShownTab(tab);
        BranchesTab.IsChecked = Tab == SidebarTab.Branches;
        TagsTab.IsChecked = Tab == SidebarTab.Tags;
        BranchesCards.Visibility = Tab == SidebarTab.Branches ? Visibility.Visible : Visibility.Collapsed;
        TagsCards.Visibility = Tab == SidebarTab.Tags ? Visibility.Visible : Visibility.Collapsed;
    }

    // Rows

    private List<SidebarRow> LocalRows(Refs refs)
    {
        // A branch checked out in another worktree with changes: a click shows that worktree's row.
        var dirty = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (WorktreeInfo info in _worktreeList)
        {
            if (!info.IsCurrent && info.IsDirty && info.Worktree.Branch is { } branch)
                dirty.TryAdd(branch, info.Path);
        }

        var rows = new List<SidebarRow>(refs.LocalBranches.Count);
        foreach (LocalBranch branch in refs.LocalBranches)
        {
            string name = DisplayText.Sanitize(branch.Name);
            GraphItem commit = new(GraphItemKind.Commit, branch.Commit);
            IReadOnlyList<GraphItem> targets = branch.IsHead ? [new GraphItem(GraphItemKind.Wip, "wip"), commit]
                : dirty.TryGetValue(branch.RefName, out string? path) ? [new GraphItem(GraphItemKind.Worktree, path), commit]
                : [commit];
            (string detail, string spoken) = AheadBehind(branch);
            RefLook look = LookOf(branch.RefName);
            string description = string.Join(", ", new[] { name, branch.IsHead ? "checked out" : "", spoken }
                .Where(part => part.Length > 0)) + look.Spoken;
            rows.Add(new SidebarRow(SidebarRowKind.Local, branch.RefName, name, description, targets, branch.Name)
            {
                Detail = detail,
                Glyph = branch.IsHead ? CheckGlyph : "",
                NameOpacity = look.Hidden ? HiddenOpacity : branch.IsHead ? 1 : SidebarRow.SecondaryOpacity,
                IsHidden = look.Hidden,
                PinVisibility = Shown(look.Pinned),
                SoloVisibility = Shown(look.Soloed),
                ShowAgainVisibility = Shown(look.Hidden),
                CanShowAgain = look.CanShowAgain,
                ShowAgainTooltip = look.CanShowAgain ? "Show Again" : RefMenus.StaleReason,
            });
        }

        return rows;
    }

    /// <summary>"↑2 ↓1" against the upstream, "gone" when it was deleted, and the same in words.</summary>
    private static (string Text, string Spoken) AheadBehind(LocalBranch branch)
    {
        if (branch.UpstreamGone)
            return ("gone", "upstream gone");
        var text = new List<string>(2);
        var spoken = new List<string>(2);
        if (branch.Ahead > 0)
        {
            text.Add(string.Create(CultureInfo.InvariantCulture, $"↑{branch.Ahead}"));
            spoken.Add(string.Create(CultureInfo.InvariantCulture, $"{branch.Ahead} ahead"));
        }

        if (branch.Behind > 0)
        {
            text.Add(string.Create(CultureInfo.InvariantCulture, $"↓{branch.Behind}"));
            spoken.Add(string.Create(CultureInfo.InvariantCulture, $"{branch.Behind} behind"));
        }

        return (string.Join(" ", text), string.Join(", ", spoken));
    }

    private List<SidebarRow> RemoteRows(Refs refs)
    {
        var rows = new List<SidebarRow>(refs.RemoteBranches.Count);
        foreach (RemoteBranch branch in refs.RemoteBranches)
        {
            // Its name under the remote's row: without "<remote>/".
            string shortName = branch.Name.Length > branch.Remote.Length + 1 && branch.Name.StartsWith(branch.Remote + "/", StringComparison.Ordinal)
                ? branch.Name[(branch.Remote.Length + 1)..]
                : branch.Name;
            RefLook look = LookOf(branch.RefName);
            rows.Add(new SidebarRow(
                SidebarRowKind.Remote, branch.RefName, DisplayText.Sanitize(shortName), DisplayText.Sanitize(branch.Name) + look.Spoken,
                [new GraphItem(GraphItemKind.Commit, branch.Commit)], branch.Name)
            {
                NameOpacity = look.Hidden ? HiddenOpacity : SidebarRow.SecondaryOpacity,
                IsHidden = look.Hidden,
                PinVisibility = Shown(look.Pinned),
                SoloVisibility = Shown(look.Soloed),
                ShowAgainVisibility = Shown(look.Hidden),
                CanShowAgain = look.CanShowAgain,
                ShowAgainTooltip = look.CanShowAgain ? "Show Again" : RefMenus.StaleReason,
                Group = branch.Remote,
                Indent = new Thickness(16, 0, 0, 0),
                Tooltip = DisplayText.Sanitize(branch.Name),
            });
        }

        return rows;
    }

    private List<SidebarRow> TagRows(Refs refs) =>
        [.. refs.Tags.Select(tag => (Tag: tag, Look: LookOf(tag.RefName))).Select(pair => new SidebarRow(
            SidebarRowKind.Tag, pair.Tag.RefName, DisplayText.Sanitize(pair.Tag.Name),
            DisplayText.Sanitize(pair.Tag.Name) + pair.Look.Spoken,
            [new GraphItem(GraphItemKind.Commit, pair.Tag.Commit ?? pair.Tag.Target)], pair.Tag.Name)
        {
            Glyph = TagGlyph,
            NameOpacity = pair.Look.Hidden ? HiddenOpacity : SidebarRow.SecondaryOpacity,
            IsHidden = pair.Look.Hidden,
            ShowAgainVisibility = Shown(pair.Look.Hidden),
            Tooltip = pair.Tag.IsAnnotated
                ? "Annotated tag: its own object, with a message, author and date"
                : "Lightweight tag: only a name pointing at a commit, no message",
        })];

    private List<SidebarRow> WorktreeRows()
    {
        var rows = new List<SidebarRow>(_worktreeList.Count);
        foreach (WorktreeInfo info in _worktreeList)
        {
            Worktree worktree = info.Worktree;
            // Its branch, else its short HEAD when detached ("bare" for a bare one), as the Mac's headLabel.
            string head = worktree.Branch is { } branch
                ? (branch.StartsWith("refs/heads/", StringComparison.Ordinal) ? branch["refs/heads/".Length..] : branch)
                : worktree.Head is { } sha ? sha[..Math.Min(7, sha.Length)] : worktree.IsBare ? "bare" : "";
            string name = DisplayText.Sanitize(info.Name);
            string label = DisplayText.Sanitize(head);
            // This tab's own changes come from its status, another worktree's from its own read.
            WorktreeChanges? changes = info.IsCurrent ? _ownChanges : info.Changes;
            bool dirty = changes is { IsEmpty: false };
            var targets = new List<GraphItem>(2);
            if (info.IsCurrent)
                targets.Add(new GraphItem(GraphItemKind.Wip, "wip"));
            else if (info.IsDirty)
                targets.Add(new GraphItem(GraphItemKind.Worktree, info.Path));
            if (worktree.Head is { } headCommit)
                targets.Add(new GraphItem(GraphItemKind.Commit, headCommit));
            string spoken = $"Worktree {name}, {label}{(dirty ? ", uncommitted changes" : "")}";
            rows.Add(new SidebarRow(SidebarRowKind.Worktree, info.Path, name, spoken, targets, $"{info.Name} {head}")
            {
                Detail = worktree.IsPrunable ? "missing" : label,
                Glyph = info.IsCurrent ? CheckGlyph : WorktreeGlyph,
                NameOpacity = info.IsCurrent ? 1 : SidebarRow.SecondaryOpacity,
                ChangesVisibility = dirty ? Visibility.Visible : Visibility.Collapsed,
                Tooltip = DisplayText.Sanitize(info.Path)
                    + (dirty ? string.Create(CultureInfo.InvariantCulture, $"\nUncommitted changes: {changes!.Unstaged} unstaged · {changes.Staged} staged") : ""),
            });
        }

        return rows;
    }

    private static List<SidebarRow> StashRows(IReadOnlyList<Stash> stashes) =>
        [.. stashes.Select(stash =>
        {
            string message = DisplayText.Sanitize(stash.Message);
            return new SidebarRow(
                SidebarRowKind.Stash, stash.Hash, message, $"Stash {stash.Selector}, {message}",
                [new GraphItem(GraphItemKind.Stash, stash.Hash)], $"{stash.Selector} {stash.Message}")
            {
                Detail = stash.Selector,
                Glyph = StashGlyph,
                Tooltip = $"{stash.Selector}: {message}",
            };
        })];

    // Cards

    /// <summary>A card's parts and state.</summary>
    private sealed class Card
    {
        public required SidebarRowKind Kind { get; init; }
        public required string Title { get; init; }
        public required string NoneText { get; init; }
        public required string Noun { get; init; }
        public required SidebarCard Root { get; init; }
        public required FontIcon Chevron { get; init; }
        public required TextBlock CountText { get; init; }
        public required Button SearchButton { get; init; }

        /// <summary>The header's eye while some rows are hidden (HiddenRowsToggle): lists them or leaves them out.</summary>
        public required Button EyeButton { get; init; }

        /// <summary>The Local and Remote cards' "…" menu (Hide Stale Branches, Show All Branches); null for the others.</summary>
        public Button? MenuButton { get; init; }
        public required TextBox Filter { get; init; }
        public required Grid Body { get; init; }
        public required ListView List { get; init; }
        public required TextBlock EmptyText { get; init; }
        public required StackPanel Skeleton { get; init; }

        public bool Expanded { get; set; } = true;
        public bool Searching { get; set; }

        /// <summary>The hidden rows are listed (dimmed), as the header's eye says.</summary>
        public bool ShowsHidden { get; set; }

        /// <summary>Its rows the graph leaves out.</summary>
        public int HiddenCount { get; set; }

        /// <summary>Its rows; null until its data first comes (skeleton rows meanwhile).</summary>
        public IReadOnlyList<SidebarRow>? Rows { get; set; }

        /// <summary>The rows its list holds now (through its filter).</summary>
        public IReadOnlyList<SidebarRow> Shown { get; set; } = [];

        /// <summary>The Remote card's remotes, in order (raw names); null for the other cards.</summary>
        public IReadOnlyList<string>? Groups { get; set; }

        /// <summary>The grid the card is stacked in, and its row there.</summary>
        public Grid? Stack { get; set; }

        /// <summary>The rows it lists (the hidden ones only while it lists them): the header's count.</summary>
        public int Count => (Rows?.Count ?? 0) - (ShowsHidden ? 0 : HiddenCount);

        /// <summary>Its rows show (a card with none listed stays collapsed).</summary>
        public bool IsOpen => Expanded && (Rows is null || Count > 0);
    }

    private Card MakeCard(SidebarRowKind kind, string title, string glyph, string noneText, string noun, double[] skeleton)
    {
        var root = new SidebarCard
        {
            Background = PaletteResources.Brush("SheetCardBrush"),
            BorderBrush = PaletteResources.Brush("SheetCardBorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["CardCornerRadius"],
        };
        AutomationProperties.SetName(root, title);
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        Brush clear = (Brush)Resources["SidebarClearBrush"];
        Brush hover = PaletteResources.Brush("HoverFillBrush");
        Brush pressed = PaletteResources.Brush("PressedFillBrush");

        // The header: the toggle (chevron, icon, title), the count, the search button.
        var header = new Grid { Height = PaletteResources.Double("CardHeaderHeight"), Padding = new Thickness(4, 0, 6, 0), ColumnSpacing = 4 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (int column = 0; column < 4; column++)
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var chevron = new FontIcon { Glyph = ExpandedGlyph, FontSize = 9, Width = 12 };
        var titleText = new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        label.Children.Add(chevron);
        label.Children.Add(new FontIcon { Glyph = glyph, FontSize = 13 });
        label.Children.Add(titleText);
        var toggle = new Button
        {
            Content = label,
            Height = 28,
            Padding = new Thickness(6, 0, 6, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            CornerRadius = new CornerRadius(14),
        };
        TabStrip.StyleButton(toggle, clear, hover, pressed);
        AutomationProperties.SetName(toggle, title);
        header.Children.Add(toggle);

        var count = new TextBlock { FontSize = 12, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(count, 1);
        header.Children.Add(count);

        var search = new Button
        {
            Content = new FontIcon { Glyph = SearchGlyph, FontSize = 12 },
            Width = 24,
            Height = 24,
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            CornerRadius = new CornerRadius(12),
            Visibility = Visibility.Collapsed,
        };
        TabStrip.StyleButton(search, clear, hover, pressed);
        AutomationProperties.SetName(search, "Search " + title);
        ToolTipService.SetToolTip(search, "Search " + title);
        Grid.SetColumn(search, 2);
        header.Children.Add(search);

        Button HeaderButton(string glyph, int column)
        {
            var button = new Button
            {
                Content = new FontIcon { Glyph = glyph, FontSize = 12 },
                Width = 24,
                Height = 24,
                Padding = new Thickness(0),
                VerticalAlignment = VerticalAlignment.Center,
                CornerRadius = new CornerRadius(12),
            };
            TabStrip.StyleButton(button, clear, hover, pressed);
            Grid.SetColumn(button, column);
            header.Children.Add(button);
            return button;
        }

        Button eye = HeaderButton(EyeSlashGlyph, 3);
        eye.Visibility = Visibility.Collapsed;
        Button? more = null;
        if (kind is SidebarRowKind.Local or SidebarRowKind.Remote)
        {
            more = HeaderButton(MoreGlyph, 4);
            AutomationProperties.SetName(more, kind == SidebarRowKind.Local ? "Local branch actions" : "Remote actions");
            ToolTipService.SetToolTip(more, kind == SidebarRowKind.Local ? "Local branches" : "Remotes");
        }

        root.Children.Add(header);

        var filter = new TextBox
        {
            PlaceholderText = "Filter by name",
            Margin = new Thickness(8, 0, 8, 6),
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(filter, "Filter " + title);
        Grid.SetRow(filter, 1);
        root.Children.Add(filter);

        // The rows: the list, the empty text over it, the skeleton until the data comes.
        var body = new Grid { Padding = new Thickness(6, 0, 6, 6) };
        Grid.SetRow(body, 2);
        var list = new ListView
        {
            SelectionMode = kind == SidebarRowKind.Worktree ? ListViewSelectionMode.None : ListViewSelectionMode.Single,
            IsItemClickEnabled = true,
            // Arrow keys move the focus only; Enter or Space clicks (ItemClick), as a pointer does.
            SingleSelectionFollowsFocus = false,
            ItemTemplate = (DataTemplate)Resources["SidebarRowTemplate"],
            ItemContainerStyle = (Style)Resources["SidebarRowStyle"],
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(list, title);
        if (kind == SidebarRowKind.Remote)
        {
            list.GroupStyle.Add(new GroupStyle
            {
                HeaderTemplate = (DataTemplate)Resources["SidebarGroupTemplate"],
                HeaderContainerStyle = (Style)Resources["SidebarGroupHeaderStyle"],
                HidesIfEmpty = false,
            });
        }

        var empty = new TextBlock
        {
            FontSize = 13,
            Opacity = 0.6,
            Margin = new Thickness(10, 4, 10, 4),
            Visibility = Visibility.Collapsed,
        };
        var bars = new StackPanel { IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(bars, AccessibilityView.Raw);
        Brush skeletonBrush = (Brush)Resources["SidebarSkeletonBrush"];
        foreach (double fraction in skeleton)
        {
            var row = new Grid { Height = 28, Padding = new Thickness(10, 0, 10, 0), ColumnSpacing = 4 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new Border { Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = skeletonBrush, HorizontalAlignment = HorizontalAlignment.Left });
            var bar = new Border { Width = 180 * fraction, Height = 11, CornerRadius = new CornerRadius(5.5), Background = skeletonBrush, HorizontalAlignment = HorizontalAlignment.Left };
            Grid.SetColumn(bar, 1);
            row.Children.Add(bar);
            bars.Children.Add(row);
        }

        body.Children.Add(list);
        body.Children.Add(empty);
        body.Children.Add(bars);
        root.Children.Add(body);

        var card = new Card
        {
            Kind = kind,
            Title = title,
            NoneText = noneText,
            Noun = noun,
            Root = root,
            Chevron = chevron,
            CountText = count,
            SearchButton = search,
            EyeButton = eye,
            MenuButton = more,
            Filter = filter,
            Body = body,
            List = list,
            EmptyText = empty,
            Skeleton = bars,
        };
        toggle.Click += (_, _) => ToggleExpanded(card);
        eye.Click += (_, _) => ToggleShowsHidden(card);
        if (more is not null)
            more.Click += (_, _) => ShowBranchViewMenu(more);
        list.ContextRequested += (_, e) => OnRowContextRequested(card, e);
        search.Click += (_, _) => ToggleSearch(card);
        filter.TextChanged += (_, _) => ApplyFilter(card);
        filter.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape)
            {
                CloseSearch(card);
                e.Handled = true;
            }
        };
        list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is SidebarRow row)
                Click(row);
        };
        return card;
    }

    /// <summary>The Branches tab with Local, Remote and Worktrees all hidden: says so.</summary>
    private static Border HiddenSectionsCard()
    {
        var text = new StackPanel { Spacing = 8, Padding = (Thickness)Application.Current.Resources["CardPadding"] };
        text.Children.Add(new TextBlock { Text = "All sections are hidden", FontSize = 13, FontWeight = FontWeights.SemiBold });
        text.Children.Add(new TextBlock
        {
            Text = "Local, Remote, Worktrees and Submodules are hidden in Settings › Appearance.",
            FontSize = 12,
            Opacity = 0.6,
            TextWrapping = TextWrapping.Wrap,
        });
        var card = new Border
        {
            Child = text,
            Background = PaletteResources.Brush("SheetCardBrush"),
            BorderBrush = PaletteResources.Brush("SheetCardBorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["CardCornerRadius"],
        };
        AutomationProperties.SetName(card, "Branches");
        return card;
    }

    /// <summary>Puts <paramref name="cards"/> in <paramref name="stack"/>'s rows, in order.</summary>
    private void Stack(Grid stack, IReadOnlyList<Card> cards)
    {
        for (int i = 0; i < cards.Count; i++)
        {
            cards[i].Stack = stack;
            stack.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(cards[i].Root, i);
            stack.Children.Add(cards[i].Root);
            UpdateCard(cards[i]);
        }
    }

    /// <summary>The card's new rows (<paramref name="groups"/>: the Remote card's remotes): shown through its filter,
    /// its selection kept.</summary>
    private void SetRows(Card card, IReadOnlyList<SidebarRow> rows, IReadOnlyList<string>? groups = null)
    {
        card.Rows = rows;
        card.Groups = groups;
        card.HiddenCount = rows.Count(row => row.IsHidden);
        ApplyFilter(card);
        UpdateCard(card);
    }

    /// <summary>Lists the rows that match the card's filter (all while it is closed), grouped by remote in the Remote
    /// card (a remote whose name matches stays, with its matching branches only); the empty text says why none.</summary>
    private void ApplyFilter(Card card)
    {
        if (card.Rows is not { } rows)
            return;
        string[] words = card.Searching ? SidebarFilter.Words(card.Filter.Text) : [];
        List<SidebarRow> shown =
            [.. rows.Where(row => (card.ShowsHidden || !row.IsHidden) && (words.Length == 0 || SidebarFilter.Matches(row.Folded, words)))];
        card.Shown = shown;
        bool none;
        if (card.Groups is { } groups)
        {
            var listed = new List<SidebarGroup>(groups.Count);
            foreach (string remote in groups)
            {
                var branches = shown.Where(row => string.Equals(row.Group, remote, StringComparison.Ordinal)).ToList();
                if (branches.Count > 0 || words.Length == 0 || SidebarFilter.Matches(SidebarFilter.Fold(remote), words))
                    listed.Add(new SidebarGroup(DisplayText.Sanitize(remote), branches));
            }

            card.List.ItemsSource = new CollectionViewSource { IsSourceGrouped = true, Source = listed }.View;
            none = listed.Count == 0;
        }
        else
        {
            card.List.ItemsSource = shown;
            none = shown.Count == 0;
        }

        card.EmptyText.Text = rows.Count == 0 ? card.NoneText
            : card.Count == 0 ? $"All {card.Noun} are hidden"
            : "No matching " + card.Noun;
        card.EmptyText.Visibility = none ? Visibility.Visible : Visibility.Collapsed;
        RestoreSelection(card);
    }

    /// <summary>Selects the card's row that stands for the selected ref (or the graph's stash); none otherwise.</summary>
    private void RestoreSelection(Card card)
    {
        if (card.List.SelectionMode == ListViewSelectionMode.None || card.Rows is null)
            return;
        string? key = card.Kind == SidebarRowKind.Stash ? _graphStash : _selectedRef;
        SidebarRow? row = key is null ? null : card.Shown.FirstOrDefault(row => string.Equals(row.Key, key, StringComparison.Ordinal));
        if (!ReferenceEquals(card.List.SelectedItem, row))
            card.List.SelectedItem = row;
    }

    private void ToggleExpanded(Card card)
    {
        // A card with no rows stays collapsed.
        if (card.Rows is { Count: 0 })
            return;
        card.Expanded = !card.Expanded;
        UpdateCard(card);
    }

    /// <summary>The header's eye: lists the hidden rows (dimmed) or leaves them out again. The graph keeps them hidden
    /// either way.</summary>
    private void ToggleShowsHidden(Card card)
    {
        card.ShowsHidden = !card.ShowsHidden;
        if (card.ShowsHidden)
            card.Expanded = true;
        ApplyFilter(card);
        UpdateCard(card);
    }

    /// <summary>The Local and Remote cards' "…": Hide Stale Branches, Show All Branches.</summary>
    private void ShowBranchViewMenu(Button button)
    {
        if (_host is { } host && RefMenus.Build(actions => RefMenus.BranchView(host, actions)) is { } menu)
            menu.ShowAt(button);
    }

    /// <summary>A ref row's menu (a right click, the menu key): its visibility and Copy.</summary>
    private void OnRowContextRequested(Card card, ContextRequestedEventArgs e)
    {
        SidebarRow? row = e.OriginalSource is ListViewItem container
            ? card.List.ItemFromContainer(container) as SidebarRow
            : (e.OriginalSource as FrameworkElement)?.DataContext as SidebarRow;
        if (row is null || _host is not { } host || row.Kind is not (SidebarRowKind.Local or SidebarRowKind.Remote or SidebarRowKind.Tag))
            return;
        e.Handled = true;
        if (RefMenus.Build(actions => RefMenus.Ref(row.Kind, ShortName(row.Key), host, actions)) is not { } menu)
            return;
        if (e.TryGetPosition(card.List, out Windows.Foundation.Point point))
            menu.ShowAt(card.List, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Position = point });
        else
            menu.ShowAt(e.OriginalSource as FrameworkElement ?? card.List);
    }

    /// <summary>A ref's short name: <c>main</c>, <c>origin/main</c>, <c>v1.0</c>.</summary>
    private static string ShortName(string refName)
    {
        foreach (string prefix in new[] { "refs/heads/", "refs/remotes/", "refs/tags/" })
        {
            if (refName.StartsWith(prefix, StringComparison.Ordinal))
                return refName[prefix.Length..];
        }

        return refName;
    }

    /// <summary>A hidden row's eye: shows its ref again.</summary>
    private void OnShowAgainClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SidebarRow row } && row.IsHidden)
            _host?.Show(row.Key);
    }

    private void ToggleSearch(Card card)
    {
        if (card.Searching)
        {
            CloseSearch(card);
            return;
        }

        card.Searching = true;
        card.Expanded = true;
        UpdateCard(card);
        ApplyFilter(card);
        // Next turn, once the field is in the tree.
        DispatcherQueue.GetForCurrentThread().TryEnqueue(() => card.Filter.Focus(FocusState.Programmatic));
    }

    private void CloseSearch(Card card)
    {
        if (!card.Searching)
            return;
        card.Searching = false;
        card.Filter.Text = "";
        UpdateCard(card);
        ApplyFilter(card);
    }

    /// <summary>The card's header and parts for its state, and its share of the height: an open card with rows takes
    /// an equal share (its list scrolls inside), a collapsed or loading one only what it needs.</summary>
    private static void UpdateCard(Card card)
    {
        bool open = card.IsOpen;
        bool loaded = card.Rows is not null;
        card.Chevron.Glyph = open ? ExpandedGlyph : CollapsedGlyph;
        card.CountText.Text = loaded ? card.Count.ToString(CultureInfo.InvariantCulture) : "";
        card.SearchButton.Visibility = card.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        card.EyeButton.Visibility = card.HiddenCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (card.HiddenCount > 0)
        {
            ((FontIcon)card.EyeButton.Content).Glyph = card.ShowsHidden ? EyeGlyph : EyeSlashGlyph;
            string eyeName = card.ShowsHidden
                ? $"Leave out hidden {card.Title} items"
                : $"List {card.HiddenCount} hidden {card.Title} items";
            AutomationProperties.SetName(card.EyeButton, eyeName);
            ToolTipService.SetToolTip(card.EyeButton, eyeName);
            if (card.ShowsHidden)
                card.EyeButton.Foreground = PaletteResources.Brush("BrandAccentBrush");
            else
                card.EyeButton.ClearValue(Control.ForegroundProperty);
        }

        ToolTipService.SetToolTip(card.SearchButton, card.Searching ? "Close Search" : "Search " + card.Title);
        if (card.Searching)
            card.SearchButton.Foreground = PaletteResources.Brush("BrandAccentBrush");
        else
            card.SearchButton.ClearValue(Control.ForegroundProperty);
        card.Filter.Visibility = open && loaded && card.Searching ? Visibility.Visible : Visibility.Collapsed;
        card.Body.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        card.Skeleton.Visibility = loaded ? Visibility.Collapsed : Visibility.Visible;
        card.List.Visibility = loaded ? Visibility.Visible : Visibility.Collapsed;
        if (card.Stack is { } stack)
        {
            GridLength height = open && loaded ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
            RowDefinition definition = stack.RowDefinitions[Grid.GetRow(card.Root)];
            if (definition.Height != height)
                definition.Height = height;
        }
    }
}

using System.Diagnostics;
using System.Globalization;
using Histq.App.Support;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;
using Windows.UI.ViewManagement;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// The tab row in the title bar (design header-and-tab-row.md §3.1-3.9, ported from TabStrip, TabTrack and
/// ArchiveCluster in App/Window/TabStrip.swift and WorktreeBoxShape in App/Window/TabGroups.swift at 6fa6d40), left to
/// right: the closed groups button (with its count) and the archive button, the popped-out archived tab beside it
/// (dashed orange outline, the archive's line from the button), the pinned well (fixed, never scrolls) and its divider,
/// the scrolling track (group chips and underlines, worktree boxes with their heads, the tabs; cut edges fade), the scroll
/// arrows while the track overflows, New Tab and All Tabs. It draws <see cref="MainWindow.Tabs"/> after each
/// <see cref="Sync"/>; every change goes through <see cref="MainWindow.Apply"/> (a press selects at once). Elements are
/// kept per tab, group and box across syncs. <see cref="GeometryChanged"/> fires after a layout, a scroll or a selection
/// slide step: the title bar's Passthrough regions and the joined sheet follow it. A press and a drag of a tab, a chip
/// or a worktree head go through its <see cref="TabDragController"/>; while a unit is dragged the strip draws the row
/// with it at its target (<see cref="ShowDrag"/>), the unit's elements lifted under the pointer, and the drop indicator.
/// </summary>
public sealed partial class TabStrip : Panel, ITabDragHost
{
    // Segoe Fluent Icons: ViewAll, Package (the archive box), ChevronLeft, ChevronRight, Add, ChevronDown.
    internal const string ClosedGroupsGlyph = "";
    internal const string ArchiveGlyph = "";
    private const string ScrollLeftGlyph = "";
    private const string ScrollRightGlyph = "";
    internal const string NewTabGlyph = "";
    internal const string AllTabsGlyph = "";

    /// <summary>A wheel notch (120) scrolls the track this far.</summary>
    private const double WheelStep = 48;

    /// <summary>A track item cut by a scrolled edge fades down to this opacity at most.</summary>
    private const double MinFadeOpacity = 0.2;

    /// <summary>The drop indicator's insertion bar (design §3.10): 2 epx wide, this far in from the tab band's top and
    /// bottom.</summary>
    private const double DropBarWidth = 2;
    private const double DropBarInset = 4;

    private readonly TabMetrics _m;
    private readonly TimeSpan _motion;
    private readonly UISettings _uiSettings = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    // Sections, each a canvas its items stand on. The track's content scrolls (its transform) inside a clipped viewport.
    private readonly Canvas _lead = new();
    private readonly Canvas _leadBack = new();
    private readonly Canvas _leadItems = new();
    private readonly Canvas _leadOverlay = new();
    private readonly Canvas _well = new();
    private readonly Canvas _wellBack = new();
    private readonly Canvas _wellItems = new();
    private readonly Canvas _wellIndicator = new();
    private readonly Rectangle _divider;
    private readonly Canvas _viewport = new();
    private readonly Canvas _content = new();
    private readonly Canvas _trackBack = new();
    private readonly Canvas _trackLines = new();
    private readonly Canvas _trackItems = new();
    private readonly Canvas _trackOverlay = new();
    private readonly Canvas _trackIndicator = new();
    private readonly StackPanel _arrows;
    private readonly StackPanel _buttons;
    private readonly Button _closedGroups;
    private readonly TextBlock _closedCount;
    private readonly Button _archive;
    private readonly Button _scrollLeft;
    private readonly Button _scrollRight;
    private readonly Button _newTab;
    private readonly Button _allTabs;
    private readonly TranslateTransform _scroll = new();
    private readonly RectangleGeometry _viewportClip = new();
    private readonly RectangleGeometry _stripClip = new();

    private readonly Dictionary<Guid, TabItemView> _tabViews = [];
    private readonly Dictionary<Guid, GroupChipView> _chips = [];
    private readonly Dictionary<string, WorktreeHeadView> _heads = new(StringComparer.Ordinal);

    /// <summary>The canvas each tab, chip and head was put on (<see cref="MoveTo"/>), kept here: FrameworkElement.Parent
    /// seems not to report it reliably.</summary>
    private readonly Dictionary<FrameworkElement, Canvas> _homes = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<string, double> _textWidths = new(StringComparer.Ordinal);
    private readonly TextBlock _measure;
    private readonly TabDragController _drag;
    private readonly TabKeyboard _keyboard;

    // The row's flyouts (design §3.4, 3.7-3.9), made on first use.
    private GroupFlyout? _groupFlyout;
    private ArchiveFlyout? _archiveFlyout;
    private ClosedGroupsFlyout? _closedFlyout;
    private AllTabsFlyout? _allTabsFlyout;

    /// <summary>A new group whose flyout opens once its chip is laid out (Add Tab(s) to New Group).</summary>
    private Guid? _pendingGroupFlyout;

    private MainWindow? _window;
    private WindowTabs? _model;
    private TabTrackLayout? _layout;
    private int _layoutVersion;

    // Where the sections stand in the strip, set by MeasureOverride.
    private double _leadWidth;
    private double _closedX;
    private double _archiveX;
    private double _poppedX;
    private double _wellX;
    private double _dividerX;
    private double _trackX;
    private double _trackWidth;
    private double _arrowsX;
    private double _buttonsX;
    private double _arrangedWidth;
    private bool _closedShown;
    private bool _archiveShown;

    private double _offset;
    private Guid? _selectedId;
    private bool _revealPending = true;

    /// <summary>A press on a tab, chip or head is held: the selection it made is revealed only once it is let go, so the
    /// track never scrolls under a press that may become a drag.</summary>
    private bool _pressHeld;

    // The selection slide (250 ms from the shape shown before) and the animated scroll.
    private Rect? _slideFrom;
    private TimeSpan _slideStart;
    private bool _sliding;

    /// <summary>The slide's eased progress, sampled once per frame in <see cref="OnRendering"/>: every layout pass of
    /// a frame sees the same shown rect (sampling the clock during layout made each pass differ, a layout cycle).</summary>
    private double _slideT = 1;
    private double _scrollFrom;
    private double _scrollTo;
    private TimeSpan _scrollStart;
    private bool _scrolling;
    private bool _renderingHooked;

    /// <summary>Inside MeasureOverride or ArrangeOverride: nothing that changes the tree or a layout input runs then;
    /// it waits for the post-layout step (<see cref="OnLayoutDone"/>).</summary>
    private bool _inLayout;
    private bool _geometryPending;
    private (int Version, Rect? Lead, Rect? Well, Rect? Track, Guid? Selected, bool Sliding)? _decorated;
    private (int Version, TabDrag? Drag)? _indicated;

    /// <summary>The geometry <see cref="GeometryChanged"/> last reported; it fires again only when this differs.</summary>
    private (int Version, double Offset, double Lift, double Width, Point Origin, Rect? Selected)? _reported;

    // What MeasureOverride last computed the layout for: a new layout version only when they change.
    private int _syncVersion;
    private (int Sync, double Available)? _measuredFor;

    // The layout-loop tripwire: layout passes and mutations in one dispatcher turn (or frame). Past MaxPassesPerTurn
    // the strip logs one Recovered line naming the last mutation and stops mutating until the next turn.
    private const int MaxPassesPerTurn = 20;
    private int _passes;
    private bool _passResetQueued;
    private bool _tripped;
    private string _lastMutation = "none";

    /// <summary>The automation children last announced (<see cref="NotifyAutomationChildren"/>).</summary>
    private List<FrameworkElement>? _automationChildren;

    // A drag: the unit drawn at its target (_dragLayout, the rest layout with its positions), its elements lifted by
    // _lift from there so they follow the pointer; after a drop that changes nothing, _lift eases back to 0 (snap back).
    private TabDrag? _dragShown;
    private TabTrackLayout? _dragLayout;
    private readonly List<FrameworkElement> _lifted = [];
    private (int First, int Last)? _liftedRange;
    private double _lift;
    private double _snapFrom;
    private TimeSpan _snapStart;
    private bool _snapping;

    public TabStrip()
    {
        _m = TabMetrics.FromPalette();
        _motion = PaletteResources.TimeSpan("MotionStandardDuration");
        Height = _m.Height;
        VerticalAlignment = VerticalAlignment.Bottom;
        Clip = _stripClip;

        _measure = new TextBlock { FontSize = PaletteResources.Double("ChipFontSize"), FontWeight = FontWeights.SemiBold };

        _closedCount = new TextBlock
        {
            FontSize = PaletteResources.Double("CountBadgeFontSize"),
            Foreground = TabColors.Brush(PaletteResources.Color("GraphBadgeTextColor")),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 2, 0),
            IsHitTestVisible = false,
        };
        _closedGroups = StowButton(ClosedGroupsGlyph, PaletteResources.Color("GroupGreyColor"), _closedCount);
        _archive = StowButton(ArchiveGlyph, TabColors.Archive, null);
        _closedGroups.Click += (_, _) => (_closedFlyout ??= new ClosedGroupsFlyout(this)).Open(_closedGroups);
        _archive.Click += (_, _) => (_archiveFlyout ??= new ArchiveFlyout(this)).Open(_archive);
        _leadItems.Children.Add(_closedGroups);
        _leadItems.Children.Add(_archive);
        _lead.Children.Add(_leadBack);
        _lead.Children.Add(_leadItems);
        _lead.Children.Add(_leadOverlay);

        _well.Children.Add(_wellBack);
        _well.Children.Add(_wellItems);
        _well.Children.Add(_wellIndicator);
        _divider = new Rectangle
        {
            Width = 1,
            Height = _m.DividerHeight,
            Fill = TabColors.Brush(PaletteResources.Color("TabRowDividerColor")),
        };

        _content.RenderTransform = _scroll;
        _content.Children.Add(_trackBack);
        _content.Children.Add(_trackLines);
        _content.Children.Add(_trackItems);
        _content.Children.Add(_trackOverlay);
        _content.Children.Add(_trackIndicator);
        _viewport.Children.Add(_content);
        _viewport.Clip = _viewportClip;
        // A background, even transparent, so a wheel over the gaps between tabs scrolls too.
        _viewport.Background = new SolidColorBrush(Colors.Transparent);
        _viewport.PointerWheelChanged += OnWheel;

        _scrollLeft = RowButton(ScrollLeftGlyph, "Scroll Tabs Left");
        _scrollRight = RowButton(ScrollRightGlyph, "Scroll Tabs Right");
        // Not in the row's focus group: the track scrolls to the focused item by itself.
        _scrollLeft.IsTabStop = false;
        _scrollRight.IsTabStop = false;
        _scrollLeft.Click += (_, _) => ScrollPage(-1);
        _scrollRight.Click += (_, _) => ScrollPage(1);
        _arrows = new StackPanel { Orientation = Orientation.Horizontal, Spacing = _m.Gap };
        _arrows.Children.Add(_scrollLeft);
        _arrows.Children.Add(_scrollRight);

        _newTab = RowButton(NewTabGlyph, "New Tab");
        _allTabs = RowButton(AllTabsGlyph, "All Tabs");
        _newTab.Click += (_, _) => _window?.Apply(model => model.OpenTab(null));
        _allTabs.Click += (_, _) => (_allTabsFlyout ??= new AllTabsFlyout(this)).Open(_allTabs);
        _buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = _m.Gap };
        _buttons.Children.Add(_newTab);
        _buttons.Children.Add(_allTabs);

        Children.Add(_well);
        Children.Add(_divider);
        Children.Add(_viewport);
        Children.Add(_arrows);
        Children.Add(_buttons);
        // Last, so the popped-out tab's flares lie over the archive button and the well's edge.
        Children.Add(_lead);

        _drag = new TabDragController(this);
        _keyboard = new TabKeyboard(this);
    }

    /// <summary>After a layout, a scroll step or a selection slide step: the shown tabs (and the selected one) moved.</summary>
    internal event EventHandler? GeometryChanged;

    /// <summary>A press on a tab, chip or worktree head is held (true) or let go (false): the title bar's Passthrough
    /// rects stay as they are while it is held, so a drag never turns into a window move (design §3.10).</summary>
    internal event EventHandler<bool>? PressHeldChanged;

    /// <summary>A flyout of the row closed: the title bar sets its Passthrough rects again.</summary>
    internal event EventHandler? FlyoutClosed;

    /// <summary>The window whose tabs it shows; call before the first <see cref="Sync"/>. Until the window closes, the
    /// tabs' icons are drawn again when the icon images change (an image loaded, uploaded or removed).</summary>
    internal void Attach(MainWindow window)
    {
        _window = window;
        CustomIconImages.Shared.Changed += OnIconImagesChanged;
        window.Closed += (_, _) => CustomIconImages.Shared.Changed -= OnIconImagesChanged;
    }

    /// <summary>Raised on the UI thread, outside any layout pass.</summary>
    private void OnIconImagesChanged(object? sender, EventArgs e)
    {
        foreach (TabItemView view in _tabViews.Values)
            view.RefreshIcon();
    }

    internal MainWindow? Window => _window;

    /// <summary>The tabs as last synced.</summary>
    internal WindowTabs? Model => _model;

    /// <summary>The row at rest, as last measured.</summary>
    internal TabTrackLayout? Layout => _layout;

    // Actions: each goes through MainWindow.Apply, which syncs the strip again.

    /// <summary>Selects the tab at once (click-first rule).</summary>
    internal void Select(Guid id) => _window?.Apply(model => model.SelectTab(id));

    /// <summary>A mouse-down on a tab (TabPress, App/Window/TabStrip.swift): a plain press ends the multi-selection and
    /// selects the tab; Shift extends the multi-selection to it and Ctrl toggles it, neither changing the shown tab.</summary>
    internal void Pick(Guid id, TabPress press) => _window?.Apply(model => PickIn(model, id, press));

    /// <summary><see cref="Pick"/>'s change to <paramref name="model"/> (shared with the vertical tabs).</summary>
    internal static void PickIn(WindowTabs model, Guid id, TabPress press)
    {
        switch (press)
        {
            case TabPress.Extend:
                model.ExtendSelection(id);
                break;
            case TabPress.Toggle:
                model.ToggleSelection(id);
                break;
            default:
                model.ClearSelection();
                model.SelectTab(id);
                break;
        }
    }

    // ITabDragHost: the strip's own members under the shared names (the menus, flyouts and TabDragController).

    MainWindow? ITabsView.Window => _window;

    WindowTabs? ITabsView.Model => _model;

    bool ITabsView.Vertical => false;

    void ITabsView.CloseTab(Guid id) => CloseTab(id);

    void ITabsView.ShowGroupFlyoutWhenPlaced(Guid id) => ShowGroupFlyoutWhenPlaced(id);

    void ITabsView.OnFlyoutClosed() => OnFlyoutClosed();

    (TabGroupSpans Spans, TabGroupSpans.Positions Positions)? ITabDragHost.DragLayout =>
        _layout is { } layout ? (layout.Spans, layout.Positions) : null;

    void ITabDragHost.Pick(Guid id, TabPress press) => Pick(id, press);

    void ITabDragHost.ToggleGroup(Guid id) => ToggleGroup(id);

    bool ITabDragHost.PressesAlone(Guid id) => IsPopped(id);

    UIElement? ITabDragHost.SpaceOf(FrameworkElement element) => SpaceOf(element);

    double ITabDragHost.SpansPosition(UIElement space, double along) => SpansX(space, along);

    void ITabDragHost.SetPressHeld(bool held) => SetPressHeld(held);

    void ITabDragHost.ShowDrag(TabDrag drag) => ShowDrag(drag);

    void ITabDragHost.SnapBack(TabDrag drag) => SnapBack(drag);

    void ITabDragHost.EndDrag() => EndDrag();

    /// <summary>The close button: closes the tab; the window closes with its last tab.</summary>
    internal void CloseTab(Guid id)
    {
        if (_window is not { } window)
            return;
        bool keep = true;
        window.Apply(model => keep = model.CloseTab(id));
        if (!keep)
            window.Close();
    }

    /// <summary>A click on a group's chip: collapses or expands it.</summary>
    internal void ToggleGroup(Guid id) => _window?.Apply(model => model.ToggleGroup(id));

    /// <summary>Opens group <paramref name="id"/>'s flyout at its chip (a right click, Shift+F10 or the Menu key on
    /// it); nothing while the chip is not shown.</summary>
    internal void ShowGroupFlyout(Guid id)
    {
        if (_chips.TryGetValue(id, out GroupChipView? chip) && chip.Visibility == Visibility.Visible && IsPlaced(chip))
            (_groupFlyout ??= new GroupFlyout(this)).ShowFor(id, chip);
    }

    /// <summary>A group just made (Add Tab(s) to New Group): its flyout opens once the next layout has placed its chip,
    /// which scrolls into view first (the Mac's popover after a new group).</summary>
    internal void ShowGroupFlyoutWhenPlaced(Guid id)
    {
        _pendingGroupFlyout = id;
        InvalidateArrange();
    }

    /// <summary>A flyout of the row closed (<see cref="TabFlyout"/>).</summary>
    internal void OnFlyoutClosed() => FlyoutClosed?.Invoke(this, EventArgs.Empty);

    /// <summary>
    /// Brings the row in line with <paramref name="model"/>: one element per tab, group chip and worktree head (kept
    /// across syncs), each element's state and UI Automation name, the stow buttons' counts. Placement waits for the
    /// next layout pass; a new selection slides there and scrolls into view.
    /// </summary>
    internal void Sync(WindowTabs model)
    {
        // The model changed under a drag (another window's or a worker's change): its indices no longer hold.
        _drag.Cancel();
        _keyboard.BeforeSync();
        _model = model;
        Preferences? preferences = _window?.Manager.Preferences;
        string defaultEmoji = preferences?.Get<string>(PrefKey.DefaultTabEmoji) ?? string.Empty;
        int defaultColor = preferences?.Get<int>(PrefKey.DefaultTabIconColor) ?? -1;

        IReadOnlyList<WindowTabs.Tab> tabs = model.Tabs;
        IReadOnlyList<TabGroup> groups = model.ManualGroups;
        IReadOnlyList<WorktreeBox> boxes = model.WorktreeBoxes;
        Guid? selected = model.SelectedTabId;
        var hidden = new HashSet<int>(groups.Where(group => group.Group.Collapsed)
            .SelectMany(group => Enumerable.Range(group.First, group.Count)));

        var liveTabs = new HashSet<Guid>();
        for (int index = 0; index < tabs.Count; index++)
        {
            WindowTabs.Tab tab = tabs[index];
            liveTabs.Add(tab.Id);
            if (!_tabViews.TryGetValue(tab.Id, out TabItemView? view))
            {
                view = new TabItemView(this, tab.Id);
                _drag.Attach(view);
                _keyboard.Attach(view);
                _tabViews[tab.Id] = view;
            }

            TabGroup? group = groups.FirstOrDefault(candidate => candidate.Contains(index));
            WorktreeBox? box = boxes.FirstOrDefault(candidate => candidate.Contains(index));
            bool isSelected = tab.Id == selected;
            string title = DisplayText.Sanitize(tab.Title);
            view.Update(new TabItemState(
                title,
                TabName(title, tab, group, box),
                TabToolTip(title, tab),
                tab.Pinned,
                isSelected,
                !isSelected && model.MultiSelection.Contains(tab.Id),
                new TabIconState(tab.Emoji, GlyphOf(tab), tab.IconColor, isSelected, null, null, defaultEmoji,
                    defaultColor)));
            MoveTo(view, tab.Archived ? _leadItems : tab.Pinned ? _wellItems : _trackItems);
            view.Visibility = hidden.Contains(index) ? Visibility.Collapsed : Visibility.Visible;
        }

        RemoveStale(_tabViews, liveTabs);

        var liveGroups = new HashSet<Guid>();
        foreach (TabGroup group in groups)
        {
            liveGroups.Add(group.Id);
            if (!_chips.TryGetValue(group.Id, out GroupChipView? chip))
            {
                chip = new GroupChipView(this, group.Id);
                _drag.Attach(chip);
                _keyboard.Attach(chip);
                _chips[group.Id] = chip;
            }

            string name = ChipName(group);
            chip.Update(ChipText(group), TabColors.Group(group.Group.ColorIndex), name,
                $"{name}. Click to {(group.Group.Collapsed ? "show" : "hide")} its tabs.", group.Group.Collapsed);
            MoveTo(chip, _trackItems);
        }

        RemoveStale(_chips, liveGroups);

        var liveBoxes = new HashSet<string>(StringComparer.Ordinal);
        foreach (WorktreeBox box in boxes.Where(box => !tabs[box.First].Pinned))
        {
            liveBoxes.Add(box.Key);
            if (!_heads.TryGetValue(box.Key, out WorktreeHeadView? head))
            {
                head = new WorktreeHeadView(this);
                _drag.Attach(head);
                _keyboard.Attach(head);
                _heads[box.Key] = head;
            }

            int count = box.Last - box.First + 1;
            head.Update(tabs[box.First].Id, box.Key,
                $"Worktrees of {RepoName(box.Key)} ({count.ToString(CultureInfo.InvariantCulture)})");
            MoveTo(head, _trackItems);
            head.Visibility = hidden.Contains(box.First) ? Visibility.Collapsed : Visibility.Visible;
        }

        RemoveStale(_heads, liveBoxes);

        _closedShown = model.ClosedGroups.Count > 0;
        string closed = $"Closed groups ({model.ClosedGroups.Count.ToString(CultureInfo.InvariantCulture)})";
        AutomationProperties.SetName(_closedGroups, closed);
        ToolTipService.SetToolTip(_closedGroups, closed);
        _closedCount.Text = model.ClosedGroups.Count.ToString(CultureInfo.InvariantCulture);
        _closedGroups.Visibility = _closedShown ? Visibility.Visible : Visibility.Collapsed;

        int archived = model.ArchivedTabs.Count + (model.ArchivedOut is null ? 0 : 1);
        _archiveShown = archived > 0;
        string archive = $"Archived tabs ({archived.ToString(CultureInfo.InvariantCulture)})";
        AutomationProperties.SetName(_archive, archive);
        ToolTipService.SetToolTip(_archive, archive);
        _archive.Visibility = _archiveShown ? Visibility.Visible : Visibility.Collapsed;

        if (selected != _selectedId)
        {
            StartSlide();
            _selectedId = selected;
            _revealPending = true;
        }

        _syncVersion++;
        _lastMutation = "TabStrip.Sync";
        InvalidateMeasure();
        // Reveal, the decorations and GeometryChanged run after the layout pass ArrangeOverride schedules, also when
        // the size stays the same.
        InvalidateArrange();
        _keyboard.AfterSync();

        // An open flyout shows the tabs as they are now, or hides when what it shows went.
        _groupFlyout?.Synced(model);
        _archiveFlyout?.Synced(model);
        _closedFlyout?.Synced(model);
        _allTabsFlyout?.Synced(model);
    }

    /// <summary>
    /// The selected tab's rect in the strip's coordinates as shown now (mid-slide included), or null when it has no
    /// joined sheet: not laid out yet, in a collapsed group, cut by the track's edge or by a narrow window.
    /// </summary>
    internal Rect? SelectedTabRect()
    {
        if (_layout is null || SelectedIndex() is not { } index || TargetRect(index) is not { } target)
            return null;
        double flare = _m.Flare;
        if (_layout.InTrack(index)
            && (target.X - flare < _trackX - 0.5 || target.X + target.Width + flare > _trackX + _trackWidth + 0.5))
            return null;
        if (target.X + target.Width + flare > _arrangedWidth + 0.5)
            return null;
        return ShownRect();
    }

    /// <summary>The elements that take input in the title bar: its Passthrough regions.</summary>
    internal IEnumerable<FrameworkElement> InteractiveElements()
    {
        if (_closedShown)
            yield return _closedGroups;
        if (_archiveShown)
            yield return _archive;
        foreach (TabItemView view in _tabViews.Values.Where(view => view.Visibility == Visibility.Visible))
            yield return view;
        foreach (GroupChipView chip in _chips.Values)
            yield return chip;
        foreach (WorktreeHeadView head in _heads.Values.Where(head => head.Visibility == Visibility.Visible))
            yield return head;
        if (_layout?.Overflows == true)
        {
            yield return _scrollLeft;
            yield return _scrollRight;
        }

        yield return _newTab;
        yield return _allTabs;
    }

    /// <summary>What clips <paramref name="element"/>'s Passthrough rect: the track's viewport for its items, else the
    /// strip (a narrow window cuts it).</summary>
    internal FrameworkElement ClipOf(FrameworkElement element) =>
        ReferenceEquals(HomeOf(element), _trackItems) ? _viewport : this;

    /// <summary>
    /// The row's items in TabArrangement order for UI Automation: the stow buttons, the pinned tabs, the track (each
    /// group's chip before its tabs, each worktree head before its box), the popped-out archived tab last (as the model
    /// keeps it), then the scroll arrows, New Tab and All Tabs. Tabs of a collapsed group have no element shown.
    /// </summary>
    internal IEnumerable<FrameworkElement> AutomationOrder()
    {
        if (_closedShown)
            yield return _closedGroups;
        if (_archiveShown)
            yield return _archive;

        if (_layout is { } layout)
        {
            for (int index = 0; index < layout.PinnedCount; index++)
            {
                if (_tabViews.TryGetValue(layout.Tabs[index].Id, out TabItemView? pinned))
                    yield return pinned;
            }

            foreach (TabGroupSpans.Item item in layout.Spans.Items)
            {
                if (item is TabGroupSpans.Item.Header header)
                {
                    if (_chips.TryGetValue(header.Group.Id, out GroupChipView? chip))
                        yield return chip;
                    continue;
                }

                if (item is not TabGroupSpans.Item.Tab tab || !layout.InTrack(tab.Index))
                    continue;
                if (layout.Headed.Contains(tab.Index)
                    && layout.Boxes.FirstOrDefault(box => box.First == tab.Index) is { } box
                    && _heads.TryGetValue(box.Key, out WorktreeHeadView? head))
                    yield return head;
                if (_tabViews.TryGetValue(tab.Value.Id, out TabItemView? view))
                    yield return view;
            }

            if (layout.Popped is { } popped && _tabViews.TryGetValue(layout.Tabs[popped].Id, out TabItemView? poppedView))
                yield return poppedView;

            if (layout.Overflows)
            {
                yield return _scrollLeft;
                yield return _scrollRight;
            }
        }

        yield return _newTab;
        yield return _allTabs;
    }

    /// <summary>
    /// The row's keyboard focus group in the order it is drawn (<see cref="TabKeyboard"/>): <see cref="AutomationOrder"/>
    /// with the popped-out archived tab right after the stow buttons, where it stands, and without the scroll arrows.
    /// Only shown items.
    /// </summary>
    internal IEnumerable<FrameworkElement> FocusOrder()
    {
        List<FrameworkElement> order = [.. AutomationOrder().Where(element =>
            element.Visibility == Visibility.Visible && !ReferenceEquals(element, _scrollLeft)
            && !ReferenceEquals(element, _scrollRight))];
        if (order.FirstOrDefault(element => element is TabItemView view && ReferenceEquals(HomeOf(view), _leadItems))
            is { } popped)
        {
            order.Remove(popped);
            order.Insert(order.TakeWhile(element =>
                ReferenceEquals(element, _closedGroups) || ReferenceEquals(element, _archive)).Count(), popped);
        }

        return order;
    }

    /// <summary>The selected tab's element while it is shown: where Tab into the row lands.</summary>
    internal FrameworkElement? SelectedItem() =>
        _selectedId is { } id && _tabViews.TryGetValue(id, out TabItemView? view) && view.Visibility == Visibility.Visible
            && HomeOf(view) is not null
            ? view
            : null;

    /// <summary>A press on a tab, chip or head is held (a possible drag): the keyboard leaves the row alone.</summary>
    internal bool PressHeld => _pressHeld;

    /// <summary>Scrolls a track item (a focused one, a new group's chip), flares included, into view; an item of the
    /// lead or the well never scrolls. Measured against where a running scroll is heading, so asking again does not
    /// restart it. Unanimated, it jumps there.</summary>
    internal void RevealItem(FrameworkElement element, bool animate = true)
    {
        if (!ReferenceEquals(HomeOf(element), _trackItems) || _layout?.Overflows != true || !double.IsFinite(element.Width))
            return;
        double start = Canvas.GetLeft(element) - _m.Flare;
        double end = Canvas.GetLeft(element) + element.Width + _m.Flare;
        double current = _scrolling ? _scrollTo : _offset;
        double target = current;
        if (start < current)
            target = start;
        else if (end > current + _trackWidth)
            target = end - _trackWidth;
        if (Math.Abs(target - current) > 0.5)
            ScrollTo(target, animate);
    }

    /// <summary>A button of the row: lightweight styling of the default template (the default Button keeps its focus
    /// and automation behaviour).</summary>
    internal static void StyleButton(Button button, Brush rest, Brush hover, Brush pressed)
    {
        Brush none = new SolidColorBrush(Colors.Transparent);
        button.Resources["ButtonBackground"] = rest;
        button.Resources["ButtonBackgroundPointerOver"] = hover;
        button.Resources["ButtonBackgroundPressed"] = pressed;
        button.Resources["ButtonBackgroundDisabled"] = rest;
        button.Resources["ButtonBorderBrush"] = none;
        button.Resources["ButtonBorderBrushPointerOver"] = none;
        button.Resources["ButtonBorderBrushPressed"] = none;
        button.Resources["ButtonBorderBrushDisabled"] = none;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new TabStripAutomationPeer(this);

    protected override Size MeasureOverride(Size availableSize)
    {
        _inLayout = true;
        try
        {
            return MeasureRow(availableSize);
        }
        finally
        {
            _inLayout = false;
        }
    }

    /// <summary>Lays out the row and measures the sections. Only time-independent values: the same inputs give the
    /// same placement on every pass (PlaceItems' equal-value sets are no-ops).</summary>
    private Size MeasureRow(Size availableSize)
    {
        double height = _m.Height;
        double width = double.IsFinite(availableSize.Width) ? availableSize.Width : double.MaxValue / 4;
        if (_model is not { } model)
        {
            foreach (UIElement child in Children)
                child.Measure(new Size(0, height));
            return new Size(0, height);
        }

        // Lead: the closed groups button, the archive button 8 apart, the popped-out tab a tab gap after it.
        double x = 0;
        _closedX = 0;
        if (_closedShown)
            x += _m.SquareSize;
        if (_archiveShown)
        {
            if (_closedShown)
                x += _m.StowGap;
            _archiveX = x;
            x += _m.SquareSize;
        }

        int? popped = model.ArchivedOut is null ? null : model.Tabs.Count - 1;
        if (popped is not null)
        {
            x += _m.Gap;
            _poppedX = x;
            x += _m.ArchivedWidth;
        }

        _leadWidth = x;

        // The pinned well, then the divider, each a flare's room apart so a selected pinned tab's flares fit.
        int pinned = model.PinnedCount;
        double wellWidth = pinned > 0 ? pinned * _m.PinnedWidth + (pinned - 1) * _m.Gap : 0;
        if (pinned > 0)
        {
            _wellX = _leadWidth > 0 ? _leadWidth + _m.Gap + _m.Flare : 0;
            _dividerX = _wellX + wellWidth + _m.DividerSpacing;
            // The track's content starts with a flare's room: its first item stands that far after the divider.
            _trackX = _dividerX + 1;
        }
        else
        {
            // Its first item a tab gap after the lead (the flares' rooms overlap), else a flare in from the start.
            _trackX = _leadWidth > 0 ? _leadWidth + _m.Gap - _m.Flare : 0;
        }

        // The scroll arrows' room is always kept (TabTrack.arrowsWidth), so the tab width does not jump as they show.
        double pair = 2 * _m.ButtonSize + _m.Gap;
        double trackAvailable = width - _trackX - (_m.ArrowSpacing + pair) - (_m.ArrowSpacing + pair);
        _layout = TabTrackLayout.Compute(model, trackAvailable, _m, ChipWidth);
        // A new version (so the decorations are rebuilt) only when the inputs changed: a re-measure of the same row
        // must not rebuild anything, or a measure pass would feed the next one.
        if (_measuredFor != (_syncVersion, trackAvailable))
        {
            _measuredFor = (_syncVersion, trackAvailable);
            _layoutVersion++;
        }

        TabTrackLayout layout = _layout;
        _trackWidth = layout.Overflows ? Math.Max(0, trackAvailable) : layout.RowWidth;

        x = _trackX + _trackWidth;
        if (layout.Overflows)
        {
            _arrowsX = x + _m.ArrowSpacing;
            x = _arrowsX + pair;
        }

        _buttonsX = x + _m.ArrowSpacing;
        x = _buttonsX + pair;

        // A drag keeps its unit, target and translation across a new layout (a resize): drawn again from this one.
        if (_dragShown is { } drag)
            LayOutDrag(layout, drag);
        else
            _dragLayout = null;
        PlaceItems(Shown!, popped);
        ApplyLift();
        _offset = Math.Clamp(_offset, 0, Math.Max(0, layout.RowWidth - _trackWidth));
        _scroll.X = -_offset;

        _lead.Visibility = _leadWidth > 0 ? Visibility.Visible : Visibility.Collapsed;
        _well.Visibility = pinned > 0 ? Visibility.Visible : Visibility.Collapsed;
        _divider.Visibility = _well.Visibility;
        _arrows.Visibility = layout.Overflows ? Visibility.Visible : Visibility.Collapsed;

        _lead.Measure(new Size(_leadWidth, height));
        _well.Measure(new Size(wellWidth, height));
        _divider.Measure(new Size(1, _m.DividerHeight));
        _viewport.Measure(new Size(_trackWidth, height));
        _arrows.Measure(new Size(pair, _m.ButtonSize));
        _buttons.Measure(new Size(pair, _m.ButtonSize));
        return new Size(Math.Min(x, width), height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        _inLayout = true;
        CountPass("TabStrip.ArrangeOverride");
        try
        {
            double height = _m.Height;
            double pair = 2 * _m.ButtonSize + _m.Gap;
            double buttonTop = (height - _m.ButtonSize) / 2;
            _lead.Arrange(new Rect(0, 0, _leadWidth, height));
            _well.Arrange(new Rect(_wellX, 0, _layout?.WellWidth ?? 0, height));
            _divider.Arrange(new Rect(_dividerX, (height - _m.DividerHeight) / 2, 1, _m.DividerHeight));
            _viewport.Arrange(new Rect(_trackX, 0, _trackWidth, height));
            _arrows.Arrange(new Rect(_arrowsX, buttonTop, pair, _m.ButtonSize));
            _buttons.Arrange(new Rect(_buttonsX, buttonTop, pair, _m.ButtonSize));
            _viewportClip.Rect = new Rect(0, 0, _trackWidth, height);
            _stripClip.Rect = new Rect(0, 0, finalSize.Width, height);
            _arrangedWidth = finalSize.Width;

            // Only positions here: the reveal, the keyboard's reveal, fades, arrows, decorations, the indicator and
            // GeometryChanged run once the layout pass is done (OnLayoutDone).
            ScheduleGeometryChanged();
            return new Size(finalSize.Width, height);
        }
        finally
        {
            _inLayout = false;
        }
    }

    // Layout.

    /// <summary>Puts every element where the layout says: the stow buttons and popped tab in the lead, the pinned tabs
    /// in the well, the chips, heads and tabs along the track's content.</summary>
    private void PlaceItems(TabTrackLayout layout, int? popped)
    {
        double height = _m.Height;
        double squareTop = (height - _m.SquareSize) / 2;
        Place(_closedGroups, _closedX, squareTop, _m.SquareSize, _m.SquareSize);
        Place(_archive, _archiveX, squareTop, _m.SquareSize, _m.SquareSize);

        for (int index = 0; index < layout.Tabs.Count; index++)
        {
            if (!_tabViews.TryGetValue(layout.Tabs[index].Id, out TabItemView? view))
                continue;
            if (index == popped)
                Place(view, _poppedX, 0, _m.ArchivedWidth, height);
            else if (!layout.Hidden.Contains(index))
                Place(view, layout.TabX(index), 0, layout.TabElementWidth(index), height);
        }

        foreach (TabGroup group in layout.Groups)
        {
            if (_chips.TryGetValue(group.Id, out GroupChipView? chip)
                && layout.Positions.Headers.TryGetValue(group.Id, out double start))
                Place(chip, layout.ContentX(start), (height - _m.ChipHeight) / 2, ChipWidth(group), _m.ChipHeight);
        }

        foreach (WorktreeBox box in layout.Boxes.Where(box => layout.Headed.Contains(box.First)))
        {
            if (_heads.TryGetValue(box.Key, out WorktreeHeadView? head))
            {
                Place(head, layout.ContentX(layout.Positions.Tabs.GetValueOrDefault(box.First)), 0, _m.HeadWidth,
                    height - _m.BottomInset);
            }
        }

        _content.Width = layout.RowWidth;
        _content.Height = height;
    }

    private static void Place(FrameworkElement element, double x, double y, double width, double height)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        element.Width = Math.Max(0, width);
        element.Height = Math.Max(0, height);
    }

    /// <summary>A chip's width: its text's width plus padding, at least a square, at most ChipMaxWidth; a square
    /// without text.</summary>
    private double ChipWidth(TabGroup group)
    {
        string text = ChipText(group);
        if (text.Length == 0)
            return _m.ChipHeight;
        return Math.Max(_m.ChipHeight, Math.Min(_m.ChipMaxWidth, Math.Ceiling(TextWidth(text)) + 2 * _m.ChipPadding));
    }

    private double TextWidth(string text)
    {
        if (!_textWidths.TryGetValue(text, out double width))
        {
            _measure.Text = text;
            _measure.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            width = _measure.DesiredSize.Width;
            _textWidths[text] = width;
        }

        return width;
    }

    // Scrolling.

    /// <summary>Scrolls the selected track tab, flares included, into view.</summary>
    private void Reveal()
    {
        if (_layout is not { } layout || SelectedIndex() is not { } index || !layout.InTrack(index))
            return;
        double start = layout.TabX(index) - _m.Flare;
        double end = layout.TabX(index) + layout.TabWidth + _m.Flare;
        double target = _offset;
        if (start < _offset)
            target = start;
        else if (end > _offset + _trackWidth)
            target = end - _trackWidth;
        if (Math.Abs(target - _offset) > 0.5)
            ScrollTo(target, animate: true);
    }

    /// <summary>A page each way: the visible width less one tab, so a tab stays in view across the jump.</summary>
    private void ScrollPage(int direction)
    {
        double step = Math.Max(_trackWidth - _m.MinWidth, _m.MinWidth);
        ScrollTo((_scrolling ? _scrollTo : _offset) + direction * step, animate: true);
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (_layout?.Overflows != true)
            return;
        var properties = e.GetCurrentPoint(_viewport).Properties;
        double notches = properties.MouseWheelDelta / 120.0;
        // A vertical wheel up scrolls toward the start; a horizontal wheel (or tilt) right toward the end.
        double delta = (properties.IsHorizontalMouseWheel ? notches : -notches) * WheelStep;
        _scrolling = false;
        ScrollTo(_offset + delta, animate: false);
        e.Handled = true;
    }

    private void ScrollTo(double target, bool animate)
    {
        double end = Math.Max(0, (_layout?.RowWidth ?? 0) - _trackWidth);
        target = Math.Clamp(target, 0, end);
        if (!animate || !_uiSettings.AnimationsEnabled)
        {
            _scrolling = false;
            SetOffset(target);
            return;
        }

        _scrollFrom = _offset;
        _scrollTo = target;
        _scrollStart = _clock.Elapsed;
        _scrolling = true;
        HookRendering();
    }

    private void SetOffset(double offset)
    {
        if (Math.Abs(offset - _offset) < 0.01)
            return;
        _offset = offset;
        _scroll.X = -offset;
        _lastMutation = "TabStrip.SetOffset";
        if (_inLayout)
        {
            ScheduleGeometryChanged();
            return;
        }

        UpdateFades();
        UpdateArrows();
        UpdateDecorations();
        RaiseGeometryChanged();
    }

    /// <summary>
    /// Fades the track's items cut by a scrolled edge (design §3.9's 28 epx edge fade): an item reaching into the fade
    /// band dims by how much of it (and the band) lies past the edge. Per item, not per pixel: WinUI has no opacity mask.
    /// </summary>
    private void UpdateFades()
    {
        if (_layout is not { } layout)
            return;
        double end = Math.Max(0, layout.RowWidth - _trackWidth);
        bool leftCut = layout.Overflows && _offset > 0.5;
        bool rightCut = layout.Overflows && _offset < end - 0.5;
        double fade = _m.EdgeFade;
        double viewEnd = _offset + _trackWidth;
        foreach (UIElement child in _trackItems.Children)
        {
            if (child is not FrameworkElement item)
                continue;
            double start = Canvas.GetLeft(item);
            double stop = start + (double.IsFinite(item.Width) ? item.Width : 0);
            double extent = stop - start + fade;
            double opacity = 1;
            if (leftCut && start < _offset + fade)
                opacity = Math.Min(opacity, Math.Clamp((stop - _offset) / extent, MinFadeOpacity, 1));
            if (rightCut && stop > viewEnd - fade)
                opacity = Math.Min(opacity, Math.Clamp((viewEnd - start) / extent, MinFadeOpacity, 1));
            item.Opacity = opacity;
        }
    }

    /// <summary>Each scroll arrow is enabled while the track can scroll its way (TabTrack's arrows, Mac parity).</summary>
    private void UpdateArrows()
    {
        double end = Math.Max(0, (_layout?.RowWidth ?? 0) - _trackWidth);
        bool overflows = _layout?.Overflows == true;
        SetEnabled(_scrollLeft, overflows && _offset > 0.5);
        SetEnabled(_scrollRight, overflows && _offset < end - 0.5);

        static void SetEnabled(Button button, bool enabled)
        {
            if (button.IsEnabled != enabled)
                button.IsEnabled = enabled;
        }
    }

    // The selection's shape: where it stands, and its 250 ms slide.

    private int? SelectedIndex()
    {
        if (_layout is not { } layout || _selectedId is not { } id)
            return null;
        for (int index = 0; index < layout.Tabs.Count; index++)
        {
            if (layout.Tabs[index].Id == id)
                return index;
        }

        return null;
    }

    /// <summary>Where the tab at <paramref name="index"/> stands in the strip's coordinates; null while hidden.</summary>
    private Rect? TargetRect(int index)
    {
        if (Shown is not { } layout)
            return null;
        double height = _m.Height;
        if (layout.Tabs[index].Archived)
            return new Rect(_poppedX, 0, _m.ArchivedWidth, height);
        // A lifted tab stands where the pointer holds it (a drag, or its snap back).
        double lift = _liftedRange is { } lifted && index >= lifted.First && index <= lifted.Last ? _lift : 0;
        if (index < layout.PinnedCount)
            return new Rect(_wellX + layout.TabX(index) + lift, 0, _m.PinnedWidth, height);
        if (!layout.InTrack(index))
            return null;
        return new Rect(_trackX + layout.TabX(index) + lift - _offset, 0, layout.TabWidth, height);
    }

    /// <summary>The selected tab's shape as drawn now: on its way from the previous selection while sliding.</summary>
    private Rect? ShownRect()
    {
        if (SelectedIndex() is not { } index || TargetRect(index) is not { } target)
            return null;
        if (!_sliding || _slideFrom is not { } from)
            return target;
        double t = _slideT;
        return new Rect(
            from.X + (target.X - from.X) * t, target.Y, from.Width + (target.Width - from.Width) * t, target.Height);
    }

    private void StartSlide()
    {
        _slideFrom = ShownRect();
        if (_slideFrom is null || !_uiSettings.AnimationsEnabled)
        {
            _sliding = false;
            return;
        }

        _slideStart = _clock.Elapsed;
        _slideT = 0;
        _sliding = true;
        HookRendering();
    }

    private double Progress(TimeSpan start, TimeSpan now) =>
        _motion <= TimeSpan.Zero ? 1 : Math.Clamp((now - start) / _motion, 0, 1);

    /// <summary>Fast then settling, as the Mac's snappy animation.</summary>
    private static double Ease(double t) => 1 - Math.Pow(1 - t, 3);

    private void HookRendering()
    {
        if (_renderingHooked)
            return;
        _renderingHooked = true;
        CompositionTarget.Rendering += OnRendering;
    }

    /// <summary>
    /// A frame: the one place the scroll, slide and snap-back progress are sampled from the clock (once, stored), so
    /// every layout pass of the frame reads the same values; then the frame's decorations and GeometryChanged.
    /// </summary>
    private void OnRendering(object? sender, object e)
    {
        ResetPasses();
        TimeSpan now = _clock.Elapsed;
        if (_scrolling)
        {
            double t = Progress(_scrollStart, now);
            _scrolling = t < 1;
            SetOffset(_scrollFrom + (_scrollTo - _scrollFrom) * Ease(t));
        }

        if (_sliding)
        {
            double t = Progress(_slideStart, now);
            _slideT = Ease(t);
            _sliding = t < 1;
            UpdateDecorations();
            RaiseGeometryChanged();
        }

        if (_snapping)
        {
            double t = Progress(_snapStart, now);
            _snapping = t < 1;
            if (_snapping)
            {
                _lift = _snapFrom * (1 - Ease(t));
                ApplyLift();
            }
            else
            {
                ClearLift();
            }

            UpdateDecorations();
            RaiseGeometryChanged();
        }

        if (!_scrolling && !_sliding && !_snapping)
        {
            CompositionTarget.Rendering -= OnRendering;
            _renderingHooked = false;
        }
    }

    /// <summary>Runs the post-layout step (<see cref="OnLayoutDone"/>, which raises <see cref="GeometryChanged"/>)
    /// once the current layout pass is done (element bounds are final then), not on every later pass.</summary>
    private void ScheduleGeometryChanged()
    {
        if (_geometryPending)
            return;
        _geometryPending = true;
        LayoutUpdated += OnLayoutDone;
    }

    /// <summary>
    /// The post-layout step, once per layout pass that arranged the strip: everything that changes the tree or a
    /// layout input and used to run inside ArrangeOverride. Idempotent: run again on an unchanged row, it changes
    /// nothing (each step compares with what it last did), so the layout it may cause settles.
    /// </summary>
    private void OnLayoutDone(object? sender, object e)
    {
        LayoutUpdated -= OnLayoutDone;
        _geometryPending = false;
        if (_tripped)
            return;

        if (_revealPending && !_pressHeld && _layout is not null)
        {
            _revealPending = false;
            Reveal();
        }

        if (!_pressHeld && _layout is not null)
            _keyboard.Arranged();

        OpenPendingGroupFlyout();

        UpdateFades();
        UpdateArrows();
        UpdateDecorations();
        UpdateIndicator();
        NotifyAutomationChildren();
        RaiseGeometryChanged();
    }

    /// <summary>
    /// The post-layout step's part for <see cref="ShowGroupFlyoutWhenPlaced"/>: once the new group's chip stands on the
    /// track, it scrolls into view at once (unanimated, so the flyout anchors where it stops) and the flyout opens on the
    /// next dispatcher turn, outside the layout pass. A group gone meanwhile drops it.
    /// </summary>
    private void OpenPendingGroupFlyout()
    {
        if (_pendingGroupFlyout is not { } id || _pressHeld)
            return;
        if (!_chips.TryGetValue(id, out GroupChipView? chip))
        {
            if (_model?.Groups.Any(group => group.Id == id) != true)
                _pendingGroupFlyout = null;
            return;
        }

        if (!IsPlaced(chip) || chip.Visibility != Visibility.Visible)
            return;
        _pendingGroupFlyout = null;
        RevealItem(chip, animate: false);
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => ShowGroupFlyout(id));
    }

    /// <summary>Raises <see cref="GeometryChanged"/> when the row's geometry differs from what it last reported: its
    /// layout, scroll, lift, width, place in the window or the selected tab's shown rect.</summary>
    private void RaiseGeometryChanged()
    {
        if (_tripped)
            return;
        Point origin = default;
        if (XamlRoot is not null)
            origin = TransformToVisual(null).TransformPoint(default);
        var geometry = (_layoutVersion, _offset, _lift, _arrangedWidth, origin, SelectedTabRect());
        if (_reported == geometry)
            return;
        _reported = geometry;
        _lastMutation = "TabStrip.GeometryChanged";
        GeometryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// The layout-loop tripwire. Counts a layout pass or a mutation from <paramref name="source"/> in this dispatcher
    /// turn; past <see cref="MaxPassesPerTurn"/> it writes one Recovered line naming the last mutation and returns
    /// false: the caller then leaves the tree as it is until the next turn (or frame), so a loop left somewhere is named
    /// in crash.log instead of ending the app in a LayoutCycleException.
    /// </summary>
    internal bool CountPass(string source)
    {
        if (!_passResetQueued)
            _passResetQueued = DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Normal, ResetPasses);
        _passes++;
        if (!source.EndsWith("ArrangeOverride", StringComparison.Ordinal))
            _lastMutation = source;
        if (_tripped)
            return false;
        if (_passes <= MaxPassesPerTurn)
            return true;
        _tripped = true;
        CrashLog.Recovered(
            $"TabStrip layout loop (more than {MaxPassesPerTurn.ToString(CultureInfo.InvariantCulture)} passes in one "
            + $"turn; last mutation {_lastMutation}; row left as it was until the next frame)",
            new InvalidOperationException($"Layout loop at {source}"));
        return false;
    }

    /// <summary>A new dispatcher turn or frame: the tripwire counts from zero; a tripped strip lays out once more.</summary>
    private void ResetPasses()
    {
        _passResetQueued = false;
        _passes = 0;
        if (!_tripped)
            return;
        _tripped = false;
        _reported = null;
        InvalidateArrange();
    }

    /// <summary>
    /// Tells UI Automation clients that the row's items changed (a tab, chip or worktree head came, went, showed, hid or
    /// moved), once laid out: the strip lists its own children (<see cref="AutomationOrder"/>), so the framework does not
    /// see them change, and a client that keeps the tree it read (vmpal_tree, Narrator) would miss a new worktree head.
    /// </summary>
    private void NotifyAutomationChildren()
    {
        if (!AutomationPeer.ListenerExists(AutomationEvents.StructureChanged)
            || FrameworkElementAutomationPeer.FromElement(this) is not { } peer)
        {
            _automationChildren = null;
            return;
        }

        List<FrameworkElement> children = [.. AutomationOrder().Where(element => element.Visibility == Visibility.Visible)];
        if (_automationChildren is { } shown && shown.SequenceEqual(children))
            return;
        _automationChildren = children;
        try
        {
            peer.RaiseStructureChangedEvent(AutomationStructureChangeType.ChildrenInvalidated, null);
        }
        catch (Exception error)
        {
            CrashLog.Recovered("UI Automation structure event (not raised)", error);
        }
    }

    // Drag (TabDragController drives it; design §3.10).

    /// <summary>The row as drawn: with a dragged unit at its target, else at rest.</summary>
    private TabTrackLayout? Shown => _dragLayout ?? _layout;

    /// <summary>The canvas a pressed element's pointer is measured in, the one it stands on: the track's content (so a
    /// scroll moves the pointer's position with the tabs) or the pinned well; null for the popped-out archived tab.</summary>
    internal UIElement? SpaceOf(FrameworkElement element) =>
        ReferenceEquals(HomeOf(element), _trackItems) ? _content
        : ReferenceEquals(HomeOf(element), _wellItems) ? _well
        : null;

    /// <summary>A position in <paramref name="space"/> (<see cref="SpaceOf"/>) in the spans' space of
    /// <see cref="Layout"/>.</summary>
    internal double SpansX(UIElement space, double x) =>
        ReferenceEquals(space, _content) && _layout is { } layout ? layout.SpansX(x) : x;

    /// <summary>The popped-out archived tab: a press selects it alone, it never drags.</summary>
    internal bool IsPopped(Guid id) => _model?.ArchivedOut?.Id == id;

    internal void SetPressHeld(bool held)
    {
        _pressHeld = held;
        PressHeldChanged?.Invoke(this, held);
        if (!held && _revealPending)
            InvalidateArrange();
    }

    /// <summary>Draws <paramref name="drag"/>: the row with its unit at its target, the unit's elements lifted under the
    /// pointer, and the drop indicator.</summary>
    internal void ShowDrag(TabDrag drag)
    {
        if (_layout is not { } layout)
            return;
        bool moved = _dragShown is not { } old || old.Index != drag.Index || old.Group != drag.Group
            || old.Unit != drag.Unit || _snapping;
        _snapping = false;
        _dragShown = drag;
        LayOutDrag(layout, drag);
        if (moved)
        {
            _layoutVersion++;
            PlaceItems(_dragLayout!, layout.Popped);
            Lift(layout, drag);
        }

        ApplyLift();
        Redraw();
    }

    /// <summary>A drop that changes nothing, or out of the window: the row goes back to rest and the unit's elements
    /// ease back into place.</summary>
    internal void SnapBack(TabDrag drag)
    {
        _dragShown = null;
        _dragLayout = null;
        _layoutVersion++;
        if (_layout is { } layout)
            PlaceItems(layout, layout.Popped);
        // Lifted by the drag's translation from its place at rest, where the pointer let it go.
        _snapFrom = drag.Translation;
        if (!_uiSettings.AnimationsEnabled || Math.Abs(_snapFrom) < 0.5)
        {
            _snapping = false;
            ClearLift();
        }
        else
        {
            _lift = _snapFrom;
            ApplyLift();
            _snapStart = _clock.Elapsed;
            _snapping = true;
            HookRendering();
        }

        Redraw();
    }

    /// <summary>Ends a drag without drawing it back: the model changes next (a drop, or a change under the drag), and
    /// the next layout places the row.</summary>
    internal void EndDrag()
    {
        _dragShown = null;
        _dragLayout = null;
        _snapping = false;
        _layoutVersion++;
        ClearLift();
        UpdateIndicator();
        InvalidateMeasure();
    }

    /// <summary>The row with <paramref name="drag"/>'s unit at its target (TabGroupSpans.DragTarget's drawing), and how
    /// far its elements stand from there: its anchor (a group's header, else its first tab) where the pointer holds it.</summary>
    private void LayOutDrag(TabTrackLayout layout, TabDrag drag)
    {
        TabGroupSpans.Positions target = layout.Spans.PositionsFor(
            TabGroupSpans.Moved(layout.Tabs.Count, drag.Range, drag.Index), drag.Range, drag.Group);
        _dragLayout = layout.WithPositions(target);
        _lift = Anchor(layout.Positions, drag) + drag.Translation - Anchor(target, drag);
    }

    private static double Anchor(TabGroupSpans.Positions positions, TabDrag drag) =>
        drag.Unit is TabArrangement.Unit.Group group
            ? positions.Headers.GetValueOrDefault(group.Id)
            : positions.Tabs.GetValueOrDefault(drag.Range.First);

    /// <summary>The dragged unit's elements: its tabs, a group's chip, and the heads of the boxes it moves whole.</summary>
    private void Lift(TabTrackLayout layout, TabDrag drag)
    {
        ClearLift();
        _liftedRange = drag.Range;
        for (int index = drag.Range.First; index <= drag.Range.Last && index < layout.Tabs.Count; index++)
        {
            if (_tabViews.TryGetValue(layout.Tabs[index].Id, out TabItemView? view))
                _lifted.Add(view);
        }

        if (drag.Unit is TabArrangement.Unit.Group group && _chips.TryGetValue(group.Id, out GroupChipView? chip))
            _lifted.Add(chip);
        if (drag.Unit is TabArrangement.Unit.Tab)
            return;
        foreach (WorktreeBox box in layout.Boxes.Where(box => box.First >= drag.Range.First && box.First <= drag.Range.Last))
        {
            if (_heads.TryGetValue(box.Key, out WorktreeHeadView? head))
                _lifted.Add(head);
        }
    }

    private void ApplyLift()
    {
        foreach (FrameworkElement element in _lifted)
        {
            if (element.RenderTransform is not TranslateTransform shift)
            {
                shift = new TranslateTransform();
                element.RenderTransform = shift;
            }

            shift.X = _lift;
            Canvas.SetZIndex(element, 1);
        }
    }

    private void ClearLift()
    {
        foreach (FrameworkElement element in _lifted)
        {
            if (element.RenderTransform is TranslateTransform shift)
                shift.X = 0;
            Canvas.SetZIndex(element, 0);
        }

        _lifted.Clear();
        _liftedRange = null;
        _lift = 0;
    }

    private void Redraw()
    {
        UpdateFades();
        UpdateDecorations();
        UpdateIndicator();
        RaiseGeometryChanged();
    }

    /// <summary>
    /// The drop indicator (design §3.10, a Windows addition): a 2 epx insertion bar in the gap before the unit's target,
    /// in the brand blue, or in the group's color when the unit would drop in a group (a dragged group excepted), with a
    /// dashed outline of that group's extent.
    /// </summary>
    private void UpdateIndicator()
    {
        if (_inLayout)
        {
            ScheduleGeometryChanged();
            return;
        }

        // Rebuilt only when the drag's target or the layout changed (not as the pointer moves along).
        (int, TabDrag?) key = (_layoutVersion, _dragShown is { } shown && _dragLayout is not null
            ? shown with { Translation = 0 }
            : null);
        if (_indicated == key || !CountPass("TabStrip.UpdateIndicator"))
            return;
        _indicated = key;
        _trackIndicator.Children.Clear();
        _wellIndicator.Children.Clear();
        if (_dragShown is not { } drag || _dragLayout is not { } layout)
            return;

        TabGroup? joined = drag.Unit is TabArrangement.Unit.Group || drag.Group is not { } id
            ? null
            : layout.Groups.FirstOrDefault(group => group.Id == id);
        Brush brush = joined is null
            ? PaletteResources.Brush("BrandAccentBrush")
            : TabColors.Brush(TabColors.Group(joined.Group.ColorIndex));
        bool pinned = drag.Range.First < layout.PinnedCount;
        double bar = Anchor(layout.Positions, drag) - layout.Spans.Gap / 2;
        Canvas canvas = pinned ? _wellIndicator : _trackIndicator;
        var line = new Rectangle
        {
            Width = DropBarWidth,
            Height = Math.Max(0, _m.Height - _m.BottomInset - 2 * DropBarInset),
            Fill = brush,
            IsHitTestVisible = false,
        };
        Canvas.SetLeft(line, (pinned ? bar : layout.ContentX(bar)) - DropBarWidth / 2);
        Canvas.SetTop(line, DropBarInset);
        canvas.Children.Add(line);

        if (joined is null || layout.GroupExtent(joined) is not { } extent)
            return;
        double thickness = 1;
        var outline = new Rect(extent.Start + thickness / 2, thickness / 2,
            Math.Max(0, extent.End - extent.Start - thickness), Math.Max(0, _m.Height - _m.BottomInset - thickness));
        _trackIndicator.Children.Add(new Path
        {
            Data = SheetTabShape.RoundedRect(outline, _m.Radius),
            Stroke = brush,
            StrokeThickness = thickness,
            StrokeDashArray = new DoubleCollection
            {
                PaletteResources.Double("ArchiveDashOn") / thickness,
                PaletteResources.Double("ArchiveDashOff") / thickness,
            },
            IsHitTestVisible = false,
        });
    }

    // Drawing: the shapes behind and around the tabs, rebuilt when the layout or the shown selection moves.

    private void UpdateDecorations()
    {
        if (_inLayout)
        {
            ScheduleGeometryChanged();
            return;
        }

        if (Shown is not { } layout || _model is null)
            return;
        // The selected shape as the sheet joins it: none while the tab is hidden or cut, so its hole and outline go too.
        // In each section's coordinates, only where it reaches that section (mid-slide it may cross them); a track
        // tab's stays put while the track scrolls, so scrolling rebuilds nothing.
        Rect? shown = SelectedTabRect();
        Rect? inLead = Within(shown, 0, _leadWidth, 0);
        Rect? inWell = Within(shown, _wellX, _wellX + (layout.PinnedCount > 0 ? layout.WellWidth : 0), _wellX);
        Rect? inTrack = Within(shown, _trackX, _trackX + _trackWidth, _trackX - _offset);
        var key = (_layoutVersion, inLead, inWell, inTrack, _selectedId, _sliding);
        if (_decorated == key || !CountPass("TabStrip.UpdateDecorations"))
            return;
        _decorated = key;

        _leadBack.Children.Clear();
        _leadOverlay.Children.Clear();
        _wellBack.Children.Clear();
        _trackBack.Children.Clear();
        _trackLines.Children.Clear();
        _trackOverlay.Children.Clear();

        double height = _m.Height;

        // The pinned well: black 0.18 with its 1 epx inner edge, the selected pinned tab cut out.
        if (layout.PinnedCount > 0)
        {
            var well = new Rect(0, 0, layout.WellWidth, height);
            AddFill(_wellBack, SheetTabShape.Box(well, _m.Radius, false, inWell), "PinnedWellFillColor");
            AddFill(_wellBack, SheetTabShape.Box(well, _m.Radius, true, inWell), "PinnedWellEdgeColor");
        }

        // Worktree boxes: a capsule 1.5 in from their first and last tab, 4.5 above the row's bottom; in a manual group
        // its edge takes the group color.
        double groupEdge = PaletteResources.Double("WorktreeBoxGroupEdgeOpacity");
        foreach (WorktreeBox box in layout.Boxes)
        {
            if (layout.BoxSpan(box) is not { } span)
                continue;
            bool pinned = box.First < layout.PinnedCount;
            var rect = new Rect(span.Start + _m.BoxInset, 0,
                Math.Max(0, span.End - span.Start - 2 * _m.BoxInset), height - _m.BottomInset);
            Rect? hole = pinned ? inWell : inTrack;
            Canvas layer = pinned ? _wellBack : _trackBack;
            AddFill(layer, SheetTabShape.Box(rect, height, false, hole), "WorktreeBoxFillColor");
            Brush edge = !pinned && layout.Spans.GroupAt(box.First) is { } group
                ? TabColors.Brush(TabColors.Group(group.Group.ColorIndex), groupEdge)
                : TabColors.Brush(PaletteResources.Color("WorktreeBoxBorderColor"));
            Add(layer, SheetTabShape.Box(rect, height, true, hole), edge);
        }

        // Manual groups: the underline from the chip to the last tab, open under the selected tab (flares included);
        // the selected grouped tab's outline in the group color.
        int? selectedIndex = SelectedIndex();
        foreach (TabGroup group in layout.Groups.Where(group => !group.Group.Collapsed))
        {
            if (layout.GroupExtent(group) is not { } extent)
                continue;
            Brush color = TabColors.Brush(TabColors.Group(group.Group.ColorIndex));
            Add(_trackLines, Line(extent.Start, extent.End, _m.GroupLine, inTrack), color);
            if (inTrack is { } tab && selectedIndex is { } index && group.Contains(index) && layout.InTrack(index))
            {
                _trackOverlay.Children.Add(new Path
                {
                    Data = SheetTabShape.Outline(tab, _m.Outline),
                    Stroke = color,
                    StrokeThickness = _m.Outline,
                    IsHitTestVisible = false,
                });
            }
        }

        // The archive: its line from the button to the popped-out tab (open under it while selected), and the tab's
        // dashed orange outline (design §3.7).
        if (layout.Popped is { } popped && _archiveShown)
        {
            Brush orange = TabColors.Brush(TabColors.Archive);
            double thickness = _m.Outline;
            var tabRect = new Rect(_poppedX, 0, _m.ArchivedWidth, height);
            bool selected = layout.Tabs[popped].Id == _selectedId;
            Add(_leadBack, Line(_archiveX, tabRect.X + tabRect.Width, thickness, inLead), orange);
            Geometry outline = selected && !_sliding
                ? SheetTabShape.Outline(tabRect, thickness)
                : SheetTabShape.RoundedRect(
                    new Rect(tabRect.X + thickness / 2, thickness / 2, tabRect.Width - thickness,
                        height - _m.BottomInset - thickness),
                    height);
            _leadOverlay.Children.Add(new Path
            {
                Data = outline,
                Stroke = orange,
                StrokeThickness = thickness,
                StrokeDashArray = new DoubleCollection
                {
                    PaletteResources.Double("ArchiveDashOn") / thickness,
                    PaletteResources.Double("ArchiveDashOff") / thickness,
                },
                IsHitTestVisible = false,
            });
        }
    }

    /// <summary><paramref name="shape"/> moved into a section's coordinates (its origin at <paramref name="origin"/>
    /// in the strip), when it reaches the section's strip range <paramref name="left"/>..<paramref name="right"/>
    /// (flares included); else null.</summary>
    private Rect? Within(Rect? shape, double left, double right, double origin)
    {
        if (shape is not { } r || right <= left || r.X + r.Width + _m.Flare <= left || r.X - _m.Flare >= right)
            return null;
        return new Rect(r.X - origin, r.Y, r.Width, r.Height);
    }

    /// <summary>A line along the row's bottom from <paramref name="start"/> to <paramref name="end"/>, open where the
    /// selected tab's shape (flares included) stands.</summary>
    private GeometryGroup Line(double start, double end, double thickness, Rect? opening)
    {
        double top = _m.Height - thickness;
        var line = new GeometryGroup();
        void Segment(double from, double to)
        {
            if (to > from)
                line.Children.Add(new RectangleGeometry { Rect = new Rect(from, top, to - from, thickness) });
        }

        if (opening is not { } cut || cut.X + cut.Width + _m.Flare <= start || cut.X - _m.Flare >= end)
        {
            Segment(start, end);
            return line;
        }

        Segment(start, Math.Min(end, cut.X - _m.Flare));
        Segment(Math.Max(start, cut.X + cut.Width + _m.Flare), end);
        return line;
    }

    private static void AddFill(Canvas layer, Geometry? geometry, string colorKey) =>
        Add(layer, geometry, TabColors.Brush(PaletteResources.Color(colorKey)));

    private static void Add(Canvas layer, Geometry? geometry, Brush fill)
    {
        if (geometry is null)
            return;
        layer.Children.Add(new Path { Data = geometry, Fill = fill, IsHitTestVisible = false });
    }

    // Elements.

    /// <summary>The item canvas a tab, chip or head stands on (<see cref="MoveTo"/>), null while it stands on none.
    /// </summary>
    internal Canvas? HomeOf(FrameworkElement element) => _homes.GetValueOrDefault(element);

    /// <summary>A tab, chip or head stands on its canvas; any other element of the row (a button) always does.</summary>
    internal bool IsPlaced(FrameworkElement element) =>
        element is not (TabItemView or GroupChipView or WorktreeHeadView) || _homes.ContainsKey(element);

    /// <summary>Puts <paramref name="element"/> on <paramref name="target"/>, off any canvas that holds it before. A
    /// failure is logged and the sync goes on with the next item; the element is tried again at the next sync.</summary>
    private void MoveTo(FrameworkElement element, Canvas target)
    {
        if (_homes.TryGetValue(element, out Canvas? home) && ReferenceEquals(home, target))
            return;
        try
        {
            Detach(element);
            target.Children.Add(element);
            _homes[element] = target;
        }
        catch (Exception error)
        {
            CrashLog.Recovered(
                $"TabStrip.MoveTo {element.GetType().Name} from {CanvasName(home)} to {CanvasName(target)} (Parent "
                + $"{element.Parent?.GetType().Name ?? "none"}, visual parent "
                + $"{VisualTreeHelper.GetParent(element)?.GetType().Name ?? "none"}; item left off the row)", error);
            // A failed Add must not leave an entry the next layout trips over.
            try
            {
                RemoveFrom(target, element);
            }
            catch (Exception cleanup)
            {
                CrashLog.Recovered($"TabStrip.MoveTo cleanup on {CanvasName(target)}", cleanup);
            }
        }
    }

    /// <summary>Takes <paramref name="element"/> off every canvas that holds it: its home, the other item canvases and
    /// its visual parent. FrameworkElement.Parent is not used: on Windows it seems not to report the canvas holding a
    /// tab (a sync added a tab again to the canvas that held it).</summary>
    private void Detach(FrameworkElement element)
    {
        _homes.Remove(element);
        foreach (Canvas canvas in (Canvas[])[_leadItems, _wellItems, _trackItems])
            RemoveFrom(canvas, element);
        if (VisualTreeHelper.GetParent(element) is Panel parent)
            RemoveFrom(parent, element);
    }

    /// <summary>Removes each entry of <paramref name="panel"/>'s children that is <paramref name="element"/>, compared by
    /// reference.</summary>
    private static void RemoveFrom(Panel panel, UIElement element)
    {
        UIElementCollection children = panel.Children;
        for (int index = children.Count - 1; index >= 0; index--)
        {
            if (ReferenceEquals(children[index], element))
                children.RemoveAt(index);
        }
    }

    private string CanvasName(Canvas? canvas) =>
        canvas is null ? "none"
        : ReferenceEquals(canvas, _leadItems) ? "lead"
        : ReferenceEquals(canvas, _wellItems) ? "well"
        : ReferenceEquals(canvas, _trackItems) ? "track"
        : canvas.GetType().Name;

    private void RemoveStale<TKey, TView>(Dictionary<TKey, TView> views, IReadOnlySet<TKey> live)
        where TKey : notnull
        where TView : FrameworkElement
    {
        foreach (TKey key in views.Keys.Where(key => !live.Contains(key)).ToList())
        {
            try
            {
                Detach(views[key]);
            }
            catch (Exception error)
            {
                CrashLog.Recovered($"TabStrip.RemoveStale {typeof(TView).Name} (left on the row)", error);
            }

            views.Remove(key);
        }
    }

    /// <summary>A 28 epx rounded square in the color at 0.38 with a white glyph (and an optional count badge).</summary>
    internal static Button StowButton(string glyph, Windows.UI.Color color, TextBlock? badge)
    {
        var content = new Grid();
        content.Children.Add(new FontIcon
        {
            Glyph = glyph,
            FontSize = PaletteResources.Double("StowButtonIconSize"),
            Foreground = TabColors.Brush(PaletteResources.Color("GraphBadgeTextColor")),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (badge is not null)
            content.Children.Add(badge);

        var button = new Button
        {
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = (CornerRadius)Application.Current.Resources["SquareButtonCornerRadius"],
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
            Content = content,
            Visibility = Visibility.Collapsed,
        };
        Brush fill = TabColors.Fill(color);
        StyleButton(button, fill, fill, fill);
        return button;
    }

    /// <summary>A 24 epx round button of the row's end (scroll arrows, New Tab, All Tabs): white 0.06, hover 0.10,
    /// pressed 0.20.</summary>
    private Button RowButton(string glyph, string name)
    {
        var button = new Button
        {
            Width = _m.ButtonSize,
            Height = _m.ButtonSize,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(_m.ButtonSize / 2),
            Content = new FontIcon { Glyph = glyph, FontSize = PaletteResources.Double("TabRowButtonIconSize") },
        };
        StyleButton(button, PaletteResources.Brush("TabFillBrush"), PaletteResources.Brush("HoverFillBrush"),
            PaletteResources.Brush("PressedFillBrush"));
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        return button;
    }

    // Names (design §3.12) and texts.

    /// <summary>A tab's UI Automation name: its title, then "pinned", "archived", "in group &lt;name&gt;" and
    /// "worktree of &lt;repo&gt;" as they apply. <paramref name="title"/> is the tab's sanitized title.</summary>
    internal static string TabName(string title, WindowTabs.Tab tab, TabGroup? group, WorktreeBox? box)
    {
        var parts = new List<string> { title };
        if (tab.Pinned)
            parts.Add("pinned");
        if (tab.Archived)
            parts.Add("archived");
        if (group is not null)
        {
            string name = GroupName(group);
            parts.Add(name.Length == 0 ? "in an unnamed group" : $"in group {name}");
        }
        if (box is not null)
            parts.Add($"worktree of {RepoName(box.Key)}");
        return string.Join(", ", parts);
    }

    /// <summary>The tooltip: the repo path (the title for a Welcome tab); a pinned tab's leads with its title. Each part
    /// is sanitized on its own, so the line break between them stays.</summary>
    internal static string TabToolTip(string title, WindowTabs.Tab tab)
    {
        string path = tab.Path is null ? title : DisplayText.Sanitize(tab.Path);
        return tab.Pinned && !string.Equals(path, title, StringComparison.Ordinal) ? $"{title}\n{path}" : path;
    }

    internal static TabGlyph GlyphOf(WindowTabs.Tab tab) =>
        tab.IsMissing ? TabGlyph.Missing : tab.Path is null ? TabGlyph.Welcome : TabGlyph.Book;

    /// <summary>The folder a worktree box's repository lives in: its common dir's parent for a <c>.git</c> dir, else
    /// the common dir's own name without <c>.git</c> (a bare repository), sanitized for display.</summary>
    internal static string RepoName(string key)
    {
        string last = PathFlavor.Host.LastComponent(key);
        if (string.Equals(last, ".git", StringComparison.OrdinalIgnoreCase))
            return DisplayText.Sanitize(PathFlavor.Host.LastComponent(PathFlavor.Host.Parent(key)));
        return DisplayText.Sanitize(last.EndsWith(".git", StringComparison.OrdinalIgnoreCase) ? last[..^4] : last);
    }

    /// <summary>A group's name as shown: sanitized, empty for an unnamed group.</summary>
    internal static string GroupName(TabGroup group) => DisplayText.Sanitize(group.Group.Name);

    /// <summary>A chip's text: the name; collapsed, the tab count appended ("Docs · 3", "2" for an unnamed group).</summary>
    internal static string ChipText(TabGroup group)
    {
        string name = GroupName(group);
        if (!group.Group.Collapsed)
            return name;
        string count = group.Count.ToString(CultureInfo.InvariantCulture);
        return name.Length == 0 ? count : $"{name} · {count}";
    }

    /// <summary>The chip's UI Automation name (TabGroup.accessibilityLabel): "Group Docs, 3 tabs", "Group, 2 tabs".</summary>
    internal static string ChipName(TabGroup group)
    {
        string tabs = group.Count == 1 ? "1 tab" : $"{group.Count.ToString(CultureInfo.InvariantCulture)} tabs";
        string name = GroupName(group);
        return name.Length == 0 ? $"Group, {tabs}" : $"Group {name}, {tabs}";
    }
}

/// <summary>The strip in UI Automation: a Tab control whose children come in TabArrangement order
/// (<see cref="TabStrip.AutomationOrder"/>), not in drawing order.</summary>
internal sealed partial class TabStripAutomationPeer(TabStrip owner) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Tab;

    protected override string GetClassNameCore() => nameof(TabStrip);

    protected override bool IsControlElementCore() => true;

    protected override IList<AutomationPeer> GetChildrenCore()
    {
        var peers = new List<AutomationPeer>();
        foreach (FrameworkElement element in ((TabStrip)Owner).AutomationOrder())
        {
            if (element.Visibility == Visibility.Visible && CreatePeerForElement(element) is { } peer)
                peers.Add(peer);
        }

        return peers;
    }
}

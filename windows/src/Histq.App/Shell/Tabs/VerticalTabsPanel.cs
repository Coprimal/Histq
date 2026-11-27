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
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace Histq.App.Shell.Tabs;

/// <summary>Where the window's tabs show: the strip in the title bar, or the vertical panel left of the sheet.</summary>
internal enum TabPosition
{
    Top,
    Left,
}

/// <summary>
/// The tab position (Settings › Appearance › Tab position, <see cref="PrefKey.TabPosition"/>, ported from TabPosition in
/// App/Window/VerticalTabsPanel.swift at 6fa6d40): "left" or "top"; anything else reads as top. In QA builds
/// <c>-HistqTabPosition left|top</c> (Debug/QaFlags.cs) wins over the preference at startup and is never
/// written to it; a View › Move Tabs switch writes the preference and wins from then on
/// (<see cref="WindowManager.CurrentTabPosition"/>).
/// </summary>
internal static class TabPositions
{
    /// <summary>The position for a stored preference value (the launch flag's, in a QA build that has it).</summary>
    public static TabPosition Resolved(string? stored) => LaunchOverride ?? Parse(stored) ?? TabPosition.Top;

    /// <summary>The position the preferences hold now.</summary>
    public static TabPosition Current(Preferences preferences) =>
        Resolved(preferences.Get<string>(PrefKey.TabPosition));

    private static TabPosition? LaunchOverride =>
#if HISTQ_QA
        Parse(QaFlags.TabPositionFlag);
#else
        null;
#endif

    private static TabPosition? Parse(string? value) => value switch
    {
        "top" => TabPosition.Top,
        "left" => TabPosition.Left,
        _ => null,
    };
}

/// <summary>
/// The vertical tabs (design header-and-tab-row.md §4, ported from VerticalTabsPanel, VerticalTabList,
/// VerticalArchiveFooter, VerticalTabGroupHeader and VerticalTabRow in App/Window/VerticalTabsPanel.swift at 6fa6d40):
/// a 150 epx panel left of the page sheet, below the title bar. Top to bottom: the pinned tabs as a grid of icons in the
/// pinned well (<see cref="VerticalPinnedGrid"/>); the other tabs as rows (28 epx, 6 apart), each manual group's header
/// row (its color at 0.38, its name, the tab count when collapsed) before its rows, which sit 12 epx in, right of a
/// 2 epx rail in the group's color; each worktree box as a rounded outline round its rows, headed by a line with the
/// branch glyph and the repository's folder name (a Windows addition), its edge in the group's color at 0.45 inside a
/// manual group; then, above the footer, the popped-out archived tab (a dashed orange outline, the archive's line down
/// to the archive button), and the footer: the closed groups button with its count, the archive button, New Tab and
/// All Tabs. The selected row has no fill of its own: it is part of the sheet's figure (<see cref="SelectedRowRect"/>,
/// <see cref="SheetTabShape.Create"/> joined on the left), cut out of a box it stands in.
/// <para>
/// Every size here is fixed (the panel's width, every row's and header's height), so <see cref="Sync"/> places every
/// element and draws every outline at once, outside any layout pass; layout only stretches the list's viewport. The
/// list scrolls by its own offset (a wheel, the selection brought into view), so the sheet's joined row follows the
/// rows in the same frame (<see cref="GeometryChanged"/>). Elements are kept per tab, group and box across syncs, each
/// on the canvas recorded for it. UI Automation: a Tab control named "Vertical tabs" whose children come in tab order
/// (the pinned grid, the list's headers, worktree heads and rows, the popped-out row, the footer buttons).
/// </para>
/// <para>
/// Interactions (VerticalTabsPanel.swift:237, 314-430, 562, 767), through the strip's <see cref="TabDragController"/>
/// along the vertical axis: a row press selects at once (Shift / Ctrl pick it into the multi-selection); past 5 epx down
/// or up it drags the row (a box's row inside its box until the pointer leaves the box, then the whole box), a worktree
/// head drags its box and a group header its group, to the place <see cref="TabGroupSpans.DragTarget"/> gives: the list
/// is drawn with the unit at its target (<see cref="VerticalTabLayout.WithPositions"/>), the unit's elements under the
/// pointer; the drop moves it through <see cref="WindowTabs.MoveUnit"/>, out of the window a lone tab moves to the
/// Histq window under the pointer, anything else snaps back. A header released before the threshold collapses or
/// expands its group; its right click opens the group flyout. A pinned cell and the popped-out row are pressed alone
/// and never drag. Rows, cells and heads have the shared tab menu (<see cref="TabContextMenu"/>, "Close Tabs Below");
/// the footer's buttons open the row's flyouts to the trailing side.
/// </para>
/// </summary>
public sealed partial class VerticalTabsPanel : Grid, ITabDragHost
{
    /// <summary>A wheel notch (120) scrolls the list this far.</summary>
    private const double WheelStep = 48;

    private readonly double _width;
    private readonly double _rowHeight;
    private readonly double _rowInset;
    private readonly double _indent;
    private readonly double _rail;
    private readonly double _headerHeight;
    private readonly double _headerTrailing;
    private readonly double _headHeight;
    private readonly double _boxRadius;
    private readonly double _boxOutset;
    private readonly double _boxTrailing;
    private readonly double _hoverTrailing;
    private readonly double _panelTrailing;
    private readonly double _panelBottom;
    private readonly double _flare;
    private readonly double _gap;
    private readonly double _stowGap;
    private readonly double _square;
    private readonly double _button;
    private readonly double _outline;
    private readonly VerticalTabLayout.Metrics _metrics;

    // The list: a clipped viewport whose content moves by the scroll offset; boxes and rails behind the items.
    private readonly Canvas _viewport = new();
    private readonly Canvas _content = new();
    private readonly Canvas _back = new();
    private readonly Canvas _items = new();
    private readonly TranslateTransform _scroll = new();
    private readonly RectangleGeometry _viewportClip = new();
    private readonly VerticalPinnedGrid _grid;

    // The bottom: the popped-out row and the footer buttons, the archive's line behind, the dashed outline over them.
    private readonly Canvas _bottom = new();
    private readonly Canvas _bottomBack = new();
    private readonly Canvas _bottomItems = new();
    private readonly Canvas _bottomOverlay = new();
    private readonly Button _closedGroups;
    private readonly TextBlock _closedCount;
    private readonly Button _archive;
    private readonly Button _newTab;
    private readonly Button _allTabs;

    private readonly Dictionary<Guid, VerticalTabRow> _rows = [];
    private readonly Dictionary<Guid, VerticalGroupHeader> _headers = [];
    private readonly Dictionary<string, VerticalWorktreeHead> _heads = new(StringComparer.Ordinal);

    /// <summary>The canvas each row, header and head was put on (<see cref="MoveTo"/>), kept here, never read from
    /// FrameworkElement.Parent.</summary>
    private readonly Dictionary<FrameworkElement, Canvas> _homes = new(ReferenceEqualityComparer.Instance);

    /// <summary>The panel's items in tab order, as UI Automation lists them (shown ones only).</summary>
    private readonly List<FrameworkElement> _order = [];

    private readonly TabDragController _drag;

    // The footer's flyouts and the group flyout, made on first use.
    private GroupFlyout? _groupFlyout;
    private ArchiveFlyout? _archiveFlyout;
    private ClosedGroupsFlyout? _closedFlyout;
    private AllTabsFlyout? _allTabsFlyout;

    private MainWindow? _window;
    private WindowTabs? _model;
    private Guid? _selectedId;
    private bool _revealPending = true;

    /// <summary>A press on a row, head or header is held: the selection it made is revealed once it is let go.</summary>
    private bool _pressHeld;

    // The last sync's snapshot, which the list is placed from: the tabs, groups and list boxes, the layout at rest, and
    // where the rows start in the list's content (below the pinned grid).
    private IReadOnlyList<WindowTabs.Tab> _tabs = [];
    private IReadOnlyList<TabGroup> _groups = [];
    private IReadOnlyList<WorktreeBox> _listBoxes = [];
    private VerticalTabLayout? _layout;
    private double _rowsTop;

    /// <summary>The unit dragged now (drawn at its target, its elements lifted by <see cref="_lift"/> to follow the
    /// pointer); null at rest.</summary>
    private TabDrag? _dragShown;
    private double _lift;

    /// <summary>The selected row in the list's content (an unscrolled list), or the popped-out row in the bottom's
    /// coordinates; null when the selection is a pinned cell, hidden, or none.</summary>
    private Rect? _selectedInList;
    private Rect? _selectedInBottom;

    private double _contentHeight;
    private double _bottomHeight;
    private double _offset;

    /// <summary>The automation children last announced (<see cref="NotifyAutomationChildren"/>).</summary>
    private List<FrameworkElement>? _automationChildren;

    public VerticalTabsPanel()
    {
        _width = PaletteResources.Double("VerticalTabsWidth");
        _rowHeight = PaletteResources.Double("VerticalRowHeight");
        _rowInset = PaletteResources.Double("VerticalRowInset");
        _indent = PaletteResources.Double("VerticalGroupIndent");
        _rail = PaletteResources.Double("VerticalRailThickness");
        _headerHeight = PaletteResources.Double("VerticalHeaderHeight");
        _headerTrailing = PaletteResources.Double("VerticalHeaderTrailing");
        _headHeight = PaletteResources.Double("VerticalHeadHeight");
        _boxRadius = PaletteResources.Double("VerticalBoxRadius");
        _boxOutset = PaletteResources.Double("VerticalBoxOutset");
        _boxTrailing = PaletteResources.Double("VerticalBoxTrailing");
        _hoverTrailing = PaletteResources.Double("VerticalHoverTrailing");
        _panelTrailing = PaletteResources.Double("VerticalPanelTrailing");
        _panelBottom = PaletteResources.Double("VerticalPanelBottom");
        _flare = PaletteResources.Double("TabFlare");
        _gap = PaletteResources.Double("TabGap");
        _stowGap = PaletteResources.Double("StowButtonGap");
        _square = PaletteResources.Double("SquareButtonSize");
        _button = PaletteResources.Double("TabRowButtonSize");
        _outline = PaletteResources.Double("TabOutlineThickness");
        _metrics = new VerticalTabLayout.Metrics(
            _rowHeight, PaletteResources.Double("VerticalRowSpacing"), _headerHeight, _headHeight);

        Width = _width;
        // Above the first item: the sheet's corner, so the first selected row's upper flare meets the sheet's straight
        // left edge.
        Padding = new Thickness(0, PaletteResources.Double("SheetRadius"), 0, 0);
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _drag = new TabDragController(this);
        _grid = new VerticalPinnedGrid(this);
        _content.RenderTransform = _scroll;
        _content.Children.Add(_back);
        _content.Children.Add(_items);
        _items.Children.Add(_grid);
        _viewport.Children.Add(_content);
        _viewport.Clip = _viewportClip;
        // A background, even transparent, so a wheel over the gaps between rows scrolls too.
        _viewport.Background = new SolidColorBrush(Colors.Transparent);
        _viewport.PointerWheelChanged += OnWheel;
        _viewport.SizeChanged += OnViewportSizeChanged;
        Children.Add(_viewport);

        _closedCount = new TextBlock
        {
            FontSize = PaletteResources.Double("CountBadgeFontSize"),
            Foreground = TabColors.Brush(PaletteResources.Color("GraphBadgeTextColor")),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 2, 0),
            IsHitTestVisible = false,
        };
        _closedGroups = TabStrip.StowButton(TabStrip.ClosedGroupsGlyph, PaletteResources.Color("GroupGreyColor"),
            _closedCount);
        _archive = TabStrip.StowButton(TabStrip.ArchiveGlyph, TabColors.Archive, null);
        _newTab = RoundButton(TabStrip.NewTabGlyph, "New Tab");
        _allTabs = RoundButton(TabStrip.AllTabsGlyph, "All Tabs");
        _newTab.Click += (_, _) => _window?.Apply(model => model.OpenTab(null));
        _closedGroups.Click += (_, _) => (_closedFlyout ??= new ClosedGroupsFlyout(this)).Open(_closedGroups);
        _archive.Click += (_, _) => (_archiveFlyout ??= new ArchiveFlyout(this)).Open(_archive);
        _allTabs.Click += (_, _) => (_allTabsFlyout ??= new AllTabsFlyout(this)).Open(_allTabs);
        _bottomItems.Children.Add(_closedGroups);
        _bottomItems.Children.Add(_archive);
        _bottomItems.Children.Add(_newTab);
        _bottomItems.Children.Add(_allTabs);
        _bottom.Children.Add(_bottomBack);
        _bottom.Children.Add(_bottomItems);
        _bottom.Children.Add(_bottomOverlay);
        _bottom.Width = _width;
        SetRow(_bottom, 1);
        Children.Add(_bottom);
        AutomationProperties.SetName(this, "Vertical tabs");
    }

    /// <summary>The list scrolled or resized: the selected row's place on the sheet's edge may have moved.</summary>
    internal event EventHandler? GeometryChanged;

    /// <summary>The window whose tabs it shows; call before the first <see cref="Sync"/>. Until the window closes, the
    /// tabs' icons are drawn again when the icon images change.</summary>
    internal void Attach(MainWindow window)
    {
        _window = window;
        CustomIconImages.Shared.Changed += OnIconImagesChanged;
        window.Closed += (_, _) => CustomIconImages.Shared.Changed -= OnIconImagesChanged;
    }

    // Actions: each goes through MainWindow.Apply, which syncs the panel again.

    /// <summary>Selects the tab at once (click-first rule).</summary>
    internal void Select(Guid id) => _window?.Apply(model => model.SelectTab(id));

    /// <summary>A mouse-down on a row (<see cref="TabPress"/>), as on the strip.</summary>
    internal void Pick(Guid id, TabPress press) => _window?.Apply(model => TabStrip.PickIn(model, id, press));

    /// <summary>A header's toggle: collapses or expands its group.</summary>
    internal void ToggleGroup(Guid id) => _window?.Apply(model => model.ToggleGroup(id));

    /// <summary>Opens group <paramref name="id"/>'s flyout at its header (a right click on it); nothing while the header
    /// is not shown.</summary>
    internal void ShowGroupFlyout(Guid id)
    {
        if (_headers.TryGetValue(id, out VerticalGroupHeader? header) && header.Visibility == Visibility.Visible
            && IsPlaced(header))
            (_groupFlyout ??= new GroupFlyout(this)).ShowFor(id, header);
    }

    /// <summary>A row, header or head stands on its canvas; any other element (a cell, a button) always does.</summary>
    internal bool IsPlaced(FrameworkElement element) =>
        element is not (VerticalTabRow or VerticalGroupHeader or VerticalWorktreeHead) || _homes.ContainsKey(element);

    /// <summary>Wires a pinned cell made by the grid: pressed alone (never dragged), middle-click close, the tab menu.</summary>
    internal void AttachCell(VerticalPinnedCell cell)
    {
        _drag.AttachTab(cell, cell.Id);
        cell.ContextRequested += (_, e) => TabContextMenu.OnContextRequested(cell, e);
    }

    /// <summary>The panel is shown again (the tab position switched to Left): its selection comes into view.</summary>
    internal void RevealOnNextSync() => _revealPending = true;

    // ITabDragHost (the menus, flyouts and TabDragController, along the vertical axis).

    MainWindow? ITabsView.Window => _window;

    WindowTabs? ITabsView.Model => _model;

    bool ITabsView.Vertical => true;

    void ITabsView.CloseTab(Guid id) => CloseTab(id);

    /// <summary>Placed by the sync that made the group: its flyout opens once that sync's layout pass has run.</summary>
    void ITabsView.ShowGroupFlyoutWhenPlaced(Guid id) =>
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => ShowGroupFlyout(id));

    /// <summary>Nothing to do: the panel has no Passthrough regions.</summary>
    void ITabsView.OnFlyoutClosed()
    {
    }

    (TabGroupSpans Spans, TabGroupSpans.Positions Positions)? ITabDragHost.DragLayout =>
        _layout is { } layout ? (layout.Spans, layout.Positions) : null;

    void ITabDragHost.Pick(Guid id, TabPress press) => Pick(id, press);

    void ITabDragHost.ToggleGroup(Guid id) => ToggleGroup(id);

    /// <summary>The popped-out row and the pinned cells (the Mac's VerticalPinnedCell and popped row presses).</summary>
    bool ITabDragHost.PressesAlone(Guid id) =>
        _model is { } model && (model.ArchivedOut?.Id == id || model.Tabs.Any(tab => tab.Id == id && tab.Pinned));

    /// <summary>The list's content (it scrolls with the rows) for a row, header or head of the list; none for the
    /// popped-out row.</summary>
    UIElement? ITabDragHost.SpaceOf(FrameworkElement element) =>
        _homes.TryGetValue(element, out Canvas? home) && ReferenceEquals(home, _items) ? _content : null;

    double ITabDragHost.SpansPosition(UIElement space, double along) =>
        ReferenceEquals(space, _content) && _layout is { } layout ? along - _rowsTop + layout.Origin : along;

    /// <summary>A press let go reveals a selection it made; after a drag, once the list is back at rest
    /// (<see cref="EndDrag"/>).</summary>
    void ITabDragHost.SetPressHeld(bool held)
    {
        _pressHeld = held;
        if (!held && _revealPending && _dragShown is null)
            Reveal();
    }

    /// <summary>Draws <paramref name="drag"/>: the list with its unit at its target, the unit's elements lifted so its
    /// anchor (a group's header, else its first row) stays under the pointer.</summary>
    void ITabDragHost.ShowDrag(TabDrag drag)
    {
        if (_layout is not { } layout)
            return;
        VerticalTabLayout target = layout.WithPositions(layout.Spans.PositionsFor(
            TabGroupSpans.Moved(_tabs.Count, drag.Range, drag.Index), drag.Range, drag.Group));
        _dragShown = drag;
        _lift = Anchor(layout, drag) + drag.Translation - Anchor(target, drag);
        PlaceList(target);
        GeometryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>A drop that changes nothing, or out of the window: the list goes back to rest at once.</summary>
    void ITabDragHost.SnapBack(TabDrag drag) => EndDrag();

    void ITabDragHost.EndDrag() => EndDrag();

    private void EndDrag()
    {
        if (_dragShown is null)
            return;
        _dragShown = null;
        _lift = 0;
        if (_layout is { } layout)
            PlaceList(layout);
        if (_revealPending && !_pressHeld)
            Reveal();
        GeometryChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Where a drag's anchor stands in <paramref name="layout"/>: a group's header, else its first row.</summary>
    private static double Anchor(VerticalTabLayout layout, TabDrag drag) =>
        drag.Unit is TabArrangement.Unit.Group group
            ? layout.Headers.GetValueOrDefault(group.Id)
            : layout.Rows.GetValueOrDefault(drag.Range.First);

    /// <summary>The tab at <paramref name="index"/> is one of the dragged unit's (it follows the pointer).</summary>
    private bool IsLifted(int index) =>
        _dragShown is { } drag && index >= drag.Range.First && index <= drag.Range.Last;

    /// <summary>The group the tab at <paramref name="index"/> is drawn in: the dragged unit's target group, else its own.</summary>
    private TabGroup? GroupAt(int index)
    {
        if (_dragShown is { } drag && IsLifted(index))
            return drag.Group is { } id ? _groups.FirstOrDefault(group => group.Id == id) : null;
        return _groups.FirstOrDefault(group => group.Contains(index));
    }

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

    /// <summary>The panel's items in tab order: the automation children.</summary>
    internal IReadOnlyList<FrameworkElement> AutomationOrder => _order;

    /// <summary>
    /// The selected row's rect in the panel's coordinates, its right on the panel's trailing edge (the sheet's left), or
    /// null when it has no joined sheet: a pinned cell, a hidden row, a row (flares included) cut by the list's scrolled
    /// edge, or before layout.
    /// </summary>
    internal Rect? SelectedRowRect()
    {
        if (ActualHeight <= 0)
            return null;
        if (_selectedInList is { } row)
        {
            double height = _viewport.ActualHeight;
            if (row.Y - _flare < _offset - 0.5 || row.Y + row.Height + _flare > _offset + height + 0.5)
                return null;
            return new Rect(row.X, Padding.Top + row.Y - _offset, row.Width, row.Height);
        }

        if (_selectedInBottom is { } popped)
            return new Rect(popped.X, ActualHeight - _bottomHeight + popped.Y, popped.Width, popped.Height);
        return null;
    }

    /// <summary>
    /// Brings the panel in line with <paramref name="model"/>: one element per tab, group header and worktree head
    /// (kept across syncs), each element's state, UI Automation name and place, the boxes, rails and the archive's
    /// marks, the footer buttons. A new selection is brought into view (once a press that made it is let go). A drag
    /// in progress ends where it stands: the model changed under it.
    /// </summary>
    internal void Sync(WindowTabs model)
    {
        _drag.Cancel();
        _model = model;
        Preferences? preferences = _window?.Manager.Preferences;
        string defaultEmoji = preferences?.Get<string>(PrefKey.DefaultTabEmoji) ?? string.Empty;
        int defaultColor = preferences?.Get<int>(PrefKey.DefaultTabIconColor) ?? -1;

        // A snapshot: WindowTabs.Tabs is its live list.
        IReadOnlyList<WindowTabs.Tab> tabs = model.Tabs.ToList();
        IReadOnlyList<TabGroup> groups = model.ManualGroups;
        IReadOnlyList<WorktreeBox> boxes = model.WorktreeBoxes;
        Guid? selected = model.SelectedTabId;
        int pinned = model.PinnedCount;
        List<WorktreeBox> listBoxes = boxes.Where(box => !tabs[box.First].Pinned).ToList();
        VerticalTabLayout layout = VerticalTabLayout.Compute(tabs, groups, listBoxes, _metrics);

        TabIconState Icon(WindowTabs.Tab tab, bool isSelected) =>
            new(tab.Emoji, TabStrip.GlyphOf(tab), tab.IconColor, isSelected, null, null, defaultEmoji, defaultColor);

        // The pinned grid, a flare below the list's top (room for a selected first row's flare).
        var cells = new List<PinnedCellState>();
        for (int index = 0; index < pinned; index++)
        {
            WindowTabs.Tab tab = tabs[index];
            WorktreeBox? box = boxes.FirstOrDefault(candidate => candidate.Contains(index));
            string title = DisplayText.Sanitize(tab.Title);
            bool isSelected = tab.Id == selected;
            cells.Add(new PinnedCellState(tab.Id, TabStrip.TabName(title, tab, null, box), TabStrip.TabToolTip(title, tab),
                isSelected, !isSelected && model.MultiSelection.Contains(tab.Id), box is not null, Icon(tab, isSelected)));
        }

        double gridHeight = _grid.Sync(cells, _width - _rowInset - _panelTrailing);
        Canvas.SetLeft(_grid, _rowInset);
        Canvas.SetTop(_grid, _flare);
        _grid.Visibility = pinned > 0 ? Visibility.Visible : Visibility.Collapsed;
        double rowsTop = (pinned > 0 ? _flare + gridHeight : 0) + _flare;

        // The rows: the list's (placed by PlaceList), then the popped-out one at the bottom (by SyncBottom).
        var liveTabs = new HashSet<Guid>();
        for (int index = pinned; index < tabs.Count; index++)
        {
            WindowTabs.Tab tab = tabs[index];
            liveTabs.Add(tab.Id);
            if (!_rows.TryGetValue(tab.Id, out VerticalTabRow? row))
            {
                row = new VerticalTabRow(this, tab.Id);
                _drag.AttachTab(row, row.Id);
                row.ContextRequested += (_, e) => TabContextMenu.OnContextRequested(row, e);
                _rows[tab.Id] = row;
            }

            TabGroup? group = groups.FirstOrDefault(candidate => candidate.Contains(index));
            WorktreeBox? box = listBoxes.FirstOrDefault(candidate => candidate.Contains(index));
            bool isSelected = tab.Id == selected;
            string title = DisplayText.Sanitize(tab.Title);
            string toolTip = TabStrip.TabToolTip(title, tab);
            if (group is not null && TabStrip.GroupName(group) is { Length: > 0 } groupName)
                toolTip = $"{toolTip}\nGroup {groupName}";
            row.Update(new TabItemState(title, TabStrip.TabName(title, tab, group, box), toolTip, false, isSelected,
                !isSelected && model.MultiSelection.Contains(tab.Id), Icon(tab, isSelected)));
            MoveTo(row, tab.Archived ? _bottomItems : _items);
            if (tab.Archived)
            {
                row.Visibility = Visibility.Visible;
                Canvas.SetZIndex(row, 0);
            }
        }

        RemoveStale(_rows, liveTabs);

        var liveGroups = new HashSet<Guid>();
        foreach (TabGroup group in groups)
        {
            liveGroups.Add(group.Id);
            if (!_headers.TryGetValue(group.Id, out VerticalGroupHeader? header))
            {
                header = new VerticalGroupHeader(this, group.Id);
                _drag.AttachGroup(header, header.GroupId);
                header.ContextRequested += (_, e) =>
                {
                    e.Handled = true;
                    ShowGroupFlyout(header.GroupId);
                };
                _headers[group.Id] = header;
            }

            string name = TabStrip.ChipName(group);
            bool named = TabStrip.GroupName(group).Length > 0;
            header.Update(TabStrip.ChipText(group), named, TabColors.Group(group.Group.ColorIndex), name,
                $"{name}. Click to {(group.Group.Collapsed ? "show" : "hide")} its tabs.", group.Group.Collapsed);
            MoveTo(header, _items);
        }

        RemoveStale(_headers, liveGroups);

        var liveBoxes = new HashSet<string>(StringComparer.Ordinal);
        foreach (WorktreeBox box in listBoxes)
        {
            liveBoxes.Add(box.Key);
            if (!_heads.TryGetValue(box.Key, out VerticalWorktreeHead? head))
            {
                head = new VerticalWorktreeHead(this);
                _drag.AttachHead(head, () => head.FirstTab, () => head.BoxKey);
                head.ContextRequested += (_, e) => TabContextMenu.OnContextRequested(head, e);
                _heads[box.Key] = head;
            }

            int count = box.Last - box.First + 1;
            string repo = TabStrip.RepoName(box.Key);
            head.Update(tabs[box.First].Id, box.Key, repo,
                $"Worktrees of {repo} ({count.ToString(CultureInfo.InvariantCulture)})");
            MoveTo(head, _items);
        }

        RemoveStale(_heads, liveBoxes);

        _tabs = tabs;
        _groups = groups;
        _listBoxes = listBoxes;
        _layout = layout;
        _rowsTop = rowsTop;
        _content.Width = _width;
        PlaceList(layout);
        SyncBottom(model);
        Order(tabs, groups, listBoxes, layout);

        if (selected != _selectedId)
        {
            _selectedId = selected;
            _revealPending = true;
        }

        // A list that got shorter scrolls back within its content; then the new selection comes into view.
        SetOffset(_offset);
        if (_revealPending && !_pressHeld)
            Reveal();
        NotifyAutomationChildren();

        // An open flyout shows the tabs as they are now, or hides when what it shows went.
        _groupFlyout?.Synced(model);
        _archiveFlyout?.Synced(model);
        _closedFlyout?.Synced(model);
        _allTabsFlyout?.Synced(model);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new VerticalTabsPanelAutomationPeer(this);

    /// <summary>Raised on the UI thread, outside any layout pass.</summary>
    private void OnIconImagesChanged(object? sender, EventArgs e)
    {
        foreach (VerticalTabRow row in _rows.Values)
            row.RefreshIcon();
        _grid.RefreshIcons();
    }

    // Placing and drawing: on each sync, and on each step of a drag (the list's marks move with its content, so a
    // scroll rebuilds nothing).

    /// <summary>
    /// Places the list's rows, headers and worktree heads where <paramref name="layout"/> says (at rest, or a drag's
    /// target), the dragged unit's lifted by <see cref="_lift"/> over the others, a row indented in the group it is
    /// drawn in; then the boxes and rails.
    /// </summary>
    private void PlaceList(VerticalTabLayout layout)
    {
        Guid? selected = _model?.SelectedTabId;
        _selectedInList = null;
        for (int index = 0; index < _tabs.Count; index++)
        {
            WindowTabs.Tab tab = _tabs[index];
            if (tab.Pinned || tab.Archived || !_rows.TryGetValue(tab.Id, out VerticalTabRow? row))
                continue;
            if (!layout.Rows.TryGetValue(index, out double top))
            {
                row.Visibility = Visibility.Collapsed;
                continue;
            }

            bool lifted = IsLifted(index);
            double x = _rowInset + (GroupAt(index) is null ? 0 : _indent);
            var rect = new Rect(x, _rowsTop + top + (lifted ? _lift : 0), _width - x, _rowHeight);
            Place(row, rect);
            row.Visibility = Visibility.Visible;
            Canvas.SetZIndex(row, lifted ? 1 : 0);
            if (tab.Id == selected)
                _selectedInList = rect;
        }

        foreach (TabGroup group in _groups)
        {
            if (!_headers.TryGetValue(group.Id, out VerticalGroupHeader? header))
                continue;
            if (!layout.Headers.TryGetValue(group.Id, out double top))
            {
                header.Visibility = Visibility.Collapsed;
                continue;
            }

            bool lifted = _dragShown?.Unit is TabArrangement.Unit.Group moved && moved.Id == group.Id;
            bool named = TabStrip.GroupName(group).Length > 0;
            double width = named ? _width - _rowInset - _headerTrailing : _headerHeight;
            Place(header, new Rect(_rowInset, _rowsTop + top + (lifted ? _lift : 0), width, _headerHeight));
            header.Visibility = Visibility.Visible;
            Canvas.SetZIndex(header, lifted ? 1 : 0);
        }

        foreach (WorktreeBox box in _listBoxes)
        {
            if (!_heads.TryGetValue(box.Key, out VerticalWorktreeHead? head))
                continue;
            if (!layout.Heads.TryGetValue(box.Key, out double top))
            {
                head.Visibility = Visibility.Collapsed;
                continue;
            }

            bool lifted = IsBoxLifted(box);
            double x = _rowInset + (GroupAt(box.First) is null ? 0 : _indent);
            Place(head, new Rect(x, _rowsTop + top + (lifted ? _lift : 0), _width - _boxTrailing - x, _headHeight));
            head.Visibility = Visibility.Visible;
            Canvas.SetZIndex(head, lifted ? 1 : 0);
        }

        int pinned = _tabs.TakeWhile(tab => tab.Pinned).Count();
        _contentHeight = layout.Height > 0 ? _rowsTop + layout.Height + _flare : pinned > 0 ? _rowsTop : 0;
        _content.Height = _contentHeight;
        DrawList(layout);
    }

    /// <summary>The box moves whole with the drag (a box or a group is dragged, not one of its rows).</summary>
    private bool IsBoxLifted(WorktreeBox box) =>
        _dragShown is { Unit: not TabArrangement.Unit.Tab } && IsLifted(box.First);

    /// <summary>The worktree boxes (fill and edge, the selected row cut out) and the expanded groups' rails; a dragged
    /// box or group's follow the pointer with its rows.</summary>
    private void DrawList(VerticalTabLayout layout)
    {
        _back.Children.Clear();
        double rowsTop = _rowsTop;
        double groupEdge = PaletteResources.Double("WorktreeBoxGroupEdgeOpacity");
        foreach (WorktreeBox box in _listBoxes)
        {
            if (!layout.Boxes.TryGetValue(box.Key, out (double Start, double End) span))
                continue;
            TabGroup? group = GroupAt(box.First);
            double lift = IsBoxLifted(box) ? _lift : 0;
            // From the rows' leading inset (a group's indent) to a hair short of the sheet, a little above and below
            // its head line and last row.
            double x = group is null ? 0 : _indent;
            var rect = new Rect(x, rowsTop + span.Start - _boxOutset + lift, Math.Max(0, _width - _boxTrailing - x),
                span.End - span.Start + 2 * _boxOutset);
            AddPath(_back, SheetTabShape.Box(rect, _boxRadius, false, _selectedInList, joinedLeft: true),
                TabColors.Brush(PaletteResources.Color("WorktreeBoxFillColor")));
            Brush edge = group is not null
                ? TabColors.Brush(TabColors.Group(group.Group.ColorIndex), groupEdge)
                : TabColors.Brush(PaletteResources.Color("WorktreeBoxBorderColor"));
            AddPath(_back, SheetTabShape.Box(rect, _boxRadius, true, _selectedInList, joinedLeft: true), edge);
        }

        foreach (TabGroup group in _groups)
        {
            if (!layout.Rails.TryGetValue(group.Id, out (double Start, double End) rail) || rail.End <= rail.Start)
                continue;
            bool lifted = _dragShown?.Unit is TabArrangement.Unit.Group moved && moved.Id == group.Id;
            var line = new Rectangle
            {
                Width = _rail,
                Height = rail.End - rail.Start,
                RadiusX = _rail / 2,
                RadiusY = _rail / 2,
                Fill = TabColors.Brush(TabColors.Group(group.Group.ColorIndex)),
                IsHitTestVisible = false,
            };
            Canvas.SetLeft(line, _rowInset + (_indent - _rail) / 2);
            Canvas.SetTop(line, rowsTop + rail.Start + (lifted ? _lift : 0));
            _back.Children.Add(line);
        }
    }

    /// <summary>
    /// The bottom: the popped-out archived row (indented as a group's row, right of the archive's line) a flare's room
    /// above and below, then the footer buttons (closed groups, archive, New Tab, All Tabs); the archive's line from the
    /// row's top down to the archive button, and the row's dashed orange outline (design §3.7), open on the sheet's
    /// side while the row is selected (the sheet's figure fills it then).
    /// </summary>
    private void SyncBottom(WindowTabs model)
    {
        _selectedInBottom = null;
        _bottomBack.Children.Clear();
        _bottomOverlay.Children.Clear();

        bool closedShown = model.ClosedGroups.Count > 0;
        string closed = $"Closed groups ({model.ClosedGroups.Count.ToString(CultureInfo.InvariantCulture)})";
        AutomationProperties.SetName(_closedGroups, closed);
        ToolTipService.SetToolTip(_closedGroups, closed);
        _closedCount.Text = model.ClosedGroups.Count.ToString(CultureInfo.InvariantCulture);
        _closedGroups.Visibility = closedShown ? Visibility.Visible : Visibility.Collapsed;

        int archived = model.ArchivedTabs.Count + (model.ArchivedOut is null ? 0 : 1);
        bool archiveShown = archived > 0;
        string archive = $"Archived tabs ({archived.ToString(CultureInfo.InvariantCulture)})";
        AutomationProperties.SetName(_archive, archive);
        ToolTipService.SetToolTip(_archive, archive);
        _archive.Visibility = archiveShown ? Visibility.Visible : Visibility.Collapsed;

        double archiveX = _rowInset + (closedShown ? _square + _stowGap : 0);
        double footerTop = 0;
        if (model.ArchivedOut is { } popped && _rows.TryGetValue(popped.Id, out VerticalTabRow? row))
        {
            double x = archiveX + _indent;
            var rect = new Rect(x, _flare, _width - x, _rowHeight);
            Place(row, rect);
            bool selected = popped.Id == model.SelectedTabId;
            if (selected)
                _selectedInBottom = rect;
            footerTop = _flare + _rowHeight + _flare;

            Brush orange = TabColors.Brush(TabColors.Archive);
            if (archiveShown)
            {
                // Down the middle of the row's indent, on to the archive button's top edge (its rounded corner dips
                // below its frame's top at the line's x by this much).
                double radius = ((CornerRadius)Application.Current.Resources["SquareButtonCornerRadius"]).TopLeft;
                double dx = Math.Max(radius - _indent / 2, 0);
                double dip = radius - Math.Sqrt(Math.Max(radius * radius - dx * dx, 0));
                var line = new Rectangle
                {
                    Width = _outline,
                    Height = footerTop - _flare + dip,
                    Fill = orange,
                    IsHitTestVisible = false,
                };
                Canvas.SetLeft(line, archiveX + (_indent - _outline) / 2);
                Canvas.SetTop(line, _flare);
                _bottomBack.Children.Add(line);
            }

            double thickness = _outline;
            Geometry outline = selected
                ? SheetTabShape.LeftOutline(rect, thickness)
                : SheetTabShape.RoundedRect(
                    new Rect(rect.X + thickness / 2, rect.Y + thickness / 2,
                        Math.Max(0, rect.Width - _hoverTrailing - thickness), rect.Height - thickness),
                    rect.Height / 2);
            _bottomOverlay.Children.Add(new Path
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

        // The footer: the stow buttons 8 apart, New Tab and All Tabs a tab gap apart, centered on the stow buttons.
        double bx = _rowInset;
        if (closedShown)
        {
            Place(_closedGroups, new Rect(bx, footerTop, _square, _square));
            bx += _square + _stowGap;
        }

        if (archiveShown)
        {
            Place(_archive, new Rect(bx, footerTop, _square, _square));
            bx += _square + _stowGap;
        }

        double buttonTop = footerTop + (_square - _button) / 2;
        Place(_newTab, new Rect(bx, buttonTop, _button, _button));
        Place(_allTabs, new Rect(bx + _button + _gap, buttonTop, _button, _button));

        _bottomHeight = footerTop + _square + _panelBottom;
        _bottom.Height = _bottomHeight;
    }

    private static void AddPath(Canvas layer, Geometry? geometry, Brush fill)
    {
        if (geometry is null)
            return;
        layer.Children.Add(new Path { Data = geometry, Fill = fill, IsHitTestVisible = false });
    }

    // Order and automation.

    /// <summary>The panel's shown items in tab order: the pinned grid, each group's header before its first row, each
    /// worktree head before its box's rows, the rows, the popped-out row, the footer buttons.</summary>
    private void Order(
        IReadOnlyList<WindowTabs.Tab> tabs, IReadOnlyList<TabGroup> groups, IReadOnlyList<WorktreeBox> boxes,
        VerticalTabLayout layout)
    {
        _order.Clear();
        if (_grid.Visibility == Visibility.Visible)
            _order.Add(_grid);
        for (int index = 0; index < tabs.Count; index++)
        {
            if (groups.FirstOrDefault(group => group.First == index) is { } group
                && _headers.TryGetValue(group.Id, out VerticalGroupHeader? header) && header.Visibility == Visibility.Visible)
                _order.Add(header);
            if (boxes.FirstOrDefault(box => box.First == index) is { } box && layout.Heads.ContainsKey(box.Key)
                && _heads.TryGetValue(box.Key, out VerticalWorktreeHead? head))
                _order.Add(head);
            if (!tabs[index].Pinned && _rows.TryGetValue(tabs[index].Id, out VerticalTabRow? row)
                && row.Visibility == Visibility.Visible)
                _order.Add(row);
        }

        foreach (Button button in (Button[])[_closedGroups, _archive, _newTab, _allTabs])
        {
            if (button.Visibility == Visibility.Visible)
                _order.Add(button);
        }
    }

    /// <summary>
    /// Tells UI Automation clients that the panel's items changed (an item came, went, showed or hid): the panel lists
    /// its own children (<see cref="AutomationOrder"/>), so the framework does not see them change.
    /// </summary>
    private void NotifyAutomationChildren()
    {
        if (!AutomationPeer.ListenerExists(AutomationEvents.StructureChanged)
            || FrameworkElementAutomationPeer.FromElement(this) is not { } peer)
        {
            _automationChildren = null;
            return;
        }

        if (_automationChildren is { } shown && shown.SequenceEqual(_order))
            return;
        _automationChildren = [.. _order];
        try
        {
            peer.RaiseStructureChangedEvent(AutomationStructureChangeType.ChildrenInvalidated, null);
        }
        catch (Exception error)
        {
            CrashLog.Recovered("UI Automation structure event (not raised)", error);
        }
    }

    // Scrolling: the list's own offset, so the sheet's joined row moves with the rows.

    private void OnViewportSizeChanged(object sender, SizeChangedEventArgs e)
    {
        _viewportClip.Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height);
        SetOffset(_offset);
        if (_revealPending && !_pressHeld)
            Reveal();
        GeometryChanged?.Invoke(this, EventArgs.Empty);
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var properties = e.GetCurrentPoint(_viewport).Properties;
        if (properties.IsHorizontalMouseWheel || _contentHeight <= _viewport.ActualHeight)
            return;
        SetOffset(_offset - properties.MouseWheelDelta / 120.0 * WheelStep);
        e.Handled = true;
    }

    /// <summary>Scrolls the selected list row, flares included, into view once the viewport has a height.</summary>
    private void Reveal()
    {
        double height = _viewport.ActualHeight;
        if (height <= 0)
            return;
        _revealPending = false;
        if (_selectedInList is not { } row)
            return;
        double start = row.Y - _flare;
        double end = row.Y + row.Height + _flare;
        if (start < _offset)
            SetOffset(start);
        else if (end > _offset + height)
            SetOffset(end - height);
    }

    /// <summary>Moves the list's content (a render transform: no layout) within its scroll range.</summary>
    private void SetOffset(double offset)
    {
        double end = Math.Max(0, _contentHeight - _viewport.ActualHeight);
        offset = Math.Clamp(offset, 0, end);
        if (Math.Abs(offset - _offset) < 0.01)
            return;
        _offset = offset;
        _scroll.Y = -offset;
        GeometryChanged?.Invoke(this, EventArgs.Empty);
    }

    // Elements.

    private static void Place(FrameworkElement element, Rect rect)
    {
        Canvas.SetLeft(element, rect.X);
        Canvas.SetTop(element, rect.Y);
        element.Width = Math.Max(0, rect.Width);
        element.Height = Math.Max(0, rect.Height);
    }

    /// <summary>Puts <paramref name="element"/> on <paramref name="target"/>, off the canvas recorded for it. A failure
    /// is logged and the sync goes on; the element is tried again at the next sync.</summary>
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
            CrashLog.Recovered($"VerticalTabsPanel.MoveTo {element.GetType().Name} (item left off the panel)", error);
            try
            {
                RemoveFrom(target, element);
            }
            catch (Exception cleanup)
            {
                CrashLog.Recovered("VerticalTabsPanel.MoveTo cleanup", cleanup);
            }
        }
    }

    /// <summary>Takes <paramref name="element"/> off both item canvases and its visual parent.</summary>
    private void Detach(FrameworkElement element)
    {
        _homes.Remove(element);
        RemoveFrom(_items, element);
        RemoveFrom(_bottomItems, element);
        if (VisualTreeHelper.GetParent(element) is Panel parent)
            RemoveFrom(parent, element);
    }

    private static void RemoveFrom(Panel panel, UIElement element)
    {
        UIElementCollection children = panel.Children;
        for (int index = children.Count - 1; index >= 0; index--)
        {
            if (ReferenceEquals(children[index], element))
                children.RemoveAt(index);
        }
    }

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
                CrashLog.Recovered($"VerticalTabsPanel.RemoveStale {typeof(TView).Name} (left on the panel)", error);
            }

            views.Remove(key);
        }
    }

    /// <summary>A 24 epx round footer button (New Tab, All Tabs): white 0.06, hover 0.10, pressed 0.20.</summary>
    private Button RoundButton(string glyph, string name)
    {
        var button = new Button
        {
            Width = _button,
            Height = _button,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(_button / 2),
            Content = new FontIcon { Glyph = glyph, FontSize = PaletteResources.Double("TabRowButtonIconSize") },
        };
        TabStrip.StyleButton(button, PaletteResources.Brush("TabFillBrush"), PaletteResources.Brush("HoverFillBrush"),
            PaletteResources.Brush("PressedFillBrush"));
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        return button;
    }
}

/// <summary>The panel in UI Automation: a Tab control named "Vertical tabs" whose children come in tab order
/// (<see cref="VerticalTabsPanel.AutomationOrder"/>), not in drawing order.</summary>
internal sealed partial class VerticalTabsPanelAutomationPeer(VerticalTabsPanel owner) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Tab;

    protected override string GetClassNameCore() => nameof(VerticalTabsPanel);

    protected override bool IsControlElementCore() => true;

    protected override IList<AutomationPeer> GetChildrenCore()
    {
        var peers = new List<AutomationPeer>();
        foreach (FrameworkElement element in owner.AutomationOrder)
        {
            if (element.Visibility == Visibility.Visible && CreatePeerForElement(element) is { } peer)
                peers.Add(peer);
        }

        return peers;
    }
}

/// <summary>
/// A vertical tab (a row, the popped-out row, a pinned cell) in UI Automation: a TabItem with the SelectionItem pattern,
/// so vmpal_tree sees which is selected; its selection container is the panel.
/// </summary>
internal sealed partial class VerticalTabAutomationPeer(
    FrameworkElement owner, Func<bool> isSelected, Action select, Func<VerticalTabsPanel> panel)
    : FrameworkElementAutomationPeer(owner), ISelectionItemProvider
{
    public bool IsSelected => isSelected();

    public IRawElementProviderSimple SelectionContainer => ProviderFromPeer(CreatePeerForElement(panel()));

    public void AddToSelection() => select();

    /// <summary>Single selection with one tab always selected, so a selected tab cannot be unselected.</summary>
    public void RemoveFromSelection()
    {
        if (isSelected())
            throw new InvalidOperationException("The vertical tabs always keep one tab selected.");
    }

    public void Select() => select();

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.SelectionItem ? this : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.TabItem;

    protected override string GetClassNameCore() => Owner.GetType().Name;

    protected override bool IsControlElementCore() => true;
}

/// <summary>
/// One tab as a row of the vertical tabs (VerticalTabRow, the Settings sidebar row style): 28 epx, padded 10, its icon
/// (<see cref="TabIcon"/>) in a 20 epx slot, 8, the title (13, cut with "…"), the close button on hover. Unselected,
/// the title is at 0.60 white and a capsule fill shows on hover (0.06) or in the multi-selection (0.08), stopping 3 epx
/// short of the sheet; the selected row has no fill: the sheet's joined figure is its fill.
/// </summary>
internal sealed partial class VerticalTabRow : Grid
{
    private static readonly SolidColorBrush NoFill = new(Colors.Transparent);

    private readonly VerticalTabsPanel _panel;
    private readonly Border _fill;
    private readonly TabIcon _icon;
    private readonly TextBlock _title;
    private readonly Button _close;
    private TabItemState? _state;
    private bool _hovered;

    public VerticalTabRow(VerticalTabsPanel panel, Guid id)
    {
        _panel = panel;
        Id = id;
        double height = PaletteResources.Double("VerticalRowHeight");
        double slot = PaletteResources.Double("TabSlot");
        double padding = PaletteResources.Double("VerticalRowPadding");
        // A background, even transparent, makes the whole row hit-testable, not only its text.
        Background = NoFill;
        _fill = new Border
        {
            Margin = new Thickness(0, 0, PaletteResources.Double("VerticalHoverTrailing"), 0),
            CornerRadius = new CornerRadius(height / 2),
            Background = NoFill,
            BackgroundTransition = new BrushTransition { Duration = PaletteResources.TimeSpan("MotionHoverDuration") },
            IsHitTestVisible = false,
        };
        _icon = new TabIcon { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        _title = new TextBlock
        {
            FontSize = PaletteResources.Double("TabTitleFontSize"),
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
            IsHitTestVisible = false,
        };
        _close = new Button
        {
            Width = slot,
            Height = slot,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(slot / 2),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            IsTabStop = false,
            Content = new FontIcon { Glyph = "", FontSize = PaletteResources.Double("TabCloseGlyphSize") },
        };
        TabStrip.StyleButton(_close, NoFill, PaletteResources.Brush("HoverFillBrush"),
            PaletteResources.Brush("PressedFillBrush"));
        _close.Resources["ButtonForeground"] = PaletteResources.Brush("TabTitleBrush");
        _close.Resources["ButtonForegroundPointerOver"] = PaletteResources.Brush("TabTitleSelectedBrush");
        _close.Resources["ButtonForegroundPressed"] = PaletteResources.Brush("TabTitleSelectedBrush");
        ToolTipService.SetToolTip(_close, "Close Tab");
        _close.Click += (_, _) => _panel.CloseTab(Id);

        var row = new Grid
        {
            Padding = new Thickness(padding, 0, padding, 0),
            ColumnSpacing = PaletteResources.Double("VerticalRowContentSpacing"),
        };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(PaletteResources.Double("VerticalIconSlot")) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        SetColumn(_title, 1);
        SetColumn(_close, 2);
        row.Children.Add(_icon);
        row.Children.Add(_title);
        row.Children.Add(_close);
        Children.Add(_fill);
        Children.Add(row);

        PointerEntered += (_, _) => SetHovered(true);
        PointerExited += (_, _) => SetHovered(false);
        PointerCanceled += (_, _) => SetHovered(false);
    }

    public Guid Id { get; }

    public bool IsSelected => _state?.Selected == true;

    internal VerticalTabsPanel Panel => _panel;

    public void Update(TabItemState state)
    {
        if (_state == state)
            return;
        bool wasSelected = IsSelected;
        string? oldName = _state?.Name;
        _state = state;
        _icon.Update(state.Icon);
        _title.Text = state.Title;
        _title.Foreground = PaletteResources.Brush(state.Selected ? "TabTitleSelectedBrush" : "TabTitleBrush");
        AutomationProperties.SetName(this, state.Name);
        AutomationProperties.SetName(_close, $"Close {state.Title}");
        ToolTipService.SetToolTip(this, state.ToolTip);
        Refresh();

        if (oldName is not null && !string.Equals(oldName, state.Name, StringComparison.Ordinal))
            TabAutomation.RaisePropertyChanged(this, AutomationElementIdentifiers.NameProperty, oldName, state.Name);
        if (wasSelected != state.Selected)
            TabAutomation.RaisePropertyChanged(this, SelectionItemPatternIdentifiers.IsSelectedProperty, wasSelected, state.Selected);
    }

    internal void RefreshIcon() => _icon.RefreshImage();

    protected override AutomationPeer OnCreateAutomationPeer() =>
        new VerticalTabAutomationPeer(this, () => IsSelected, () => _panel.Select(Id), () => _panel);

    private void SetHovered(bool hovered)
    {
        if (_hovered == hovered)
            return;
        _hovered = hovered;
        Refresh();
    }

    private void Refresh()
    {
        TabItemState? state = _state;
        bool selected = state?.Selected == true;
        // Transparent, never null: the fill's BrushTransition animates between solid color brushes only.
        _fill.Background = selected ? NoFill
            : state?.MultiSelected == true ? TabColors.Brush(PaletteResources.Color("MultiSelectFillColor"))
            : _hovered ? PaletteResources.Brush("TabFillBrush")
            : NoFill;
        _close.Visibility = _hovered ? Visibility.Visible : Visibility.Collapsed;
    }
}

/// <summary>
/// A manual group's header row above its rows (VerticalTabGroupHeader): 22 epx, radius 6, the group color at 0.38,
/// its name in white 12 semibold (padded 8, cut with "…"), the tab count appended while collapsed ("Docs · 3"); an
/// unnamed group is a 22 epx color square (with the count while collapsed). UI Automation: a Button with the
/// ExpandCollapse pattern, named as the strip's chip ("Group Docs, 3 tabs").
/// </summary>
internal sealed partial class VerticalGroupHeader : Grid
{
    private readonly VerticalTabsPanel _panel;
    private readonly TextBlock _text;

    public VerticalGroupHeader(VerticalTabsPanel panel, Guid id)
    {
        _panel = panel;
        GroupId = id;
        CornerRadius = (CornerRadius)Application.Current.Resources["ChipCornerRadius"];
        _text = new TextBlock
        {
            FontSize = PaletteResources.Double("VerticalHeaderFontSize"),
            FontWeight = FontWeights.SemiBold,
            Foreground = TabColors.Brush(PaletteResources.Color("GraphBadgeTextColor")),
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
            IsHitTestVisible = false,
        };
        Children.Add(_text);
    }

    public Guid GroupId { get; }

    public bool IsCollapsed { get; private set; }

    internal VerticalTabsPanel Panel => _panel;

    /// <param name="text">The name, with the count while collapsed; empty for an expanded unnamed group.</param>
    /// <param name="named">The group has a name: a full-width row, else a square.</param>
    /// <param name="name">Its UI Automation name ("Group Docs, 3 tabs").</param>
    public void Update(string text, bool named, Windows.UI.Color color, string name, string toolTip, bool collapsed)
    {
        bool wasCollapsed = IsCollapsed;
        string oldName = AutomationProperties.GetName(this);
        IsCollapsed = collapsed;
        _text.Text = text;
        _text.HorizontalAlignment = named ? HorizontalAlignment.Left : HorizontalAlignment.Center;
        double padding = named ? PaletteResources.Double("ChipPadding") : 0;
        Padding = new Thickness(padding, 0, padding, 0);
        Background = TabColors.Fill(color);
        AutomationProperties.SetName(this, name);
        ToolTipService.SetToolTip(this, toolTip);

        if (oldName.Length > 0 && !string.Equals(oldName, name, StringComparison.Ordinal))
            TabAutomation.RaisePropertyChanged(this, AutomationElementIdentifiers.NameProperty, oldName, name);
        if (wasCollapsed != collapsed)
        {
            TabAutomation.RaisePropertyChanged(this, ExpandCollapsePatternIdentifiers.ExpandCollapseStateProperty,
                GroupChipView.State(wasCollapsed), GroupChipView.State(collapsed));
        }
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new VerticalGroupHeaderAutomationPeer(this);
}

/// <summary>A header in UI Automation: a Button that reports its group Collapsed or Expanded.</summary>
internal sealed partial class VerticalGroupHeaderAutomationPeer(VerticalGroupHeader owner)
    : FrameworkElementAutomationPeer(owner), IExpandCollapseProvider, IInvokeProvider
{
    public ExpandCollapseState ExpandCollapseState => GroupChipView.State(owner.IsCollapsed);

    public void Collapse()
    {
        if (!owner.IsCollapsed)
            owner.Panel.ToggleGroup(owner.GroupId);
    }

    public void Expand()
    {
        if (owner.IsCollapsed)
            owner.Panel.ToggleGroup(owner.GroupId);
    }

    public void Invoke() => owner.Panel.ToggleGroup(owner.GroupId);

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface is PatternInterface.ExpandCollapse or PatternInterface.Invoke
            ? this
            : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;

    protected override string GetClassNameCore() => nameof(VerticalGroupHeader);

    protected override bool IsControlElementCore() => true;
}

/// <summary>
/// The head line at a worktree box's top (design §4, a Windows addition): 16 epx, the 12 epx branch glyph lined up with
/// the rows' icons and the repository's folder name lined up with their titles, both at white 0.45. UI Automation: a
/// Button named "Worktrees of &lt;repo&gt; (N)" that selects the box's first tab.
/// </summary>
internal sealed partial class VerticalWorktreeHead : Grid
{
    private readonly VerticalTabsPanel _panel;
    private readonly TextBlock _name;

    public VerticalWorktreeHead(VerticalTabsPanel panel)
    {
        _panel = panel;
        double glyph = PaletteResources.Double("WorktreeHeadGlyphSize");
        double inset = (PaletteResources.Double("VerticalIconSlot") - glyph) / 2;
        Background = new SolidColorBrush(Colors.Transparent);
        Padding = new Thickness(PaletteResources.Double("VerticalRowPadding") + inset, 0, 0, 0);
        ColumnSpacing = inset + PaletteResources.Double("VerticalRowContentSpacing");
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(glyph) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Brush brush = PaletteResources.Brush("WorktreeHeadGlyphBrush");
        Children.Add(new Path
        {
            Width = glyph,
            Height = glyph,
            Data = WorktreeHeadView.BranchGlyph(glyph),
            Stroke = brush,
            StrokeThickness = glyph / 10,
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
        });
        _name = new TextBlock
        {
            FontSize = PaletteResources.Double("VerticalHeadFontSize"),
            Foreground = brush,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
            IsHitTestVisible = false,
        };
        SetColumn(_name, 1);
        Children.Add(_name);
    }

    /// <summary>The box's first tab, which an invoke selects.</summary>
    public Guid FirstTab { get; private set; }

    /// <summary>The box's repository key (its menu and its drag).</summary>
    public string BoxKey { get; private set; } = string.Empty;

    internal VerticalTabsPanel Panel => _panel;

    public void Update(Guid firstTab, string boxKey, string repo, string name)
    {
        FirstTab = firstTab;
        BoxKey = boxKey;
        _name.Text = repo;
        string oldName = AutomationProperties.GetName(this);
        if (string.Equals(oldName, name, StringComparison.Ordinal))
            return;
        AutomationProperties.SetName(this, name);
        ToolTipService.SetToolTip(this, name);
        if (oldName.Length > 0)
            TabAutomation.RaisePropertyChanged(this, AutomationElementIdentifiers.NameProperty, oldName, name);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new VerticalWorktreeHeadAutomationPeer(this);
}

/// <summary>A worktree head line in UI Automation: a Button that selects the box's first tab.</summary>
internal sealed partial class VerticalWorktreeHeadAutomationPeer(VerticalWorktreeHead owner)
    : FrameworkElementAutomationPeer(owner), IInvokeProvider
{
    public void Invoke() => owner.Panel.Select(owner.FirstTab);

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.Invoke ? this : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;

    protected override string GetClassNameCore() => nameof(VerticalWorktreeHead);

    protected override bool IsControlElementCore() => true;
}

using Histq.App.Theme;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace Histq.App.Shell.Tabs;

/// <summary>What one pinned tab's cell shows.</summary>
/// <param name="Name">Its UI Automation name (design §3.12): the title, then "pinned", "worktree of &lt;repo&gt;".</param>
/// <param name="ToolTip">The title, then the path when that says more.</param>
/// <param name="Boxed">In a pinned worktree box: the box's fill when not selected.</param>
internal sealed record PinnedCellState(
    Guid Id, string Name, string ToolTip, bool Selected, bool MultiSelected, bool Boxed, TabIconState Icon);

/// <summary>
/// The pinned tabs as a grid of icon cells at the top of the vertical tabs (design header-and-tab-row.md §4, ported from
/// VerticalPinnedGrid and VerticalPinnedCell in App/Window/VerticalTabsPanel.swift at 6fa6d40): cells 30 epx tall and
/// 30 to 34 wide, up to 4 to a row, 4 apart, inside the pinned well of the top row (§3.3, a Windows addition: radius
/// 18, black 0.18 with its 1 epx inner edge, hugging the cells). The selected cell sits on the sheet's color (not joined: the grid
/// stands off the sheet's edge), a multi-selected one on the multi-select fill, a hovered one on the hover fill, a
/// pinned worktree box's cells on the box's fill. Cells are kept per tab across syncs and placed in
/// <see cref="Sync"/>, never in a layout pass. UI Automation: a Group named "Pinned tabs" whose children are the cells
/// (TabItems with SelectionItem). A press selects a cell alone (never a drag), a middle click closes it, a right click opens
/// the tab menu (<see cref="VerticalTabsPanel.AttachCell"/>).
/// </summary>
internal sealed partial class VerticalPinnedGrid : Canvas
{
    private readonly VerticalTabsPanel _panel;
    private readonly Canvas _well = new();
    private readonly Canvas _items = new();
    private readonly Dictionary<Guid, VerticalPinnedCell> _cells = [];
    private readonly List<VerticalPinnedCell> _order = [];
    private readonly double _cell;
    private readonly double _cellMax;
    private readonly double _spacing;
    private readonly double _columns;
    private readonly double _padding;
    private Size _wellSize;

    public VerticalPinnedGrid(VerticalTabsPanel panel)
    {
        _panel = panel;
        _cell = PaletteResources.Double("VerticalPinnedCell");
        _cellMax = PaletteResources.Double("VerticalPinnedCellMax");
        _spacing = PaletteResources.Double("VerticalPinnedSpacing");
        _columns = PaletteResources.Double("VerticalPinnedColumns");
        _padding = PaletteResources.Double("VerticalPinnedWellPadding");
        Children.Add(_well);
        Children.Add(_items);
        AutomationProperties.SetName(this, "Pinned tabs");
    }

    internal VerticalTabsPanel Panel => _panel;

    /// <summary>The cells in tab order (the automation children).</summary>
    internal IReadOnlyList<VerticalPinnedCell> Cells => _order;

    /// <summary>
    /// One cell per pinned tab, in order, placed in rows of up to 4 inside a grid <paramref name="width"/> wide (the
    /// well's outer width at most); the well hugs them. Returns the grid's height (0 without pinned tabs). Called
    /// outside layout passes only.
    /// </summary>
    public double Sync(IReadOnlyList<PinnedCellState> cells, double width)
    {
        var live = new HashSet<Guid>();
        _order.Clear();
        foreach (PinnedCellState state in cells)
        {
            live.Add(state.Id);
            if (!_cells.TryGetValue(state.Id, out VerticalPinnedCell? cell))
            {
                cell = new VerticalPinnedCell(this, state.Id);
                _panel.AttachCell(cell);
                _cells[state.Id] = cell;
                _items.Children.Add(cell);
            }

            cell.Update(state);
            _order.Add(cell);
        }

        foreach (Guid id in _cells.Keys.Where(id => !live.Contains(id)).ToList())
        {
            VerticalPinnedCell stale = _cells[id];
            int at = _items.Children.IndexOf(stale);
            if (at >= 0)
                _items.Children.RemoveAt(at);
            _cells.Remove(id);
        }

        if (cells.Count == 0)
        {
            SetWell(new Size(0, 0));
            Width = 0;
            Height = 0;
            return 0;
        }

        // Up to 4 columns of at least 30 epx in the well's inner width, each as wide as that allows up to 34.
        double inner = Math.Max(0, width - 2 * _padding);
        int fit = (int)Math.Floor((inner + _spacing) / (_cell + _spacing));
        int columns = Math.Clamp(fit, 1, (int)_columns);
        double cellWidth = Math.Clamp((inner - (columns - 1) * _spacing) / columns, 1, _cellMax);
        int used = Math.Min(columns, cells.Count);
        int rows = (cells.Count + columns - 1) / columns;
        for (int index = 0; index < _order.Count; index++)
        {
            VerticalPinnedCell cell = _order[index];
            SetLeft(cell, _padding + (index % columns) * (cellWidth + _spacing));
            SetTop(cell, _padding + (index / columns) * (_cell + _spacing));
            cell.Width = cellWidth;
            cell.Height = _cell;
        }

        var size = new Size(
            used * cellWidth + (used - 1) * _spacing + 2 * _padding,
            rows * _cell + (rows - 1) * _spacing + 2 * _padding);
        SetWell(size);
        Width = size.Width;
        Height = size.Height;
        return size.Height;
    }

    /// <summary>The icon images changed: each cell's icon is drawn again if it shows an image.</summary>
    internal void RefreshIcons()
    {
        foreach (VerticalPinnedCell cell in _cells.Values)
            cell.RefreshIcon();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new VerticalPinnedGridAutomationPeer(this);

    /// <summary>The well (fill and inner edge) for <paramref name="size"/>, rebuilt only when that changes.</summary>
    private void SetWell(Size size)
    {
        if (size == _wellSize && _well.Children.Count > 0 == (size.Width > 0))
            return;
        _wellSize = size;
        _well.Children.Clear();
        if (size.Width <= 0 || size.Height <= 0)
            return;
        var rect = new Rect(0, 0, size.Width, size.Height);
        double radius = PaletteResources.Double("TabRadius");
        AddPath(SheetTabShape.Box(rect, radius, false, null), "PinnedWellFillColor");
        AddPath(SheetTabShape.Box(rect, radius, true, null), "PinnedWellEdgeColor");
    }

    private void AddPath(Geometry? geometry, string colorKey)
    {
        if (geometry is null)
            return;
        _well.Children.Add(new Path
        {
            Data = geometry,
            Fill = TabColors.Brush(PaletteResources.Color(colorKey)),
            IsHitTestVisible = false,
        });
    }
}

/// <summary>The pinned grid in UI Automation: a Group named "Pinned tabs" whose children are its cells in tab order.</summary>
internal sealed partial class VerticalPinnedGridAutomationPeer(VerticalPinnedGrid owner) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Group;

    protected override string GetClassNameCore() => nameof(VerticalPinnedGrid);

    protected override bool IsControlElementCore() => true;

    protected override IList<AutomationPeer> GetChildrenCore()
    {
        var peers = new List<AutomationPeer>();
        foreach (VerticalPinnedCell cell in owner.Cells)
        {
            if (CreatePeerForElement(cell) is { } peer)
                peers.Add(peer);
        }

        return peers;
    }
}

/// <summary>
/// A pinned tab's cell (VerticalPinnedCell): its icon (<see cref="TabIcon"/>, with the profile's dot) centered in a
/// rounded square (radius 8), on the sheet's color when selected, the multi-select fill, the hover fill, or a worktree
/// box's fill. UI Automation: a TabItem named as the strip names it ("docs, pinned").
/// </summary>
internal sealed partial class VerticalPinnedCell : Grid
{
    private static readonly SolidColorBrush NoFill = new(Colors.Transparent);

    private readonly VerticalPinnedGrid _grid;
    private readonly TabIcon _icon;
    private PinnedCellState? _state;
    private bool _hovered;

    public VerticalPinnedCell(VerticalPinnedGrid grid, Guid id)
    {
        _grid = grid;
        Id = id;
        CornerRadius = new CornerRadius(PaletteResources.Double("VerticalPinnedRadius"));
        Background = NoFill;
        BackgroundTransition = new BrushTransition { Duration = PaletteResources.TimeSpan("MotionHoverDuration") };
        _icon = new TabIcon { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        Children.Add(_icon);
        PointerEntered += (_, _) => SetHovered(true);
        PointerExited += (_, _) => SetHovered(false);
        PointerCanceled += (_, _) => SetHovered(false);
    }

    public Guid Id { get; }

    public bool IsSelected => _state?.Selected == true;

    internal VerticalTabsPanel Panel => _grid.Panel;

    public void Update(PinnedCellState state)
    {
        if (_state == state)
            return;
        bool wasSelected = IsSelected;
        string? oldName = _state?.Name;
        _state = state;
        _icon.Update(state.Icon);
        AutomationProperties.SetName(this, state.Name);
        ToolTipService.SetToolTip(this, state.ToolTip);
        Refresh();

        if (oldName is not null && !string.Equals(oldName, state.Name, StringComparison.Ordinal))
            TabAutomation.RaisePropertyChanged(this, AutomationElementIdentifiers.NameProperty, oldName, state.Name);
        if (wasSelected != state.Selected)
            TabAutomation.RaisePropertyChanged(this, SelectionItemPatternIdentifiers.IsSelectedProperty, wasSelected, state.Selected);
    }

    internal void RefreshIcon() => _icon.RefreshImage();

    protected override AutomationPeer OnCreateAutomationPeer() => new VerticalTabAutomationPeer(this, () => IsSelected,
        () => Panel.Select(Id), () => Panel);

    private void SetHovered(bool hovered)
    {
        if (_hovered == hovered)
            return;
        _hovered = hovered;
        Refresh();
    }

    /// <summary>Selected: the sheet's color; else the multi-select fill, the hover fill, or a box's fill.</summary>
    private void Refresh()
    {
        PinnedCellState? state = _state;
        // Solid color brushes only, never null: the BrushTransition animates between them.
        Background = state?.Selected == true ? TabColors.Brush(PaletteResources.Color("SheetColor"))
            : state?.MultiSelected == true ? TabColors.Brush(PaletteResources.Color("MultiSelectFillColor"))
            : _hovered ? PaletteResources.Brush("TabFillBrush")
            : state?.Boxed == true ? TabColors.Brush(PaletteResources.Color("WorktreeBoxFillColor"))
            : NoFill;
    }
}

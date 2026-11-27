using Histq.App.Theme;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;
using Windows.UI;

namespace Histq.App.Shell.Tabs;

/// <summary>What one tab shows.</summary>
/// <param name="Name">Its UI Automation name (design §3.12): the title, then "pinned", "archived", "in group &lt;name&gt;",
/// "worktree of &lt;repo&gt;" as they apply.</param>
/// <param name="ToolTip">The repo path; a pinned tab's leads with its title.</param>
internal sealed record TabItemState(
    string Title, string Name, string ToolTip, bool Pinned, bool Selected, bool MultiSelected, TabIconState Icon);

/// <summary>
/// One tab of the row (design header-and-tab-row.md §3.1-3.3, ported from TabItem, App/Window/TabStrip.swift): its icon
/// in the 16 epx slot, the title centered (the close slot balances the icon's) and cut with "…", and the close button,
/// shown only while hovered. A pinned tab shows its icon alone, with no close button. Unselected, a capsule fill shows
/// on hover (white 0.06) or in the multi-selection (0.08), stopping 4.5 epx above the row's bottom; the selected tab
/// has none: the sheet's joined shape (MainWindow's SheetPath) is its fill. Its presses (a left press selects it at once,
/// click-first rule; Shift/Ctrl multi-select; drag; middle-click close) go through the strip's
/// <see cref="TabDragController"/>; the strip places it and draws every outline around it.
/// </summary>
internal sealed partial class TabItemView : Grid
{
    private readonly TabStrip _strip;
    private readonly Border _fill;
    private readonly Grid _row;
    private readonly TabIcon _icon;
    private readonly TextBlock _title;
    private readonly Button _close;
    private TabItemState? _state;
    private bool _hovered;

    public TabItemView(TabStrip strip, Guid id)
    {
        _strip = strip;
        Id = id;
        double height = PaletteResources.Double("TabHeight");
        double bottomInset = PaletteResources.Double("TabRowBottomInset");
        double slot = PaletteResources.Double("TabSlot");
        double padding = PaletteResources.Double("TabPadding");
        Height = height;

        // A background, even transparent, makes the whole tab hit-testable, not only its text.
        Background = new SolidColorBrush(Colors.Transparent);
        // In the row's focus group (TabKeyboard); the ring is drawn inside the tab band, which the strip's clip keeps.
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        FocusVisualMargin = new Thickness(1, 1, 1, bottomInset);
        _fill = new Border
        {
            Margin = new Thickness(0, 0, 0, bottomInset),
            CornerRadius = new CornerRadius((height - bottomInset) / 2),
            BackgroundTransition = new BrushTransition { Duration = PaletteResources.TimeSpan("MotionHoverDuration") },
            IsHitTestVisible = false,
        };

        _icon = new TabIcon { VerticalAlignment = VerticalAlignment.Center };
        _title = new TextBlock
        {
            FontSize = PaletteResources.Double("TabTitleFontSize"),
            HorizontalAlignment = HorizontalAlignment.Center,
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
            // The tab is the row's focus stop; Delete closes it from the keyboard.
            IsTabStop = false,
            Content = new FontIcon { Glyph = "", FontSize = PaletteResources.Double("TabCloseGlyphSize") },
        };
        TabStrip.StyleButton(_close, new SolidColorBrush(Colors.Transparent), PaletteResources.Brush("HoverFillBrush"),
            PaletteResources.Brush("PressedFillBrush"));
        _close.Resources["ButtonForeground"] = PaletteResources.Brush("TabTitleBrush");
        _close.Resources["ButtonForegroundPointerOver"] = PaletteResources.Brush("TabTitleSelectedBrush");
        _close.Resources["ButtonForegroundPressed"] = PaletteResources.Brush("TabTitleSelectedBrush");
        ToolTipService.SetToolTip(_close, "Close Tab");
        _close.Click += (_, _) => _strip.CloseTab(Id);

        _row = new Grid
        {
            Padding = new Thickness(padding, 0, padding, 0),
            ColumnSpacing = PaletteResources.Double("TabSlotSpacing"),
        };
        _row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(slot) });
        _row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(slot) });
        SetColumn(_title, 1);
        SetColumn(_close, 2);
        _row.Children.Add(_icon);
        _row.Children.Add(_title);
        _row.Children.Add(_close);

        Children.Add(_fill);
        Children.Add(_row);

        PointerEntered += (_, _) => SetHovered(true);
        PointerExited += (_, _) => SetHovered(false);
        PointerCanceled += (_, _) => SetHovered(false);
    }

    public Guid Id { get; }

    internal TabStrip Strip => _strip;

    public bool IsSelected => _state?.Selected == true;

    public void Update(TabItemState state)
    {
        if (_state == state)
            return;
        bool wasSelected = IsSelected;
        _state = state;

        _icon.Update(state.Icon);
        _title.Text = state.Title;
        _title.Foreground = PaletteResources.Brush(state.Selected ? "TabTitleSelectedBrush" : "TabTitleBrush");
        _title.Visibility = state.Pinned ? Visibility.Collapsed : Visibility.Visible;
        SetColumnSpan(_icon, state.Pinned ? 3 : 1);
        _icon.HorizontalAlignment = state.Pinned ? HorizontalAlignment.Center : HorizontalAlignment.Left;
        AutomationProperties.SetName(this, state.Name);
        AutomationProperties.SetName(_close, $"Close {state.Title}");
        ToolTipService.SetToolTip(this, state.ToolTip);
        Refresh();

        if (wasSelected != state.Selected && AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged)
            && FrameworkElementAutomationPeer.FromElement(this) is { } peer)
            peer.RaisePropertyChangedEvent(SelectionItemPatternIdentifiers.IsSelectedProperty, wasSelected, state.Selected);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new TabItemAutomationPeer(this);

    private void SetHovered(bool hovered)
    {
        if (_hovered == hovered)
            return;
        _hovered = hovered;
        Refresh();
    }

    /// <summary>The fill and the close button for the current state and hover.</summary>
    private void Refresh()
    {
        TabItemState? state = _state;
        bool selected = state?.Selected == true;
        _fill.Background = selected ? null
            : state?.MultiSelected == true ? TabColors.Brush(PaletteResources.Color("MultiSelectFillColor"))
            : _hovered ? PaletteResources.Brush("TabFillBrush")
            : null;
        _close.Visibility = _hovered && state is { Pinned: false } ? Visibility.Visible : Visibility.Collapsed;
    }
}

/// <summary>A tab in UI Automation: a TabItem with the SelectionItem pattern, so vmpal_tree sees which is selected.</summary>
internal sealed partial class TabItemAutomationPeer : FrameworkElementAutomationPeer, ISelectionItemProvider
{
    private readonly TabItemView _tab;

    public TabItemAutomationPeer(TabItemView owner)
        : base(owner) => _tab = owner;

    public bool IsSelected => _tab.IsSelected;

    public IRawElementProviderSimple SelectionContainer =>
        ProviderFromPeer(FrameworkElementAutomationPeer.CreatePeerForElement(_tab.Strip));

    public void AddToSelection() => Select();

    /// <summary>Single selection with one tab always selected, so a selected tab cannot be unselected.</summary>
    public void RemoveFromSelection()
    {
        if (_tab.IsSelected)
            throw new InvalidOperationException("A tab strip always keeps one tab selected.");
    }

    public void Select() => _tab.Strip.Select(_tab.Id);

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.SelectionItem ? this : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.TabItem;

    protected override string GetClassNameCore() => nameof(TabItemView);

    protected override bool IsControlElementCore() => true;

    protected override bool IsKeyboardFocusableCore() => true;

    protected override bool HasKeyboardFocusCore() => Owner.FocusState != FocusState.Unfocused;

    protected override void SetFocusCore() => TabKeyboard.FocusFromAutomation(Owner);
}

/// <summary>
/// A manual group's chip before its first tab (design §3.4, TabGroupChip in App/Window/TabStrip.swift): 22 epx tall,
/// radius 6, the group color at 0.38, its name in white 11 semibold (an unnamed group is a color square); collapsed, its
/// tab count is appended ("Docs · 3"). A click toggles the collapse on release and a drag moves the whole group (the
/// strip's <see cref="TabDragController"/>); its flyout is task 10.2. UI Automation: a Button with the ExpandCollapse
/// pattern.
/// </summary>
internal sealed partial class GroupChipView : Grid
{
    private readonly TabStrip _strip;
    private readonly TextBlock _text;

    public GroupChipView(TabStrip strip, Guid id)
    {
        _strip = strip;
        GroupId = id;
        Height = PaletteResources.Double("ChipHeight");
        CornerRadius = (CornerRadius)Application.Current.Resources["ChipCornerRadius"];
        // In the row's focus group (TabKeyboard); the ring goes round the chip, inside the 36 epx band.
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        FocusVisualMargin = new Thickness(-2);
        _text = new TextBlock
        {
            FontSize = PaletteResources.Double("ChipFontSize"),
            FontWeight = FontWeights.SemiBold,
            Foreground = TabColors.Brush(PaletteResources.Color("GraphBadgeTextColor")),
            HorizontalAlignment = HorizontalAlignment.Center,
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

    internal TabStrip Strip => _strip;

    /// <param name="text">The chip's text: the name, with the count while collapsed; empty for a plain square.</param>
    /// <param name="name">Its UI Automation name ("Group Docs, 3 tabs").</param>
    public void Update(string text, Color color, string name, string toolTip, bool collapsed)
    {
        bool wasCollapsed = IsCollapsed;
        IsCollapsed = collapsed;
        _text.Text = text;
        Padding = new Thickness(text.Length == 0 ? 0 : PaletteResources.Double("ChipPadding"), 0,
            text.Length == 0 ? 0 : PaletteResources.Double("ChipPadding"), 0);
        Background = TabColors.Fill(color);
        AutomationProperties.SetName(this, name);
        ToolTipService.SetToolTip(this, toolTip);

        if (wasCollapsed != collapsed && AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged)
            && FrameworkElementAutomationPeer.FromElement(this) is { } peer)
            peer.RaisePropertyChangedEvent(ExpandCollapsePatternIdentifiers.ExpandCollapseStateProperty,
                State(wasCollapsed), State(collapsed));
    }

    internal static ExpandCollapseState State(bool collapsed) =>
        collapsed ? ExpandCollapseState.Collapsed : ExpandCollapseState.Expanded;

    protected override AutomationPeer OnCreateAutomationPeer() => new GroupChipAutomationPeer(this);
}

/// <summary>A chip in UI Automation: a Button that reports its group Collapsed or Expanded.</summary>
internal sealed partial class GroupChipAutomationPeer : FrameworkElementAutomationPeer, IExpandCollapseProvider, IInvokeProvider
{
    private readonly GroupChipView _chip;

    public GroupChipAutomationPeer(GroupChipView owner)
        : base(owner) => _chip = owner;

    public ExpandCollapseState ExpandCollapseState => GroupChipView.State(_chip.IsCollapsed);

    public void Collapse()
    {
        if (!_chip.IsCollapsed)
            _chip.Strip.ToggleGroup(_chip.GroupId);
    }

    public void Expand()
    {
        if (_chip.IsCollapsed)
            _chip.Strip.ToggleGroup(_chip.GroupId);
    }

    public void Invoke() => _chip.Strip.ToggleGroup(_chip.GroupId);

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface is PatternInterface.ExpandCollapse or PatternInterface.Invoke
            ? this
            : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;

    protected override string GetClassNameCore() => nameof(GroupChipView);

    protected override bool IsControlElementCore() => true;

    protected override bool IsKeyboardFocusableCore() => true;

    protected override bool HasKeyboardFocusCore() => Owner.FocusState != FocusState.Unfocused;

    protected override void SetFocusCore() => TabKeyboard.FocusFromAutomation(Owner);
}

/// <summary>
/// The head at a worktree box's start (design §3.5, a Windows addition): a 20 epx part of the box with a 12 epx branch
/// glyph at white 0.45; its tooltip names the repository and the count. A press selects the box's first tab and a drag
/// moves the whole box (the strip's <see cref="TabDragController"/>). UI Automation: a Button.
/// </summary>
internal sealed partial class WorktreeHeadView : Grid
{
    private readonly TabStrip _strip;

    public WorktreeHeadView(TabStrip strip)
    {
        _strip = strip;
        Width = PaletteResources.Double("WorktreeHeadWidth");
        Background = new SolidColorBrush(Colors.Transparent);
        // In the row's focus group (TabKeyboard); the ring is drawn inside the head.
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        FocusVisualMargin = new Thickness(1);
        double size = PaletteResources.Double("WorktreeHeadGlyphSize");
        Children.Add(new Path
        {
            Width = size,
            Height = size,
            Data = BranchGlyph(size),
            Stroke = PaletteResources.Brush("WorktreeHeadGlyphBrush"),
            StrokeThickness = size / 10,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
        });
    }

    /// <summary>The box's first tab, which a click selects.</summary>
    public Guid FirstTab { get; private set; }

    /// <summary>The box's repository key (<see cref="Histq.Core.WorktreeBox.Key"/>): a drag moves the whole box.</summary>
    public string BoxKey { get; private set; } = string.Empty;

    internal TabStrip Strip => _strip;

    public void Update(Guid firstTab, string boxKey, string name)
    {
        FirstTab = firstTab;
        BoxKey = boxKey;
        AutomationProperties.SetName(this, name);
        ToolTipService.SetToolTip(this, name);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new WorktreeHeadAutomationPeer(this);

    /// <summary>A branch mark drawn in a <paramref name="size"/> square: two commits on a line, a third branching off
    /// (drawn, so it needs no icon font codepoint).</summary>
    private static Geometry BranchGlyph(double size)
    {
        double u = size / 12;
        double r = 1.6 * u;
        var group = new GeometryGroup();
        group.Children.Add(new EllipseGeometry { Center = new Point(3.5 * u, 2.5 * u), RadiusX = r, RadiusY = r });
        group.Children.Add(new EllipseGeometry { Center = new Point(3.5 * u, 9.5 * u), RadiusX = r, RadiusY = r });
        group.Children.Add(new EllipseGeometry { Center = new Point(8.5 * u, 2.5 * u), RadiusX = r, RadiusY = r });
        group.Children.Add(new LineGeometry
        {
            StartPoint = new Point(3.5 * u, 2.5 * u + r),
            EndPoint = new Point(3.5 * u, 9.5 * u - r),
        });
        var branch = new PathFigure { StartPoint = new Point(8.5 * u, 2.5 * u + r), IsFilled = false };
        branch.Segments.Add(new BezierSegment
        {
            Point1 = new Point(8.5 * u, 6.5 * u),
            Point2 = new Point(3.5 * u, 5.5 * u),
            Point3 = new Point(3.5 * u, 8 * u),
        });
        var path = new PathGeometry();
        path.Figures.Add(branch);
        group.Children.Add(path);
        return group;
    }
}

/// <summary>A worktree head in UI Automation: a Button that selects the box's first tab.</summary>
internal sealed partial class WorktreeHeadAutomationPeer : FrameworkElementAutomationPeer, IInvokeProvider
{
    private readonly WorktreeHeadView _head;

    public WorktreeHeadAutomationPeer(WorktreeHeadView owner)
        : base(owner) => _head = owner;

    public void Invoke() => _head.Strip.Select(_head.FirstTab);

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.Invoke ? this : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;

    protected override string GetClassNameCore() => nameof(WorktreeHeadView);

    protected override bool IsControlElementCore() => true;

    protected override bool IsKeyboardFocusableCore() => true;

    protected override bool HasKeyboardFocusCore() => Owner.FocusState != FocusState.Unfocused;

    protected override void SetFocusCore() => TabKeyboard.FocusFromAutomation(Owner);
}

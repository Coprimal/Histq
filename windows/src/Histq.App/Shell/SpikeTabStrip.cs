using Histq.App.Theme;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Histq.App.Shell;

/// <summary>
/// Phase 5 spike tab strip: six placeholder tabs ("Tab 1" ... "Tab 6", 160 x 36, gap 5) in the title bar row. A press
/// selects a tab on pointer-down (click-first rule), and <see cref="SelectionChanged"/> fires synchronously so the
/// joined sheet (<see cref="SheetTabShape"/>) moves under it in the same frame. Placeholder visuals only: the final
/// tab row comes in phase 9 (design header-and-tab-row.md §3).
/// </summary>
public sealed partial class SpikeTabStrip : StackPanel
{
    private const int TabCount = 6;
    private const double TabWidth = 160;
    private const double TabHeight = 36;
    private const double TabGap = 5;

    private readonly SpikeTab[] _tabs;
    private int _selectedIndex;

    public SpikeTabStrip()
    {
        Orientation = Orientation.Horizontal;
        Spacing = TabGap;
        VerticalAlignment = VerticalAlignment.Bottom;

        Brush selectedText = PaletteResources.Brush("TabTitleSelectedBrush");
        Brush unselectedText = PaletteResources.Brush("TabTitleBrush");
        _tabs = new SpikeTab[TabCount];
        for (int i = 0; i < TabCount; i++)
        {
            var tab = new SpikeTab(this, i, $"Tab {i + 1}", selectedText, unselectedText)
            {
                Width = TabWidth,
                Height = TabHeight,
            };
            tab.PointerPressed += OnTabPointerPressed;
            _tabs[i] = tab;
            Children.Add(tab);
        }
        _tabs[0].IsSelected = true;
        Tabs = _tabs;

        SizeChanged += (_, _) => TitleBarRegions?.Refresh();
    }

    /// <summary>Raised synchronously, in the same input event, after <see cref="SelectedIndex"/> changes.</summary>
    public event EventHandler? SelectionChanged;

    /// <summary>The tab elements, left to right: the title bar's Passthrough rects.</summary>
    public IReadOnlyList<FrameworkElement> Tabs { get; }

    /// <summary>Refreshed after every selection or size change of the strip.</summary>
    internal TitleBarRegions? TitleBarRegions { get; set; }

    /// <summary>The selected tab, 0-based.</summary>
    public int SelectedIndex
    {
        get => _selectedIndex;
        set
        {
            ArgumentOutOfRangeException.ThrowIfNegative(value);
            ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(value, TabCount);
            if (value == _selectedIndex)
                return;

            _tabs[_selectedIndex].IsSelected = false;
            _selectedIndex = value;
            _tabs[value].IsSelected = true;
            SelectionChanged?.Invoke(this, EventArgs.Empty);
            TitleBarRegions?.Refresh();
        }
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new SpikeTabStripAutomationPeer(this);

    private void OnTabPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        // A middle press will close a tab without selecting it (phase 9); every other press selects at once.
        if (sender is not SpikeTab tab || e.GetCurrentPoint(tab).Properties.IsMiddleButtonPressed)
            return;
        SelectedIndex = tab.Index;
        e.Handled = true;
    }
}

/// <summary>A placeholder tab: its title centered, full white when selected, 0.60 white otherwise.</summary>
internal sealed partial class SpikeTab : Grid
{
    private readonly TextBlock _title;
    private readonly Brush _selectedText;
    private readonly Brush _unselectedText;
    private bool _isSelected;

    public SpikeTab(SpikeTabStrip strip, int index, string title, Brush selectedText, Brush unselectedText)
    {
        Strip = strip;
        Index = index;
        _selectedText = selectedText;
        _unselectedText = unselectedText;

        // A background, even transparent, makes the whole tab hit-testable, not only its text.
        Background = new SolidColorBrush(Colors.Transparent);
        AutomationProperties.SetName(this, title);
        _title = new TextBlock
        {
            Text = title,
            FontSize = 13,
            Foreground = unselectedText,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            IsHitTestVisible = false,
        };
        Children.Add(_title);
    }

    public SpikeTabStrip Strip { get; }

    public int Index { get; }

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (value == _isSelected)
                return;
            _isSelected = value;
            _title.Foreground = value ? _selectedText : _unselectedText;
            if (AutomationPeer.ListenerExists(AutomationEvents.PropertyChanged)
                && FrameworkElementAutomationPeer.FromElement(this) is { } peer)
                peer.RaisePropertyChangedEvent(SelectionItemPatternIdentifiers.IsSelectedProperty, !value, value);
        }
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new SpikeTabAutomationPeer(this);
}

/// <summary>The strip in UI Automation: a Tab control holding the tab items.</summary>
internal sealed partial class SpikeTabStripAutomationPeer(SpikeTabStrip owner) : FrameworkElementAutomationPeer(owner)
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Tab;

    protected override string GetClassNameCore() => nameof(SpikeTabStrip);

    protected override bool IsControlElementCore() => true;
}

/// <summary>A tab in UI Automation: a TabItem with the SelectionItem pattern, so vmpal_tree sees which is selected.</summary>
internal sealed partial class SpikeTabAutomationPeer : FrameworkElementAutomationPeer, ISelectionItemProvider
{
    private readonly SpikeTab _tab;

    public SpikeTabAutomationPeer(SpikeTab owner)
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

    public void Select() => _tab.Strip.SelectedIndex = _tab.Index;

    protected override object GetPatternCore(PatternInterface patternInterface) =>
        patternInterface == PatternInterface.SelectionItem ? this : base.GetPatternCore(patternInterface);

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.TabItem;

    protected override string GetClassNameCore() => nameof(SpikeTab);

    protected override bool IsControlElementCore() => true;
}

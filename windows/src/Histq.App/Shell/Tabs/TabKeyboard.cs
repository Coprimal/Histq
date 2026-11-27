using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI.Core;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// The tab row's keyboard (design header-and-tab-row.md §3.12, a Windows addition): the row is one focus group, one Tab
/// stop (<see cref="KeyboardNavigationMode.Once"/>) that lands on the selected tab when it comes from outside the row.
/// Left / Right move the focus through <see cref="TabStrip.FocusOrder"/> (the stow buttons, the popped-out archived tab,
/// the pinned well, the track's chips, worktree heads and tabs, New Tab and All Tabs, as drawn), the track scrolling
/// the focused item into view. Enter selects a tab, collapses or shows a chip's group, and selects a worktree head's
/// first tab; Delete closes the focused tab (as its middle click does). Shift+F10 and the Menu key open the focused
/// item's context menu once task 10.1 brings it; until then they are swallowed, so no system menu shows. A left press
/// on an item focuses it without a focus ring (ListView-like), so the arrows then go on from there. When a sync
/// removes or hides the focused item, the focus moves to the nearest item still shown.
/// </summary>
internal sealed class TabKeyboard
{
    private readonly TabStrip _strip;

    // The focus as it stood when a sync began: the row's items then, the focused one's place and its focus state.
    private List<FrameworkElement>? _syncOrder;
    private int _syncIndex;
    private FocusState _syncState;

    /// <summary>Focused by a sync, before the new layout placed it: revealed again once it is laid out.</summary>
    private FrameworkElement? _revealAfterLayout;

    public TabKeyboard(TabStrip strip)
    {
        _strip = strip;
        strip.TabFocusNavigation = KeyboardNavigationMode.Once;
        strip.XYFocusKeyboardNavigation = XYFocusKeyboardNavigationMode.Disabled;
        strip.GettingFocus += OnGettingFocus;
        strip.GotFocus += OnGotFocus;
        strip.PreviewKeyDown += OnPreviewKeyDown;
        strip.KeyDown += OnKeyDown;
        strip.ContextRequested += OnContextRequested;
    }

    /// <summary>A tab, chip or worktree head: a left press focuses it (no ring), after the drag controller's own
    /// handling, which it leaves as it is.</summary>
    public void Attach(FrameworkElement item) =>
        item.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnItemPressed), handledEventsToo: true);

    /// <summary>UI Automation's SetFocus on an item: a keyboard focus, so its ring shows and the arrows go on from it.
    /// </summary>
    internal static void FocusFromAutomation(UIElement item) => item.Focus(FocusState.Keyboard);

    /// <summary>Called as <see cref="TabStrip.Sync"/> begins: notes the focused item, if the row holds the focus.</summary>
    public void BeforeSync()
    {
        _syncOrder = null;
        if (FocusedItem() is not { } item)
            return;
        List<FrameworkElement> order = [.. _strip.FocusOrder()];
        int index = order.IndexOf(item);
        if (index < 0)
            return;
        _syncOrder = order;
        _syncIndex = index;
        _syncState = item.FocusState;
    }

    /// <summary>Called as <see cref="TabStrip.Sync"/> ends: an item that lost the focus gets it back (it moved from the
    /// track to the well or the lead), or its nearest neighbour still shown takes it (it closed, or its group
    /// collapsed): first the items after it, then those before.</summary>
    public void AfterSync()
    {
        if (_syncOrder is not { } order)
            return;
        _syncOrder = null;
        FrameworkElement item = order[_syncIndex];
        if (item.FocusState != FocusState.Unfocused && IsShown(item))
            return;

        // A closed tab hands the focus to the nearest tab, so Delete can go on closing.
        Func<FrameworkElement, bool> tab = element => element is TabItemView && IsShown(element);
        FrameworkElement? next = IsShown(item) ? item
            : (item is TabItemView ? Nearest(order, tab) : null) ?? Nearest(order, IsShown);
        if (next is null)
            return;
        _revealAfterLayout = next;
        next.Focus(_syncState == FocusState.Unfocused ? FocusState.Programmatic : _syncState);
    }

    /// <summary>The first item after the noted one that <paramref name="fits"/>, else the last one before it.</summary>
    private FrameworkElement? Nearest(List<FrameworkElement> order, Func<FrameworkElement, bool> fits) =>
        order.Skip(_syncIndex + 1).FirstOrDefault(fits) ?? order.Take(_syncIndex).LastOrDefault(fits);

    /// <summary>Called by the strip's arrange, once the new layout has placed the items: scrolls an item a sync focused
    /// into view (its old place would not do).</summary>
    public void Arranged()
    {
        if (_revealAfterLayout is not { } item)
            return;
        _revealAfterLayout = null;
        if (item.FocusState is FocusState.Keyboard or FocusState.Programmatic)
            _strip.RevealItem(item);
    }

    private bool IsShown(FrameworkElement item) =>
        item.Visibility == Visibility.Visible && item.Parent is not null && _strip.FocusOrder().Contains(item);

    /// <summary>The row's item that has the focus, if any.</summary>
    private FrameworkElement? FocusedItem() =>
        _strip.XamlRoot is { } root && FocusManager.GetFocusedElement(root) is FrameworkElement focused
            && _strip.FocusOrder().Contains(focused)
            ? focused
            : null;

    /// <summary>Tab or Shift+Tab into the row from outside it lands on the selected tab (the first item when it is not
    /// shown), not on whichever item the framework picks.</summary>
    private void OnGettingFocus(UIElement sender, GettingFocusEventArgs e)
    {
        if (e.Direction is not (FocusNavigationDirection.Next or FocusNavigationDirection.Previous)
            || IsInRow(e.OldFocusedElement))
            return;
        FrameworkElement? entry = _strip.SelectedItem() ?? _strip.FocusOrder().FirstOrDefault();
        if (entry is not null && !ReferenceEquals(entry, e.NewFocusedElement))
            e.TrySetNewFocusedElement(entry);
    }

    /// <summary>Scrolls a track item focused from the keyboard (or UI Automation) into view; a press does not, so the
    /// track never scrolls under a press that may become a drag.</summary>
    private void OnGotFocus(object sender, RoutedEventArgs e)
    {
        // An item a sync focused waits for its new place (Arranged).
        if (e.OriginalSource is FrameworkElement { FocusState: FocusState.Keyboard or FocusState.Programmatic } item
            && !ReferenceEquals(item, _revealAfterLayout) && _strip.FocusOrder().Contains(item))
            _strip.RevealItem(item);
    }

    /// <summary>Shift+F10 and the Menu key, taken on the way down so no other handler (the F10 app menu, the system
    /// menu) sees them. They open the focused item's context menu once task 10.1 brings the tab, chip and head menus;
    /// until then nothing opens.</summary>
    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        bool menuKey = e.Key == VirtualKey.Application
            || (e.Key == VirtualKey.F10 && IsDown(VirtualKey.Shift) && !IsDown(VirtualKey.Control)
                && !IsDown(VirtualKey.Menu));
        if (menuKey && FocusedItem() is not null)
            e.Handled = true;
    }

    /// <summary>A context menu asked for from the keyboard by another route: nothing opens until task 10.1. A right
    /// click is left alone.</summary>
    private void OnContextRequested(UIElement sender, ContextRequestedEventArgs e)
    {
        if (!e.TryGetPosition(_strip, out _))
            e.Handled = true;
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_strip.PressHeld || IsDown(VirtualKey.Control) || IsDown(VirtualKey.Shift) || IsDown(VirtualKey.Menu)
            || IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows)
            || e.OriginalSource is not FrameworkElement item)
            return;

        switch (e.Key)
        {
            case VirtualKey.Left:
            case VirtualKey.Right:
                List<FrameworkElement> order = [.. _strip.FocusOrder()];
                int index = order.IndexOf(item);
                if (index < 0)
                    return;
                e.Handled = true;
                int next = index + (e.Key == VirtualKey.Right ? 1 : -1);
                if (next >= 0 && next < order.Count)
                    order[next].Focus(FocusState.Keyboard);
                break;
            case VirtualKey.Enter when !e.KeyStatus.WasKeyDown:
                e.Handled = Activate(item);
                break;
            case VirtualKey.Delete when !e.KeyStatus.WasKeyDown && item is TabItemView tab && tab.Strip == _strip:
                e.Handled = true;
                _strip.CloseTab(tab.Id);
                break;
        }
    }

    /// <summary>Enter: a tab is selected (a plain click's pick), a chip's group collapses or shows, a worktree head
    /// selects its box's first tab. The buttons take Enter themselves.</summary>
    private bool Activate(FrameworkElement item)
    {
        switch (item)
        {
            case TabItemView tab when tab.Strip == _strip:
                _strip.Pick(tab.Id, TabPress.Plain);
                return true;
            case GroupChipView chip when chip.Strip == _strip:
                _strip.ToggleGroup(chip.GroupId);
                return true;
            case WorktreeHeadView head when head.Strip == _strip:
                _strip.Pick(head.FirstTab, TabPress.Plain);
                return true;
            default:
                return false;
        }
    }

    private void OnItemPressed(object sender, PointerRoutedEventArgs e)
    {
        if (sender is FrameworkElement item && e.GetCurrentPoint(item).Properties.IsLeftButtonPressed
            && item.Visibility == Visibility.Visible && item.Parent is not null)
            item.Focus(FocusState.Pointer);
    }

    private bool IsInRow(DependencyObject? element)
    {
        for (DependencyObject? node = element; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (ReferenceEquals(node, _strip))
                return true;
        }

        return false;
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
}

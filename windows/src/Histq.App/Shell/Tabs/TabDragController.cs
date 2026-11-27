using Histq.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Histq.App.Shell.Tabs;

/// <summary>What a mouse-down on a tab does (TabPress, App/Window/TabStrip.swift), from the keys held as it goes down:
/// Ctrl for the Mac's Cmd.</summary>
internal enum TabPress
{
    /// <summary>Ends the multi-selection and selects the tab.</summary>
    Plain,

    /// <summary>Shift: extends the multi-selection to the tab; the shown tab stays.</summary>
    Extend,

    /// <summary>Ctrl: adds the tab to the multi-selection or takes it out; the shown tab stays.</summary>
    Toggle,
}

/// <summary>
/// A tab drag (TabDrag, App/Window/TabStrip.swift): what it moves (a tab, a worktree box or a whole group), its tabs'
/// indices before it moves, where it would land (its first tab's index once moved, and the group it would be in, from
/// <see cref="TabGroupSpans.DragTarget"/>), the group it started in, and how far the pointer moved along the row.
/// </summary>
internal sealed record TabDrag(
    TabArrangement.Unit Unit, (int First, int Last) Range, int Index, Guid? Group, Guid? Origin, double Translation);

/// <summary>
/// The view that shows a window's tabs, which the tab menus and the row's flyouts act through: the title bar's
/// <see cref="TabStrip"/> or the <see cref="VerticalTabsPanel"/> (<see cref="Vertical"/>).
/// </summary>
internal interface ITabsView
{
    MainWindow? Window { get; }

    /// <summary>The tabs as last synced.</summary>
    WindowTabs? Model { get; }

    /// <summary>The vertical panel: its menus say "Below" for "to the Right", its flyouts open to the trailing side.</summary>
    bool Vertical { get; }

    void CloseTab(Guid id);

    /// <summary>A group just made: its flyout opens once its chip or header is placed.</summary>
    void ShowGroupFlyoutWhenPlaced(Guid id);

    /// <summary>A flyout of the view closed.</summary>
    void OnFlyoutClosed();
}

/// <summary>
/// A view whose tabs a <see cref="TabDragController"/> presses and drags, along its axis (<see cref="ITabsView.Vertical"/>:
/// down the list, else along the row).
/// </summary>
internal interface ITabDragHost : ITabsView
{
    XamlRoot? XamlRoot { get; }

    /// <summary>The tabs' spans and their positions at rest, as last laid out; null before the first layout.</summary>
    (TabGroupSpans Spans, TabGroupSpans.Positions Positions)? DragLayout { get; }

    void Pick(Guid id, TabPress press);

    void ToggleGroup(Guid id);

    /// <summary>A press on it picks it alone and it never drags (the popped-out archived tab, a pinned cell).</summary>
    bool PressesAlone(Guid id);

    /// <summary>The canvas a pressed element's pointer is measured in; null for an element that never drags.</summary>
    UIElement? SpaceOf(FrameworkElement element);

    /// <summary>A position along the axis in <paramref name="space"/> (<see cref="SpaceOf"/>) in the spans' space.</summary>
    double SpansPosition(UIElement space, double along);

    void SetPressHeld(bool held);

    void ShowDrag(TabDrag drag);

    void SnapBack(TabDrag drag);

    void EndDrag();
}

/// <summary>
/// Presses and drags in the tab row (design header-and-tab-row.md §3.10, ported from TabStrip.press, chipPress,
/// startDrag, retarget and drop in App/Window/TabStrip.swift at 6fa6d40), and down the vertical tabs' list (press,
/// headerPress, startDrag, retarget and drop in App/Window/VerticalTabsPanel.swift): the same logic along the host's
/// axis (<see cref="ITabDragHost"/>), a row for a tab, a header for a chip. A left press on a tab picks it at once
/// (<see cref="TabPress"/>; click-first rule), one on a worktree head selects its box's first tab, one on a chip does
/// nothing yet. Past <see cref="Threshold"/> along the row the press drags a <see cref="TabArrangement.Unit"/> to the
/// allowed place nearest the pointer (<see cref="TabGroupSpans.DragTarget"/>): a tab (a Shift/Ctrl press turns into a
/// plain drag of the tab, selected alone), a box from its head, a group from its chip. A box's tab reorders inside its
/// box until the pointer leaves the box (as the box stands at rest), then drags the whole box. On release the unit
/// moves (<see cref="WindowTabs.MoveUnit"/>), or snaps back when it would land where it stands. Released outside the
/// window, a lone tab moves to the other Histq window under the pointer (<see cref="WindowManager.DropTarget"/>); a box,
/// a group, a refused move (its toast in this window) or no Histq window there snaps back. A chip released before the threshold collapses or shows its
/// group, on release (as on the Mac: a click must be told from a drag). A middle click on a tab closes it. The right
/// button is left alone (the tab's menu, task 10.1). While a press is held the title bar's Passthrough rects stay put.
/// A press on the popped-out archived tab or a vertical pinned cell picks it alone and never drags
/// (<see cref="ITabDragHost.PressesAlone"/>).
/// </summary>
internal sealed class TabDragController
{
    /// <summary>How far (epx) a press moves along the axis before it drags (TabStripMetrics.dragThreshold).</summary>
    public const double Threshold = 5;

    private readonly ITabDragHost _host;
    private Press? _press;

    /// <summary>The tab element a middle button went down on: its tab closes when the button comes up over it.</summary>
    private (FrameworkElement Element, Guid Id)? _middle;

    public TabDragController(ITabDragHost host) => _host = host;

    private enum Kind
    {
        Tab,
        Head,
        Chip,
    }

    /// <summary>Wires a tab's presses: pick, drag, middle-click close.</summary>
    public void Attach(TabItemView view) => AttachTab(view, view.Id);

    /// <summary>Wires a group chip's presses: a click toggles the group, a drag moves it.</summary>
    public void Attach(GroupChipView chip) => AttachGroup(chip, chip.GroupId);

    /// <summary>Wires a worktree head's presses: selects its box's first tab, a drag moves the box.</summary>
    public void Attach(WorktreeHeadView head) => AttachHead(head, () => head.FirstTab, () => head.BoxKey);

    /// <summary>Wires the presses of tab <paramref name="id"/>'s element (a strip tab, a vertical row or pinned cell):
    /// pick, drag, middle-click close.</summary>
    public void AttachTab(FrameworkElement view, Guid id)
    {
        view.PointerPressed += (_, e) => OnTabPressed(view, id, e);
        Wire(view);
    }

    /// <summary>Wires the presses of group <paramref name="id"/>'s chip or header: a click toggles the group, a drag
    /// moves it.</summary>
    public void AttachGroup(FrameworkElement chip, Guid id)
    {
        chip.PointerPressed += (_, e) =>
        {
            if (IsLeft(chip, e))
                Hold(chip, e, Kind.Chip, id, null);
        };
        Wire(chip);
    }

    /// <summary>Wires a worktree head's presses (its box's first tab and key as they are at the press): selects the
    /// first tab, a drag moves the box.</summary>
    public void AttachHead(FrameworkElement head, Func<Guid> firstTab, Func<string> boxKey)
    {
        head.PointerPressed += (_, e) =>
        {
            if (!IsLeft(head, e))
                return;
            Guid first = firstTab();
            Hold(head, e, Kind.Head, first, boxKey());
            _host.Pick(first, TabPress.Plain);
        };
        Wire(head);
    }

    /// <summary>The model changed under a drag (not through it): the drag ends where it stands, nothing moves.</summary>
    public void Cancel()
    {
        if (_press is not { Drag: not null } press)
            return;
        _press = null;
        _host.EndDrag();
        press.Element.ReleasePointerCaptures();
        _host.SetPressHeld(false);
    }

    private void Wire(FrameworkElement element)
    {
        element.PointerMoved += OnMoved;
        element.PointerReleased += OnReleased;
        element.PointerCaptureLost += OnCaptureLost;
    }

    private static bool IsLeft(UIElement element, PointerRoutedEventArgs e) =>
        e.GetCurrentPoint(element).Properties.IsLeftButtonPressed;

    private void OnTabPressed(FrameworkElement view, Guid id, PointerRoutedEventArgs e)
    {
        PointerPointProperties properties = e.GetCurrentPoint(view).Properties;
        if (properties.IsMiddleButtonPressed)
        {
            _middle = (view, id);
            e.Handled = true;
            return;
        }

        if (!properties.IsLeftButtonPressed)
            return;

        // The popped-out archived tab (and a vertical pinned cell) is never in a multi-selection and never drags:
        // Shift/Ctrl press it plainly.
        if (_host.PressesAlone(id))
        {
            e.Handled = true;
            _host.Pick(id, TabPress.Plain);
            return;
        }

        TabPress press = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control) ? TabPress.Toggle
            : e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift) ? TabPress.Extend
            : TabPress.Plain;
        // Held before the pick, so the selection the pick makes is revealed only once the press is let go (the list
        // never scrolls under a press that may become a drag).
        Press? held = Hold(view, e, Kind.Tab, id, null);
        _host.Pick(id, press);
        if (held is not null)
            held.Picked = press != TabPress.Plain;
    }

    /// <summary>The pointer's position along the host's axis in <paramref name="space"/>.</summary>
    private double Along(PointerRoutedEventArgs e, UIElement space)
    {
        Windows.Foundation.Point point = e.GetCurrentPoint(space).Position;
        return _host.Vertical ? point.Y : point.X;
    }

    /// <summary>Takes the pointer for a press that may turn into a drag; null when the element is not on a canvas that
    /// drags. A press still held from before (its release never came: its element went) is dropped first, so it never
    /// blocks this one (the Mac's <c>pressedID != id</c>).</summary>
    private Press? Hold(FrameworkElement element, PointerRoutedEventArgs e, Kind kind, Guid id, string? box)
    {
        e.Handled = true;
        if (_press is { } stale)
        {
            _press = null;
            if (stale.Drag is not null)
                _host.EndDrag();
            stale.Element.ReleasePointerCaptures();
            _host.SetPressHeld(false);
        }

        if (_host.SpaceOf(element) is not { } space || !element.CapturePointer(e.Pointer))
            return null;
        _press = new Press(element, e.Pointer.PointerId, space, Along(e, space), kind, id, box);
        _host.SetPressHeld(true);
        return _press;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_press is not { } press || e.Pointer.PointerId != press.PointerId)
            return;
        e.Handled = true;
        double along = Along(e, press.Space);
        if (press.Drag is null && (Math.Abs(along - press.Start) < Threshold || !Begin(press)))
            return;
        Retarget(press, along);
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_press is not { } press || e.Pointer.PointerId != press.PointerId)
        {
            if (_middle is { } middle && ReferenceEquals(sender, middle.Element)
                && e.GetCurrentPoint(middle.Element).Properties.PointerUpdateKind == PointerUpdateKind.MiddleButtonReleased)
            {
                e.Handled = true;
                _middle = null;
                _host.CloseTab(middle.Id);
            }

            return;
        }

        // Cleared first: releasing the capture raises PointerCaptureLost, which must find no press.
        _press = null;
        e.Handled = true;
        TabDrag? drag = null;
        bool outside = false;
        if (press.Drag is not null)
        {
            // Injected or fast drags may send few moves: aim at the release point once more.
            Retarget(press, Along(e, press.Space));
            drag = press.Drag;
            outside = OutsideWindow(e);
        }

        // Before the drop: a tab moved to another window takes its element out of this row, and may close the window.
        press.Element.ReleasePointerCapture(e.Pointer);
        _host.SetPressHeld(false);
        if (drag is not null)
            Drop(drag, outside);
        else if (press.Kind == Kind.Chip)
            _host.ToggleGroup(press.Id);
    }

    /// <summary>The capture went (Alt+Tab, a window over the pointer, an element removed): the drag snaps back.</summary>
    private void OnCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_press is not { } press || !ReferenceEquals(sender, press.Element))
            return;
        _press = null;
        if (press.Drag is { } drag)
            _host.SnapBack(drag);
        _host.SetPressHeld(false);
    }

    /// <summary>A drag of the press's unit begins where it stands, in its own group; false when there is nothing to drag.</summary>
    private bool Begin(Press press)
    {
        if (press.Kind == Kind.Tab && press.Picked)
        {
            // A Shift/Ctrl press turns into a plain drag: the dragged tab is always the selected one, alone.
            _host.Pick(press.Id, TabPress.Plain);
        }

        if (_host.Model is not { } model || _host.DragLayout is not { } layout)
            return false;
        TabArrangement.Unit unit = press.Kind switch
        {
            Kind.Chip => new TabArrangement.Unit.Group(press.Id),
            Kind.Head => new TabArrangement.Unit.Box(press.Box!),
            _ => new TabArrangement.Unit.Tab(press.Id),
        };
        IReadOnlyList<TabArrangement.Entry> entries = model.ArrangementEntries;
        if (TabGroupSpans.RangeOf(unit, entries) is not { } range)
            return false;
        Guid? group = layout.Spans.GroupOf(unit, entries);
        press.Drag = new TabDrag(unit, range, range.First, group, group, 0);
        return true;
    }

    /// <summary>Aims the drag at the place and group it would drop in with the pointer at <paramref name="along"/> (in
    /// the press's space, along the axis), and draws it there.</summary>
    private void Retarget(Press press, double along)
    {
        if (press.Drag is not { } drag || _host.Model is not { } model || _host.DragLayout is not { } layout)
            return;
        double translation = along - press.Start;
        IReadOnlyList<TabArrangement.Entry> entries = model.ArrangementEntries;
        TabDrag next = drag with { Translation = translation };

        // Once the pointer leaves its box (as the box stands at rest), a box's tab drags the whole box, to the drag's end.
        if (next.Unit is TabArrangement.Unit.Tab
            && layout.Spans.Boxes.FirstOrDefault(box => box.Contains(next.Range.First)) is { } box
            && layout.Spans.BoxSpan(box, layout.Positions) is { } span)
        {
            double pointer = _host.SpansPosition(press.Space, along);
            var whole = new TabArrangement.Unit.Box(box.Key);
            if ((pointer < span.Start || pointer > span.End) && TabGroupSpans.RangeOf(whole, entries) is { } range)
            {
                Guid? group = layout.Spans.GroupOf(whole, entries);
                next = new TabDrag(whole, range, range.First, group, group, translation);
            }
        }

        (int index, Guid? target) = layout.Spans.DragTarget(next.Unit, translation, next.Group, entries);
        next = next with { Index = index, Group = target };
        press.Drag = next;
        _host.ShowDrag(next);
    }

    /// <summary>
    /// Ends a drag (TabStrip.drop, TabDragOut): out of the window, a lone tab moves to the Histq window under the
    /// pointer, else it snaps back; inside, the unit moves when it would land elsewhere or in another group, else it
    /// snaps back.
    /// </summary>
    private void Drop(TabDrag drag, bool outside)
    {
        if (outside && _host.Window is { } source && drag.Unit is TabArrangement.Unit.Tab tab
            && source.Manager.DropTarget(source, drag.Unit) is { } destination)
        {
            // Without animation: the tab leaves this window.
            _host.EndDrag();
            source.Manager.MoveTab(tab.Id, source, destination);
            return;
        }

        if (outside || (drag.Index == drag.Range.First && drag.Group == drag.Origin) || _host.Window is not { } window)
        {
            _host.SnapBack(drag);
            return;
        }

        // Without animation before the move, so the tabs are placed at their new places directly.
        _host.EndDrag();
        window.Apply(model => model.MoveUnit(drag.Unit, drag.Index, drag.Group));
    }

    /// <summary>The pointer is outside the window's content (its XAML root) as the button comes up.</summary>
    private bool OutsideWindow(PointerRoutedEventArgs e)
    {
        if (_host.XamlRoot is not { } root)
            return false;
        Windows.Foundation.Point point = e.GetCurrentPoint(null).Position;
        return point.X < 0 || point.Y < 0 || point.X > root.Size.Width || point.Y > root.Size.Height;
    }

    /// <summary>A held press: the element that has the pointer, where it went down in <see cref="Space"/> (along the
    /// axis), and the drag once it passed the threshold.</summary>
    private sealed class Press(
        FrameworkElement element, uint pointerId, UIElement space, double start, Kind kind, Guid id, string? box)
    {
        public FrameworkElement Element { get; } = element;

        public uint PointerId { get; } = pointerId;

        /// <summary>The canvas the pointer is measured in (<see cref="ITabDragHost.SpaceOf"/>).</summary>
        public UIElement Space { get; } = space;

        public double Start { get; } = start;

        public Kind Kind { get; } = kind;

        /// <summary>The tab (a tab or head press) or the group (a chip press).</summary>
        public Guid Id { get; } = id;

        /// <summary>A head press's box key.</summary>
        public string? Box { get; } = box;

        /// <summary>A Shift/Ctrl press: a drag selects the tab alone first.</summary>
        public bool Picked { get; set; }

        public TabDrag? Drag { get; set; }
    }
}

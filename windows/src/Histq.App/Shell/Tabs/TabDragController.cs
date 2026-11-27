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
/// Presses and drags in the tab row (design header-and-tab-row.md §3.10, ported from TabStrip.press, chipPress,
/// startDrag, retarget and drop in App/Window/TabStrip.swift at 6fa6d40). A left press on a tab picks it at once
/// (<see cref="TabPress"/>; click-first rule), one on a worktree head selects its box's first tab, one on a chip does
/// nothing yet. Past <see cref="Threshold"/> along the row the press drags a <see cref="TabArrangement.Unit"/> to the
/// allowed place nearest the pointer (<see cref="TabGroupSpans.DragTarget"/>): a tab (a Shift/Ctrl press turns into a
/// plain drag of the tab, selected alone), a box from its head, a group from its chip. A box's tab reorders inside its
/// box until the pointer leaves the box (as the box stands at rest), then drags the whole box. On release the unit
/// moves (<see cref="WindowTabs.MoveUnit"/>), or snaps back when it would land where it stands or the pointer left the
/// window (moving a tab to another window is task 11.1). A chip released before the threshold collapses or shows its
/// group, on release (as on the Mac: a click must be told from a drag). A middle click on a tab closes it. The right
/// button is left alone (the tab's menu, task 10.1). While a press is held the title bar's Passthrough rects stay put.
/// </summary>
internal sealed class TabDragController
{
    /// <summary>How far (epx) a press moves along the row before it drags (TabStripMetrics.dragThreshold).</summary>
    public const double Threshold = 5;

    private readonly TabStrip _strip;
    private Press? _press;

    /// <summary>The tab a middle button went down on: it closes when the button comes up over it.</summary>
    private Guid? _middleTab;

    public TabDragController(TabStrip strip) => _strip = strip;

    private enum Kind
    {
        Tab,
        Head,
        Chip,
    }

    /// <summary>Wires a tab's presses: pick, drag, middle-click close.</summary>
    public void Attach(TabItemView view)
    {
        view.PointerPressed += (_, e) => OnTabPressed(view, e);
        Wire(view);
    }

    /// <summary>Wires a group chip's presses: a click toggles the group, a drag moves it.</summary>
    public void Attach(GroupChipView chip)
    {
        chip.PointerPressed += (_, e) =>
        {
            if (IsLeft(chip, e))
                Hold(chip, e, Kind.Chip, chip.GroupId, null);
        };
        Wire(chip);
    }

    /// <summary>Wires a worktree head's presses: selects its box's first tab, a drag moves the box.</summary>
    public void Attach(WorktreeHeadView head)
    {
        head.PointerPressed += (_, e) =>
        {
            if (!IsLeft(head, e))
                return;
            _strip.Pick(head.FirstTab, TabPress.Plain);
            Hold(head, e, Kind.Head, head.FirstTab, head.BoxKey);
        };
        Wire(head);
    }

    /// <summary>The model changed under a drag (not through it): the drag ends where it stands, nothing moves.</summary>
    public void Cancel()
    {
        if (_press is not { Drag: not null } press)
            return;
        _press = null;
        _strip.EndDrag();
        press.Element.ReleasePointerCaptures();
        _strip.SetPressHeld(false);
    }

    private void Wire(FrameworkElement element)
    {
        element.PointerMoved += OnMoved;
        element.PointerReleased += OnReleased;
        element.PointerCaptureLost += OnCaptureLost;
    }

    private static bool IsLeft(UIElement element, PointerRoutedEventArgs e) =>
        e.GetCurrentPoint(element).Properties.IsLeftButtonPressed;

    private void OnTabPressed(TabItemView view, PointerRoutedEventArgs e)
    {
        PointerPointProperties properties = e.GetCurrentPoint(view).Properties;
        if (properties.IsMiddleButtonPressed)
        {
            _middleTab = view.Id;
            e.Handled = true;
            return;
        }

        if (!properties.IsLeftButtonPressed)
            return;

        // The popped-out archived tab is never in a multi-selection and never drags: Shift/Ctrl press it plainly.
        if (_strip.IsPopped(view.Id))
        {
            e.Handled = true;
            _strip.Pick(view.Id, TabPress.Plain);
            return;
        }

        TabPress press = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control) ? TabPress.Toggle
            : e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift) ? TabPress.Extend
            : TabPress.Plain;
        _strip.Pick(view.Id, press);
        if (Hold(view, e, Kind.Tab, view.Id, null) is { } held)
            held.Picked = press != TabPress.Plain;
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
                _strip.EndDrag();
            stale.Element.ReleasePointerCaptures();
            _strip.SetPressHeld(false);
        }

        if (_strip.SpaceOf(element) is not { } space || !element.CapturePointer(e.Pointer))
            return null;
        _press = new Press(element, e.Pointer.PointerId, space, e.GetCurrentPoint(space).Position.X, kind, id, box);
        _strip.SetPressHeld(true);
        return _press;
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_press is not { } press || e.Pointer.PointerId != press.PointerId)
            return;
        e.Handled = true;
        double x = e.GetCurrentPoint(press.Space).Position.X;
        if (press.Drag is null && (Math.Abs(x - press.StartX) < Threshold || !Begin(press)))
            return;
        Retarget(press, x);
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_press is not { } press || e.Pointer.PointerId != press.PointerId)
        {
            if (sender is TabItemView view && _middleTab == view.Id
                && e.GetCurrentPoint(view).Properties.PointerUpdateKind == PointerUpdateKind.MiddleButtonReleased)
            {
                e.Handled = true;
                _middleTab = null;
                _strip.CloseTab(view.Id);
            }

            return;
        }

        // Cleared first: releasing the capture raises PointerCaptureLost, which must find no press.
        _press = null;
        e.Handled = true;
        if (press.Drag is not null)
        {
            // Injected or fast drags may send few moves: aim at the release point once more.
            Retarget(press, e.GetCurrentPoint(press.Space).Position.X);
            Drop(press.Drag!, OutsideWindow(e));
        }
        else if (press.Kind == Kind.Chip)
        {
            _strip.ToggleGroup(press.Id);
        }

        press.Element.ReleasePointerCapture(e.Pointer);
        _strip.SetPressHeld(false);
    }

    /// <summary>The capture went (Alt+Tab, a window over the pointer, an element removed): the drag snaps back.</summary>
    private void OnCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_press is not { } press || !ReferenceEquals(sender, press.Element))
            return;
        _press = null;
        if (press.Drag is { } drag)
            _strip.SnapBack(drag);
        _strip.SetPressHeld(false);
    }

    /// <summary>A drag of the press's unit begins where it stands, in its own group; false when there is nothing to drag.</summary>
    private bool Begin(Press press)
    {
        if (press.Kind == Kind.Tab && press.Picked)
        {
            // A Shift/Ctrl press turns into a plain drag: the dragged tab is always the selected one, alone.
            _strip.Pick(press.Id, TabPress.Plain);
        }

        if (_strip.Model is not { } model || _strip.Layout is not { } layout)
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

    /// <summary>Aims the drag at the place and group it would drop in with the pointer at <paramref name="x"/> (in the
    /// press's space), and draws it there.</summary>
    private void Retarget(Press press, double x)
    {
        if (press.Drag is not { } drag || _strip.Model is not { } model || _strip.Layout is not { } layout)
            return;
        double translation = x - press.StartX;
        IReadOnlyList<TabArrangement.Entry> entries = model.ArrangementEntries;
        TabDrag next = drag with { Translation = translation };

        // Once the pointer leaves its box (as the box stands at rest), a box's tab drags the whole box, to the drag's end.
        if (next.Unit is TabArrangement.Unit.Tab
            && layout.Boxes.FirstOrDefault(box => box.Contains(next.Range.First)) is { } box
            && layout.Spans.BoxSpan(box, layout.Positions) is { } span)
        {
            double pointer = _strip.SpansX(press.Space, x);
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
        _strip.ShowDrag(next);
    }

    /// <summary>
    /// Ends a drag (TabStrip.drop): out of the window it snaps back (a lone tab moves to another window in task 11.1);
    /// inside, the unit moves when it would land elsewhere or in another group, else it snaps back.
    /// </summary>
    private void Drop(TabDrag drag, bool outside)
    {
        if (outside || (drag.Index == drag.Range.First && drag.Group == drag.Origin) || _strip.Window is not { } window)
        {
            _strip.SnapBack(drag);
            return;
        }

        // Without animation before the move, so the tabs are placed at their new places directly.
        _strip.EndDrag();
        window.Apply(model => model.MoveUnit(drag.Unit, drag.Index, drag.Group));
    }

    /// <summary>The pointer is outside the window's content (its XAML root) as the button comes up.</summary>
    private bool OutsideWindow(PointerRoutedEventArgs e)
    {
        if (_strip.XamlRoot is not { } root)
            return false;
        Windows.Foundation.Point point = e.GetCurrentPoint(null).Position;
        return point.X < 0 || point.Y < 0 || point.X > root.Size.Width || point.Y > root.Size.Height;
    }

    /// <summary>A held press: the element that has the pointer, where it went down in <see cref="Space"/>, and the drag
    /// once it passed the threshold.</summary>
    private sealed class Press(
        FrameworkElement element, uint pointerId, UIElement space, double startX, Kind kind, Guid id, string? box)
    {
        public FrameworkElement Element { get; } = element;

        public uint PointerId { get; } = pointerId;

        /// <summary>The canvas the pointer is measured in (<see cref="TabStrip.SpaceOf"/>).</summary>
        public UIElement Space { get; } = space;

        public double StartX { get; } = startX;

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

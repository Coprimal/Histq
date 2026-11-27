using System.Globalization;
using Histq.App.Shell.Dialogs;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// A manual group's flyout from its chip (design header-and-tab-row.md §3.4, ported from TabGroupPopover,
/// App/Window/TabGroupPopover.swift at 6fa6d40): its name (live, focused when it opens, empty for none), its 9 swatches
/// (the current one ringed; a click recolors at once and the flyout stays), then New Tab in Group, Move Group to New
/// Window, Close Group (the window's closed groups keep it), Delete Group (asks first; Ctrl+Shift+T brings the tabs back)
/// and Ungroup. Move and Delete are off while the group holds every normal tab of the window. Enter in the name and Esc
/// close it. The rows that take the chip away (Move, Close, Delete, Ungroup) act once the flyout has closed, so the
/// focus is back on the row first. It opens on the chip's right click, Shift+F10 or Menu key, and after Add Tab(s) to New Group.
/// </summary>
internal sealed class GroupFlyout : TabFlyout
{
    /// <summary>A group's swatches: 0 grey, 1-8 the lanes.</summary>
    private const int SwatchCount = 9;

    private const double SwatchSize = 16;

    /// <summary>Why Delete Group and Move Group to New Window are off.</summary>
    private const string HoldsAllHelp = "The group holds every tab of the window.";

    // Segoe Fluent Icons: Add, NewWindow, Cancel, Delete, ClearSelection.
    private const string NewTabGlyph = "";
    private const string NewWindowGlyph = "";
    private const string CloseGlyph = "";
    private const string DeleteGlyph = "";
    private const string UngroupGlyph = "";

    private readonly List<(Button Button, Ellipse Ring)> _swatches = [];
    private Guid _groupId;
    private TextBox? _name;

    /// <summary>The name as last handed to the model (or seeded): TextChanged comes late and also after the seed.</summary>
    private string _sentName = string.Empty;

    private Button? _move;
    private Button? _delete;
    private FrameworkElement? _moveHolder;
    private FrameworkElement? _deleteHolder;

    public GroupFlyout(TabStrip strip)
        : base(strip, FlyoutPlacementMode.BottomEdgeAlignedLeft)
    {
    }

    /// <summary>Opens the flyout of group <paramref name="id"/> at its <paramref name="chip"/>.</summary>
    public void ShowFor(Guid id, FrameworkElement chip)
    {
        if (IsOpen)
            return;
        _groupId = id;
        ShowAt(chip);
    }

    protected override UIElement? Build(WindowTabs model)
    {
        if (model.Groups.FirstOrDefault(group => group.Id == _groupId) is not { } group)
            return null;

        StackPanel panel = Panel();
        // Seeded once: the model trims the name, so a field it wrote back would eat a space as it is typed.
        _sentName = DisplayText.Sanitize(group.Name);
        _name = new TextBox
        {
            Text = _sentName,
            PlaceholderText = "Name this group",
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            Margin = new Thickness(10, 0, 10, 0),
        };
        AutomationProperties.SetName(_name, "Group name");
        _name.TextChanged += (_, _) => OnNameChanged();
        _name.KeyDown += OnNameKeyDown;
        panel.Children.Add(_name);

        panel.Children.Add(Swatches());

        var rows = new StackPanel { Spacing = RowSpacing, Padding = new Thickness(10, 0, 10, 0) };
        rows.Children.Add(ActionRow("New Tab in Group", NewTabGlyph, null, NewTabInGroup));
        (_moveHolder, _move) = Holder(ActionRow("Move Group to New Window", NewWindowGlyph,
            "Its tabs open in a new window.", MoveToNewWindow));
        rows.Children.Add(_moveHolder);
        rows.Children.Add(ActionRow("Close Group", CloseGlyph, "Hide the group; reopen it from Closed Groups.",
            CloseGroup));
        (_deleteHolder, _delete) = Holder(ActionRow("Delete Group", DeleteGlyph,
            "Close the group and its tabs; Ctrl+Shift+T brings them back.", DeleteGroup));
        rows.Children.Add(_deleteHolder);
        rows.Children.Add(ActionRow("Ungroup", UngroupGlyph, null, Ungroup));
        panel.Children.Add(rows);

        Update(model);
        return panel;
    }

    protected override bool Update(WindowTabs model)
    {
        if (model.Groups.FirstOrDefault(group => group.Id == _groupId) is not { } group)
            return false;
        for (int index = 0; index < _swatches.Count; index++)
        {
            bool current = index == group.ColorIndex;
            _swatches[index].Ring.Visibility = current ? Visibility.Visible : Visibility.Collapsed;
            AutomationProperties.SetItemStatus(_swatches[index].Button, current ? "Current color" : string.Empty);
        }

        bool holdsAll = model.GroupHoldsAllNormalTabs(_groupId);
        SetBlocked(_move, _moveHolder, holdsAll, "Its tabs open in a new window.");
        SetBlocked(_delete, _deleteHolder, holdsAll, "Close the group and its tabs; Ctrl+Shift+T brings them back.");
        return true;
    }

    protected override void Opened()
    {
        // The name field takes the keyboard, its text selected, as the Mac's popover focuses it.
        _name?.Focus(FocusState.Programmatic);
        _name?.SelectAll();
    }

    // The name and the swatches.

    private void OnNameChanged()
    {
        if (_name is not { } field || string.Equals(field.Text, _sentName, StringComparison.Ordinal))
            return;
        _sentName = field.Text;
        Guid id = _groupId;
        string name = field.Text;
        Strip.Window?.Apply(model => model.SetGroupName(id, name));
    }

    /// <summary>Enter closes the flyout, as the Mac's Return does (Esc closes any flyout).</summary>
    private void OnNameKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
            return;
        e.Handled = true;
        Hide();
    }

    /// <summary>The 9 colors as circles spread over the row; the current one ringed.</summary>
    private Grid Swatches()
    {
        _swatches.Clear();
        var row = new Grid { Margin = new Thickness(10, 2, 10, 2) };
        AutomationProperties.SetName(row, "Group color");
        for (int index = 0; index < SwatchCount; index++)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            int color = index;
            var dot = new Grid { Width = SwatchSize + 6, Height = SwatchSize + 6 };
            dot.Children.Add(new Ellipse { Width = SwatchSize, Height = SwatchSize, Fill = GroupBrush(color) });
            var ring = new Ellipse
            {
                Stroke = TabColors.Brush(Colors.White),
                StrokeThickness = 1.5,
                Visibility = Visibility.Collapsed,
            };
            dot.Children.Add(ring);
            var button = new Button
            {
                Content = dot,
                Padding = new Thickness(0),
                MinWidth = 0,
                MinHeight = 0,
                HorizontalAlignment = HorizontalAlignment.Center,
                CornerRadius = new CornerRadius((SwatchSize + 6) / 2),
            };
            TabStrip.StyleButton(button, new SolidColorBrush(Colors.Transparent),
                PaletteResources.Brush("HoverFillBrush"), PaletteResources.Brush("PressedFillBrush"));
            string name = SwatchName(color);
            AutomationProperties.SetName(button, name);
            ToolTipService.SetToolTip(button, name);
            button.Click += (_, _) =>
            {
                Guid id = _groupId;
                Strip.Window?.Apply(model => model.SetGroupColor(id, color));
            };
            Grid.SetColumn(button, index);
            row.Children.Add(button);
            _swatches.Add((button, ring));
        }

        return row;
    }

    /// <summary>A swatch's name: Grey, then the lane colors' names.</summary>
    private static string SwatchName(int index) => index == 0 ? "Grey" : TabColors.LaneName(index - 1);

    // The actions.

    private Button ActionRow(string text, string glyph, string? help, Action action)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        content.Children.Add(RowGlyph(glyph));
        content.Children.Add(Title(text));
        Button button = Row(content, text, help);
        if (help is not null)
            AutomationProperties.SetHelpText(button, help);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>A row inside a holder that carries its tooltip while it is off (a disabled button shows none).</summary>
    private static (FrameworkElement Holder, Button Button) Holder(Button button)
    {
        var holder = new Grid { Background = new SolidColorBrush(Colors.Transparent) };
        holder.Children.Add(button);
        return (holder, button);
    }

    /// <summary>Turns a Move/Delete row off while the group holds every tab, with the reason as its tooltip and help.
    /// </summary>
    private static void SetBlocked(Button? button, FrameworkElement? holder, bool blocked, string help)
    {
        if (button is null || holder is null)
            return;
        button.IsEnabled = !blocked;
        // A disabled row does not dim by itself in this style.
        button.Opacity = blocked ? 0.45 : 1;
        string text = blocked ? HoldsAllHelp : help;
        ToolTipService.SetToolTip(button, text);
        ToolTipService.SetToolTip(holder, blocked ? HoldsAllHelp : null);
        AutomationProperties.SetHelpText(button, text);
    }

    private void NewTabInGroup()
    {
        Guid id = _groupId;
        Act(() => Strip.Window?.Apply(model => model.NewTabInGroup(id)));
    }

    /// <summary>Move Group to New Window: the tabs leave this window and a new one opens with them, in the group (same
    /// id, name and color), through the window manager.</summary>
    private void MoveToNewWindow()
    {
        Guid id = _groupId;
        // Once closed: the chip, its anchor, goes, and the focus is back on the row before the sync moves it on.
        AfterClose(() =>
        {
            if (Strip.Window is not { } window)
                return;
            WindowTabs.GroupWindow? moved = null;
            window.Apply(model => moved = model.MoveGroupToNewWindow(id));
            if (moved is not null)
                window.Manager.OpenGroupWindow(moved);
        });
    }

    private void CloseGroup()
    {
        Guid id = _groupId;
        AfterClose(() => Strip.Window?.Apply(model => model.CloseGroup(id)));
    }

    /// <summary>Delete Group: asks first (once the flyout has closed), then closes the group's tabs as one batch.
    /// </summary>
    private void DeleteGroup()
    {
        Guid id = _groupId;
        AfterClose(() => _ = ConfirmDeleteGroupAsync(Strip.Window, id));
    }

    private void Ungroup()
    {
        Guid id = _groupId;
        AfterClose(() => Strip.Window?.Apply(model => model.Ungroup(id)));
    }

    private static async Task ConfirmDeleteGroupAsync(MainWindow? window, Guid id)
    {
        try
        {
            if (window?.Content?.XamlRoot is not { } root
                || window.Tabs.Groups.FirstOrDefault(group => group.Id == id) is not { } group)
                return;
            int count = window.Tabs.Tabs.Count(tab => tab.GroupId == id && !tab.Pinned && !tab.Archived);
            bool confirmed = await ConfirmDialog.AskAsync(root, DeleteGroupTitle(group.Name),
                $"{ItsTabs(count)} close. Ctrl+Shift+T brings them back.", "Delete Group");
            if (confirmed)
                window.Apply(model => model.DeleteGroup(id));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Delete Group (dialog not shown)", error);
        }
    }

    /// <summary>The Delete Group confirmation's title, naming the group (sanitized) when it has a name.</summary>
    internal static string DeleteGroupTitle(string? name)
    {
        string shown = DisplayText.Sanitize(name);
        return shown.Length == 0 ? "Delete this group?" : $"Delete the group \"{shown}\"?";
    }

    /// <summary>"Its 1 tab" / "Its N tabs".</summary>
    internal static string ItsTabs(int count) =>
        count == 1 ? "Its 1 tab" : $"Its {count.ToString(CultureInfo.InvariantCulture)} tabs";
}

using Histq.App.Shell.Dialogs;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// The closed groups button's flyout (design header-and-tab-row.md §3.8, ported from ClosedGroupsPopover,
/// App/Window/ClosedGroups.swift at 6fa6d40): one row per closed group, most recently closed first, with its 10 epx
/// color square, its name in that color and its tab count; no search. A click opens the group at once (at the end of the
/// normal tabs, expanded, its first tab selected) and closes the flyout. A row's right click: Open Group, Open Group in
/// New Window (a new window through the window manager), Delete Group (asks first), then a "Tabs in Group" header and
/// one item per tab, each opening the group with that tab selected. It hides when no closed group is left.
/// </summary>
internal sealed class ClosedGroupsFlyout : TabFlyout
{
    /// <summary>A name's greatest width in a row, so the tab count after it always shows.</summary>
    private const double NameMaxWidth = 170;

    private StackPanel? _rows;

    public ClosedGroupsFlyout(ITabsView strip)
        : base(strip, strip.Vertical ? FlyoutPlacementMode.RightEdgeAlignedBottom : FlyoutPlacementMode.BottomEdgeAlignedLeft)
    {
    }

    public void Open(FrameworkElement button) => ShowAt(button);

    protected override UIElement? Build(WindowTabs model)
    {
        if (model.ClosedGroups.Count == 0)
            return null;
        StackPanel panel = Panel();
        _rows = new StackPanel();
        Fill(model);
        panel.Children.Add(List(_rows, "Closed groups"));
        return panel;
    }

    protected override bool Update(WindowTabs model)
    {
        if (model.ClosedGroups.Count == 0)
            return false;
        Fill(model);
        return true;
    }

    protected override void Opened()
    {
        if (_rows?.Children.FirstOrDefault() is Control first)
            first.Focus(FocusState.Programmatic);
    }

    private void Fill(WindowTabs model)
    {
        if (_rows is null)
            return;
        _rows.Children.Clear();
        foreach (SavedClosedTabGroup group in model.ClosedGroups)
            _rows.Children.Add(GroupRow(group));
    }

    /// <summary>One closed group: its color square, its name in that color (when it has one), then its tab count
    /// (never cut: a long name gives way first, at <see cref="NameMaxWidth"/>).</summary>
    private Button GroupRow(SavedClosedTabGroup group)
    {
        string name = GroupName(group.Name);
        string count = TabCount(group.Tabs.Count);
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(Square(GroupBrush(group.Color), 10, null));
        if (name.Length > 0)
        {
            TextBlock title = Title(name, GroupBrush(group.Color));
            title.MaxWidth = NameMaxWidth;
            content.Children.Add(title);
        }

        content.Children.Add(Title(count, Secondary()));

        string toolTip = string.Join(", ", group.Tabs.Select(tab => DisplayText.Sanitize(tab.Title)));
        Button row = Row(content, name.Length == 0 ? $"Group, {count}" : $"Group {name}, {count}", toolTip);
        Guid id = group.Id;
        row.Click += (_, _) => Act(() => OpenGroup(id, null));
        row.ContextFlyout = Menu(group);
        return row;
    }

    /// <summary>A row's right-click menu.</summary>
    private MenuFlyout Menu(SavedClosedTabGroup group)
    {
        Guid id = group.Id;
        var menu = new MenuFlyout();
        menu.Items.Add(Item("Open Group", () => Act(() => OpenGroup(id, null))));
        menu.Items.Add(Item("Open Group in New Window", () => Act(() => OpenInNewWindow(id))));
        menu.Items.Add(Item("Delete Group", () => AfterClose(() => _ = ConfirmDeleteAsync(Strip.Window, id))));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(new MenuFlyoutItem { Text = "Tabs in Group", IsEnabled = false });
        for (int index = 0; index < group.Tabs.Count; index++)
        {
            int tab = index;
            menu.Items.Add(Item(DisplayText.Sanitize(group.Tabs[index].Title), () => Act(() => OpenGroup(id, tab))));
        }

        return menu;
    }

    private static MenuFlyoutItem Item(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>Opens the closed group here, with its tab <paramref name="tab"/> selected (its first for null); its
    /// folders are checked off the UI thread.</summary>
    private void OpenGroup(Guid id, int? tab) => Strip.Window?.Apply(model => model.OpenClosedGroup(id, tab));

    /// <summary>Open Group in New Window: the group leaves the closed groups and a new window opens with it.</summary>
    private void OpenInNewWindow(Guid id)
    {
        if (Strip.Window is not { } window)
            return;
        WindowTabs.GroupWindow? opened = null;
        window.Apply(model => opened = model.OpenClosedGroupInNewWindow(id));
        if (opened is not null)
            window.Manager.OpenGroupWindow(window, opened);
    }

    /// <summary>A closed group's Delete Group: asks first, then its tabs go on the reopen stack as one batch.</summary>
    private static async Task ConfirmDeleteAsync(MainWindow? window, Guid id)
    {
        try
        {
            if (window?.Content?.XamlRoot is not { } root
                || window.Tabs.ClosedGroups.FirstOrDefault(group => group.Id == id) is not { } group)
                return;
            bool confirmed = await ConfirmDialog.AskAsync(root, GroupFlyout.DeleteGroupTitle(group.Name),
                $"It leaves Closed Groups. Ctrl+Shift+T brings its {TabCount(group.Tabs.Count)} back.",
                "Delete Group");
            if (confirmed)
                window.Apply(model => model.DeleteClosedGroup(id));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Delete closed group (dialog not shown)", error);
        }
    }
}

using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// The All Tabs button's flyout (design header-and-tab-row.md §3.9, ported from TabListPopover,
/// App/Window/TabStrip.swift at 6fa6d40): a search field ("Search tabs", focused when it opens) and the tabs that match
/// it (<see cref="TabListSearch.AllTabs"/>): the window's tabs, then the stowed archived tabs, then the closed groups'
/// tabs. An archived row (the popped-out tab too) shows the archive button's orange square, a closed group's the closed
/// groups glyph in the group's color with "In closed group". A click acts at once and closes the flyout: a tab of the
/// window is selected, an archived one pops out, a closed group's reopens its whole group with that tab selected.
/// </summary>
internal sealed class AllTabsFlyout : TabFlyout
{
    // Segoe Fluent Icons: Home (a Welcome tab), Folder (a repo tab).
    private const string HomeGlyph = "";
    private const string FolderGlyph = "";

    private TextBox? _search;
    private StackPanel? _body;

    public AllTabsFlyout(TabStrip strip)
        : base(strip, FlyoutPlacementMode.BottomEdgeAlignedRight)
    {
    }

    public void Open(FrameworkElement button) => ShowAt(button);

    protected override UIElement? Build(WindowTabs model)
    {
        StackPanel panel = Panel();
        _search = SearchBox("Search tabs");
        _search.TextChanged += (_, _) =>
        {
            if (Strip.Model is { } current)
                Fill(current);
        };
        panel.Children.Add(_search);
        _body = new StackPanel();
        panel.Children.Add(_body);
        Fill(model);
        return panel;
    }

    protected override bool Update(WindowTabs model)
    {
        Fill(model);
        return true;
    }

    protected override void Opened() => _search?.Focus(FocusState.Programmatic);

    private void Fill(WindowTabs model)
    {
        if (_body is null)
            return;
        // Focus on a row that goes would fall out of the flyout: it goes back to the search field.
        bool hadFocus = HasFocusIn(_body);
        _body.Children.Clear();
        IReadOnlyList<TabListSearch.Row> matches = TabListSearch.AllTabs(model, _search?.Text);
        if (matches.Count == 0)
        {
            _body.Children.Add(EmptyText("No matching tabs"));
        }
        else
        {
            var rows = new StackPanel();
            foreach (TabListSearch.Row row in matches)
                rows.Children.Add(TabRow(row, model.SelectedTabId));
            _body.Children.Add(List(rows, "All tabs"));
        }

        if (hadFocus)
            _search?.Focus(FocusState.Programmatic);
    }

    /// <summary>A row's button: its glyph and title, then its badge (never cut: the title gives way first).</summary>
    private Button TabRow(TabListSearch.Row row, Guid? selected)
    {
        string title = DisplayText.Sanitize(row.Title);
        var content = new Grid();
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.Children.Add(RowGlyph(row.Path is null ? HomeGlyph : FolderGlyph));
        TextBlock text = Title(title);
        Grid.SetColumn(text, 1);
        content.Children.Add(text);
        if (Badge(row) is { } badge)
        {
            badge.Margin = new Thickness(6, 0, 0, 0);
            Grid.SetColumn(badge, 2);
            content.Children.Add(badge);
        }

        bool isSelected = row is TabListSearch.Row.Open open && open.Tab.Id == selected;
        Button button = Row(content, Name(title, row), Help(title, row), isSelected);
        button.Click += (_, _) => Act(() => Pick(row));
        return button;
    }

    /// <summary>The click: a tab of the window is selected, an archived one pops out, a closed group's reopens its
    /// group with it selected.</summary>
    private void Pick(TabListSearch.Row row)
    {
        if (Strip.Window is not { } window)
            return;
        switch (row)
        {
            case TabListSearch.Row.Open open:
                Guid id = open.Tab.Id;
                window.Apply(model => model.SelectTab(id));
                break;
            case TabListSearch.Row.Archived archived:
                int index = archived.Index;
                window.Apply(model => model.OpenArchived(index));
                break;
            case TabListSearch.Row.Closed closed:
                Guid group = closed.Group.Id;
                int tab = closed.Index;
                window.Apply(model => model.OpenClosedGroup(group, tab));
                break;
        }
    }

    /// <summary>The archive's orange square, or the closed groups glyph in the group's chip fill; none for a shown tab.
    /// </summary>
    private static Border? Badge(TabListSearch.Row row)
    {
        double size = PaletteResources.Double("ChipHeight");
        return row switch
        {
            TabListSearch.Row.Open { Tab.Archived: true } or TabListSearch.Row.Archived =>
                Square(TabColors.Fill(TabColors.Archive), size, ArchiveGlyph),
            TabListSearch.Row.Closed closed => Square(TabColors.Fill(TabColors.Group(closed.Group.Color)), size,
                ClosedGroupsGlyph),
            _ => null,
        };
    }

    /// <summary>A row's UI Automation name: the title, then where a hidden tab is ("archived", "in closed group Docs").
    /// </summary>
    private static string Name(string title, TabListSearch.Row row) =>
        row switch
        {
            TabListSearch.Row.Open { Tab.Archived: true } or TabListSearch.Row.Archived => $"{title}, archived",
            TabListSearch.Row.Closed closed => GroupName(closed.Group.Name) is { Length: > 0 } name
                ? $"{title}, in closed group {name}"
                : $"{title}, in a closed group",
            _ => title,
        };

    /// <summary>The tooltip: the folder (or title), and where a hidden tab is.</summary>
    private static string Help(string title, TabListSearch.Row row)
    {
        string place = row.Path is null ? title : DisplayText.Sanitize(row.Path);
        return row switch
        {
            TabListSearch.Row.Open { Tab.Archived: true } => $"{place}\nArchived",
            TabListSearch.Row.Archived => $"{place}\nArchived: opens beside the archive button",
            TabListSearch.Row.Closed closed => GroupName(closed.Group.Name) is { Length: > 0 } name
                ? $"{place}\nIn closed group \"{name}\": opens the whole group"
                : $"{place}\nIn closed group: opens the whole group",
            _ => place,
        };
    }
}

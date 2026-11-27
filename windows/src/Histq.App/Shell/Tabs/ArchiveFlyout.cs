using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// The archive button's flyout (design header-and-tab-row.md §3.7, ported from ArchiveListPopover,
/// App/Window/TabStrip.swift at 6fa6d40): a search field ("Search archived tabs", focused when it opens) and the stowed
/// archived tabs that match it, most recently archived first (<see cref="TabListSearch.Archived"/>). A click pops the
/// tab out at once and closes the flyout; a row's ✕ (shown on hover or focus) removes it from the archive and the list
/// stays. It hides when the archive button goes (nothing archived and no tab popped out).
/// </summary>
internal sealed class ArchiveFlyout : TabFlyout
{
    private TextBox? _search;
    private StackPanel? _body;

    public ArchiveFlyout(TabStrip strip)
        : base(strip, FlyoutPlacementMode.BottomEdgeAlignedLeft)
    {
    }

    public void Open(FrameworkElement button) => ShowAt(button);

    protected override UIElement? Build(WindowTabs model)
    {
        StackPanel panel = Panel();
        _search = SearchBox("Search archived tabs");
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
        if (model.ArchivedTabs.Count == 0 && model.ArchivedOut is null)
            return false;
        Fill(model);
        return true;
    }

    protected override void Opened() => _search?.Focus(FocusState.Programmatic);

    /// <summary>The rows matching the search, or the line saying why there is none.</summary>
    private void Fill(WindowTabs model)
    {
        if (_body is null)
            return;
        // Focus on a row that goes would fall out of the flyout: it goes back to the search field.
        bool hadFocus = HasFocusIn(_body);
        _body.Children.Clear();
        IReadOnlyList<(int Index, SavedTab Entry)> matches = TabListSearch.Archived(model, _search?.Text);
        if (matches.Count == 0)
        {
            // Only the popped-out tab is archived: the list has no other.
            _body.Children.Add(EmptyText(model.ArchivedTabs.Count == 0 ? "No other archived tabs" : "No matching archived tabs"));
        }
        else
        {
            var rows = new StackPanel();
            foreach ((int index, SavedTab entry) in matches)
                rows.Children.Add(ArchiveRow(index, entry));
            _body.Children.Add(List(rows, "Archived tabs"));
        }

        if (hadFocus)
            _search?.Focus(FocusState.Programmatic);
    }

    /// <summary>One archived tab: a click pops it out; its ✕ on hover or focus removes it from the archive.</summary>
    private Grid ArchiveRow(int index, SavedTab entry)
    {
        string title = DisplayText.Sanitize(entry.Title);
        // The ✕ stands over the row's end.
        var content = new Grid { Margin = new Thickness(0, 0, RowHeight - 8, 0) };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.Children.Add(RowGlyph(ArchiveGlyph));
        TextBlock text = Title(title);
        Grid.SetColumn(text, 1);
        content.Children.Add(text);
        string path = entry.Path is null ? title : DisplayText.Sanitize(entry.Path);
        Button open = Row(content, $"{title}, archived", path);
        open.Click += (_, _) => Act(() => Strip.Window?.Apply(model => model.OpenArchived(index)));

        string removeName = $"Remove {title} from Archive";
        var remove = new Button
        {
            Content = new FontIcon { Glyph = RemoveGlyph, FontSize = 9 },
            Width = RowHeight - 6,
            Height = RowHeight - 6,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius((RowHeight - 6) / 2),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 3, 0),
            Opacity = 0,
        };
        TabStrip.StyleButton(remove, PaletteResources.Brush("TabFillBrush"), PaletteResources.Brush("HoverFillBrush"),
            PaletteResources.Brush("PressedFillBrush"));
        AutomationProperties.SetName(remove, removeName);
        ToolTipService.SetToolTip(remove, "Remove from Archive");
        remove.Click += (_, _) => Strip.Window?.Apply(model => model.RemoveArchived(index));

        var row = new Grid();
        row.Children.Add(open);
        row.Children.Add(remove);
        void Show(bool shown) => remove.Opacity = shown ? 1 : 0;
        row.PointerEntered += (_, _) => Show(true);
        row.PointerExited += (_, _) => Show(remove.FocusState != FocusState.Unfocused);
        remove.GotFocus += (_, _) => Show(true);
        remove.LostFocus += (_, _) => Show(false);
        return row;
    }
}

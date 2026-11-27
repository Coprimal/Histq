using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// A flyout of the tab row (the group flyout, the archive, closed groups and All Tabs lists; design header-and-tab-row.md
/// §3.4, 3.7-3.9), anchored to the strip's element that opens it. Its content is built when it opens and brought in line
/// with the tabs after each <see cref="TabStrip.Sync"/> while it is open (<see cref="Synced"/>): its rows hold indices
/// into the model, so they never outlive a change. A row acts at once and the flyout hides (<see cref="Act"/>); an action
/// that shows a dialog waits for the flyout to close (<see cref="AfterClose"/>). Each close has the strip set the title
/// bar's Passthrough rects again.
/// </summary>
internal abstract class TabFlyout
{
    /// <summary>The 280 epx lists' greatest height (design §3.8).</summary>
    protected const double ListMaxHeight = 320;

    /// <summary>A list row's height and the gap between rows.</summary>
    protected const double RowHeight = 28;
    protected const double RowSpacing = 2;

    // Segoe Fluent Icons, as the strip's buttons: ViewAll (closed groups), Package (the archive), ChromeClose.
    protected const string ClosedGroupsGlyph = "";
    protected const string ArchiveGlyph = "";
    protected const string RemoveGlyph = "";

    private Action? _afterClose;

    /// <summary>Hidden by a row's action: the syncs that action causes leave the content as it is.</summary>
    private bool _closing;

    protected TabFlyout(ITabsView strip, FlyoutPlacementMode placement)
    {
        Strip = strip;
        Flyout = new Flyout
        {
            Placement = placement,
            FlyoutPresenterStyle = PresenterStyle(),
        };
        Flyout.Opened += (_, _) => Opened();
        Flyout.Closed += (_, _) => OnClosed();
    }

    /// <summary>The strip or the vertical panel that opens it.</summary>
    protected ITabsView Strip { get; }

    protected Flyout Flyout { get; }

    public bool IsOpen => Flyout.IsOpen;

    /// <summary>Opens the flyout at <paramref name="anchor"/>, its content built from the tabs as they are; nothing
    /// while it is open, before the strip has tabs, or when there is nothing to show.</summary>
    protected void ShowAt(FrameworkElement anchor)
    {
        if (Flyout.IsOpen || anchor.XamlRoot is null || anchor.Visibility != Visibility.Visible
            || Strip.Model is not { } model || Build(model) is not { } content)
            return;
        _closing = false;
        _afterClose = null;
        Flyout.Content = content;
        Flyout.ShowAt(anchor);
    }

    /// <summary>After a sync of the strip: an open flyout shows the tabs as they are now, or hides when what it shows
    /// (its group, the closed groups, the archive) is gone.</summary>
    public void Synced(WindowTabs model)
    {
        if (!Flyout.IsOpen || _closing)
            return;
        if (!Update(model))
            Hide();
    }

    public void Hide()
    {
        _closing = true;
        Flyout.Hide();
    }

    /// <summary>The flyout's content for <paramref name="model"/>; null when there is nothing to show.</summary>
    protected abstract UIElement? Build(WindowTabs model);

    /// <summary>Brings the open content in line with <paramref name="model"/>; false when the flyout should hide.</summary>
    protected abstract bool Update(WindowTabs model);

    /// <summary>The flyout has opened: where the keyboard focus goes.</summary>
    protected virtual void Opened()
    {
    }

    /// <summary>A row's click: the flyout hides and <paramref name="action"/> runs at once (click-first rule).</summary>
    protected void Act(Action action)
    {
        Hide();
        Run(action, "Tab row flyout action (not done)");
    }

    /// <summary>A row's click whose action shows a dialog or takes the anchor away: it runs once the flyout has closed
    /// (the focus is back where it was by then).</summary>
    protected void AfterClose(Action action)
    {
        _afterClose = action;
        Hide();
    }

    private void OnClosed()
    {
        _closing = false;
        Flyout.Content = null;
        Strip.OnFlyoutClosed();
        if (_afterClose is not { } action)
            return;
        _afterClose = null;
        Run(action, "Tab row flyout action after close (not done)");
    }

    private static void Run(Action action, string what)
    {
        try
        {
            action();
        }
        catch (Exception error)
        {
            CrashLog.Recovered(what, error);
        }
    }

    /// <summary>Whether the keyboard focus is inside <paramref name="container"/> (a list about to be rebuilt: its
    /// focus would fall out of the flyout).</summary>
    protected static bool HasFocusIn(FrameworkElement container)
    {
        if (container.XamlRoot is not { } root || FocusManager.GetFocusedElement(root) is not DependencyObject focused)
            return false;
        for (DependencyObject? node = focused; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            if (ReferenceEquals(node, container))
                return true;
        }

        return false;
    }

    // Parts.

    /// <summary>No padding of its own (the content has it) and the design's 280 epx width (set here only: the content
    /// stretches to it).</summary>
    private static Style PresenterStyle()
    {
        var style = new Style(typeof(FlyoutPresenter));
        if (Application.Current.Resources.TryGetValue("DefaultFlyoutPresenterStyle", out object? basis)
            && basis is Style based)
            style.BasedOn = based;
        double width = PaletteResources.Double("FlyoutWidth");
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(0)));
        style.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, width));
        style.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty, width));
        return style;
    }

    /// <summary>The flyout's content panel: 10 epx above and below, its parts 8 apart.</summary>
    protected static StackPanel Panel() =>
        new() { Spacing = 8, Padding = new Thickness(0, 10, 0, 10) };

    /// <summary>A search field (its placeholder is its UI Automation name too).</summary>
    protected static TextBox SearchBox(string placeholder)
    {
        var box = new TextBox
        {
            PlaceholderText = placeholder,
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            Margin = new Thickness(10, 0, 10, 0),
        };
        AutomationProperties.SetName(box, placeholder);
        return box;
    }

    /// <summary>The rows' list: scrolls past <see cref="ListMaxHeight"/>; its scroll bar runs along the flyout's edge.
    /// </summary>
    protected static ScrollViewer List(StackPanel rows, string name)
    {
        rows.Spacing = RowSpacing;
        rows.Padding = new Thickness(10, 0, 10, 0);
        AutomationProperties.SetName(rows, name);
        return new ScrollViewer
        {
            Content = rows,
            MaxHeight = ListMaxHeight,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    /// <summary>The line a list shows when it has no row.</summary>
    protected static TextBlock EmptyText(string text) =>
        new()
        {
            Text = text,
            Opacity = 0.6,
            Margin = new Thickness(20, 0, 20, 0),
            MinHeight = RowHeight,
            VerticalAlignment = VerticalAlignment.Center,
        };

    /// <summary>A list row: a full-width button (transparent, hover white 0.06, pressed 0.20; the selected one filled)
    /// named for UI Automation.</summary>
    protected static Button Row(UIElement content, string name, string? toolTip, bool selected = false)
    {
        var button = new Button
        {
            Content = content,
            MinHeight = RowHeight,
            Padding = new Thickness(8, 0, 8, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Center,
            CornerRadius = new CornerRadius(6),
        };
        Brush rest = selected
            ? TabColors.Brush(PaletteResources.Color("SelectedFillColor"))
            : new SolidColorBrush(Colors.Transparent);
        TabStrip.StyleButton(button, rest, PaletteResources.Brush("HoverFillBrush"),
            PaletteResources.Brush("PressedFillBrush"));
        AutomationProperties.SetName(button, name);
        if (toolTip is { Length: > 0 })
            ToolTipService.SetToolTip(button, toolTip);
        return button;
    }

    /// <summary>A row's leading glyph.</summary>
    protected static FontIcon RowGlyph(string glyph) =>
        new() { Glyph = glyph, FontSize = 14, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };

    /// <summary>A one-line title that gives way first (ellipsis).</summary>
    protected static TextBlock Title(string text, Brush? foreground = null)
    {
        var title = new TextBlock
        {
            Text = text,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            MaxLines = 1,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (foreground is not null)
            title.Foreground = foreground;
        return title;
    }

    /// <summary>A rounded square in <paramref name="fill"/>, with a white glyph when one is given (the stow buttons'
    /// look at chip height), else a plain color square.</summary>
    protected static Border Square(Brush fill, double size, string? glyph)
    {
        var square = new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(Math.Round(size * 3 / 10)),
            Background = fill,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (glyph is not null)
        {
            square.Child = new FontIcon
            {
                Glyph = glyph,
                FontSize = Math.Round(size * 0.55),
                Foreground = TabColors.Brush(PaletteResources.Color("GraphBadgeTextColor")),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }

        return square;
    }

    /// <summary>A closed group's name as shown (sanitized; empty for an unnamed group).</summary>
    protected static string GroupName(string? name) => DisplayText.Sanitize(name);

    /// <summary>"1 tab" / "N tabs".</summary>
    protected static string TabCount(int count) =>
        count == 1 ? "1 tab" : $"{count.ToString(System.Globalization.CultureInfo.InvariantCulture)} tabs";

    /// <summary>A group's swatch color as a brush.</summary>
    protected static SolidColorBrush GroupBrush(int colorIndex, double opacity = 1) =>
        TabColors.Brush(TabColors.Group(colorIndex), opacity);

    /// <summary>The secondary text's color.</summary>
    protected static Brush Secondary() => TabColors.Brush(Colors.White, 0.6);
}

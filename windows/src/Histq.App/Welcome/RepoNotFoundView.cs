using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Histq.App.Welcome;

/// <summary>
/// The page of a tab whose repo folder is gone (ported from RepoNotFoundView, App/Window/RepoNotFoundView.swift at
/// 6fa6d40): one card, at most 560 epx wide and centered, that names the folder, with Locate (pick where it went, then it
/// opens in this tab: <see cref="Shell.WindowManager.LocateRepo"/>) and Remove (closes the tab, and the window with its
/// last tab). Unlike the Mac's, the picker cannot start at the nearest folder that still exists (the system folder
/// picker takes no start folder), and nothing is probed here. Built in code: no XAML.
/// </summary>
internal sealed partial class RepoNotFoundView : UserControl
{
    /// <summary>The card's widest (the Mac's .frame(maxWidth: 560)).</summary>
    private const double CardMaxWidth = 560;

    /// <summary>The page's padding (SettingsMetrics.pagePadding) and the extra top offset (contentTopOffset).</summary>
    private const double PagePadding = 20;

    private const double ContentTopOffset = 12;

    private readonly MainWindow _window;
    private readonly Guid _tabId;

    internal RepoNotFoundView(MainWindow window, Guid tabId, string path)
    {
        _window = window;
        _tabId = tabId;

        var header = new Grid { Height = PaletteResources.Double("CardHeaderHeight"), ColumnSpacing = 6 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        // Segoe Fluent Icons "Folder": the Mac's questionmark.folder has no Fluent match.
        header.Children.Add(new FontIcon
        {
            Glyph = "",
            FontSize = PaletteResources.Double("CommandIconSize"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var title = new TextBlock
        {
            Text = "Repo not found",
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 1);
        header.Children.Add(title);

        // Prominent, as the Mac's: the framework's accent button (the plain one should the style ever be missing).
        var locate = new Button { Content = "Locate" };
        if (Application.Current.Resources.TryGetValue("AccentButtonStyle", out object? accent) && accent is Style style)
            locate.Style = style;
        locate.Click += (_, _) => _window.Manager.LocateRepo(_window, _tabId);
        var remove = new Button { Content = "Remove" };
        remove.Click += (_, _) => Remove();

        var body = new StackPanel
        {
            Spacing = 8,
            Padding = new Thickness(12, 0, 12, 12),
            Children =
            {
                new TextBlock
                {
                    Text = DisplayText.Sanitize(path),
                    FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                    FontSize = 13,
                    IsTextSelectionEnabled = true,
                    TextWrapping = TextWrapping.Wrap,
                },
                new TextBlock
                {
                    Text = "This folder was moved, renamed or deleted, or it is no longer a git repository.",
                    FontSize = 13,
                    Opacity = 0.6,
                    TextWrapping = TextWrapping.Wrap,
                },
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    Margin = new Thickness(0, 4, 0, 0),
                    Children = { locate, remove },
                },
            },
        };

        var card = new Border
        {
            Background = PaletteResources.Brush("SheetCardBrush"),
            BorderBrush = PaletteResources.Brush("SheetCardBorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = (CornerRadius)Application.Current.Resources["CardCornerRadius"],
            MaxWidth = CardMaxWidth,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(PagePadding, PagePadding + ContentTopOffset, PagePadding, PagePadding),
            Child = new StackPanel { Children = { header, body } },
        };

        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = card };
    }

    /// <summary>Closes this tab, and the window with its last tab (as the tab's close button does).</summary>
    private void Remove()
    {
        bool keep = true;
        _window.Apply(model => keep = model.CloseTab(_tabId));
        if (!keep)
            _window.Close();
    }
}

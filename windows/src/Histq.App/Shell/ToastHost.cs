using Histq.App.Shell.Tabs;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Histq.App.Shell;

/// <summary>
/// The window's toasts at its bottom right (a minimal port of ToastHost, App/Window/ToastHost.swift at 6fa6d40): warning
/// cards (an orange mark, the title, the detail, a Dismiss button), newest at the bottom, at most <see cref="Limit"/>
/// (a new one pushes the oldest out). Each closes by itself after <see cref="Duration"/>; the pointer over the cards holds
/// every timer until it leaves. The same title and detail again restarts that card instead of stacking a copy. Only the
/// cards take clicks. Call on the UI thread.
/// </summary>
public sealed partial class ToastHost : StackPanel
{
    /// <summary>The most cards on screen at once.</summary>
    private const int Limit = 3;

    private const double CardWidth = 320;

    /// <summary>The most text elements of a title and of a detail; both are sanitized (<see cref="DisplayText"/>), as
    /// they reach UI Automation's live region too.</summary>
    private const int TitleLimit = 120;

    private const int DetailLimit = 300;

    /// <summary>A warning's time on screen (the Mac's failure and warning duration).</summary>
    private static readonly TimeSpan Duration = TimeSpan.FromSeconds(6);

    private readonly List<Card> _cards = [];
    private bool _held;

    public ToastHost()
    {
        Orientation = Orientation.Vertical;
        Spacing = 8;
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Bottom;
        PointerEntered += (_, _) => Hold(true);
        PointerExited += (_, _) => Hold(false);
        PointerCanceled += (_, _) => Hold(false);
    }

    /// <summary>Shows a warning card: <paramref name="title"/> ("Move Tab to Window"), and what happened under it. Both
    /// are sanitized and capped first.</summary>
    public void Show(string title, string? detail)
    {
        title = DisplayText.Sanitize(title, TitleLimit);
        detail = detail is null ? null : DisplayText.Sanitize(detail, DetailLimit);
        if (_cards.Find(card => card.Same(title, detail)) is { } shown)
        {
            shown.Restart(_held);
            return;
        }

        var card = new Card(this, title, detail);
        _cards.Add(card);
        Children.Add(card.View);
        while (_cards.Count > Limit)
            Dismiss(_cards[0]);
        card.Restart(_held);
        card.Announce();
    }

    private void Dismiss(Card card)
    {
        card.Stop();
        _cards.Remove(card);
        Children.Remove(card.View);
        if (_cards.Count == 0)
            _held = false;
    }

    /// <summary>The pointer over the cards stops every timer; leaving starts them again with their time left.</summary>
    private void Hold(bool held)
    {
        if (_held == held)
            return;
        _held = held;
        foreach (Card card in _cards)
        {
            if (held)
                card.Pause();
            else
                card.Resume();
        }
    }

    /// <summary>One card and its timer.</summary>
    private sealed class Card
    {
        private readonly ToastHost _host;
        private readonly string _title;
        private readonly string? _detail;
        private readonly DispatcherQueueTimer _timer;
        private DateTime _started;
        private TimeSpan _left;

        public Card(ToastHost host, string title, string? detail)
        {
            _host = host;
            _title = title;
            _detail = detail;
            _left = Duration;
            _timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
            _timer.IsRepeating = false;
            _timer.Tick += (_, _) => _host.Dismiss(this);

            var grid = new Grid { ColumnSpacing = 10 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            // Segoe Fluent Icons Warning.
            grid.Children.Add(new FontIcon
            {
                Glyph = "",
                FontSize = 15,
                Foreground = TabColors.Brush(TabColors.Archive),
                VerticalAlignment = VerticalAlignment.Top,
            });

            var texts = new StackPanel { Spacing = 2 };
            texts.Children.Add(new TextBlock
            {
                Text = title,
                FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 2,
            });
            texts.Children.Add(new TextBlock
            {
                Text = detail ?? string.Empty,
                FontSize = 12,
                Opacity = 0.6,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 4,
                TextTrimming = TextTrimming.CharacterEllipsis,
                IsTextSelectionEnabled = true,
                Visibility = detail is null ? Visibility.Collapsed : Visibility.Visible,
            });
            Grid.SetColumn(texts, 1);
            grid.Children.Add(texts);

            var dismiss = new Button
            {
                Padding = new Thickness(4),
                MinWidth = 0,
                MinHeight = 0,
                VerticalAlignment = VerticalAlignment.Top,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Content = new FontIcon { Glyph = "", FontSize = 11 },
            };
            AutomationProperties.SetName(dismiss, "Dismiss");
            ToolTipService.SetToolTip(dismiss, "Dismiss");
            dismiss.Click += (_, _) => _host.Dismiss(this);
            Grid.SetColumn(dismiss, 2);
            grid.Children.Add(dismiss);

            View = new Border
            {
                Width = CardWidth,
                Padding = new Thickness(12, 10, 12, 10),
                CornerRadius = (CornerRadius)Application.Current.Resources["CardCornerRadius"],
                Background = new SolidColorBrush(PaletteResources.Color("SheetCardOpaqueColor")),
                BorderBrush = PaletteResources.Brush("SheetCardBorderBrush"),
                BorderThickness = new Thickness(1),
                Child = grid,
            };
            AutomationProperties.SetName(View, detail is null ? title : $"{title}. {detail}");
            AutomationProperties.SetLiveSetting(View, AutomationLiveSetting.Assertive);
        }

        public Border View { get; }

        public bool Same(string title, string? detail) =>
            string.Equals(_title, title, StringComparison.Ordinal) && string.Equals(_detail, detail, StringComparison.Ordinal);

        /// <summary>A full time on screen again (its timer waits while <paramref name="held"/>).</summary>
        public void Restart(bool held)
        {
            _left = Duration;
            if (held)
                _timer.Stop();
            else
                Resume();
        }

        public void Pause()
        {
            _timer.Stop();
            _left = Max(TimeSpan.Zero, _left - (DateTime.UtcNow - _started));
        }

        public void Resume()
        {
            _started = DateTime.UtcNow;
            _timer.Interval = _left;
            _timer.Start();
        }

        public void Stop() => _timer.Stop();

        /// <summary>Screen readers read the new card (its live region changed).</summary>
        public void Announce()
        {
            if (AutomationPeer.ListenerExists(AutomationEvents.LiveRegionChanged)
                && FrameworkElementAutomationPeer.CreatePeerForElement(View) is { } peer)
                peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }

        private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;
    }
}

using Histq.App.Support;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Histq.App.Shell.Tabs;

/// <summary>The glyph a tab shows without an emoji (TabIcon.symbol(of:)): a repo's book, a missing repo, a Welcome tab.</summary>
internal enum TabGlyph
{
    Book,
    Missing,
    Welcome,
}

/// <summary>What a tab's icon shows.</summary>
/// <param name="Emoji">The tab's own emoji or image reference; null for none.</param>
/// <param name="IconColor">The tab's own book color, an index into the lane colors; null for none.</param>
/// <param name="ProfileColor">The profile's color (the dot); null without a profile.</param>
/// <param name="DefaultEmoji">Settings › Appearance's default tab icon (an emoji or an image reference; "" for none).</param>
/// <param name="DefaultColor">Settings › Appearance's default book color; -1 for none.</param>
internal readonly record struct TabIconState(
    string? Emoji,
    TabGlyph Glyph,
    int? IconColor,
    bool Selected,
    Color? ProfileColor,
    string? ProfileName,
    string DefaultEmoji,
    int DefaultColor);

/// <summary>
/// The tab row's colors by index (TabGroupColors and TabIcon.tint, App/Window/TabStrip.swift): the 8 lane colors, a
/// group's swatch (0 grey, 1-8 the lanes, wrapped into range: a hand-edited session.json may hold any number), the
/// chip fill (the color at BadgeFillOpacity) and the archive's orange (lane 1). Brushes are made once, on the UI thread.
/// </summary>
internal static class TabColors
{
    internal const int LaneCount = 8;

    /// <summary>The archive's lane: index 1, the orange.</summary>
    private const int ArchiveLane = 1;

    private static readonly Dictionary<(Color Color, double Opacity), SolidColorBrush> Brushes = [];

    /// <summary>Lane color <paramref name="index"/>, wrapped into range.</summary>
    public static Color Lane(int index) => PaletteResources.Color($"Lane{Wrap(index, LaneCount)}Color");

    /// <summary>A manual group's line color by its swatch.</summary>
    public static Color Group(int colorIndex)
    {
        int swatch = Wrap(colorIndex, LaneCount + 1);
        return swatch == 0 ? PaletteResources.Color("GroupGreyColor") : Lane(swatch - 1);
    }

    public static Color Archive => Lane(ArchiveLane);

    /// <summary>A shared brush of <paramref name="color"/> at <paramref name="opacity"/> (its alpha scaled).</summary>
    public static SolidColorBrush Brush(Color color, double opacity = 1)
    {
        if (!Brushes.TryGetValue((color, opacity), out SolidColorBrush? brush))
        {
            brush = new SolidColorBrush(ColorHelper.FromArgb(
                (byte)Math.Round(color.A * Math.Clamp(opacity, 0, 1)), color.R, color.G, color.B));
            Brushes[(color, opacity)] = brush;
        }

        return brush;
    }

    /// <summary>A chip's or stow button's fill: the color at BadgeFillOpacity.</summary>
    public static SolidColorBrush Fill(Color color) => Brush(color, PaletteResources.Double("BadgeFillOpacity"));

    /// <summary>The name of lane color <paramref name="index"/> (TabIcon.colorNames).</summary>
    public static string LaneName(int index) =>
        Wrap(index, LaneCount) switch
        {
            0 => "Blue",
            1 => "Orange",
            2 => "Green",
            3 => "Pink",
            4 => "Cyan",
            5 => "Yellow",
            6 => "Purple",
            _ => "Red",
        };

    private static int Wrap(int index, int count) => ((index % count) + count) % count;
}

/// <summary>
/// A tab's icon in its 16 epx slot (ported from TabIcon, App/Window/TabStrip.swift): its own emoji or uploaded image,
/// else (a book with neither its own icon nor its own color) Settings › Appearance's default tab icon (an emoji or an
/// image), else its glyph, tinted by its own color or the default color, else the title's color. An image
/// (<c>icon:&lt;sha&gt;</c>, <see cref="CustomIconImages"/>) is fitted in the emoji's square, never cropped; the slot
/// stays empty while it loads, and an image found missing counts as no icon. An emoji read from a session or workspace
/// file is shown only as <see cref="TabEmoji.Normalized"/> keeps it (its last emoji), and not when that is longer than
/// <see cref="DisplayText.MaxElementLength"/>. The profile's color dot sits on its lower-right corner in a white ring.
/// UI Automation reads it as an Image named by its emoji, or "Custom icon"; a glyph is not read (the tab's name says
/// it all).
/// </summary>
internal sealed partial class TabIcon : Grid
{
    /// <summary>Segoe Fluent Icons: Dictionary (the closed book the command bar's repo button shows), Unknown, Add.</summary>
    private const string BookGlyph = "";
    private const string MissingGlyph = "";
    private const string WelcomeGlyph = "";

    private readonly TextBlock _emoji;
    private readonly Image _image;
    private readonly FontIcon _glyph;
    private readonly Ellipse _dot;
    private TabIconState? _shown;

    public TabIcon()
    {
        double slot = PaletteResources.Double("TabSlot");
        double size = slot * PaletteResources.Double("TabIconScale");
        Width = slot;
        Height = slot;

        _emoji = new TextBlock
        {
            FontSize = size,
            FontFamily = new FontFamily("Segoe UI Emoji"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            TextLineBounds = TextLineBounds.Tight,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        // A fixed size, so a source that arrives later changes no layout.
        _image = new Image
        {
            Width = size,
            Height = size,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        _glyph = new FontIcon
        {
            FontSize = size,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
        };

        // Only the dot takes the pointer: its tooltip names the profile. Its center stands ProfileDotInset inside the
        // icon's lower-right corner.
        double ring = PaletteResources.Double("ProfileDotRing");
        double dot = PaletteResources.Double("ProfileDotSize") + 2 * ring;
        double shift = dot / 2 - PaletteResources.Double("ProfileDotInset");
        _dot = new Ellipse
        {
            Width = dot,
            Height = dot,
            StrokeThickness = ring,
            Stroke = TabColors.Brush(PaletteResources.Color("ProfileDotRingColor")),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, -shift, -shift),
            Visibility = Visibility.Collapsed,
        };

        Children.Add(_emoji);
        Children.Add(_image);
        Children.Add(_glyph);
        Children.Add(_dot);
    }

    /// <summary>What UI Automation reads: the emoji shown, "Custom icon" for an image, null for the glyph.</summary>
    public string? ShownName =>
        _emoji.Visibility == Visibility.Visible ? _emoji.Text
        : _image.Visibility == Visibility.Visible ? "Custom icon"
        : null;

    public void Update(TabIconState state)
    {
        if (_shown == state)
            return;
        _shown = state;
        Show(state);
    }

    /// <summary>The icon images changed (<see cref="CustomIconImages.Changed"/>): an icon that shows or waits for an
    /// image is drawn again.</summary>
    public void RefreshImage()
    {
        if (_shown is { } state && (CustomIcon.IsRef(state.Emoji) || CustomIcon.IsRef(state.DefaultEmoji)))
            Show(state);
    }

    private void Show(TabIconState state)
    {
        CustomIconImages images = CustomIconImages.Shared;
        string? own = Present(state.Emoji, images);
        bool usesDefault = own is null && state.IconColor is null && state.Glyph == TabGlyph.Book;
        string? icon = own ?? (usesDefault ? Present(state.DefaultEmoji, images) : null);

        _emoji.Visibility = Visibility.Collapsed;
        _image.Visibility = Visibility.Collapsed;
        _glyph.Visibility = Visibility.Collapsed;
        if (icon is not null && CustomIcon.IsRef(icon))
        {
            // Empty until the image has loaded.
            ImageSource? source = images.Image(icon);
            if (source is null)
                images.Load(icon);
            _image.Source = source;
            _image.Visibility = Visibility.Visible;
        }
        else if (icon is not null)
        {
            _emoji.Text = icon;
            _emoji.Visibility = Visibility.Visible;
        }
        else
        {
            _glyph.Visibility = Visibility.Visible;
            _glyph.Glyph = state.Glyph switch
            {
                TabGlyph.Missing => MissingGlyph,
                TabGlyph.Welcome => WelcomeGlyph,
                _ => BookGlyph,
            };
            int? color = usesDefault && state.DefaultColor >= 0 ? state.DefaultColor : state.IconColor;
            _glyph.Foreground = color is { } lane
                ? TabColors.Brush(TabColors.Lane(lane))
                : PaletteResources.Brush(state.Selected ? "TabTitleSelectedBrush" : "TabTitleBrush");
        }

        if (state.ProfileColor is { } profile)
        {
            _dot.Fill = TabColors.Brush(profile);
            _dot.Visibility = Visibility.Visible;
            ToolTipService.SetToolTip(_dot, $"Profile {state.ProfileName}");
        }
        else
        {
            _dot.Visibility = Visibility.Collapsed;
        }
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new TabIconAutomationPeer(this);

    /// <summary>What an icon slot value shows: an image reference unless its image was found missing, else its last
    /// emoji (<see cref="TabEmoji.Normalized"/>) when that is short enough; null for none.</summary>
    private static string? Present(string? value, CustomIconImages images)
    {
        if (string.IsNullOrEmpty(value))
            return null;
        if (CustomIcon.IsRef(value))
            return images.IsMissing(value) ? null : value;
        return TabEmoji.Normalized(value) is { Length: > 0 and <= DisplayText.MaxElementLength } emoji
            && DisplayText.Sanitize(emoji) is { Length: > 0 } shown
            ? shown
            : null;
    }
}

/// <summary>A tab's icon in UI Automation: an Image named by the emoji it shows, or "Custom icon"; with the glyph it
/// is not read. It has no children (its emoji is its name).</summary>
internal sealed partial class TabIconAutomationPeer(TabIcon owner) : FrameworkElementAutomationPeer(owner)
{
    protected override string GetNameCore() => owner.ShownName ?? string.Empty;

    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;

    protected override string GetClassNameCore() => nameof(TabIcon);

    protected override IList<AutomationPeer>? GetChildrenCore() => null;

    protected override bool IsControlElementCore() => owner.ShownName is not null;

    protected override bool IsContentElementCore() => owner.ShownName is not null;
}

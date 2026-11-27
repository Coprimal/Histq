using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
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
    private const int LaneCount = 8;

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
/// A tab's icon in its 16 epx slot (ported from TabIcon, App/Window/TabStrip.swift): its own emoji, else (a book with
/// neither its own icon nor its own color) Settings › Appearance's default tab icon, else its glyph, tinted by its own
/// color or the default color, else the title's color. The profile's color dot sits on its lower-right corner in a
/// white ring. Uploaded image icons (<c>icon:&lt;sha&gt;</c>) arrive with the icon library (task 10.3); until then a
/// reference counts as no icon, as a missing image does on the Mac.
/// </summary>
internal sealed partial class TabIcon : Grid
{
    /// <summary>Segoe Fluent Icons: Dictionary (the closed book the command bar's repo button shows), Unknown, Add.</summary>
    private const string BookGlyph = "";
    private const string MissingGlyph = "";
    private const string WelcomeGlyph = "";

    private readonly TextBlock _emoji;
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
        Children.Add(_glyph);
        Children.Add(_dot);
    }

    /// <summary>The emoji shown, or null when the glyph is (UI Automation reads it with the tab's name).</summary>
    public string? ShownEmoji => _emoji.Visibility == Visibility.Visible ? _emoji.Text : null;

    public void Update(TabIconState state)
    {
        if (_shown == state)
            return;
        _shown = state;

        string? own = state.Emoji is { } mark && !CustomIcon.IsRef(mark) ? mark : null;
        bool usesDefault = own is null && state.IconColor is null && state.Glyph == TabGlyph.Book;
        string? fallback = CustomIcon.IsRef(state.DefaultEmoji) ? null : TabEmoji.Normalized(state.DefaultEmoji);
        string? emoji = own ?? (usesDefault ? fallback : null);

        if (emoji is not null)
        {
            _emoji.Text = emoji;
            _emoji.Visibility = Visibility.Visible;
            _glyph.Visibility = Visibility.Collapsed;
        }
        else
        {
            _emoji.Visibility = Visibility.Collapsed;
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
}

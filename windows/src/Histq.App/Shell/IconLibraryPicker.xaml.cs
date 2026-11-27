using System.Diagnostics;
using Histq.App.Shell.Tabs;
using Histq.App.Support;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Histq.App.Shell;

/// <summary>
/// The uploaded images to pick a tab icon from (ported from IconLibraryPicker.swift at 6fa6d40): Upload…, then the
/// stored images newest first, the selected one ringed in the brand blue. A click selects at once; each image has a
/// small delete button (no confirm: the dialog it sits in holds the window's one dialog). Upload… opens a file picker
/// owned by the window; the file is checked (<see cref="CustomIcon"/>: its first bytes, its size, an SVG self-contained)
/// and stored on a worker, and a refused file shows a toast. The list and every thumbnail load off the UI thread and
/// load again when the images change (<see cref="CustomIconImages.Changed"/>).
/// </summary>
public sealed partial class IconLibraryPicker : UserControl
{
    private const double Side = 30;
    private const double ImageSide = 20;
    private const double DeleteSide = 14;

    private static readonly SolidColorBrush NoRing = new(Colors.Transparent);

    /// <summary>Segoe Fluent Icons: Photo (an image found missing), Cancel (delete).</summary>
    private const string MissingGlyph = "";
    private const string DeleteGlyph = "";

    private MainWindow? _window;
    private string? _selection;
    private IReadOnlyList<string> _refs = [];

    /// <summary>Each shown thumbnail's button and ring, by reference, so a new selection only recolors the rings.</summary>
    private readonly Dictionary<string, (Button Pick, Border Ring)> _cells = new(StringComparer.Ordinal);

    /// <summary>Bumped on each listing: a newer one drops an older one's result.</summary>
    private int _listing;

    private bool _subscribed;

    public IconLibraryPicker()
    {
        InitializeComponent();
        ToolTipService.SetToolTip(UploadButton,
            $"Add a PNG, JPEG, WebP or SVG image of up to {CustomIcon.MaxBytes / 1024} KB; "
            + $"a bitmap must be {CustomIcon.MinSide}–{CustomIcon.MaxSide} px a side");
        UploadButton.Click += OnUploadClick;
        Loaded += (_, _) =>
        {
            if (!_subscribed)
            {
                _subscribed = true;
                CustomIconImages.Shared.Changed += OnImagesChanged;
            }

            List();
        };
        Unloaded += (_, _) =>
        {
            if (_subscribed && !IsLoaded)
            {
                _subscribed = false;
                CustomIconImages.Shared.Changed -= OnImagesChanged;
            }
        };
    }

    /// <summary>The chosen image's reference changed (a click, an upload, a delete of the chosen one).</summary>
    internal event EventHandler? SelectionChanged;

    /// <summary>The chosen image's reference (<see cref="CustomIcon"/>); null for none.</summary>
    internal string? Selection
    {
        get => _selection;
        set
        {
            if (string.Equals(_selection, value, StringComparison.Ordinal))
                return;
            _selection = value;
            ShowSelection();
            SelectionChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>The window that owns the file picker and shows the toasts; call before the picker is shown.</summary>
    internal void Attach(MainWindow window) => _window = window;

    /// <summary>Stops following the icon images (the dialog holding it closed), whatever Unloaded did.</summary>
    internal void Detach()
    {
        if (!_subscribed)
            return;
        _subscribed = false;
        CustomIconImages.Shared.Changed -= OnImagesChanged;
    }

    private void OnImagesChanged(object? sender, EventArgs e) => List();

    /// <summary>Lists the stored images on a worker, then shows them.</summary>
    private async void List()
    {
        int listing = ++_listing;
        IReadOnlyList<string> refs;
        try
        {
            refs = await CustomIconImages.Shared.RefsAsync();
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Icon library (not listed)", error);
            return;
        }

        if (listing != _listing)
            return;
        if (refs.SequenceEqual(_refs, StringComparer.Ordinal))
        {
            // The same images: only the thumbnails whose image loaded or went missing change, so the focus stays.
            foreach ((string reference, (Button pick, _)) in _cells)
                pick.Content = ThumbnailContent(reference, pick.Content);
            return;
        }

        _refs = refs;
        Rebuild();
    }

    /// <summary>One thumbnail per stored image; the row shows only when there is one.</summary>
    private void Rebuild()
    {
        Thumbnails.Children.Clear();
        _cells.Clear();
        foreach (string reference in _refs)
            Thumbnails.Children.Add(Thumbnail(reference));
        UploadedRow.Visibility = _refs.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowSelection();
    }

    /// <summary>The selected thumbnail's ring in the brand blue, the others' clear; UI Automation names follow.</summary>
    private void ShowSelection()
    {
        foreach ((string reference, (Button pick, Border ring)) in _cells)
        {
            bool selected = string.Equals(reference, _selection, StringComparison.Ordinal);
            ring.BorderBrush = selected ? PaletteResources.Brush("BrandAccentBrush") : NoRing;
            AutomationProperties.SetName(pick, selected ? "Uploaded image, selected" : "Uploaded image");
        }
    }

    /// <summary>One stored image fitted in a small rounded square: a click selects it, the selected one has a blue
    /// ring, and a small delete button sits on its top-right corner. Empty until its image has loaded.</summary>
    private Grid Thumbnail(string reference)
    {
        var corner = new CornerRadius(7);
        var pick = new Button
        {
            Width = Side,
            Height = Side,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = corner,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Content = ThumbnailContent(reference, null),
        };
        TabStrip.StyleButton(pick, TabColors.Brush(PaletteResources.Color("InputSurfaceColor")),
            PaletteResources.Brush("HoverFillBrush"), PaletteResources.Brush("PressedFillBrush"));
        ToolTipService.SetToolTip(pick, "Use this image");
        pick.Click += (_, _) => Selection = reference;

        var ring = new Border
        {
            Width = Side,
            Height = Side,
            CornerRadius = corner,
            BorderThickness = new Thickness(2),
            BorderBrush = NoRing,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            IsHitTestVisible = false,
        };

        var delete = new Button
        {
            Width = DeleteSide,
            Height = DeleteSide,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(DeleteSide / 2),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Content = new FontIcon { Glyph = DeleteGlyph, FontSize = 7 },
        };
        TabStrip.StyleButton(delete, TabColors.Brush(PaletteResources.Color("InputSurfaceColor")),
            PaletteResources.Brush("HoverFillBrush"), PaletteResources.Brush("PressedFillBrush"));
        AutomationProperties.SetName(delete, "Delete image");
        ToolTipService.SetToolTip(delete, "Delete this image");
        delete.Click += (_, _) => Delete(reference);

        // The delete button stands half out of the square's corner, inside the cell (the row's scroller clips).
        var cell = new Grid { Width = Side + DeleteSide / 2, Height = Side + DeleteSide / 2 };
        cell.Children.Add(pick);
        cell.Children.Add(ring);
        cell.Children.Add(delete);
        _cells[reference] = (pick, ring);
        return cell;
    }

    /// <summary>What a thumbnail shows: its image once loaded (the load starts here), a photo glyph when it is missing,
    /// else an empty square; <paramref name="shown"/> when it already shows that.</summary>
    private static object ThumbnailContent(string reference, object? shown)
    {
        CustomIconImages images = CustomIconImages.Shared;
        ImageSource? source = images.Image(reference);
        if (source is not null)
        {
            return shown is Image { Source: { } current } && ReferenceEquals(current, source)
                ? shown
                : new Image { Source = source, Width = ImageSide, Height = ImageSide, Stretch = Stretch.Uniform };
        }

        if (images.IsMissing(reference))
            return shown as FontIcon ?? new FontIcon { Glyph = MissingGlyph, FontSize = 14, Opacity = 0.6 };
        images.Load(reference);
        return shown as Border ?? new Border { Width = ImageSide, Height = ImageSide };
    }

    /// <summary>Deletes the stored image: it leaves the list at once, and the selection when it was selected.</summary>
    private void Delete(string reference)
    {
        _refs = _refs.Where(candidate => !string.Equals(candidate, reference, StringComparison.Ordinal)).ToList();
        Rebuild();
        if (string.Equals(_selection, reference, StringComparison.Ordinal))
            Selection = null;
        CustomIconImages.Shared.Remove(reference);
    }

    /// <summary>Asks for an image file, stores it on a worker and selects it; a refused image shows a toast. The
    /// button is off at once and until the upload has finished.</summary>
    private async void OnUploadClick(object sender, RoutedEventArgs e)
    {
        if (_window is not { } window || !UploadButton.IsEnabled)
            return;
        UploadButton.IsEnabled = false;
        try
        {
            string? path = await PickAsync(window);
            if (string.IsNullOrEmpty(path))
                return;
            Selection = await CustomIconImages.Shared.UploadAsync(path);
        }
        catch (CustomIcon.Problem problem)
        {
            window.ShowToast("Image not added", problem.Message);
        }
        catch (Exception error)
        {
            // Expected (a failed write: disk full, access denied): a toast, not a crash.log entry. The message may
            // name the user's paths, so only its kind is logged.
            Trace.WriteLine($"Histq: icon upload failed: {error.GetType().Name}");
            window.ShowToast("Image not added", "The image could not be saved.");
        }
        finally
        {
            UploadButton.IsEnabled = true;
        }
    }

    /// <summary>The picked file's path; null when cancelled, for a file with no path (a virtual folder's), or when the
    /// picker does not open.</summary>
    private static async Task<string?> PickAsync(MainWindow window)
    {
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
            foreach (string type in (string[])[".png", ".jpg", ".jpeg", ".webp", ".svg"])
                picker.FileTypeFilter.Add(type);
            // An unpackaged app's picker needs its owner window.
            InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));
            StorageFile? file = await picker.PickSingleFileAsync();
            return file?.Path;
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Icon picker (not shown)", error);
            return null;
        }
    }
}

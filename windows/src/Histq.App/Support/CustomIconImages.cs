using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using Histq.App.Shell;
using Histq.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Svg;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Histq.App.Support;

/// <summary>
/// The uploaded tab icons (<see cref="CustomIcon"/> references) as images (ported from CustomIconImages.swift at
/// 6fa6d40). <see cref="Image"/> only reads the cache, so a draw never waits on the disk: a view asks
/// <see cref="Load"/> for a reference it has no image for, which reads and decodes the file on a worker and raises
/// <see cref="Changed"/> on the UI thread once the image (or its absence) is known. A reference that does not parse or
/// names a missing or undecodable file is recorded as missing once and never retried per draw, until an upload of the
/// same image clears it. Raster images go through BitmapDecoder only when <see cref="CustomIcon.IsStoredRaster"/> holds
/// for the stored bytes (a PNG, JPEG or WebP whose type matches the file's extension and whose header size is in range,
/// so no other codec ever reads them), refused past <see cref="CustomIcon.MaxSide"/>²
/// pixels as the decoder reads them (headers can lie), and are scaled down to <see cref="DecodePixels"/> on their longer
/// side; an SVG is drawn with Win2D's CanvasSvgDocument only when <see cref="CustomIcon.IsSelfContainedSvg"/> holds for
/// the stored bytes (no script, image, style sheet or outside reference, so nothing is fetched). An upload that does
/// not decode is deleted again and refused (the Mac checks SVGs only). Every file read is bounded (<see cref="CustomIcon.ReadFile"/>). Call
/// on the UI thread; the bitmaps are made there.
/// </summary>
internal sealed class CustomIconImages
{
    /// <summary>The longer side, in pixels, an image is decoded or an SVG drawn at: sharp at every size a tab icon or a
    /// thumbnail takes (20 epx at 300 %).</summary>
    private const int DecodePixels = 128;

    private static CustomIconImages? s_shared;

    private readonly CustomIcon.Library _library;

    /// <summary>Loaded images, by reference.</summary>
    private readonly Dictionary<string, ImageSource> _images = new(StringComparer.Ordinal);

    /// <summary>References whose load found no image: an invalid reference, a missing or undecodable file.</summary>
    private readonly HashSet<string> _missing = new(StringComparer.Ordinal);

    /// <summary>References being loaded, with the token of their load: a load that an upload or a removal superseded
    /// (its token is gone) drops its result.</summary>
    private readonly Dictionary<string, int> _inFlight = new(StringComparer.Ordinal);

    /// <summary>References whose file is being deleted.</summary>
    private readonly HashSet<string> _removing = new(StringComparer.Ordinal);

    private int _nextToken;

    private CustomIconImages(string directory) => _library = new CustomIcon.Library(directory);

    /// <summary>The app's icons, in the state folder's <c>Icons</c> folder (as StatePaths.Directory("Icons"); created
    /// by the first upload, never here, so nothing touches the disk on the UI thread).</summary>
    public static CustomIconImages Shared =>
        s_shared ??= new CustomIconImages(Path.Combine(((App)Application.Current).StatePaths.Root, "Icons"));

    /// <summary>An image was loaded or found missing, uploaded or removed. Raised on the UI thread.</summary>
    public event EventHandler? Changed;

    /// <summary>The cached image of <paramref name="reference"/>; null until <see cref="Load"/> has loaded it. Never
    /// reads the disk.</summary>
    public ImageSource? Image(string reference) => _images.GetValueOrDefault(reference);

    /// <summary>Whether the load of <paramref name="reference"/> found no image.</summary>
    public bool IsMissing(string reference) => _missing.Contains(reference);

    /// <summary>Decodes the image of <paramref name="reference"/> on a worker, then caches it or records it as missing
    /// and raises <see cref="Changed"/>. Nothing when it is cached, missing or already being loaded.</summary>
    public async void Load(string reference)
    {
        if (_images.ContainsKey(reference) || _missing.Contains(reference) || _inFlight.ContainsKey(reference))
            return;
        int token = ++_nextToken;
        _inFlight[reference] = token;
        Decoded? decoded;
        try
        {
            decoded = await Task.Run(() => DecodeAsync(_library.PathFor(reference)));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Icon image (not decoded)", error);
            decoded = null;
        }

        // The await resumes on the UI thread.
        if (!_inFlight.TryGetValue(reference, out int current) || current != token)
            return;
        _inFlight.Remove(reference);
        ImageSource? image = decoded is null ? null : Bitmap(decoded);
        if (image is null)
            _missing.Add(reference);
        else
            _images[reference] = image;
        RaiseChanged();
    }

    /// <summary>Checks and stores the image at <paramref name="path"/> on a worker and returns its reference; an image
    /// that does not decode (past the decoder's pixel cap, a broken body, an SVG that does not draw) is deleted again
    /// and refused. Throws a <see cref="CustomIcon.Problem"/> for a refused image, or the error
    /// of a failed write.</summary>
    public async Task<string> UploadAsync(string path)
    {
        string reference = await Task.Run(async () =>
        {
            string added = _library.Add(path);
            if (await DecodeAsync(_library.PathFor(added)) is null)
            {
                _library.Remove(added);
                throw CustomIcon.Problem.Unreadable();
            }

            return added;
        });
        Forget(reference);
        RaiseChanged();
        return reference;
    }

    /// <summary>Deletes the stored image of <paramref name="reference"/> on a worker; tabs still using it show it as
    /// missing at once, and <see cref="RefsAsync"/> leaves it out from now on. <see cref="Changed"/> is raised at once
    /// and again once the file is gone.</summary>
    public async void Remove(string reference)
    {
        Forget(reference);
        _missing.Add(reference);
        _removing.Add(reference);
        RaiseChanged();
        try
        {
            await Task.Run(() => _library.Remove(reference));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Icon image (not deleted)", error);
        }

        _removing.Remove(reference);
        RaiseChanged();
    }

    /// <summary>The references of the stored images, newest first, listed on a worker; one being removed is left
    /// out.</summary>
    public async Task<IReadOnlyList<string>> RefsAsync()
    {
        IReadOnlyList<string> refs = await Task.Run(_library.Refs);
        return _removing.Count == 0 ? refs : refs.Where(reference => !_removing.Contains(reference)).ToList();
    }

    /// <summary>Drops what is known of <paramref name="reference"/>, including a load in flight, so the next
    /// <see cref="Load"/> reads the file again.</summary>
    private void Forget(string reference)
    {
        _images.Remove(reference);
        _missing.Remove(reference);
        _inFlight.Remove(reference);
    }

    private void RaiseChanged()
    {
        try
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Icon images changed (views not refreshed)", error);
        }
    }

    // The worker half: reading and decoding.

    /// <summary>Premultiplied BGRA pixels, <see cref="Width"/> × <see cref="Height"/>, rows packed.</summary>
    private sealed record Decoded(byte[] Pixels, int Width, int Height);

    /// <summary>The image at <paramref name="file"/> decoded now; null for no file (an invalid reference) or a missing,
    /// refused or undecodable one.</summary>
    private static async Task<Decoded?> DecodeAsync(string? file)
    {
        if (file is null)
            return null;
        try
        {
            byte[] data = CustomIcon.ReadFile(file);
            bool svg = file.EndsWith("." + CustomIcon.SvgExtension, StringComparison.Ordinal);

            // Checked again on the stored bytes before any decoder sees them: the file may have been put there by hand.
            if (!svg && !CustomIcon.IsStoredRaster(file, data))
                return null;

            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(data.AsBuffer());
            stream.Seek(0);
            return svg
                ? await DrawSvgAsync(data, stream)
                : await DecodeRasterAsync(stream);
        }
        catch (Exception error)
        {
            // Expected for a missing, refused or broken file: logged, never shown.
            Trace.WriteLine($"Histq: icon not decoded: {error.GetType().Name}");
            return null;
        }
    }

    /// <summary>The first frame, refused when the decoder's own size is past <see cref="CustomIcon.MaxSide"/>² pixels
    /// (or either side past <see cref="CustomIcon.MaxSide"/>), scaled down to <see cref="DecodePixels"/>.</summary>
    private static async Task<Decoded?> DecodeRasterAsync(IRandomAccessStream stream)
    {
        BitmapDecoder decoder = await BitmapDecoder.CreateAsync(stream);
        uint width = decoder.PixelWidth;
        uint height = decoder.PixelHeight;
        if (width == 0 || height == 0 || width > CustomIcon.MaxSide || height > CustomIcon.MaxSide
            || (ulong)width * height > (ulong)CustomIcon.MaxSide * CustomIcon.MaxSide)
            return null;

        (int fitWidth, int fitHeight) = Fit(width, height, scaleUp: false);
        var transform = new BitmapTransform
        {
            ScaledWidth = (uint)fitWidth,
            ScaledHeight = (uint)fitHeight,
            InterpolationMode = BitmapInterpolationMode.Fant,
        };
        PixelDataProvider pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.IgnoreExifOrientation,
            ColorManagementMode.DoNotColorManage);
        byte[] bytes = pixels.DetachPixelData();
        return bytes.Length == fitWidth * fitHeight * 4 ? new Decoded(bytes, fitWidth, fitHeight) : null;
    }

    /// <summary>A self-contained SVG drawn by Win2D at <see cref="DecodePixels"/> on its longer side, its aspect kept
    /// (from its viewBox, else its plain width and height); null when it is not self-contained or does not draw.</summary>
    private static async Task<Decoded?> DrawSvgAsync(byte[] data, IRandomAccessStream stream)
    {
        // Checked again on the stored bytes: the file may predate the upload check or have been put there by hand.
        if (!CustomIcon.IsSelfContainedSvg(data))
            return null;

        CanvasDevice device = CanvasDevice.GetSharedDevice();
        using CanvasSvgDocument document = await CanvasSvgDocument.LoadAsync(device, stream);
        CanvasSvgNamedElement root = document.Root;
        Rect? box = root.IsAttributeSpecified("viewBox") ? root.GetRectangleAttribute("viewBox") : null;
        if (box is null && root.IsAttributeSpecified("width") && root.IsAttributeSpecified("height"))
        {
            float width = root.GetLengthAttribute("width", out CanvasSvgLengthUnits widthUnits);
            float height = root.GetLengthAttribute("height", out CanvasSvgLengthUnits heightUnits);
            if (widthUnits == CanvasSvgLengthUnits.Number && heightUnits == CanvasSvgLengthUnits.Number
                && width > 0 && height > 0 && float.IsFinite(width) && float.IsFinite(height))
            {
                box = new Rect(0, 0, width, height);
                root.SetRectangleAttribute("viewBox", box.Value);
            }
        }

        // The document fills the viewport, its viewBox mapped into it.
        root.SetLengthAttribute("width", 100, CanvasSvgLengthUnits.Percentage);
        root.SetLengthAttribute("height", 100, CanvasSvgLengthUnits.Percentage);
        (int pixelWidth, int pixelHeight) = box is { Width: > 0 and < double.PositiveInfinity, Height: > 0 and < double.PositiveInfinity } shape
            ? Fit(shape.Width, shape.Height, scaleUp: true)
            : (DecodePixels, DecodePixels);

        using var target = new CanvasRenderTarget(device, pixelWidth, pixelHeight, 96);
        using (CanvasDrawingSession session = target.CreateDrawingSession())
        {
            session.Clear(Colors.Transparent);
            session.DrawSvg(document, new Size(pixelWidth, pixelHeight));
        }

        byte[] bytes = target.GetPixelBytes();
        return bytes.Length == pixelWidth * pixelHeight * 4 ? new Decoded(bytes, pixelWidth, pixelHeight) : null;
    }

    /// <summary><paramref name="width"/> × <paramref name="height"/> scaled to <see cref="DecodePixels"/> on the longer
    /// side (a bitmap only down, never up; a vector both ways), at least 1 pixel a side.</summary>
    private static (int Width, int Height) Fit(double width, double height, bool scaleUp)
    {
        double scale = DecodePixels / Math.Max(width, height);
        if (!scaleUp)
            scale = Math.Min(1, scale);
        return (Math.Max(1, (int)Math.Round(width * scale)), Math.Max(1, (int)Math.Round(height * scale)));
    }

    /// <summary>A bitmap of <paramref name="decoded"/>, made on the UI thread; null when it cannot be made.</summary>
    private static WriteableBitmap? Bitmap(Decoded decoded)
    {
        try
        {
            var bitmap = new WriteableBitmap(decoded.Width, decoded.Height);
            using (Stream pixels = bitmap.PixelBuffer.AsStream())
                pixels.Write(decoded.Pixels);
            bitmap.Invalidate();
            return bitmap;
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Icon bitmap (not made)", error);
            return null;
        }
    }
}

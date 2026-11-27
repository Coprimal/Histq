// Key feature and untrusted-input tests for uploaded tab icons: a reference read from a file names a file only when it
// parses strictly (no traversal, no other shape), and the library stores a valid image once under its hash while
// refusing a wrong size, a non-image, an SVG with a DTD, a cut-short header or an oversized file without writing
// anything. Ported from CustomIconTests.swift at 6fa6d40; the images are built byte by byte here (the Swift tests draw
// them with CoreGraphics), and the JPEG, WebP, DTD, truncation and size cases are added because this port reads
// image headers itself instead of ImageIO.
using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace Histq.Core.Tests;

public sealed class CustomIconTests
{
    /// <summary>A well-formed name's hash part: 64 lowercase hex digits.</summary>
    private static readonly string Hash = string.Concat(Enumerable.Repeat("0123456789abcdef", 4));

    public static TheoryData<string> MalformedReferences => new(
        "icon:../x.png",
        $"icon:../{Hash}.png",
        $"icon:{Hash}/../x.png",
        $"icon:sub/{Hash}.png",
        $"icon:/{Hash}.png",
        $"icon:{Hash.ToUpperInvariant()}.png",
        $"icon:{Hash}.gif",
        $"icon:{Hash}.PNG",
        $"icon:{Hash}.png.png",
        $"icon:{Hash}..png",
        $"icon:{Hash}",
        $"icon:{Hash[..^1]}.png",
        $"icon:{Hash}0.png",
        "icon:",
        $"{Hash}.png",
        $"ICON:{Hash}.png",
        $" icon:{Hash}.png",
        $@"icon:..\{Hash}.png");

    // References.

    // A malformed or path-traversal reference names no file.
    [Theory]
    [MemberData(nameof(MalformedReferences))]
    public void RejectsMalformedReference(string reference)
    {
        Assert.Null(CustomIcon.FileName(reference));
        Assert.False(CustomIcon.IsRef(reference));
        Assert.Null(new CustomIcon.Library(Path.Join(Path.GetTempPath(), "HistqIcons")).PathFor(reference));
    }

    // A valid reference names its file directly inside the folder.
    [Theory]
    [InlineData("png")]
    [InlineData("jpg")]
    [InlineData("webp")]
    [InlineData("svg")]
    public void AcceptsValidReference(string extension)
    {
        var name = $"{Hash}.{extension}";
        var reference = CustomIcon.Ref(name);
        Assert.Equal($"icon:{name}", reference);
        Assert.Equal(name, CustomIcon.FileName(reference));
        Assert.True(CustomIcon.IsRef(reference));

        var directory = Path.Join(Path.GetTempPath(), "HistqIcons");
        var file = new CustomIcon.Library(directory).PathFor(reference);
        Assert.NotNull(file);
        Assert.Equal(name, Path.GetFileName(file));
        Assert.Equal(Path.GetFullPath(directory), Path.GetDirectoryName(Path.GetFullPath(file)));
    }

    // Library.

    // A valid PNG added twice is stored once, under the SHA-256 of its bytes, with the same reference.
    [Fact]
    public void AddStoresOnceUnderHash()
    {
        using var folder = new TempFolder();
        var data = Png(32, 32);
        var upload = folder.Write("upload.png", data);
        var library = folder.Library();

        var first = library.Add(upload);
        var second = library.Add(upload);

        var expected = Convert.ToHexStringLower(SHA256.HashData(data)) + ".png";
        Assert.Equal(first, second);
        Assert.Equal(expected, CustomIcon.FileName(first));
        Assert.Equal([expected], Files(library.Directory));
        Assert.Equal(data, File.ReadAllBytes(library.PathFor(first)!));
        Assert.Equal([first], library.Refs());
    }

    // A PNG with a side out of range and a non-image are refused and nothing is stored.
    [Fact]
    public void AddRefusesWithoutStoring()
    {
        using var folder = new TempFolder();
        var library = folder.Library();

        var tiny = folder.Write("tiny.png", Png(8, 8));
        Assert.Equal(CustomIcon.Problem.SizeOutOfRange(8, 8), Assert.Throws<CustomIcon.Problem>(() => library.Add(tiny)));

        var text = folder.Write("notes.png", Encoding.UTF8.GetBytes("not an image, just text\n"));
        Assert.Throws<CustomIcon.Problem>(() => library.Add(text));

        Assert.Empty(Files(library.Directory));
        Assert.Empty(library.Refs());
    }

    // An SVG is stored with its extension; XML with another root, or an SVG with a DTD, is refused.
    [Fact]
    public void AddsSvg()
    {
        using var folder = new TempFolder();
        var library = folder.Library();

        var svg = folder.Write(
            "logo.svg", Encoding.UTF8.GetBytes("""<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"/>"""));
        var reference = library.Add(svg);
        Assert.EndsWith(".svg", reference, StringComparison.Ordinal);
        Assert.Equal([reference], library.Refs());

        var html = folder.Write("page.svg", Encoding.UTF8.GetBytes("<html><body/></html>"));
        Assert.Throws<CustomIcon.Problem>(() => library.Add(html));
        var entity = folder.Write("entity.svg", Encoding.UTF8.GetBytes(
            """<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg xmlns="http://www.w3.org/2000/svg">&x;</svg>"""));
        Assert.Throws<CustomIcon.Problem>(() => library.Add(entity));
        Assert.Equal([reference], library.Refs());
    }

    public static TheoryData<string> NotSelfContainedSvgs => new(
        """<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="data:image/png;base64,AA=="/></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><p>x</p></foreignObject></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg"><style>rect { fill: red }</style></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><use xlink:href="\\server\share\a.svg#x"/></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg"><use href="https://example.com/a.svg#x"/></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url( 'file:///C:/a.svg#g')"/></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill: URL(http://example.com/x)"/></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>""",
        """<?xml-stylesheet href="http://example.com/a.css"?><svg xmlns="http://www.w3.org/2000/svg"/>""",
        """<svg xmlns="http://www.w3.org/2000/svg"><use href="#r"><set attributeName="href" to="http://x/"/></use></svg>""",
        """<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:u\72l(http://x)"/></svg>""",
        "<svg xmlns=\"http://www.w3.org/2000/svg\">" + string.Concat(Enumerable.Repeat("<g>", CustomIcon.MaxSvgDepth + 1))
            + string.Concat(Enumerable.Repeat("</g>", CustomIcon.MaxSvgDepth + 1)) + "</svg>");

    // An SVG that runs code, loads another file or resource, or nests too deep is refused and nothing is stored.
    [Theory]
    [MemberData(nameof(NotSelfContainedSvgs))]
    public void AddRefusesSvgThatIsNotSelfContained(string svg)
    {
        using var folder = new TempFolder();
        var library = folder.Library();
        var file = folder.Write("icon.svg", Encoding.UTF8.GetBytes(svg));

        Assert.Equal(CustomIcon.Problem.NotSelfContained(), Assert.Throws<CustomIcon.Problem>(() => library.Add(file)));
        Assert.Empty(Files(library.Directory));
    }

    // References inside the document (a gradient by url(#id), a use by href="#id") are kept.
    [Fact]
    public void SvgWithFragmentReferencesIsSelfContained()
    {
        var svg = Encoding.UTF8.GetBytes(
            """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 8 8">
              <defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient><rect id="r" width="4" height="4"/></defs>
              <rect width="8" height="8" fill="url(#g)"/><use xlink:href="#r"/><use href=" #r"/>
            </svg>
            """);
        Assert.True(CustomIcon.IsSelfContainedSvg(svg));
    }

    // A Windows device path (pipes, devices) is refused before any read; drive, UNC and POSIX paths are not.
    [Theory]
    [InlineData(@"\\.\pipe\x", PathFlavor.Windows, true)]
    [InlineData(@"\\?\C:\a.png", PathFlavor.Windows, true)]
    [InlineData("//./CON", PathFlavor.Windows, true)]
    [InlineData(@"C:\a.png", PathFlavor.Windows, false)]
    [InlineData(@"\\server\share\a.png", PathFlavor.Windows, false)]
    [InlineData("//./x", PathFlavor.Posix, false)]
    public void DevicePathsAreRefused(string path, PathFlavor flavor, bool refused) =>
        Assert.Equal(refused, CustomIcon.IsDevicePath(path, flavor));

    // A file of exactly the limit is read whole.
    [Fact]
    public void ReadFileReadsUpToTheLimit()
    {
        using var folder = new TempFolder();
        var data = new byte[CustomIcon.MaxBytes];
        data[^1] = 7;
        Assert.Equal(data, CustomIcon.ReadFile(folder.Write("full.bin", data)));
        Assert.Equal(CustomIcon.Problem.Unreadable(),
            Assert.Throws<CustomIcon.Problem>(() => CustomIcon.ReadFile(Path.Join(Path.GetTempPath(), "HistqNoSuchFile.png"))));
    }

    // JPEG and WebP are recognised by their first bytes and measured from their headers, whatever the file's name.
    [Fact]
    public void JpegAndWebPAreSniffedAndMeasured()
    {
        using var folder = new TempFolder();
        var library = folder.Library();

        var jpeg = library.Add(folder.Write("photo.png", Jpeg(64, 48)));
        Assert.EndsWith(".jpg", jpeg, StringComparison.Ordinal);
        var lossless = library.Add(folder.Write("a.webp", WebPLossless(20, 512)));
        Assert.EndsWith(".webp", lossless, StringComparison.Ordinal);
        Assert.Equal(
            CustomIcon.Problem.SizeOutOfRange(600, 20),
            Assert.Throws<CustomIcon.Problem>(() => library.Add(folder.Write("wide.webp", WebPExtended(600, 20)))));
        Assert.Equal(2, library.Refs().Count);
    }

    // A stored raster file reaches a decoder only when its bytes are the type its extension names and its size is in
    // range: a GIF, a BMP or a JPEG saved under a .png name is refused before any decode.
    [Fact]
    public void StoredRasterMustMatchItsExtension()
    {
        var file = $"{Hash}.png";
        Assert.True(CustomIcon.IsStoredRaster(file, Png(32, 32)));
        Assert.False(CustomIcon.IsStoredRaster(file, Png(8, 8)));
        Assert.False(CustomIcon.IsStoredRaster(file, Jpeg(64, 48)));
        Assert.True(CustomIcon.IsStoredRaster($"{Hash}.jpg", Jpeg(64, 48)));
        byte[] gif = [.. "GIF89a"u8, 32, 0, 32, 0, 0, 0, 0, 0x3B];
        Assert.False(CustomIcon.IsStoredRaster(file, gif));
        byte[] bmp = [.. "BM"u8, .. new byte[52]];
        Assert.False(CustomIcon.IsStoredRaster(file, bmp));
    }

    // A known type whose header is cut short is unreadable, and a file over the limit is refused before it is read.
    [Fact]
    public void TruncatedAndOversizedFilesAreRefused()
    {
        using var folder = new TempFolder();
        var library = folder.Library();
        byte[][] truncated = [Png(32, 32)[..20], Jpeg(64, 48)[..12], WebPExtended(32, 32)[..18]];
        foreach (var data in truncated)
        {
            var file = folder.Write("cut.bin", data);
            Assert.Equal(CustomIcon.Problem.Unreadable(), Assert.Throws<CustomIcon.Problem>(() => library.Add(file)));
        }

        var big = folder.Write("big.png", new byte[CustomIcon.MaxBytes + 1]);
        Assert.Equal(
            CustomIcon.Problem.TooLarge(CustomIcon.MaxBytes + 1), Assert.Throws<CustomIcon.Problem>(() => library.Add(big)));
        Assert.Empty(Files(library.Directory));
    }

    /// <summary>The names of the files in <paramref name="folder"/>; empty when it does not exist.</summary>
    private static List<string> Files(string folder) =>
        Directory.Exists(folder) ? Directory.EnumerateFiles(folder).Select(file => Path.GetFileName(file)).ToList() : [];

    /// <summary>A valid RGBA PNG of <paramref name="width"/> x <paramref name="height"/> pixels in one colour.</summary>
    private static byte[] Png(int width, int height)
    {
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header, width);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), height);
        header[8] = 8; // Bit depth.
        header[9] = 6; // RGBA.
        var raw = new MemoryStream();
        for (var y = 0; y < height; y++)
        {
            raw.WriteByte(0); // No filter.
            for (var x = 0; x < width; x++)
            {
                raw.Write([0x33, 0x80, 0xE6, 0xFF]);
            }
        }

        var compressed = new MemoryStream();
        using (var zlib = new ZLibStream(compressed, CompressionLevel.Optimal, leaveOpen: true))
        {
            zlib.Write(raw.ToArray());
        }

        var png = new MemoryStream();
        png.Write([0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        WriteChunk(png, "IHDR", header);
        WriteChunk(png, "IDAT", compressed.ToArray());
        WriteChunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void WriteChunk(Stream stream, string type, byte[] data)
    {
        var length = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(length, data.Length);
        stream.Write(length);
        var typed = Encoding.ASCII.GetBytes(type).Concat(data).ToArray();
        stream.Write(typed);
        var crc = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(crc, Crc32(typed));
        stream.Write(crc);
    }

    private static uint Crc32(byte[] data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in data)
        {
            crc ^= b;
            for (var bit = 0; bit < 8; bit++)
            {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
            }
        }

        return ~crc;
    }

    /// <summary>A JPEG header: start of image, a JFIF segment, then a baseline start-of-frame with the size.</summary>
    private static byte[] Jpeg(int width, int height) =>
    [
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x10, (byte)'J', (byte)'F', (byte)'I', (byte)'F', 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xC0, 0x00, 0x11, 0x08, (byte)(height >> 8), (byte)height, (byte)(width >> 8), (byte)width,
        0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        0xFF, 0xD9,
    ];

    /// <summary>A WebP whose first chunk is lossless (<c>VP8L</c>).</summary>
    private static byte[] WebPLossless(int width, int height)
    {
        var bits = (uint)(width - 1) | ((uint)(height - 1) << 14);
        var payload = new byte[5];
        payload[0] = 0x2F;
        BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(1), bits);
        return Riff("VP8L", payload);
    }

    /// <summary>A WebP whose first chunk is extended (<c>VP8X</c>).</summary>
    private static byte[] WebPExtended(int width, int height)
    {
        var payload = new byte[10];
        payload[4] = (byte)(width - 1);
        payload[5] = (byte)((width - 1) >> 8);
        payload[6] = (byte)((width - 1) >> 16);
        payload[7] = (byte)(height - 1);
        payload[8] = (byte)((height - 1) >> 8);
        payload[9] = (byte)((height - 1) >> 16);
        return Riff("VP8X", payload);
    }

    private static byte[] Riff(string chunk, byte[] payload)
    {
        var file = new MemoryStream();
        var size = new byte[4];
        file.Write("RIFF"u8);
        BinaryPrimitives.WriteInt32LittleEndian(size, 4 + 8 + payload.Length);
        file.Write(size);
        file.Write("WEBP"u8);
        file.Write(Encoding.ASCII.GetBytes(chunk));
        BinaryPrimitives.WriteInt32LittleEndian(size, payload.Length);
        file.Write(size);
        file.Write(payload);
        return file.ToArray();
    }

    /// <summary>A temp folder for uploads, with the library in its <c>Icons</c> subfolder.</summary>
    private sealed class TempFolder : IDisposable
    {
        private readonly string _root = Fixtures.MakeTempDirectory("HistqCustomIcon");

        public CustomIcon.Library Library() => new(Path.Join(_root, "Icons"));

        public string Write(string name, byte[] data)
        {
            var file = Path.Join(_root, name);
            File.WriteAllBytes(file, data);
            return file;
        }

        public void Dispose() => Fixtures.RemoveTempDirectory(_root);
    }
}

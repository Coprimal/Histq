// Uploaded images used as tab icons. A tab icon slot holds one string: an emoji or a reference `icon:<name>`, where
// `<name>` is the lowercase hex SHA-256 of the image's bytes plus the extension of its detected type. The images live
// in one folder (Library). Uploads and the references read from session and workspace files are untrusted: a reference
// is parsed strictly before it names a file, so it never leaves the folder, and an upload is size-checked before it is
// read. Its type comes from its first bytes (PNG, JPEG, WebP) and its pixel size from its header, never from its name;
// nothing is decoded here. An SVG is recognised by its root element `<svg>`, read with XmlReader with DTDs prohibited
// and no resolver (so no entity expansion and no external reference), and has no pixel size to check; the app draws
// it. Ported from CustomIcon.swift at 6fa6d40, where ImageIO sniffs and measures the image.
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Xml;

namespace Histq.Core;

public static class CustomIcon
{
    /// <summary>The largest file accepted, in bytes.</summary>
    public const int MaxBytes = 512 * 1024;

    /// <summary>The smallest accepted width and height, in pixels.</summary>
    public const int MinSide = 16;

    /// <summary>The largest accepted width and height, in pixels.</summary>
    public const int MaxSide = 512;

    /// <summary>The marker that starts a reference.</summary>
    public const string Prefix = "icon:";

    /// <summary>The extension an SVG is stored with.</summary>
    public const string SvgExtension = "svg";

    /// <summary>The extensions the accepted bitmap types (PNG, JPEG, WebP) are stored with.</summary>
    internal static readonly string[] ImageExtensions = ["png", "jpg", "webp"];

    /// <summary>The reference for a stored file name.</summary>
    public static string Ref(string fileName) => Prefix + fileName;

    /// <summary>The file name a reference names, or null when the value is not a valid reference.</summary>
    public static string? FileName(string reference)
    {
        if (!reference.StartsWith(Prefix, StringComparison.Ordinal))
        {
            return null;
        }

        var name = reference[Prefix.Length..];
        return IsValidFileName(name) ? name : null;
    }

    /// <summary>Whether the value is a valid reference.</summary>
    public static bool IsRef(string? value) => value is not null && FileName(value) is not null;

    /// <summary>Exactly 64 lowercase hex digits, a dot and one accepted extension: nothing that can leave the folder.</summary>
    public static bool IsValidFileName(string name)
    {
        var parts = name.Split('.');
        if (parts.Length != 2
            || !(ImageExtensions.Contains(parts[1], StringComparer.Ordinal)
                 || string.Equals(parts[1], SvgExtension, StringComparison.Ordinal)))
        {
            return false;
        }

        return parts[0].Length == 64 && parts[0].All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));
    }

    /// <summary>Whether <paramref name="data"/> is an XML document whose root element is <c>svg</c> (by local name).
    /// Only the start of the document is read; a DTD, malformed XML or anything else is not an SVG.</summary>
    internal static bool IsSvg(byte[] data)
    {
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
            IgnoreWhitespace = true,
        };
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(data, writable: false), settings);
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element)
                {
                    return string.Equals(reader.LocalName, "svg", StringComparison.Ordinal);
                }
            }
        }
        catch (XmlException)
        {
        }

        return false;
    }

    /// <summary>
    /// The stored extension and pixel size of a PNG, JPEG or WebP image, from its first bytes and header. Throws
    /// <see cref="Problem"/>: <see cref="ProblemKind.UnsupportedType"/> for any other bytes,
    /// <see cref="ProblemKind.Unreadable"/> for a known type whose header is cut short or malformed.
    /// </summary>
    internal static (string Extension, int Width, int Height) Sniff(ReadOnlySpan<byte> data)
    {
        if (data.StartsWith((ReadOnlySpan<byte>)[0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]))
        {
            return PngSize(data) is { } size ? ("png", size.Width, size.Height) : throw Problem.Unreadable();
        }

        if (data.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xD8, 0xFF]))
        {
            return JpegSize(data) is { } size ? ("jpg", size.Width, size.Height) : throw Problem.Unreadable();
        }

        if (data.Length >= 12 && data[..4].SequenceEqual("RIFF"u8) && data[8..12].SequenceEqual("WEBP"u8))
        {
            return WebPSize(data) is { } size ? ("webp", size.Width, size.Height) : throw Problem.Unreadable();
        }

        throw Problem.UnsupportedType();
    }

    /// <summary>The IHDR chunk's width and height, which must come first.</summary>
    private static (int Width, int Height)? PngSize(ReadOnlySpan<byte> data)
    {
        if (data.Length < 24 || !data[12..16].SequenceEqual("IHDR"u8))
        {
            return null;
        }

        var width = BinaryPrimitives.ReadInt32BigEndian(data[16..]);
        var height = BinaryPrimitives.ReadInt32BigEndian(data[20..]);
        return width > 0 && height > 0 ? (width, height) : null;
    }

    /// <summary>The size in the first start-of-frame segment, walking the segments from the start.</summary>
    private static (int Width, int Height)? JpegSize(ReadOnlySpan<byte> data)
    {
        var index = 2;
        while (index < data.Length)
        {
            if (data[index] != 0xFF)
            {
                return null;
            }

            while (index < data.Length && data[index] == 0xFF)
            {
                index++;
            }

            if (index >= data.Length)
            {
                return null;
            }

            var marker = data[index++];
            if (marker is 0x01 or 0xD8 or (>= 0xD0 and <= 0xD7))
            {
                continue; // A marker without a length.
            }

            if (marker is 0xD9 or 0xDA || index + 2 > data.Length)
            {
                return null; // End of image or start of scan before any frame, or cut short.
            }

            var length = BinaryPrimitives.ReadUInt16BigEndian(data[index..]);
            if (length < 2)
            {
                return null;
            }

            if (marker is >= 0xC0 and <= 0xCF and not (0xC4 or 0xC8 or 0xCC))
            {
                if (length < 7 || index + 7 > data.Length)
                {
                    return null;
                }

                int height = BinaryPrimitives.ReadUInt16BigEndian(data[(index + 3)..]);
                int width = BinaryPrimitives.ReadUInt16BigEndian(data[(index + 5)..]);
                return width > 0 && height > 0 ? (width, height) : null;
            }

            index += length;
        }

        return null;
    }

    /// <summary>The canvas size of the first chunk: lossy (<c>VP8 </c>), lossless (<c>VP8L</c>) or extended (<c>VP8X</c>).</summary>
    private static (int Width, int Height)? WebPSize(ReadOnlySpan<byte> data)
    {
        if (data.Length < 20)
        {
            return null;
        }

        var chunk = data[12..16];
        if (chunk.SequenceEqual("VP8 "u8))
        {
            if (data.Length < 30 || data[23] != 0x9D || data[24] != 0x01 || data[25] != 0x2A)
            {
                return null;
            }

            return (BinaryPrimitives.ReadUInt16LittleEndian(data[26..]) & 0x3FFF,
                BinaryPrimitives.ReadUInt16LittleEndian(data[28..]) & 0x3FFF);
        }

        if (chunk.SequenceEqual("VP8L"u8))
        {
            if (data.Length < 25 || data[20] != 0x2F)
            {
                return null;
            }

            var bits = BinaryPrimitives.ReadUInt32LittleEndian(data[21..]);
            return ((int)(bits & 0x3FFF) + 1, (int)((bits >> 14) & 0x3FFF) + 1);
        }

        if (chunk.SequenceEqual("VP8X"u8))
        {
            if (data.Length < 30)
            {
                return null;
            }

            return (1 + (data[24] | (data[25] << 8) | (data[26] << 16)), 1 + (data[27] | (data[28] << 8) | (data[29] << 16)));
        }

        return null;
    }

    /// <summary>Why an image was refused.</summary>
    public enum ProblemKind
    {
        TooLarge,
        UnsupportedType,
        SizeOutOfRange,
        Unreadable,
    }

    /// <summary>Why an image was refused, with a user-facing <see cref="Exception.Message"/>. Equal when the kind and
    /// its numbers are equal.</summary>
    public sealed class Problem : Exception, IEquatable<Problem>
    {
        private Problem(ProblemKind kind, int bytes, int width, int height, string message)
            : base(message)
        {
            Kind = kind;
            Bytes = bytes;
            Width = width;
            Height = height;
        }

        public ProblemKind Kind { get; }

        /// <summary>The file's size for <see cref="ProblemKind.TooLarge"/>, else 0.</summary>
        public int Bytes { get; }

        /// <summary>The image's width for <see cref="ProblemKind.SizeOutOfRange"/>, else 0.</summary>
        public int Width { get; }

        /// <summary>The image's height for <see cref="ProblemKind.SizeOutOfRange"/>, else 0.</summary>
        public int Height { get; }

        public static Problem TooLarge(int bytes) =>
            new(ProblemKind.TooLarge, bytes, 0, 0,
                $"The image is {((long)bytes + 1023) / 1024} KB; the limit is {MaxBytes / 1024} KB.");

        public static Problem UnsupportedType() =>
            new(ProblemKind.UnsupportedType, 0, 0, 0, "The file is not a supported image. Use a PNG, JPEG, WebP or SVG image.");

        public static Problem SizeOutOfRange(int width, int height) =>
            new(ProblemKind.SizeOutOfRange, 0, width, height,
                $"The image is {width} × {height} px; each side must be {MinSide}–{MaxSide} px.");

        public static Problem Unreadable() => new(ProblemKind.Unreadable, 0, 0, 0, "The image could not be read.");

        public bool Equals(Problem? other) =>
            other is not null && Kind == other.Kind && Bytes == other.Bytes && Width == other.Width && Height == other.Height;

        public override bool Equals(object? obj) => Equals(obj as Problem);

        public override int GetHashCode() => HashCode.Combine(Kind, Bytes, Width, Height);
    }

    /// <summary>The folder of uploaded images, one file per distinct image.</summary>
    public sealed class Library(string directory)
    {
        public string Directory { get; } = directory;

        /// <summary>
        /// Checks the image at <paramref name="path"/>, stores it unless the same image is already stored (then marks it
        /// as the newest) and returns its reference. Throws a <see cref="Problem"/> for a refused image, or the error of
        /// a failed write.
        /// </summary>
        public string Add(string path)
        {
            byte[] data;
            try
            {
                var size = new FileInfo(path).Length;
                if (size > MaxBytes)
                {
                    throw Problem.TooLarge((int)Math.Min(size, int.MaxValue));
                }

                data = File.ReadAllBytes(path);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                throw Problem.Unreadable();
            }

            if (data.Length > MaxBytes)
            {
                throw Problem.TooLarge(data.Length);
            }

            if (IsSvg(data))
            {
                return Store(data, SvgExtension);
            }

            var (extension, width, height) = Sniff(data);
            if (width is < MinSide or > MaxSide || height is < MinSide or > MaxSide)
            {
                throw Problem.SizeOutOfRange(width, height);
            }

            return Store(data, extension);
        }

        /// <summary>The references of the stored images, newest first; empty when the folder does not exist.</summary>
        public IReadOnlyList<string> Refs()
        {
            if (!System.IO.Directory.Exists(Directory))
            {
                return [];
            }

            return System.IO.Directory.EnumerateFiles(Directory)
                .Select(file => (Path: file, Name: System.IO.Path.GetFileName(file)))
                .Where(entry => IsValidFileName(entry.Name))
                .Select(entry => (entry.Name, Date: File.GetLastWriteTimeUtc(entry.Path)))
                .OrderByDescending(entry => entry.Date)
                .ThenBy(entry => entry.Name, StringComparer.Ordinal)
                .Select(entry => Ref(entry.Name))
                .ToList();
        }

        /// <summary>Deletes the stored image of a reference; nothing for an invalid reference or a missing file.</summary>
        public void Remove(string reference)
        {
            if (PathFor(reference) is not { } file)
            {
                return;
            }

            try
            {
                File.Delete(file);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
            }
        }

        /// <summary>The file a reference names, or null for an invalid reference. The file may not exist.</summary>
        public string? PathFor(string reference) =>
            FileName(reference) is { } name ? System.IO.Path.Join(Directory, name) : null;

        /// <summary>Stores <paramref name="data"/> under the SHA-256 of its bytes unless it is already stored (then
        /// marks it as the newest) and returns its reference.</summary>
        private string Store(byte[] data, string extension)
        {
            var name = Convert.ToHexStringLower(SHA256.HashData(data)) + "." + extension;
            var file = System.IO.Path.Join(Directory, name);
            System.IO.Directory.CreateDirectory(Directory);
            if (File.Exists(file))
            {
                File.SetLastWriteTimeUtc(file, DateTime.UtcNow);
                return Ref(name);
            }

            var temp = System.IO.Path.Join(Directory, $".{name}.{Guid.NewGuid():N}.tmp");
            try
            {
                File.WriteAllBytes(temp, data);
                File.Move(temp, file, overwrite: true);
            }
            catch
            {
                try
                {
                    File.Delete(temp);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                }

                throw;
            }

            return Ref(name);
        }
    }
}

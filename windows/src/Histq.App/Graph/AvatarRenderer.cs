using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using Histq.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Windows.UI;

namespace Histq.App.Graph;

/// <summary>
/// The commit nodes' avatars, drawn on this machine (the generated and initials part of AvatarStore in
/// App/Graph/AvatarStore.swift at 6fa6d40; real avatars come in M8): the avatarMode preference's "generated" (a 5x5
/// mirrored pattern in a lane color on a dark disc, from the SHA-256 of the author's identity, the default; "real"
/// draws it too until real avatars exist) or "initials" (the author's initials, light on a neutral disc). An author's
/// emoji (authorEmojis, by identity) wins over the mode, but never for an author without an email, a provider's
/// no-reply address or a GitHub bot.
/// <para>
/// Each avatar is drawn once into a round render target of the node's inner size on the canvas's device, kept by
/// author and by drawing (identity, initials or emoji), so a frame only draws images. The caches start again past a few
/// thousand entries, and on a new size or device (<see cref="Reset"/>). UI thread only.
/// </para>
/// </summary>
internal sealed class AvatarRenderer : IDisposable
{
    /// <summary>The cached drawings kept at most.</summary>
    private const int MaxDrawn = 2048;

    /// <summary>An emoji's glyph box, as a part of the disc's diameter.</summary>
    private const float EmojiFill = 0.9f;

    // The generated avatar's background, darker than the card (#1C1C1E); lane 0's blue gives way to the app's accent.
    private static readonly Color Background = ColorHelper.FromArgb(0xFF, 0x1C, 0x1C, 0x1E);
    private static readonly Color Accent = ColorHelper.FromArgb(0xFF, 0x2F, 0x86, 0xFB);

    // The initials avatar's disc (#48484A) and letters (white 0.92).
    private static readonly Color InitialsFill = ColorHelper.FromArgb(0xFF, 0x48, 0x48, 0x4A);
    private static readonly Color InitialsText = ColorHelper.FromArgb(0xEB, 0xFF, 0xFF, 0xFF);

    private readonly bool _initials;
    private readonly IReadOnlyDictionary<string, string> _emojis;
    private readonly Dictionary<(string Email, string Name), CanvasRenderTarget> _byAuthor = [];
    private readonly Dictionary<string, CanvasRenderTarget> _drawn = new(StringComparer.Ordinal);
    private float _size;

    /// <param name="mode">The avatarMode preference: "initials", else generated.</param>
    /// <param name="emojis">The authorEmojis preference: an emoji by identity (the lowercased email).</param>
    public AvatarRenderer(string mode, IReadOnlyDictionary<string, string> emojis)
    {
        _initials = string.Equals(mode, "initials", StringComparison.Ordinal);
        _emojis = emojis;
    }

    /// <summary>
    /// The avatar of the author (<paramref name="email"/>, <paramref name="name"/>, raw) as a round image
    /// <paramref name="diameter"/> epx wide, drawn on <paramref name="ds"/>'s device on first use.
    /// </summary>
    public ICanvasImage Avatar(CanvasDrawingSession ds, string email, string name, float diameter)
    {
        if (diameter != _size)
        {
            Reset();
            _size = diameter;
        }

        if (_byAuthor.TryGetValue((email, name), out CanvasRenderTarget? cached))
            return cached;
        if (_drawn.Count >= MaxDrawn || _byAuthor.Count >= 4 * MaxDrawn)
            Reset();

        string identity = Identity(email, name);
        string? emoji = EmojiOf(email, name);
        string key = emoji is not null ? "e|" + emoji : _initials ? "i|" + Initials(name) : "g|" + identity;
        if (!_drawn.TryGetValue(key, out CanvasRenderTarget? target))
        {
            target = new CanvasRenderTarget(ds, diameter, diameter);
            using (CanvasDrawingSession drawing = target.CreateDrawingSession())
            {
                drawing.Clear(Colors.Transparent);
                using var disc = CanvasGeometry.CreateCircle(drawing, diameter / 2, diameter / 2, diameter / 2);
                using (drawing.CreateLayer(1f, disc))
                {
                    if (emoji is not null)
                        DrawEmoji(drawing, emoji, diameter);
                    else if (_initials)
                        DrawInitials(drawing, Initials(name), diameter);
                    else
                        DrawGenerated(drawing, identity, diameter);
                }
            }

            _drawn[key] = target;
        }

        _byAuthor[(email, name)] = target;
        return target;
    }

    /// <summary>The emoji the author's avatar shows (sanitized, one text element); null when none is set or the author
    /// cannot have one (<see cref="AllowsEmoji"/>).</summary>
    public string? EmojiOf(string email, string name)
    {
        string identity = Identity(email, name);
        return AllowsEmoji(identity) && _emojis.TryGetValue(identity, out string? stored)
            && DisplayText.Sanitize(stored, 1) is { Length: > 0 } shown
            ? shown
            : null;
    }

    /// <summary>Drops every drawing (a new device or node size); they are drawn again on use.</summary>
    public void Reset()
    {
        foreach (CanvasRenderTarget target in _drawn.Values)
            target.Dispose();
        _drawn.Clear();
        _byAuthor.Clear();
    }

    public void Dispose() => Reset();

    /// <summary>The trimmed, lowercased email (the name when there is none): what the pattern and the emojis key on.</summary>
    internal static string Identity(string email, string name)
    {
        string trimmed = email.Trim().ToLowerInvariant();
        return trimmed.Length == 0 ? "name:" + name : trimmed;
    }

    /// <summary>Up to two letters: the first of the name's first and last words (<c>Ada Lovelace</c> gives
    /// <c>AL</c>).</summary>
    internal static string Initials(string name)
    {
        string[] words = name.Split([' ', '.', '_', '-'], StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0)
            return "";
        string first = FirstElement(words[0]);
        return (words.Length > 1 ? first + FirstElement(words[^1]) : first).ToUpperInvariant();
    }

    /// <summary>Whether the author can have an emoji: not without an email, nor a provider's no-reply address, a GitHub
    /// bot or an owner identity.</summary>
    internal static bool AllowsEmoji(string identity)
    {
        if (identity.StartsWith("name:", StringComparison.Ordinal) || identity.StartsWith("owner:", StringComparison.Ordinal)
            || identity.EndsWith("[bot]@users.noreply.github.com", StringComparison.Ordinal))
        {
            return false;
        }

        int at = identity.LastIndexOf('@');
        return at < 0 || identity[..at] is not ("noreply" or "no-reply" or "commits-noreply")
            || identity[(at + 1)..] is not ("github.com" or "gitlab.com" or "bitbucket.org" or "codeberg.org" or "dev.azure.com");
    }

    /// <summary>The first text element of <paramref name="word"/> (never half a surrogate pair), safe to show.</summary>
    private static string FirstElement(string word) =>
        DisplayText.Sanitize(System.Globalization.StringInfo.GetNextTextElement(word), 1);

    /// <summary>The 5x5 pattern: byte 0 of the hash picks the lane color, bits 0 to 14 of bytes 1 and 2 the cells of
    /// the 3 left columns; the right 2 mirror them.</summary>
    private static void DrawGenerated(CanvasDrawingSession ds, string identity, float size)
    {
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes(identity));
        int lane = hash[0] % 8;
        Color color = lane == 0 ? Accent : GraphPalette.Lane(lane, gradient: false);
        uint bits = hash[1] | (uint)hash[2] << 8;
        ds.FillRectangle(0, 0, size, size, Background);
        float inset = size * 0.18f;
        float cell = (size - 2 * inset) / 5;
        for (int column = 0; column < 3; column++)
        {
            for (int row = 0; row < 5; row++)
            {
                if ((bits & (1u << (column * 5 + row))) == 0)
                    continue;
                ds.FillRectangle(inset + column * cell, inset + row * cell, cell, cell, color);
                if (column != 2)
                    ds.FillRectangle(inset + (4 - column) * cell, inset + row * cell, cell, cell, color);
            }
        }
    }

    private static void DrawInitials(CanvasDrawingSession ds, string initials, float size)
    {
        ds.FillRectangle(0, 0, size, size, InitialsFill);
        if (initials.Length == 0)
            return;
        using var format = new CanvasTextFormat
        {
            FontFamily = "Segoe UI Variable Text",
            FontSize = MathF.Round(size * 0.46f),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
            VerticalAlignment = CanvasVerticalAlignment.Center,
            WordWrapping = CanvasWordWrapping.NoWrap,
        };
        ds.DrawText(initials, new Windows.Foundation.Rect(0, 0, size, size), InitialsText, format);
    }

    /// <summary>The emoji in color on the dark disc, scaled and centered by its glyph's own box.</summary>
    private static void DrawEmoji(CanvasDrawingSession ds, string emoji, float size)
    {
        ds.FillRectangle(0, 0, size, size, Background);
        using var format = new CanvasTextFormat
        {
            FontFamily = "Segoe UI Emoji",
            FontSize = size,
            WordWrapping = CanvasWordWrapping.NoWrap,
            Options = CanvasDrawTextOptions.EnableColorFont,
        };
        using var layout = new CanvasTextLayout(ds, emoji, format, 10 * size, 10 * size);
        Windows.Foundation.Rect glyph = layout.DrawBounds;
        if (glyph.Width <= 0 || glyph.Height <= 0)
            return;
        float scale = size * EmojiFill / (float)Math.Max(glyph.Width, glyph.Height);
        Matrix3x2 saved = ds.Transform;
        ds.Transform = Matrix3x2.CreateTranslation(
                (float)-(glyph.X + glyph.Width / 2), (float)-(glyph.Y + glyph.Height / 2))
            * Matrix3x2.CreateScale(scale)
            * Matrix3x2.CreateTranslation(size / 2, size / 2)
            * saved;
        ds.DrawTextLayout(layout, 0, 0, Colors.White);
        ds.Transform = saved;
    }
}

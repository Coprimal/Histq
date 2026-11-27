// Path rules of one OS as pure string functions, so the workspace and session formats map stored strings to absolute
// paths the same way on every machine and the Windows rules are tested on the Mac. Nothing here touches the file
// system or uses a Path.* default of the running OS: the caller names the flavor. POSIX paths are rooted at `/`.
// Windows paths read `\` and `/` alike; an absolute one has a drive (`C:\`) or is a UNC or device path (`\\server\share`,
// `//server/share`, `\\?\`, `\\.\`, any two leading separators), `\x` and `C:x` count as relative, and keys compare
// case-insensitively. Standardized paths use the flavor's separator (`\`, with an upper-case drive letter on Windows);
// relative paths and `~/` forms are always written with `/`. Ported from the path parts of WorkspaceFile.swift
// (420-514) at 6fa6d40, where Foundation's URL does this for macOS only.
namespace Histq.Core;

/// <summary>Which OS's path rules apply.</summary>
public enum PathFlavor
{
    Posix,
    Windows,
}

public static class PathFlavorRules
{
    extension(PathFlavor flavor)
    {
        /// <summary>The flavor of the OS this process runs on.</summary>
        public static PathFlavor Host => OperatingSystem.IsWindows() ? PathFlavor.Windows : PathFlavor.Posix;

        /// <summary>How two path keys compare: case-insensitively on Windows, ordinally elsewhere.</summary>
        public StringComparison KeyComparison =>
            flavor == PathFlavor.Windows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

        /// <summary>The comparer for sets and dictionaries keyed by path.</summary>
        public StringComparer KeyComparer =>
            flavor == PathFlavor.Windows ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

        /// <summary>Whether two standardized paths name the same key.</summary>
        public bool KeysEqual(string a, string b) => string.Equals(a, b, flavor.KeyComparison);

        /// <summary>
        /// Whether <paramref name="path"/> is a Windows UNC or device path: it starts with two separators of either kind
        /// (<c>\\server\share</c>, <c>//server/share</c>, <c>\\?\C:\x</c>, <c>\\.\pipe\x</c>). Never on POSIX.
        /// </summary>
        public bool IsUncOrDevice(string path) =>
            flavor == PathFlavor.Windows && path.Length >= 2 && IsSeparator(flavor, path[0]) && IsSeparator(flavor, path[1]);

        /// <summary>Whether <paramref name="path"/> is absolute: <c>/x</c> on POSIX; <c>C:\x</c>, <c>C:/x</c>, or a UNC or
        /// device path on Windows.</summary>
        public bool IsAbsolute(string path) => Split(flavor, path).Root.Length > 0;

        /// <summary>The one form of an absolute path: no <c>.</c> or <c>..</c> (a <c>..</c> at the root stays there),
        /// no repeated or trailing separator, the flavor's separator, an upper-case drive letter.</summary>
        public string Standardized(string path)
        {
            var (root, parts) = Split(flavor, path);
            return Join(flavor, root, Normalized(parts, rooted: root.Length > 0));
        }

        /// <summary>
        /// <paramref name="path"/> as an absolute path: an absolute one standardized, anything else taken under
        /// <paramref name="folder"/> component by component, a <c>..</c> dropping the last one as written.
        /// </summary>
        public string Resolve(string folder, string path) =>
            flavor.IsAbsolute(path) ? flavor.Standardized(path) : Combine(flavor, folder, path);

        /// <summary>The folder that holds <paramref name="path"/>; the root for the root itself.</summary>
        public string Parent(string path)
        {
            var (root, parts) = Split(flavor, flavor.Standardized(path));
            return Join(flavor, root, parts.Count > 0 ? parts[..^1] : parts);
        }

        /// <summary>The last component of <paramref name="path"/>; the root for the root itself.</summary>
        public string LastComponent(string path)
        {
            var standardized = flavor.Standardized(path);
            var parts = Split(flavor, standardized).Parts;
            return parts.Count > 0 ? parts[^1] : standardized;
        }

        /// <summary>
        /// <paramref name="target"/> relative to <paramref name="folder"/> by components, written with <c>/</c>
        /// (<c>.</c> for the folder itself); null when they share no root (another drive or share).
        /// </summary>
        public string? Relative(string folder, string target) => flavor.RelativeWithCommon(folder, target).Path;

        /// <summary>
        /// A <c>~</c> or <c>~/...</c> string (<c>~\...</c> too on Windows) under <paramref name="home"/>; null for any
        /// other string. The rest is always taken as relative, so it never names another root or a UNC path.
        /// </summary>
        public string? ExpandHome(string home, string stored)
        {
            if (string.Equals(stored, "~", StringComparison.Ordinal))
            {
                return flavor.Standardized(home);
            }

            return stored.Length >= 2 && stored[0] == '~' && IsSeparator(flavor, stored[1])
                ? Combine(flavor, home, stored[2..])
                : null;
        }

        /// <summary><paramref name="absolute"/> as <c>~</c> or <c>~/...</c> when it is in <paramref name="home"/>
        /// (never when home is a root), else as it is.</summary>
        public string Tilde(string home, string absolute)
        {
            var from = Components(flavor, home);
            var to = Components(flavor, absolute);
            if (from.Count <= 1 || to.Count < from.Count || !SameComponents(flavor, from, to, from.Count))
            {
                return absolute;
            }

            return to.Count == from.Count ? "~" : "~/" + string.Join('/', to.Skip(from.Count));
        }

        /// <summary>The standardized root of <paramref name="path"/> (empty for a relative one) and its normalized
        /// components after it.</summary>
        internal (string Root, IReadOnlyList<string> Parts) RootAndParts(string path)
        {
            var (root, parts) = Split(flavor, path);
            return (root, Normalized(parts, rooted: root.Length > 0));
        }

        /// <summary>The relative path and how many leading components (the root included) both sides share.</summary>
        internal (string? Path, int Common) RelativeWithCommon(string folder, string target)
        {
            var from = Components(flavor, folder);
            var to = Components(flavor, target);
            var common = 0;
            while (common < from.Count && common < to.Count && SameComponents(flavor, from, to, common + 1))
            {
                common++;
            }

            if (common == 0)
            {
                return (null, 0);
            }

            var parts = Enumerable.Repeat("..", from.Count - common).Concat(to.Skip(common)).ToList();
            return (parts.Count == 0 ? "." : string.Join('/', parts), common);
        }
    }

    private static bool IsSeparator(PathFlavor flavor, char c) => c == '/' || (flavor == PathFlavor.Windows && c == '\\');

    private static char[] Separators(PathFlavor flavor) => flavor == PathFlavor.Windows ? ['/', '\\'] : ['/'];

    /// <summary>
    /// The root of an absolute path in its standardized form (<c>/</c>; <c>C:\</c>, <c>\\server\share\</c>,
    /// <c>\\?\C:\</c>), empty for a relative one, and the non-empty components after it.
    /// </summary>
    private static (string Root, List<string> Parts) Split(PathFlavor flavor, string path)
    {
        var separators = Separators(flavor);
        if (flavor == PathFlavor.Posix)
        {
            var parts = path.Split(separators, StringSplitOptions.RemoveEmptyEntries).ToList();
            return (path.StartsWith('/') ? "/" : "", parts);
        }

        if (flavor.IsUncOrDevice(path))
        {
            // `\\server\share\` or `\\?\C:\`: the two components after the leading separators are the root.
            var all = path.Split(separators, StringSplitOptions.RemoveEmptyEntries).ToList();
            var head = all.Take(2).ToList();
            return (@"\\" + string.Concat(head.Select(part => part + @"\")), all.Skip(head.Count).ToList());
        }

        if (path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && IsSeparator(flavor, path[2]))
        {
            var parts = path[3..].Split(separators, StringSplitOptions.RemoveEmptyEntries).ToList();
            return (char.ToUpperInvariant(path[0]) + @":\", parts);
        }

        return ("", path.Split(separators, StringSplitOptions.RemoveEmptyEntries).ToList());
    }

    /// <summary>The root (when there is one) and the normalized components of a path.</summary>
    private static List<string> Components(PathFlavor flavor, string path)
    {
        var (root, parts) = Split(flavor, path);
        var normalized = Normalized(parts, rooted: root.Length > 0);
        return root.Length > 0 ? [root, .. normalized] : normalized;
    }

    private static bool SameComponents(PathFlavor flavor, List<string> a, List<string> b, int count)
    {
        for (var i = 0; i < count; i++)
        {
            if (!string.Equals(a[i], b[i], flavor.KeyComparison))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary><paramref name="parts"/> without <c>.</c>, each <c>..</c> dropping the component before it (kept at
    /// the start of a relative path, dropped at a root).</summary>
    private static List<string> Normalized(IEnumerable<string> parts, bool rooted)
    {
        var result = new List<string>();
        foreach (var part in parts)
        {
            if (part == ".")
            {
                continue;
            }

            if (part == "..")
            {
                if (result.Count > 0 && result[^1] != "..")
                {
                    result.RemoveAt(result.Count - 1);
                }
                else if (!rooted)
                {
                    result.Add(part);
                }

                continue;
            }

            result.Add(part);
        }

        return result;
    }

    /// <summary><paramref name="relative"/> under <paramref name="folder"/>, always taken as relative.</summary>
    private static string Combine(PathFlavor flavor, string folder, string relative)
    {
        var (root, parts) = Split(flavor, folder);
        var all = parts.Concat(relative.Split(Separators(flavor), StringSplitOptions.RemoveEmptyEntries));
        return Join(flavor, root, Normalized(all, rooted: root.Length > 0));
    }

    private static string Join(PathFlavor flavor, string root, List<string> parts)
    {
        var separator = flavor == PathFlavor.Windows ? "\\" : "/";
        var body = string.Join(separator, parts);
        if (root.Length == 0)
        {
            return body.Length > 0 ? body : ".";
        }

        return root + body;
    }
}

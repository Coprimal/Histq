// The repositories opened lately, most recent first, for the Welcome page, and the workspace files opened lately, for
// Recent Workspaces. Kept in the preferences (PrefKey.RecentRepos, PrefKey.RecentWorkspaces). Ported from
// RecentRepos.swift at 6fa6d40.
namespace Histq.Core;

/// <summary>
/// A recent list: absolute paths, most recent first, at most <see cref="Limit"/>. String work only: listing, adding or
/// removing never touches an entry on disk, so a UNC or device entry (a share, <c>\\wsl.localhost\...</c>) is probed
/// only when the user picks it (<see cref="SavedSession.IsUserRepository"/>). Paths compare as keys of the flavor
/// (case-insensitively on Windows).
/// </summary>
public sealed class RecentRepos
{
    /// <summary>How many entries a list keeps.</summary>
    public const int Limit = 10;

    private readonly Preferences preferences;
    private readonly PrefKey key;
    private readonly PathFlavor flavor;
    private List<string> paths;

    /// <param name="key"><see cref="PrefKey.RecentRepos"/> (folders) or <see cref="PrefKey.RecentWorkspaces"/>
    /// (workspace files, added by identity key).</param>
    public RecentRepos(Preferences preferences, PrefKey key)
        : this(preferences, key, PathFlavor.Host)
    {
    }

    internal RecentRepos(Preferences preferences, PrefKey key, PathFlavor flavor)
    {
        this.preferences = preferences;
        this.key = key;
        this.flavor = flavor;
        paths = [.. preferences.Get<string[]>(key)];
    }

    /// <summary>The paths, most recent first.</summary>
    public IReadOnlyList<string> Paths => paths;

    /// <summary>Puts <paramref name="path"/> first (standardized; moved up if already listed), keeping
    /// <see cref="Limit"/> entries.</summary>
    public void Add(string path)
    {
        var standardized = flavor.Standardized(path);
        paths = [standardized, .. paths.Where(entry => !Same(entry, standardized)).Take(Limit - 1)];
        Save();
    }

    public void Remove(string path)
    {
        var standardized = flavor.Standardized(path);
        paths.RemoveAll(entry => Same(entry, standardized));
        Save();
    }

    /// <summary>Empties the list (Recent Workspaces › Clear Menu).</summary>
    public void Clear()
    {
        paths = [];
        Save();
    }

    private bool Same(string entry, string standardized) => flavor.KeysEqual(flavor.Standardized(entry), standardized);

    private void Save() => preferences.Set(key, paths.ToArray());
}

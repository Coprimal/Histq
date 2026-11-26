namespace Histq.Core;

/// <summary>
/// Where Histq keeps its files: state (session, profiles, workspaces, repo view, AI chat, undo) in <see cref="Root"/>
/// (<c>%APPDATA%\Histq</c>), avatars, icons and caches in <see cref="DataRoot"/> (<c>%LOCALAPPDATA%\HistqData</c>).
/// An automated (QA) launch keeps both under one folder, first match wins: the <c>-HistqStateDir &lt;dir&gt;</c> launch
/// argument, else the <c>HISTQ_DATA_ROOT</c> variable; <see cref="Root"/> is then <c>&lt;dir&gt;</c> and
/// <see cref="DataRoot"/> <c>&lt;dir&gt;\data</c>. Resolving creates nothing; only <see cref="Directory"/> and
/// <see cref="Prepare"/> touch the disk.
/// </summary>
public sealed record StatePaths(string Root, string DataRoot, bool IsStateDirMode)
{
    public const string StateDirFlag = "-HistqStateDir";

    public const string DataRootVariable = "HISTQ_DATA_ROOT";

    /// <summary>
    /// The paths for <paramref name="arguments"/> (the launch arguments) and <paramref name="environment"/> (a
    /// variable lookup, <c>Environment.GetEnvironmentVariable</c> in the app). The app passes no arguments in builds
    /// that must ignore QA flags.
    /// </summary>
    public static StatePaths Resolve(IReadOnlyList<string> arguments, Func<string, string?> environment)
    {
        var overrideDir = LaunchFlag(arguments, StateDirFlag);
        if (string.IsNullOrEmpty(overrideDir))
        {
            overrideDir = environment(DataRootVariable);
        }

        if (string.IsNullOrEmpty(overrideDir))
        {
            return new(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Histq"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HistqData"),
                IsStateDirMode: false);
        }

        var root = Path.GetFullPath(overrideDir);
        return new(root, Path.Combine(root, "data"), IsStateDirMode: true);
    }

    /// <summary>
    /// The value after the first <paramref name="name"/> in <paramref name="arguments"/>
    /// (<c>-HistqStateDir C:\x</c> -> <c>C:\x</c>), or null when the flag is absent or has no value.
    /// </summary>
    internal static string? LaunchFlag(IReadOnlyList<string> arguments, string name)
    {
        for (var i = 0; i < arguments.Count; i++)
        {
            if (arguments[i] == name)
            {
                return i + 1 < arguments.Count ? arguments[i + 1] : null;
            }
        }

        return null;
    }

    /// <summary><c>Root\&lt;name&gt;</c>, created if missing (profiles, sessions, undo journals).</summary>
    public string Directory(string name)
    {
        var path = Path.Combine(Root, name);
        TryCreate(path);
        return path;
    }

    /// <summary>Creates the root folder; called once at launch.</summary>
    public void Prepare() => TryCreate(Root);

    /// <summary>A failure is ignored, as on the Mac: the first read or write of a file there reports it.</summary>
    private static void TryCreate(string path)
    {
        try
        {
            System.IO.Directory.CreateDirectory(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}

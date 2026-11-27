using Windows.Win32;
using Windows.Win32.Storage.FileSystem;

namespace Histq.Platform.IO;

/// <summary>
/// The real path of a file or folder, as Windows resolves it (links followed, the on-disk case of every component):
/// what repo keys (<c>RepoGroupKey</c>) are canonicalised with, so two spellings of one repository get one key.
/// </summary>
/// <remarks>
/// Security: opening a path reaches whatever it names, and a UNC path makes Windows connect (and authenticate) to that
/// server. <see cref="Of"/> does not check its input: callers must refuse a UNC or device path that comes from a
/// received file (a workspace, a session someone sent) before calling it, with Core's <c>PathFlavor.IsUncOrDevice</c>
/// (as <c>WorkspaceFile</c>'s guarded disk does). That guard does not cover a local path whose link points at a share,
/// which still reaches the network, so this is never a probe for whether an untrusted path is safe.
/// </remarks>
public static class FinalPath
{
    private const string DevicePrefix = @"\\?\";
    private const string UncDevicePrefix = @"\\?\UNC\";

    /// <summary>
    /// The real path of <paramref name="path"/>: no <c>\\?\</c> prefix (<c>\\?\UNC\server\share</c> becomes
    /// <c>\\server\share</c>), an upper-case drive letter. Null when it does not exist or cannot be opened.
    /// </summary>
    public static string? Of(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        // No access rights (attributes only) and full sharing, so the open never blocks or disturbs anyone else;
        // FILE_FLAG_BACKUP_SEMANTICS lets it open folders.
        using var handle = PInvoke.CreateFile(
            path, 0,
            FILE_SHARE_MODE.FILE_SHARE_READ | FILE_SHARE_MODE.FILE_SHARE_WRITE | FILE_SHARE_MODE.FILE_SHARE_DELETE,
            null, FILE_CREATION_DISPOSITION.OPEN_EXISTING, FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_BACKUP_SEMANTICS, null);
        if (handle.IsInvalid)
            return null;

        var buffer = new char[260];
        while (true)
        {
            var length = PInvoke.GetFinalPathNameByHandle(
                handle, buffer, GETFINALPATHNAMEBYHANDLE_FLAGS.FILE_NAME_NORMALIZED | GETFINALPATHNAMEBYHANDLE_FLAGS.VOLUME_NAME_DOS);
            if (length == 0)
                return null;
            // Too small: the return value is the size needed, terminating null included.
            if (length >= buffer.Length)
            {
                buffer = new char[length];
                continue;
            }
            return Cleaned(new string(buffer, 0, (int)length));
        }
    }

    private static string Cleaned(string path)
    {
        if (path.StartsWith(UncDevicePrefix, StringComparison.Ordinal))
            return @"\\" + path[UncDevicePrefix.Length..];
        if (path.StartsWith(DevicePrefix, StringComparison.Ordinal) && path.Length >= DevicePrefix.Length + 2
            && char.IsAsciiLetter(path[DevicePrefix.Length]) && path[DevicePrefix.Length + 1] == ':')
            path = path[DevicePrefix.Length..];
        if (path.Length >= 2 && char.IsAsciiLetter(path[0]) && path[1] == ':')
            path = char.ToUpperInvariant(path[0]) + path[1..];
        return path;
    }
}

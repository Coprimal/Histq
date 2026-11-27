// The path rules both flavors share, tested on any host: Windows drive letters, UNC and device paths, relative paths
// written with '/', the '~' home form and case-insensitive keys on Windows; POSIX stays case-sensitive.
namespace Histq.Core.Tests;

public sealed class PathFlavorTests
{
    private const PathFlavor Windows = PathFlavor.Windows;
    private const PathFlavor Posix = PathFlavor.Posix;

    // Absolute on Windows means a drive with a separator, or a UNC or device path; `\x`, `C:x` and `/x` are relative.
    [Theory]
    [InlineData(Windows, @"C:\HistqQA", true)]
    [InlineData(Windows, "c:/HistqQA", true)]
    [InlineData(Windows, @"C:\", true)]
    [InlineData(Windows, @"\\server\share\x", true)]
    [InlineData(Windows, "C:HistqQA", false)]
    [InlineData(Windows, @"\HistqQA", false)]
    [InlineData(Windows, "/Users/me", false)]
    [InlineData(Windows, @"..\fx\app", false)]
    [InlineData(Posix, "/Users/me", true)]
    [InlineData(Posix, @"C:\HistqQA", false)]
    [InlineData(Posix, "~/git", false)]
    public void AbsoluteFollowsTheFlavor(PathFlavor flavor, string path, bool expected) =>
        Assert.Equal(expected, flavor.IsAbsolute(path));

    // Any two leading separators make a UNC or device path on Windows; never on POSIX.
    [Theory]
    [InlineData(Windows, @"\\server\share", true)]
    [InlineData(Windows, "//server/share", true)]
    [InlineData(Windows, @"\\?\C:\x", true)]
    [InlineData(Windows, @"\\.\pipe\x", true)]
    [InlineData(Windows, @"\/server/share", true)]
    [InlineData(Windows, @"C:\x", false)]
    [InlineData(Windows, @"\x", false)]
    [InlineData(Windows, "x", false)]
    [InlineData(Posix, "//server/share", false)]
    public void UncAndDevicePathsAreClassified(PathFlavor flavor, string path, bool expected) =>
        Assert.Equal(expected, flavor.IsUncOrDevice(path));

    [Theory]
    [InlineData(Windows, @"c:/HistqQA//fx/./a/../b\", @"C:\HistqQA\fx\b")]
    [InlineData(Windows, @"C:\..\x", @"C:\x")]
    [InlineData(Windows, "C:/", @"C:\")]
    [InlineData(Windows, "//server/share/a/../b", @"\\server\share\b")]
    [InlineData(Posix, "/a//b/./c/../", "/a/b")]
    [InlineData(Posix, "/..", "/")]
    public void StandardizedHasOneForm(PathFlavor flavor, string path, string expected) =>
        Assert.Equal(expected, flavor.Standardized(path));

    // Relative paths are written with '/' on Windows too; another drive has none.
    [Theory]
    [InlineData(Windows, @"C:\HistqQA\data", @"C:\HistqQA\fx\tabs\docs", "../fx/tabs/docs")]
    [InlineData(Windows, @"C:\HistqQA\Data", @"c:\histqqa\data\sub", "sub")]
    [InlineData(Windows, @"C:\HistqQA", @"c:\histqqa", ".")]
    [InlineData(Windows, @"C:\HistqQA", @"D:\repo", null)]
    [InlineData(Windows, @"C:\HistqQA", @"\\server\share\repo", null)]
    [InlineData(Posix, "/a/B", "/a/b/c", "../b/c")]
    [InlineData(Posix, "/a/b", "/a/b", ".")]
    public void RelativeIsWrittenWithSlashes(PathFlavor flavor, string folder, string target, string? expected) =>
        Assert.Equal(expected, flavor.Relative(folder, target));

    [Theory]
    [InlineData(Windows, @"C:\HistqQA\data", "../fx/tabs/docs", @"C:\HistqQA\fx\tabs\docs")]
    [InlineData(Windows, @"C:\HistqQA\data", @"..\fx\tabs\docs", @"C:\HistqQA\fx\tabs\docs")]
    [InlineData(Windows, @"C:\HistqQA\data", "../../../../x", @"C:\x")]
    [InlineData(Windows, @"C:\HistqQA\data", "D:/repo", @"D:\repo")]
    [InlineData(Windows, @"C:\HistqQA\data", @"\x", @"C:\HistqQA\data\x")]
    [InlineData(Posix, "/ws/data", "../repos/app", "/ws/repos/app")]
    [InlineData(Posix, "/ws/data", "/repos/app", "/repos/app")]
    public void ResolveTakesRelativePathsUnderTheFolder(PathFlavor flavor, string folder, string path, string expected) =>
        Assert.Equal(expected, flavor.Resolve(folder, path));

    // The '~' form: written with '/', compared case-insensitively on Windows, never escaping into a UNC path.
    [Fact]
    public void HomeFormOnWindows()
    {
        const string home = @"C:\Users\me";
        Assert.Equal("~/git/x", Windows.Tilde(home, @"c:\users\ME\git\x"));
        Assert.Equal("~", Windows.Tilde(home, @"C:\Users\me"));
        Assert.Equal(@"D:\git\x", Windows.Tilde(home, @"D:\git\x"));
        Assert.Equal(@"C:\x", Windows.Tilde(@"C:\", @"C:\x"));
        Assert.Equal(@"C:\Users\me\git\x", Windows.ExpandHome(home, "~/git/x"));
        Assert.Equal(@"C:\Users\me\git\x", Windows.ExpandHome(home, @"~\git\x"));
        Assert.Equal(@"C:\Users\me", Windows.ExpandHome(home, "~"));
        Assert.Equal(@"C:\Users\server\share", Windows.ExpandHome(home, "~/..//server/share"));
        Assert.Null(Windows.ExpandHome(home, "git/x"));
        Assert.Null(Posix.ExpandHome("/Users/me", @"~\git"));
        Assert.Equal("~/git/x", Posix.Tilde("/Users/me", "/Users/me/git/x"));
        Assert.Equal("/Users/ME/git/x", Posix.Tilde("/Users/me", "/Users/ME/git/x"));
    }

    [Fact]
    public void KeysCompareCaseInsensitivelyOnWindowsOnly()
    {
        Assert.True(Windows.KeysEqual(@"C:\HistqQA\fx\App", @"c:\histqqa\FX\app"));
        Assert.False(Posix.KeysEqual("/HistqQA/fx/App", "/histqqa/fx/app"));
        Assert.Contains(@"c:\histqqa\fx\app", new HashSet<string>([@"C:\HistqQA\fx\App"], Windows.KeyComparer));
    }
}

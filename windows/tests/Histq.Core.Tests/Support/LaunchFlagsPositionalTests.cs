// The launch's positional arguments (a folder or a workspace file to open): never a flag or a flag's value.
namespace Histq.Core.Tests;

public sealed class LaunchFlagsPositionalTests
{
    [Fact]
    public void PositionalSkipsFlagsAndTheirValues()
    {
        string[] arguments =
        [
            "-HistqStateDir", @"C:\HistqQA\state", @"C:\repo", "-HistqOpen", @"C:\HistqQA\fx\graph", @"D:\w.histqws",
        ];

        Assert.Equal([@"C:\repo", @"D:\w.histqws"], LaunchFlags.Positional(arguments));
    }

    [Fact]
    public void PositionalLeavesOutEmptyArgumentsAndATrailingFlag()
    {
        Assert.Equal(["/r/a"], LaunchFlags.Positional(["", "  ", "/r/a", "-HistqSpikeLog"]));
        Assert.Empty(LaunchFlags.Positional([]));
    }

    [Fact]
    public void AFlagFollowedByAFlagTakesNoValue() =>
        Assert.Equal([@"C:\repo"], LaunchFlags.Positional(["-HistqTabWalk", "-HistqStateDir", @"C:\state", @"C:\repo"]));
}

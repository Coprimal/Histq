using System.Runtime;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Histq.App;

/// <summary>
/// The entry point (the csproj defines DISABLE_XAML_GENERATED_MAIN): what the generated Main does. Velopack's startup
/// and single instance come here later. QA builds start <c>SpikeHarness</c> with the launch arguments.
/// </summary>
public static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        // The graph and log of a large repository stay in memory, and a blocking gen-2 collection of that heap stalls
        // the UI thread ~190 ms (the phase 5 scroll probe at 1M commits). Gen-2 runs in the background instead, except
        // under memory pressure (needs concurrent GC, set in the csproj); never GC.Collect or no-GC regions.
        GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency;
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            // Application.Current keeps it alive, as in the XAML-generated Main.
            new App();
#if HISTQ_QA
            // Loads its dump at once; waits for the main window (OnLaunched) before it touches it.
            SpikeHarness.Start(args);
#endif
        });
    }
}

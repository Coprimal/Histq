using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Histq.App;

/// <summary>
/// The entry point (the csproj defines DISABLE_XAML_GENERATED_MAIN): what the generated Main does. Velopack's startup
/// and single instance come here later.
/// </summary>
public static class Program
{
    [STAThread]
    private static void Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            // Application.Current keeps it alive, as in the XAML-generated Main.
            new App();
        });
    }
}

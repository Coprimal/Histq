using System.Security.Cryptography;
using System.Text;
using Histq.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Histq.App;

/// <summary>
/// The entry point (the csproj defines DISABLE_XAML_GENERATED_MAIN): one instance per state folder (a second launch on
/// the same folder hands its activation to the first and exits), the saved session read off the UI thread while XAML
/// starts, then what the generated Main does. Velopack's startup comes here later. QA builds start
/// <c>SpikeHarness</c> with the launch arguments.
/// </summary>
public static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

#if HISTQ_QA
        IReadOnlyList<string> stateArguments = args;
#else
        // Builds without QA flags ignore -HistqStateDir (StatePaths.Resolve).
        IReadOnlyList<string> stateArguments = [];
#endif
        StatePaths paths = StatePaths.Resolve(stateArguments, Environment.GetEnvironmentVariable);

        AppInstance instance = AppInstance.FindOrRegisterForKey(InstanceKey(paths));
        if (!instance.IsCurrent)
        {
            // The redirect runs on a worker and Main waits for it (a pumping wait on this STA thread), as in the
            // Windows App SDK's single-instance sample.
            AppActivationArguments activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            Task.Run(() => instance.RedirectActivationToAsync(activation).AsTask()).Wait();
            return;
        }

        // Load probes every tab's folder on disk: a worker reads it while XAML starts; OnLaunched waits for it before
        // it makes the first window.
        Task<SessionStore.Loaded?> sessionLoad = Task.Run(() =>
        {
            paths.Prepare();
            return SessionStore.Load(SessionStore.In(paths));
        });
        // The preferences (the recent repos), read on a worker once the state folder exists.
        Task<Preferences> preferencesLoad = sessionLoad.ContinueWith(
            _ => Preferences.Load(Preferences.In(paths)),
            CancellationToken.None,
            TaskContinuationOptions.None,
            TaskScheduler.Default);

        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            // Application.Current keeps it alive, as in the XAML-generated Main.
            var app = new App { StatePaths = paths, SessionLoad = sessionLoad, PreferencesLoad = preferencesLoad };
            instance.Activated += app.OnRedirectedActivation;
#if HISTQ_QA
            // Loads its dump at once; waits for the main window (OnLaunched) before it touches it.
            SpikeHarness.Start(args);
#endif
        });
    }

    /// <summary>
    /// The single-instance key of a state folder: a hash of its full path without a trailing separator, case-folded
    /// (Windows paths are case-insensitive), so <c>C:\X</c> and <c>c:\x\</c> share one instance. A hash, as the key
    /// names a system object, where a backslash is not allowed.
    /// </summary>
    private static string InstanceKey(StatePaths paths)
    {
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(paths.Root)).ToUpperInvariant();
        return "Histq-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(root)), 0, 16);
    }
}

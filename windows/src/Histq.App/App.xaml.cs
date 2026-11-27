using System.Diagnostics;
using Histq.App.Shell;
using Histq.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Histq.App;

/// <summary>
/// The application: dark theme only (App.xaml), the saved session's windows opened once it is read (WindowManager), and
/// the session saved when the last window closes (quit).
/// </summary>
public partial class App : Application
{
    private readonly DispatcherQueue _dispatcher;
    private WindowManager? _windows;

    public App()
    {
        InitializeComponent();
        _dispatcher = DispatcherQueue.GetForCurrentThread();
    }

    /// <summary>The state folder (set by Program).</summary>
    internal StatePaths StatePaths { get; init; } = null!;

    /// <summary>The saved session's read, started by Program off the UI thread.</summary>
    internal Task<SessionStore.Loaded?> SessionLoad { get; init; } = null!;

    /// <summary>The preferences' read, started by Program off the UI thread.</summary>
    internal Task<Preferences> PreferencesLoad { get; init; } = null!;

    /// <summary>The session read at launch, or null when there is none.</summary>
    internal SessionStore.Loaded? LoadedSession { get; private set; }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        // Program started the reads before XAML; by now they have (nearly always) finished, and no window exists yet.
        LoadedSession = SessionLoad.GetAwaiter().GetResult();

        // Made here, on the UI thread, so its debounce runs on this thread's context.
        var sessionStore = new SessionStore(SessionStore.In(StatePaths))
        {
            SessionWriteFailed = error => Trace.WriteLine($"Histq: session.json not saved: {error.Message}"),
        };

        Preferences preferences = PreferencesLoad.GetAwaiter().GetResult();
        var recentRepos = new RecentRepos(preferences, PrefKey.RecentRepos);
        _windows = new WindowManager(sessionStore, LoadedSession?.Session.Workspaces, preferences, recentRepos);
        _windows.Restore(LoadedSession);
    }

    /// <summary>
    /// A second launch on this state folder handed its activation here (on a worker thread): bring the front window
    /// forward. Its arguments (a folder to open) are not handled yet.
    /// </summary>
    internal void OnRedirectedActivation(object? sender, AppActivationArguments args)
    {
        Trace.WriteLine($"Histq: activation redirected from a second launch ({args.Kind}); its arguments are ignored");
        _dispatcher.TryEnqueue(() => _windows?.BringForward());
    }
}

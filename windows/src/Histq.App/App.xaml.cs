using Microsoft.UI.Xaml;

namespace Histq.App;

/// <summary>The application: dark theme only (App.xaml), one main window at launch.</summary>
public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}

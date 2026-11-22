using System.Windows;
using System.Windows.Threading;

namespace SoulspireLauncher;

public partial class App : Application
{
    public const string ApplicationTitle = "SoulspireXI Launcher";

    protected override void OnStartup(StartupEventArgs e)
    {
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        base.OnStartup(e);
    }

    private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(
            $"SoulspireXI Launcher encountered an unexpected error:\n\n{e.Exception.Message}",
            $"{ApplicationTitle} — Error",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        e.Handled = true;
    }
}

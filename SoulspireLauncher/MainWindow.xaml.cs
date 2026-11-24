using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using SoulspireLauncher.ViewModels;

namespace SoulspireLauncher;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private bool _syncingPassword;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = new MainViewModel();
        _viewModel.RequestMinimizeWindow += OnRequestMinimizeWindow;
        DataContext = _viewModel;

        Loaded += MainWindow_Loaded;
        Closing += MainWindow_Closing;
        Closed += MainWindow_Closed;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        _syncingPassword = true;
        AccountPasswordBox.Password = _viewModel.PlainPassword;
        _syncingPassword = false;

        await _viewModel.InitializeAsync();
    }

    private void OnRequestMinimizeWindow()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => WindowState = WindowState.Minimized);
            return;
        }

        WindowState = WindowState.Minimized;
    }

    private void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (_viewModel.IsStagingRelayActive)
        {
            var choice = MessageBox.Show(
                "The managed Staging TCP relay is currently active on 127.0.0.1 (ports 54231/54230/54001/54002).\n\n" +
                "Closing the launcher will immediately stop the relay and release those local ports (re-login and Search/AH require the relay while playing on Staging).\n\n" +
                "Stop the Staging relay and close SoulspireXI Launcher?",
                "SoulspireXI Launcher — Staging Relay Active",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (choice != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }

        _viewModel.Shutdown();
    }

    private void MainWindow_Closed(object? sender, EventArgs e)
    {
        _viewModel.RequestMinimizeWindow -= OnRequestMinimizeWindow;
        _viewModel.Dispose();
    }

    private void AccountPasswordBox_OnPasswordChanged(object sender, RoutedEventArgs e)
    {
        if (_syncingPassword || sender is not PasswordBox box)
        {
            return;
        }

        _viewModel.PlainPassword = box.Password;
    }

    private void MinimizeClick(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void CloseClick(object sender, RoutedEventArgs e) => Close();
}

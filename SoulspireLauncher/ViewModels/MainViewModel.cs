using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using Microsoft.Win32;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;

namespace SoulspireLauncher.ViewModels;

public sealed class MainViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly SettingsService _settingsService;
    private readonly SettingsImportService _importService;
    private readonly ManifestUpdateService _manifestService;
    private readonly LauncherSelfUpdateService _selfUpdateService;
    private readonly FfxiInstallDetector _detector;
    private readonly AshitaConfigGenerator _configGenerator;
    private readonly ModernClientConfigGenerator _modernConfigGenerator;
    private readonly ModernClientInstallService _modernInstallService;
    private readonly ModernClientDiagnosticsService _modernDiagnosticsService;
    private readonly ServerStatusService _statusService;
    private readonly GameLaunchService _launchService;
    private readonly ShortcutMigrationService _shortcutMigrationService;
    private readonly StagingRelayService _stagingRelay;
    private readonly PerformanceDiagnosticsService _perfDiag;

    private LauncherSettings _settings;
    private LauncherManifest _manifest;
    private InstallDiagnostics _diagnostics = new();
    private ServerStatus _serverStatus = new();
    private LauncherUpdateCheckResult? _availableLauncherUpdate;

    private string _selectedTab = "Play";
    private bool _isBusy;
    private string _statusMessage = "Ready";
    private double _progressPercent;
    private int _pendingUpdatesCount;
    private string _plainPassword = string.Empty;
    private string? _manifestUnavailableError;
    private LauncherUpdateStage _launcherUpdateStage = LauncherUpdateStage.Idle;
    private string _launcherUpdateStatusText = "Up to date (auto-check enabled)";
    private LauncherInstallState? _installState;
    private bool _hasRecordedStartupSpan;
    private bool _isColdCheckSpan = true;
    private bool _isColdSyncSpan = true;
    private string _lastPerfExportPath = string.Empty;

    public MainViewModel()
    {
        _settingsService = new SettingsService();
        _importService = new SettingsImportService();
        _manifestService = new ManifestUpdateService();
        _selfUpdateService = new LauncherSelfUpdateService();
        _detector = new FfxiInstallDetector();
        _configGenerator = new AshitaConfigGenerator();
        _modernConfigGenerator = new ModernClientConfigGenerator();
        _modernInstallService = new ModernClientInstallService();
        _modernDiagnosticsService = new ModernClientDiagnosticsService();
        _statusService = new ServerStatusService();
        _launchService = new GameLaunchService();
        _shortcutMigrationService = new ShortcutMigrationService();
        _stagingRelay = new StagingRelayService();
        _perfDiag = new PerformanceDiagnosticsService();
        _stagingRelay.DiagnosticMessage += Log;
        _stagingRelay.StateChanged += OnStagingRelayStateChanged;

        _manifest = _manifestService.LoadEmbeddedManifest();
        ManifestUpdateService.ApplyLocalOverride(_manifest, _settingsService.LoadLocalServerOverride());

        _settings = _settingsService.Load();
        _plainPassword = _settingsService.UnprotectPassword(_settings);

        NewsItems = new ObservableCollection<ManifestNewsItem>(_manifest.News);
        ActivityLog = new ObservableCollection<string>();

        SelectTabCommand = new RelayCommand(p => SelectedTab = p?.ToString() ?? "Play");
        PlayCommand = new AsyncRelayCommand(PlayAsync, () => !IsBusy);
        CheckUpdatesCommand = new AsyncRelayCommand(() => SyncUpdatesAsync(forceAll: false), () => !IsBusy);
        RepairFilesCommand = new AsyncRelayCommand(() => SyncUpdatesAsync(forceAll: true), () => !IsBusy);
        CheckLauncherUpdateCommand = new AsyncRelayCommand(
            async () => await CheckAndApplyLauncherUpdateAsync(autoApply: false, showUpToDateDialog: true),
            () => !IsBusy);
        ApplyLauncherUpdateCommand = new AsyncRelayCommand(
            async () => await ApplyAvailableLauncherUpdateAsync(),
            () => !IsBusy && IsLauncherUpdateAvailable);
        InstallPrerequisitesCommand = new AsyncRelayCommand(InstallPrerequisitesAsync, () => !IsBusy);
        RefreshStatusCommand = new AsyncRelayCommand(RefreshServerStatusAsync);
        RefreshDiagnosticsCommand = new RelayCommand(RefreshDiagnostics);
        SaveSettingsCommand = new RelayCommand(SaveCurrentSettings);

        BrowseFfxiCommand = new RelayCommand(BrowseFfxiFolder);
        BrowseAshitaCommand = new RelayCommand(BrowseAshitaFolder);
        ResetAshitaPathCommand = new RelayCommand(ResetAshitaToLauncherFolder);
        BrowseCustomDatCommand = new RelayCommand(BrowseCustomDatFolder);
        OpenAshitaFolderCommand = new RelayCommand(OpenAshitaFolder);
        ExportServerOverrideCommand = new RelayCommand(ExportShareableServerJson);
        ApplyResolutionPresetCommand = new RelayCommand(ApplyResolutionPreset);
        ImportSystemSettingsCommand = new RelayCommand(ImportSystemSettings);
        ImportAshitaIniCommand = new RelayCommand(ImportFromAshitaIniDialog);
        LaunchFfxiConfigCommand = new RelayCommand(LaunchFfxiConfigTool);
        CreateDesktopShortcutCommand = new RelayCommand(CreateDesktopShortcut);
        SelectProductionServerCommand = new RelayCommand(() => SelectedServerTarget = ServerTargetMode.Production);
        StopStagingRelayCommand = new RelayCommand(StopStagingRelay, () => IsStagingRelayActive);
        ResetStagingDefaultsCommand = new RelayCommand(ResetStagingDefaults);
        InstallPerUserLauncherCommand = new RelayCommand(InstallPerUserLauncher, () => !IsBusy && CanInstallPerUser);
        RollbackLauncherCommand = new AsyncRelayCommand(RollbackLauncherAsync, () => !IsBusy && CanRollbackLauncher);
        ExportPerformanceBundleCommand = new RelayCommand(ExportPerformanceBundleNow, () => !IsBusy);
        OpenDiagnosticsFolderCommand = new RelayCommand(OpenDiagnosticsFolder);
        ExportModernDiagnosticsCommand = new RelayCommand(ExportModernDiagnosticsNow, () => !IsBusy);
        OpenModernLogsFolderCommand = new RelayCommand(OpenModernLogsFolder);
        InstallModernClientCommand = new AsyncRelayCommand(() => InstallSelectedModernClientAsync(forceReinstall: false), () => !IsBusy && IsModernEngineSelected);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? RequestMinimizeWindow;

    public ObservableCollection<ManifestNewsItem> NewsItems { get; }
    public ObservableCollection<string> ActivityLog { get; }

    public ICommand SelectTabCommand { get; }
    public ICommand PlayCommand { get; }
    public ICommand CheckUpdatesCommand { get; }
    public ICommand RepairFilesCommand { get; }
    public ICommand CheckLauncherUpdateCommand { get; }
    public ICommand ApplyLauncherUpdateCommand { get; }
    public ICommand InstallPrerequisitesCommand { get; }
    public ICommand RefreshStatusCommand { get; }
    public ICommand RefreshDiagnosticsCommand { get; }
    public ICommand SaveSettingsCommand { get; }
    public ICommand BrowseFfxiCommand { get; }
    public ICommand BrowseAshitaCommand { get; }
    public ICommand ResetAshitaPathCommand { get; }
    public ICommand BrowseCustomDatCommand { get; }
    public ICommand OpenAshitaFolderCommand { get; }
    public ICommand ExportServerOverrideCommand { get; }
    public ICommand ApplyResolutionPresetCommand { get; }
    public ICommand ImportSystemSettingsCommand { get; }
    public ICommand ImportAshitaIniCommand { get; }
    public ICommand LaunchFfxiConfigCommand { get; }
    public ICommand CreateDesktopShortcutCommand { get; }
    public ICommand SelectProductionServerCommand { get; }
    public ICommand StopStagingRelayCommand { get; }
    public ICommand ResetStagingDefaultsCommand { get; }
    public ICommand InstallPerUserLauncherCommand { get; }
    public ICommand RollbackLauncherCommand { get; }
    public ICommand ExportPerformanceBundleCommand { get; }
    public ICommand OpenDiagnosticsFolderCommand { get; }
    public ICommand ExportModernDiagnosticsCommand { get; }
    public ICommand OpenModernLogsFolderCommand { get; }
    public ICommand InstallModernClientCommand { get; }

    public IReadOnlyList<ServerTargetMode> ServerTargetOptions { get; } =
    [
        ServerTargetMode.Production,
        ServerTargetMode.Staging,
        ServerTargetMode.Custom
    ];

    public IReadOnlyList<StagingLane> StagingLaneOptions { get; } =
    [
        StagingLane.Combat,
        StagingLane.CoreUi,
        StagingLane.Native
    ];

    public string SelectedTab
    {
        get => _selectedTab;
        set
        {
            if (SetField(ref _selectedTab, value))
            {
                OnPropertyChanged(nameof(IsPlayTab));
                OnPropertyChanged(nameof(IsSettingsTab));
                OnPropertyChanged(nameof(IsSetupTab));
                OnPropertyChanged(nameof(IsGuideTab));
            }
        }
    }

    public bool IsPlayTab => SelectedTab == "Play";
    public bool IsSettingsTab => SelectedTab == "Settings";
    public bool IsSetupTab => SelectedTab == "Setup";
    public bool IsGuideTab => SelectedTab == "Guide";

    public string ServerName => _manifest.ServerName;
    public string Tagline => _manifest.Tagline;

    private ResolvedServerConnectionPlan CurrentConnectionPlan =>
        StagingRelayService.ResolveConnectionPlan(_settings, _manifest);

    public ServerTargetMode SelectedServerTarget
    {
        get => _settings.ServerTarget;
        set
        {
            if (_settings.ServerTarget == value)
            {
                return;
            }

            var previous = _settings.ServerTarget;
            _settings.ServerTarget = value;
            _settings.UseCustomServer = value == ServerTargetMode.Custom;

            if (previous == ServerTargetMode.Staging && value != ServerTargetMode.Staging)
            {
                _stagingRelay.Stop();
                _settingsService.Save(_settings, PlainPassword);
                var restoredIni = StagingRelayService.TryRestoreOrdinaryBootConfig(
                    _configGenerator,
                    _settings,
                    _manifest,
                    PlainPassword);
                var plan = CurrentConnectionPlan;
                StatusMessage = $"Switched to {value} ({plan.DisplayHost}). Staging relay stopped.";
                Log(restoredIni
                    ? $"Switched from Staging to {value} ({plan.DisplayHost}); stopped Staging TCP relay and restored soulspirexi.ini."
                    : $"Switched from Staging to {value} ({plan.DisplayHost}); stopped Staging TCP relay.");
            }
            else if (value == ServerTargetMode.Staging)
            {
                _settingsService.Save(_settings, PlainPassword);
                var plan = CurrentConnectionPlan;
                StatusMessage = $"Staging Server selected ({plan.DisplayHost}). Managed TCP relay starts automatically on Play.";
                Log($"Selected Staging Server ({plan.DisplayHost}, TCP {StagingAuthPort}/{StagingDataPort}/{StagingViewPort}/{StagingSearchPort}, Profile {StagingProfilePort}/{StagingProfileIrcPort}, Map UDP {plan.MapUdpPort}). No admin privileges or Windows portproxy changes required.");
            }
            else
            {
                _stagingRelay.Stop();
                _settingsService.Save(_settings, PlainPassword);
            }

            OnPropertyChanged();
            OnPropertyChanged(nameof(UseCustomServer));
            NotifyEffectiveServerChanged();
            _ = RefreshServerStatusAsync();
        }
    }

    public StagingLane SelectedStagingLane
    {
        get => _settings.StagingLane;
        set
        {
            if (_settings.StagingLane == value)
            {
                return;
            }

            _settings.ApplyStagingLanePreset(value);
            if (IsStagingRelayActive)
            {
                _stagingRelay.Stop();
            }

            _settingsService.Save(_settings, PlainPassword);

            OnPropertyChanged();
            OnPropertyChanged(nameof(StagingAuthPort));
            OnPropertyChanged(nameof(StagingDataPort));
            OnPropertyChanged(nameof(StagingViewPort));
            OnPropertyChanged(nameof(StagingSearchPort));
            OnPropertyChanged(nameof(StagingProfilePort));
            OnPropertyChanged(nameof(StagingProfileIrcPort));
            NotifyEffectiveServerChanged();

            var preset = LauncherSettings.GetStagingLanePreset(value);
            var plan = CurrentConnectionPlan;
            StatusMessage = $"Selected {preset.DisplayName} ({plan.DisplayHost}). Managed TCP relay starts on Play.";
            Log($"Selected Staging Lane: {preset.DisplayName} ({plan.StatusProbeHost}, TCP {StagingAuthPort}/{StagingDataPort}/{StagingViewPort}/{StagingSearchPort}, Profile {StagingProfilePort}/{StagingProfileIrcPort}, Map UDP {plan.MapUdpPort}).");
            _ = RefreshServerStatusAsync();
        }
    }

    public bool IsProductionMode => _settings.ServerTarget == ServerTargetMode.Production;
    public bool IsStagingMode => _settings.ServerTarget == ServerTargetMode.Staging;
    public bool IsCustomServerMode => _settings.ServerTarget == ServerTargetMode.Custom;
    public bool IsStagingRelayActive => _stagingRelay.IsRunning;

    public string EffectiveHost => CurrentConnectionPlan.StatusProbeHost;
    public bool EffectiveUseHairpin => CurrentConnectionPlan.BootUseHairpin;
    public int EffectiveLobbyPort => CurrentConnectionPlan.StatusProbeLobbyPort;
    public int EffectiveSearchPort => CurrentConnectionPlan.StatusProbeSearchPort;

    public string StagingHeaderBadgeText
    {
        get
        {
            var preset = LauncherSettings.GetStagingLanePreset(_settings.StagingLane);
            return $"TARGET: {preset.ShortBadgeLabel} ({preset.PortBlockLabel})";
        }
    }

    public string StagingCardHeaderText
    {
        get
        {
            var preset = LauncherSettings.GetStagingLanePreset(_settings.StagingLane);
            return $"{preset.ShortBadgeLabel} ACTIVE ({preset.PortBlockLabel})";
        }
    }

    public string ServerStatusDisplayHost
    {
        get
        {
            var plan = CurrentConnectionPlan;
            if (!IsStagingMode)
            {
                return plan.DisplayHost;
            }

            var preset = LauncherSettings.GetStagingLanePreset(_settings.StagingLane);
            return $"{preset.ShortBadgeLabel} • {plan.DisplayHost}";
        }
    }

    public string StagingTargetSummaryText
    {
        get
        {
            var plan = CurrentConnectionPlan;
            var preset = LauncherSettings.GetStagingLanePreset(_settings.StagingLane);
            return $"{preset.DisplayName} • {plan.StatusProbeHost} (Lobby/Search {StagingAuthPort}/{StagingDataPort}/{StagingViewPort}/{StagingSearchPort} • Profile {StagingProfilePort}/{StagingProfileIrcPort} • Map UDP {plan.MapUdpPort})";
        }
    }

    public string StagingRelayStatusText => IsStagingRelayActive
        ? "Managed loopback TCP relay ACTIVE on 127.0.0.1 (54231/54230/54001/54002/51220/51240) • No admin required"
        : "Managed loopback TCP relay ready (6 TCP ports incl. Profile 51220/51240 • Starts on Play • No admin required)";

    public bool IsBusy
    {
        get => _isBusy;
        set
        {
            if (SetField(ref _isBusy, value))
            {
                OnPropertyChanged(nameof(PlayButtonText));
                RelayCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string PlayButtonText
    {
        get
        {
            if (IsBusy)
            {
                return "PREPARING...";
            }

            if (IsStagingMode)
            {
                var preset = LauncherSettings.GetStagingLanePreset(_settings.StagingLane);
                return PendingUpdatesCount > 0
                    ? $"UPDATE & PLAY {preset.ShortBadgeLabel} ({PendingUpdatesCount})"
                    : $"PLAY {preset.ShortBadgeLabel}";
            }

            return PendingUpdatesCount > 0
                ? $"UPDATE & PLAY ({PendingUpdatesCount})"
                : "PLAY SOULSPIREXI";
        }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        set => SetField(ref _statusMessage, value);
    }

    public double ProgressPercent
    {
        get => _progressPercent;
        set => SetField(ref _progressPercent, value);
    }

    public int PendingUpdatesCount
    {
        get => _pendingUpdatesCount;
        set
        {
            if (SetField(ref _pendingUpdatesCount, value))
            {
                OnPropertyChanged(nameof(PlayButtonText));
                OnPropertyChanged(nameof(UpdateBadgeText));
                OnPropertyChanged(nameof(PayloadSyncStatusText));
                OnPropertyChanged(nameof(InstalledClientPayloadVersionText));
            }
        }
    }

    public string UpdateBadgeText => !string.IsNullOrWhiteSpace(_manifestUnavailableError)
        ? "Update blocked — switch channel"
        : (PendingUpdatesCount == 0
            ? "Client files up to date"
            : $"{PendingUpdatesCount} file update(s) ready");

    public ServerStatus ServerStatus
    {
        get => _serverStatus;
        private set => SetField(ref _serverStatus, value);
    }

    public InstallDiagnostics Diagnostics
    {
        get => _diagnostics;
        private set => SetField(ref _diagnostics, value);
    }

    public string PlainPassword
    {
        get => _plainPassword;
        set => SetField(ref _plainPassword, value);
    }

    // Settings Pass-Through Properties
    public bool UseCustomServer
    {
        get => _settings.UseCustomServer;
        set
        {
            if (_settings.UseCustomServer != value)
            {
                SelectedServerTarget = value
                    ? ServerTargetMode.Custom
                    : ServerTargetMode.Production;
            }
        }
    }

    public string StagingServerHost
    {
        get => _settings.StagingServerHost;
        set
        {
            if (_settings.StagingServerHost != value)
            {
                _settings.StagingServerHost = value;
                if (IsStagingRelayActive)
                {
                    _stagingRelay.Stop();
                }

                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int StagingAuthPort
    {
        get => _settings.StagingAuthPort;
        set
        {
            if (_settings.StagingAuthPort != value)
            {
                _settings.StagingAuthPort = value;
                if (IsStagingRelayActive)
                {
                    _stagingRelay.Stop();
                }

                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int StagingDataPort
    {
        get => _settings.StagingDataPort;
        set
        {
            if (_settings.StagingDataPort != value)
            {
                _settings.StagingDataPort = value;
                if (IsStagingRelayActive)
                {
                    _stagingRelay.Stop();
                }

                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int StagingViewPort
    {
        get => _settings.StagingViewPort;
        set
        {
            if (_settings.StagingViewPort != value)
            {
                _settings.StagingViewPort = value;
                if (IsStagingRelayActive)
                {
                    _stagingRelay.Stop();
                }

                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int StagingSearchPort
    {
        get => _settings.StagingSearchPort;
        set
        {
            if (_settings.StagingSearchPort != value)
            {
                _settings.StagingSearchPort = value;
                if (IsStagingRelayActive)
                {
                    _stagingRelay.Stop();
                }

                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int StagingProfilePort
    {
        get => _settings.StagingProfilePort;
        set
        {
            if (_settings.StagingProfilePort != value)
            {
                _settings.StagingProfilePort = value;
                if (IsStagingRelayActive)
                {
                    _stagingRelay.Stop();
                }

                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int StagingProfileIrcPort
    {
        get => _settings.StagingProfileIrcPort;
        set
        {
            if (_settings.StagingProfileIrcPort != value)
            {
                _settings.StagingProfileIrcPort = value;
                if (IsStagingRelayActive)
                {
                    _stagingRelay.Stop();
                }

                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public string CustomServerHost
    {
        get => _settings.CustomServerHost;
        set
        {
            if (_settings.CustomServerHost != value)
            {
                _settings.CustomServerHost = value;
                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public bool CustomUseHairpin
    {
        get => _settings.CustomUseHairpin;
        set
        {
            if (_settings.CustomUseHairpin != value)
            {
                _settings.CustomUseHairpin = value;
                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int CustomLobbyPort
    {
        get => _settings.CustomLobbyPort;
        set
        {
            if (_settings.CustomLobbyPort != value)
            {
                _settings.CustomLobbyPort = value;
                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public int CustomSearchPort
    {
        get => _settings.CustomSearchPort;
        set
        {
            if (_settings.CustomSearchPort != value)
            {
                _settings.CustomSearchPort = value;
                OnPropertyChanged();
                NotifyEffectiveServerChanged();
            }
        }
    }

    public string FfxiPath
    {
        get => _settings.FfxiPath;
        set
        {
            if (_settings.FfxiPath != value)
            {
                _settings.FfxiPath = value;
                OnPropertyChanged();
            }
        }
    }

    public string AshitaPath
    {
        get => _settings.AshitaPath;
        set
        {
            if (_settings.AshitaPath != value)
            {
                _settings.AshitaPath = value;
                _settings.UseCustomAshitaPath =
                    !string.IsNullOrWhiteSpace(value) &&
                    !SettingsService.PathsEqual(value, _settingsService.DefaultAshitaDirectory);
                OnPropertyChanged();
            }
        }
    }

    public bool SyncToCustomDatFolder
    {
        get => _settings.SyncToCustomDatFolder;
        set
        {
            if (_settings.SyncToCustomDatFolder != value)
            {
                _settings.SyncToCustomDatFolder = value;
                OnPropertyChanged();
            }
        }
    }

    public string CustomDatOverlayPath
    {
        get => _settings.CustomDatOverlayPath;
        set
        {
            if (_settings.CustomDatOverlayPath != value)
            {
                _settings.CustomDatOverlayPath = value;
                OnPropertyChanged();
            }
        }
    }

    public string Username
    {
        get => _settings.Username;
        set
        {
            if (_settings.Username != value)
            {
                _settings.Username = value;
                OnPropertyChanged();
            }
        }
    }

    public bool RememberPassword
    {
        get => _settings.RememberPassword;
        set
        {
            if (_settings.RememberPassword != value)
            {
                _settings.RememberPassword = value;
                OnPropertyChanged();
            }
        }
    }

    public bool AutoLogin
    {
        get => _settings.AutoLogin;
        set
        {
            if (_settings.AutoLogin != value)
            {
                _settings.AutoLogin = value;
                OnPropertyChanged();
            }
        }
    }

    public IReadOnlyList<WindowModeOption> WindowModes { get; } =
    [
        WindowModeOption.Borderless,
        WindowModeOption.Windowed,
        WindowModeOption.Fullscreen
    ];

    public WindowModeOption SelectedWindowMode
    {
        get => _settings.WindowMode;
        set
        {
            if (_settings.WindowMode != value)
            {
                _settings.WindowMode = value;
                OnPropertyChanged();
            }
        }
    }

    public int WindowWidth
    {
        get => _settings.WindowWidth;
        set { if (_settings.WindowWidth != value) { _settings.WindowWidth = value; OnPropertyChanged(); } }
    }

    public int WindowHeight
    {
        get => _settings.WindowHeight;
        set { if (_settings.WindowHeight != value) { _settings.WindowHeight = value; OnPropertyChanged(); } }
    }

    public int BackgroundWidth
    {
        get => _settings.BackgroundWidth;
        set { if (_settings.BackgroundWidth != value) { _settings.BackgroundWidth = value; OnPropertyChanged(); } }
    }

    public int BackgroundHeight
    {
        get => _settings.BackgroundHeight;
        set { if (_settings.BackgroundHeight != value) { _settings.BackgroundHeight = value; OnPropertyChanged(); } }
    }

    public int MenuWidth
    {
        get => _settings.MenuWidth;
        set { if (_settings.MenuWidth != value) { _settings.MenuWidth = value; OnPropertyChanged(); } }
    }

    public int MenuHeight
    {
        get => _settings.MenuHeight;
        set { if (_settings.MenuHeight != value) { _settings.MenuHeight = value; OnPropertyChanged(); } }
    }

    public int MipMapping
    {
        get => _settings.MipMapping;
        set { if (_settings.MipMapping != value) { _settings.MipMapping = value; OnPropertyChanged(); } }
    }

    public bool BumpMapping
    {
        get => _settings.BumpMapping;
        set { if (_settings.BumpMapping != value) { _settings.BumpMapping = value; OnPropertyChanged(); } }
    }

    public bool UncompressedTextures
    {
        get => _settings.UncompressedTextures;
        set { if (_settings.UncompressedTextures != value) { _settings.UncompressedTextures = value; OnPropertyChanged(); } }
    }

    public bool UncompressedMaps
    {
        get => _settings.UncompressedMaps;
        set { if (_settings.UncompressedMaps != value) { _settings.UncompressedMaps = value; OnPropertyChanged(); } }
    }

    public bool HighQualityFonts
    {
        get => _settings.HighQualityFonts;
        set { if (_settings.HighQualityFonts != value) { _settings.HighQualityFonts = value; OnPropertyChanged(); } }
    }

    public bool HardwareMouse
    {
        get => _settings.HardwareMouse;
        set { if (_settings.HardwareMouse != value) { _settings.HardwareMouse = value; OnPropertyChanged(); } }
    }

    public bool ShowOpeningMovie
    {
        get => _settings.ShowOpeningMovie;
        set { if (_settings.ShowOpeningMovie != value) { _settings.ShowOpeningMovie = value; OnPropertyChanged(); } }
    }

    public bool SoundEnabled
    {
        get => _settings.SoundEnabled;
        set { if (_settings.SoundEnabled != value) { _settings.SoundEnabled = value; OnPropertyChanged(); } }
    }

    public bool BackgroundSound
    {
        get => _settings.BackgroundSound;
        set { if (_settings.BackgroundSound != value) { _settings.BackgroundSound = value; OnPropertyChanged(); } }
    }

    public IReadOnlyList<int> FpsCapOptions { get; } = [60, 30, 0];

    public int SelectedFpsCap
    {
        get => _settings.FpsCap;
        set { if (_settings.FpsCap != value) { _settings.FpsCap = value; OnPropertyChanged(); } }
    }

    public IReadOnlyList<string> LanguageOptions { get; } = ["US", "EU", "JP"];

    public string SelectedLanguage
    {
        get => _settings.Language;
        set { if (_settings.Language != value) { _settings.Language = value; OnPropertyChanged(); } }
    }

    public bool EnablePivotOverlay
    {
        get => _settings.EnablePivotOverlay;
        set { if (_settings.EnablePivotOverlay != value) { _settings.EnablePivotOverlay = value; OnPropertyChanged(); } }
    }

    public bool EnableFlintlockDualPistolsOverlay
    {
        get => _settings.EnableFlintlockDualPistolsOverlay;
        set { if (_settings.EnableFlintlockDualPistolsOverlay != value) { _settings.EnableFlintlockDualPistolsOverlay = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadTalentsAddon
    {
        get => _settings.AutoLoadTalentsAddon;
        set { if (_settings.AutoLoadTalentsAddon != value) { _settings.AutoLoadTalentsAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadCrystalSocketAddon
    {
        get => _settings.AutoLoadCrystalSocketAddon;
        set { if (_settings.AutoLoadCrystalSocketAddon != value) { _settings.AutoLoadCrystalSocketAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadMetricsAddon
    {
        get => _settings.AutoLoadMetricsAddon;
        set { if (_settings.AutoLoadMetricsAddon != value) { _settings.AutoLoadMetricsAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadCheckerAddon
    {
        get => _settings.AutoLoadCheckerAddon;
        set { if (_settings.AutoLoadCheckerAddon != value) { _settings.AutoLoadCheckerAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadMobDbAddon
    {
        get => _settings.AutoLoadMobDbAddon;
        set { if (_settings.AutoLoadMobDbAddon != value) { _settings.AutoLoadMobDbAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadKazenoeyeAddon
    {
        get => _settings.AutoLoadKazenoeyeAddon;
        set { if (_settings.AutoLoadKazenoeyeAddon != value) { _settings.AutoLoadKazenoeyeAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadGearAddon
    {
        get => _settings.AutoLoadGearAddon;
        set { if (_settings.AutoLoadGearAddon != value) { _settings.AutoLoadGearAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoLoadSoulHudAddon
    {
        get => _settings.AutoLoadSoulHudAddon;
        set { if (_settings.AutoLoadSoulHudAddon != value) { _settings.AutoLoadSoulHudAddon = value; OnPropertyChanged(); } }
    }

    public bool AutoCloseOnLaunch
    {
        get => _settings.AutoCloseOnLaunch;
        set { if (_settings.AutoCloseOnLaunch != value) { _settings.AutoCloseOnLaunch = value; OnPropertyChanged(); } }
    }

    public bool AutoCheckUpdatesOnStartup
    {
        get => _settings.AutoCheckUpdatesOnStartup;
        set { if (_settings.AutoCheckUpdatesOnStartup != value) { _settings.AutoCheckUpdatesOnStartup = value; OnPropertyChanged(); } }
    }

    public bool AutoUpdateLauncher
    {
        get => _settings.AutoUpdateLauncher;
        set { if (_settings.AutoUpdateLauncher != value) { _settings.AutoUpdateLauncher = value; OnPropertyChanged(); } }
    }

    public bool EnableAutomaticTestingQolSettings
    {
        get => _settings.EnableAutomaticTestingQolSettings;
        set
        {
            if (_settings.EnableAutomaticTestingQolSettings != value)
            {
                _settings.EnableAutomaticTestingQolSettings = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(TestingQolStatusText));
                OnPropertyChanged(nameof(CanEnablePerformanceDiagnostics));
                OnPropertyChanged(nameof(PerfDiagStatusText));
                SyncCorePerfConfigSafe();
                _settingsService.Save(_settings, PlainPassword);
                Log($"Automatic Testing Quality of Life Settings {(value ? "enabled" : "disabled")}.");
            }
        }
    }

    public string TestingQolStatusText
    {
        get
        {
            var resolved = TestingEnvironmentQolPolicy.ResolveInputSettings(
                _settings,
                EffectiveHost,
                _manifest.Channel,
                _manifest.ServerName);

            if (resolved.TestingQolApplied)
            {
                return $"Active ({resolved.Reason}): Allow Binds During Input & Allow Windows Key will be applied before launch.";
            }

            if (!_settings.EnableAutomaticTestingQolSettings)
            {
                return "Disabled: original Ashita input preferences will be used.";
            }

            return "Standby (Stable production server): original Ashita input preferences will be preserved.";
        }
    }

    public bool CanEnablePerformanceDiagnostics => IsTestingChannel;

    public bool EnablePerformanceDiagnostics
    {
        get => _settings.EnablePerformanceDiagnostics;
        set
        {
            if (_settings.EnablePerformanceDiagnostics != value)
            {
                _settings.EnablePerformanceDiagnostics = value;
                SyncCorePerfConfigSafe();
                OnPropertyChanged();
                OnPropertyChanged(nameof(PerfDiagStatusText));
                _settingsService.Save(_settings, PlainPassword);
                Log($"Performance Diagnostics {(value && IsTestingChannel ? "enabled (Testing channel)" : "disabled")}.");
            }
        }
    }

    public string PerfDiagStatusText
    {
        get
        {
            if (!IsTestingChannel)
            {
                return "Disabled on Stable channel (switch to a Testing channel to opt in).";
            }

            if (TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(_settings, _manifest.Channel))
            {
                return string.IsNullOrWhiteSpace(_lastPerfExportPath)
                    ? "Active (Testing): records launcher & Core timings with redacted JSON export on exit (<= 512 KB)."
                    : $"Active (Testing): last bundle saved ({Path.GetFileName(_lastPerfExportPath)}).";
            }

            return "Off by default: opt in to record launcher & in-game Core performance baselines on Testing.";
        }
    }

    public string LauncherVersionText => $"v{LauncherSelfUpdateService.GetCurrentInformationalVersion()}";

    public string LauncherExecutableVersionText => LauncherVersionText;

    public string InstalledClientPayloadVersionText
    {
        get
        {
            var installed = ManifestUpdateService.LoadInstalledState(AshitaPath);
            if (installed is null || string.IsNullOrWhiteSpace(installed.ManifestVersion))
            {
                return "Not synced";
            }

            return installed.ManifestVersion.Trim();
        }
    }

    public string AvailableClientPayloadVersionText =>
        !string.IsNullOrWhiteSpace(_manifestUnavailableError)
            ? "Unavailable"
            : (string.IsNullOrWhiteSpace(_manifest.ManifestVersion) ? "1.0.0" : _manifest.ManifestVersion.Trim());

    public int ResolvedNativeHookCount =>
        _manifest.Registry?.NativeHooks is > 0
            ? _manifest.Registry.NativeHooks.Value
            : (_manifest.ServerCompatibility?.NativeHooks is > 0
                ? _manifest.ServerCompatibility.NativeHooks.Value
                : (_manifest.ServerCompatibility?.CrystalJobsHooks ?? 0));

    public string NativeDllHookCountText =>
        ResolvedNativeHookCount > 0 ? $"{ResolvedNativeHookCount} hooks" : "Unknown";

    public string PayloadSourceCommitText
    {
        get
        {
            var branch = string.IsNullOrWhiteSpace(_manifest.Repo?.Branch) ? "main" : _manifest.Repo.Branch.Trim();
            var commit = _manifest.ServerCompatibility?.Commit?.Trim();
            return !string.IsNullOrWhiteSpace(commit) ? $"{branch} ({commit})" : branch;
        }
    }

    public string PayloadSyncStatusText
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(_manifestUnavailableError))
            {
                return "Manifest unavailable";
            }

            return PendingUpdatesCount > 0
                ? $"{PendingUpdatesCount} file(s) pending sync"
                : "Up to date";
        }
    }

    public IReadOnlyList<UpdateChannel> UpdateChannelOptions { get; } =
    [
        UpdateChannel.Stable,
        UpdateChannel.Testing
    ];

    public UpdateChannel SelectedUpdateChannel
    {
        get => ManifestUpdateService.NormalizeUserFacingChannel(_settings.UpdateChannel);
        set
        {
            var normalized = ManifestUpdateService.NormalizeUserFacingChannel(value);
            if (_settings.UpdateChannel != normalized)
            {
                _settings.UpdateChannel = normalized;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsTestingChannel));
                OnPropertyChanged(nameof(ChannelBadgeText));
                OnPropertyChanged(nameof(ChannelDescriptionText));
                OnPropertyChanged(nameof(TestingQolStatusText));
                OnPropertyChanged(nameof(CanEnablePerformanceDiagnostics));
                OnPropertyChanged(nameof(PerfDiagStatusText));
                OnPropertyChanged(nameof(SelectedClientEngine));
                OnPropertyChanged(nameof(CanSelectModernEngine));
                OnPropertyChanged(nameof(IsModernEngineSelected));
                OnPropertyChanged(nameof(ClientEngineStatusText));
                NotifyPayloadMetadataChanged();
                SyncCorePerfConfigSafe();
                _settingsService.Save(_settings, PlainPassword);
                Log($"Switched update channel to {normalized}. Checking manifest...");
                _ = CheckUpdatesOnlyAsync();
            }
        }
    }

    public bool IsTestingChannel => ManifestUpdateService.NormalizeUserFacingChannel(_settings.UpdateChannel) == UpdateChannel.Testing;

    public string ChannelBadgeText => IsTestingChannel
        ? (ResolvedNativeHookCount > 0 ? $"TESTING ({ResolvedNativeHookCount}-HOOK)" : "TESTING")
        : "STABLE";

    public string ChannelDescriptionText => IsTestingChannel
        ? $"Canonical Testing payload ({(ResolvedNativeHookCount > 0 ? $"{ResolvedNativeHookCount}-hook" : "native")} DLL, Soulspire Core, Stage 2A performance diagnostics, Testing QoL, and weapon presentation updates) without affecting Stable players."
        : "Stable channel delivers production-verified SoulspireXI client builds.";

    public IReadOnlyList<ClientEngineMode> ClientEngineOptions { get; } =
    [
        ClientEngineMode.Classic,
        ClientEngineMode.ModernBaseline,
        ClientEngineMode.ModernCompat,
        ClientEngineMode.ModernNative
    ];

    public bool CanSelectModernEngine =>
        IsTestingChannel ||
        _manifest.ModernClient?.ClientVerified == true ||
        _manifest.ModernClient?.Baseline?.ClientVerified == true ||
        _manifest.ModernClient?.Compat?.ClientVerified == true ||
        _manifest.ModernClient?.Native?.ClientVerified == true;

    public ClientEngineMode SelectedClientEngine
    {
        get => ModernClientConfigGenerator.ResolveEffectiveEngine(_settings, _manifest);
        set
        {
            var effective = ModernClientConfigGenerator.IsModernEngine(value) && !CanSelectModernEngine
                ? ClientEngineMode.Classic
                : value;
            if (_settings.ClientEngine != effective)
            {
                _settings.ClientEngine = effective;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsModernEngineSelected));
                OnPropertyChanged(nameof(IsModernCompatSelected));
                OnPropertyChanged(nameof(ActiveModernProfileDirectory));
                OnPropertyChanged(nameof(ClientEngineStatusText));
                OnPropertyChanged(nameof(ModernDiagnosticsStatusText));
                _settingsService.Save(_settings, PlainPassword);
                Log(effective switch
                {
                    ClientEngineMode.ModernBaseline => "Selected Modern — VanaCore Baseline (Experimental) in isolated ModernClient\\baseline folder.",
                    ClientEngineMode.ModernCompat => "Selected Modern — Soulspire Compatibility (Experimental) in isolated ModernClient\\compat folder.",
                    ClientEngineMode.ModernNative => "Selected Modern — Soulspire Native (Experimental, zero Ashita compat) in isolated ModernClient\\native folder.",
                    _ => "Selected Classic — Ashita v4 client engine."
                });
            }
        }
    }

    public bool IsModernEngineSelected => ModernClientConfigGenerator.IsModernEngine(SelectedClientEngine);
    public bool IsModernCompatSelected => SelectedClientEngine == ClientEngineMode.ModernCompat;

    public string ModernClientPath
    {
        get => string.IsNullOrWhiteSpace(_settings.ModernClientPath)
            ? Path.Combine(SettingsService.ResolveLauncherBaseDirectory(), "ModernClient")
            : _settings.ModernClientPath;
        set
        {
            if (_settings.ModernClientPath != value)
            {
                _settings.ModernClientPath = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(ActiveModernProfileDirectory));
                OnPropertyChanged(nameof(ClientEngineStatusText));
                OnPropertyChanged(nameof(ModernDiagnosticsStatusText));
                _settingsService.Save(_settings, PlainPassword);
            }
        }
    }

    public string ActiveModernProfileDirectory =>
        ModernClientConfigGenerator.ResolveProfileDirectory(ModernClientPath, SelectedClientEngine);

    public bool ModernClientUseD3D11Fallback
    {
        get => _settings.ModernClientUseD3D11Fallback;
        set
        {
            if (_settings.ModernClientUseD3D11Fallback != value)
            {
                _settings.ModernClientUseD3D11Fallback = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(ClientEngineStatusText));
                _settingsService.Save(_settings, PlainPassword);
            }
        }
    }

    public bool ModernClientSafeLoginMode
    {
        get => _settings.ModernClientSafeLoginMode;
        set
        {
            if (_settings.ModernClientSafeLoginMode != value)
            {
                _settings.ModernClientSafeLoginMode = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(ClientEngineStatusText));
                _settingsService.Save(_settings, PlainPassword);
            }
        }
    }

    public string ClientEngineStatusText
    {
        get
        {
            if (!CanSelectModernEngine)
            {
                return "Classic — Ashita v4 active. Switch Update Channel to Testing to opt into Modern (VanaCore — Experimental).";
            }

            if (!IsModernEngineSelected)
            {
                return "Classic — Ashita v4 active. Your Ashita installation stays isolated and untouched if you test Modern.";
            }

            var mode = SelectedClientEngine;
            var profileDir = ActiveModernProfileDirectory;
            var pkg = _manifest.ModernClient?.ResolvePackage(mode);
            var rendererLabel = ModernClientUseD3D11Fallback ? "D3D11 fallback" : "D3D12";
            var modeSummary = mode == ClientEngineMode.ModernBaseline
                ? "Baseline (all Soulspire native hooks, addons & experimental menus disabled)"
                : "Soulspire Compatibility (progressive dual-host soulspire_native.dll + Core + Pivot)";

            if (pkg is not null && ModernClientInstallService.IsUpToDate(profileDir, pkg))
            {
                return $"Ready ({pkg.Tag}, {rendererLabel}) — {modeSummary}. Press Play to launch securely via --password-stdin.";
            }

            if (pkg is not null && !string.IsNullOrWhiteSpace(pkg.PackageUrl))
            {
                return $"Will auto-download & SHA-256 verify {pkg.Tag} into isolated folder on Play ({rendererLabel}) — {modeSummary}.";
            }

            var exe = GameLaunchService.ResolveModernClientExecutable(profileDir);
            return exe is not null
                ? $"Local build ready ({rendererLabel}) — {modeSummary}. Uses --password-stdin."
                : $"No local package found in {profileDir}. Check for Testing updates to fetch the verified Modern client package.";
        }
    }

    public string ModernDiagnosticsStatusText
    {
        get
        {
            var profileDir = ActiveModernProfileDirectory;
            var vanaLog = Path.Combine(profileDir, "logs", "vanacore.log");
            if (!File.Exists(vanaLog))
            {
                return "No VanaCore session log yet. Launch Modern once, then click Export Modern Diagnostics to create a redacted ZIP.";
            }

            try
            {
                var summary = ModernClientDiagnosticsService.ParseVanaCoreLog(File.ReadAllText(vanaLog));
                return $"Latest log: sigs matched={summary.MatchedCount}, failed={summary.FailedCount} | {summary.FfxiMainInfo}";
            }
            catch
            {
                return "VanaCore log detected. Click Export Modern Diagnostics to export a redacted diagnostic ZIP.";
            }
        }
    }

    private void NotifyPayloadMetadataChanged()
    {
        OnPropertyChanged(nameof(ChannelBadgeText));
        OnPropertyChanged(nameof(ChannelDescriptionText));
        OnPropertyChanged(nameof(ManifestVersionText));
        OnPropertyChanged(nameof(InstalledClientPayloadVersionText));
        OnPropertyChanged(nameof(AvailableClientPayloadVersionText));
        OnPropertyChanged(nameof(ResolvedNativeHookCount));
        OnPropertyChanged(nameof(NativeDllHookCountText));
        OnPropertyChanged(nameof(PayloadSourceCommitText));
        OnPropertyChanged(nameof(PayloadSyncStatusText));
    }

    public string ManifestVersionText
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(_manifestUnavailableError))
            {
                return $"{ChannelBadgeText} • Manifest unavailable (see status log)";
            }

            var version = string.IsNullOrWhiteSpace(_manifest.ManifestVersion) ? "1.0.0" : _manifest.ManifestVersion.Trim();
            var channel = string.IsNullOrWhiteSpace(_manifest.Channel) ? "stable" : _manifest.Channel.Trim().ToUpperInvariant();
            var candidateTag = !string.IsNullOrWhiteSpace(_manifest.CandidateId)
                ? $" • {_manifest.CandidateId.Trim()}"
                : string.Empty;
            var registryInfo = _manifest.Registry is { } reg && !string.IsNullOrWhiteSpace(reg.Hash)
                ? $" • Registry: {reg.Hash.Trim()}"
                : string.Empty;
            var serverInfo = _manifest.ServerCompatibility is { } sc && !string.IsNullOrWhiteSpace(sc.Version)
                ? $" • Server: {sc.Version}"
                : string.Empty;
            return $"Manifest {version} ({channel}{candidateTag}){registryInfo}{serverInfo}";
        }
    }

    public bool IsLauncherUpdateAvailable => _availableLauncherUpdate?.UpdateAvailable == true;

    public LauncherUpdateStage LauncherUpdateStage
    {
        get => _launcherUpdateStage;
        private set
        {
            if (SetField(ref _launcherUpdateStage, value))
            {
                OnPropertyChanged(nameof(LauncherUpdateStatusText));
            }
        }
    }

    public string LauncherUpdateStatusText
    {
        get => _launcherUpdateStatusText;
        private set => SetField(ref _launcherUpdateStatusText, value);
    }

    public bool CanInstallPerUser
    {
        get
        {
            var exePath = LauncherSelfUpdateService.GetCurrentExecutablePath();
            return !string.IsNullOrWhiteSpace(exePath) &&
                   !LauncherInstallationService.IsRunningFromPerUserInstall(exePath);
        }
    }

    public bool CanRollbackLauncher
    {
        get
        {
            var exePath = LauncherSelfUpdateService.GetCurrentExecutablePath();
            var dir = !string.IsNullOrWhiteSpace(exePath) ? Path.GetDirectoryName(exePath) : null;
            return !string.IsNullOrWhiteSpace(dir) && LauncherInstallationService.CanRollback(dir, out _);
        }
    }

    public string RollbackLauncherButtonText =>
        !string.IsNullOrWhiteSpace(_installState?.PreviousVersion)
            ? $"Rollback to {_installState.PreviousVersion}"
            : "Rollback Previous Launcher";

    public string LauncherInstallLocationText
    {
        get
        {
            var exePath = LauncherSelfUpdateService.GetCurrentExecutablePath();
            if (string.IsNullOrWhiteSpace(exePath))
            {
                return "Development / unpacked build";
            }

            var mode = LauncherInstallationService.IsRunningFromPerUserInstall(exePath)
                ? "Per-user install"
                : "Portable location";
            return $"{mode}: {Path.GetDirectoryName(exePath)}";
        }
    }

    public string LauncherUpdateButtonText => IsLauncherUpdateAvailable
        ? $"Update Launcher ({_availableLauncherUpdate!.LatestTag})"
        : "Check Launcher Update";

    public bool GamepadAllowBackground
    {
        get => _settings.GamepadAllowBackground;
        set { if (_settings.GamepadAllowBackground != value) { _settings.GamepadAllowBackground = value; OnPropertyChanged(); } }
    }

    public bool GamepadDisableEnumeration
    {
        get => _settings.GamepadDisableEnumeration;
        set { if (_settings.GamepadDisableEnumeration != value) { _settings.GamepadDisableEnumeration = value; OnPropertyChanged(); } }
    }

    public bool EnableGamepad
    {
        get => _settings.EnableGamepad;
        set
        {
            if (_settings.EnableGamepad != value)
            {
                _settings.EnableGamepad = value;
                _settings.UseCustomGamepadConfig = true;
                OnPropertyChanged();
                OnPropertyChanged(nameof(GamepadSummaryText));
            }
        }
    }

    public bool EnableXInput
    {
        get => _settings.EnableXInput;
        set
        {
            if (_settings.EnableXInput != value)
            {
                _settings.EnableXInput = value;
                _settings.UseCustomGamepadConfig = true;
                OnPropertyChanged();
                OnPropertyChanged(nameof(GamepadSummaryText));
            }
        }
    }

    public string GamepadSummaryText
    {
        get
        {
            var padMode = AshitaConfigGenerator.BuildEffectivePadMode(_settings);
            var hasCustomMap = !string.IsNullOrWhiteSpace(_settings.PadSin);
            if (padMode == "-1" && !hasCustomMap)
            {
                return "Gamepad mode: Windows FFXI Registry passthrough (-1)";
            }

            var mappingLabel = hasCustomMap ? "button map imported" : "default button map";
            return $"padmode000 = {padMode} ({mappingLabel})";
        }
    }

    public string ImportedSettingsSourceText =>
        string.IsNullOrWhiteSpace(_settings.ImportedSettingsSource)
            ? "No external FFXI/Ashita settings imported yet"
            : $"Last imported: {_settings.ImportedSettingsSource}";

    public async Task InitializeAsync()
    {
        var cmdArgs = Environment.GetCommandLineArgs();
        var justUpdated = cmdArgs.Any(arg => arg.Equals(LauncherSelfUpdateService.JustUpdatedArg, StringComparison.OrdinalIgnoreCase));
        var rolledBack = cmdArgs.Any(arg => arg.Equals(LauncherSelfUpdateService.RolledBackArg, StringComparison.OrdinalIgnoreCase));
        var updateFailed = cmdArgs.Any(arg => arg.Equals(LauncherSelfUpdateService.UpdateFailedArg, StringComparison.OrdinalIgnoreCase));
        var updatedTo = ReadArgValue(cmdArgs, LauncherSelfUpdateService.UpdatedToArg);
        LauncherSelfUpdateService.CleanupStagingDirectory();

        // Only remove obsolete OverlordsLauncher.exe once SoulspireLauncher.exe itself is verified running.
        var currentExePath = LauncherSelfUpdateService.GetCurrentExecutablePath();
        var currentInstallDir = !string.IsNullOrWhiteSpace(currentExePath) ? Path.GetDirectoryName(currentExePath) : null;
        if (!string.IsNullOrWhiteSpace(currentInstallDir))
        {
            var recovery = LauncherInstallationService.RecoverFromInterruptedUpdate(currentInstallDir);
            if (recovery.RecoveredCorruptOrMissingExe || recovery.CleanedTempFilesCount > 0 || recovery.ClearedPendingVerification)
            {
                Log($"Launcher recovery: {recovery.Summary}");
            }

            RefreshInstallState();
        }

        if (LauncherSelfUpdateService.CleanupObsoleteLegacyLauncherBinary(currentExePath))
        {
            Log("Removed obsolete OverlordsLauncher.exe after verifying SoulspireLauncher.exe.");
        }

        if (!string.IsNullOrWhiteSpace(currentExePath) &&
            string.Equals(Path.GetFileName(currentExePath), LauncherSelfUpdateService.CanonicalLauncherExeName, StringComparison.OrdinalIgnoreCase))
        {
            var shortcutResult = _shortcutMigrationService.MigrateLegacyShortcuts(currentExePath);
            if (shortcutResult.MigratedCount > 0)
            {
                Log($"Migrated {shortcutResult.MigratedCount} legacy shortcut(s) to SoulspireXI Launcher.");
            }
        }

        try
        {
            _settingsService.EnsureAshitaDirectory(_settings);
            OnPropertyChanged(nameof(AshitaPath));
        }
        catch (Exception ex)
        {
            Log($"Could not create Ashita folder at {AshitaPath}: {ex.Message}");
        }

        var isFirstRun = !File.Exists(_settingsService.SettingsPath);
        RefreshDiagnostics();
        if (string.IsNullOrWhiteSpace(_settings.FfxiPath) && !string.IsNullOrWhiteSpace(Diagnostics.DetectedFfxiPath))
        {
            FfxiPath = Diagnostics.DetectedFfxiPath;
            if (Diagnostics.FfxiRegion is "US" or "EU" or "JP")
            {
                SelectedLanguage = Diagnostics.FfxiRegion;
            }
        }

        if (isFirstRun || !_settings.HasImportedSystemSettings)
        {
            var importResult = _importService.ImportBestAvailable(_settings, gamepadOnly: !isFirstRun);
            if (importResult.ImportedAny)
            {
                NotifyAllSettingsChanged();
                _settingsService.Save(_settings, PlainPassword);
                Log(importResult.SourceSummary);
            }
            else if (isFirstRun)
            {
                _settings.HasImportedSystemSettings = true;
                _settingsService.Save(_settings, PlainPassword);
            }
        }

        Log($"Launcher {LauncherVersionText} initialized ({_settings.UpdateChannel} • {_settings.ServerTarget}). Ashita path: {AshitaPath}");
        SyncCorePerfConfigSafe();
        if (!_hasRecordedStartupSpan)
        {
            _hasRecordedStartupSpan = true;
            App.StartupStopwatch.Stop();
            _perfDiag.RecordDurationMs(
                IsPerfDiagActive,
                "startup",
                App.StartupStopwatch.Elapsed.TotalMilliseconds,
                isColdOverride: true,
                outcome: "complete",
                scope: "client_only");
        }
        if (justUpdated)
        {
            LauncherUpdateStage = LauncherUpdateStage.Completed;
            var targetLabel = string.IsNullOrWhiteSpace(updatedTo) ? LauncherVersionText : updatedTo;
            LauncherUpdateStatusText = $"Update completed ({targetLabel})";
            StatusMessage = $"Launcher updated to {targetLabel}. Settings and {_settings.ServerTarget} environment preserved.";
            Log(StatusMessage);
        }
        else if (rolledBack)
        {
            LauncherUpdateStage = LauncherUpdateStage.Completed;
            var targetLabel = string.IsNullOrWhiteSpace(updatedTo) ? LauncherVersionText : updatedTo;
            LauncherUpdateStatusText = $"Rolled back to {targetLabel}";
            StatusMessage = $"Launcher rolled back to {targetLabel}.";
            Log(StatusMessage);
        }
        else if (updateFailed)
        {
            LauncherUpdateStage = LauncherUpdateStage.Failed;
            var detail = _installState?.LastUpdateError ?? "Previous launcher update failed and rolled back safely.";
            LauncherUpdateStatusText = $"Previous update rolled back: {detail}";
            StatusMessage = LauncherUpdateStatusText;
            Log(StatusMessage);
        }

        await RefreshServerStatusAsync();

        if (_settings.AutoCheckUpdatesOnStartup)
        {
            await CheckUpdatesOnlyAsync();
        }

        if (!justUpdated && !rolledBack && (_settings.AutoUpdateLauncher || _settings.AutoCheckUpdatesOnStartup))
        {
            await CheckAndApplyLauncherUpdateAsync(autoApply: _settings.AutoUpdateLauncher, showUpToDateDialog: false);
        }
    }

    private async Task CheckUpdatesOnlyAsync()
    {
        var checkSw = PerformanceDiagnosticsService.StartSpanIfEnabled(IsPerfDiagActive);
        var isColdCheck = _isColdCheckSpan;
        try
        {
            StatusMessage = $"Checking SoulspireXI {ChannelBadgeText} manifest...";
            var embedded = _manifestService.LoadEmbeddedManifest();
            var result = await _manifestService.FetchManifestDetailedAsync(
                embedded,
                _settingsService.LoadLocalServerOverride(),
                _settings.UpdateChannel,
                perf: _perfDiag,
                perfEnabled: IsPerfDiagActive,
                isColdCheck: isColdCheck);

            if (result.Manifest is null)
            {
                _perfDiag.RecordSpan(IsPerfDiagActive, "check", checkSw, isColdCheck, "failed", "client_plus_server_rtt");
                _isColdCheckSpan = false;
                _manifestUnavailableError = result.ErrorMessage ?? $"Could not load remote manifest for {_settings.UpdateChannel}.";
                PendingUpdatesCount = 0;
                OnPropertyChanged(nameof(ManifestVersionText));
                OnPropertyChanged(nameof(UpdateBadgeText));
                StatusMessage = _manifestUnavailableError;
                Log(StatusMessage);
                return;
            }

            _manifestUnavailableError = null;
            OnPropertyChanged(nameof(UpdateBadgeText));
            _manifest = result.Manifest;
            ApplyManifest(result.Manifest);

            var pending = _manifestService.GetOutdatedFiles(_manifest, _settings, perf: _perfDiag, perfEnabled: IsPerfDiagActive, isCold: isColdCheck);
            _perfDiag.RecordSpan(IsPerfDiagActive, "check", checkSw, isColdCheck, "complete", "client_plus_server_rtt", files: pending.Count);
            _isColdCheckSpan = false;
            PendingUpdatesCount = pending.Count;
            RefreshDiagnostics();

            StatusMessage = result.FromRemote
                ? (pending.Count == 0 ? $"All SoulspireXI ({ChannelBadgeText}) client files are up to date." : $"{pending.Count} update(s) available on {ChannelBadgeText}.")
                : "Using bundled Stable manifest (offline or GitHub unreachable).";
            Log(StatusMessage);
        }
        catch (Exception ex)
        {
            StatusMessage = $"Update check failed: {ex.Message}";
            Log(StatusMessage);
        }
    }

    private void ApplyManifest(LauncherManifest manifest)
    {
        _manifest = manifest;
        OnPropertyChanged(nameof(ServerName));
        OnPropertyChanged(nameof(Tagline));
        NotifyPayloadMetadataChanged();
        NotifyEffectiveServerChanged();

        NewsItems.Clear();
        foreach (var item in _manifest.News)
        {
            NewsItems.Add(item);
        }
    }

    private async Task<bool> CheckAndApplyLauncherUpdateAsync(
        bool autoApply,
        bool showUpToDateDialog,
        bool promptOnUpdateIfManual = false)
    {
        try
        {
            LauncherUpdateStage = LauncherUpdateStage.Checking;
            LauncherUpdateStatusText = $"Checking {ChannelBadgeText} launcher updates...";
            var result = await _selfUpdateService.CheckForUpdateAsync(_manifest, _settings.UpdateChannel);
            _availableLauncherUpdate = result;
            OnPropertyChanged(nameof(IsLauncherUpdateAvailable));
            OnPropertyChanged(nameof(LauncherUpdateButtonText));
            RelayCommand.RaiseCanExecuteChanged();

            if (!result.UpdateAvailable)
            {
                LauncherUpdateStage = LauncherUpdateStage.UpToDate;
                LauncherUpdateStatusText = $"Up to date ({LauncherVersionText} • {ChannelBadgeText})";
                if (showUpToDateDialog)
                {
                    MessageBox.Show(
                        $"SoulspireXI Launcher {LauncherVersionText} ({ChannelBadgeText}) is already up to date.",
                        "SoulspireXI Launcher — Up to Date",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }

                return false;
            }

            LauncherUpdateStage = LauncherUpdateStage.UpdateAvailable;
            LauncherUpdateStatusText = $"Update available: {result.LatestTag} ({ChannelBadgeText})";
            Log($"Launcher update available ({ChannelBadgeText}, source={result.Source}): {result.LatestTag} (current {LauncherVersionText})");

            if (autoApply)
            {
                if (_stagingRelay.IsRunning)
                {
                    LauncherUpdateStage = LauncherUpdateStage.DeferredActiveRelay;
                    LauncherUpdateStatusText = $"Update {result.LatestTag} ready — deferred while Staging relay is active";
                    StatusMessage = LauncherUpdateStatusText;
                    Log("Deferred automatic launcher update because the Staging TCP relay is currently active.");
                    return false;
                }

                if (LauncherSelfUpdateService.CanSelfUpdateInPlace(out _, out var reason))
                {
                    return await ApplyAvailableLauncherUpdateAsync(isAutoApply: true);
                }

                Log($"Automatic launcher update skipped: {reason}");
                StatusMessage = $"Launcher {result.LatestTag} available (click Update Launcher or Install Per-User).";
                return false;
            }

            StatusMessage = $"Launcher {result.LatestTag} is available!";
            if (showUpToDateDialog || promptOnUpdateIfManual)
            {
                var prompt = promptOnUpdateIfManual
                    ? $"A verified SoulspireXI Launcher release ({result.LatestTag}) is available.\nCurrent version: {LauncherVersionText}\n\nDownload, verify, and restart before playing?"
                    : $"A verified SoulspireXI Launcher release ({result.LatestTag}) is available.\nCurrent version: {LauncherVersionText}\n\nDownload, verify, and restart now?";
                var choice = MessageBox.Show(
                    prompt,
                    "SoulspireXI Launcher — Update Available",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information);
                if (choice == MessageBoxResult.Yes)
                {
                    return await ApplyAvailableLauncherUpdateAsync(isAutoApply: false);
                }
            }
        }
        catch (Exception ex)
        {
            LauncherUpdateStage = LauncherUpdateStage.Failed;
            LauncherUpdateStatusText = $"Update check failed: {ex.Message}";
            Log($"Launcher update check failed: {ex.Message}");
            if (showUpToDateDialog)
            {
                MessageBox.Show(
                    $"Could not check for SoulspireXI Launcher updates:\n{ex.Message}",
                    "SoulspireXI Launcher — Update Check Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        return false;
    }

    private async Task<bool> ApplyAvailableLauncherUpdateAsync(bool isAutoApply = false)
    {
        if (_availableLauncherUpdate is null || !_availableLauncherUpdate.UpdateAvailable)
        {
            return false;
        }

        // Coordinate with active Staging TCP relay so gameplay connections are never unexpectedly severed
        if (_stagingRelay.IsRunning)
        {
            if (isAutoApply)
            {
                LauncherUpdateStage = LauncherUpdateStage.DeferredActiveRelay;
                LauncherUpdateStatusText = $"Update {_availableLauncherUpdate.LatestTag} deferred while Staging relay is active";
                StatusMessage = LauncherUpdateStatusText;
                Log("Deferred automatic launcher update because Staging TCP relay is active.");
                return false;
            }

            var activeClients = _stagingRelay.ActiveClientConnections;
            var relayChoice = MessageBox.Show(
                $"The Staging TCP relay is currently active ({activeClients} active connection(s)).\n\n" +
                $"Installing SoulspireXI Launcher {_availableLauncherUpdate.LatestTag} requires stopping the Staging relay and restarting the launcher.\n\n" +
                "Stop the Staging relay and install the update now? (Choose No to defer until you finish playing.)",
                "SoulspireXI Launcher — Staging Relay Active",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (relayChoice != MessageBoxResult.Yes)
            {
                LauncherUpdateStage = LauncherUpdateStage.DeferredActiveRelay;
                LauncherUpdateStatusText = $"Update {_availableLauncherUpdate.LatestTag} deferred by user while Staging relay is active";
                StatusMessage = LauncherUpdateStatusText;
                Log("Deferred launcher update so active Staging connections remain uninterrupted.");
                return false;
            }
        }

        if (!LauncherSelfUpdateService.CanSelfUpdateInPlace(out var targetExePath, out var reason) ||
            string.IsNullOrEmpty(targetExePath))
        {
            LauncherUpdateStage = LauncherUpdateStage.Failed;
            LauncherUpdateStatusText = reason;
            Log(reason);
            if (!string.IsNullOrWhiteSpace(_availableLauncherUpdate.ReleaseUrl))
            {
                var openBrowser = MessageBox.Show(
                    $"{reason}\n\nOpen the GitHub Release page to download {_availableLauncherUpdate.LatestTag}?",
                    "Manual Update Required",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information);
                if (openBrowser == MessageBoxResult.Yes)
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = _availableLauncherUpdate.ReleaseUrl,
                        UseShellExecute = true
                    });
                }
            }

            return false;
        }

        var wasBusy = IsBusy;
        if (!wasBusy)
        {
            IsBusy = true;
        }

        ProgressPercent = 0;
        try
        {
            LauncherUpdateStage = LauncherUpdateStage.Downloading;
            LauncherUpdateStatusText = $"Downloading {_availableLauncherUpdate.LatestTag}...";
            var progress = new Progress<SyncProgress>(p =>
            {
                StatusMessage = p.Message;
                LauncherUpdateStatusText = p.Message;
                ProgressPercent = p.Percent;
                if (p.Percent >= 85 && p.Percent < 100)
                {
                    LauncherUpdateStage = LauncherUpdateStage.Verifying;
                }
            });

            Log($"Downloading and verifying launcher update {_availableLauncherUpdate.LatestTag}...");
            var staged = await _selfUpdateService.DownloadAndVerifyUpdateAsync(_availableLauncherUpdate, progress);

            // Persist all player settings (channel, Staging/Production target, paths, credentials) before restart
            _settingsService.Save(_settings, PlainPassword);
            _stagingRelay.Stop();

            LauncherUpdateStage = LauncherUpdateStage.Installing;
            LauncherUpdateStatusText = $"Installing {_availableLauncherUpdate.LatestTag} via SoulspireUpdater...";
            StatusMessage = $"Installing {_availableLauncherUpdate.LatestTag} and restarting launcher...";
            Log(StatusMessage);

            var usedStandalone = _selfUpdateService.LaunchStandaloneUpdaterAndPrepareRestart(
                staged,
                targetExePath,
                LauncherSelfUpdateService.GetCurrentInformationalVersion());
            Log(usedStandalone
                ? "Launched standalone SoulspireUpdater.exe outside active install directory."
                : "Launched backup-and-swap updater fallback.");

            LauncherUpdateStage = LauncherUpdateStage.Restarting;
            LauncherUpdateStatusText = $"Restarting into {_availableLauncherUpdate.LatestTag}...";
            Application.Current?.Shutdown();
            return true;
        }
        catch (Exception ex)
        {
            LauncherUpdateStage = LauncherUpdateStage.Failed;
            LauncherUpdateStatusText = $"Update failed: {ex.Message}";
            StatusMessage = $"Launcher self-update failed: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show(
                $"Could not update SoulspireLauncher.exe (existing installation was preserved untouched):\n\n{ex.Message}",
                "SoulspireXI Launcher — Update Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return false;
        }
        finally
        {
            if (!wasBusy)
            {
                IsBusy = false;
            }
        }
    }

    private void InstallPerUserLauncher()
    {
        var currentExe = LauncherSelfUpdateService.GetCurrentExecutablePath();
        if (string.IsNullOrWhiteSpace(currentExe))
        {
            MessageBox.Show(
                "Per-user installation is available when running the packaged SoulspireLauncher.exe.",
                "SoulspireXI Launcher — Install",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        try
        {
            var currentDir = Path.GetDirectoryName(currentExe) ?? string.Empty;
            var siblingUpdater = Path.Combine(currentDir, LauncherInstallationService.CanonicalUpdaterExeName);
            var result = LauncherInstallationService.InstallPerUser(
                currentExe,
                File.Exists(siblingUpdater) ? siblingUpdater : null,
                LauncherSelfUpdateService.GetCurrentInformationalVersion(),
                _settings.UpdateChannel,
                _settingsService,
                _settings,
                PlainPassword,
                _shortcutMigrationService);

            if (!result.Success)
            {
                MessageBox.Show(result.Message, "SoulspireXI Launcher — Install Error", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            RefreshInstallState();
            StatusMessage = result.Message;
            Log(result.Message);

            var relaunch = MessageBox.Show(
                $"{result.Message}\n\nStart Menu shortcut: {(result.StartMenuShortcutCreated ? "Created" : "Skipped")}\nDesktop shortcut: {(result.DesktopShortcutCreated ? "Created" : "Skipped")}\n\nSwitch to the installed launcher now?",
                "SoulspireXI Launcher — Installed",
                MessageBoxButton.YesNo,
                MessageBoxImage.Information);
            if (relaunch == MessageBoxResult.Yes)
            {
                _settingsService.Save(_settings, PlainPassword);
                _stagingRelay.Stop();
                Process.Start(new ProcessStartInfo
                {
                    FileName = result.InstalledExePath,
                    WorkingDirectory = result.InstallRoot,
                    UseShellExecute = true
                });
                Application.Current?.Shutdown();
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Installation failed: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show($"Could not install SoulspireXI Launcher:\n{ex.Message}", "SoulspireXI Launcher — Install Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private Task RollbackLauncherAsync()
    {
        var currentExe = LauncherSelfUpdateService.GetCurrentExecutablePath();
        if (string.IsNullOrWhiteSpace(currentExe))
        {
            return Task.CompletedTask;
        }

        if (_stagingRelay.IsRunning)
        {
            var relayChoice = MessageBox.Show(
                $"The Staging TCP relay is currently active ({_stagingRelay.ActiveClientConnections} active connection(s)).\n\nStop the Staging relay and roll back the launcher now?",
                "SoulspireXI Launcher — Staging Relay Active",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (relayChoice != MessageBoxResult.Yes)
            {
                return Task.CompletedTask;
            }
        }

        var prevLabel = _installState?.PreviousVersion ?? "the previous version";
        var confirm = MessageBox.Show(
            $"Roll back SoulspireXI Launcher to {prevLabel}?\n\nYour settings, Update Channel, Server Environment, and installed game files will be preserved.",
            "SoulspireXI Launcher — Confirm Rollback",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);
        if (confirm != MessageBoxResult.Yes)
        {
            return Task.CompletedTask;
        }

        try
        {
            LauncherUpdateStage = LauncherUpdateStage.RollingBack;
            LauncherUpdateStatusText = $"Rolling back to {prevLabel}...";
            _settingsService.Save(_settings, PlainPassword);
            _stagingRelay.Stop();
            _selfUpdateService.LaunchRollbackAndPrepareRestart(currentExe);
            Application.Current?.Shutdown();
        }
        catch (Exception ex)
        {
            LauncherUpdateStage = LauncherUpdateStage.Failed;
            LauncherUpdateStatusText = $"Rollback failed: {ex.Message}";
            Log(LauncherUpdateStatusText);
            MessageBox.Show($"Could not roll back SoulspireXI Launcher:\n{ex.Message}", "SoulspireXI Launcher — Rollback Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }

        return Task.CompletedTask;
    }

    private void RefreshInstallState()
    {
        var exePath = LauncherSelfUpdateService.GetCurrentExecutablePath();
        var dir = !string.IsNullOrWhiteSpace(exePath) ? Path.GetDirectoryName(exePath) : null;
        _installState = !string.IsNullOrWhiteSpace(dir) ? LauncherInstallationService.LoadInstallState(dir) : null;
        OnPropertyChanged(nameof(CanInstallPerUser));
        OnPropertyChanged(nameof(CanRollbackLauncher));
        OnPropertyChanged(nameof(RollbackLauncherButtonText));
        OnPropertyChanged(nameof(LauncherInstallLocationText));
        RelayCommand.RaiseCanExecuteChanged();
    }

    private static string? ReadArgValue(string[] args, string flag)
    {
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i].Equals(flag, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }

        return null;
    }

    private async Task SyncUpdatesAsync(bool forceAll)
    {
        IsBusy = true;
        ProgressPercent = 0;
        try
        {
            var embedded = _manifestService.LoadEmbeddedManifest();
            var result = await _manifestService.FetchManifestDetailedAsync(
                embedded,
                _settingsService.LoadLocalServerOverride(),
                _settings.UpdateChannel);

            if (result.Manifest is null || !result.FromRemote)
            {
                if (result.Manifest is null)
                {
                    _manifestUnavailableError = result.ErrorMessage ?? $"Could not download SoulspireXI ({ChannelBadgeText}) manifest.";
                    OnPropertyChanged(nameof(ManifestVersionText));
                }

                throw new InvalidOperationException(
                    result.ErrorMessage ?? $"Could not download the latest SoulspireXI ({ChannelBadgeText}) manifest from GitHub. Please check your internet connection and try again.");
            }

            _manifestUnavailableError = null;
            ApplyManifest(result.Manifest);

            var progress = new Progress<SyncProgress>(p =>
            {
                StatusMessage = p.Message;
                ProgressPercent = p.Percent;
            });

            var count = await _manifestService.SyncSoulspireFilesAsync(
                _manifest,
                _settings,
                forceAll,
                progress,
                perf: _perfDiag,
                perfEnabled: IsPerfDiagActive,
                isCold: _isColdSyncSpan);
            _isColdSyncSpan = false;
            PendingUpdatesCount = _manifestService.GetOutdatedFiles(_manifest, _settings).Count;
            RefreshDiagnostics();

            Log(count > 0 ? $"Updated {count} SoulspireXI client file(s)." : "No file updates required.");
        }
        catch (Exception ex)
        {
            StatusMessage = $"Sync error: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show(ex.Message, "SoulspireXI Sync Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task InstallPrerequisitesAsync()
    {
        IsBusy = true;
        ProgressPercent = 0;
        try
        {
            var progress = new Progress<SyncProgress>(p =>
            {
                StatusMessage = p.Message;
                ProgressPercent = p.Percent;
            });

            var embedded = _manifestService.LoadEmbeddedManifest();
            var result = await _manifestService.FetchManifestDetailedAsync(
                embedded,
                _settingsService.LoadLocalServerOverride(),
                _settings.UpdateChannel);
            if (result.Manifest is null)
            {
                _manifestUnavailableError = result.ErrorMessage ?? $"Could not load manifest for {ChannelBadgeText}.";
                OnPropertyChanged(nameof(ManifestVersionText));
                throw new InvalidOperationException(_manifestUnavailableError);
            }

            _manifestUnavailableError = null;
            ApplyManifest(result.Manifest);

            await _manifestService.EnsureAshitaAndToolsAsync(_manifest, _settings, progress);
            if (result.FromRemote)
            {
                await _manifestService.SyncSoulspireFilesAsync(_manifest, _settings, forceAll: false, progress);
            }
            else
            {
                Log("Warning: Could not fetch remote manifest from GitHub; skipped file sync against bundled hashes.");
            }

            PendingUpdatesCount = _manifestService.GetOutdatedFiles(_manifest, _settings).Count;
            RefreshDiagnostics();
            Log("Ashita v4, xiloader, XIPivot, and SoulspireXI files are ready.");
        }
        catch (Exception ex)
        {
            StatusMessage = $"Setup error: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show(ex.Message, "SoulspireXI Setup Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task PlayAsync()
    {
        if (_settings.AutoLogin && (string.IsNullOrWhiteSpace(_settings.Username) || string.IsNullOrEmpty(PlainPassword)))
        {
            MessageBox.Show(
                "Auto-login is enabled, so please enter both a username and password (or uncheck Auto-login to use the xiloader prompt).",
                "Missing Credentials",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        IsBusy = true;
        ProgressPercent = 0;

        try
        {
            _settingsService.Save(_settings, PlainPassword);

            StatusMessage = "Checking for launcher updates...";
            var updatedLauncher = await CheckAndApplyLauncherUpdateAsync(
                autoApply: _settings.AutoUpdateLauncher,
                showUpToDateDialog: false,
                promptOnUpdateIfManual: true);
            if (updatedLauncher)
            {
                return;
            }

            var progress = new Progress<SyncProgress>(p =>
            {
                StatusMessage = p.Message;
                ProgressPercent = p.Percent;
            });

            StatusMessage = $"Checking latest SoulspireXI ({ChannelBadgeText}) manifest...";
            var embedded = _manifestService.LoadEmbeddedManifest();
            var result = await _manifestService.FetchManifestDetailedAsync(
                embedded,
                _settingsService.LoadLocalServerOverride(),
                _settings.UpdateChannel);
            if (result.Manifest is null)
            {
                _manifestUnavailableError = result.ErrorMessage ?? $"Could not load manifest for {ChannelBadgeText}.";
                OnPropertyChanged(nameof(ManifestVersionText));
                throw new InvalidOperationException(_manifestUnavailableError);
            }

            _manifestUnavailableError = null;
            ApplyManifest(result.Manifest);

            StatusMessage = "Checking Ashita v4 prerequisites...";
            await _manifestService.EnsureAshitaAndToolsAsync(_manifest, _settings, progress);

            if (result.FromRemote)
            {
                StatusMessage = $"Verifying & syncing SoulspireXI ({ChannelBadgeText}) client payload...";
                var updatedCount = await _manifestService.SyncSoulspireFilesAsync(
                    _manifest,
                    _settings,
                    forceAll: false,
                    progress,
                    perf: _perfDiag,
                    perfEnabled: IsPerfDiagActive,
                    isCold: _isColdSyncSpan);
                _isColdSyncSpan = false;
                var remainingOutdated = _manifestService.GetOutdatedFiles(_manifest, _settings, perf: _perfDiag, perfEnabled: IsPerfDiagActive, isCold: false);
                PendingUpdatesCount = remainingOutdated.Count;
                NotifyPayloadMetadataChanged();
                if (remainingOutdated.Count > 0)
                {
                    throw new InvalidOperationException(
                        $"Pre-launch client payload verification failed: {remainingOutdated.Count} file(s) still do not match " +
                        $"manifest {_manifest.ManifestVersion} after synchronization. Launch cancelled to protect client integrity.");
                }
                Log(updatedCount > 0
                    ? $"Verified and synced {updatedCount} SoulspireXI client file(s) ({_manifest.ManifestVersion}) before launch."
                    : $"Pre-launch verification passed: all SoulspireXI client files match {_manifest.ManifestVersion}.");
            }
            else
            {
                Log("Warning: Could not reach GitHub for remote manifest; launching with local client files.");
            }

            var plan = StagingRelayService.ResolveConnectionPlan(_settings, _manifest);
            if (plan.RequiresLoopbackRelay && plan.RelayConfig is not null)
            {
                StatusMessage = $"Checking Staging lobby & profile reachability ({plan.StatusProbeHost}:{plan.StatusProbeLobbyPort}, {plan.StatusProbeProfilePort}/{plan.StatusProbeProfileIrcPort})...";
                var stagingProbe = await _statusService.CheckStagingAsync(
                    plan.StatusProbeHost,
                    plan.StatusProbeLobbyPort,
                    plan.StatusProbeSearchPort,
                    plan.StatusProbeProfilePort,
                    plan.StatusProbeProfileIrcPort);
                ServerStatus = stagingProbe;

                if (!stagingProbe.LobbyReachable)
                {
                    _stagingRelay.Stop();
                    throw new InvalidOperationException(
                        $"Staging server {plan.StatusProbeHost}:{plan.StatusProbeLobbyPort} is unreachable ({stagingProbe.SummaryText}).\n\n" +
                        "Launch cancelled before starting the loopback relay or modifying soulspirexi.ini. " +
                        "Verify the Staging server is running and reachable from this PC, or switch back to Production.");
                }

                if (stagingProbe.ProfileReachable == false)
                {
                    _stagingRelay.Stop();
                    var detail = stagingProbe.ProfileFailureDetail
                        ?? $"Staging profile server unreachable on {plan.StatusProbeHost}:{plan.StatusProbeProfilePort}/{plan.StatusProbeProfileIrcPort}";
                    throw new InvalidOperationException(
                        $"{detail}.\n\n" +
                        "xiloader requires both profile TCP ports (51220->51221 and 51240->51241) to complete login without error 0x21. " +
                        "Launch cancelled before starting the loopback relay or modifying soulspirexi.ini.");
                }

                StatusMessage = $"Starting managed Staging TCP relay -> {plan.StatusProbeHost}...";
                var relayResult = _stagingRelay.Start(plan.RelayConfig);
                if (!relayResult.Success)
                {
                    throw new InvalidOperationException(relayResult.Message);
                }
            }
            else
            {
                // Always guarantee the Staging loopback relay is stopped before launching Production or Custom.
                _stagingRelay.Stop();
            }

            var effectiveEngine = ModernClientConfigGenerator.ResolveEffectiveEngine(_settings, _manifest);
            if (ModernClientConfigGenerator.IsModernEngine(effectiveEngine))
            {
                var profileDir = ModernClientConfigGenerator.ResolveProfileDirectory(ModernClientPath, effectiveEngine);
                var modernPkg = _manifest.ModernClient?.ResolvePackage(effectiveEngine);
                if (modernPkg is not null && !string.IsNullOrWhiteSpace(modernPkg.PackageUrl))
                {
                    StatusMessage = $"Ensuring verified Modern ({modernPkg.Profile}) client package ({modernPkg.Tag})...";
                    var installResult = await _modernInstallService.EnsureInstalledAsync(
                        profileDir,
                        modernPkg,
                        forceReinstall: false,
                        progress,
                        CancellationToken.None);
                    if (installResult.Downloaded)
                    {
                        Log($"Downloaded, SHA-256 verified, and installed Modern ({modernPkg.Profile}) {modernPkg.Tag} into {profileDir}.");
                    }
                    else
                    {
                        Log($"Verified existing Modern ({modernPkg.Profile}) {modernPkg.Tag} installation.");
                    }
                }
                else if (GameLaunchService.ResolveModernClientExecutable(profileDir) is null)
                {
                    throw new FileNotFoundException(
                        $"Modern (VanaCore) client binaries were not found in '{profileDir}' and the active manifest does not declare a download package.\n\n" +
                        "Check for Testing updates or switch Client Engine back to Classic — Ashita v4.",
                        Path.Combine(profileDir, "VanaCore.exe"));
                }

                if (effectiveEngine == ClientEngineMode.ModernCompat)
                {
                    StatusMessage = "Syncing dual-host Soulspire Native, addons & Pivot overlays into isolated Modern compat folder...";
                    var syncedCompat = ModernClientInstallService.SyncCompatibilityOverlayFromAshita(_settings.AshitaPath, profileDir);
                    Log($"Prepared isolated Modern Compatibility overlay ({syncedCompat} files copied; Classic Ashita untouched).");
                }
                else if (effectiveEngine == ClientEngineMode.ModernNative)
                {
                    StatusMessage = "Syncing pure VanaCore-native Soulspire Core, assets & Pivot overlays into isolated Modern native folder...";
                    var syncedNative = ModernClientInstallService.SyncNativeOverlayFromAshita(_settings.AshitaPath, profileDir);
                    Log($"Prepared isolated Modern Native overlay ({syncedNative} files copied; zero Ashita addons or legacy DLLs).");
                }

                StatusMessage = "Auto-detecting FFXI & PlayOnline paths and generating VanaCore config...";
                var diag = _detector.Inspect(_settings, _manifest);
                var ffxiDir = !string.IsNullOrWhiteSpace(_settings.FfxiPath) && Directory.Exists(_settings.FfxiPath)
                    ? _settings.FfxiPath
                    : diag.DetectedFfxiPath;
                var polDir = !string.IsNullOrWhiteSpace(diag.DetectedPolPath) && Directory.Exists(diag.DetectedPolPath)
                    ? diag.DetectedPolPath
                    : null;
                if (polDir is null && !string.IsNullOrWhiteSpace(ffxiDir))
                {
                    var parent = Directory.GetParent(ffxiDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))?.FullName;
                    var candidatePol = parent is not null ? Path.Combine(parent, "PlayOnlineViewer") : null;
                    if (!string.IsNullOrWhiteSpace(candidatePol) && Directory.Exists(candidatePol))
                    {
                        polDir = candidatePol;
                    }
                }

                var cfgSwModern = PerformanceDiagnosticsService.StartSpanIfEnabled(IsPerfDiagActive);
                var iniName = _modernConfigGenerator.WriteAllConfigs(
                    profileDir,
                    _settings,
                    effectiveEngine,
                    plan.BootServerHost,
                    polDir,
                    string.IsNullOrWhiteSpace(ffxiDir) ? null : ffxiDir);
                if (!string.IsNullOrWhiteSpace(_modernConfigGenerator.LastGamepadImportDiagnostic))
                {
                    Log(_modernConfigGenerator.LastGamepadImportDiagnostic);
                }
                _perfDiag.RecordSpan(IsPerfDiagActive, "config_write", cfgSwModern, true, "complete", "client_only");

                var engineLabel = effectiveEngine switch
                {
                    ClientEngineMode.ModernBaseline => "Modern — VanaCore Baseline",
                    ClientEngineMode.ModernNative => "Modern — Soulspire Native",
                    _ => "Modern — Soulspire Compatibility"
                };
                StatusMessage = $"Launching {engineLabel} -> {plan.DisplayHost} (secure --password-stdin)...";
                Log(StatusMessage);
                var launchSwModern = PerformanceDiagnosticsService.StartSpanIfEnabled(IsPerfDiagActive);
                var launchedModern = _launchService.LaunchModernClient(
                    profileDir,
                    plan.BootServerHost,
                    _settings.Username,
                    PlainPassword,
                    iniName,
                    _settings.Language);
                _perfDiag.RecordSpan(IsPerfDiagActive, "launch_handoff", launchSwModern, true, "complete", "client_only");
                _perfDiag.StartProcessMonitoring(launchedModern, IsPerfDiagActive, () => ExportPerfBundleFromBackground());
                OnPropertyChanged(nameof(ClientEngineStatusText));
                OnPropertyChanged(nameof(ModernDiagnosticsStatusText));

                if (_settings.AutoCloseOnLaunch && !plan.RequiresLoopbackRelay)
                {
                    Application.Current.Shutdown();
                }
                return;
            }

            var xiloaderPath = FfxiInstallDetector.ResolveXiloaderPath(_settings.AshitaPath);
            if (string.IsNullOrEmpty(xiloaderPath))
            {
                throw new FileNotFoundException("xiloader.exe could not be located or downloaded.");
            }

            StatusMessage = "Writing Ashita v4 & Pivot configurations...";
            if (_configGenerator.CapturePlayerInputPreferencesIfUnmanaged(_settings.AshitaPath, _settings))
            {
                _settingsService.Save(_settings, PlainPassword);
            }

            var effectiveInput = TestingEnvironmentQolPolicy.ResolveInputSettings(
                _settings,
                plan.BootServerHost,
                _manifest.Channel,
                _manifest.ServerName);

            var cfgSw = PerformanceDiagnosticsService.StartSpanIfEnabled(IsPerfDiagActive);
            _configGenerator.WriteAllConfigs(
                _settings.AshitaPath,
                _settings,
                plan.BootServerHost,
                plan.BootUseHairpin,
                PlainPassword,
                xiloaderPath,
                manifestChannel: _manifest.Channel,
                serverName: _manifest.ServerName);
            SyncCorePerfConfigSafe();
            _perfDiag.RecordSpan(IsPerfDiagActive, "config_write", cfgSw, true, "complete", "client_only");

            if (effectiveInput.TestingQolApplied)
            {
                Log($"Applied Automatic Testing QoL settings ({effectiveInput.Reason}): Allow Binds During Input + Allow Windows Key enabled.");
            }

            RefreshDiagnostics();

            StatusMessage = plan.RequiresLoopbackRelay
                ? $"Launching Ashita v4 -> STAGING {plan.DisplayHost} (via local loopback relay)..."
                : $"Launching Ashita v4 -> {plan.DisplayHost}...";
            Log(StatusMessage);
            var launchSw = PerformanceDiagnosticsService.StartSpanIfEnabled(IsPerfDiagActive);
            var launchedProc = _launchService.LaunchAshita(_settings.AshitaPath);
            _perfDiag.RecordSpan(IsPerfDiagActive, "launch_handoff", launchSw, true, "complete", "client_only");
            _perfDiag.StartProcessMonitoring(launchedProc, IsPerfDiagActive, () => ExportPerfBundleFromBackground());

            if (_settings.AutoCloseOnLaunch)
            {
                if (plan.RequiresLoopbackRelay)
                {
                    StatusMessage = "Staging TCP relay active — launcher minimized (keep open while playing Staging).";
                    Log(StatusMessage);
                    RequestMinimizeWindow?.Invoke();
                }
                else
                {
                    Application.Current.Shutdown();
                }
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Launch failed: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show(ex.Message, "SoulspireXI Launcher — Launch Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task RefreshServerStatusAsync()
    {
        var plan = CurrentConnectionPlan;
        ServerStatus = new ServerStatus
        {
            Host = plan.StatusProbeHost,
            IsOnline = false,
            SummaryText = $"Checking {plan.DisplayHost}..."
        };

        var result = plan.RequiresLoopbackRelay
            ? await _statusService.CheckStagingAsync(
                plan.StatusProbeHost,
                plan.StatusProbeLobbyPort,
                plan.StatusProbeSearchPort,
                plan.StatusProbeProfilePort,
                plan.StatusProbeProfileIrcPort)
            : await _statusService.CheckAsync(
                plan.StatusProbeHost,
                plan.StatusProbeLobbyPort,
                plan.StatusProbeSearchPort);
        ServerStatus = result;
    }

    private void RefreshDiagnostics()
    {
        Diagnostics = _detector.Inspect(_settings, _manifest);
        PendingUpdatesCount = _manifestService.GetOutdatedFiles(_manifest, _settings).Count;
    }

    private void SaveCurrentSettings()
    {
        _settingsService.Save(_settings, PlainPassword);
        StatusMessage = "Settings saved.";
        Log($"Settings saved to {_settingsService.SettingsPath}");
        _ = RefreshServerStatusAsync();
    }

    private void BrowseFfxiFolder()
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Select FINAL FANTASY XI Installation Folder",
            InitialDirectory = Directory.Exists(FfxiPath) ? FfxiPath : @"C:\"
        };
        if (dialog.ShowDialog() == true)
        {
            FfxiPath = dialog.FolderName;
            RefreshDiagnostics();
        }
    }

    private void BrowseAshitaFolder()
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Select Ashita v4 Folder",
            InitialDirectory = Directory.Exists(AshitaPath) ? AshitaPath : _settingsService.LauncherBaseDirectory
        };
        if (dialog.ShowDialog() == true)
        {
            AshitaPath = dialog.FolderName;
            RefreshDiagnostics();
        }
    }

    private void ResetAshitaToLauncherFolder()
    {
        _settings.UseCustomAshitaPath = false;
        var defaultDir = _settingsService.EnsureDefaultAshitaDirectory();
        AshitaPath = defaultDir;
        _settingsService.Save(_settings, PlainPassword);
        RefreshDiagnostics();
        StatusMessage = $"Ashita folder set to {defaultDir}";
        Log(StatusMessage);
    }

    private void BrowseCustomDatFolder()
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Select Custom DAT Overlay Folder",
            InitialDirectory = Directory.Exists(CustomDatOverlayPath) ? CustomDatOverlayPath : @"C:\"
        };
        if (dialog.ShowDialog() == true)
        {
            CustomDatOverlayPath = dialog.FolderName;
        }
    }

    private void OpenAshitaFolder()
    {
        Directory.CreateDirectory(AshitaPath);
        Process.Start(new ProcessStartInfo
        {
            FileName = AshitaPath,
            UseShellExecute = true
        });
    }

    private void ExportShareableServerJson()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "soulspire-server.json");
        var payload = new LocalServerOverride
        {
            ServerName = _manifest.ServerName,
            DefaultHost = EffectiveHost,
            UseHairpin = EffectiveUseHairpin,
            LobbyPort = EffectiveLobbyPort,
            SearchPort = EffectiveSearchPort
        };

        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
        StatusMessage = $"Exported {path}";
        Log($"Exported shareable server config: {path}");
        MessageBox.Show(
            $"Saved server config to:\n{path}\n\nDistribute SoulspireLauncher.exe alongside this file so players automatically connect to {EffectiveHost}.",
            "Shareable Config Exported",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    private void ApplyResolutionPreset(object? parameter)
    {
        var preset = parameter?.ToString();
        switch (preset)
        {
            case "1080p":
                WindowWidth = 1920;
                WindowHeight = 1080;
                MenuWidth = 1920;
                MenuHeight = 1080;
                BackgroundWidth = 2048;
                BackgroundHeight = 2048;
                break;
            case "1440p":
                WindowWidth = 2560;
                WindowHeight = 1440;
                MenuWidth = 1920;
                MenuHeight = 1080;
                BackgroundWidth = 4096;
                BackgroundHeight = 4096;
                break;
            case "4k":
                WindowWidth = 3840;
                WindowHeight = 2160;
                MenuWidth = 1920;
                MenuHeight = 1080;
                BackgroundWidth = 4096;
                BackgroundHeight = 4096;
                break;
            case "720p":
                WindowWidth = 1280;
                WindowHeight = 720;
                MenuWidth = 1280;
                MenuHeight = 720;
                BackgroundWidth = 2048;
                BackgroundHeight = 2048;
                break;
        }
    }

    private void ImportSystemSettings()
    {
        var result = _importService.ImportBestAvailable(_settings, gamepadOnly: false);
        NotifyAllSettingsChanged();

        if (result.ImportedAny)
        {
            _settingsService.Save(_settings, PlainPassword);
            StatusMessage = result.SourceSummary;
            Log(result.SourceSummary);
            RefreshDiagnostics();
            MessageBox.Show(
                $"{result.SourceSummary}\n\nGamepad: {GamepadSummaryText}\nResolution: {WindowWidth}x{WindowHeight} ({SelectedWindowMode})",
                "Settings Imported",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        else
        {
            StatusMessage = result.SourceSummary;
            Log(result.SourceSummary);
            MessageBox.Show(
                "Could not find existing settings in Windows FFXI Registry or standard Ashita config folders.\n\nUse \"Import Ashita .ini...\" to select your existing Ashita boot .ini file manually, or click \"Open FFXI Config\" to configure your gamepad.",
                "No Existing Settings Found",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
    }

    private void ImportFromAshitaIniDialog()
    {
        var dialog = new OpenFileDialog
        {
            Title = "Select Existing Ashita v4 Boot Configuration (.ini)",
            Filter = "Ashita INI Files (*.ini)|*.ini|All Files (*.*)|*.*",
            InitialDirectory = Directory.Exists(Path.Combine(AshitaPath, "config", "boot"))
                ? Path.Combine(AshitaPath, "config", "boot")
                : AppContext.BaseDirectory
        };

        if (dialog.ShowDialog() == true)
        {
            if (_importService.TryImportFromAshitaIni(dialog.FileName, _settings, gamepadOnly: false))
            {
                NotifyAllSettingsChanged();
                _settingsService.Save(_settings, PlainPassword);
                StatusMessage = $"Imported settings from {Path.GetFileName(dialog.FileName)}";
                Log($"Imported settings from {dialog.FileName}");
                RefreshDiagnostics();
            }
            else
            {
                MessageBox.Show(
                    "No FFXI registry or Ashita input settings were found inside the selected .ini file.",
                    "Import Unchanged",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
    }

    private void LaunchFfxiConfigTool()
    {
        var exe = SettingsImportService.FindFfxiConfigExecutable(_settings);
        if (string.IsNullOrEmpty(exe))
        {
            MessageBox.Show(
                "Could not locate FINAL FANTASY XI Config.exe or FFXiPadConfig.exe inside your FFXI folder.",
                "FFXI Config Tool Not Found",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = Path.GetDirectoryName(exe) ?? string.Empty,
            UseShellExecute = true
        });
        Log($"Opened {Path.GetFileName(exe)} — click 'Auto-Import Current Settings' after saving changes.");
    }

    private void CreateDesktopShortcut()
    {
        var currentExe = LauncherSelfUpdateService.GetCurrentExecutablePath();
        if (string.IsNullOrWhiteSpace(currentExe))
        {
            MessageBox.Show(
                "Desktop shortcut creation is available when running the packaged SoulspireLauncher.exe.",
                "SoulspireXI Launcher — Shortcut",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        try
        {
            var canonicalExe = LauncherSelfUpdateService.ResolveCanonicalTargetExePath(currentExe);
            if (_shortcutMigrationService.CreateDesktopShortcut(canonicalExe))
            {
                StatusMessage = "Created Desktop shortcut: SoulspireXI Launcher.";
                Log(StatusMessage);
                MessageBox.Show(
                    "Created 'SoulspireXI Launcher' shortcut on your Desktop.",
                    "SoulspireXI Launcher — Shortcut Created",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show(
                    "Could not create the Desktop shortcut. Please check folder permissions.",
                    "SoulspireXI Launcher — Shortcut",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"Could not create Desktop shortcut:\n{ex.Message}",
                "SoulspireXI Launcher — Shortcut Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void NotifyAllSettingsChanged()
    {
        OnPropertyChanged(nameof(FfxiPath));
        OnPropertyChanged(nameof(SelectedWindowMode));
        OnPropertyChanged(nameof(WindowWidth));
        OnPropertyChanged(nameof(WindowHeight));
        OnPropertyChanged(nameof(BackgroundWidth));
        OnPropertyChanged(nameof(BackgroundHeight));
        OnPropertyChanged(nameof(MenuWidth));
        OnPropertyChanged(nameof(MenuHeight));
        OnPropertyChanged(nameof(MipMapping));
        OnPropertyChanged(nameof(BumpMapping));
        OnPropertyChanged(nameof(UncompressedTextures));
        OnPropertyChanged(nameof(UncompressedMaps));
        OnPropertyChanged(nameof(HighQualityFonts));
        OnPropertyChanged(nameof(HardwareMouse));
        OnPropertyChanged(nameof(ShowOpeningMovie));
        OnPropertyChanged(nameof(SoundEnabled));
        OnPropertyChanged(nameof(BackgroundSound));
        OnPropertyChanged(nameof(SelectedLanguage));
        OnPropertyChanged(nameof(GamepadAllowBackground));
        OnPropertyChanged(nameof(GamepadDisableEnumeration));
        OnPropertyChanged(nameof(EnableGamepad));
        OnPropertyChanged(nameof(EnableXInput));
        OnPropertyChanged(nameof(GamepadSummaryText));
        OnPropertyChanged(nameof(ImportedSettingsSourceText));
        OnPropertyChanged(nameof(EnableAutomaticTestingQolSettings));
        OnPropertyChanged(nameof(TestingQolStatusText));
        OnPropertyChanged(nameof(CanEnablePerformanceDiagnostics));
        OnPropertyChanged(nameof(EnablePerformanceDiagnostics));
        OnPropertyChanged(nameof(PerfDiagStatusText));
        SyncCorePerfConfigSafe();
    }

    private void StopStagingRelay()
    {
        _stagingRelay.Stop();
        StatusMessage = "Staging TCP relay stopped.";
    }

    private void ResetStagingDefaults()
    {
        var manifestStaging = _manifest.StagingServer;
        _settings.StagingServerHost = !string.IsNullOrWhiteSpace(manifestStaging?.Host)
            ? manifestStaging.Host.Trim()
            : LauncherSettings.DefaultStagingHost;
        _settings.ApplyStagingLanePreset(_settings.StagingLane);

        _stagingRelay.Stop();
        _settingsService.Save(_settings, PlainPassword);

        OnPropertyChanged(nameof(SelectedStagingLane));
        OnPropertyChanged(nameof(StagingServerHost));
        OnPropertyChanged(nameof(StagingAuthPort));
        OnPropertyChanged(nameof(StagingDataPort));
        OnPropertyChanged(nameof(StagingViewPort));
        OnPropertyChanged(nameof(StagingSearchPort));
        OnPropertyChanged(nameof(StagingProfilePort));
        OnPropertyChanged(nameof(StagingProfileIrcPort));
        NotifyEffectiveServerChanged();
        var preset = LauncherSettings.GetStagingLanePreset(_settings.StagingLane);
        StatusMessage = $"Restored {preset.DisplayName} defaults ({_settings.StagingServerHost}:{_settings.StagingAuthPort}).";
        Log(StatusMessage);
        _ = RefreshServerStatusAsync();
    }

    public void Shutdown()
    {
        if (IsPerfDiagActive)
        {
            TryExportPerfBundle(silent: true);
        }

        _perfDiag.StopProcessMonitoring();
        _stagingRelay.Stop();
    }

    public void Dispose()
    {
        _perfDiag.Dispose();
        _stagingRelay.DiagnosticMessage -= Log;
        _stagingRelay.StateChanged -= OnStagingRelayStateChanged;
        _stagingRelay.Dispose();
    }

    private bool IsPerfDiagActive =>
        TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(_settings, _manifest.Channel);

    private void SyncCorePerfConfigSafe()
    {
        try
        {
            PerformanceDiagnosticsService.WriteCoreConfig(_settings, _manifest.Channel);
        }
        catch (Exception ex)
        {
            Log($"Warning: could not update Core perf config: {ex.Message}");
        }
    }

    private void ExportPerformanceBundleNow() => TryExportPerfBundle(silent: false);

    private void ExportPerfBundleFromBackground()
    {
        void Run()
        {
            if (IsPerfDiagActive)
            {
                TryExportPerfBundle(silent: true);
            }
        }

        if (Application.Current?.Dispatcher is { } dispatcher && !dispatcher.CheckAccess())
        {
            dispatcher.Invoke(Run);
        }
        else
        {
            Run();
        }
    }

    private void TryExportPerfBundle(bool silent)
    {
        try
        {
            var res = _perfDiag.ExportBundle(_settings, _manifest, LauncherVersionText);
            if (res.Success)
            {
                _lastPerfExportPath = res.JsonPath;
                OnPropertyChanged(nameof(PerfDiagStatusText));
                StatusMessage = res.Message;
                Log(res.Message);
            }
            else if (!silent)
            {
                MessageBox.Show(res.Message, "SoulspireXI Performance Diagnostics", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
        catch (Exception ex)
        {
            Log($"Performance diagnostic export error: {ex.Message}");
            if (!silent)
            {
                MessageBox.Show(ex.Message, "SoulspireXI Performance Diagnostics — Export Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }

    private void OpenDiagnosticsFolder()
    {
        try
        {
            Directory.CreateDirectory(_perfDiag.DiagnosticsDirectory);
            Process.Start(new ProcessStartInfo
            {
                FileName = _perfDiag.DiagnosticsDirectory,
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "SoulspireXI Launcher", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnStagingRelayStateChanged()
    {
        void Raise()
        {
            OnPropertyChanged(nameof(IsStagingRelayActive));
            OnPropertyChanged(nameof(StagingRelayStatusText));
            RelayCommand.RaiseCanExecuteChanged();
        }

        if (Application.Current?.Dispatcher is { } dispatcher && !dispatcher.CheckAccess())
        {
            dispatcher.Invoke(Raise);
        }
        else
        {
            Raise();
        }
    }

    private async Task InstallSelectedModernClientAsync(bool forceReinstall)
    {
        var effectiveEngine = ModernClientConfigGenerator.ResolveEffectiveEngine(_settings, _manifest);
        if (!ModernClientConfigGenerator.IsModernEngine(effectiveEngine))
        {
            StatusMessage = "Select Modern — VanaCore Baseline or Modern — Soulspire Compatibility first.";
            return;
        }

        var pkg = _manifest.ModernClient?.ResolvePackage(effectiveEngine);
        if (pkg is null || string.IsNullOrWhiteSpace(pkg.PackageUrl))
        {
            MessageBox.Show(
                "No downloadable Modern client package is declared in the current manifest.\nClick 'Check / Sync Updates' on the Testing channel first.",
                "Modern Client Package Unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        IsBusy = true;
        ProgressPercent = 0;
        try
        {
            var profileDir = ModernClientConfigGenerator.ResolveProfileDirectory(ModernClientPath, effectiveEngine);
            var progress = new Progress<SyncProgress>(p =>
            {
                StatusMessage = p.Message;
                ProgressPercent = p.Percent;
            });

            var result = await _modernInstallService.EnsureInstalledAsync(
                profileDir,
                pkg,
                forceReinstall,
                progress,
                CancellationToken.None);

            if (effectiveEngine == ClientEngineMode.ModernCompat)
            {
                ModernClientInstallService.SyncCompatibilityOverlayFromAshita(_settings.AshitaPath, profileDir);
            }
            else if (effectiveEngine == ClientEngineMode.ModernNative)
            {
                ModernClientInstallService.SyncNativeOverlayFromAshita(_settings.AshitaPath, profileDir);
            }

            StatusMessage = result.Downloaded
                ? $"Installed and SHA-256 verified Modern ({pkg.Profile}) {pkg.Tag}."
                : $"Modern ({pkg.Profile}) {pkg.Tag} is already installed and up to date.";
            Log(StatusMessage);
            OnPropertyChanged(nameof(ClientEngineStatusText));
            OnPropertyChanged(nameof(ModernDiagnosticsStatusText));
        }
        catch (Exception ex)
        {
            StatusMessage = $"Modern client install failed: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show(ex.Message, "Modern Client Install Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            IsBusy = false;
            ProgressPercent = 0;
        }
    }

    private void ExportModernDiagnosticsNow()
    {
        try
        {
            var mode = ModernClientConfigGenerator.IsModernEngine(SelectedClientEngine)
                ? SelectedClientEngine
                : ClientEngineMode.ModernBaseline;
            var profileDir = ModernClientConfigGenerator.ResolveProfileDirectory(ModernClientPath, mode);
            var result = _modernDiagnosticsService.ExportBundle(
                profileDir,
                mode,
                _settings,
                LauncherVersionText,
                PlainPassword);

            StatusMessage = result.SummaryText;
            Log($"{result.SummaryText} -> {result.ZipPath}");
            OnPropertyChanged(nameof(ModernDiagnosticsStatusText));

            MessageBox.Show(
                $"{result.SummaryText}\n\nSaved to:\n{result.ZipPath}\n\nPasswords and authentication secrets have been redacted.",
                "Modern Client Diagnostics Exported",
                MessageBoxButton.OK,
                MessageBoxImage.Information);

            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"/select,\"{result.ZipPath}\"",
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            StatusMessage = $"Could not export Modern diagnostics: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show(ex.Message, "Modern Diagnostics Export Failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OpenModernLogsFolder()
    {
        var mode = ModernClientConfigGenerator.IsModernEngine(SelectedClientEngine)
            ? SelectedClientEngine
            : ClientEngineMode.ModernBaseline;
        var profileDir = ModernClientConfigGenerator.ResolveProfileDirectory(ModernClientPath, mode);
        var logsDir = Path.Combine(profileDir, "logs");
        Directory.CreateDirectory(logsDir);
        Process.Start(new ProcessStartInfo
        {
            FileName = logsDir,
            UseShellExecute = true
        });
    }

    private void NotifyEffectiveServerChanged()
    {
        OnPropertyChanged(nameof(IsProductionMode));
        OnPropertyChanged(nameof(IsStagingMode));
        OnPropertyChanged(nameof(IsCustomServerMode));
        OnPropertyChanged(nameof(EffectiveHost));
        OnPropertyChanged(nameof(EffectiveUseHairpin));
        OnPropertyChanged(nameof(EffectiveLobbyPort));
        OnPropertyChanged(nameof(EffectiveSearchPort));
        OnPropertyChanged(nameof(ServerStatusDisplayHost));
        OnPropertyChanged(nameof(StagingHeaderBadgeText));
        OnPropertyChanged(nameof(StagingCardHeaderText));
        OnPropertyChanged(nameof(StagingTargetSummaryText));
        OnPropertyChanged(nameof(StagingRelayStatusText));
        OnPropertyChanged(nameof(PlayButtonText));
        OnPropertyChanged(nameof(TestingQolStatusText));
    }

    private void Log(string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {message}";
        if (Application.Current?.Dispatcher is { } dispatcher && !dispatcher.CheckAccess())
        {
            dispatcher.Invoke(() => ActivityLog.Insert(0, line));
        }
        else
        {
            ActivityLog.Insert(0, line);
        }
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

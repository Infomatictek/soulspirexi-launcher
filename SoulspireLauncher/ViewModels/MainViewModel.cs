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
    private readonly ServerStatusService _statusService;
    private readonly GameLaunchService _launchService;
    private readonly ShortcutMigrationService _shortcutMigrationService;
    private readonly StagingRelayService _stagingRelay;

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

    public MainViewModel()
    {
        _settingsService = new SettingsService();
        _importService = new SettingsImportService();
        _manifestService = new ManifestUpdateService();
        _selfUpdateService = new LauncherSelfUpdateService();
        _detector = new FfxiInstallDetector();
        _configGenerator = new AshitaConfigGenerator();
        _statusService = new ServerStatusService();
        _launchService = new GameLaunchService();
        _shortcutMigrationService = new ShortcutMigrationService();
        _stagingRelay = new StagingRelayService();
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

    public IReadOnlyList<ServerTargetMode> ServerTargetOptions { get; } =
    [
        ServerTargetMode.Production,
        ServerTargetMode.Staging,
        ServerTargetMode.Custom
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

    public bool IsProductionMode => _settings.ServerTarget == ServerTargetMode.Production;
    public bool IsStagingMode => _settings.ServerTarget == ServerTargetMode.Staging;
    public bool IsCustomServerMode => _settings.ServerTarget == ServerTargetMode.Custom;
    public bool IsStagingRelayActive => _stagingRelay.IsRunning;

    public string EffectiveHost => CurrentConnectionPlan.StatusProbeHost;
    public bool EffectiveUseHairpin => CurrentConnectionPlan.BootUseHairpin;
    public int EffectiveLobbyPort => CurrentConnectionPlan.StatusProbeLobbyPort;
    public int EffectiveSearchPort => CurrentConnectionPlan.StatusProbeSearchPort;

    public string ServerStatusDisplayHost => IsStagingMode
        ? $"STAGING • {CurrentConnectionPlan.DisplayHost}"
        : CurrentConnectionPlan.DisplayHost;

    public string StagingTargetSummaryText
    {
        get
        {
            var plan = CurrentConnectionPlan;
            return $"Target: {plan.StatusProbeHost} (Lobby/Search {StagingAuthPort}/{StagingDataPort}/{StagingViewPort}/{StagingSearchPort} • Profile {StagingProfilePort}/{StagingProfileIrcPort} • Map UDP {plan.MapUdpPort})";
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

    public string PlayButtonText => IsBusy
        ? "PREPARING..."
        : IsStagingMode
            ? (PendingUpdatesCount > 0 ? $"UPDATE & PLAY STAGING ({PendingUpdatesCount})" : "PLAY STAGING SERVER")
            : (PendingUpdatesCount > 0 ? $"UPDATE & PLAY ({PendingUpdatesCount})" : "PLAY SOULSPIREXI");

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
            }
        }
    }

    public string UpdateBadgeText => PendingUpdatesCount == 0
        ? "Client files up to date"
        : $"{PendingUpdatesCount} file update(s) ready";

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

    public string LauncherVersionText => $"v{LauncherSelfUpdateService.GetCurrentVersion()}";

    public IReadOnlyList<UpdateChannel> UpdateChannelOptions { get; } =
    [
        UpdateChannel.Stable,
        UpdateChannel.TestingCoreUi,
        UpdateChannel.Testing,
        UpdateChannel.TestingSearchLegacyText,
        UpdateChannel.TestingRegistry24Hook,
        UpdateChannel.TestingSearchAlignedText
    ];

    public UpdateChannel SelectedUpdateChannel
    {
        get => _settings.UpdateChannel;
        set
        {
            if (_settings.UpdateChannel != value)
            {
                _settings.UpdateChannel = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsTestingChannel));
                OnPropertyChanged(nameof(ChannelBadgeText));
                OnPropertyChanged(nameof(ChannelDescriptionText));
                _settingsService.Save(_settings, PlainPassword);
                Log($"Switched update channel to {value}. Checking manifest...");
                _ = CheckUpdatesOnlyAsync();
            }
        }
    }

    public bool IsTestingChannel => _settings.UpdateChannel is UpdateChannel.Testing
        or UpdateChannel.TestingRegistry24Hook
        or UpdateChannel.TestingSearchLegacyText
        or UpdateChannel.TestingSearchAlignedText
        or UpdateChannel.TestingCoreUi;

    public string ChannelBadgeText => _settings.UpdateChannel switch
    {
        UpdateChannel.Testing => "TESTING CHANNEL",
        UpdateChannel.TestingCoreUi => "TESTING — CORE UI",
        UpdateChannel.TestingRegistry24Hook => "TESTING B (MENU2FON)",
        UpdateChannel.TestingSearchLegacyText => "TESTING A (LEGACY TEXT)",
        UpdateChannel.TestingSearchAlignedText => "TESTING C (ALIGNED TEXT)",
        _ => "STABLE"
    };

    public string ChannelDescriptionText => _settings.UpdateChannel switch
    {
        UpdateChannel.Testing => "Testing channel delivers verified 27-hook weapon-template preview DLLs, addons, and DAT overlays without affecting Stable players.",
        UpdateChannel.TestingCoreUi => "Isolated SoulspireXI Core unified UI, Main Menu dock, Soulforge, and gamepad navigation preview (24-hook). Preserves your settings; switch back to Stable anytime.",
        UpdateChannel.TestingRegistry24Hook => "Candidate B (Control): Current 24-hook menu2fon sprite Search renderer (2.1.4-testing.registry24). Switch back to Stable anytime.",
        UpdateChannel.TestingSearchLegacyText => "Candidate A (Historical 4f0fdb3): 24-hook 66-Soul registry with legacy single-call 0.75x native_text Search labels (zero sprite mutation).",
        UpdateChannel.TestingSearchAlignedText => "Candidate C (Repair): 24-hook 66-Soul registry with fixed-column aligned native_text Search labels (readable first, zero sprite mutation).",
        _ => "Stable channel delivers production-verified SoulspireXI client builds."
    };

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
        var justUpdated = Environment.GetCommandLineArgs()
            .Any(arg => arg.Equals(LauncherSelfUpdateService.JustUpdatedArg, StringComparison.OrdinalIgnoreCase));
        LauncherSelfUpdateService.CleanupStagingDirectory();

        // Only remove obsolete OverlordsLauncher.exe once SoulspireLauncher.exe itself is verified running.
        var currentExePath = LauncherSelfUpdateService.GetCurrentExecutablePath();
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

        Log($"Launcher {LauncherVersionText} initialized. Ashita path: {AshitaPath}");
        if (justUpdated)
        {
            StatusMessage = $"Launcher updated to {LauncherVersionText}.";
            Log(StatusMessage);
        }

        await RefreshServerStatusAsync();

        if (_settings.AutoCheckUpdatesOnStartup)
        {
            await CheckUpdatesOnlyAsync();
        }

        if (!justUpdated && (_settings.AutoUpdateLauncher || _settings.AutoCheckUpdatesOnStartup))
        {
            await CheckAndApplyLauncherUpdateAsync(autoApply: _settings.AutoUpdateLauncher, showUpToDateDialog: false);
        }
    }

    private async Task CheckUpdatesOnlyAsync()
    {
        try
        {
            StatusMessage = $"Checking SoulspireXI {ChannelBadgeText} manifest...";
            var embedded = _manifestService.LoadEmbeddedManifest();
            var result = await _manifestService.FetchManifestDetailedAsync(
                embedded,
                _settingsService.LoadLocalServerOverride(),
                _settings.UpdateChannel);

            if (result.Manifest is null)
            {
                _manifestUnavailableError = result.ErrorMessage ?? $"Could not load remote manifest for {_settings.UpdateChannel}.";
                PendingUpdatesCount = 0;
                OnPropertyChanged(nameof(ManifestVersionText));
                StatusMessage = _manifestUnavailableError;
                Log(StatusMessage);
                return;
            }

            _manifestUnavailableError = null;
            _manifest = result.Manifest;
            ApplyManifest(result.Manifest);

            var pending = _manifestService.GetOutdatedFiles(_manifest, _settings);
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
        OnPropertyChanged(nameof(ManifestVersionText));
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
            var result = await _selfUpdateService.CheckForUpdateAsync(_manifest, _settings.UpdateChannel);
            _availableLauncherUpdate = result;
            OnPropertyChanged(nameof(IsLauncherUpdateAvailable));
            OnPropertyChanged(nameof(LauncherUpdateButtonText));
            RelayCommand.RaiseCanExecuteChanged();

            if (!result.UpdateAvailable)
            {
                if (showUpToDateDialog)
                {
                    MessageBox.Show(
                        $"SoulspireXI Launcher {LauncherVersionText} ({_settings.UpdateChannel}) is already up to date.",
                        "SoulspireXI Launcher — Up to Date",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }

                return false;
            }

            Log($"Launcher update available ({_settings.UpdateChannel}): {result.LatestTag} (current {LauncherVersionText})");

            if (autoApply)
            {
                if (LauncherSelfUpdateService.CanSelfUpdateInPlace(out _, out var reason))
                {
                    return await ApplyAvailableLauncherUpdateAsync();
                }

                Log($"Automatic launcher update skipped: {reason}");
                StatusMessage = $"Launcher {result.LatestTag} available (click Update Launcher).";
                return false;
            }

            StatusMessage = $"Launcher {result.LatestTag} is available!";
            if (showUpToDateDialog || promptOnUpdateIfManual)
            {
                var prompt = promptOnUpdateIfManual
                    ? $"A new SoulspireXI Launcher release ({result.LatestTag}) is available.\nCurrent version: {LauncherVersionText}\n\nDownload and restart before playing?"
                    : $"A new SoulspireXI Launcher release ({result.LatestTag}) is available.\nCurrent version: {LauncherVersionText}\n\nDownload and restart now?";
                var choice = MessageBox.Show(
                    prompt,
                    "SoulspireXI Launcher — Update Available",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information);
                if (choice == MessageBoxResult.Yes)
                {
                    return await ApplyAvailableLauncherUpdateAsync();
                }
            }
        }
        catch (Exception ex)
        {
            Log($"Launcher update check skipped: {ex.Message}");
            if (showUpToDateDialog)
            {
                MessageBox.Show(
                    $"Could not check GitHub Releases for SoulspireXI Launcher updates:\n{ex.Message}",
                    "SoulspireXI Launcher — Update Check Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        return false;
    }

    private async Task<bool> ApplyAvailableLauncherUpdateAsync()
    {
        if (_availableLauncherUpdate is null || !_availableLauncherUpdate.UpdateAvailable)
        {
            return false;
        }

        if (!LauncherSelfUpdateService.CanSelfUpdateInPlace(out var targetExePath, out var reason) ||
            string.IsNullOrEmpty(targetExePath))
        {
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
            var progress = new Progress<SyncProgress>(p =>
            {
                StatusMessage = p.Message;
                ProgressPercent = p.Percent;
            });

            Log($"Downloading launcher update {_availableLauncherUpdate.LatestTag}...");
            var stagedExe = await _selfUpdateService.DownloadUpdateAsync(_availableLauncherUpdate, progress);
            StatusMessage = $"Installing {_availableLauncherUpdate.LatestTag} and restarting...";
            Log(StatusMessage);

            _selfUpdateService.LaunchUpdaterAndPrepareRestart(stagedExe, targetExePath);
            Application.Current?.Shutdown();
            return true;
        }
        catch (Exception ex)
        {
            StatusMessage = $"Launcher self-update failed: {ex.Message}";
            Log(StatusMessage);
            MessageBox.Show(
                $"Could not update SoulspireLauncher.exe:\n{ex.Message}",
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

            var count = await _manifestService.SyncSoulspireFilesAsync(_manifest, _settings, forceAll, progress);
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
                StatusMessage = $"Checking for SoulspireXI ({ChannelBadgeText}) file updates...";
                var updatedCount = await _manifestService.SyncSoulspireFilesAsync(_manifest, _settings, forceAll: false, progress);
                PendingUpdatesCount = _manifestService.GetOutdatedFiles(_manifest, _settings).Count;
                Log(updatedCount > 0
                    ? $"Updated {updatedCount} SoulspireXI client file(s) before launch."
                    : "All SoulspireXI client files are up to date.");
            }
            else
            {
                Log("Warning: Could not reach GitHub for remote manifest; launching with local client files.");
            }

            var xiloaderPath = FfxiInstallDetector.ResolveXiloaderPath(_settings.AshitaPath);
            if (string.IsNullOrEmpty(xiloaderPath))
            {
                throw new FileNotFoundException("xiloader.exe could not be located or downloaded.");
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

            StatusMessage = "Writing Ashita v4 & Pivot configurations...";
            _configGenerator.WriteAllConfigs(
                _settings.AshitaPath,
                _settings,
                plan.BootServerHost,
                plan.BootUseHairpin,
                PlainPassword,
                xiloaderPath);

            RefreshDiagnostics();

            StatusMessage = plan.RequiresLoopbackRelay
                ? $"Launching Ashita v4 -> STAGING {plan.DisplayHost} (via local loopback relay)..."
                : $"Launching Ashita v4 -> {plan.DisplayHost}...";
            Log(StatusMessage);
            _launchService.LaunchAshita(_settings.AshitaPath);

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
        _settings.StagingAuthPort = manifestStaging?.Ports.Auth is > 0 and <= 65535
            ? manifestStaging.Ports.Auth
            : LauncherSettings.DefaultStagingAuthPort;
        _settings.StagingDataPort = manifestStaging?.Ports.Data is > 0 and <= 65535
            ? manifestStaging.Ports.Data
            : LauncherSettings.DefaultStagingDataPort;
        _settings.StagingViewPort = manifestStaging?.Ports.View is > 0 and <= 65535
            ? manifestStaging.Ports.View
            : LauncherSettings.DefaultStagingViewPort;
        _settings.StagingSearchPort = manifestStaging?.Ports.Search is > 0 and <= 65535
            ? manifestStaging.Ports.Search
            : LauncherSettings.DefaultStagingSearchPort;
        _settings.StagingProfilePort = manifestStaging?.Ports.Profile is > 0 and <= 65535
            ? manifestStaging.Ports.Profile
            : LauncherSettings.DefaultStagingProfilePort;
        _settings.StagingProfileIrcPort = manifestStaging?.Ports.ProfileIrc is > 0 and <= 65535
            ? manifestStaging.Ports.ProfileIrc
            : LauncherSettings.DefaultStagingProfileIrcPort;

        _stagingRelay.Stop();
        _settingsService.Save(_settings, PlainPassword);

        OnPropertyChanged(nameof(StagingServerHost));
        OnPropertyChanged(nameof(StagingAuthPort));
        OnPropertyChanged(nameof(StagingDataPort));
        OnPropertyChanged(nameof(StagingViewPort));
        OnPropertyChanged(nameof(StagingSearchPort));
        OnPropertyChanged(nameof(StagingProfilePort));
        OnPropertyChanged(nameof(StagingProfileIrcPort));
        NotifyEffectiveServerChanged();
        StatusMessage = $"Restored Staging defaults ({_settings.StagingServerHost}:{_settings.StagingAuthPort}).";
        Log(StatusMessage);
        _ = RefreshServerStatusAsync();
    }

    public void Shutdown()
    {
        _stagingRelay.Stop();
    }

    public void Dispose()
    {
        _stagingRelay.DiagnosticMessage -= Log;
        _stagingRelay.StateChanged -= OnStagingRelayStateChanged;
        _stagingRelay.Dispose();
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
        OnPropertyChanged(nameof(StagingTargetSummaryText));
        OnPropertyChanged(nameof(StagingRelayStatusText));
        OnPropertyChanged(nameof(PlayButtonText));
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

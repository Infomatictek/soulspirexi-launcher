using System.IO;

namespace SoulspireLauncher.Models;

public enum ClientEngineMode
{
    Classic = 0,
    ModernBaseline = 1,
    ModernCompat = 2
}

public enum WindowModeOption
{
    Borderless = 3,
    Windowed = 1,
    Fullscreen = 0
}

public enum UpdateChannel
{
    Stable = 0,
    Testing = 1,
    TestingRegistry24Hook = 2,
    TestingSearchLegacyText = 3,
    TestingSearchAlignedText = 4,
    TestingCoreUi = 5
}

public enum ServerTargetMode
{
    Production = 0,
    Staging = 1,
    Custom = 2
}

public enum StagingLane
{
    Combat = 0,
    CoreUi = 1,
    Native = 2
}

public sealed record StagingLanePreset(
    StagingLane Lane,
    string Id,
    string DisplayName,
    string ShortBadgeLabel,
    string PortBlockLabel,
    int AuthPort,
    int DataPort,
    int ViewPort,
    int SearchPort,
    int ProfilePort,
    int ProfileIrcPort,
    int MapUdpPort,
    bool IsFutureReserved = false);

public sealed class LauncherSettings
{
    public const string DefaultCustomDatOverlayPath = @"C:\DATs\Soulspire";
    public const string LegacyDefaultCustomDatOverlayPath = @"C:\DATs\Overlords";
    public const string DefaultStagingHost = "192.168.86.117";
    public const int DefaultStagingAuthPort = 55231;
    public const int DefaultStagingDataPort = 55230;
    public const int DefaultStagingViewPort = 55001;
    public const int DefaultStagingSearchPort = 55002;
    public const int DefaultStagingProfilePort = 51221;
    public const int DefaultStagingProfileIrcPort = 51241;
    public const int DefaultStagingMapPort = 55230;

    public static readonly StagingLanePreset CombatStagingPreset = new(
        Lane: StagingLane.Combat,
        Id: "combat",
        DisplayName: "Combat Staging (55xxx • Balance / Gauntlet)",
        ShortBadgeLabel: "COMBAT STAGING",
        PortBlockLabel: "55xxx",
        AuthPort: 55231,
        DataPort: 55230,
        ViewPort: 55001,
        SearchPort: 55002,
        ProfilePort: 51221,
        ProfileIrcPort: 51241,
        MapUdpPort: 55230);

    public static readonly StagingLanePreset CoreUiStagingPreset = new(
        Lane: StagingLane.CoreUi,
        Id: "core-ui",
        DisplayName: "Core UI Staging (56xxx • Core UI / OXTL v2 Cache)",
        ShortBadgeLabel: "CORE UI STAGING",
        PortBlockLabel: "56xxx",
        AuthPort: 56231,
        DataPort: 56230,
        ViewPort: 56001,
        SearchPort: 56002,
        ProfilePort: 51222,
        ProfileIrcPort: 51242,
        MapUdpPort: 56230);

    public static readonly StagingLanePreset NativeStagingPreset = new(
        Lane: StagingLane.Native,
        Id: "native",
        DisplayName: "Native Staging (57xxx • Future / Reserved)",
        ShortBadgeLabel: "NATIVE STAGING (FUTURE)",
        PortBlockLabel: "57xxx",
        AuthPort: 57231,
        DataPort: 57230,
        ViewPort: 57001,
        SearchPort: 57002,
        ProfilePort: 51223,
        ProfileIrcPort: 51243,
        MapUdpPort: 57230,
        IsFutureReserved: true);

    public static StagingLanePreset GetStagingLanePreset(StagingLane lane) =>
        lane switch
        {
            StagingLane.CoreUi => CoreUiStagingPreset,
            StagingLane.Native => NativeStagingPreset,
            _ => CombatStagingPreset
        };

    public void ApplyStagingLanePreset(StagingLane lane)
    {
        var preset = GetStagingLanePreset(lane);
        StagingLane = preset.Lane;
        StagingAuthPort = preset.AuthPort;
        StagingDataPort = preset.DataPort;
        StagingViewPort = preset.ViewPort;
        StagingSearchPort = preset.SearchPort;
        StagingProfilePort = preset.ProfilePort;
        StagingProfileIrcPort = preset.ProfileIrcPort;
        StagingMapPort = preset.MapUdpPort;
    }

    public UpdateChannel UpdateChannel { get; set; } = UpdateChannel.Stable;
    public ClientEngineMode ClientEngine { get; set; } = ClientEngineMode.Classic;
    public string ModernClientPath { get; set; } = string.Empty;
    public bool ModernClientSafeLoginMode { get; set; } = true;
    public bool ModernClientUseD3D11Fallback { get; set; }

    public ServerTargetMode ServerTarget { get; set; } = ServerTargetMode.Production;
    public StagingLane StagingLane { get; set; } = StagingLane.Combat;
    public string StagingServerHost { get; set; } = DefaultStagingHost;
    public int StagingAuthPort { get; set; } = DefaultStagingAuthPort;
    public int StagingDataPort { get; set; } = DefaultStagingDataPort;
    public int StagingViewPort { get; set; } = DefaultStagingViewPort;
    public int StagingSearchPort { get; set; } = DefaultStagingSearchPort;
    public int StagingProfilePort { get; set; } = DefaultStagingProfilePort;
    public int StagingProfileIrcPort { get; set; } = DefaultStagingProfileIrcPort;
    public int StagingMapPort { get; set; } = DefaultStagingMapPort;

    public bool UseCustomServer { get; set; }
    public string CustomServerHost { get; set; } = "play.soulspirexi.com";
    public bool CustomUseHairpin { get; set; }
    public int CustomLobbyPort { get; set; } = 54231;
    public int CustomSearchPort { get; set; } = 54002;

    public string FfxiPath { get; set; } = string.Empty;
    public string AshitaPath { get; set; } = string.Empty;
    public bool UseCustomAshitaPath { get; set; }
    public bool SyncToCustomDatFolder { get; set; }
    public string CustomDatOverlayPath { get; set; } = DefaultCustomDatOverlayPath;

    public string Username { get; set; } = string.Empty;
    public bool RememberPassword { get; set; }
    public string EncryptedPasswordBase64 { get; set; } = string.Empty;
    public bool AutoLogin { get; set; }

    public WindowModeOption WindowMode { get; set; } = WindowModeOption.Borderless;
    public int WindowWidth { get; set; } = 1920;
    public int WindowHeight { get; set; } = 1080;
    public int BackgroundWidth { get; set; } = 2048;
    public int BackgroundHeight { get; set; } = 2048;
    public int MenuWidth { get; set; } = 1920;
    public int MenuHeight { get; set; } = 1080;
    public int MipMapping { get; set; } = 6;
    public bool BumpMapping { get; set; }
    public bool UncompressedTextures { get; set; } = true;
    public bool UncompressedMaps { get; set; } = true;
    public bool HighQualityFonts { get; set; } = true;
    public bool HardwareMouse { get; set; } = true;
    public bool ShowOpeningMovie { get; set; }
    public bool SoundEnabled { get; set; } = true;
    public bool BackgroundSound { get; set; } = true;
    public int FpsCap { get; set; } = 60;
    public string Language { get; set; } = "US";

    public bool EnablePivotOverlay { get; set; } = true;
    public bool EnableFlintlockDualPistolsOverlay { get; set; }
    public bool AutoLoadTalentsAddon { get; set; } = true;
    public bool AutoLoadCrystalSocketAddon { get; set; } = true;
    public bool AutoLoadMetricsAddon { get; set; } = true;
    public bool AutoLoadCheckerAddon { get; set; } = true;
    public bool AutoLoadMobDbAddon { get; set; } = true;
    public bool AutoLoadKazenoeyeAddon { get; set; } = true;
    public bool AutoLoadGearAddon { get; set; } = true;
    public bool AutoLoadSoulHudAddon { get; set; } = true;
    public bool AutoLoadFlintlockAddon { get; set; } = true;
    public bool AutoCloseOnLaunch { get; set; }
    public bool AutoCheckUpdatesOnStartup { get; set; } = true;
    public bool AutoUpdateLauncher { get; set; } = true;
    public bool EnableAutomaticTestingQolSettings { get; set; } = true;
    public bool EnablePerformanceDiagnostics { get; set; } = false;

    public bool HasImportedSystemSettings { get; set; }
    public string ImportedSettingsSource { get; set; } = string.Empty;

    // Preserved original Ashita v4 [ashita.input] keyboard preferences (restored on Stable or when Testing QoL is disabled).
    public bool KeyboardBlockBindsDuringInput { get; set; } = true;
    public bool KeyboardWindowsKeyEnabled { get; set; }

    public bool GamepadAllowBackground { get; set; } = true;
    public bool GamepadDisableEnumeration { get; set; }
    public bool UseCustomGamepadConfig { get; set; }
    public bool EnableGamepad { get; set; } = true;
    public bool EnableXInput { get; set; } = true;
    public string PadMode { get; set; } = string.Empty;
    public string PadSin { get; set; } = string.Empty;
    public string PadGuid { get; set; } = string.Empty;
    public string PadExSin { get; set; } = string.Empty;

    public static LauncherSettings CreateDefault(string baseDir)
    {
        return new LauncherSettings
        {
            AshitaPath = Path.Combine(baseDir, "Ashita"),
            ModernClientPath = Path.Combine(baseDir, "ModernClient")
        };
    }
}

public sealed class LocalServerOverride
{
    public string? ServerName { get; set; }
    public string? DefaultHost { get; set; }
    public bool? UseHairpin { get; set; }
    public int? LobbyPort { get; set; }
    public int? AuthPort { get; set; }
    public int? SearchPort { get; set; }
}

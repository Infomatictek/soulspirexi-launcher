using System.IO;

namespace SoulspireLauncher.Models;

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

public sealed class LauncherSettings
{
    public const string DefaultCustomDatOverlayPath = @"C:\DATs\Soulspire";
    public const string LegacyDefaultCustomDatOverlayPath = @"C:\DATs\Overlords";
    public const string DefaultStagingHost = "192.168.86.117";
    public const int DefaultStagingAuthPort = 55231;
    public const int DefaultStagingDataPort = 55230;
    public const int DefaultStagingViewPort = 55001;
    public const int DefaultStagingSearchPort = 55002;
    public const int DefaultStagingMapPort = 55230;

    public UpdateChannel UpdateChannel { get; set; } = UpdateChannel.Stable;

    public ServerTargetMode ServerTarget { get; set; } = ServerTargetMode.Production;
    public string StagingServerHost { get; set; } = DefaultStagingHost;
    public int StagingAuthPort { get; set; } = DefaultStagingAuthPort;
    public int StagingDataPort { get; set; } = DefaultStagingDataPort;
    public int StagingViewPort { get; set; } = DefaultStagingViewPort;
    public int StagingSearchPort { get; set; } = DefaultStagingSearchPort;

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

    public bool HasImportedSystemSettings { get; set; }
    public string ImportedSettingsSource { get; set; } = string.Empty;

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
            AshitaPath = Path.Combine(baseDir, "Ashita")
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

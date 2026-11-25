using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class SettingsService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    private readonly string _appDataDir;
    private readonly string _legacyAppDataDir;
    private readonly string _settingsPath;
    private readonly string _launcherBaseDir;

    public SettingsService(
        string? launcherBaseDir = null,
        string? appDataOverride = null,
        string? legacyAppDataOverride = null)
    {
        _launcherBaseDir = ResolveLauncherBaseDirectory(launcherBaseDir);
        var roamingRoot = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _appDataDir = appDataOverride ?? Path.Combine(roamingRoot, "SoulspireXI");
        _legacyAppDataDir = legacyAppDataOverride ?? (appDataOverride is null
            ? Path.Combine(roamingRoot, "OverlordsXI")
            : string.Empty);
        _settingsPath = Path.Combine(_appDataDir, "settings.json");
    }

    public string SettingsPath => _settingsPath;
    public string LauncherBaseDirectory => _launcherBaseDir;
    public string DefaultAshitaDirectory => GetDefaultAshitaDirectory(_launcherBaseDir);

    public static string ResolveLauncherBaseDirectory(string? launcherBaseDir = null)
    {
        if (!string.IsNullOrWhiteSpace(launcherBaseDir))
        {
            return Path.GetFullPath(launcherBaseDir);
        }

        var exePath = LauncherSelfUpdateService.GetCurrentExecutablePath();
        var exeDir = !string.IsNullOrWhiteSpace(exePath) ? Path.GetDirectoryName(exePath) : null;
        return Path.GetFullPath(!string.IsNullOrWhiteSpace(exeDir) ? exeDir : AppContext.BaseDirectory);
    }

    public static string GetDefaultAshitaDirectory(string baseDir) =>
        Path.Combine(Path.GetFullPath(baseDir), "Ashita");

    public static bool PathsEqual(string? left, string? right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right))
        {
            return false;
        }

        try
        {
            var normLeft = Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normRight = Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return string.Equals(normLeft, normRight, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return string.Equals(left.Trim(), right.Trim(), StringComparison.OrdinalIgnoreCase);
        }
    }

    public string EnsureDefaultAshitaDirectory()
    {
        var dir = DefaultAshitaDirectory;
        Directory.CreateDirectory(dir);
        return dir;
    }

    public void EnsureAshitaDirectory(LauncherSettings settings)
    {
        if (!settings.UseCustomAshitaPath || string.IsNullOrWhiteSpace(settings.AshitaPath))
        {
            settings.AshitaPath = DefaultAshitaDirectory;
            settings.UseCustomAshitaPath = false;
        }

        Directory.CreateDirectory(settings.AshitaPath);
    }

    public LauncherSettings Load()
    {
        var defaultAshitaDir = DefaultAshitaDirectory;
        try
        {
            if (!File.Exists(_settingsPath) && !string.IsNullOrWhiteSpace(_legacyAppDataDir))
            {
                var legacyPath = Path.Combine(_legacyAppDataDir, "settings.json");
                if (File.Exists(legacyPath))
                {
                    Directory.CreateDirectory(_appDataDir);
                    File.Copy(legacyPath, _settingsPath, overwrite: false);
                }
            }

            if (File.Exists(_settingsPath))
            {
                var json = File.ReadAllText(_settingsPath, Encoding.UTF8);
                var loaded = JsonSerializer.Deserialize<LauncherSettings>(json, JsonOptions);
                if (loaded is not null)
                {
                    using var doc = JsonDocument.Parse(json);
                    var hasExplicitCustomFlag = doc.RootElement.ValueKind == JsonValueKind.Object &&
                        doc.RootElement.EnumerateObject().Any(p =>
                            p.Name.Equals(nameof(LauncherSettings.UseCustomAshitaPath), StringComparison.OrdinalIgnoreCase));
                    var hasExplicitServerTarget = doc.RootElement.ValueKind == JsonValueKind.Object &&
                        doc.RootElement.EnumerateObject().Any(p =>
                            p.Name.Equals(nameof(LauncherSettings.ServerTarget), StringComparison.OrdinalIgnoreCase));

                    if (!hasExplicitServerTarget)
                    {
                        loaded.ServerTarget = loaded.UseCustomServer
                            ? ServerTargetMode.Custom
                            : ServerTargetMode.Production;
                    }
                    else
                    {
                        if (!Enum.IsDefined(loaded.ServerTarget))
                        {
                            loaded.ServerTarget = loaded.UseCustomServer
                                ? ServerTargetMode.Custom
                                : ServerTargetMode.Production;
                        }

                        loaded.UseCustomServer = loaded.ServerTarget == ServerTargetMode.Custom;
                    }

                    if (string.IsNullOrWhiteSpace(loaded.StagingServerHost))
                    {
                        loaded.StagingServerHost = LauncherSettings.DefaultStagingHost;
                    }
                    if (loaded.StagingAuthPort is <= 0 or > 65535)
                    {
                        loaded.StagingAuthPort = LauncherSettings.DefaultStagingAuthPort;
                    }
                    if (loaded.StagingDataPort is <= 0 or > 65535)
                    {
                        loaded.StagingDataPort = LauncherSettings.DefaultStagingDataPort;
                    }
                    if (loaded.StagingViewPort is <= 0 or > 65535)
                    {
                        loaded.StagingViewPort = LauncherSettings.DefaultStagingViewPort;
                    }
                    if (loaded.StagingSearchPort is <= 0 or > 65535)
                    {
                        loaded.StagingSearchPort = LauncherSettings.DefaultStagingSearchPort;
                    }
                    if (loaded.StagingProfilePort is <= 0 or > 65535)
                    {
                        loaded.StagingProfilePort = LauncherSettings.DefaultStagingProfilePort;
                    }
                    if (loaded.StagingProfileIrcPort is <= 0 or > 65535)
                    {
                        loaded.StagingProfileIrcPort = LauncherSettings.DefaultStagingProfileIrcPort;
                    }

                    if (string.IsNullOrWhiteSpace(loaded.AshitaPath))
                    {
                        loaded.AshitaPath = defaultAshitaDir;
                        loaded.UseCustomAshitaPath = false;
                    }
                    else if (!hasExplicitCustomFlag && !PathsEqual(loaded.AshitaPath, defaultAshitaDir))
                    {
                        var folderName = Path.GetFileName(loaded.AshitaPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                        var hasExistingCustomInstall =
                            !string.Equals(folderName, "Ashita", StringComparison.OrdinalIgnoreCase) &&
                            File.Exists(Path.Combine(loaded.AshitaPath, "Ashita-cli.exe"));

                        if (hasExistingCustomInstall)
                        {
                            loaded.UseCustomAshitaPath = true;
                        }
                        else
                        {
                            loaded.AshitaPath = defaultAshitaDir;
                            loaded.UseCustomAshitaPath = false;
                        }
                    }
                    else if (!loaded.UseCustomAshitaPath)
                    {
                        loaded.AshitaPath = defaultAshitaDir;
                    }

                    // Consolidate legacy/experimental Testing channel selections to canonical Testing
                    // without resetting QoL, graphics, Ashita path, or server settings.
                    loaded.UpdateChannel = ManifestUpdateService.NormalizeUserFacingChannel(loaded.UpdateChannel);

                    // Migrate untouched legacy default DAT folder path when custom DAT sync is not active.
                    if (!loaded.SyncToCustomDatFolder &&
                        string.Equals(
                            loaded.CustomDatOverlayPath?.Trim(),
                            LauncherSettings.LegacyDefaultCustomDatOverlayPath,
                            StringComparison.OrdinalIgnoreCase))
                    {
                        loaded.CustomDatOverlayPath = LauncherSettings.DefaultCustomDatOverlayPath;
                    }

                    return loaded;
                }
            }
        }
        catch
        {
            // Fall back to defaults if user settings are corrupt.
        }

        return LauncherSettings.CreateDefault(_launcherBaseDir);
    }

    public void Save(LauncherSettings settings, string? plainPassword)
    {
        Directory.CreateDirectory(_appDataDir);

        if (settings.RememberPassword && !string.IsNullOrEmpty(plainPassword))
        {
            settings.EncryptedPasswordBase64 = ProtectPassword(plainPassword);
        }
        else if (!settings.RememberPassword)
        {
            settings.EncryptedPasswordBase64 = string.Empty;
        }

        var json = JsonSerializer.Serialize(settings, JsonOptions);
        File.WriteAllText(_settingsPath, json, Encoding.UTF8);
    }

    public string UnprotectPassword(LauncherSettings settings)
    {
        if (!settings.RememberPassword || string.IsNullOrWhiteSpace(settings.EncryptedPasswordBase64))
        {
            return string.Empty;
        }

        try
        {
            var protectedBytes = Convert.FromBase64String(settings.EncryptedPasswordBase64);
            var rawBytes = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(rawBytes);
        }
        catch
        {
            return string.Empty;
        }
    }

    public LocalServerOverride? LoadLocalServerOverride()
    {
        var overridePath = Path.Combine(_launcherBaseDir, "soulspire-server.json");
        if (!File.Exists(overridePath))
        {
            var legacyOverridePath = Path.Combine(_launcherBaseDir, "overlords-server.json");
            if (!File.Exists(legacyOverridePath))
            {
                return null;
            }

            overridePath = legacyOverridePath;
        }

        try
        {
            var json = File.ReadAllText(overridePath, Encoding.UTF8);
            return JsonSerializer.Deserialize<LocalServerOverride>(json, JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    private static string ProtectPassword(string plainPassword)
    {
        var rawBytes = Encoding.UTF8.GetBytes(plainPassword);
        var protectedBytes = ProtectedData.Protect(rawBytes, null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(protectedBytes);
    }
}

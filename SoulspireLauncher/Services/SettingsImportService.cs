using System.Globalization;
using System.IO;
using Microsoft.Win32;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class SettingsImportResult
{
    public bool ImportedAny { get; init; }
    public string SourceSummary { get; init; } = string.Empty;
}

public sealed record FfxiGamepadConfig(
    string? PadMode,
    string? PadSin,
    string? PadExSin,
    string? PadGuid,
    string Source)
{
    public bool HasAny =>
        !string.IsNullOrWhiteSpace(PadMode) ||
        !string.IsNullOrWhiteSpace(PadSin) ||
        !string.IsNullOrWhiteSpace(PadExSin) ||
        !string.IsNullOrWhiteSpace(PadGuid);
}

public sealed class SettingsImportService
{
    private static readonly (string SubKeyPath, string Region)[] FfxiConfigRegistryKeys =
    [
        (@"SOFTWARE\PlayOnlineUS\SquareEnix\FinalFantasyXI", "US"),
        (@"SOFTWARE\PlayOnlineEU\SquareEnix\FinalFantasyXI", "EU"),
        (@"SOFTWARE\PlayOnline\SQUARE\FinalFantasyXI", "JP"),
        (@"SOFTWARE\PlayOnline\SquareEnix\FinalFantasyXI", "JP")
    ];

    private static readonly (string SubKeyPath, string Region)[] FfxiVirtualStoreRegistryKeys =
    [
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\WOW6432Node\PlayOnlineUS\SquareEnix\FinalFantasyXI", "US"),
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\WOW6432Node\PlayOnlineEU\SquareEnix\FinalFantasyXI", "EU"),
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\WOW6432Node\PlayOnline\SQUARE\FinalFantasyXI", "JP"),
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\WOW6432Node\PlayOnline\SquareEnix\FinalFantasyXI", "JP"),
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\PlayOnlineUS\SquareEnix\FinalFantasyXI", "US"),
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\PlayOnlineEU\SquareEnix\FinalFantasyXI", "EU"),
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\PlayOnline\SQUARE\FinalFantasyXI", "JP"),
        (@"Software\Classes\VirtualStore\MACHINE\SOFTWARE\PlayOnline\SquareEnix\FinalFantasyXI", "JP")
    ];

    public SettingsImportResult ImportBestAvailable(LauncherSettings settings, bool gamepadOnly = false)
    {
        var sources = new List<string>();

        if (TryImportFromWindowsRegistry(settings, gamepadOnly, out var regSource))
        {
            sources.Add(regSource);
        }

        var iniPath = FindBestAshitaIniPath(settings);
        if (!string.IsNullOrEmpty(iniPath) && TryImportFromAshitaIni(iniPath, settings, gamepadOnly))
        {
            sources.Add($"Ashita config ({Path.GetFileName(iniPath)})");
        }

        if (sources.Count == 0)
        {
            return new SettingsImportResult
            {
                ImportedAny = false,
                SourceSummary = "No existing FFXI Registry or Ashita .ini settings found."
            };
        }

        var summary = string.Join(" + ", sources);
        settings.HasImportedSystemSettings = true;
        settings.ImportedSettingsSource = summary;
        return new SettingsImportResult
        {
            ImportedAny = true,
            SourceSummary = $"Imported from {summary}"
        };
    }

    public bool TryImportFromAshitaIni(string iniPath, LauncherSettings settings, bool gamepadOnly = false)
    {
        if (!File.Exists(iniPath))
        {
            return false;
        }

        var rawContent = File.ReadAllText(iniPath);
        var isTestingQolManagedIni = rawContent.Contains(AshitaConfigGenerator.TestingQolIniMarker, StringComparison.OrdinalIgnoreCase);
        var sections = ParseIni(rawContent);
        var changed = false;

        if (sections.TryGetValue("ashita.input", out var inputSec))
        {
            if (TryReadBool(inputSec, "gamepad.allowbackground", out var allowBg))
            {
                settings.GamepadAllowBackground = allowBg;
                changed = true;
            }

            if (TryReadBool(inputSec, "gamepad.disableenumeration", out var disableEnum))
            {
                settings.GamepadDisableEnumeration = disableEnum;
                changed = true;
            }

            if (!gamepadOnly && !isTestingQolManagedIni)
            {
                if (TryReadBool(inputSec, "keyboard.blockbindsduringinput", out var blockBinds))
                {
                    settings.KeyboardBlockBindsDuringInput = blockBinds;
                    changed = true;
                }

                if (TryReadBool(inputSec, "keyboard.windowskeyenabled", out var winKeyEnabled))
                {
                    settings.KeyboardWindowsKeyEnabled = winKeyEnabled;
                    changed = true;
                }
            }
        }

        if (!gamepadOnly && sections.TryGetValue("ashita.language", out var langSec))
        {
            if (TryReadInt(langSec, "playonline", out var langCode))
            {
                settings.Language = langCode switch
                {
                    1 => "JP",
                    3 => "EU",
                    _ => "US"
                };
                changed = true;
            }
        }

        if (sections.TryGetValue("ffxi.registry", out var regSec))
        {
            if (!gamepadOnly)
            {
                changed |= ApplyFfxiRegistryValues(regSec, settings);
            }

            changed |= ApplyGamepadRegistryValues(regSec, settings);
        }

        if (changed)
        {
            settings.HasImportedSystemSettings = true;
            settings.ImportedSettingsSource = $"Ashita config ({iniPath})";
        }

        return changed;
    }

    public bool TryImportFromWindowsRegistry(LauncherSettings settings, bool gamepadOnly, out string sourceLabel)
    {
        sourceLabel = string.Empty;

        // 1. Check UAC VirtualStore first (non-elevated FFXiPadConfig.exe writes here on Windows 10/11,
        //    and 32-bit retail FFXI / Classic Ashita transparently reads VirtualStore before HKLM).
        foreach (var (keyPath, region) in FfxiVirtualStoreRegistryKeys)
        {
            if (TryReadRegistryDict(RegistryHive.CurrentUser, RegistryView.Default, keyPath, out var dict))
            {
                var changed = false;
                if (!gamepadOnly)
                {
                    changed |= ApplyFfxiRegistryValues(dict, settings);
                    if (settings.Language is not ("US" or "EU" or "JP"))
                    {
                        settings.Language = region;
                    }
                }

                changed |= ApplyGamepadRegistryValues(dict, settings);
                if (changed)
                {
                    sourceLabel = $"FFXI Registry ({region}, VirtualStore)";
                    return true;
                }
            }
        }

        // 2. Check real HKLM (WOW6432Node first, then 64-bit view), strictly read-only.
        foreach (var view in new[] { RegistryView.Registry32, RegistryView.Registry64 })
        {
            foreach (var (keyPath, region) in FfxiConfigRegistryKeys)
            {
                if (TryReadRegistryDict(RegistryHive.LocalMachine, view, keyPath, out var dict))
                {
                    var changed = false;
                    if (!gamepadOnly)
                    {
                        changed |= ApplyFfxiRegistryValues(dict, settings);
                        if (settings.Language is not ("US" or "EU" or "JP"))
                        {
                            settings.Language = region;
                        }
                    }

                    changed |= ApplyGamepadRegistryValues(dict, settings);
                    if (changed)
                    {
                        var viewLabel = view == RegistryView.Registry32 ? "HKLM WOW6432Node" : "HKLM 64-bit";
                        sourceLabel = $"FFXI Registry ({region}, {viewLabel})";
                        return true;
                    }
                }
            }
        }

        return false;
    }

    /// <summary>
    /// Non-destructively reads the player's existing FFXI gamepad settings (padmode000, padsin000,
    /// padexsin000, padguid000) without mutating any Windows registry key or resetting user settings.
    /// </summary>
    public FfxiGamepadConfig ReadBestExistingGamepadConfig(LauncherSettings settings)
    {
        string? padMode = null;
        string? padSin = null;
        string? padExSin = null;
        string? padGuid = null;
        var sources = new List<string>();

        void MergeFromDict(IReadOnlyDictionary<string, string> dict, string label)
        {
            var hit = false;
            if (string.IsNullOrWhiteSpace(padMode) && TryGetNonPassthroughValue(dict, "padmode000", out var m))
            {
                padMode = m;
                hit = true;
            }
            if (string.IsNullOrWhiteSpace(padSin) && TryGetNonPassthroughValue(dict, "padsin000", out var s))
            {
                padSin = s;
                hit = true;
            }
            if (string.IsNullOrWhiteSpace(padExSin) && TryGetNonPassthroughValue(dict, "padexsin000", out var ex))
            {
                padExSin = ex;
                hit = true;
            }
            if (string.IsNullOrWhiteSpace(padGuid) && TryGetNonPassthroughValue(dict, "padguid000", out var g))
            {
                padGuid = g;
                hit = true;
            }
            if (hit && !sources.Contains(label, StringComparer.OrdinalIgnoreCase))
            {
                sources.Add(label);
            }
        }

        // 1. Real Windows Registry: UAC VirtualStore first, then HKLM WOW6432Node, then HKLM 64-bit (read-only).
        foreach (var (keyPath, region) in FfxiVirtualStoreRegistryKeys)
        {
            if (TryReadRegistryDict(RegistryHive.CurrentUser, RegistryView.Default, keyPath, out var dict))
            {
                MergeFromDict(dict, $"FFXI Registry ({region}, VirtualStore)");
            }
        }

        foreach (var view in new[] { RegistryView.Registry32, RegistryView.Registry64 })
        {
            var viewLabel = view == RegistryView.Registry32 ? "HKLM WOW6432Node" : "HKLM 64-bit";
            foreach (var (keyPath, region) in FfxiConfigRegistryKeys)
            {
                if (TryReadRegistryDict(RegistryHive.LocalMachine, view, keyPath, out var dict))
                {
                    MergeFromDict(dict, $"FFXI Registry ({region}, {viewLabel})");
                }
            }
        }

        // 2. Existing Ashita boot INI ([ffxi.registry]) for any remaining fields.
        var iniPath = FindBestAshitaIniPath(settings);
        if (!string.IsNullOrEmpty(iniPath) && File.Exists(iniPath))
        {
            try
            {
                var sections = ParseIni(File.ReadAllText(iniPath));
                if (sections.TryGetValue("ffxi.registry", out var regSec))
                {
                    MergeFromDict(regSec, $"Ashita config ({Path.GetFileName(iniPath)})");
                }
            }
            catch
            {
                // Ignore unreadable Ashita config files.
            }
        }

        // 3. Previously imported LauncherSettings fields as fallback.
        var settingsDict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(settings.PadMode)) settingsDict["padmode000"] = settings.PadMode;
        if (!string.IsNullOrWhiteSpace(settings.PadSin)) settingsDict["padsin000"] = settings.PadSin;
        if (!string.IsNullOrWhiteSpace(settings.PadExSin)) settingsDict["padexsin000"] = settings.PadExSin;
        if (!string.IsNullOrWhiteSpace(settings.PadGuid)) settingsDict["padguid000"] = settings.PadGuid;
        if (settingsDict.Count > 0)
        {
            MergeFromDict(settingsDict, "LauncherSettings");
        }

        var sourceSummary = sources.Count > 0
            ? string.Join(" + ", sources)
            : "Not found in Windows Registry, Ashita config, or LauncherSettings";

        return new FfxiGamepadConfig(padMode, padSin, padExSin, padGuid, sourceSummary);
    }

    /// <summary>
    /// Extracts existing [ffxi] gamepad.* values from a VanaCore INI file so in-game /vana
    /// customizations are preserved across launcher updates and relaunches.
    /// </summary>
    public static FfxiGamepadConfig? ParseVanaCoreIniGamepadConfig(string? rawIniContent)
    {
        if (string.IsNullOrWhiteSpace(rawIniContent))
        {
            return null;
        }

        var sections = ParseIni(rawIniContent);
        if (!sections.TryGetValue("ffxi", out var ffxiSec))
        {
            return null;
        }

        TryGetNonPassthroughValue(ffxiSec, "gamepad.mode", out var mode);
        TryGetNonPassthroughValue(ffxiSec, "gamepad.buttons", out var buttons);
        TryGetNonPassthroughValue(ffxiSec, "gamepad.buttons_ex", out var buttonsEx);
        TryGetNonPassthroughValue(ffxiSec, "gamepad.guid", out var guid);

        var cfg = new FfxiGamepadConfig(
            string.IsNullOrWhiteSpace(mode) ? null : mode,
            string.IsNullOrWhiteSpace(buttons) ? null : buttons,
            string.IsNullOrWhiteSpace(buttonsEx) ? null : buttonsEx,
            string.IsNullOrWhiteSpace(guid) ? null : guid,
            "Preserved from existing vanacore.ini");

        return cfg.HasAny ? cfg : null;
    }

    private static bool TryReadRegistryDict(
        RegistryHive hive,
        RegistryView view,
        string subKeyPath,
        out Dictionary<string, string> dict)
    {
        dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(hive, view);
            using var subKey = baseKey.OpenSubKey(subKeyPath, writable: false);
            if (subKey is null)
            {
                return false;
            }

            foreach (var valueName in subKey.GetValueNames())
            {
                var val = subKey.GetValue(valueName);
                if (val is null or byte[])
                {
                    continue;
                }

                dict[valueName] = Convert.ToString(val, CultureInfo.InvariantCulture) ?? string.Empty;
            }

            return dict.Count > 0;
        }
        catch
        {
            return false;
        }
    }

    public static bool ApplyFfxiRegistryValues(IReadOnlyDictionary<string, string> values, LauncherSettings settings)
    {
        var changed = false;

        if (TryReadInt(values, "0000", out var mip) && mip >= 0)
        {
            settings.MipMapping = Math.Clamp(mip, 0, 6);
            changed = true;
        }

        if (TryReadInt(values, "0001", out var w) && w >= 640)
        {
            settings.WindowWidth = w;
            changed = true;
        }

        if (TryReadInt(values, "0002", out var h) && h >= 480)
        {
            settings.WindowHeight = h;
            changed = true;
        }

        if (TryReadInt(values, "0003", out var bw) && bw >= 512)
        {
            settings.BackgroundWidth = bw;
            changed = true;
        }

        if (TryReadInt(values, "0004", out var bh) && bh >= 512)
        {
            settings.BackgroundHeight = bh;
            changed = true;
        }

        if (TryReadBool(values, "0007", out var sound))
        {
            settings.SoundEnabled = sound;
            changed = true;
        }

        if (TryReadBool(values, "0017", out var bump))
        {
            settings.BumpMapping = bump;
            changed = true;
        }

        if (TryReadInt(values, "0018", out var uncompTex) && uncompTex >= 0)
        {
            settings.UncompressedTextures = uncompTex > 0;
            changed = true;
        }

        if (TryReadBool(values, "0019", out var uncompMap))
        {
            settings.UncompressedMaps = uncompMap;
            changed = true;
        }

        if (TryReadBool(values, "0021", out var hwMouse))
        {
            settings.HardwareMouse = hwMouse;
            changed = true;
        }

        if (TryReadBool(values, "0022", out var openingMovie))
        {
            settings.ShowOpeningMovie = openingMovie;
            changed = true;
        }

        if (TryReadInt(values, "0034", out var winMode) && winMode is 0 or 1 or 3)
        {
            settings.WindowMode = (WindowModeOption)winMode;
            changed = true;
        }

        if (TryReadBool(values, "0035", out var bgSound))
        {
            settings.BackgroundSound = bgSound;
            changed = true;
        }

        if (TryReadInt(values, "0036", out var fonts) && fonts >= 0)
        {
            settings.HighQualityFonts = fonts > 0;
            changed = true;
        }

        if (TryReadInt(values, "0037", out var mw) && mw >= 640)
        {
            settings.MenuWidth = mw;
            changed = true;
        }

        if (TryReadInt(values, "0038", out var mh) && mh >= 480)
        {
            settings.MenuHeight = mh;
            changed = true;
        }

        if (values.TryGetValue("0042", out var ffxiPath) &&
            !string.IsNullOrWhiteSpace(ffxiPath) &&
            ffxiPath.Trim() != "-1" &&
            string.IsNullOrWhiteSpace(settings.FfxiPath) &&
            Directory.Exists(ffxiPath.Trim()))
        {
            settings.FfxiPath = ffxiPath.Trim();
            changed = true;
        }

        return changed;
    }

    public static bool ApplyGamepadRegistryValues(IReadOnlyDictionary<string, string> values, LauncherSettings settings)
    {
        var changed = false;

        if (TryGetNonPassthroughValue(values, "padmode000", out var padMode))
        {
            settings.PadMode = padMode;
            settings.UseCustomGamepadConfig = true;
            ParsePadModeFlags(padMode, settings);
            changed = true;
        }

        if (TryGetNonPassthroughValue(values, "padsin000", out var padSin))
        {
            settings.PadSin = padSin;
            settings.UseCustomGamepadConfig = true;
            changed = true;
        }

        if (TryGetNonPassthroughValue(values, "padguid000", out var padGuid))
        {
            settings.PadGuid = padGuid;
            settings.UseCustomGamepadConfig = true;
            changed = true;
        }

        if (TryGetNonPassthroughValue(values, "padexsin000", out var padExSin))
        {
            settings.PadExSin = padExSin;
            settings.UseCustomGamepadConfig = true;
            changed = true;
        }

        return changed;
    }

    public static void ParsePadModeFlags(string padMode, LauncherSettings settings)
    {
        var parts = padMode.Split(',', StringSplitOptions.TrimEntries);
        if (parts.Length >= 1)
        {
            settings.EnableGamepad = parts[0] == "1";
        }

        if (parts.Length >= 6)
        {
            settings.EnableXInput = parts[5] == "1";
        }
    }

    public static string? FindFfxiConfigExecutable(LauncherSettings settings)
    {
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(settings.FfxiPath))
        {
            candidates.Add(Path.Combine(settings.FfxiPath, "ToolsUS", "FINAL FANTASY XI Config.exe"));
            candidates.Add(Path.Combine(settings.FfxiPath, "ToolsEU", "FINAL FANTASY XI Config.exe"));
            candidates.Add(Path.Combine(settings.FfxiPath, "Tools", "FINAL FANTASY XI Config.exe"));
            candidates.Add(Path.Combine(settings.FfxiPath, "ToolsUS", "FFXiPadConfig.exe"));
            candidates.Add(Path.Combine(settings.FfxiPath, "ToolsEU", "FFXiPadConfig.exe"));
            candidates.Add(Path.Combine(settings.FfxiPath, "Tools", "FFXiPadConfig.exe"));
        }

        return candidates.FirstOrDefault(File.Exists);
    }

    private static string? FindBestAshitaIniPath(LauncherSettings settings)
    {
        var bootDirs = new List<string>();

        if (!string.IsNullOrWhiteSpace(settings.AshitaPath))
        {
            bootDirs.Add(Path.Combine(settings.AshitaPath, "config", "boot"));
            var parent = Directory.GetParent(settings.AshitaPath)?.FullName;
            if (!string.IsNullOrWhiteSpace(parent))
            {
                bootDirs.Add(Path.Combine(parent, "Ashita", "config", "boot"));
            }
        }

        bootDirs.Add(@"C:\Ashita\config\boot");
        bootDirs.Add(@"D:\Ashita\config\boot");
        bootDirs.Add(@"C:\AshitaXI\config\boot");
        bootDirs.Add(@"D:\AshitaXI\config\boot");

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrWhiteSpace(localAppData))
        {
            bootDirs.Add(Path.Combine(localAppData, "HorizonXI", "Ashita", "config", "boot"));
            bootDirs.Add(Path.Combine(localAppData, "Programs", "HorizonXI", "Ashita", "config", "boot"));
        }

        var candidates = new List<FileInfo>();
        foreach (var dir in bootDirs.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                if (!Directory.Exists(dir))
                {
                    continue;
                }

                foreach (var file in Directory.EnumerateFiles(dir, "*.ini"))
                {
                    var name = Path.GetFileName(file);
                    if (name.Equals(AshitaConfigGenerator.BootConfigFileName, StringComparison.OrdinalIgnoreCase) ||
                        name.StartsWith("example", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    candidates.Add(new FileInfo(file));
                }
            }
            catch
            {
                // Ignore inaccessible directories.
            }
        }

        return candidates
            .OrderByDescending(f => f.LastWriteTimeUtc)
            .Select(f => f.FullName)
            .FirstOrDefault();
    }

    private static Dictionary<string, Dictionary<string, string>> ParseIni(string content)
    {
        var result = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        var currentSection = string.Empty;

        using var reader = new StringReader(content);
        string? rawLine;
        while ((rawLine = reader.ReadLine()) is not null)
        {
            var line = rawLine.Trim();
            if (string.IsNullOrEmpty(line) || line.StartsWith(';') || line.StartsWith('#'))
            {
                continue;
            }

            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                currentSection = line[1..^1].Trim();
                if (!result.ContainsKey(currentSection))
                {
                    result[currentSection] = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                }

                continue;
            }

            var eqIdx = line.IndexOf('=');
            if (eqIdx <= 0)
            {
                continue;
            }

            var key = line[..eqIdx].Trim();
            var value = line[(eqIdx + 1)..].Trim();

            if (!result.TryGetValue(currentSection, out var dict))
            {
                dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                result[currentSection] = dict;
            }

            dict[key] = value;
        }

        return result;
    }

    private static bool TryGetNonPassthroughValue(IReadOnlyDictionary<string, string> values, string key, out string value)
    {
        if (values.TryGetValue(key, out var raw))
        {
            var trimmed = raw.Trim();
            if (!string.IsNullOrWhiteSpace(trimmed) && trimmed != "-1")
            {
                value = trimmed;
                return true;
            }
        }

        value = string.Empty;
        return false;
    }

    private static bool TryReadInt(IReadOnlyDictionary<string, string> values, string key, out int result)
    {
        if (values.TryGetValue(key, out var raw) &&
            int.TryParse(raw.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out result))
        {
            return true;
        }

        result = 0;
        return false;
    }

    private static bool TryReadBool(IReadOnlyDictionary<string, string> values, string key, out bool result)
    {
        if (TryReadInt(values, key, out var intVal) && intVal >= 0)
        {
            result = intVal != 0;
            return true;
        }

        result = false;
        return false;
    }
}

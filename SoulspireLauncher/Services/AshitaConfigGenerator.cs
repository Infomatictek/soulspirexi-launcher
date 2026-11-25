using System.IO;
using System.Text;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class AshitaConfigGenerator
{
    public const string BootConfigFileName = "soulspirexi.ini";
    public const string ScriptFileName = "soulspirexi.txt";
    public const string LegacyScriptFileName = "overlordsxi.txt";
    public const string PivotConfigName = "soulspirexi";
    public const string OverlayFolderName = "soulspirexi";
    public const string FlintlockOverlayId = "flintlock-akimbo-compact";
    public const string FlintlockOverlayFolderName = "flintlock-akimbo-compact";
    public const string TestingQolIniMarker = "; soulspire-testing-qol-active = 1";
    public const string TestingQolScriptStartMarker = "# [SoulspireXI Testing QoL] Managed default bindings (auto-restored on Stable)";
    public const string TestingQolScriptEndMarker = "# [/SoulspireXI Testing QoL]";
    public const string DefaultScreenshotLoadLine = "/load screenshot";
    public const string DefaultScreenshotBindLine = "/bind SYSRQ /screenshot hide";
    public const string DefaultClipboardPasteBindLine = "/bind $^v /paste";

    public string BuildXiloaderCommand(
        string serverHost,
        bool useHairpin,
        string? username,
        string? password,
        bool autoLogin,
        string language)
    {
        var parts = new List<string>
        {
            $"--server {serverHost.Trim()}"
        };

        if (useHairpin)
        {
            parts.Add("--hairpin");
        }

        if (string.Equals(language, "EU", StringComparison.OrdinalIgnoreCase))
        {
            parts.Add("--lang EU");
        }
        else if (string.Equals(language, "JP", StringComparison.OrdinalIgnoreCase))
        {
            parts.Add("--lang JP");
        }

        if (autoLogin && !string.IsNullOrWhiteSpace(username) && !string.IsNullOrEmpty(password))
        {
            parts.Add($"--user {QuoteIfNeeded(username.Trim())}");
            parts.Add($"--pass {QuoteIfNeeded(password)}");
        }

        return string.Join(" ", parts);
    }

    public bool CapturePlayerInputPreferencesIfUnmanaged(string ashitaDir, LauncherSettings settings)
    {
        if (string.IsNullOrWhiteSpace(ashitaDir))
        {
            return false;
        }

        var bootIniPath = Path.Combine(ashitaDir, "config", "boot", BootConfigFileName);
        if (!File.Exists(bootIniPath))
        {
            return false;
        }

        string rawContent;
        try
        {
            rawContent = File.ReadAllText(bootIniPath, Encoding.UTF8);
        }
        catch
        {
            return false;
        }

        if (rawContent.Contains(TestingQolIniMarker, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var changed = false;
        var inInputSection = false;
        using var reader = new StringReader(rawContent);
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
                inInputSection = line[1..^1].Trim().Equals("ashita.input", StringComparison.OrdinalIgnoreCase);
                continue;
            }

            if (!inInputSection)
            {
                continue;
            }

            var eqIdx = line.IndexOf('=');
            if (eqIdx <= 0)
            {
                continue;
            }

            var key = line[..eqIdx].Trim();
            var valText = line[(eqIdx + 1)..].Trim();
            if (!int.TryParse(valText, out var intVal) || intVal < 0)
            {
                continue;
            }

            var boolVal = intVal != 0;
            if (key.Equals("keyboard.blockbindsduringinput", StringComparison.OrdinalIgnoreCase) &&
                settings.KeyboardBlockBindsDuringInput != boolVal)
            {
                settings.KeyboardBlockBindsDuringInput = boolVal;
                changed = true;
            }
            else if (key.Equals("keyboard.windowskeyenabled", StringComparison.OrdinalIgnoreCase) &&
                     settings.KeyboardWindowsKeyEnabled != boolVal)
            {
                settings.KeyboardWindowsKeyEnabled = boolVal;
                changed = true;
            }
        }

        return changed;
    }

    public string BuildBootIniContent(
        LauncherSettings settings,
        string serverHost,
        bool useHairpin,
        string? password,
        string xiloaderPath,
        string? manifestChannel = null,
        string? serverName = null)
    {
        var command = BuildXiloaderCommand(
            serverHost,
            useHairpin,
            settings.Username,
            password,
            settings.AutoLogin,
            settings.Language);

        var langCode = settings.Language.ToUpperInvariant() switch
        {
            "JP" => "1",
            "EU" => "3",
            _ => "2"
        };

        var effectiveInput = TestingEnvironmentQolPolicy.ResolveInputSettings(
            settings,
            serverHost,
            manifestChannel,
            serverName);

        var sb = new StringBuilder();
        sb.AppendLine("; Auto-generated by SoulspireXI Launcher");
        sb.AppendLine("[ashita.launcher]");
        sb.AppendLine($"autoclose = {(settings.AutoCloseOnLaunch ? 1 : 0)}");
        sb.AppendLine("name = SoulspireXI");
        sb.AppendLine();

        sb.AppendLine("[ashita.boot]");
        sb.AppendLine($"file = {xiloaderPath}");
        sb.AppendLine($"command = {command}");
        sb.AppendLine("gamemodule = ffximain.dll");
        sb.AppendLine($"script = {ScriptFileName}");
        sb.AppendLine("args =");
        sb.AppendLine();

        sb.AppendLine("[ashita.language]");
        sb.AppendLine($"playonline = {langCode}");
        sb.AppendLine($"ashita = {langCode}");
        sb.AppendLine();

        sb.AppendLine("[ashita.input]");
        if (effectiveInput.TestingQolApplied)
        {
            sb.AppendLine(TestingQolIniMarker);
        }
        sb.AppendLine($"gamepad.allowbackground = {(settings.GamepadAllowBackground ? 1 : 0)}");
        sb.AppendLine($"gamepad.disableenumeration = {(settings.GamepadDisableEnumeration ? 1 : 0)}");
        sb.AppendLine("keyboard.blockinput = 0");
        sb.AppendLine($"keyboard.blockbindsduringinput = {(effectiveInput.BlockBindsDuringInput ? 1 : 0)}");
        sb.AppendLine("keyboard.silentbinds = 0");
        sb.AppendLine($"keyboard.windowskeyenabled = {(effectiveInput.WindowsKeyEnabled ? 1 : 0)}");
        sb.AppendLine("mouse.blockinput = 0");
        sb.AppendLine("mouse.unhook = 1");
        sb.AppendLine();

        sb.AppendLine("[ashita.logging]");
        sb.AppendLine("level = 5");
        sb.AppendLine("crashdumps = 1");
        sb.AppendLine();

        sb.AppendLine("[ashita.polplugins]");
        if (settings.EnablePivotOverlay)
        {
            sb.AppendLine("pivot = 1");
        }
        sb.AppendLine();

        sb.AppendLine("[ashita.polplugins.args]");
        if (settings.EnablePivotOverlay)
        {
            sb.AppendLine($"pivot = {PivotConfigName}");
        }
        sb.AppendLine();

        sb.AppendLine("[ffxi.registry]");
        sb.AppendLine($"0000 = {Math.Clamp(settings.MipMapping, 0, 6)}");
        sb.AppendLine($"0001 = {Math.Max(640, settings.WindowWidth)}");
        sb.AppendLine($"0002 = {Math.Max(480, settings.WindowHeight)}");
        sb.AppendLine($"0003 = {Math.Max(512, settings.BackgroundWidth)}");
        sb.AppendLine($"0004 = {Math.Max(512, settings.BackgroundHeight)}");
        sb.AppendLine($"0007 = {(settings.SoundEnabled ? 1 : 0)}");
        sb.AppendLine("0011 = 2");
        sb.AppendLine($"0017 = {(settings.BumpMapping ? 1 : 0)}");
        sb.AppendLine($"0018 = {(settings.UncompressedTextures ? 2 : 0)}");
        sb.AppendLine($"0019 = {(settings.UncompressedMaps ? 1 : 0)}");
        sb.AppendLine($"0021 = {(settings.HardwareMouse ? 1 : 0)}");
        sb.AppendLine($"0022 = {(settings.ShowOpeningMovie ? 1 : 0)}");
        sb.AppendLine("0023 = 0");
        sb.AppendLine("0028 = 0");
        sb.AppendLine("0029 = 20");
        sb.AppendLine($"0034 = {(int)settings.WindowMode}");
        sb.AppendLine($"0035 = {(settings.BackgroundSound ? 1 : 0)}");
        sb.AppendLine($"0036 = {(settings.HighQualityFonts ? 2 : 0)}");
        sb.AppendLine($"0037 = {Math.Max(640, settings.MenuWidth)}");
        sb.AppendLine($"0038 = {Math.Max(480, settings.MenuHeight)}");
        sb.AppendLine("0040 = 0");
        if (!string.IsNullOrWhiteSpace(settings.FfxiPath))
        {
            sb.AppendLine($"0042 = {settings.FfxiPath.Trim()}");
        }

        sb.AppendLine($"padexsin000 = {ValueOrPassthrough(settings.PadExSin)}");
        sb.AppendLine($"padguid000 = {ValueOrPassthrough(settings.PadGuid)}");
        sb.AppendLine($"padmode000 = {BuildEffectivePadMode(settings)}");
        sb.AppendLine($"padsin000 = {ValueOrPassthrough(settings.PadSin)}");

        return sb.ToString();
    }

    public static string BuildEffectivePadMode(LauncherSettings settings)
    {
        if (settings.UseCustomGamepadConfig)
        {
            var parts = !string.IsNullOrWhiteSpace(settings.PadMode)
                ? settings.PadMode.Split(',', StringSplitOptions.TrimEntries)
                : ["0", "0", "0", "1", "0", "0"];

            if (parts.Length < 6)
            {
                var padded = new[] { "0", "0", "0", "1", "0", "0" };
                for (var i = 0; i < Math.Min(parts.Length, 6); i++)
                {
                    if (!string.IsNullOrWhiteSpace(parts[i]))
                    {
                        padded[i] = parts[i];
                    }
                }

                parts = padded;
            }

            parts[0] = settings.EnableGamepad ? "1" : "0";
            parts[5] = settings.EnableXInput ? "1" : "0";
            return string.Join(",", parts);
        }

        return ValueOrPassthrough(settings.PadMode);
    }

    private static string ValueOrPassthrough(string? value) =>
        string.IsNullOrWhiteSpace(value) ? "-1" : value.Trim();

    public string BuildPivotIniContent(string datsRootPath, bool enableFlintlockOverlay = false)
    {
        var sb = new StringBuilder();
        sb.AppendLine("[settings]");
        sb.AppendLine($"root_path={datsRootPath}");
        sb.AppendLine("debug_log=false");
        sb.AppendLine();
        sb.AppendLine("[overlays]");
        if (enableFlintlockOverlay)
        {
            sb.AppendLine($"0={FlintlockOverlayFolderName}");
            sb.AppendLine($"1={OverlayFolderName}");
        }
        else
        {
            sb.AppendLine($"0={OverlayFolderName}");
        }
        sb.AppendLine();
        sb.AppendLine("[cache]");
        sb.AppendLine("enabled=false");
        sb.AppendLine("size=0");
        sb.AppendLine("max_age=600");
        return sb.ToString();
    }

    public string MergeBootScriptContent(
        string? existingContent,
        LauncherSettings settings,
        bool applyTestingQolBindings = false)
    {
        var lines = new List<string>();
        if (!string.IsNullOrWhiteSpace(existingContent))
        {
            using var reader = new StringReader(existingContent);
            string? rawLine;
            var insideTestingQolBlock = false;
            while ((rawLine = reader.ReadLine()) is not null)
            {
                var trimmed = rawLine.Trim();
                if (trimmed.Equals(TestingQolScriptStartMarker, StringComparison.OrdinalIgnoreCase))
                {
                    insideTestingQolBlock = true;
                    continue;
                }

                if (insideTestingQolBlock)
                {
                    if (trimmed.Equals(TestingQolScriptEndMarker, StringComparison.OrdinalIgnoreCase))
                    {
                        insideTestingQolBlock = false;
                    }

                    continue;
                }

                if (trimmed.Equals("/load crystaljobs", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/unload crystaljobs", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/load soulspire_native", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/unload soulspire_native", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load soulspire_talents", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload soulspire_talents", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load overlords_talents", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload overlords_talents", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load crystalsocket", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload crystalsocket", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load metrics", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload metrics", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load checker", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload checker", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load mobdb", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload mobdb", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load kazenoeye", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload kazenoeye", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load soulspire_gear", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload soulspire_gear", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load overlords_gear", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload overlords_gear", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load overlords_boost", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload overlords_boost", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load soulspire_soul_actions", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload soulspire_soul_actions", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load overlords_soul_actions", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload overlords_soul_actions", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load soulspire_soulhud", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload soulspire_soulhud", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load overlords_soulhud", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload overlords_soulhud", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load soulspire_flintlock", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload soulspire_flintlock", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon load soulspire_core", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals("/addon unload soulspire_core", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.StartsWith("/fps ", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                lines.Add(rawLine);
            }
        }
        else
        {
            lines.Add("# SoulspireXI Ashita v4 startup script");
            lines.Add("/load addons");
            lines.Add("/wait 3");
            lines.Add("/addon load fps");
            lines.Add("/addon load timestamp");
        }

        EnsureLine(lines, "/load addons", insertAtTop: false);

        if (settings.AutoLoadCrystalSocketAddon)
        {
            var addonsIdx = lines.FindIndex(l => l.Trim().Equals("/load addons", StringComparison.OrdinalIgnoreCase));
            if (addonsIdx >= 0)
            {
                lines.Insert(addonsIdx + 1, "/load soulspire_native");
            }
            else
            {
                EnsureLine(lines, "/load soulspire_native", insertAtTop: false);
            }
        }

        if (settings.AutoLoadTalentsAddon)
        {
            EnsureLine(lines, "/addon load soulspire_talents", insertAtTop: false);
        }

        if (settings.AutoLoadCrystalSocketAddon)
        {
            EnsureLine(lines, "/addon load crystalsocket", insertAtTop: false);
        }

        if (settings.AutoLoadMetricsAddon)
        {
            EnsureLine(lines, "/addon load metrics", insertAtTop: false);
        }

        if (settings.AutoLoadCheckerAddon)
        {
            EnsureLine(lines, "/addon load checker", insertAtTop: false);
        }

        if (settings.AutoLoadMobDbAddon)
        {
            EnsureLine(lines, "/addon load mobdb", insertAtTop: false);
        }

        if (settings.AutoLoadKazenoeyeAddon)
        {
            EnsureLine(lines, "/addon load kazenoeye", insertAtTop: false);
        }

        if (settings.AutoLoadGearAddon)
        {
            EnsureLine(lines, "/addon load soulspire_gear", insertAtTop: false);
        }

        if (settings.AutoLoadSoulHudAddon)
        {
            EnsureLine(lines, "/addon load soulspire_soulhud", insertAtTop: false);
        }

        if (settings.AutoLoadFlintlockAddon)
        {
            EnsureLine(lines, "/addon load soulspire_flintlock", insertAtTop: false);
        }

        // Soul Actions is client-only and starts hidden; launch it automatically for everyone.
        // Normalize existing script entries above to prevent duplicate loads on repeat launches.
        EnsureLine(lines, "/addon load soulspire_soul_actions", insertAtTop: false);

        // SoulspireXI Core (Phase 1A): modular UI shell and native-styled Main Menu entry.
        EnsureLine(lines, "/addon load soulspire_core", insertAtTop: false);

        if (applyTestingQolBindings)
        {
            ApplyTestingQolScriptBindings(lines);
        }

        if (settings.FpsCap is 30 or 60 or 0)
        {
            EnsureLine(lines, "/addon load fps", insertAtTop: false);
            var divisor = settings.FpsCap switch
            {
                60 => 1,
                30 => 2,
                _ => 0
            };
            lines.Add($"/fps {divisor}");
        }

        return string.Join(Environment.NewLine, lines).TrimEnd() + Environment.NewLine;
    }

    public void WriteAllConfigs(
        string ashitaDir,
        LauncherSettings settings,
        string serverHost,
        bool useHairpin,
        string? password,
        string xiloaderPath,
        string? manifestChannel = null,
        string? serverName = null)
    {
        var bootDir = Path.Combine(ashitaDir, "config", "boot");
        var pivotDir = Path.Combine(ashitaDir, "config", "pivot");
        var scriptsDir = Path.Combine(ashitaDir, "scripts");
        var datsRoot = Path.Combine(ashitaDir, "polplugins", "DATs");

        Directory.CreateDirectory(bootDir);
        Directory.CreateDirectory(pivotDir);
        Directory.CreateDirectory(scriptsDir);
        Directory.CreateDirectory(Path.Combine(datsRoot, OverlayFolderName));

        CapturePlayerInputPreferencesIfUnmanaged(ashitaDir, settings);

        var effectiveInput = TestingEnvironmentQolPolicy.ResolveInputSettings(
            settings,
            serverHost,
            manifestChannel,
            serverName);

        var bootIniPath = Path.Combine(bootDir, BootConfigFileName);
        var bootIni = BuildBootIniContent(
            settings,
            serverHost,
            useHairpin,
            password,
            xiloaderPath,
            manifestChannel,
            serverName);
        File.WriteAllText(bootIniPath, bootIni, new UTF8Encoding(false));

        var pivotIniPath = Path.Combine(pivotDir, $"{PivotConfigName}.ini");
        if (settings.EnablePivotOverlay)
        {
            if (settings.EnableFlintlockDualPistolsOverlay)
            {
                Directory.CreateDirectory(Path.Combine(datsRoot, FlintlockOverlayFolderName));
            }

            var pivotIni = BuildPivotIniContent(datsRoot, settings.EnableFlintlockDualPistolsOverlay);
            File.WriteAllText(pivotIniPath, pivotIni, new UTF8Encoding(false));
        }
        else if (File.Exists(pivotIniPath))
        {
            // Clear any previously enabled optional Flintlock overlay so disabling Pivot never leaves stale config on disk.
            var pivotIni = BuildPivotIniContent(datsRoot, enableFlintlockOverlay: false);
            File.WriteAllText(pivotIniPath, pivotIni, new UTF8Encoding(false));
        }

        var scriptPath = Path.Combine(scriptsDir, ScriptFileName);
        string? existingScript = File.Exists(scriptPath) ? File.ReadAllText(scriptPath, Encoding.UTF8) : null;
        if (existingScript is null)
        {
            var legacyScriptPath = Path.Combine(scriptsDir, LegacyScriptFileName);
            if (File.Exists(legacyScriptPath))
            {
                existingScript = File.ReadAllText(legacyScriptPath, Encoding.UTF8);
            }
            else
            {
                var defaultScriptPath = Path.Combine(scriptsDir, "default.txt");
                if (File.Exists(defaultScriptPath))
                {
                    existingScript = File.ReadAllText(defaultScriptPath, Encoding.UTF8);
                }
            }
        }

        var mergedScript = MergeBootScriptContent(
            existingScript,
            settings,
            applyTestingQolBindings: effectiveInput.TestingQolApplied);
        File.WriteAllText(scriptPath, mergedScript, new UTF8Encoding(false));
    }

    private static void ApplyTestingQolScriptBindings(List<string> lines)
    {
        var missingLines = new List<string>();

        var hasScreenshotPlugin = lines.Any(l =>
        {
            var t = l.Trim();
            return t.Equals(DefaultScreenshotLoadLine, StringComparison.OrdinalIgnoreCase) ||
                   t.Equals("/unload screenshot", StringComparison.OrdinalIgnoreCase);
        });
        if (!hasScreenshotPlugin)
        {
            missingLines.Add(DefaultScreenshotLoadLine);
        }

        if (!HasBindToCommand(lines, "/screenshot"))
        {
            missingLines.Add(DefaultScreenshotBindLine);
        }

        if (!HasBindToCommand(lines, "/paste"))
        {
            missingLines.Add(DefaultClipboardPasteBindLine);
        }

        if (missingLines.Count == 0)
        {
            return;
        }

        var block = new List<string>(missingLines.Count + 2)
        {
            TestingQolScriptStartMarker
        };
        block.AddRange(missingLines);
        block.Add(TestingQolScriptEndMarker);

        var waitIdx = lines.FindIndex(l => l.TrimStart().StartsWith("/wait ", StringComparison.OrdinalIgnoreCase));
        if (waitIdx >= 0)
        {
            lines.InsertRange(waitIdx, block);
            return;
        }

        var addonsIdx = lines.FindIndex(l => l.Trim().Equals("/load addons", StringComparison.OrdinalIgnoreCase));
        if (addonsIdx >= 0)
        {
            var insertIdx = addonsIdx + 1;
            if (insertIdx < lines.Count &&
                lines[insertIdx].Trim().Equals("/load soulspire_native", StringComparison.OrdinalIgnoreCase))
            {
                insertIdx++;
            }

            lines.InsertRange(insertIdx, block);
            return;
        }

        lines.AddRange(block);
    }

    private static bool HasBindToCommand(IEnumerable<string> lines, string targetCommand)
    {
        foreach (var rawLine in lines)
        {
            var trimmed = rawLine.Trim();
            if (!trimmed.StartsWith("/bind ", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var tokens = trimmed.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (tokens.Length >= 3 &&
                tokens[2].Equals(targetCommand, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static void EnsureLine(List<string> lines, string expectedLine, bool insertAtTop)
    {
        var exists = lines.Any(l => l.Trim().Equals(expectedLine, StringComparison.OrdinalIgnoreCase));
        if (!exists)
        {
            if (insertAtTop)
            {
                lines.Insert(0, expectedLine);
            }
            else
            {
                lines.Add(expectedLine);
            }
        }
    }

    private static string QuoteIfNeeded(string value)
    {
        if (value.Contains(' ') || value.Contains('"'))
        {
            return $"\"{value.Replace("\"", "\\\"")}\"";
        }

        return value;
    }
}

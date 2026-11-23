using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using Microsoft.Win32;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class FfxiInstallDetector
{
    private static readonly (string KeyPath, string Region)[] RegistryInstallKeys =
    [
        (@"SOFTWARE\PlayOnlineUS\InstallFolder", "US"),
        (@"SOFTWARE\PlayOnlineEU\InstallFolder", "EU"),
        (@"SOFTWARE\PlayOnline\InstallFolder", "JP")
    ];

    public InstallDiagnostics Inspect(LauncherSettings settings, LauncherManifest manifest)
    {
        var diag = new InstallDiagnostics();

        var (detectedFfxi, detectedPol, region) = DetectFfxiFromRegistryOrCommonPaths();
        if (!string.IsNullOrWhiteSpace(settings.FfxiPath) && Directory.Exists(settings.FfxiPath))
        {
            diag.FfxiDetected = File.Exists(Path.Combine(settings.FfxiPath, "FFXiMain.dll")) ||
                                Directory.Exists(Path.Combine(settings.FfxiPath, "ROM"));
            diag.DetectedFfxiPath = settings.FfxiPath;
            diag.DetectedPolPath = detectedPol;
            diag.FfxiRegion = region != "Unknown" ? region : settings.Language;
        }
        else if (!string.IsNullOrWhiteSpace(detectedFfxi))
        {
            diag.FfxiDetected = true;
            diag.DetectedFfxiPath = detectedFfxi;
            diag.DetectedPolPath = detectedPol;
            diag.FfxiRegion = region;
        }

        var ashitaDir = settings.AshitaPath;
        diag.AshitaInstalled = !string.IsNullOrWhiteSpace(ashitaDir) &&
                               File.Exists(Path.Combine(ashitaDir, "Ashita-cli.exe"));

        diag.XiloaderPath = ResolveXiloaderPath(ashitaDir);
        diag.XiloaderInstalled = !string.IsNullOrEmpty(diag.XiloaderPath);

        diag.PivotPluginInstalled = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                    File.Exists(Path.Combine(ashitaDir, "polplugins", "pivot.dll"));

        diag.TalentsAddonSynced = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                  File.Exists(Path.Combine(ashitaDir, "addons", "soulspire_talents", "soulspire_talents.lua"));

        diag.CrystalSocketAddonSynced = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                        File.Exists(Path.Combine(ashitaDir, "addons", "crystalsocket", "crystalsocket.lua")) &&
                                        File.Exists(Path.Combine(ashitaDir, "addons", "crystalsocket", "job_labels.lua")) &&
                                        (File.Exists(Path.Combine(ashitaDir, "plugins", "soulspire_native.dll")) ||
                                         File.Exists(Path.Combine(ashitaDir, "plugins", "crystaljobs.dll")));

        diag.MetricsAddonSynced = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                  File.Exists(Path.Combine(ashitaDir, "addons", "metrics", "metrics.lua"));

        diag.CheckerAddonInstalled = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                     File.Exists(Path.Combine(ashitaDir, "addons", "checker", "checker.lua"));

        diag.MobDbAddonSynced = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                File.Exists(Path.Combine(ashitaDir, "addons", "mobdb", "mobdb.lua"));

        diag.KazenoeyeAddonSynced = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                    File.Exists(Path.Combine(ashitaDir, "addons", "kazenoeye", "kazenoeye.lua")) &&
                                    File.Exists(Path.Combine(ashitaDir, "addons", "kazenoeye", "assets", "icons", "0.png")) &&
                                    File.Exists(Path.Combine(ashitaDir, "addons", "kazenoeye", "util", "debuffhandler.lua"));

        diag.GearAddonSynced = !string.IsNullOrWhiteSpace(ashitaDir) &&
                               File.Exists(Path.Combine(ashitaDir, "addons", "soulspire_gear", "soulspire_gear.lua")) &&
                               File.Exists(Path.Combine(ashitaDir, "addons", "soulspire_gear", "data", "items.lua"));

        var datFiles = manifest.Files.Where(f => f.Category == "dat").ToList();
        diag.DatOverlaySynced = !string.IsNullOrWhiteSpace(ashitaDir) &&
                                datFiles.Count > 0 &&
                                datFiles.All(f => File.Exists(Path.Combine(
                                    ashitaDir,
                                    "polplugins",
                                    "DATs",
                                    AshitaConfigGenerator.OverlayFolderName,
                                    f.TargetPath.Replace('/', Path.DirectorySeparatorChar))));

        diag.DirectPlayEnabled = CheckDirectPlayPresent();
        diag.VcRedistX86Present = CheckVcRedistX86Present();

        PopulateNativeDllDiagnostics(diag, settings, manifest);

        return diag;
    }

    public static void PopulateNativeDllDiagnostics(
        InstallDiagnostics diag,
        LauncherSettings settings,
        LauncherManifest? manifest,
        bool inspectRunningProcess = true)
    {
        diag.NativeSelectedChannel = settings.UpdateChannel switch
        {
            UpdateChannel.Stable => "Stable",
            UpdateChannel.Testing => "Testing (27-Hook Weapon Templates)",
            UpdateChannel.TestingRegistry24Hook => "Testing B — Registry 24-Hook (Current menu2fon)",
            UpdateChannel.TestingSearchLegacyText => "Testing A — Search Legacy native_text (4f0fdb3)",
            UpdateChannel.TestingSearchAlignedText => "Testing C — Search Aligned native_text (Repair)",
            UpdateChannel.TestingCoreUi => "Testing — SoulspireXI Core UI & Gamepad",
            _ => settings.UpdateChannel.ToString()
        };

        var dllEntry = manifest?.Files.FirstOrDefault(f =>
            f.Category.Equals("plugin", StringComparison.OrdinalIgnoreCase) &&
            f.TargetPath.Replace('\\', '/').EndsWith("soulspire_native.dll", StringComparison.OrdinalIgnoreCase))
            ?? manifest?.Files.FirstOrDefault(f =>
            f.Category.Equals("plugin", StringComparison.OrdinalIgnoreCase) &&
            f.TargetPath.Replace('\\', '/').EndsWith("crystaljobs.dll", StringComparison.OrdinalIgnoreCase));

        var expectedDllFileName = "soulspire_native.dll";
        if (dllEntry is not null &&
            dllEntry.TargetPath.Replace('\\', '/').EndsWith("crystaljobs.dll", StringComparison.OrdinalIgnoreCase))
        {
            expectedDllFileName = "crystaljobs.dll";
        }
        else if (dllEntry is null && !string.IsNullOrWhiteSpace(settings.AshitaPath) &&
                 !File.Exists(Path.Combine(settings.AshitaPath, "plugins", "soulspire_native.dll")) &&
                 File.Exists(Path.Combine(settings.AshitaPath, "plugins", "crystaljobs.dll")))
        {
            expectedDllFileName = "crystaljobs.dll";
        }

        var dllPath = string.IsNullOrWhiteSpace(settings.AshitaPath)
            ? string.Empty
            : Path.Combine(settings.AshitaPath, "plugins", expectedDllFileName);
        diag.NativeDllFilePath = string.IsNullOrWhiteSpace(dllPath) ? "UNKNOWN (Ashita path not set)" : dllPath;

        var expectedSha = dllEntry?.Sha256?.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(expectedSha))
        {
            expectedSha = manifest?.Registry?.NativeDllSha256?.Trim().ToLowerInvariant();
        }
        diag.NativeExpectedDllSha256 = string.IsNullOrWhiteSpace(expectedSha) ? "UNKNOWN" : expectedSha;

        var compiledHash = manifest?.Registry?.NativeDllCompiledHash?.Trim();
        diag.NativeRegistryCompiledHash = string.IsNullOrWhiteSpace(compiledHash) ? "UNKNOWN" : compiledHash;

        var hookCount = manifest?.Registry?.NativeHooks
            ?? manifest?.Registry?.CrystalJobsHooks
            ?? manifest?.ServerCompatibility?.NativeHooks
            ?? manifest?.ServerCompatibility?.CrystalJobsHooks;
        diag.NativeHookCount = hookCount is > 0 ? hookCount.Value.ToString() : "UNKNOWN";

        if (string.IsNullOrWhiteSpace(dllPath) || !File.Exists(dllPath))
        {
            diag.NativeInstalledDllSha256 = "MISSING";
            diag.NativeDllSha256Status = "FAIL";
            diag.NativeDllArchitecture = "UNKNOWN (file missing)";
            diag.NativeDllArchitectureStatus = "FAIL";
        }
        else
        {
            try
            {
                using var stream = new FileStream(dllPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                var sha = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
                diag.NativeInstalledDllSha256 = sha;

                if (string.IsNullOrWhiteSpace(expectedSha))
                {
                    diag.NativeDllSha256Status = "UNKNOWN";
                }
                else
                {
                    diag.NativeDllSha256Status = sha.Equals(expectedSha, StringComparison.OrdinalIgnoreCase)
                        ? "PASS"
                        : "FAIL";
                }

                stream.Position = 0;
                var (archStatus, archLabel) = InspectPeArchitectureReadOnly(stream);
                diag.NativeDllArchitectureStatus = archStatus;
                diag.NativeDllArchitecture = archLabel;
            }
            catch (Exception ex)
            {
                diag.NativeInstalledDllSha256 = $"UNREADABLE ({ex.Message})";
                diag.NativeDllSha256Status = "UNKNOWN";
                diag.NativeDllArchitecture = "UNKNOWN";
                diag.NativeDllArchitectureStatus = "UNKNOWN";
            }
        }

        if (!inspectRunningProcess)
        {
            diag.NativeLoadedModuleStatus = "UNKNOWN";
            diag.NativeLoadedModuleDetail = "Process inspection skipped";
            return;
        }

        InspectLoadedCrystalJobsModule(diag, dllPath);
    }

    private static (string Status, string Label) InspectPeArchitectureReadOnly(Stream stream)
    {
        try
        {
            if (stream.Length < 64)
            {
                return ("FAIL", "Invalid PE (file too small)");
            }

            using var reader = new BinaryReader(stream, System.Text.Encoding.ASCII, leaveOpen: true);
            if (reader.ReadUInt16() != 0x5A4D) // MZ
            {
                return ("FAIL", "Invalid PE (missing MZ header)");
            }

            stream.Position = 0x3C;
            var peOffset = reader.ReadInt32();
            if (peOffset < 0 || peOffset + 6 > stream.Length)
            {
                return ("FAIL", "Invalid PE (bad e_lfanew)");
            }

            stream.Position = peOffset;
            if (reader.ReadUInt32() != 0x00004550) // PE\0\0
            {
                return ("FAIL", "Invalid PE (missing PE signature)");
            }

            var machine = reader.ReadUInt16();
            return machine switch
            {
                0x014C => ("PASS", "PE32 x86 (0x014C)"),
                0x8664 => ("FAIL", "PE32+ x64 (0x8664 — expected x86)"),
                _ => ("FAIL", $"Unexpected PE machine (0x{machine:X4})")
            };
        }
        catch
        {
            return ("UNKNOWN", "UNKNOWN");
        }
    }

    private static void InspectLoadedCrystalJobsModule(InstallDiagnostics diag, string expectedDllPath)
    {
        try
        {
            var polProcesses = Process.GetProcessesByName("pol");
            if (polProcesses.Length == 0)
            {
                diag.NativeLoadedModuleStatus = "UNKNOWN";
                diag.NativeLoadedModuleDetail = "FFXI / pol.exe is not running";
                return;
            }

            try
            {
                foreach (var proc in polProcesses)
                {
                    try
                    {
                        ProcessModule? nativeMod = null;
                        ProcessModule? legacyMod = null;
                        foreach (ProcessModule mod in proc.Modules)
                        {
                            if (mod.ModuleName.Equals("soulspire_native.dll", StringComparison.OrdinalIgnoreCase))
                            {
                                nativeMod = mod;
                            }
                            else if (mod.ModuleName.Equals("crystaljobs.dll", StringComparison.OrdinalIgnoreCase))
                            {
                                legacyMod = mod;
                            }
                        }

                        if (nativeMod is not null && legacyMod is not null)
                        {
                            diag.NativeLoadedModuleStatus = "FAIL";
                            diag.NativeLoadedModuleDetail = $"CONFLICT: both soulspire_native.dll and legacy crystaljobs.dll loaded in pol.exe (PID {proc.Id})";
                            return;
                        }

                        var activeMod = nativeMod ?? legacyMod;
                        if (activeMod is not null)
                        {
                            var loadedPath = activeMod.FileName ?? string.Empty;
                            if (!string.IsNullOrWhiteSpace(expectedDllPath) &&
                                loadedPath.Equals(expectedDllPath, StringComparison.OrdinalIgnoreCase))
                            {
                                diag.NativeLoadedModuleStatus = "PASS";
                                diag.NativeLoadedModuleDetail = $"Loaded {activeMod.ModuleName} in pol.exe (PID {proc.Id}) from expected path";
                            }
                            else
                            {
                                diag.NativeLoadedModuleStatus = "FAIL";
                                diag.NativeLoadedModuleDetail = $"Loaded {activeMod.ModuleName} in pol.exe (PID {proc.Id}) from unexpected path: {loadedPath}";
                            }
                            return;
                        }

                        diag.NativeLoadedModuleStatus = "FAIL";
                        diag.NativeLoadedModuleDetail = $"pol.exe (PID {proc.Id}) running, but soulspire_native.dll not observed in loaded modules";
                        return;
                    }
                    catch
                    {
                        diag.NativeLoadedModuleStatus = "UNKNOWN";
                        diag.NativeLoadedModuleDetail = $"pol.exe (PID {proc.Id}) running; module list not observable (permissions/WOW64)";
                        return;
                    }
                }
            }
            finally
            {
                foreach (var proc in polProcesses)
                {
                    proc.Dispose();
                }
            }
        }
        catch
        {
            diag.NativeLoadedModuleStatus = "UNKNOWN";
            diag.NativeLoadedModuleDetail = "Unable to query running processes";
        }
    }

    public static string ResolveXiloaderPath(string ashitaDir)
    {
        if (string.IsNullOrWhiteSpace(ashitaDir))
        {
            return string.Empty;
        }

        var candidates = new[]
        {
            Path.Combine(ashitaDir, "bootloader", "xiloader.exe"),
            Path.Combine(ashitaDir, "xiloader.exe"),
            Path.Combine(AppContext.BaseDirectory, "xiloader.exe")
        };

        return candidates.FirstOrDefault(File.Exists) ?? string.Empty;
    }

    private static (string FfxiPath, string PolPath, string Region) DetectFfxiFromRegistryOrCommonPaths()
    {
        foreach (var view in new[] { RegistryView.Registry32, RegistryView.Registry64 })
        {
            foreach (var (keyPath, region) in RegistryInstallKeys)
            {
                try
                {
                    using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view);
                    using var subKey = baseKey.OpenSubKey(keyPath);
                    if (subKey is null)
                    {
                        continue;
                    }

                    var ffxi = (subKey.GetValue("0001") as string)?.TrimEnd('\\', '/');
                    var pol = (subKey.GetValue("1000") as string)?.TrimEnd('\\', '/');
                    if (!string.IsNullOrWhiteSpace(ffxi) && Directory.Exists(ffxi))
                    {
                        return (ffxi!, pol ?? string.Empty, region);
                    }
                }
                catch
                {
                    // Ignore registry access exceptions.
                }
            }
        }

        var commonDirs = new[]
        {
            @"C:\Program Files (x86)\PlayOnline\SquareEnix\FINAL FANTASY XI",
            @"C:\PlayOnline\SquareEnix\FINAL FANTASY XI",
            @"D:\PlayOnline\SquareEnix\FINAL FANTASY XI"
        };

        foreach (var dir in commonDirs)
        {
            if (Directory.Exists(dir))
            {
                return (dir, string.Empty, "US");
            }
        }

        return (string.Empty, string.Empty, "Unknown");
    }

    private static bool CheckDirectPlayPresent()
    {
        try
        {
            var sysWow64 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "SysWOW64", "dplayx.dll");
            var sys32 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "dplayx.dll");
            if (File.Exists(sysWow64) || File.Exists(sys32))
            {
                return true;
            }

            using var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32)
                .OpenSubKey(@"SOFTWARE\Microsoft\DirectPlay");
            return key is not null;
        }
        catch
        {
            return false;
        }
    }

    private static bool CheckVcRedistX86Present()
    {
        try
        {
            var sysWow64 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "SysWOW64", "vcruntime140.dll");
            var sys32 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "vcruntime140.dll");
            return File.Exists(sysWow64) || File.Exists(sys32);
        }
        catch
        {
            return false;
        }
    }
}

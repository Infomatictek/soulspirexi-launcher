using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed record ModernSignatureScanSummary(
    string FfxiMainInfo,
    int MatchedCount,
    int FailedCount,
    IReadOnlyList<string> FailedLines,
    IReadOnlyList<string> RendererLines);

public sealed record ModernDiagnosticsExportResult(
    bool Success,
    string ZipPath,
    long ByteSize,
    string SummaryText,
    IReadOnlyList<string> IncludedFiles);

/// <summary>
/// Collects and exports a one-click, secret-redacted diagnostic ZIP bundle for Modern (VanaCore)
/// client sessions: VanaCore logs, Soulspire Native logs, signature scan results, crash inventory,
/// build provenance, GPU/renderer info, and sanitized configuration.
/// </summary>
public sealed class ModernClientDiagnosticsService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private static readonly Regex SecretKeyValueRegex = new(
        @"(?im)^(\s*(?:password|pass|pwd|secret|token|auth_token|api_key|session_hash)\s*[=:]\s*)(.+)$",
        RegexOptions.Compiled);

    private static readonly Regex CliSecretArgRegex = new(
        @"(?i)(--(?:pass|password|token|secret)\s+)(?:""[^""]*""|\S+)",
        RegexOptions.Compiled);

    private static readonly Regex BearerRegex = new(
        @"(?i)(Bearer\s+)[A-Za-z0-9._\-~+/=]+",
        RegexOptions.Compiled);

    private static readonly Regex GhTokenRegex = new(
        @"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]+\b",
        RegexOptions.Compiled);

    public string ExportDirectory { get; }

    public ModernClientDiagnosticsService(string? exportDirectory = null)
    {
        ExportDirectory = string.IsNullOrWhiteSpace(exportDirectory)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SoulspireXI",
                "Diagnostics")
            : exportDirectory;
    }

    public static string RedactSensitiveText(string raw, string? currentPassword = null)
    {
        if (string.IsNullOrEmpty(raw))
        {
            return string.Empty;
        }

        var text = raw;
        if (!string.IsNullOrEmpty(currentPassword) && currentPassword.Length >= 3)
        {
            text = text.Replace(currentPassword, "[REDACTED_PASSWORD]", StringComparison.Ordinal);
        }

        text = SecretKeyValueRegex.Replace(text, "$1[REDACTED]");
        text = CliSecretArgRegex.Replace(text, "$1[REDACTED]");
        text = BearerRegex.Replace(text, "$1[REDACTED]");
        text = GhTokenRegex.Replace(text, "[REDACTED_TOKEN]");
        return text;
    }

    public static ModernSignatureScanSummary ParseVanaCoreLog(string? logText)
    {
        if (string.IsNullOrWhiteSpace(logText))
        {
            return new ModernSignatureScanSummary("Not recorded yet (no logs\\vanacore.log found)", 0, 0, [], []);
        }

        var ffxiInfo = "Not reported";
        var matched = 0;
        var failed = 0;
        var failedLines = new List<string>();
        var rendererLines = new List<string>();

        using var reader = new StringReader(logText);
        string? line;
        while ((line = reader.ReadLine()) is not null)
        {
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed))
            {
                continue;
            }

            if (trimmed.Contains("FFXiMain", StringComparison.OrdinalIgnoreCase) &&
                (trimmed.Contains("0x", StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Contains("timestamp", StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Contains("version", StringComparison.OrdinalIgnoreCase)))
            {
                ffxiInfo = trimmed;
            }

            if (trimmed.Contains("sig", StringComparison.OrdinalIgnoreCase) ||
                trimmed.Contains("pattern", StringComparison.OrdinalIgnoreCase) ||
                trimmed.Contains("hook", StringComparison.OrdinalIgnoreCase))
            {
                if (trimmed.Contains("miss", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Contains("fail", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Contains("not found", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Contains("error", StringComparison.OrdinalIgnoreCase))
                {
                    failed++;
                    if (failedLines.Count < 40)
                    {
                        failedLines.Add(trimmed);
                    }
                }
                else if (trimmed.Contains("found", StringComparison.OrdinalIgnoreCase) ||
                         trimmed.Contains("matched", StringComparison.OrdinalIgnoreCase) ||
                         trimmed.Contains("installed", StringComparison.OrdinalIgnoreCase) ||
                         trimmed.Contains("ok", StringComparison.OrdinalIgnoreCase))
                {
                    matched++;
                }
            }

            if ((trimmed.Contains("d3d12", StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Contains("d3d11", StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Contains("adapter", StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Contains("renderer", StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Contains("gpu", StringComparison.OrdinalIgnoreCase)) &&
                rendererLines.Count < 20)
            {
                rendererLines.Add(trimmed);
            }
        }

        return new ModernSignatureScanSummary(ffxiInfo, matched, failed, failedLines, rendererLines);
    }

    public static IReadOnlyList<string> DetectGpuAdapters()
    {
        var gpus = new List<string>();
        if (!OperatingSystem.IsWindows())
        {
            return gpus;
        }

        try
        {
            using var displayClass = Registry.LocalMachine.OpenSubKey(
                @"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}");
            if (displayClass is not null)
            {
                foreach (var subName in displayClass.GetSubKeyNames())
                {
                    if (subName.Length != 4 || !subName.All(char.IsDigit))
                    {
                        continue;
                    }

                    try
                    {
                        using var adapterKey = displayClass.OpenSubKey(subName);
                        var desc = adapterKey?.GetValue("DriverDesc") as string;
                        var driverVer = adapterKey?.GetValue("DriverVersion") as string;
                        if (!string.IsNullOrWhiteSpace(desc))
                        {
                            var label = string.IsNullOrWhiteSpace(driverVer) ? desc.Trim() : $"{desc.Trim()} (Driver {driverVer.Trim()})";
                            if (!gpus.Contains(label, StringComparer.OrdinalIgnoreCase))
                            {
                                gpus.Add(label);
                            }
                        }
                    }
                    catch
                    {
                        // Ignore unreadable subkeys.
                    }
                }
            }
        }
        catch
        {
            // Ignore registry query failures.
        }

        return gpus;
    }

    public ModernDiagnosticsExportResult ExportBundle(
        string profileDir,
        ClientEngineMode mode,
        LauncherSettings settings,
        string launcherVersion,
        string? currentPassword = null)
    {
        Directory.CreateDirectory(ExportDirectory);
        var profileName = ModernClientConfigGenerator.GetProfileFolderName(mode);
        var stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
        var zipPath = Path.Combine(ExportDirectory, $"soulspire-modern-diagnostics-{profileName}-{stamp}.zip");

        var included = new List<string>();
        var vanacoreLogPath = Path.Combine(profileDir, "logs", "vanacore.log");
        string? redactedVanaLog = null;
        if (File.Exists(vanacoreLogPath))
        {
            redactedVanaLog = RedactSensitiveText(ReadSharedText(vanacoreLogPath), currentPassword);
        }

        var nativeLogCandidates = new[]
        {
            Path.Combine(profileDir, "logs", "soulspire_native.log"),
            Path.Combine(profileDir, "plugins", "ashita", "soulspire_native.log"),
            Path.Combine(profileDir, "plugins", "ashita", "data", "soulspire_native.log"),
            Path.Combine(profileDir, "plugins", "soulspire_native.log"),
            Path.Combine(profileDir, "soulspire_native.log")
        };
        var nativeLogPath = nativeLogCandidates.FirstOrDefault(File.Exists);
        string? redactedNativeLog = nativeLogPath is not null
            ? RedactSensitiveText(ReadSharedText(nativeLogPath), currentPassword)
            : null;

        var sigSummary = ParseVanaCoreLog(redactedVanaLog);
        var installState = ModernClientInstallService.LoadState(profileDir);

        var crashFiles = new List<object>();
        if (Directory.Exists(profileDir))
        {
            foreach (var f in Directory.EnumerateFiles(profileDir, "*", SearchOption.AllDirectories))
            {
                var ext = Path.GetExtension(f);
                var name = Path.GetFileName(f);
                if (ext.Equals(".dmp", StringComparison.OrdinalIgnoreCase) ||
                    ext.Equals(".mdmp", StringComparison.OrdinalIgnoreCase) ||
                    name.Contains("crash", StringComparison.OrdinalIgnoreCase))
                {
                    var fi = new FileInfo(f);
                    crashFiles.Add(new
                    {
                        relativePath = Path.GetRelativePath(profileDir, f).Replace('\\', '/'),
                        sizeBytes = fi.Length,
                        lastWriteUtc = fi.LastWriteTimeUtc
                    });
                }
            }
        }

        var summaryObj = new
        {
            schemaVersion = "1.0.0",
            exportedUtc = DateTimeOffset.UtcNow,
            launcherVersion,
            engineMode = mode.ToString(),
            profile = profileName,
            runtimeCertified = false,
            configuredRenderer = settings.ModernClientUseD3D11Fallback ? "d3d11" : "d3d12",
            osDescription = RuntimeInformation.OSDescription,
            osArchitecture = RuntimeInformation.OSArchitecture.ToString(),
            gpuAdapters = DetectGpuAdapters(),
            installedPackage = installState,
            signatureScan = sigSummary,
            hasVanaCoreLog = redactedVanaLog is not null,
            hasNativeDllLog = redactedNativeLog is not null,
            crashArtifacts = crashFiles
        };

        using (var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create))
        {
            WriteZipText(archive, "diagnostics-summary.json", JsonSerializer.Serialize(summaryObj, JsonOptions));
            included.Add("diagnostics-summary.json");

            if (redactedVanaLog is not null)
            {
                WriteZipText(archive, "logs/vanacore.log", redactedVanaLog);
                included.Add("logs/vanacore.log");
            }

            if (redactedNativeLog is not null)
            {
                WriteZipText(archive, "logs/soulspire_native.log", redactedNativeLog);
                included.Add("logs/soulspire_native.log");
            }

            var provenancePath = Path.Combine(profileDir, "build-provenance.json");
            if (File.Exists(provenancePath))
            {
                WriteZipText(archive, "build-provenance.json", RedactSensitiveText(ReadSharedText(provenancePath), currentPassword));
                included.Add("build-provenance.json");
            }

            var iniFileName = ModernClientConfigGenerator.GetAccountIniFileName(settings.Username);
            var iniPath = Path.Combine(profileDir, iniFileName);
            if (!File.Exists(iniPath))
            {
                iniPath = Path.Combine(profileDir, ModernClientConfigGenerator.DefaultIniFileName);
            }
            if (File.Exists(iniPath))
            {
                WriteZipText(archive, "config/vanacore.redacted.ini", RedactSensitiveText(ReadSharedText(iniPath), currentPassword));
                included.Add("config/vanacore.redacted.ini");
            }

            var bootPath = Path.Combine(profileDir, ModernClientConfigGenerator.BootScriptRelativePath);
            if (File.Exists(bootPath))
            {
                WriteZipText(archive, "config/boot.txt", RedactSensitiveText(ReadSharedText(bootPath), currentPassword));
                included.Add("config/boot.txt");
            }
        }

        var size = new FileInfo(zipPath).Length;
        var summaryText = $"Exported redacted Modern ({profileName}) diagnostics ({included.Count} files, {size / 1024.0:F1} KB; " +
                          $"sigs matched={sigSummary.MatchedCount}, failed={sigSummary.FailedCount}, crashes={crashFiles.Count}).";
        return new ModernDiagnosticsExportResult(true, zipPath, size, summaryText, included);
    }

    private static string ReadSharedText(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var sr = new StreamReader(fs, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return sr.ReadToEnd();
    }

    private static void WriteZipText(ZipArchive archive, string entryName, string content)
    {
        var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(content);
    }
}

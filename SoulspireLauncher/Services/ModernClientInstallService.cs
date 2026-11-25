using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class InstalledModernClientState
{
    [JsonPropertyName("profile")]
    public string Profile { get; set; } = string.Empty;

    [JsonPropertyName("version")]
    public string Version { get; set; } = string.Empty;

    [JsonPropertyName("tag")]
    public string Tag { get; set; } = string.Empty;

    [JsonPropertyName("commitSha")]
    public string CommitSha { get; set; } = string.Empty;

    [JsonPropertyName("packageSha256")]
    public string PackageSha256 { get; set; } = string.Empty;

    [JsonPropertyName("installedUtc")]
    public DateTimeOffset InstalledUtc { get; set; } = DateTimeOffset.UtcNow;
}

public sealed record ModernInstallResult(
    bool Downloaded,
    bool UpToDate,
    string ProfileDirectory,
    string ExecutablePath,
    InstalledModernClientState? State);

/// <summary>
/// Automatically downloads, SHA-256 verifies, installs, snapshots for rollback, and updates
/// isolated Modern (VanaCore) client profiles (ModernClient\baseline\ and ModernClient\compat\)
/// without ever modifying Classic Ashita v4 or retail FFXI installations.
/// </summary>
public sealed class ModernClientInstallService
{
    public const string StateFileName = ".soulspire-modern-state.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _http;

    public ModernClientInstallService(HttpClient? httpClient = null)
    {
        _http = httpClient ?? ManifestUpdateService.CreateDefaultHttpClient();
    }

    public static InstalledModernClientState? LoadState(string profileDir)
    {
        var path = Path.Combine(profileDir, StateFileName);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            return JsonSerializer.Deserialize<InstalledModernClientState>(File.ReadAllText(path, Encoding.UTF8), JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    public static bool IsUpToDate(string profileDir, ManifestModernClientPackage package)
    {
        if (GameLaunchService.ResolveModernClientExecutable(profileDir) is null)
        {
            return false;
        }

        if (!File.Exists(Path.Combine(profileDir, "VanaCore.Core.dll")) &&
            !File.Exists(Path.Combine(profileDir, "SoulspireClient.Core.dll")))
        {
            return false;
        }

        var state = LoadState(profileDir);
        if (state is null || string.IsNullOrWhiteSpace(package.PackageSha256))
        {
            return false;
        }

        return state.PackageSha256.Equals(package.PackageSha256.Trim(), StringComparison.OrdinalIgnoreCase);
    }

    public async Task<ModernInstallResult> EnsureInstalledAsync(
        string profileDir,
        ManifestModernClientPackage package,
        bool forceReinstall = false,
        IProgress<SyncProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(profileDir))
        {
            throw new ArgumentException("Modern client profile directory must be specified.", nameof(profileDir));
        }

        if (string.IsNullOrWhiteSpace(package.PackageUrl))
        {
            throw new InvalidOperationException($"Modern client profile '{package.Profile}' does not declare a download packageUrl in the manifest.");
        }

        var expectedSha = (package.PackageSha256 ?? string.Empty).Trim().ToLowerInvariant();
        if (expectedSha.Length != 64 || !expectedSha.All(Uri.IsHexDigit))
        {
            throw new InvalidOperationException($"Refusing unverified Modern client package '{package.Profile}': missing valid SHA-256 checksum.");
        }

        Directory.CreateDirectory(profileDir);

        if (!forceReinstall && IsUpToDate(profileDir, package))
        {
            var existingExe = GameLaunchService.ResolveModernClientExecutable(profileDir)!;
            return new ModernInstallResult(false, true, profileDir, existingExe, LoadState(profileDir));
        }

        progress?.Report(new SyncProgress
        {
            Message = $"Downloading Modern ({package.Profile}) client package ({package.Tag})...",
            Percent = 10
        });

        var tempZip = Path.Combine(profileDir, $".download-{Guid.NewGuid():N}.zip.tmp");
        try
        {
            using (var response = await _http.GetAsync(package.PackageUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();
                var totalBytes = response.Content.Headers.ContentLength ?? package.PackageSize;
                await using var netStream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                await using var fileStream = new FileStream(tempZip, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true);

                var buffer = new byte[81920];
                long downloaded = 0;
                int read;
                while ((read = await netStream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    await fileStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    downloaded += read;
                    if (totalBytes > 0)
                    {
                        var pct = 10.0 + Math.Min(60.0, (downloaded / (double)totalBytes) * 60.0);
                        progress?.Report(new SyncProgress
                        {
                            Message = $"Downloading Modern ({package.Profile}): {downloaded / (1024.0 * 1024.0):F1} / {totalBytes / (1024.0 * 1024.0):F1} MB",
                            Percent = pct
                        });
                    }
                }
            }

            progress?.Report(new SyncProgress
            {
                Message = $"Verifying SHA-256 checksum for Modern ({package.Profile}) package...",
                Percent = 75
            });

            var actualSha = ComputeSha256(tempZip);
            if (!actualSha.Equals(expectedSha, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    $"SHA-256 verification FAILED for Modern ({package.Profile}) package! " +
                    $"Expected {expectedSha}, got {actualSha}. Installation aborted.");
            }

            progress?.Report(new SyncProgress
            {
                Message = $"Installing verified Modern ({package.Profile}) client into isolated folder...",
                Percent = 85
            });

            ModernClientConfigGenerator.CreateRollbackSnapshot(profileDir);
            try
            {
                ExtractPackageArchiveSafely(tempZip, profileDir);
            }
            catch
            {
                ModernClientConfigGenerator.RestoreRollbackSnapshot(profileDir);
                throw;
            }

            var installedExe = GameLaunchService.ResolveModernClientExecutable(profileDir);
            if (string.IsNullOrWhiteSpace(installedExe) ||
                (!File.Exists(Path.Combine(profileDir, "VanaCore.Core.dll")) &&
                 !File.Exists(Path.Combine(profileDir, "SoulspireClient.Core.dll"))))
            {
                ModernClientConfigGenerator.RestoreRollbackSnapshot(profileDir);
                throw new InvalidOperationException(
                    $"Modern ({package.Profile}) package extracted cleanly, but VanaCore.exe or VanaCore.Core.dll was not found. Rolled back.");
            }

            var newState = new InstalledModernClientState
            {
                Profile = package.Profile,
                Version = package.Version,
                Tag = package.Tag,
                CommitSha = package.CommitSha,
                PackageSha256 = actualSha,
                InstalledUtc = DateTimeOffset.UtcNow
            };
            File.WriteAllText(
                Path.Combine(profileDir, StateFileName),
                JsonSerializer.Serialize(newState, JsonOptions),
                new UTF8Encoding(false));

            progress?.Report(new SyncProgress
            {
                Message = $"Modern ({package.Profile}) {package.Tag} verified and installed.",
                Percent = 100
            });

            return new ModernInstallResult(true, false, profileDir, installedExe, newState);
        }
        finally
        {
            if (File.Exists(tempZip))
            {
                try { File.Delete(tempZip); } catch { /* ignore cleanup errors */ }
            }
        }
    }

    /// <summary>
    /// Extracts a verified Modern client ZIP archive into profileDir, flattening a single top-level
    /// VanaCore\ wrapper directory if present and refusing any zip-slip path traversal.
    /// </summary>
    public static void ExtractPackageArchiveSafely(string zipPath, string destDir)
    {
        Directory.CreateDirectory(destDir);
        var fullDestRoot = Path.GetFullPath(destDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;

        using var archive = ZipFile.OpenRead(zipPath);
        var fileEntries = archive.Entries
            .Where(e => !string.IsNullOrEmpty(e.Name))
            .ToList();

        // Detect if all entries live under a single wrapper directory (e.g., "VanaCore/...").
        string? stripPrefix = null;
        if (fileEntries.Count > 0)
        {
            var firstSegments = fileEntries
                .Select(e => e.FullName.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries))
                .ToList();
            if (firstSegments.All(parts => parts.Length >= 2) &&
                firstSegments.Select(parts => parts[0]).Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1)
            {
                stripPrefix = firstSegments[0][0] + "/";
            }
        }

        foreach (var entry in fileEntries)
        {
            var normalized = entry.FullName.Replace('\\', '/').TrimStart('/');
            if (stripPrefix is not null && normalized.StartsWith(stripPrefix, StringComparison.OrdinalIgnoreCase))
            {
                normalized = normalized[stripPrefix.Length..];
            }

            if (string.IsNullOrWhiteSpace(normalized))
            {
                continue;
            }

            var targetPath = Path.GetFullPath(Path.Combine(destDir, normalized.Replace('/', Path.DirectorySeparatorChar)));
            if (!targetPath.StartsWith(fullDestRoot, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException($"Refusing unsafe archive entry outside ModernClient folder: {entry.FullName}");
            }

            // Never overwrite user/account vanacore.*.ini during client binary upgrades.
            var fileName = Path.GetFileName(targetPath);
            if (fileName.StartsWith("vanacore.", StringComparison.OrdinalIgnoreCase) &&
                fileName.EndsWith(".ini", StringComparison.OrdinalIgnoreCase) &&
                !fileName.Equals("vanacore.example.ini", StringComparison.OrdinalIgnoreCase) &&
                !fileName.Equals("vanacore.soulspire-minimal.ini", StringComparison.OrdinalIgnoreCase) &&
                File.Exists(targetPath))
            {
                continue;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
            entry.ExtractToFile(targetPath, overwrite: true);
        }
    }

    /// <summary>
    /// Copies verified SoulspireXI native plugin, data configs, Ashita addons, and Pivot DAT overlays
    /// from the read-only Classic Ashita installation into ModernClient\compat\ without modifying Ashita\.
    /// </summary>
    public static int SyncCompatibilityOverlayFromAshita(string ashitaDir, string compatDir)
    {
        if (string.IsNullOrWhiteSpace(ashitaDir) || !Directory.Exists(ashitaDir))
        {
            return 0;
        }

        var copied = 0;

        // 1. Copy dual-host soulspire_native.dll + plugins\data\*
        var srcNative = Path.Combine(ashitaDir, "plugins", "soulspire_native.dll");
        if (File.Exists(srcNative))
        {
            var destPlugins = Path.Combine(compatDir, "plugins");
            Directory.CreateDirectory(destPlugins);
            File.Copy(srcNative, Path.Combine(destPlugins, "soulspire_native.dll"), overwrite: true);
            copied++;
        }

        var srcPluginData = Path.Combine(ashitaDir, "plugins", "data");
        if (Directory.Exists(srcPluginData))
        {
            copied += CopyDirectoryContents(srcPluginData, Path.Combine(compatDir, "plugins", "data"));
        }

        // 2. Copy SoulspireXI Ashita addons (preserving any user settings inside compat\addons\...\settings\)
        foreach (var addonName in new[] { "soulspire_core", "crystalsocket", "soulspire_flintlock", "soulspire_gear", "soulspire_soul_actions" })
        {
            var srcAddon = Path.Combine(ashitaDir, "addons", addonName);
            if (Directory.Exists(srcAddon))
            {
                copied += CopyDirectoryContents(srcAddon, Path.Combine(compatDir, "addons", "ashita", addonName), preserveExistingSettings: true);
            }
        }

        // 3. Copy SoulspireXI Pivot DAT overlays into compat\pivot\
        foreach (var overlay in new[] { AshitaConfigGenerator.OverlayFolderName, AshitaConfigGenerator.FlintlockOverlayFolderName })
        {
            var srcOverlay = Path.Combine(ashitaDir, "polplugins", "DATs", overlay);
            if (Directory.Exists(srcOverlay))
            {
                copied += CopyDirectoryContents(srcOverlay, Path.Combine(compatDir, "pivot", overlay));
            }
        }

        return copied;
    }

    private static int CopyDirectoryContents(string sourceDir, string targetDir, bool preserveExistingSettings = false)
    {
        var count = 0;
        Directory.CreateDirectory(targetDir);
        foreach (var srcFile in Directory.GetFiles(sourceDir, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(sourceDir, srcFile);
            var normRel = rel.Replace('\\', '/').ToLowerInvariant();
            var destFile = Path.Combine(targetDir, rel);
            if (preserveExistingSettings &&
                (normRel.Contains("/settings/") || normRel.StartsWith("settings/", StringComparison.Ordinal)) &&
                File.Exists(destFile))
            {
                continue;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(destFile)!);
            File.Copy(srcFile, destFile, overwrite: true);
            count++;
        }
        return count;
    }

    private static string ComputeSha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
}

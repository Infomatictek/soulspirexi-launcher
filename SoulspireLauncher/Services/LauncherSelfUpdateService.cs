using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class LauncherUpdateCheckResult
{
    public bool UpdateAvailable { get; init; }
    public Version CurrentVersion { get; init; } = new(1, 0, 0);
    public Version? LatestVersion { get; init; }
    public string LatestTag { get; init; } = string.Empty;
    public string DownloadUrl { get; init; } = string.Empty;
    public long ExpectedSize { get; init; }
    public string ReleaseUrl { get; init; } = string.Empty;
    public bool IsPrerelease { get; init; }
    public UpdateChannel Channel { get; init; } = UpdateChannel.Stable;
}

public sealed class LauncherSelfUpdateService
{
    public const string JustUpdatedArg = "--just-updated";
    public const string CanonicalLauncherExeName = "SoulspireLauncher.exe";
    public const string LegacyLauncherExeName = "OverlordsLauncher.exe";
    private const long MinimumValidExeBytes = 512 * 1024;

    private readonly HttpClient _http;

    public LauncherSelfUpdateService(HttpClient? httpClient = null)
    {
        _http = httpClient ?? ManifestUpdateService.CreateDefaultHttpClient();
    }

    public static Version GetCurrentVersion()
    {
        var raw = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(1, 0, 0);
        return NormalizeVersion(raw);
    }

    public static string GetCurrentInformationalVersion()
    {
        var attr = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>();
        if (!string.IsNullOrWhiteSpace(attr?.InformationalVersion))
        {
            var raw = attr.InformationalVersion.Trim();
            var plusIdx = raw.IndexOf('+');
            return plusIdx > 0 ? raw[..plusIdx] : raw;
        }

        return GetCurrentVersion().ToString();
    }

    public static Version NormalizeVersion(Version version)
    {
        return new Version(
            Math.Max(0, version.Major),
            Math.Max(0, version.Minor),
            Math.Max(0, version.Build));
    }

    public static bool TryParseVersionTag(string? tagOrVersion, out Version parsedVersion)
    {
        return TryParseVersionTag(tagOrVersion, out parsedVersion, out _);
    }

    public static bool TryParseVersionTag(string? tagOrVersion, out Version parsedVersion, out string prereleaseSuffix)
    {
        parsedVersion = new Version(0, 0, 0);
        prereleaseSuffix = string.Empty;
        if (string.IsNullOrWhiteSpace(tagOrVersion))
        {
            return false;
        }

        var trimmed = tagOrVersion.Trim().TrimStart('v', 'V');
        var buildMetaIdx = trimmed.IndexOf('+');
        if (buildMetaIdx >= 0)
        {
            trimmed = trimmed[..buildMetaIdx];
        }

        var dashIndex = trimmed.IndexOf('-');
        if (dashIndex > 0)
        {
            prereleaseSuffix = trimmed[(dashIndex + 1)..].Trim();
            trimmed = trimmed[..dashIndex];
        }

        if (!Version.TryParse(trimmed, out var raw))
        {
            return false;
        }

        parsedVersion = NormalizeVersion(raw);
        return true;
    }

    public static int CompareVersionTags(string? leftTag, string? rightTag)
    {
        var leftOk = TryParseVersionTag(leftTag, out var leftVer, out var leftPre);
        var rightOk = TryParseVersionTag(rightTag, out var rightVer, out var rightPre);
        if (!leftOk && !rightOk) return 0;
        if (!leftOk) return -1;
        if (!rightOk) return 1;

        var verCmp = leftVer.CompareTo(rightVer);
        if (verCmp != 0)
        {
            return verCmp;
        }

        // Stable (no prerelease suffix) > Prerelease of the same version
        var leftIsStable = string.IsNullOrEmpty(leftPre);
        var rightIsStable = string.IsNullOrEmpty(rightPre);
        if (leftIsStable && rightIsStable) return 0;
        if (leftIsStable) return 1;
        if (rightIsStable) return -1;

        var leftParts = leftPre.Split('.', StringSplitOptions.RemoveEmptyEntries);
        var rightParts = rightPre.Split('.', StringSplitOptions.RemoveEmptyEntries);
        var count = Math.Max(leftParts.Length, rightParts.Length);
        for (var i = 0; i < count; i++)
        {
            if (i >= leftParts.Length) return -1;
            if (i >= rightParts.Length) return 1;

            var leftIsNum = int.TryParse(leftParts[i], out var lNum);
            var rightIsNum = int.TryParse(rightParts[i], out var rNum);
            if (leftIsNum && rightIsNum)
            {
                var numCmp = lNum.CompareTo(rNum);
                if (numCmp != 0) return numCmp;
            }
            else
            {
                var strCmp = string.Compare(leftParts[i], rightParts[i], StringComparison.OrdinalIgnoreCase);
                if (strCmp != 0) return strCmp;
            }
        }

        return 0;
    }

    public static bool IsNewerVersion(Version currentVersion, string? latestTag, out Version? parsedLatest)
    {
        return IsNewerVersion(NormalizeVersion(currentVersion).ToString(), latestTag, out parsedLatest);
    }

    public static bool IsNewerVersion(string currentVersionTag, string? latestTag, out Version? parsedLatest)
    {
        parsedLatest = null;
        if (!TryParseVersionTag(latestTag, out var latest))
        {
            return false;
        }

        parsedLatest = latest;
        return CompareVersionTags(latestTag, currentVersionTag) > 0;
    }

    public static LauncherUpdateCheckResult ParseLatestReleaseJson(
        string json,
        Version currentVersion,
        UpdateChannel channel = UpdateChannel.Stable,
        string? currentInformationalVersion = null)
    {
        var normalizedCurrent = NormalizeVersion(currentVersion);
        var currentTag = string.IsNullOrWhiteSpace(currentInformationalVersion)
            ? normalizedCurrent.ToString()
            : currentInformationalVersion;

        using var doc = JsonDocument.Parse(json);
        return ParseReleaseElement(doc.RootElement, normalizedCurrent, currentTag, channel);
    }

    public static LauncherUpdateCheckResult ParseReleaseListJson(
        string json,
        Version currentVersion,
        UpdateChannel channel,
        string? currentInformationalVersion = null)
    {
        var normalizedCurrent = NormalizeVersion(currentVersion);
        var currentTag = string.IsNullOrWhiteSpace(currentInformationalVersion)
            ? normalizedCurrent.ToString()
            : currentInformationalVersion;

        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.ValueKind != JsonValueKind.Array)
        {
            return ParseReleaseElement(doc.RootElement, normalizedCurrent, currentTag, channel);
        }

        LauncherUpdateCheckResult? best = null;
        foreach (var element in doc.RootElement.EnumerateArray())
        {
            var candidate = ParseReleaseElement(element, normalizedCurrent, currentTag, channel);
            if (string.IsNullOrWhiteSpace(candidate.DownloadUrl))
            {
                continue;
            }

            if (channel == UpdateChannel.Stable && candidate.IsPrerelease)
            {
                continue;
            }

            if (best is null || CompareVersionTags(candidate.LatestTag, best.LatestTag) > 0)
            {
                best = candidate;
            }
        }

        return best ?? new LauncherUpdateCheckResult
        {
            UpdateAvailable = false,
            CurrentVersion = normalizedCurrent,
            Channel = channel
        };
    }

    private static LauncherUpdateCheckResult ParseReleaseElement(
        JsonElement root,
        Version normalizedCurrent,
        string currentTag,
        UpdateChannel channel)
    {
        var isDraft = root.TryGetProperty("draft", out var draftProp) && draftProp.ValueKind == JsonValueKind.True;
        var isPrerelease = root.TryGetProperty("prerelease", out var preProp) && preProp.ValueKind == JsonValueKind.True;
        var tagName = root.TryGetProperty("tag_name", out var tagProp) ? tagProp.GetString() ?? string.Empty : string.Empty;
        var htmlUrl = root.TryGetProperty("html_url", out var htmlProp) ? htmlProp.GetString() ?? string.Empty : string.Empty;

        string downloadUrl = string.Empty;
        long expectedSize = 0;

        // Strictly accept only SoulspireLauncher.exe so the updater can never reinstall legacy OverlordsLauncher.exe.
        if (root.TryGetProperty("assets", out var assetsProp) && assetsProp.ValueKind == JsonValueKind.Array)
        {
            foreach (var asset in assetsProp.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var nameProp) ? nameProp.GetString() : null;
                if (!string.Equals(name, CanonicalLauncherExeName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                downloadUrl = asset.TryGetProperty("browser_download_url", out var urlProp) ? urlProp.GetString() ?? string.Empty : string.Empty;
                if (asset.TryGetProperty("size", out var sizeProp) && sizeProp.TryGetInt64(out var size))
                {
                    expectedSize = size;
                }

                break;
            }
        }

        var isTesting = channel is UpdateChannel.Testing
            or UpdateChannel.TestingRegistry24Hook
            or UpdateChannel.TestingSearchLegacyText
            or UpdateChannel.TestingSearchAlignedText;
        var channelAllowsRelease = isTesting || !isPrerelease;
        Version? latestVersion = null;
        var isNewer = !isDraft &&
                      channelAllowsRelease &&
                      IsNewerVersion(currentTag, tagName, out latestVersion) &&
                      !string.IsNullOrWhiteSpace(downloadUrl);

        return new LauncherUpdateCheckResult
        {
            UpdateAvailable = isNewer,
            CurrentVersion = normalizedCurrent,
            LatestVersion = latestVersion,
            LatestTag = tagName,
            DownloadUrl = downloadUrl,
            ExpectedSize = expectedSize,
            ReleaseUrl = htmlUrl,
            IsPrerelease = isPrerelease,
            Channel = channel
        };
    }

    public async Task<LauncherUpdateCheckResult> CheckForUpdateAsync(
        LauncherManifest manifest,
        UpdateChannel channel = UpdateChannel.Stable,
        CancellationToken cancellationToken = default)
    {
        var currentVersion = GetCurrentVersion();
        var currentInfoVersion = GetCurrentInformationalVersion();
        var owner = string.IsNullOrWhiteSpace(manifest.Repo.Owner) ? "Infomatictek" : manifest.Repo.Owner.Trim();
        var repo = string.IsNullOrWhiteSpace(manifest.Repo.Name) ? "soulspirexi-launcher" : manifest.Repo.Name.Trim();

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cts.CancelAfter(TimeSpan.FromSeconds(10));

        if (channel is UpdateChannel.Testing
            or UpdateChannel.TestingRegistry24Hook
            or UpdateChannel.TestingSearchLegacyText
            or UpdateChannel.TestingSearchAlignedText)
        {
            var listUrl = $"https://api.github.com/repos/{owner}/{repo}/releases?per_page=15";
            var json = await _http.GetStringAsync(listUrl, cts.Token).ConfigureAwait(false);
            return ParseReleaseListJson(json, currentVersion, channel, currentInfoVersion);
        }

        var apiUrl = $"https://api.github.com/repos/{owner}/{repo}/releases/latest";
        var latestJson = await _http.GetStringAsync(apiUrl, cts.Token).ConfigureAwait(false);
        return ParseLatestReleaseJson(latestJson, currentVersion, UpdateChannel.Stable, currentInfoVersion);
    }

    public static string? GetCurrentExecutablePath()
    {
        var path = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(path))
        {
            try
            {
                path = Process.GetCurrentProcess().MainModule?.FileName;
            }
            catch
            {
                path = null;
            }
        }

        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            return null;
        }

        var fileName = Path.GetFileName(path);
        if (!fileName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
            fileName.Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        return path;
    }

    /// <summary>
    /// Ensures self-updates always target SoulspireLauncher.exe, even if invoked from a legacy OverlordsLauncher.exe binary.
    /// </summary>
    public static string ResolveCanonicalTargetExePath(string currentExePath)
    {
        if (string.IsNullOrWhiteSpace(currentExePath))
        {
            return currentExePath;
        }

        var fileName = Path.GetFileName(currentExePath);
        if (string.Equals(fileName, LegacyLauncherExeName, StringComparison.OrdinalIgnoreCase))
        {
            var dir = Path.GetDirectoryName(currentExePath) ?? string.Empty;
            return Path.Combine(dir, CanonicalLauncherExeName);
        }

        return currentExePath;
    }

    /// <summary>
    /// Removes an obsolete sibling OverlordsLauncher.exe ONLY after confirming the running binary is SoulspireLauncher.exe.
    /// </summary>
    public static bool CleanupObsoleteLegacyLauncherBinary(string? currentExePath = null)
    {
        var runningPath = currentExePath ?? GetCurrentExecutablePath();
        if (string.IsNullOrWhiteSpace(runningPath) || !File.Exists(runningPath))
        {
            return false;
        }

        var runningName = Path.GetFileName(runningPath);
        if (!string.Equals(runningName, CanonicalLauncherExeName, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var dir = Path.GetDirectoryName(runningPath);
        if (string.IsNullOrWhiteSpace(dir))
        {
            return false;
        }

        var legacyPath = Path.Combine(dir, LegacyLauncherExeName);
        if (!File.Exists(legacyPath))
        {
            return false;
        }

        try
        {
            File.Delete(legacyPath);
            return !File.Exists(legacyPath);
        }
        catch
        {
            // Legacy binary may still be exiting; it will be cleaned on next launch.
            return false;
        }
    }

    public static bool CanSelfUpdateInPlace(out string? exePath, out string reason)
    {
        exePath = GetCurrentExecutablePath();
        if (string.IsNullOrWhiteSpace(exePath))
        {
            reason = "Self-update is only available when running the packaged SoulspireLauncher.exe.";
            return false;
        }

        var dir = Path.GetDirectoryName(exePath);
        if (string.IsNullOrWhiteSpace(dir))
        {
            reason = "Cannot determine launcher directory.";
            return false;
        }

        try
        {
            var probe = Path.Combine(dir, $".update-write-test-{Environment.ProcessId}.tmp");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
            reason = string.Empty;
            return true;
        }
        catch (Exception ex)
        {
            reason = $"Launcher folder is not writable ({ex.Message}). Move SoulspireLauncher.exe to a user folder or update manually.";
            return false;
        }
    }

    public async Task<string> DownloadUpdateAsync(
        LauncherUpdateCheckResult update,
        IProgress<SyncProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(update.DownloadUrl))
        {
            throw new InvalidOperationException("No download URL provided for launcher update.");
        }

        var stagingDir = GetStagingDirectory();
        Directory.CreateDirectory(stagingDir);

        var safeTag = string.IsNullOrWhiteSpace(update.LatestTag) ? "latest" : update.LatestTag.Trim();
        var stagedPath = Path.Combine(stagingDir, $"SoulspireLauncher-{safeTag}.exe");
        if (File.Exists(stagedPath))
        {
            File.Delete(stagedPath);
        }

        progress?.Report(new SyncProgress
        {
            Message = $"Downloading SoulspireXI Launcher {safeTag}...",
            Percent = 10
        });

        using var response = await _http.GetAsync(update.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        var totalBytes = response.Content.Headers.ContentLength ?? update.ExpectedSize;
        await using (var remoteStream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
        await using (var fileStream = File.Create(stagedPath))
        {
            var buffer = new byte[81920];
            long totalRead = 0;
            int read;
            while ((read = await remoteStream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
            {
                await fileStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                totalRead += read;

                if (totalBytes > 0)
                {
                    var pct = 10 + (85.0 * totalRead / totalBytes);
                    progress?.Report(new SyncProgress
                    {
                        Message = $"Downloading SoulspireXI Launcher {safeTag}... ({totalRead / (1024 * 1024.0):F1} MB)",
                        Percent = Math.Min(95, pct)
                    });
                }
            }
        }

        var info = new FileInfo(stagedPath);
        if (info.Length < MinimumValidExeBytes || (update.ExpectedSize > 0 && info.Length != update.ExpectedSize))
        {
            try
            {
                File.Delete(stagedPath);
            }
            catch
            {
                // Ignore cleanup failure.
            }

            throw new InvalidDataException($"Downloaded SoulspireLauncher.exe size ({info.Length} bytes) did not match expected release size.");
        }

        progress?.Report(new SyncProgress
        {
            Message = $"Downloaded SoulspireXI Launcher {safeTag}. Restarting...",
            Percent = 100
        });

        return stagedPath;
    }

    public void LaunchUpdaterAndPrepareRestart(string stagedExePath, string currentExePath)
    {
        var stagingDir = GetStagingDirectory();
        Directory.CreateDirectory(stagingDir);

        var canonicalTargetExePath = ResolveCanonicalTargetExePath(currentExePath);
        var scriptPath = Path.Combine(stagingDir, "apply-soulspire-update.cmd");
        var scriptContent = BuildUpdaterBatchScript(Environment.ProcessId, stagedExePath, canonicalTargetExePath);
        File.WriteAllText(scriptPath, scriptContent);

        Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = $"/c \"{scriptPath}\"",
            WorkingDirectory = stagingDir,
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden
        });
    }

    public static string BuildUpdaterBatchScript(int currentPid, string stagedExePath, string targetExePath)
    {
        var canonicalTarget = ResolveCanonicalTargetExePath(targetExePath);
        return string.Join(
            "\r\n",
            "@echo off",
            "setlocal",
            $"set \"TARGET_PID={currentPid}\"",
            $"set \"SRC={stagedExePath}\"",
            $"set \"DST={canonicalTarget}\"",
            "set /a WAIT_COUNT=0",
            ":waitloop",
            "tasklist /FI \"PID eq %TARGET_PID%\" /FO CSV /NH 2>nul | findstr /C:\",\\\"%TARGET_PID%\\\",\" >nul",
            "if not errorlevel 1 (",
            "  set /a WAIT_COUNT+=1",
            "  if %WAIT_COUNT% GEQ 30 goto copystep",
            "  ping -n 2 127.0.0.1 >nul",
            "  goto waitloop",
            ")",
            ":copystep",
            "set /a COPY_COUNT=0",
            ":copyloop",
            "copy /Y \"%SRC%\" \"%DST%\" >nul 2>&1",
            "if errorlevel 1 (",
            "  set /a COPY_COUNT+=1",
            "  if %COPY_COUNT% GEQ 20 goto cleanup",
            "  ping -n 2 127.0.0.1 >nul",
            "  goto copyloop",
            ")",
            "if not exist \"%DST%\" goto cleanup",
            "del /F /Q \"%SRC%\" >nul 2>&1",
            $"start \"\" \"%DST%\" {JustUpdatedArg}",
            ":cleanup",
            "del /F /Q \"%~f0\" >nul 2>&1");
    }

    public static void CleanupStagingDirectory()
    {
        try
        {
            var dir = GetStagingDirectory();
            if (Directory.Exists(dir))
            {
                Directory.Delete(dir, recursive: true);
            }
        }
        catch
        {
            // Best-effort cleanup of temp update files.
        }
    }

    private static string GetStagingDirectory() =>
        Path.Combine(Path.GetTempPath(), "SoulspireLauncher-Update");
}

using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class SyncProgress
{
    public string Message { get; init; } = string.Empty;
    public double Percent { get; init; }
}

public sealed class ManifestFetchResult
{
    public LauncherManifest? Manifest { get; init; }
    public bool FromRemote { get; init; }
    public bool UsedBundledFallback { get; init; }
    public UpdateChannel RequestedChannel { get; init; }
    public string? RequestedUrl { get; init; }
    public int? HttpStatusCode { get; init; }
    public string? ErrorMessage { get; init; }
}

public sealed class ManifestUpdateService
{
    public const string StableManifestRelativePath = "manifest.json";
    public const string TestingManifestRelativePath = "channels/testing/manifest.json";
    public const string TestingRegistry24HookManifestRelativePath = "channels/testing-registry-24hook/manifest.json";
    public const string TestingSearchLegacyTextManifestRelativePath = "channels/testing-search-legacy-text/manifest.json";
    public const string TestingSearchAlignedTextManifestRelativePath = "channels/testing-search-aligned-text/manifest.json";
    public const string TestingRegistry24HookBranch = "feat/soul-identity-registry-integration";
    public const string InstalledStateFileName = ".soulspire-state.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    private readonly HttpClient _http;

    public ManifestUpdateService(HttpClient? httpClient = null)
    {
        _http = httpClient ?? CreateDefaultHttpClient();
    }

    public static string GetManifestRelativePath(UpdateChannel channel) => channel switch
    {
        UpdateChannel.Testing => TestingManifestRelativePath,
        UpdateChannel.TestingRegistry24Hook => TestingRegistry24HookManifestRelativePath,
        UpdateChannel.TestingSearchLegacyText => TestingSearchLegacyTextManifestRelativePath,
        UpdateChannel.TestingSearchAlignedText => TestingSearchAlignedTextManifestRelativePath,
        _ => StableManifestRelativePath
    };

    public static string GetManifestBranch(LauncherManifest fallback, UpdateChannel channel) =>
        channel is UpdateChannel.TestingRegistry24Hook
            or UpdateChannel.TestingSearchLegacyText
            or UpdateChannel.TestingSearchAlignedText
            ? TestingRegistry24HookBranch
            : (string.IsNullOrWhiteSpace(fallback.Repo.Branch) ? "main" : fallback.Repo.Branch.Trim());

    public static HttpClient CreateDefaultHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(60)
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("SoulspireLauncher/2.1 (+https://github.com/Infomatictek/soulspirexi-launcher)");
        client.DefaultRequestHeaders.CacheControl = new CacheControlHeaderValue
        {
            NoCache = true,
            NoStore = true
        };
        client.DefaultRequestHeaders.Pragma.ParseAdd("no-cache");
        return client;
    }

    public LauncherManifest LoadEmbeddedManifest()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("manifest.json", StringComparison.OrdinalIgnoreCase));

        if (resourceName is null)
        {
            return new LauncherManifest();
        }

        using var stream = assembly.GetManifestResourceStream(resourceName);
        if (stream is null)
        {
            return new LauncherManifest();
        }

        return JsonSerializer.Deserialize<LauncherManifest>(stream, JsonOptions) ?? new LauncherManifest();
    }

    public Task<(LauncherManifest Manifest, bool FromRemote)> FetchManifestAsync(
        LauncherManifest fallback,
        LocalServerOverride? localOverride,
        CancellationToken cancellationToken = default) =>
        FetchManifestAsync(fallback, localOverride, UpdateChannel.Stable, cancellationToken);

    public async Task<(LauncherManifest Manifest, bool FromRemote)> FetchManifestAsync(
        LauncherManifest fallback,
        LocalServerOverride? localOverride,
        UpdateChannel channel,
        CancellationToken cancellationToken = default)
    {
        var result = await FetchManifestDetailedAsync(fallback, localOverride, channel, cancellationToken)
            .ConfigureAwait(false);
        if (result.Manifest is not null)
        {
            return (result.Manifest, result.FromRemote);
        }

        throw new InvalidOperationException(
            result.ErrorMessage ?? $"Could not load remote manifest for channel {channel}.");
    }

    public async Task<ManifestFetchResult> FetchManifestDetailedAsync(
        LauncherManifest fallback,
        LocalServerOverride? localOverride,
        UpdateChannel channel,
        CancellationToken cancellationToken = default)
    {
        var manifestRelativePath = GetManifestRelativePath(channel);
        var manifestBranch = GetManifestBranch(fallback, channel);

        var rawBase = fallback.Repo.RawBaseUrl.TrimEnd('/');
        if (IsGitHubRawBaseUrl(rawBase) &&
            !string.IsNullOrWhiteSpace(fallback.Repo.Owner) &&
            !string.IsNullOrWhiteSpace(fallback.Repo.Name) &&
            !string.IsNullOrWhiteSpace(manifestBranch))
        {
            rawBase = $"https://raw.githubusercontent.com/{fallback.Repo.Owner.Trim()}/{fallback.Repo.Name.Trim()}/{manifestBranch}";
        }

        string? lastUrl = null;
        int? lastStatusCode = null;
        string? lastError = null;

        if (!string.IsNullOrWhiteSpace(rawBase))
        {
            string? pinnedRawBase = null;
            if (IsGitHubRawBaseUrl(rawBase) &&
                !string.IsNullOrWhiteSpace(fallback.Repo.Owner) &&
                !string.IsNullOrWhiteSpace(fallback.Repo.Name) &&
                !string.IsNullOrWhiteSpace(manifestBranch))
            {
                var commitSha = await TryResolveBranchCommitShaAsync(
                    fallback.Repo.Owner.Trim(),
                    fallback.Repo.Name.Trim(),
                    manifestBranch,
                    cancellationToken).ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(commitSha))
                {
                    pinnedRawBase = $"https://raw.githubusercontent.com/{fallback.Repo.Owner.Trim()}/{fallback.Repo.Name.Trim()}/{commitSha}";
                }
            }

            if (!string.IsNullOrWhiteSpace(pinnedRawBase))
            {
                var pinnedUrl = $"{pinnedRawBase}/{manifestRelativePath}";
                var attempt = await TryFetchManifestFromUrlDetailedAsync(pinnedUrl, cancellationToken)
                    .ConfigureAwait(false);
                lastUrl = pinnedUrl;
                lastStatusCode = attempt.StatusCode;
                lastError = attempt.Error;

                if (attempt.Manifest is not null)
                {
                    if (ValidateManifestForChannel(attempt.Manifest, channel, out var validationError))
                    {
                        attempt.Manifest.ResolvedRawBaseUrl =
                            !string.IsNullOrWhiteSpace(attempt.Manifest.Repo.RawBaseUrl) &&
                            !string.Equals(attempt.Manifest.Repo.RawBaseUrl.TrimEnd('/'), rawBase, StringComparison.OrdinalIgnoreCase)
                                ? attempt.Manifest.Repo.RawBaseUrl.TrimEnd('/')
                                : pinnedRawBase;
                        ApplyLocalOverride(attempt.Manifest, localOverride);
                        return new ManifestFetchResult
                        {
                            Manifest = attempt.Manifest,
                            FromRemote = true,
                            UsedBundledFallback = false,
                            RequestedChannel = channel,
                            RequestedUrl = pinnedUrl,
                            HttpStatusCode = attempt.StatusCode
                        };
                    }

                    lastError = validationError;
                }
            }

            var directUrl = $"{rawBase}/{manifestRelativePath}?t={DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
            var directAttempt = await TryFetchManifestFromUrlDetailedAsync(directUrl, cancellationToken)
                .ConfigureAwait(false);
            lastUrl = directUrl;
            lastStatusCode = directAttempt.StatusCode ?? lastStatusCode;
            lastError = directAttempt.Error ?? lastError;

            if (directAttempt.Manifest is not null)
            {
                if (ValidateManifestForChannel(directAttempt.Manifest, channel, out var validationError))
                {
                    directAttempt.Manifest.ResolvedRawBaseUrl =
                        !string.IsNullOrWhiteSpace(directAttempt.Manifest.Repo.RawBaseUrl)
                            ? directAttempt.Manifest.Repo.RawBaseUrl.TrimEnd('/')
                            : rawBase;
                    ApplyLocalOverride(directAttempt.Manifest, localOverride);
                    return new ManifestFetchResult
                    {
                        Manifest = directAttempt.Manifest,
                        FromRemote = true,
                        UsedBundledFallback = false,
                        RequestedChannel = channel,
                        RequestedUrl = directUrl,
                        HttpStatusCode = directAttempt.StatusCode
                    };
                }

                lastError = validationError;
            }
        }
        else
        {
            lastError = "No remote repository RawBaseUrl configured.";
        }

        // Only Stable may fall back to the bundled Stable manifest.json when offline.
        // Never display or apply the bundled Stable manifest as though it belongs to Testing or Registry Testing.
        if (channel == UpdateChannel.Stable)
        {
            ApplyLocalOverride(fallback, localOverride);
            return new ManifestFetchResult
            {
                Manifest = fallback,
                FromRemote = false,
                UsedBundledFallback = true,
                RequestedChannel = channel,
                RequestedUrl = lastUrl,
                HttpStatusCode = lastStatusCode,
                ErrorMessage = lastError
            };
        }

        var channelLabel = channel switch
        {
            UpdateChannel.TestingRegistry24Hook => "Testing B — Registry 24-Hook (Current menu2fon)",
            UpdateChannel.TestingSearchLegacyText => "Testing A — Search Legacy native_text (4f0fdb3)",
            UpdateChannel.TestingSearchAlignedText => "Testing C — Search Aligned native_text (Repair)",
            _ => "Testing (27-Hook)"
        };
        var statusDetail = lastStatusCode.HasValue ? $"HTTP {lastStatusCode.Value}: " : string.Empty;
        var reason = string.IsNullOrWhiteSpace(lastError) ? "Remote manifest could not be retrieved." : lastError;
        var urlSuffix = string.IsNullOrWhiteSpace(lastUrl) ? string.Empty : $" ({lastUrl})";

        return new ManifestFetchResult
        {
            Manifest = null,
            FromRemote = false,
            UsedBundledFallback = false,
            RequestedChannel = channel,
            RequestedUrl = lastUrl,
            HttpStatusCode = lastStatusCode,
            ErrorMessage = $"{channelLabel} manifest unavailable — {statusDetail}{reason}{urlSuffix}. Switch to Stable or another available Testing channel."
        };
    }

    public static bool IsValidManifestForChannel(LauncherManifest? manifest, UpdateChannel requestedChannel) =>
        ValidateManifestForChannel(manifest, requestedChannel, out _);

    public static bool ValidateManifestForChannel(
        LauncherManifest? manifest,
        UpdateChannel requestedChannel,
        out string error)
    {
        error = string.Empty;
        if (manifest is null || manifest.Files.Count == 0)
        {
            error = "Manifest is empty or contains no file entries.";
            return false;
        }

        var declared = (manifest.Channel ?? "stable").Trim();
        var candidateId = (manifest.CandidateId ?? string.Empty).Trim();

        if (requestedChannel == UpdateChannel.Stable)
        {
            if (declared.Equals("testing", StringComparison.OrdinalIgnoreCase))
            {
                error = "Refusing Testing manifest on Stable channel.";
                return false;
            }
        }
        else if (requestedChannel == UpdateChannel.Testing)
        {
            if (!declared.Equals("testing", StringComparison.OrdinalIgnoreCase))
            {
                error = $"Expected channel 'testing' for Testing channel, but received '{declared}'.";
                return false;
            }

            if (candidateId.Equals("registry-24hook", StringComparison.OrdinalIgnoreCase) ||
                candidateId.Equals("search-legacy-text", StringComparison.OrdinalIgnoreCase) ||
                candidateId.Equals("search-aligned-text", StringComparison.OrdinalIgnoreCase))
            {
                error = "Refusing isolated 24-hook candidate on 27-hook Testing channel.";
                return false;
            }
        }
        else if (requestedChannel is UpdateChannel.TestingRegistry24Hook
                 or UpdateChannel.TestingSearchLegacyText
                 or UpdateChannel.TestingSearchAlignedText)
        {
            var expectedCandidateId = requestedChannel switch
            {
                UpdateChannel.TestingRegistry24Hook => "registry-24hook",
                UpdateChannel.TestingSearchLegacyText => "search-legacy-text",
                UpdateChannel.TestingSearchAlignedText => "search-aligned-text",
                _ => string.Empty
            };

            if (!declared.Equals("testing", StringComparison.OrdinalIgnoreCase))
            {
                error = $"Expected channel 'testing' for {requestedChannel} channel, but received '{declared}'.";
                return false;
            }

            if (!candidateId.Equals(expectedCandidateId, StringComparison.OrdinalIgnoreCase))
            {
                error = $"Expected candidateId '{expectedCandidateId}' for {requestedChannel}, but received '{(string.IsNullOrWhiteSpace(candidateId) ? "none" : candidateId)}'.";
                return false;
            }
        }

        if (!ValidateRegistryBundle(manifest, requestedChannel, out var bundleError))
        {
            error = bundleError;
            return false;
        }

        return true;
    }

    public static bool ValidateRegistryBundle(
        LauncherManifest manifest,
        UpdateChannel requestedChannel,
        out string error)
    {
        error = string.Empty;
        var reg = manifest.Registry;
        if (reg is null)
        {
            return true;
        }

        if (!string.IsNullOrWhiteSpace(reg.Version) && string.IsNullOrWhiteSpace(reg.Hash))
        {
            error = "Manifest declares registry.version without a deterministic registry.hash.";
            return false;
        }

        var dllEntry = manifest.Files.FirstOrDefault(f =>
            f.Category.Equals("plugin", StringComparison.OrdinalIgnoreCase) &&
            f.TargetPath.Replace('\\', '/').EndsWith("crystaljobs.dll", StringComparison.OrdinalIgnoreCase));

        if (dllEntry is not null && !string.IsNullOrWhiteSpace(reg.NativeDllSha256) &&
            !dllEntry.Sha256.Equals(reg.NativeDllSha256, StringComparison.OrdinalIgnoreCase))
        {
            error = $"Manifest registry.nativeDllSha256 ({reg.NativeDllSha256}) does not match crystaljobs.dll entry ({dllEntry.Sha256}).";
            return false;
        }

        // Stable channel must never distribute a newly built registry DLL that has not passed Windows client verification.
        if (requestedChannel == UpdateChannel.Stable &&
            !string.IsNullOrWhiteSpace(reg.NativeDllCompiledHash) &&
            !reg.NativeDllCompiledHash.Equals("legacy-pre-registry", StringComparison.OrdinalIgnoreCase) &&
            !reg.NativeDllClientVerified)
        {
            error = "Refusing Stable manifest: crystaljobs.dll is not marked client-verified (nativeDllClientVerified=false).";
            return false;
        }

        return true;
    }

    public static void EnsureTargetFilesWritable(
        IEnumerable<ManifestFileEntry> pending,
        LauncherSettings settings)
    {
        foreach (var entry in pending)
        {
            var destPath = ResolveTargetFilePath(settings, entry);
            if (!File.Exists(destPath))
            {
                continue;
            }

            try
            {
                using var stream = new FileStream(destPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException ex)
            {
                throw new IOException(
                    $"Cannot update {entry.TargetPath} because it is locked by a running process. Close Ashita / FINAL FANTASY XI / PlayOnline and retry. ({ex.Message})",
                    ex);
            }
            catch (UnauthorizedAccessException ex)
            {
                throw new IOException(
                    $"Cannot update {entry.TargetPath} due to file permissions or active lock. Close Ashita / FINAL FANTASY XI / PlayOnline and retry. ({ex.Message})",
                    ex);
            }
        }
    }

    public static bool IsGitHubRawBaseUrl(string rawBaseUrl) =>
        Uri.TryCreate(rawBaseUrl, UriKind.Absolute, out var uri) &&
        uri.Host.Equals("raw.githubusercontent.com", StringComparison.OrdinalIgnoreCase);

    private async Task<string?> TryResolveBranchCommitShaAsync(
        string owner,
        string repo,
        string branch,
        CancellationToken cancellationToken)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(TimeSpan.FromSeconds(8));

            var apiUrl = $"https://api.github.com/repos/{Uri.EscapeDataString(owner)}/{Uri.EscapeDataString(repo)}/commits/{Uri.EscapeDataString(branch)}";
            using var request = new HttpRequestMessage(HttpMethod.Get, apiUrl);
            request.Headers.Accept.ParseAdd("application/vnd.github.sha");

            using var response = await _http.SendAsync(request, cts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var sha = (await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false)).Trim();
            return sha.Length == 40 && sha.All(Uri.IsHexDigit) ? sha : null;
        }
        catch
        {
            return null;
        }
    }

    private async Task<(LauncherManifest? Manifest, int? StatusCode, string? Error)> TryFetchManifestFromUrlDetailedAsync(
        string url,
        CancellationToken cancellationToken)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(TimeSpan.FromSeconds(10));
            using var response = await _http.GetAsync(url, cts.Token).ConfigureAwait(false);
            var statusCode = (int)response.StatusCode;
            if (!response.IsSuccessStatusCode)
            {
                var reason = string.IsNullOrWhiteSpace(response.ReasonPhrase)
                    ? response.StatusCode.ToString()
                    : response.ReasonPhrase;
                return (null, statusCode, reason);
            }

            var json = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            var parsed = JsonSerializer.Deserialize<LauncherManifest>(json, JsonOptions);
            if (parsed is null)
            {
                return (null, statusCode, "Remote manifest JSON deserialized to null.");
            }

            return (parsed, statusCode, null);
        }
        catch (JsonException ex)
        {
            return (null, null, $"Invalid manifest JSON: {ex.Message}");
        }
        catch (TaskCanceledException)
        {
            return (null, null, "Request timed out while contacting GitHub.");
        }
        catch (HttpRequestException ex)
        {
            return (null, ex.StatusCode.HasValue ? (int)ex.StatusCode.Value : null, ex.Message);
        }
        catch (Exception ex)
        {
            return (null, null, ex.Message);
        }
    }

    public static void ApplyLocalOverride(LauncherManifest manifest, LocalServerOverride? localOverride)
    {
        if (localOverride is null)
        {
            return;
        }

        if (!string.IsNullOrWhiteSpace(localOverride.ServerName))
        {
            manifest.ServerName = localOverride.ServerName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(localOverride.DefaultHost))
        {
            manifest.DefaultHost = localOverride.DefaultHost.Trim();
        }

        if (localOverride.UseHairpin.HasValue)
        {
            manifest.UseHairpin = localOverride.UseHairpin.Value;
        }

        if (localOverride.LobbyPort is > 0)
        {
            manifest.Ports.Lobby = localOverride.LobbyPort.Value;
        }

        if (localOverride.AuthPort is > 0)
        {
            manifest.Ports.Auth = localOverride.AuthPort.Value;
        }

        if (localOverride.SearchPort is > 0)
        {
            manifest.Ports.Search = localOverride.SearchPort.Value;
        }
    }

    public static bool IsProtectedPlayerConfigPath(string category, string targetPath)
    {
        var normalized = targetPath.Replace('\\', '/').TrimStart('/').ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return true;
        }

        if (normalized.Equals("settings.json", StringComparison.Ordinal) ||
            normalized.Equals("soulspire-server.json", StringComparison.Ordinal) ||
            normalized.Equals("overlords-server.json", StringComparison.Ordinal) ||
            normalized.StartsWith("config/addons/", StringComparison.Ordinal) ||
            normalized.StartsWith("config/boot/", StringComparison.Ordinal))
        {
            return true;
        }

        if (category.Equals("addon", StringComparison.OrdinalIgnoreCase) &&
            (normalized.Contains("/settings/", StringComparison.Ordinal) ||
             normalized.EndsWith("/settings.lua", StringComparison.Ordinal) ||
             normalized.EndsWith("/settings.json", StringComparison.Ordinal)))
        {
            return true;
        }

        return false;
    }

    public static string ResolveTargetFilePath(LauncherSettings settings, ManifestFileEntry entry)
    {
        var relative = entry.TargetPath.Replace('/', Path.DirectorySeparatorChar);
        string candidate;
        if (entry.Category.Equals("dat-optional", StringComparison.OrdinalIgnoreCase))
        {
            var folder = string.IsNullOrWhiteSpace(entry.OverlayFolder)
                ? AshitaConfigGenerator.FlintlockOverlayFolderName
                : entry.OverlayFolder.Trim();
            candidate = Path.Combine(settings.AshitaPath, "polplugins", "DATs", folder, relative);
        }
        else if (entry.Category.Equals("dat", StringComparison.OrdinalIgnoreCase))
        {
            candidate = Path.Combine(settings.AshitaPath, "polplugins", "DATs", AshitaConfigGenerator.OverlayFolderName, relative);
        }
        else if (entry.Category.Equals("plugin", StringComparison.OrdinalIgnoreCase))
        {
            candidate = Path.Combine(settings.AshitaPath, "plugins", relative);
        }
        else if (entry.Category.Equals("resource", StringComparison.OrdinalIgnoreCase))
        {
            candidate = Path.Combine(settings.AshitaPath, relative);
        }
        else
        {
            candidate = Path.Combine(settings.AshitaPath, "addons", relative);
        }

        var fullRoot = Path.GetFullPath(settings.AshitaPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        var fullCandidate = Path.GetFullPath(candidate);
        if (!fullCandidate.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Refusing unsafe manifest target path outside Ashita folder: {entry.TargetPath}");
        }

        return fullCandidate;
    }

    public static bool IsOptionalOverlayEnabled(LauncherSettings settings, ManifestOptionalOverlay overlay)
    {
        if (!settings.EnablePivotOverlay)
        {
            return false;
        }

        if (overlay.Id.Equals(AshitaConfigGenerator.FlintlockOverlayId, StringComparison.OrdinalIgnoreCase))
        {
            return settings.EnableFlintlockDualPistolsOverlay;
        }

        return overlay.DefaultEnabled;
    }

    public static IEnumerable<ManifestFileEntry> EnumerateActiveFiles(
        LauncherManifest manifest,
        LauncherSettings settings)
    {
        foreach (var entry in manifest.Files)
        {
            yield return entry;
        }

        foreach (var overlay in manifest.OptionalOverlays)
        {
            if (!IsOptionalOverlayEnabled(settings, overlay))
            {
                continue;
            }

            var folder = string.IsNullOrWhiteSpace(overlay.OverlayFolder) ? overlay.Id : overlay.OverlayFolder;
            foreach (var entry in overlay.Files)
            {
                entry.OverlayFolder = folder;
                yield return entry;
            }
        }
    }

    public List<ManifestFileEntry> GetOutdatedFiles(
        LauncherManifest manifest,
        LauncherSettings settings,
        bool forceAll = false)
    {
        var pending = new List<ManifestFileEntry>();
        foreach (var entry in EnumerateActiveFiles(manifest, settings))
        {
            var dest = ResolveTargetFilePath(settings, entry);
            if (forceAll || !FileMatchesHash(dest, entry.Sha256))
            {
                pending.Add(entry);
                continue;
            }

            if (entry.Category.Equals("dat", StringComparison.OrdinalIgnoreCase) &&
                settings.SyncToCustomDatFolder &&
                !string.IsNullOrWhiteSpace(settings.CustomDatOverlayPath))
            {
                var customDest = Path.Combine(settings.CustomDatOverlayPath, entry.TargetPath.Replace('/', Path.DirectorySeparatorChar));
                if (!FileMatchesHash(customDest, entry.Sha256))
                {
                    pending.Add(entry);
                }
            }
        }

        return pending;
    }

    // Addons retired or renamed during the OverlordsXI -> SoulspireXI transition.
    // Removing these prevents duplicate Ashita addon loads on upgraded installs.
    public static readonly string[] RetiredAddonFolders =
    {
        "overlords_boost",
        "overlords_talents",
        "overlords_gear",
        "overlords_soulhud",
        "overlords_soul_actions"
    };

    private static readonly string[] RetiredAddonFiles =
    {
        "metrics/overlords.lua"
    };

    public static void RemoveRetiredAddons(LauncherSettings settings)
    {
        foreach (var folder in RetiredAddonFolders)
        {
            try
            {
                var dir = Path.Combine(settings.AshitaPath, "addons", folder);
                if (Directory.Exists(dir))
                {
                    Directory.Delete(dir, recursive: true);
                }
            }
            catch (IOException)
            {
                // In use by a running client; it is removed on the next sync.
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        foreach (var relFile in RetiredAddonFiles)
        {
            try
            {
                var path = Path.Combine(settings.AshitaPath, "addons", relFile.Replace('/', Path.DirectorySeparatorChar));
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    public static InstalledClientState? LoadInstalledState(string ashitaPath)
    {
        var statePath = Path.Combine(ashitaPath, InstalledStateFileName);
        if (!File.Exists(statePath))
        {
            return null;
        }

        try
        {
            var json = File.ReadAllText(statePath);
            return JsonSerializer.Deserialize<InstalledClientState>(json, JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    public static void SaveInstalledState(string ashitaPath, LauncherManifest manifest, LauncherSettings settings)
    {
        var state = new InstalledClientState
        {
            Channel = string.IsNullOrWhiteSpace(manifest.Channel)
                ? settings.UpdateChannel.ToString().ToLowerInvariant()
                : manifest.Channel.Trim().ToLowerInvariant(),
            ManifestVersion = manifest.ManifestVersion ?? string.Empty,
            ServerVersion = manifest.ServerCompatibility?.Version ?? string.Empty,
            RegistryVersion = manifest.Registry?.Version ?? string.Empty,
            RegistryHash = manifest.Registry?.Hash ?? string.Empty,
            LastSyncedUtc = DateTimeOffset.UtcNow,
            ManagedFiles = EnumerateActiveFiles(manifest, settings)
                .Select(e => new InstalledManagedFile
                {
                    Category = e.Category,
                    TargetPath = e.TargetPath,
                    OverlayFolder = e.OverlayFolder,
                    Sha256 = e.Sha256
                })
                .ToList()
        };

        var statePath = Path.Combine(ashitaPath, InstalledStateFileName);
        File.WriteAllText(statePath, JsonSerializer.Serialize(state, JsonOptions));
    }

    public static int ReconcileRemovedManagedFiles(
        LauncherManifest activeManifest,
        LauncherSettings settings,
        InstalledClientState? previousState)
    {
        if (previousState is null || previousState.ManagedFiles.Count == 0)
        {
            return 0;
        }

        var activeTargets = new HashSet<string>(
            EnumerateActiveFiles(activeManifest, settings)
                .Select(e => ResolveTargetFilePath(settings, e)),
            StringComparer.OrdinalIgnoreCase);

        var removed = 0;
        foreach (var prev in previousState.ManagedFiles)
        {
            if (IsProtectedPlayerConfigPath(prev.Category, prev.TargetPath))
            {
                continue;
            }

            try
            {
                var prevEntry = new ManifestFileEntry
                {
                    Category = prev.Category,
                    TargetPath = prev.TargetPath,
                    OverlayFolder = prev.OverlayFolder
                };
                var prevPath = ResolveTargetFilePath(settings, prevEntry);
                if (!activeTargets.Contains(prevPath) && File.Exists(prevPath))
                {
                    File.Delete(prevPath);
                    removed++;
                }
            }
            catch
            {
                // Best-effort cleanup of retired managed files.
            }
        }

        return removed;
    }

    [Obsolete("Use SyncSoulspireFilesAsync instead.")]
    public Task<int> SyncOverlordsFilesAsync(
        LauncherManifest manifest,
        LauncherSettings settings,
        bool forceAll,
        IProgress<SyncProgress>? progress = null,
        CancellationToken cancellationToken = default) =>
        SyncSoulspireFilesAsync(manifest, settings, forceAll, progress, cancellationToken);

    public async Task<int> SyncSoulspireFilesAsync(
        LauncherManifest manifest,
        LauncherSettings settings,
        bool forceAll,
        IProgress<SyncProgress>? progress = null,
        CancellationToken cancellationToken = default,
        Action<ManifestFileEntry, string>? beforeCommitFile = null)
    {
        Directory.CreateDirectory(settings.AshitaPath);
        RemoveRetiredAddons(settings);

        var previousState = LoadInstalledState(settings.AshitaPath);
        var pending = GetOutdatedFiles(manifest, settings, forceAll)
            .Where(e => !IsProtectedPlayerConfigPath(e.Category, e.TargetPath))
            .ToList();

        if (pending.Count == 0)
        {
            ReconcileRemovedManagedFiles(manifest, settings, previousState);
            SaveInstalledState(settings.AshitaPath, manifest, settings);
            progress?.Report(new SyncProgress { Message = "All SoulspireXI client files are up to date.", Percent = 100 });
            return 0;
        }

        if (!ValidateRegistryBundle(manifest, settings.UpdateChannel, out var bundleError))
        {
            throw new InvalidDataException(bundleError);
        }

        // Pre-flight lock check before downloading so locked DLLs/files fail fast with zero partial state.
        EnsureTargetFilesWritable(pending, settings);

        var rawBase = (!string.IsNullOrWhiteSpace(manifest.ResolvedRawBaseUrl)
            ? manifest.ResolvedRawBaseUrl
            : manifest.Repo.RawBaseUrl).TrimEnd('/');

        var stageRoot = Path.Combine(Path.GetTempPath(), $"soulspire_stage_{Guid.NewGuid():N}");
        var rollbackRoot = Path.Combine(Path.GetTempPath(), $"soulspire_rollback_{Guid.NewGuid():N}");
        Directory.CreateDirectory(stageRoot);
        Directory.CreateDirectory(rollbackRoot);

        var stagedFiles = new List<(ManifestFileEntry Entry, string StagedPath, string DestPath)>(pending.Count);
        var appliedBackups = new List<(string DestPath, string? BackupPath)>();

        try
        {
            // Phase 1: Download & verify ALL pending files in staging before modifying any live file.
            for (var i = 0; i < pending.Count; i++)
            {
                var entry = pending[i];
                cancellationToken.ThrowIfCancellationRequested();

                var pct = (double)i / pending.Count * 75.0;
                progress?.Report(new SyncProgress
                {
                    Message = $"Downloading & verifying {entry.TargetPath} ({i + 1}/{pending.Count})...",
                    Percent = pct
                });

                var destPath = ResolveTargetFilePath(settings, entry);
                var stagedPath = Path.Combine(stageRoot, $"{i:D4}_{Path.GetFileName(destPath)}");

                var cacheBuster = !string.IsNullOrWhiteSpace(entry.Sha256)
                    ? $"sha={Uri.EscapeDataString(entry.Sha256)}"
                    : $"t={DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";
                var baseUrl = !string.IsNullOrWhiteSpace(entry.DownloadUrl)
                    ? entry.DownloadUrl!.Trim()
                    : $"{rawBase}/{entry.SourcePath.TrimStart('/')}";
                var separator = baseUrl.Contains('?') ? "&" : "?";
                var url = $"{baseUrl}{separator}{cacheBuster}";

                await DownloadFileAsync(url, stagedPath, cancellationToken).ConfigureAwait(false);

                if (!VerifyStagedFile(stagedPath, entry, out var verifyError))
                {
                    TryDeleteFile(stagedPath);
                    var retryUrl = $"{baseUrl}{separator}cb={Guid.NewGuid():N}";
                    await DownloadFileAsync(retryUrl, stagedPath, cancellationToken).ConfigureAwait(false);
                    if (!VerifyStagedFile(stagedPath, entry, out verifyError))
                    {
                        TryDeleteFile(stagedPath);
                        throw new InvalidDataException(verifyError);
                    }
                }

                stagedFiles.Add((entry, stagedPath, destPath));
            }

            // Phase 2: Back up existing files and swap staged files into place with full rollback on error.
            var backupIndex = 0;
            for (var i = 0; i < stagedFiles.Count; i++)
            {
                var (entry, stagedPath, destPath) = stagedFiles[i];
                var pct = 75.0 + ((double)(i + 1) / stagedFiles.Count * 20.0);
                progress?.Report(new SyncProgress
                {
                    Message = $"Applying {entry.TargetPath} ({i + 1}/{stagedFiles.Count})...",
                    Percent = pct
                });

                Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);

                string? backupPath = null;
                if (File.Exists(destPath))
                {
                    backupPath = Path.Combine(rollbackRoot, $"{backupIndex++:D4}_{Path.GetFileName(destPath)}.bak");
                    File.Copy(destPath, backupPath, overwrite: true);
                }

                beforeCommitFile?.Invoke(entry, destPath);

                try
                {
                    File.Move(stagedPath, destPath, overwrite: true);
                    appliedBackups.Add((destPath, backupPath));
                }
                catch (IOException ex)
                {
                    throw new IOException(
                        $"Could not update {entry.TargetPath} because it is currently in use. Close Ashita / FINAL FANTASY XI / PlayOnline and try again. All changes were rolled back. ({ex.Message})",
                        ex);
                }
            }

            // Phase 3: Reconcile retired managed files, mirror custom DAT folder, and save installed state.
            ReconcileRemovedManagedFiles(manifest, settings, previousState);

            foreach (var (entry, _, destPath) in stagedFiles)
            {
                if (entry.Category.Equals("dat", StringComparison.OrdinalIgnoreCase) &&
                    settings.SyncToCustomDatFolder &&
                    !string.IsNullOrWhiteSpace(settings.CustomDatOverlayPath))
                {
                    var customDest = Path.Combine(settings.CustomDatOverlayPath, entry.TargetPath.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(customDest)!);
                    File.Copy(destPath, customDest, overwrite: true);
                }
            }

            SaveInstalledState(settings.AshitaPath, manifest, settings);

            progress?.Report(new SyncProgress
            {
                Message = $"Synced {stagedFiles.Count} SoulspireXI file(s).",
                Percent = 100
            });

            return stagedFiles.Count;
        }
        catch
        {
            RollbackAppliedFiles(appliedBackups);
            throw;
        }
        finally
        {
            TryDeleteDirectory(stageRoot);
            TryDeleteDirectory(rollbackRoot);
        }
    }

    private static bool VerifyStagedFile(string stagedPath, ManifestFileEntry entry, out string error)
    {
        var info = new FileInfo(stagedPath);
        if (!info.Exists)
        {
            error = $"Staged file missing for {entry.TargetPath}.";
            return false;
        }

        if (entry.Size > 0 && info.Length != entry.Size)
        {
            error = $"Size mismatch for {entry.TargetPath}. Expected {entry.Size} bytes, got {info.Length} bytes.";
            return false;
        }

        if (!string.IsNullOrWhiteSpace(entry.Sha256))
        {
            var actualHash = ComputeSha256(stagedPath);
            if (!actualHash.Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                error = $"Checksum mismatch for {entry.TargetPath}. Expected {entry.Sha256}, got {actualHash}.";
                return false;
            }
        }

        error = string.Empty;
        return true;
    }

    private static void RollbackAppliedFiles(List<(string DestPath, string? BackupPath)> appliedBackups)
    {
        for (var i = appliedBackups.Count - 1; i >= 0; i--)
        {
            var (destPath, backupPath) = appliedBackups[i];
            try
            {
                if (!string.IsNullOrEmpty(backupPath) && File.Exists(backupPath))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
                    File.Copy(backupPath, destPath, overwrite: true);
                }
                else if (File.Exists(destPath))
                {
                    File.Delete(destPath);
                }
            }
            catch
            {
                // Best-effort rollback of remaining files.
            }
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
            // Ignore temp cleanup errors.
        }
    }

    public async Task EnsureAshitaAndToolsAsync(
        LauncherManifest manifest,
        LauncherSettings settings,
        IProgress<SyncProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var ashitaDir = settings.AshitaPath;
        Directory.CreateDirectory(ashitaDir);

        if (!File.Exists(Path.Combine(ashitaDir, "Ashita-cli.exe")))
        {
            progress?.Report(new SyncProgress { Message = "Downloading Ashita v4...", Percent = 10 });
            await InstallAshitaAsync(manifest.Bootstrap.AshitaZipUrl, ashitaDir, cancellationToken).ConfigureAwait(false);
        }

        if (string.IsNullOrEmpty(FfxiInstallDetector.ResolveXiloaderPath(ashitaDir)))
        {
            progress?.Report(new SyncProgress { Message = "Downloading latest xiloader.exe...", Percent = 45 });
            await InstallLatestXiloaderAsync(manifest.Bootstrap.XiloaderLatestApiUrl, ashitaDir, cancellationToken).ConfigureAwait(false);
        }

        if (settings.EnablePivotOverlay && !File.Exists(Path.Combine(ashitaDir, "polplugins", "pivot.dll")))
        {
            progress?.Report(new SyncProgress { Message = "Downloading XIPivot plugin for Ashita v4...", Percent = 70 });
            await InstallLatestXipivotAsync(manifest.Bootstrap.XipivotLatestApiUrl, ashitaDir, cancellationToken).ConfigureAwait(false);
        }

        var metricsDir = Path.Combine(ashitaDir, "addons", "metrics");
        if (!File.Exists(Path.Combine(metricsDir, "metrics.lua")) ||
            !File.Exists(Path.Combine(metricsDir, "horizon.lua")) ||
            !File.Exists(Path.Combine(metricsDir, "initialization.lua")))
        {
            progress?.Report(new SyncProgress { Message = "Downloading Metrics parse addon for Ashita v4...", Percent = 80 });
            await InstallLatestGitHubAddonAsync(
                manifest.Bootstrap.MetricsLatestApiUrl,
                ashitaDir,
                addonFolderName: "metrics",
                entryFileName: "metrics.lua",
                displayName: "Metrics",
                cancellationToken).ConfigureAwait(false);
        }

        if (!File.Exists(Path.Combine(ashitaDir, "addons", "mobdb", "mobdb.lua")))
        {
            progress?.Report(new SyncProgress { Message = "Downloading MobDB mob level & info addon...", Percent = 88 });
            await InstallLatestGitHubAddonAsync(
                manifest.Bootstrap.MobDbLatestApiUrl,
                ashitaDir,
                addonFolderName: "mobdb",
                entryFileName: "mobdb.lua",
                displayName: "MobDB",
                cancellationToken).ConfigureAwait(false);
        }

        var kazenoeyeDir = Path.Combine(ashitaDir, "addons", "kazenoeye");
        if (!File.Exists(Path.Combine(kazenoeyeDir, "kazenoeye.lua")) ||
            !File.Exists(Path.Combine(kazenoeyeDir, "assets", "icons", "0.png")))
        {
            progress?.Report(new SyncProgress { Message = "Downloading Kazenoeye mob debuff HUD icons & base files...", Percent = 94 });
            await InstallLatestGitHubAddonAsync(
                manifest.Bootstrap.KazenoeyeLatestApiUrl,
                ashitaDir,
                addonFolderName: "kazenoeye",
                entryFileName: "kazenoeye.lua",
                displayName: "Kazenoeye",
                cancellationToken).ConfigureAwait(false);
        }

        progress?.Report(new SyncProgress { Message = "Ashita v4 prerequisites verified.", Percent = 100 });
    }

    private async Task InstallAshitaAsync(string zipUrl, string ashitaDir, CancellationToken cancellationToken)
    {
        var tempZip = Path.Combine(Path.GetTempPath(), $"soulspire_ashita_{Guid.NewGuid():N}.zip");
        try
        {
            await DownloadFileAsync(zipUrl, tempZip, cancellationToken).ConfigureAwait(false);

            using var archive = ZipFile.OpenRead(tempZip);
            foreach (var entry in archive.Entries)
            {
                if (string.IsNullOrEmpty(entry.Name))
                {
                    continue;
                }

                // Strip leading repository folder name (e.g. Ashita-v4beta-main/)
                var parts = entry.FullName.Split(['/', '\\'], 2);
                var relPath = parts.Length == 2 ? parts[1] : parts[0];
                if (string.IsNullOrWhiteSpace(relPath))
                {
                    continue;
                }

                var dest = Path.GetFullPath(Path.Combine(ashitaDir, relPath.Replace('/', Path.DirectorySeparatorChar)));
                var rootFull = Path.GetFullPath(ashitaDir);
                if (!dest.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                entry.ExtractToFile(dest, overwrite: true);
            }
        }
        finally
        {
            TryDeleteFile(tempZip);
        }
    }

    private async Task InstallLatestXiloaderAsync(string latestApiUrl, string ashitaDir, CancellationToken cancellationToken)
    {
        var releaseJson = await _http.GetStringAsync(latestApiUrl, cancellationToken).ConfigureAwait(false);
        using var doc = JsonDocument.Parse(releaseJson);
        if (!doc.RootElement.TryGetProperty("assets", out var assets))
        {
            throw new InvalidOperationException("No release assets found for xiloader.");
        }

        string? exeUrl = null;
        string? zipUrl = null;

        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.GetProperty("name").GetString() ?? string.Empty;
            var url = asset.GetProperty("browser_download_url").GetString();
            if (string.IsNullOrWhiteSpace(url))
            {
                continue;
            }

            if (name.Equals("xiloader.exe", StringComparison.OrdinalIgnoreCase))
            {
                exeUrl = url;
                break;
            }

            if (name.Contains("xiloader", StringComparison.OrdinalIgnoreCase) &&
                name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                zipUrl = url;
            }
        }

        var bootloaderDir = Path.Combine(ashitaDir, "bootloader");
        Directory.CreateDirectory(bootloaderDir);
        var targetExe = Path.Combine(bootloaderDir, "xiloader.exe");

        if (exeUrl is not null)
        {
            await DownloadFileAsync(exeUrl, targetExe, cancellationToken).ConfigureAwait(false);
            return;
        }

        if (zipUrl is not null)
        {
            var tempZip = Path.Combine(Path.GetTempPath(), $"soulspire_xiloader_{Guid.NewGuid():N}.zip");
            try
            {
                await DownloadFileAsync(zipUrl, tempZip, cancellationToken).ConfigureAwait(false);
                using var archive = ZipFile.OpenRead(tempZip);
                var exeEntry = archive.Entries.FirstOrDefault(e =>
                    e.Name.Equals("xiloader.exe", StringComparison.OrdinalIgnoreCase));
                if (exeEntry is null)
                {
                    throw new InvalidOperationException("xiloader.exe was not found inside release archive.");
                }

                exeEntry.ExtractToFile(targetExe, overwrite: true);
                return;
            }
            finally
            {
                TryDeleteFile(tempZip);
            }
        }

        throw new InvalidOperationException("Could not find xiloader.exe in latest LandSandBoat/xiloader release.");
    }

    private async Task InstallLatestXipivotAsync(string latestApiUrl, string ashitaDir, CancellationToken cancellationToken)
    {
        var releaseJson = await _http.GetStringAsync(latestApiUrl, cancellationToken).ConfigureAwait(false);
        using var doc = JsonDocument.Parse(releaseJson);
        if (!doc.RootElement.TryGetProperty("assets", out var assets))
        {
            throw new InvalidOperationException("No release assets found for XIPivot.");
        }

        string? ashita4ZipUrl = null;
        string? fallbackZipUrl = null;
        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.GetProperty("name").GetString() ?? string.Empty;
            var url = asset.GetProperty("browser_download_url").GetString();
            if (string.IsNullOrWhiteSpace(url) || !name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            fallbackZipUrl ??= url;

            if (name.Contains("Ashita_v4", StringComparison.OrdinalIgnoreCase) ||
                name.Contains("Ashita4", StringComparison.OrdinalIgnoreCase) ||
                name.Contains("v4", StringComparison.OrdinalIgnoreCase))
            {
                ashita4ZipUrl = url;
                break;
            }
        }

        var downloadUrl = ashita4ZipUrl ?? fallbackZipUrl;
        if (downloadUrl is null)
        {
            throw new InvalidOperationException("Could not find Ashita v4 archive in latest XIPivot release.");
        }

        var tempZip = Path.Combine(Path.GetTempPath(), $"soulspire_xipivot_{Guid.NewGuid():N}.zip");
        try
        {
            await DownloadFileAsync(downloadUrl, tempZip, cancellationToken).ConfigureAwait(false);
            using var archive = ZipFile.OpenRead(tempZip);
            var polPluginsDir = Path.Combine(ashitaDir, "polplugins");
            Directory.CreateDirectory(polPluginsDir);

            var pivotEntries = archive.Entries
                .Where(e => !string.IsNullOrEmpty(e.Name) &&
                            e.Name.Equals("pivot.dll", StringComparison.OrdinalIgnoreCase))
                .ToList();

            var chosen = pivotEntries.FirstOrDefault(e =>
                             e.FullName.Contains("v4", StringComparison.OrdinalIgnoreCase) ||
                             e.FullName.Contains("polplugins", StringComparison.OrdinalIgnoreCase))
                         ?? pivotEntries.FirstOrDefault();

            if (chosen is null)
            {
                throw new InvalidOperationException("pivot.dll was not found inside XIPivot archive.");
            }

            chosen.ExtractToFile(Path.Combine(polPluginsDir, "pivot.dll"), overwrite: true);
        }
        finally
        {
            TryDeleteFile(tempZip);
        }
    }

    private async Task InstallLatestGitHubAddonAsync(
        string releaseApiUrl,
        string ashitaDir,
        string addonFolderName,
        string entryFileName,
        string displayName,
        CancellationToken cancellationToken)
    {
        var json = await _http.GetStringAsync(releaseApiUrl, cancellationToken).ConfigureAwait(false);
        using var doc = JsonDocument.Parse(json);

        string? addonZipUrl = null;
        if (doc.RootElement.TryGetProperty("assets", out var assetsProp) && assetsProp.ValueKind == JsonValueKind.Array)
        {
            string? fallbackZip = null;
            foreach (var asset in assetsProp.EnumerateArray())
            {
                var name = asset.GetProperty("name").GetString() ?? string.Empty;
                var url = asset.GetProperty("browser_download_url").GetString();
                if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || string.IsNullOrWhiteSpace(url))
                {
                    continue;
                }

                fallbackZip ??= url;
                if (name.Contains(addonFolderName, StringComparison.OrdinalIgnoreCase))
                {
                    addonZipUrl = url;
                    break;
                }
            }

            addonZipUrl ??= fallbackZip;
        }

        if (string.IsNullOrWhiteSpace(addonZipUrl) &&
            doc.RootElement.TryGetProperty("zipball_url", out var zipballProp))
        {
            addonZipUrl = zipballProp.GetString();
        }

        if (string.IsNullOrWhiteSpace(addonZipUrl))
        {
            throw new InvalidOperationException($"Could not find {displayName} addon archive in latest GitHub release.");
        }

        var tempZip = Path.Combine(Path.GetTempPath(), $"soulspire_{addonFolderName}_{Guid.NewGuid():N}.zip");
        try
        {
            await DownloadFileAsync(addonZipUrl, tempZip, cancellationToken).ConfigureAwait(false);
            var addonDir = Path.Combine(ashitaDir, "addons", addonFolderName);
            ExtractAddonZipToDirectory(tempZip, addonDir, entryFileName);
        }
        finally
        {
            TryDeleteFile(tempZip);
        }
    }

    public static void ExtractMetricsZipToDirectory(string zipPath, string metricsDir) =>
        ExtractAddonZipToDirectory(zipPath, metricsDir, "metrics.lua");

    public static void ExtractAddonZipToDirectory(string zipPath, string addonDir, string entryFileName)
    {
        Directory.CreateDirectory(addonDir);
        var rootFull = Path.GetFullPath(addonDir);
        var rootWithSep = rootFull.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;

        using var archive = ZipFile.OpenRead(zipPath);
        var entryPoint = archive.Entries.FirstOrDefault(e =>
            !string.IsNullOrEmpty(e.Name) &&
            e.Name.Equals(entryFileName, StringComparison.OrdinalIgnoreCase));

        var stripPrefix = string.Empty;
        if (entryPoint is not null)
        {
            var normalized = entryPoint.FullName.Replace('\\', '/').TrimStart('/');
            var slashIdx = normalized.LastIndexOf('/');
            if (slashIdx >= 0)
            {
                stripPrefix = normalized[..(slashIdx + 1)];
            }
        }

        foreach (var entry in archive.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name))
            {
                continue;
            }

            var relPath = entry.FullName.Replace('\\', '/').TrimStart('/');
            if (!string.IsNullOrEmpty(stripPrefix))
            {
                if (!relPath.StartsWith(stripPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                relPath = relPath[stripPrefix.Length..];
            }

            if (string.IsNullOrWhiteSpace(relPath))
            {
                continue;
            }

            var dest = Path.GetFullPath(Path.Combine(rootFull, relPath.Replace('/', Path.DirectorySeparatorChar)));
            if (!dest.StartsWith(rootWithSep, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            entry.ExtractToFile(dest, overwrite: true);
        }

        if (!File.Exists(Path.Combine(rootFull, entryFileName)))
        {
            throw new InvalidOperationException($"{entryFileName} was not found inside downloaded archive.");
        }
    }

    private async Task DownloadFileAsync(string url, string destinationPath, CancellationToken cancellationToken)
    {
        using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        await using var src = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var dst = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true);
        await src.CopyToAsync(dst, cancellationToken).ConfigureAwait(false);
    }

    public static bool FileMatchesHash(string filePath, string expectedSha256)
    {
        if (!File.Exists(filePath))
        {
            return false;
        }

        if (string.IsNullOrWhiteSpace(expectedSha256))
        {
            return true;
        }

        return ComputeSha256(filePath).Equals(expectedSha256, StringComparison.OrdinalIgnoreCase);
    }

    public static string ComputeSha256(string filePath)
    {
        using var stream = File.OpenRead(filePath);
        var hash = SHA256.HashData(stream);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Ignore cleanup errors.
        }
    }
}

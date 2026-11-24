using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text;
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
    public string ExpectedSha256 { get; init; } = string.Empty;
    public string ExpectedExecutableSha256 { get; init; } = string.Empty;
    public string? ExpectedUpdaterSha256 { get; init; }
    public string PackageType { get; init; } = "exe";
    public string ReleaseUrl { get; init; } = string.Empty;
    public string ReleaseNotes { get; init; } = string.Empty;
    public bool IsPrerelease { get; init; }
    public UpdateChannel Channel { get; init; } = UpdateChannel.Stable;
    public string Source { get; init; } = "github-releases";
    public LauncherReleaseMetadata? ReleaseMetadata { get; init; }
}

public sealed record StagedLauncherUpdate(
    string StagingDirectory,
    string StagedExePath,
    string VerifiedExeSha256,
    string? StagedUpdaterPath,
    string? VerifiedUpdaterSha256,
    string TargetVersion,
    string ChannelSlug);

public sealed class LauncherSelfUpdateService
{
    public const string JustUpdatedArg = "--just-updated";
    public const string RolledBackArg = "--rolled-back";
    public const string UpdateFailedArg = "--update-failed";
    public const string UpdatedFromArg = "--updated-from";
    public const string UpdatedToArg = "--updated-to";
    public const string CanonicalLauncherExeName = "SoulspireLauncher.exe";
    public const string LegacyLauncherExeName = "OverlordsLauncher.exe";
    public const string ReleaseMetadataAssetName = "launcher-release.json";
    private const long MinimumValidExeBytes = LauncherPackageVerifier.DefaultMinimumValidExeBytes;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    private readonly HttpClient _http;
    private readonly string? _trustedPublicKeyPem;
    private readonly bool _requireSignature;
    private readonly bool _allowLoopbackHttpForTests;

    public LauncherSelfUpdateService(
        HttpClient? httpClient = null,
        string? trustedPublicKeyPem = null,
        bool requireSignature = false,
        bool allowLoopbackHttpForTests = false)
    {
        _http = httpClient ?? ManifestUpdateService.CreateDefaultHttpClient();
        _trustedPublicKeyPem = trustedPublicKeyPem;
        _requireSignature = requireSignature;
        _allowLoopbackHttpForTests = allowLoopbackHttpForTests;
    }

    public static string GetChannelSlug(UpdateChannel channel) =>
        channel switch
        {
            UpdateChannel.Stable => "stable",
            UpdateChannel.TestingCoreUi => "testing-core-ui",
            _ => "testing"
        };

    public static bool IsTestingChannel(UpdateChannel channel) =>
        channel is UpdateChannel.Testing
            or UpdateChannel.TestingRegistry24Hook
            or UpdateChannel.TestingSearchLegacyText
            or UpdateChannel.TestingSearchAlignedText
            or UpdateChannel.TestingCoreUi;

    public static string ResolveChannelReleaseFeedUrl(LauncherManifest manifest, UpdateChannel channel)
    {
        var owner = string.IsNullOrWhiteSpace(manifest.Repo.Owner) ? "Infomatictek" : manifest.Repo.Owner.Trim();
        var repo = string.IsNullOrWhiteSpace(manifest.Repo.Name) ? "soulspirexi-launcher" : manifest.Repo.Name.Trim();
        var slug = GetChannelSlug(channel);
        var branch = channel switch
        {
            UpdateChannel.Stable => "main",
            UpdateChannel.TestingCoreUi => ManifestUpdateService.TestingCoreUiBranch,
            _ => string.IsNullOrWhiteSpace(manifest.Repo.Branch) ? "main" : manifest.Repo.Branch.Trim()
        };

        return $"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/channels/launcher-releases/{slug}.json";
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

    /// <summary>
    /// Parses & validates a channel-scoped launcher-release.json document.
    /// Enforces strict channel isolation (a Testing release can NEVER upgrade a Stable player)
    /// and verifies any cryptographic signature before marking UpdateAvailable=true.
    /// </summary>
    public static LauncherUpdateCheckResult ParseChannelReleaseMetadataJson(
        string json,
        Version currentVersion,
        UpdateChannel channel,
        string? currentInformationalVersion = null,
        string? trustedPublicKeyPem = null,
        bool requireSignature = false,
        string expectedOwner = "Infomatictek",
        string expectedRepo = "soulspirexi-launcher",
        bool allowLoopbackHttpForTests = false)
    {
        var normalizedCurrent = NormalizeVersion(currentVersion);
        var currentTag = string.IsNullOrWhiteSpace(currentInformationalVersion)
            ? normalizedCurrent.ToString()
            : currentInformationalVersion;

        var meta = JsonSerializer.Deserialize<LauncherReleaseMetadata>(json, JsonOptions);
        if (meta is null || string.IsNullOrWhiteSpace(meta.Version))
        {
            throw new InvalidDataException("Launcher release metadata is empty or missing version.");
        }

        var expectedChannelSlug = GetChannelSlug(channel);
        var metaChannelSlug = (meta.Channel ?? string.Empty).Trim().ToLowerInvariant();
        if (channel == UpdateChannel.Stable && metaChannelSlug != "stable")
        {
            // Stable players must NEVER receive a non-stable launcher release.
            return new LauncherUpdateCheckResult
            {
                UpdateAvailable = false,
                CurrentVersion = normalizedCurrent,
                Channel = channel,
                Source = "channel-metadata"
            };
        }

        if (channel == UpdateChannel.TestingCoreUi &&
            metaChannelSlug is not ("testing-core-ui" or "stable"))
        {
            return new LauncherUpdateCheckResult
            {
                UpdateAvailable = false,
                CurrentVersion = normalizedCurrent,
                Channel = channel,
                Source = "channel-metadata"
            };
        }

        if (!LauncherPackageVerifier.VerifySignature(meta, trustedPublicKeyPem, requireSignature, out var sigErr))
        {
            throw new InvalidDataException(sigErr);
        }

        if (!LauncherPackageVerifier.IsTrustedDownloadUri(
                meta.DownloadUrl,
                expectedOwner,
                expectedRepo,
                allowLoopbackHttpForTests))
        {
            throw new InvalidDataException($"Untrusted launcher download URL rejected: {meta.DownloadUrl}");
        }

        if (!LauncherPackageVerifier.IsValidSha256Hex(meta.Sha256))
        {
            throw new InvalidDataException("Launcher release metadata is missing a valid 64-character SHA-256 digest.");
        }

        var tagOrVersion = string.IsNullOrWhiteSpace(meta.Tag) ? meta.Version : meta.Tag;
        var isPrerelease = metaChannelSlug != "stable" ||
            (TryParseVersionTag(tagOrVersion, out _, out var pre) && !string.IsNullOrEmpty(pre));
        if (channel == UpdateChannel.Stable && isPrerelease)
        {
            return new LauncherUpdateCheckResult
            {
                UpdateAvailable = false,
                CurrentVersion = normalizedCurrent,
                Channel = channel,
                Source = "channel-metadata"
            };
        }

        var isNewer = IsNewerVersion(currentTag, tagOrVersion, out var parsedLatest);
        return new LauncherUpdateCheckResult
        {
            UpdateAvailable = isNewer,
            CurrentVersion = normalizedCurrent,
            LatestVersion = parsedLatest,
            LatestTag = tagOrVersion,
            DownloadUrl = meta.DownloadUrl.Trim(),
            ExpectedSize = meta.Size,
            ExpectedSha256 = meta.Sha256.Trim().ToLowerInvariant(),
            ExpectedExecutableSha256 = string.IsNullOrWhiteSpace(meta.ExecutableSha256)
                ? meta.Sha256.Trim().ToLowerInvariant()
                : meta.ExecutableSha256.Trim().ToLowerInvariant(),
            ExpectedUpdaterSha256 = string.IsNullOrWhiteSpace(meta.UpdaterSha256)
                ? null
                : meta.UpdaterSha256.Trim().ToLowerInvariant(),
            PackageType = string.IsNullOrWhiteSpace(meta.PackageType) ? "zip" : meta.PackageType.Trim().ToLowerInvariant(),
            ReleaseUrl = meta.ReleaseUrl ?? string.Empty,
            ReleaseNotes = meta.ReleaseNotes ?? string.Empty,
            IsPrerelease = isPrerelease,
            Channel = channel,
            Source = $"channel-metadata:{expectedChannelSlug}",
            ReleaseMetadata = meta
        };
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

            // Testing Core UI only picks core-ui prereleases or strictly newer stable releases
            if (channel == UpdateChannel.TestingCoreUi &&
                candidate.IsPrerelease &&
                !candidate.LatestTag.Contains("core-ui", StringComparison.OrdinalIgnoreCase))
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

        var isTesting = IsTestingChannel(channel);
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
            PackageType = "exe",
            ReleaseUrl = htmlUrl,
            IsPrerelease = isPrerelease,
            Channel = channel,
            Source = "github-releases"
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
        cts.CancelAfter(TimeSpan.FromSeconds(12));

        // 1. Prefer authenticated per-channel launcher-release.json feed (no GitHub API rate-limit,
        //    includes SHA-256 + optional ECDSA signature + ZIP/updater hashes + strict channel separation).
        var channelFeedUrl = ResolveChannelReleaseFeedUrl(manifest, channel);
        try
        {
            using var feedResp = await _http.GetAsync(channelFeedUrl, cts.Token).ConfigureAwait(false);
            if (feedResp.IsSuccessStatusCode)
            {
                var feedJson = await feedResp.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
                var parsed = ParseChannelReleaseMetadataJson(
                    feedJson,
                    currentVersion,
                    channel,
                    currentInfoVersion,
                    _trustedPublicKeyPem,
                    _requireSignature,
                    owner,
                    repo,
                    _allowLoopbackHttpForTests);
                if (!string.IsNullOrWhiteSpace(parsed.LatestTag))
                {
                    return parsed;
                }
            }
        }
        catch (InvalidDataException)
        {
            // Cryptographic signature or trust validation error MUST fail closed rather than silently falling back.
            throw;
        }
        catch
        {
            // Feed may not be published yet on older branches; fall through to GitHub Releases API.
        }

        // 2. Fallback to GitHub Releases API (supports companion launcher-release.json asset if present)
        if (IsTestingChannel(channel))
        {
            var listUrl = $"https://api.github.com/repos/{owner}/{repo}/releases?per_page=15";
            var json = await _http.GetStringAsync(listUrl, cts.Token).ConfigureAwait(false);
            var companion = await TryResolveCompanionMetadataFromReleaseListAsync(json, currentVersion, channel, currentInfoVersion, owner, repo, cts.Token)
                .ConfigureAwait(false);
            return companion ?? ParseReleaseListJson(json, currentVersion, channel, currentInfoVersion);
        }

        var apiUrl = $"https://api.github.com/repos/{owner}/{repo}/releases/latest";
        var latestJson = await _http.GetStringAsync(apiUrl, cts.Token).ConfigureAwait(false);
        var stableCompanion = await TryResolveCompanionMetadataFromReleaseJsonAsync(latestJson, currentVersion, UpdateChannel.Stable, currentInfoVersion, owner, repo, cts.Token)
            .ConfigureAwait(false);
        return stableCompanion ?? ParseLatestReleaseJson(latestJson, currentVersion, UpdateChannel.Stable, currentInfoVersion);
    }

    private async Task<LauncherUpdateCheckResult?> TryResolveCompanionMetadataFromReleaseListAsync(
        string listJson,
        Version currentVersion,
        UpdateChannel channel,
        string currentInfoVersion,
        string owner,
        string repo,
        CancellationToken ct)
    {
        using var doc = JsonDocument.Parse(listJson);
        if (doc.RootElement.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        LauncherUpdateCheckResult? best = null;
        foreach (var el in doc.RootElement.EnumerateArray())
        {
            var res = await TryResolveCompanionMetadataElementAsync(el, currentVersion, channel, currentInfoVersion, owner, repo, ct)
                .ConfigureAwait(false);
            if (res is null) continue;
            if (best is null || CompareVersionTags(res.LatestTag, best.LatestTag) > 0)
            {
                best = res;
            }
        }

        return best;
    }

    private async Task<LauncherUpdateCheckResult?> TryResolveCompanionMetadataFromReleaseJsonAsync(
        string releaseJson,
        Version currentVersion,
        UpdateChannel channel,
        string currentInfoVersion,
        string owner,
        string repo,
        CancellationToken ct)
    {
        using var doc = JsonDocument.Parse(releaseJson);
        return await TryResolveCompanionMetadataElementAsync(doc.RootElement, currentVersion, channel, currentInfoVersion, owner, repo, ct)
            .ConfigureAwait(false);
    }

    private async Task<LauncherUpdateCheckResult?> TryResolveCompanionMetadataElementAsync(
        JsonElement root,
        Version currentVersion,
        UpdateChannel channel,
        string currentInfoVersion,
        string owner,
        string repo,
        CancellationToken ct)
    {
        if (root.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True)
        {
            return null;
        }

        var isPrerelease = root.TryGetProperty("prerelease", out var pre) && pre.ValueKind == JsonValueKind.True;
        if (channel == UpdateChannel.Stable && isPrerelease)
        {
            return null;
        }

        var tagName = root.TryGetProperty("tag_name", out var tagProp) ? tagProp.GetString() ?? string.Empty : string.Empty;
        if (channel == UpdateChannel.TestingCoreUi &&
            isPrerelease &&
            !tagName.Contains("core-ui", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (!root.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        string? metaUrl = null;
        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
            if (string.Equals(name, ReleaseMetadataAssetName, StringComparison.OrdinalIgnoreCase))
            {
                metaUrl = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
                break;
            }
        }

        if (string.IsNullOrWhiteSpace(metaUrl) ||
            !LauncherPackageVerifier.IsTrustedDownloadUri(metaUrl, owner, repo, _allowLoopbackHttpForTests))
        {
            return null;
        }

        var metaJson = await _http.GetStringAsync(metaUrl, ct).ConfigureAwait(false);
        return ParseChannelReleaseMetadataJson(
            metaJson,
            currentVersion,
            channel,
            currentInfoVersion,
            _trustedPublicKeyPem,
            _requireSignature,
            owner,
            repo,
            _allowLoopbackHttpForTests);
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
            reason = $"Launcher folder is not writable ({ex.Message}). Use 'Install Per-User Launcher' to move SoulspireLauncher.exe into %LOCALAPPDATA%\\SoulspireXI\\Launcher.";
            return false;
        }
    }

    /// <summary>
    /// Downloads, verifies (HTTPS origin, cryptographic signature if present/required, exact size,
    /// SHA-256, and PE header), and stages the update outside the active launcher directory.
    /// Interrupted or corrupt downloads are deleted immediately and never installed.
    /// </summary>
    public async Task<StagedLauncherUpdate> DownloadAndVerifyUpdateAsync(
        LauncherUpdateCheckResult update,
        IProgress<SyncProgress>? progress = null,
        CancellationToken cancellationToken = default,
        string? stagingRootOverride = null,
        long minimumExeBytes = MinimumValidExeBytes,
        bool requirePeHeader = true)
    {
        if (string.IsNullOrWhiteSpace(update.DownloadUrl))
        {
            throw new InvalidOperationException("No download URL provided for launcher update.");
        }

        if (!LauncherPackageVerifier.IsTrustedDownloadUri(
                update.DownloadUrl,
                allowLoopbackHttpForTests: _allowLoopbackHttpForTests))
        {
            throw new InvalidDataException($"Refusing to download launcher update from untrusted URL: {update.DownloadUrl}");
        }

        if (update.ReleaseMetadata is not null &&
            !LauncherPackageVerifier.VerifySignature(update.ReleaseMetadata, _trustedPublicKeyPem, _requireSignature, out var sigErr))
        {
            throw new InvalidDataException(sigErr);
        }

        var safeTag = LauncherInstallationService.SanitizeVersionFolderName(
            string.IsNullOrWhiteSpace(update.LatestTag) ? "latest" : update.LatestTag);
        var sessionDir = Path.Combine(
            stagingRootOverride ?? GetStagingDirectory(),
            $"stage-{safeTag}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(sessionDir);

        var isZip = string.Equals(update.PackageType, "zip", StringComparison.OrdinalIgnoreCase) ||
            update.DownloadUrl.EndsWith(".zip", StringComparison.OrdinalIgnoreCase);
        var finalDownloadPath = Path.Combine(sessionDir, isZip ? $"SoulspireLauncher-{safeTag}.zip" : $"SoulspireLauncher-{safeTag}.exe");
        var partPath = finalDownloadPath + ".part";

        try
        {
            progress?.Report(new SyncProgress
            {
                Message = $"Downloading SoulspireXI Launcher {update.LatestTag}...",
                Percent = 5
            });

            using (var response = await _http.GetAsync(update.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                       .ConfigureAwait(false))
            {
                response.EnsureSuccessStatusCode();
                var totalBytes = response.Content.Headers.ContentLength ?? update.ExpectedSize;

                await using var remoteStream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                await using var fileStream = File.Create(partPath);
                var buffer = new byte[81920];
                long totalRead = 0;
                int read;
                while ((read = await remoteStream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    await fileStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    totalRead += read;

                    if (totalBytes > 0)
                    {
                        var pct = 5 + (75.0 * totalRead / totalBytes);
                        progress?.Report(new SyncProgress
                        {
                            Message = $"Downloading SoulspireXI Launcher {update.LatestTag}... ({totalRead / (1024 * 1024.0):F1} MB)",
                            Percent = Math.Min(80, pct)
                        });
                    }
                }
            }

            File.Move(partPath, finalDownloadPath, overwrite: true);

            progress?.Report(new SyncProgress
            {
                Message = $"Verifying SHA-256 integrity for {update.LatestTag}...",
                Percent = 85
            });

            if (isZip)
            {
                var meta = update.ReleaseMetadata ?? new LauncherReleaseMetadata
                {
                    Channel = GetChannelSlug(update.Channel),
                    Version = update.LatestTag,
                    Tag = update.LatestTag,
                    PackageType = "zip",
                    DownloadUrl = update.DownloadUrl,
                    Sha256 = update.ExpectedSha256,
                    Size = update.ExpectedSize,
                    ExecutableName = CanonicalLauncherExeName,
                    ExecutableSha256 = update.ExpectedExecutableSha256,
                    UpdaterName = LauncherInstallationService.CanonicalUpdaterExeName,
                    UpdaterSha256 = update.ExpectedUpdaterSha256
                };

                var extractDir = Path.Combine(sessionDir, "extracted");
                var extracted = LauncherPackageVerifier.VerifyAndExtractZipPackage(
                    finalDownloadPath,
                    meta,
                    extractDir,
                    minimumExeBytes: minimumExeBytes,
                    requirePeHeader: requirePeHeader);
                if (!extracted.Success)
                {
                    throw new InvalidDataException(extracted.ErrorMessage);
                }

                progress?.Report(new SyncProgress
                {
                    Message = $"Verified {update.LatestTag} (SHA-256 {extracted.ExtractedExeSha256[..12]}). Ready to install...",
                    Percent = 100
                });

                return new StagedLauncherUpdate(
                    sessionDir,
                    extracted.ExtractedExePath,
                    extracted.ExtractedExeSha256,
                    extracted.ExtractedUpdaterPath,
                    extracted.ExtractedUpdaterSha256,
                    update.LatestTag,
                    GetChannelSlug(update.Channel));
            }
            else
            {
                var expectedSha = !string.IsNullOrWhiteSpace(update.ExpectedExecutableSha256)
                    ? update.ExpectedExecutableSha256
                    : update.ExpectedSha256;
                var check = LauncherPackageVerifier.VerifyFileIntegrity(
                    finalDownloadPath,
                    expectedSha,
                    update.ExpectedSize,
                    minimumSizeBytes: minimumExeBytes,
                    requirePeHeader: requirePeHeader);
                if (!check.IsValid)
                {
                    throw new InvalidDataException(check.ErrorMessage);
                }

                progress?.Report(new SyncProgress
                {
                    Message = $"Verified {update.LatestTag} (SHA-256 {check.ComputedSha256[..12]}). Ready to install...",
                    Percent = 100
                });

                return new StagedLauncherUpdate(
                    sessionDir,
                    finalDownloadPath,
                    check.ComputedSha256,
                    null,
                    null,
                    update.LatestTag,
                    GetChannelSlug(update.Channel));
            }
        }
        catch
        {
            try
            {
                if (File.Exists(partPath)) File.Delete(partPath);
                if (Directory.Exists(sessionDir)) Directory.Delete(sessionDir, recursive: true);
            }
            catch
            {
                // Best-effort cleanup of interrupted/corrupt staging session.
            }

            throw;
        }
    }

    /// <summary>
    /// Backwards-compatible download wrapper returning the staged executable path.
    /// </summary>
    public async Task<string> DownloadUpdateAsync(
        LauncherUpdateCheckResult update,
        IProgress<SyncProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var staged = await DownloadAndVerifyUpdateAsync(update, progress, cancellationToken).ConfigureAwait(false);
        return staged.StagedExePath;
    }

    /// <summary>
    /// Stages the LOCAL trusted SoulspireUpdater.exe into the temp staging directory outside the
    /// active installation directory, writes a verified update-plan.json, and launches the updater.
    /// Never executes an unverified downloaded updater binary.
    /// </summary>
    public bool LaunchStandaloneUpdaterAndPrepareRestart(
        StagedLauncherUpdate staged,
        string currentExePath,
        string? currentVersion = null)
    {
        var canonicalTargetExe = ResolveCanonicalTargetExePath(currentExePath);
        var installRoot = Path.GetDirectoryName(canonicalTargetExe) ?? string.Empty;
        var localTrustedUpdater = Path.Combine(installRoot, LauncherInstallationService.CanonicalUpdaterExeName);

        var plan = new LauncherUpdatePlan
        {
            Operation = "apply",
            ParentProcessId = Environment.ProcessId,
            InstallRoot = installRoot,
            TargetExePath = canonicalTargetExe,
            StagedExePath = staged.StagedExePath,
            ExpectedExeSha256 = staged.VerifiedExeSha256,
            StagedUpdaterPath = staged.StagedUpdaterPath,
            ExpectedUpdaterSha256 = staged.VerifiedUpdaterSha256,
            CurrentVersion = currentVersion ?? GetCurrentInformationalVersion(),
            TargetVersion = staged.TargetVersion,
            Channel = staged.ChannelSlug,
            StagingDirectory = staged.StagingDirectory,
            RestartArguments = $"{JustUpdatedArg} {UpdatedFromArg} \"{currentVersion ?? GetCurrentInformationalVersion()}\" {UpdatedToArg} \"{staged.TargetVersion}\""
        };

        Directory.CreateDirectory(staged.StagingDirectory);
        var planPath = Path.Combine(staged.StagingDirectory, "update-plan.json");
        File.WriteAllText(planPath, JsonSerializer.Serialize(plan, JsonOptions), Encoding.UTF8);

        // Preferred path: invoke our own ALREADY-INSTALLED trusted SoulspireUpdater.exe copied out of installRoot.
        // Secondary trusted path: only if localTrustedUpdater doesn't exist yet (first upgrade from legacy single-file EXE)
        // AND staged.StagedUpdaterPath was already verified by SHA-256 + signature against authenticated release metadata.
        string? trustedUpdaterSource = null;
        if (File.Exists(localTrustedUpdater))
        {
            trustedUpdaterSource = localTrustedUpdater;
        }
        else if (!string.IsNullOrWhiteSpace(staged.StagedUpdaterPath) &&
                 !string.IsNullOrWhiteSpace(staged.VerifiedUpdaterSha256) &&
                 File.Exists(staged.StagedUpdaterPath))
        {
            var verifyStagedUpdater = LauncherPackageVerifier.VerifyFileIntegrity(
                staged.StagedUpdaterPath,
                staged.VerifiedUpdaterSha256,
                expectedSize: 0,
                minimumSizeBytes: 64,
                requirePeHeader: true);
            if (verifyStagedUpdater.IsValid)
            {
                trustedUpdaterSource = staged.StagedUpdaterPath;
            }
        }

        if (!string.IsNullOrWhiteSpace(trustedUpdaterSource))
        {
            var runnerCopy = Path.Combine(staged.StagingDirectory, "SoulspireUpdater-Runner.exe");
            File.Copy(trustedUpdaterSource, runnerCopy, overwrite: true);

            Process.Start(new ProcessStartInfo
            {
                FileName = runnerCopy,
                Arguments = $"--apply --plan \"{planPath}\" --parent-pid {Environment.ProcessId}",
                WorkingDirectory = staged.StagingDirectory,
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden
            });
            return true;
        }

        // Legacy fallback for older single-file releases without SoulspireUpdater.exe
        LaunchUpdaterAndPrepareRestart(staged.StagedExePath, canonicalTargetExe);
        return false;
    }

    public bool LaunchRollbackAndPrepareRestart(string currentExePath)
    {
        var canonicalTargetExe = ResolveCanonicalTargetExePath(currentExePath);
        var installRoot = Path.GetDirectoryName(canonicalTargetExe) ?? string.Empty;
        if (!LauncherInstallationService.CanRollback(installRoot, out _))
        {
            throw new InvalidOperationException("No verified previous launcher backup is available for rollback.");
        }

        var localTrustedUpdater = Path.Combine(installRoot, LauncherInstallationService.CanonicalUpdaterExeName);
        if (!File.Exists(localTrustedUpdater))
        {
            throw new FileNotFoundException(
                "SoulspireUpdater.exe was not found next to SoulspireLauncher.exe; cannot launch automated rollback.",
                localTrustedUpdater);
        }

        var stagingDir = Path.Combine(GetStagingDirectory(), $"rollback-{Guid.NewGuid():N}");
        Directory.CreateDirectory(stagingDir);
        var runnerCopy = Path.Combine(stagingDir, "SoulspireUpdater-Rollback.exe");
        File.Copy(localTrustedUpdater, runnerCopy, overwrite: true);

        Process.Start(new ProcessStartInfo
        {
            FileName = runnerCopy,
            Arguments = $"--rollback --install-root \"{installRoot}\" --parent-pid {Environment.ProcessId}",
            WorkingDirectory = stagingDir,
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden
        });
        return true;
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
        var backupTarget = canonicalTarget + ".bak";
        return string.Join(
            "\r\n",
            "@echo off",
            "setlocal",
            $"set \"TARGET_PID={currentPid}\"",
            $"set \"SRC={stagedExePath}\"",
            $"set \"DST={canonicalTarget}\"",
            $"set \"BAK={backupTarget}\"",
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
            "if exist \"%DST%\" copy /Y \"%DST%\" \"%BAK%\" >nul 2>&1",
            "set /a COPY_COUNT=0",
            ":copyloop",
            "copy /Y \"%SRC%\" \"%DST%\" >nul 2>&1",
            "if errorlevel 1 (",
            "  set /a COPY_COUNT+=1",
            "  if %COPY_COUNT% GEQ 20 goto rollback",
            "  ping -n 2 127.0.0.1 >nul",
            "  goto copyloop",
            ")",
            "if not exist \"%DST%\" goto rollback",
            "del /F /Q \"%SRC%\" >nul 2>&1",
            $"start \"\" \"%DST%\" {JustUpdatedArg}",
            "goto cleanup",
            ":rollback",
            "if exist \"%BAK%\" copy /Y \"%BAK%\" \"%DST%\" >nul 2>&1",
            $"if exist \"%DST%\" start \"\" \"%DST%\" {UpdateFailedArg}",
            ":cleanup",
            "del /F /Q \"%~f0\" >nul 2>&1");
    }

    public static void CleanupStagingDirectory(string? stagingRootOverride = null)
    {
        try
        {
            var dir = stagingRootOverride ?? GetStagingDirectory();
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

    public static string GetStagingDirectory() =>
        Path.Combine(Path.GetTempPath(), "SoulspireLauncher-Update");
}

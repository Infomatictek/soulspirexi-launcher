using System.Text.Json.Serialization;

namespace SoulspireLauncher.Models;

public enum LauncherUpdateStage
{
    Idle = 0,
    Checking = 1,
    UpToDate = 2,
    UpdateAvailable = 3,
    DeferredActiveRelay = 4,
    Downloading = 5,
    Verifying = 6,
    Staging = 7,
    Installing = 8,
    Restarting = 9,
    Completed = 10,
    RollingBack = 11,
    Failed = 12
}

/// <summary>
/// Authenticated launcher release metadata published per channel (stable / testing-core-ui).
/// Strictly separated from game-content manifest.json versions.
/// </summary>
public sealed class LauncherReleaseMetadata
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("channel")]
    public string Channel { get; set; } = "stable";

    [JsonPropertyName("version")]
    public string Version { get; set; } = string.Empty;

    [JsonPropertyName("tag")]
    public string Tag { get; set; } = string.Empty;

    [JsonPropertyName("publishedAtUtc")]
    public string PublishedAtUtc { get; set; } = string.Empty;

    [JsonPropertyName("minUpgradeFromVersion")]
    public string? MinUpgradeFromVersion { get; set; }

    [JsonPropertyName("packageType")]
    public string PackageType { get; set; } = "zip";

    [JsonPropertyName("assetName")]
    public string AssetName { get; set; } = "SoulspireLauncher-win-x64.zip";

    [JsonPropertyName("downloadUrl")]
    public string DownloadUrl { get; set; } = string.Empty;

    [JsonPropertyName("sha256")]
    public string Sha256 { get; set; } = string.Empty;

    [JsonPropertyName("size")]
    public long Size { get; set; }

    [JsonPropertyName("executableName")]
    public string ExecutableName { get; set; } = "SoulspireLauncher.exe";

    [JsonPropertyName("executableSha256")]
    public string ExecutableSha256 { get; set; } = string.Empty;

    [JsonPropertyName("updaterName")]
    public string? UpdaterName { get; set; } = "SoulspireUpdater.exe";

    [JsonPropertyName("updaterSha256")]
    public string? UpdaterSha256 { get; set; }

    [JsonPropertyName("releaseUrl")]
    public string ReleaseUrl { get; set; } = string.Empty;

    [JsonPropertyName("releaseNotes")]
    public string ReleaseNotes { get; set; } = string.Empty;

    [JsonPropertyName("signatureAlgorithm")]
    public string? SignatureAlgorithm { get; set; }

    [JsonPropertyName("signatureBase64")]
    public string? SignatureBase64 { get; set; }

    [JsonPropertyName("signatureKeyId")]
    public string? SignatureKeyId { get; set; }
}

/// <summary>
/// Persisted per-installation state stored in <installRoot>\install-state.json.
/// Tracks active release version, rollback backup hash, and interrupted-update recovery state.
/// Never overwrites user game settings in %APPDATA%\SoulspireXI\settings.json.
/// </summary>
public sealed class LauncherInstallState
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("installMode")]
    public string InstallMode { get; set; } = "portable";

    [JsonPropertyName("installRoot")]
    public string InstallRoot { get; set; } = string.Empty;

    [JsonPropertyName("channel")]
    public string Channel { get; set; } = "stable";

    [JsonPropertyName("currentVersion")]
    public string CurrentVersion { get; set; } = string.Empty;

    [JsonPropertyName("currentReleaseDir")]
    public string CurrentReleaseDir { get; set; } = string.Empty;

    [JsonPropertyName("activeExecutableSha256")]
    public string ActiveExecutableSha256 { get; set; } = string.Empty;

    [JsonPropertyName("previousVersion")]
    public string? PreviousVersion { get; set; }

    [JsonPropertyName("previousBackupPath")]
    public string? PreviousBackupPath { get; set; }

    [JsonPropertyName("previousBackupSha256")]
    public string? PreviousBackupSha256 { get; set; }

    [JsonPropertyName("pendingVerification")]
    public bool PendingVerification { get; set; }

    [JsonPropertyName("pendingTargetVersion")]
    public string? PendingTargetVersion { get; set; }

    [JsonPropertyName("lastUpdateStatus")]
    public string LastUpdateStatus { get; set; } = "idle";

    [JsonPropertyName("lastUpdateError")]
    public string? LastUpdateError { get; set; }

    [JsonPropertyName("updatedAtUtc")]
    public string UpdatedAtUtc { get; set; } = string.Empty;
}

/// <summary>
/// Plan written by the trusted running launcher and consumed by SoulspireUpdater.exe.
/// </summary>
public sealed class LauncherUpdatePlan
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("operation")]
    public string Operation { get; set; } = "apply";

    [JsonPropertyName("parentProcessId")]
    public int ParentProcessId { get; set; }

    [JsonPropertyName("installRoot")]
    public string InstallRoot { get; set; } = string.Empty;

    [JsonPropertyName("targetExePath")]
    public string TargetExePath { get; set; } = string.Empty;

    [JsonPropertyName("stagedExePath")]
    public string StagedExePath { get; set; } = string.Empty;

    [JsonPropertyName("expectedExeSha256")]
    public string ExpectedExeSha256 { get; set; } = string.Empty;

    [JsonPropertyName("stagedUpdaterPath")]
    public string? StagedUpdaterPath { get; set; }

    [JsonPropertyName("expectedUpdaterSha256")]
    public string? ExpectedUpdaterSha256 { get; set; }

    [JsonPropertyName("currentVersion")]
    public string CurrentVersion { get; set; } = string.Empty;

    [JsonPropertyName("targetVersion")]
    public string TargetVersion { get; set; } = string.Empty;

    [JsonPropertyName("channel")]
    public string Channel { get; set; } = "stable";

    [JsonPropertyName("stagingDirectory")]
    public string StagingDirectory { get; set; } = string.Empty;

    [JsonPropertyName("restartArguments")]
    public string RestartArguments { get; set; } = string.Empty;
}

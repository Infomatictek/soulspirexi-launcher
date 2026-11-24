using System.Text.Json.Serialization;

namespace SoulspireLauncher.Models;

public sealed class LauncherManifest
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("channel")]
    public string Channel { get; set; } = "stable";

    [JsonPropertyName("candidateId")]
    public string? CandidateId { get; set; }

    [JsonPropertyName("manifestVersion")]
    public string ManifestVersion { get; set; } = "2.1.0";

    [JsonPropertyName("minLauncherVersion")]
    public string? MinLauncherVersion { get; set; }

    [JsonPropertyName("serverCompatibility")]
    public ManifestServerCompatibility? ServerCompatibility { get; set; }

    [JsonPropertyName("registry")]
    public ManifestRegistryMetadata? Registry { get; set; }

    [JsonPropertyName("clientDataCache")]
    public ManifestClientDataCache? ClientDataCache { get; set; }

    [JsonPropertyName("serverName")]
    public string ServerName { get; set; } = "SoulspireXI";

    [JsonPropertyName("tagline")]
    public string Tagline { get; set; } = string.Empty;

    [JsonPropertyName("defaultHost")]
    public string DefaultHost { get; set; } = "play.soulspirexi.com";

    [JsonPropertyName("useHairpin")]
    public bool UseHairpin { get; set; }

    [JsonPropertyName("ports")]
    public ManifestPorts Ports { get; set; } = new();

    [JsonPropertyName("stagingServer")]
    public ManifestStagingServer? StagingServer { get; set; }

    [JsonPropertyName("repo")]
    public ManifestRepo Repo { get; set; } = new();

    [JsonPropertyName("bootstrap")]
    public ManifestBootstrap Bootstrap { get; set; } = new();

    [JsonPropertyName("files")]
    public List<ManifestFileEntry> Files { get; set; } = [];

    [JsonPropertyName("optionalOverlays")]
    public List<ManifestOptionalOverlay> OptionalOverlays { get; set; } = [];

    [JsonPropertyName("news")]
    public List<ManifestNewsItem> News { get; set; } = [];

    [JsonIgnore]
    public string? ResolvedRawBaseUrl { get; set; }
}

public sealed class ManifestPorts
{
    [JsonPropertyName("lobby")]
    public int Lobby { get; set; } = 54231;

    [JsonPropertyName("auth")]
    public int Auth { get; set; } = 54001;

    [JsonPropertyName("search")]
    public int Search { get; set; } = 54002;
}

public sealed class ManifestStagingServer
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "SoulspireXI Staging";

    [JsonPropertyName("host")]
    public string Host { get; set; } = LauncherSettings.DefaultStagingHost;

    [JsonPropertyName("useHairpin")]
    public bool UseHairpin { get; set; }

    [JsonPropertyName("localLoopbackHost")]
    public string LocalLoopbackHost { get; set; } = "127.0.0.1";

    [JsonPropertyName("ports")]
    public ManifestStagingPorts Ports { get; set; } = new();

    [JsonPropertyName("notes")]
    public string Notes { get; set; } = string.Empty;
}

public sealed class ManifestStagingPorts
{
    [JsonPropertyName("auth")]
    public int Auth { get; set; } = LauncherSettings.DefaultStagingAuthPort;

    [JsonPropertyName("data")]
    public int Data { get; set; } = LauncherSettings.DefaultStagingDataPort;

    [JsonPropertyName("view")]
    public int View { get; set; } = LauncherSettings.DefaultStagingViewPort;

    [JsonPropertyName("search")]
    public int Search { get; set; } = LauncherSettings.DefaultStagingSearchPort;

    [JsonPropertyName("profile")]
    public int Profile { get; set; } = LauncherSettings.DefaultStagingProfilePort;

    [JsonPropertyName("profileIrc")]
    public int ProfileIrc { get; set; } = LauncherSettings.DefaultStagingProfileIrcPort;

    [JsonPropertyName("map")]
    public int Map { get; set; } = LauncherSettings.DefaultStagingMapPort;
}

public sealed class ManifestRepo
{
    [JsonPropertyName("owner")]
    public string Owner { get; set; } = "Infomatictek";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "soulspirexi-launcher";

    [JsonPropertyName("branch")]
    public string Branch { get; set; } = "main";

    [JsonPropertyName("rawBaseUrl")]
    public string RawBaseUrl { get; set; } = "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/main";
}

public sealed class ManifestBootstrap
{
    [JsonPropertyName("ashitaZipUrl")]
    public string AshitaZipUrl { get; set; } = "https://github.com/AshitaXI/Ashita-v4beta/archive/refs/heads/main.zip";

    [JsonPropertyName("xiloaderLatestApiUrl")]
    public string XiloaderLatestApiUrl { get; set; } = "https://api.github.com/repos/LandSandBoat/xiloader/releases/latest";

    [JsonPropertyName("xipivotLatestApiUrl")]
    public string XipivotLatestApiUrl { get; set; } = "https://api.github.com/repos/HealsCodes/XIPivot/releases/latest";

    [JsonPropertyName("metricsLatestApiUrl")]
    public string MetricsLatestApiUrl { get; set; } = "https://api.github.com/repos/RaraProjects/metrics/releases/latest";

    [JsonPropertyName("mobdbLatestApiUrl")]
    public string MobDbLatestApiUrl { get; set; } = "https://api.github.com/repos/ThornyFFXI/mobdb/releases/latest";

    [JsonPropertyName("kazenoeyeLatestApiUrl")]
    public string KazenoeyeLatestApiUrl { get; set; } = "https://api.github.com/repos/kazenohito/kazenoeye/releases/latest";
}

public sealed class ManifestFileEntry
{
    [JsonPropertyName("category")]
    public string Category { get; set; } = string.Empty;

    [JsonPropertyName("sourcePath")]
    public string SourcePath { get; set; } = string.Empty;

    [JsonPropertyName("targetPath")]
    public string TargetPath { get; set; } = string.Empty;

    [JsonPropertyName("sha256")]
    public string Sha256 { get; set; } = string.Empty;

    [JsonPropertyName("size")]
    public long Size { get; set; }

    [JsonPropertyName("downloadUrl")]
    public string? DownloadUrl { get; set; }

    [JsonIgnore]
    public string? OverlayFolder { get; set; }
}

public sealed class ManifestServerCompatibility
{
    [JsonPropertyName("version")]
    public string Version { get; set; } = string.Empty;

    [JsonPropertyName("branch")]
    public string Branch { get; set; } = string.Empty;

    [JsonPropertyName("commit")]
    public string Commit { get; set; } = string.Empty;

    [JsonPropertyName("dockerImage")]
    public string DockerImage { get; set; } = string.Empty;

    [JsonPropertyName("nativeHooks")]
    public int? NativeHooks { get; set; }

    [JsonPropertyName("crystalJobsHooks")]
    public int? CrystalJobsHooks { get; set; }

    [JsonPropertyName("notes")]
    public string Notes { get; set; } = string.Empty;
}

public sealed class ManifestRegistryMetadata
{
    [JsonPropertyName("version")]
    public string Version { get; set; } = string.Empty;

    [JsonPropertyName("hash")]
    public string Hash { get; set; } = string.Empty;

    [JsonPropertyName("idLockStatus")]
    public string IdLockStatus { get; set; } = string.Empty;

    [JsonPropertyName("nativeDllCompiledHash")]
    public string NativeDllCompiledHash { get; set; } = string.Empty;

    [JsonPropertyName("nativeDllSha256")]
    public string NativeDllSha256 { get; set; } = string.Empty;

    [JsonPropertyName("nativeDllClientVerified")]
    public bool NativeDllClientVerified { get; set; }

    [JsonPropertyName("nativeHooks")]
    public int? NativeHooks { get; set; }

    [JsonPropertyName("crystalJobsHooks")]
    public int CrystalJobsHooks { get; set; } = 27;
}

public sealed class InstalledClientState
{
    [JsonPropertyName("channel")]
    public string Channel { get; set; } = "stable";

    [JsonPropertyName("candidateId")]
    public string? CandidateId { get; set; }

    [JsonPropertyName("manifestVersion")]
    public string ManifestVersion { get; set; } = string.Empty;

    [JsonPropertyName("serverVersion")]
    public string ServerVersion { get; set; } = string.Empty;

    [JsonPropertyName("registryVersion")]
    public string RegistryVersion { get; set; } = string.Empty;

    [JsonPropertyName("registryHash")]
    public string RegistryHash { get; set; } = string.Empty;

    [JsonPropertyName("lastSyncedUtc")]
    public DateTimeOffset LastSyncedUtc { get; set; } = DateTimeOffset.UtcNow;

    [JsonPropertyName("managedFiles")]
    public List<InstalledManagedFile> ManagedFiles { get; set; } = [];
}

public sealed class InstalledManagedFile
{
    [JsonPropertyName("category")]
    public string Category { get; set; } = string.Empty;

    [JsonPropertyName("targetPath")]
    public string TargetPath { get; set; } = string.Empty;

    [JsonPropertyName("overlayFolder")]
    public string? OverlayFolder { get; set; }

    [JsonPropertyName("sha256")]
    public string Sha256 { get; set; } = string.Empty;
}

public sealed class ManifestSoulGate
{
    [JsonPropertyName("job")]
    public int Job { get; set; }

    [JsonPropertyName("branch")]
    public int Branch { get; set; }

    [JsonPropertyName("soul")]
    public string Soul { get; set; } = string.Empty;
}

public sealed class ManifestOptionalOverlay
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = string.Empty;

    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("description")]
    public string Description { get; set; } = string.Empty;

    [JsonPropertyName("overlayFolder")]
    public string OverlayFolder { get; set; } = string.Empty;

    [JsonPropertyName("defaultEnabled")]
    public bool DefaultEnabled { get; set; }

    [JsonPropertyName("soulGate")]
    public ManifestSoulGate? SoulGate { get; set; }

    [JsonPropertyName("files")]
    public List<ManifestFileEntry> Files { get; set; } = [];
}

public sealed class ManifestNewsItem
{
    [JsonPropertyName("date")]
    public string Date { get; set; } = string.Empty;

    [JsonPropertyName("title")]
    public string Title { get; set; } = string.Empty;

    [JsonPropertyName("body")]
    public string Body { get; set; } = string.Empty;
}

public sealed class ManifestClientDataCache
{
    [JsonPropertyName("schemaVersion")]
    public int SchemaVersion { get; set; } = 1;

    [JsonPropertyName("protocolVersion")]
    public int ProtocolVersion { get; set; } = 2;

    [JsonPropertyName("contentVersion")]
    public string ContentVersion { get; set; } = string.Empty;

    [JsonPropertyName("contentHash")]
    public string ContentHash { get; set; } = string.Empty;

    [JsonPropertyName("registryHash")]
    public string RegistryHash { get; set; } = string.Empty;

    [JsonPropertyName("manifestTargetPath")]
    public string ManifestTargetPath { get; set; } = "soulspire_core/cache/manifest.json";

    [JsonPropertyName("manifestSha256")]
    public string ManifestSha256 { get; set; } = string.Empty;

    [JsonPropertyName("packageCount")]
    public int PackageCount { get; set; }
}

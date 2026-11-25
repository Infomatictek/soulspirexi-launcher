using System.Text.Json.Serialization;

namespace SoulspireLauncher.Models;

public sealed class ClientPerfBundle
{
    [JsonPropertyName("schema_version")]
    public string SchemaVersion { get; set; } = "client-perf-1.0.0";

    [JsonPropertyName("record_kind")]
    public string RecordKind { get; set; } = "client_automated_baseline";

    [JsonPropertyName("captured_at_utc")]
    public string CapturedAtUtc { get; set; } = string.Empty;

    [JsonPropertyName("source_channel")]
    public string SourceChannel { get; set; } = "testing";

    [JsonPropertyName("launcher_version")]
    public string LauncherVersion { get; set; } = string.Empty;

    [JsonPropertyName("server_target_class")]
    public string ServerTargetClass { get; set; } = "main";

    [JsonPropertyName("server_build_tag")]
    public string ServerBuildTag { get; set; } = "unknown";

    [JsonPropertyName("privacy_redacted")]
    public bool PrivacyRedacted { get; set; } = true;

    [JsonPropertyName("client_env")]
    public ClientEnvInfo ClientEnv { get; set; } = new();

    [JsonPropertyName("overhead")]
    public DiagOverheadStats Overhead { get; set; } = new();

    [JsonPropertyName("launcher_flows")]
    public Dictionary<string, FlowModeGroup> LauncherFlows { get; set; } = new();

    [JsonPropertyName("client_flows")]
    public Dictionary<string, FlowModeGroup> ClientFlows { get; set; } = new();

    [JsonPropertyName("runtime_health")]
    public RuntimeHealthStats RuntimeHealth { get; set; } = new();
}

public sealed class ClientEnvInfo
{
    [JsonPropertyName("os")]
    public string Os { get; set; } = "Windows";

    [JsonPropertyName("cpu_class")]
    public string CpuClass { get; set; } = "x86_64";

    [JsonPropertyName("ram_gb")]
    public double RamGb { get; set; }

    [JsonPropertyName("transport")]
    public string Transport { get; set; } = "unknown";
}

public sealed class DiagOverheadStats
{
    [JsonPropertyName("diag_cpu_ms_total")]
    public double DiagCpuMsTotal { get; set; }

    [JsonPropertyName("diag_p99_callback_ms")]
    public double DiagP99CallbackMs { get; set; }

    [JsonPropertyName("lua_mem_kb_delta")]
    public double LuaMemKbDelta { get; set; }

    [JsonPropertyName("dropped_samples")]
    public int DroppedSamples { get; set; }
}

public sealed class FlowOutcomes
{
    [JsonPropertyName("complete")]
    public int Complete { get; set; }

    [JsonPropertyName("failed")]
    public int Failed { get; set; }

    [JsonPropertyName("cancelled")]
    public int Cancelled { get; set; }

    [JsonPropertyName("incomplete")]
    public int Incomplete { get; set; }
}

public sealed class FlowStats
{
    [JsonPropertyName("n")]
    public int N { get; set; }

    [JsonPropertyName("p50_ms")]
    public double P50Ms { get; set; }

    [JsonPropertyName("p95_ms")]
    public double? P95Ms { get; set; }

    [JsonPropertyName("p99_ms")]
    public double? P99Ms { get; set; }

    [JsonPropertyName("max_ms")]
    public double MaxMs { get; set; }

    [JsonPropertyName("failures")]
    public int Failures { get; set; }

    [JsonPropertyName("retries")]
    public int Retries { get; set; }

    [JsonPropertyName("timeouts")]
    public int Timeouts { get; set; }

    [JsonPropertyName("cancelled")]
    public int Cancelled { get; set; }

    [JsonPropertyName("incomplete")]
    public int Incomplete { get; set; }

    [JsonPropertyName("files")]
    public int? Files { get; set; }

    [JsonPropertyName("bytes")]
    public long? Bytes { get; set; }

    [JsonPropertyName("bytes_in")]
    public long? BytesIn { get; set; }

    [JsonPropertyName("packets_in")]
    public int? PacketsIn { get; set; }

    [JsonPropertyName("outcomes")]
    public FlowOutcomes Outcomes { get; set; } = new();

    [JsonPropertyName("attribution_scope")]
    public string AttributionScope { get; set; } = "client_only";
}

public sealed class FlowModeGroup
{
    [JsonPropertyName("cold")]
    public FlowStats? Cold { get; set; }

    [JsonPropertyName("warm")]
    public FlowStats? Warm { get; set; }

    [JsonPropertyName("legacy_fallback_count")]
    public int? LegacyFallbackCount { get; set; }

    [JsonPropertyName("op_cache_sync_count")]
    public int? OpCacheSyncCount { get; set; }
}

public sealed class FrameMsStats
{
    [JsonPropertyName("n")]
    public int N { get; set; }

    [JsonPropertyName("p50")]
    public double P50 { get; set; }

    [JsonPropertyName("p95")]
    public double P95 { get; set; }

    [JsonPropertyName("p99")]
    public double P99 { get; set; }

    [JsonPropertyName("max")]
    public double Max { get; set; }

    [JsonPropertyName("hitches_gt_33ms")]
    public int HitchesGt33Ms { get; set; }

    [JsonPropertyName("hitches_gt_100ms")]
    public int HitchesGt100Ms { get; set; }
}

public sealed class RuntimeHealthStats
{
    [JsonPropertyName("frame_ms")]
    public FrameMsStats? FrameMs { get; set; }

    [JsonPropertyName("pol_private_mb_max")]
    public double? PolPrivateMbMax { get; set; }

    [JsonPropertyName("packet_counters")]
    public Dictionary<string, long>? PacketCounters { get; set; }

    [JsonPropertyName("cache_stats")]
    public Dictionary<string, double>? CacheStats { get; set; }
}

public sealed class CorePerfConfigFile
{
    [JsonPropertyName("schema_version")]
    public string SchemaVersion { get; set; } = "soulspire-perf-diag-config-1.0.0";

    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; }

    [JsonPropertyName("source_channel")]
    public string SourceChannel { get; set; } = "testing";

    [JsonPropertyName("server_target_class")]
    public string ServerTargetClass { get; set; } = "main";
}

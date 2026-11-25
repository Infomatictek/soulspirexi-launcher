using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed record LauncherPerfExportResult(
    bool Success,
    string JsonPath,
    string SummaryPath,
    long ByteSize,
    string Message);

public sealed class PerformanceDiagnosticsService : IDisposable
{
    public const int MaxBundleBytes = 512 * 1024;
    public const string CoreConfigRelativePath = @"addons\ashita4\config\soulspire_perf_diag.json";
    public const string CoreExportRelativePath = @"logs\soulspire_perf\core-perf-latest.json";

    private const int MaxFlowSamples = 256;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static readonly Regex WindowsPathRegex = new(@"[A-Za-z]:\\[^\s""',;]+", RegexOptions.Compiled);
    private static readonly Regex UncPathRegex = new(@"\\\\[^\s""',;]+", RegexOptions.Compiled);
    private static readonly Regex UnixPathRegex = new(@"/(?:mnt|root|home)/[A-Za-z0-9._/\-]+", RegexOptions.Compiled);
    private static readonly Regex Ipv4Regex = new(@"\b(?:\d{1,3}\.){3}\d{1,3}\b", RegexOptions.Compiled);
    private static readonly Regex EmailRegex = new(@"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", RegexOptions.Compiled);

    private sealed class FlowSample
    {
        public double DurationMs { get; init; }
        public string Outcome { get; init; } = "complete";
        public string Scope { get; init; } = "client_only";
        public int? Files { get; init; }
        public long? Bytes { get; init; }
        public int Retries { get; init; }
    }

    private sealed class ModeBucket
    {
        public List<FlowSample> Samples { get; } = [];
        public int Complete { get; set; }
        public int Failed { get; set; }
        public int Cancelled { get; set; }
        public int Incomplete { get; set; }
        public int Retries { get; set; }
        public int FilesTotal { get; set; }
        public long BytesTotal { get; set; }
        public bool HasFiles { get; set; }
        public bool HasBytes { get; set; }
        public string Scope { get; set; } = "client_only";
    }

    private readonly object _lock = new();
    private readonly Dictionary<string, (ModeBucket Cold, ModeBucket Warm)> _launcherFlows = new(StringComparer.Ordinal);
    private readonly HashSet<string> _seenColdFlows = new(StringComparer.Ordinal);
    private readonly List<double> _overheadCallbackSamplesMs = [];
    private double _diagCpuMsTotal;
    private int _droppedSamples;
    private double? _polPeakMb;
    private Process? _watchedProcess;
    private CancellationTokenSource? _monitorCts;
    private Task? _monitorTask;

    public string DiagnosticsDirectory { get; }

    public PerformanceDiagnosticsService(string? diagnosticsDirectory = null)
    {
        DiagnosticsDirectory = string.IsNullOrWhiteSpace(diagnosticsDirectory)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "SoulspireXI",
                "Diagnostics")
            : diagnosticsDirectory;
    }

    public static Stopwatch? StartSpanIfEnabled(bool enabled) => enabled ? Stopwatch.StartNew() : null;

    public void RecordSpan(
        bool enabled,
        string flowName,
        Stopwatch? sw,
        bool isCold,
        string outcome = "complete",
        string scope = "client_only",
        int? files = null,
        long? bytes = null,
        int retries = 0)
    {
        if (!enabled || sw is null || string.IsNullOrWhiteSpace(flowName))
        {
            return;
        }

        sw.Stop();
        RecordDurationMs(enabled, flowName, sw.Elapsed.TotalMilliseconds, isCold, outcome, scope, files, bytes, retries);
    }

    public void RecordDurationMs(
        bool enabled,
        string flowName,
        double durationMs,
        bool? isColdOverride = null,
        string outcome = "complete",
        string scope = "client_only",
        int? files = null,
        long? bytes = null,
        int retries = 0)
    {
        if (!enabled || string.IsNullOrWhiteSpace(flowName))
        {
            return;
        }

        var cbSw = Stopwatch.StartNew();
        var normalizedOutcome = outcome is "complete" or "failed" or "cancelled" or "incomplete"
            ? outcome
            : "incomplete";

        lock (_lock)
        {
            if (!_launcherFlows.TryGetValue(flowName, out var pair))
            {
                pair = (new ModeBucket { Scope = scope }, new ModeBucket { Scope = scope });
                _launcherFlows[flowName] = pair;
            }

            var isCold = isColdOverride ?? !_seenColdFlows.Contains(flowName);
            _seenColdFlows.Add(flowName);
            var bucket = isCold ? pair.Cold : pair.Warm;
            bucket.Scope = scope;

            switch (normalizedOutcome)
            {
                case "complete":
                    bucket.Complete++;
                    break;
                case "failed":
                    bucket.Failed++;
                    break;
                case "cancelled":
                    bucket.Cancelled++;
                    break;
                default:
                    bucket.Incomplete++;
                    break;
            }

            bucket.Retries += Math.Max(0, retries);
            if (files.HasValue)
            {
                bucket.HasFiles = true;
                bucket.FilesTotal += Math.Max(0, files.Value);
            }

            if (bytes.HasValue)
            {
                bucket.HasBytes = true;
                bucket.BytesTotal += Math.Max(0, bytes.Value);
            }

            if (normalizedOutcome == "complete")
            {
                if (bucket.Samples.Count >= MaxFlowSamples)
                {
                    bucket.Samples.RemoveAt(0);
                    _droppedSamples++;
                }

                bucket.Samples.Add(new FlowSample
                {
                    DurationMs = Math.Max(0, durationMs),
                    Outcome = normalizedOutcome,
                    Scope = scope,
                    Files = files,
                    Bytes = bytes,
                    Retries = retries
                });
            }

            cbSw.Stop();
            var cbMs = cbSw.Elapsed.TotalMilliseconds;
            _diagCpuMsTotal += cbMs;
            if (_overheadCallbackSamplesMs.Count >= 512)
            {
                _overheadCallbackSamplesMs.RemoveAt(0);
            }
            _overheadCallbackSamplesMs.Add(cbMs);
        }
    }

    public static string GetCoreConfigPath(string ashitaPath) =>
        Path.Combine(ashitaPath, CoreConfigRelativePath.Replace('\\', Path.DirectorySeparatorChar));

    public static string GetCoreExportPath(string ashitaPath) =>
        Path.Combine(ashitaPath, CoreExportRelativePath.Replace('\\', Path.DirectorySeparatorChar));

    public static void WriteCoreConfig(LauncherSettings settings, string? manifestChannel = null)
    {
        if (string.IsNullOrWhiteSpace(settings.AshitaPath))
        {
            return;
        }

        var enabled = TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(settings, manifestChannel);
        var path = GetCoreConfigPath(settings.AshitaPath);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);

        var cfg = new CorePerfConfigFile
        {
            Enabled = enabled,
            SourceChannel = LauncherSelfUpdateService.GetChannelSlug(settings.UpdateChannel),
            ServerTargetClass = ResolveServerTargetClass(settings)
        };

        var json = JsonSerializer.Serialize(cfg, JsonOptions);
        File.WriteAllText(path, json + Environment.NewLine, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    public static string ResolveServerTargetClass(LauncherSettings settings) =>
        settings.ServerTarget switch
        {
            ServerTargetMode.Staging => $"staging-{settings.StagingLane.ToString().ToLowerInvariant()}",
            ServerTargetMode.Custom => "custom",
            _ => "main"
        };

    public static string ScrubText(string? input, params string?[] extraSensitiveTokens)
    {
        if (string.IsNullOrEmpty(input))
        {
            return string.Empty;
        }

        var cleaned = UncPathRegex.Replace(input, "<unc-path-redacted>");
        cleaned = WindowsPathRegex.Replace(cleaned, "<win-path-redacted>");
        cleaned = UnixPathRegex.Replace(cleaned, "<host-path-redacted>");
        cleaned = EmailRegex.Replace(cleaned, "<email-redacted>");
        if (!Regex.IsMatch(cleaned.Trim(), @"^\d+\.\d+\.\d+$"))
        {
            cleaned = Ipv4Regex.Replace(cleaned, "<ip-redacted>");
        }

        foreach (var token in extraSensitiveTokens)
        {
            if (!string.IsNullOrWhiteSpace(token) && token.Length >= 2)
            {
                cleaned = cleaned.Replace(token, "<redacted>", StringComparison.OrdinalIgnoreCase);
            }
        }

        var winUser = Environment.UserName;
        if (!string.IsNullOrWhiteSpace(winUser) && winUser.Length >= 2)
        {
            cleaned = cleaned.Replace(winUser, "<user-redacted>", StringComparison.OrdinalIgnoreCase);
        }

        var machine = Environment.MachineName;
        if (!string.IsNullOrWhiteSpace(machine) && machine.Length >= 2)
        {
            cleaned = cleaned.Replace(machine, "<host-redacted>", StringComparison.OrdinalIgnoreCase);
        }

        return cleaned;
    }

    public void StartProcessMonitoring(Process? launchedProcess, bool enabled, Action? onProcessExited = null)
    {
        StopProcessMonitoring();
        if (!enabled || launchedProcess is null)
        {
            return;
        }

        _watchedProcess = launchedProcess;
        _monitorCts = new CancellationTokenSource();
        var token = _monitorCts.Token;

        _monitorTask = Task.Run(async () =>
        {
            try
            {
                while (!token.IsCancellationRequested)
                {
                    SampleGameProcesses();
                    if (_watchedProcess is { HasExited: true })
                    {
                        break;
                    }

                    await Task.Delay(TimeSpan.FromSeconds(5), token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
            }
            catch
            {
            }
            finally
            {
                if (!token.IsCancellationRequested)
                {
                    onProcessExited?.Invoke();
                }
            }
        }, token);
    }

    public void StopProcessMonitoring()
    {
        try
        {
            _monitorCts?.Cancel();
        }
        catch
        {
        }

        _monitorCts?.Dispose();
        _monitorCts = null;
        _watchedProcess = null;
    }

    public void RecordPolMemoryMb(double mb)
    {
        if (double.IsNaN(mb) || double.IsInfinity(mb) || mb < 0)
        {
            return;
        }

        lock (_lock)
        {
            _polPeakMb = _polPeakMb.HasValue ? Math.Max(_polPeakMb.Value, mb) : mb;
        }
    }

    private void SampleGameProcesses()
    {
        try
        {
            foreach (var name in new[] { "pol", "xiloader", "Ashita-cli" })
            {
                foreach (var proc in Process.GetProcessesByName(name))
                {
                    try
                    {
                        proc.Refresh();
                        var mb = proc.PrivateMemorySize64 / (1024.0 * 1024.0);
                        RecordPolMemoryMb(mb);
                    }
                    catch
                    {
                    }
                    finally
                    {
                        proc.Dispose();
                    }
                }
            }
        }
        catch
        {
        }
    }

    public ClientPerfBundle BuildBundle(
        LauncherSettings settings,
        LauncherManifest? manifest,
        string launcherVersion,
        DateTimeOffset? capturedAtUtc = null)
    {
        var serverBuildTag = !string.IsNullOrWhiteSpace(manifest?.ServerCompatibility?.DockerImage)
            ? ScrubText(manifest!.ServerCompatibility!.DockerImage, settings.Username)
            : !string.IsNullOrWhiteSpace(manifest?.ServerCompatibility?.Version)
                ? ScrubText(manifest!.ServerCompatibility!.Version, settings.Username)
                : "unknown";

        if (string.IsNullOrWhiteSpace(serverBuildTag))
        {
            serverBuildTag = "unknown";
        }

        var bundle = new ClientPerfBundle
        {
            CapturedAtUtc = (capturedAtUtc ?? DateTimeOffset.UtcNow).ToString("yyyy-MM-ddTHH:mm:ssZ"),
            SourceChannel = LauncherSelfUpdateService.GetChannelSlug(settings.UpdateChannel),
            LauncherVersion = ScrubText(string.IsNullOrWhiteSpace(launcherVersion) ? "unknown" : launcherVersion, settings.Username),
            ServerTargetClass = ResolveServerTargetClass(settings),
            ServerBuildTag = serverBuildTag,
            PrivacyRedacted = true,
            ClientEnv = new ClientEnvInfo
            {
                Os = ScrubText(RuntimeInformation.OSDescription, settings.Username),
                CpuClass = RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant(),
                RamGb = EstimateTotalRamGb(),
                Transport = settings.ServerTarget == ServerTargetMode.Staging ? "loopback_relay_to_lan_or_wg" : "direct_or_masked"
            }
        };

        List<double> cbCopy;
        double cpuTotal;
        int dropped;
        double? polMax;

        lock (_lock)
        {
            foreach (var kvp in _launcherFlows)
            {
                var grp = new FlowModeGroup
                {
                    Cold = SummarizeBucket(kvp.Value.Cold),
                    Warm = SummarizeBucket(kvp.Value.Warm)
                };
                if (grp.Cold is not null || grp.Warm is not null)
                {
                    bundle.LauncherFlows[kvp.Key] = grp;
                }
            }

            cbCopy = [.. _overheadCallbackSamplesMs];
            cpuTotal = _diagCpuMsTotal;
            dropped = _droppedSamples;
            polMax = _polPeakMb;
        }

        double luaMemKb = 0;
        if (!string.IsNullOrWhiteSpace(settings.AshitaPath))
        {
            MergeCoreExport(GetCoreExportPath(settings.AshitaPath), bundle, ref cpuTotal, cbCopy, ref luaMemKb, ref dropped);
        }

        if (polMax.HasValue)
        {
            bundle.RuntimeHealth.PolPrivateMbMax = Math.Round(polMax.Value, 2);
        }

        cbCopy.Sort();
        bundle.Overhead = new DiagOverheadStats
        {
            DiagCpuMsTotal = Math.Round(cpuTotal, 4),
            DiagP99CallbackMs = Percentile(cbCopy, 0.99),
            LuaMemKbDelta = Math.Round(luaMemKb, 2),
            DroppedSamples = dropped
        };

        return bundle;
    }

    public LauncherPerfExportResult ExportBundle(
        LauncherSettings settings,
        LauncherManifest? manifest,
        string launcherVersion,
        DateTimeOffset? capturedAtUtc = null)
    {
        var stamp = (capturedAtUtc ?? DateTimeOffset.UtcNow).ToString("yyyyMMddTHHmmssZ");
        var jsonPath = Path.Combine(DiagnosticsDirectory, $"client-perf-{stamp}.json");
        var summaryPath = Path.Combine(DiagnosticsDirectory, $"client-perf-{stamp}.summary.txt");

        Directory.CreateDirectory(DiagnosticsDirectory);
        var bundle = BuildBundle(settings, manifest, launcherVersion, capturedAtUtc);

        var raw = SerializeBoundedJson(bundle);
        var bytes = Encoding.UTF8.GetBytes(raw);
        if (bytes.Length > MaxBundleBytes)
        {
            return new LauncherPerfExportResult(
                false,
                jsonPath,
                summaryPath,
                bytes.Length,
                $"Serialized diagnostic bundle exceeded {MaxBundleBytes} bytes ({bytes.Length} bytes).");
        }

        var tmpJson = jsonPath + ".tmp";
        File.WriteAllBytes(tmpJson, bytes);
        File.Move(tmpJson, jsonPath, overwrite: true);

        var summary = BuildHumanSummary(bundle, jsonPath, bytes.Length);
        var tmpSummary = summaryPath + ".tmp";
        File.WriteAllText(tmpSummary, summary, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        File.Move(tmpSummary, summaryPath, overwrite: true);

        return new LauncherPerfExportResult(
            true,
            jsonPath,
            summaryPath,
            bytes.Length,
            $"Exported redacted performance bundle ({bytes.Length / 1024.0:F1} KB) to {jsonPath}");
    }

    private static string SerializeBoundedJson(ClientPerfBundle bundle)
    {
        var raw = JsonSerializer.Serialize(bundle, JsonOptions);
        if (Encoding.UTF8.GetByteCount(raw) <= MaxBundleBytes)
        {
            return raw;
        }

        bundle.RuntimeHealth.CacheStats = null;
        raw = JsonSerializer.Serialize(bundle, JsonOptions);
        if (Encoding.UTF8.GetByteCount(raw) <= MaxBundleBytes)
        {
            return raw;
        }

        return JsonSerializer.Serialize(bundle);
    }

    private static string BuildHumanSummary(ClientPerfBundle b, string jsonPath, long byteLen)
    {
        var sb = new StringBuilder();
        sb.AppendLine("SoulspireXI Automated Performance Diagnostic Summary (Stage 2A)");
        sb.AppendLine($"Captured UTC      : {b.CapturedAtUtc}");
        sb.AppendLine($"Channel / Build   : {b.SourceChannel} / {b.LauncherVersion} ({b.ServerTargetClass}: {b.ServerBuildTag})");
        sb.AppendLine($"Bundle Size       : {byteLen} bytes (limit: {MaxBundleBytes} bytes, privacy_redacted={b.PrivacyRedacted})");
        sb.AppendLine($"Diag Overhead     : total_cpu={b.Overhead.DiagCpuMsTotal:F3}ms, p99_cb={b.Overhead.DiagP99CallbackMs:F4}ms, lua_mem_delta={b.Overhead.LuaMemKbDelta:F1}KB, dropped={b.Overhead.DroppedSamples}");
        sb.AppendLine();
        sb.AppendLine("Launcher Flows:");
        foreach (var kvp in b.LauncherFlows.OrderBy(k => k.Key, StringComparer.Ordinal))
        {
            AppendFlowLine(sb, kvp.Key, "cold", kvp.Value.Cold);
            AppendFlowLine(sb, kvp.Key, "warm", kvp.Value.Warm);
        }

        sb.AppendLine();
        sb.AppendLine("Core Client Flows:");
        if (b.ClientFlows.Count == 0)
        {
            sb.AppendLine("  (none recorded yet — launch game with Performance Diagnostics enabled to collect client flows)");
        }
        else
        {
            foreach (var kvp in b.ClientFlows.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                AppendFlowLine(sb, kvp.Key, "cold", kvp.Value.Cold);
                AppendFlowLine(sb, kvp.Key, "warm", kvp.Value.Warm);
            }
        }

        if (b.RuntimeHealth.FrameMs is { } fm)
        {
            sb.AppendLine();
            sb.AppendLine($"Frame Pacing      : n={fm.N}, p50={fm.P50:F2}ms, p95={fm.P95:F2}ms, p99={fm.P99:F2}ms, max={fm.Max:F2}ms, >33ms={fm.HitchesGt33Ms}, >100ms={fm.HitchesGt100Ms}");
        }

        if (b.RuntimeHealth.PolPrivateMbMax is { } polMb)
        {
            sb.AppendLine($"POL/FFXI Peak Mem : {polMb:F1} MB");
        }

        sb.AppendLine();
        sb.AppendLine($"Upload JSON File  : {jsonPath}");
        return sb.ToString();
    }

    private static void AppendFlowLine(StringBuilder sb, string name, string mode, FlowStats? st)
    {
        if (st is null)
        {
            return;
        }

        var reliability = st.Outcomes.Complete < 3 ? " [INSUFFICIENT_SAMPLES n<3]"
            : st.Outcomes.Complete < 5 ? " [LOW_SAMPLE n<5]"
            : string.Empty;
        sb.AppendLine(
            $"  {name,-22} {mode,-4} n={st.N} (ok={st.Outcomes.Complete}, fail={st.Outcomes.Failed}, cancel={st.Outcomes.Cancelled}, inc={st.Outcomes.Incomplete}) p50={st.P50Ms:F1}ms p95={(st.P95Ms ?? st.P50Ms):F1}ms max={st.MaxMs:F1}ms scope={st.AttributionScope}{reliability}");
    }

    private void MergeCoreExport(
        string coreExportPath,
        ClientPerfBundle bundle,
        ref double cpuTotal,
        List<double> cbCopy,
        ref double luaMemKb,
        ref int dropped)
    {
        if (!File.Exists(coreExportPath))
        {
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(coreExportPath));
            var root = doc.RootElement;

            if (root.TryGetProperty("overhead", out var ov) && ov.ValueKind == JsonValueKind.Object)
            {
                if (ov.TryGetProperty("diag_cpu_ms_total", out var cpuEl) && cpuEl.TryGetDouble(out var c))
                {
                    cpuTotal += c;
                }
                if (ov.TryGetProperty("diag_p99_callback_ms", out var p99El) && p99El.TryGetDouble(out var p99))
                {
                    cbCopy.Add(p99);
                }
                if (ov.TryGetProperty("lua_mem_kb_delta", out var memEl) && memEl.TryGetDouble(out var mk))
                {
                    luaMemKb = Math.Max(luaMemKb, mk);
                }
                if (ov.TryGetProperty("dropped_samples", out var drpEl) && drpEl.TryGetInt32(out var d))
                {
                    dropped += d;
                }
            }

            if (root.TryGetProperty("client_flows", out var cf) && cf.ValueKind == JsonValueKind.Object)
            {
                foreach (var flowProp in cf.EnumerateObject())
                {
                    var grp = JsonSerializer.Deserialize<FlowModeGroup>(flowProp.Value.GetRawText(), JsonOptions);
                    if (grp is not null)
                    {
                        bundle.ClientFlows[flowProp.Name] = grp;
                    }
                }
            }

            if (root.TryGetProperty("runtime_health", out var rh) && rh.ValueKind == JsonValueKind.Object)
            {
                if (rh.TryGetProperty("frame_ms", out var fm) && fm.ValueKind == JsonValueKind.Object)
                {
                    bundle.RuntimeHealth.FrameMs = JsonSerializer.Deserialize<FrameMsStats>(fm.GetRawText(), JsonOptions);
                }
                if (rh.TryGetProperty("packet_counters", out var pc) && pc.ValueKind == JsonValueKind.Object)
                {
                    bundle.RuntimeHealth.PacketCounters = JsonSerializer.Deserialize<Dictionary<string, long>>(pc.GetRawText(), JsonOptions);
                }
                if (rh.TryGetProperty("cache_stats", out var cs) && cs.ValueKind == JsonValueKind.Object)
                {
                    bundle.RuntimeHealth.CacheStats = JsonSerializer.Deserialize<Dictionary<string, double>>(cs.GetRawText(), JsonOptions);
                }
            }
        }
        catch
        {
            // Resilient against malformed or partially-written local Lua file.
        }
    }

    private static FlowStats? SummarizeBucket(ModeBucket b)
    {
        var nTotal = b.Complete + b.Failed + b.Cancelled + b.Incomplete;
        if (nTotal == 0)
        {
            return null;
        }

        var sorted = b.Samples.Select(s => s.DurationMs).OrderBy(x => x).ToList();
        return new FlowStats
        {
            N = nTotal,
            P50Ms = Percentile(sorted, 0.50),
            P95Ms = Percentile(sorted, 0.95),
            P99Ms = Percentile(sorted, 0.99),
            MaxMs = sorted.Count > 0 ? Math.Round(sorted[^1], 4) : 0,
            Failures = b.Failed + b.Incomplete,
            Retries = b.Retries,
            Timeouts = 0,
            Cancelled = b.Cancelled,
            Incomplete = b.Incomplete,
            Files = b.HasFiles ? b.FilesTotal : null,
            Bytes = b.HasBytes ? b.BytesTotal : null,
            Outcomes = new FlowOutcomes
            {
                Complete = b.Complete,
                Failed = b.Failed,
                Cancelled = b.Cancelled,
                Incomplete = b.Incomplete
            },
            AttributionScope = b.Scope
        };
    }

    private static double Percentile(List<double> sorted, double p)
    {
        if (sorted.Count == 0)
        {
            return 0;
        }

        var idx = Math.Max(0, Math.Min(sorted.Count - 1, (int)Math.Ceiling(sorted.Count * p) - 1));
        return Math.Round(sorted[idx], 4);
    }

    private static double EstimateTotalRamGb()
    {
        try
        {
            var info = GC.GetGCMemoryInfo();
            if (info.TotalAvailableMemoryBytes > 0)
            {
                return Math.Round(info.TotalAvailableMemoryBytes / (1024.0 * 1024.0 * 1024.0), 1);
            }
        }
        catch
        {
        }

        return 0;
    }

    public void Dispose()
    {
        StopProcessMonitoring();
    }
}

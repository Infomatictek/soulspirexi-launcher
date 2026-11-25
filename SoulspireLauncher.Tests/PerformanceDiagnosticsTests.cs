using System.Diagnostics;
using System.IO;
using System.Text.Json;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class PerformanceDiagnosticsTests : IDisposable
{
    private readonly string _tempRoot = Path.Combine(
        Path.GetTempPath(),
        $"soulspire_perf_diag_tests_{Guid.NewGuid():N}");

    public PerformanceDiagnosticsTests()
    {
        Directory.CreateDirectory(_tempRoot);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tempRoot))
            {
                Directory.Delete(_tempRoot, recursive: true);
            }
        }
        catch
        {
        }
    }

    [Fact]
    public void DisabledByDefault_AndHardDisabledOnStableChannel()
    {
        var defaults = new LauncherSettings();
        Assert.False(defaults.EnablePerformanceDiagnostics);
        Assert.False(TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(defaults));

        // Even if the bool were manually toggled in JSON, Stable MUST force diagnostics OFF.
        var forcedStable = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Stable,
            EnablePerformanceDiagnostics = true
        };
        Assert.False(TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(forcedStable, "stable"));
        Assert.False(TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(forcedStable, "testing"));

        var testingOptIn = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            EnablePerformanceDiagnostics = true
        };
        Assert.True(TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(testingOptIn, "testing"));
        Assert.False(TestingEnvironmentQolPolicy.IsPerformanceDiagnosticsActive(testingOptIn, "stable"));
    }

    [Fact]
    public void ClientConfigSyncAndProtection_EnforcesChannelPolicyAndPreservesUserConfig()
    {
        var ashitaDir = Path.Combine(_tempRoot, "ashita");
        var settings = new LauncherSettings
        {
            AshitaPath = ashitaDir,
            UpdateChannel = UpdateChannel.Testing,
            ServerTarget = ServerTargetMode.Staging,
            StagingLane = StagingLane.CoreUi,
            EnablePerformanceDiagnostics = true
        };

        PerformanceDiagnosticsService.WriteCoreConfig(settings, "testing");
        var cfgPath = PerformanceDiagnosticsService.GetCoreConfigPath(ashitaDir);
        Assert.True(File.Exists(cfgPath));
        var cfg = JsonSerializer.Deserialize<CorePerfConfigFile>(File.ReadAllText(cfgPath));
        Assert.NotNull(cfg);
        Assert.True(cfg!.Enabled);
        Assert.Equal("testing", cfg.SourceChannel);
        Assert.Equal("staging-coreui", cfg.ServerTargetClass);

        // Switching back to Stable immediately writes enabled=false
        settings.UpdateChannel = UpdateChannel.Stable;
        PerformanceDiagnosticsService.WriteCoreConfig(settings, "stable");
        var stableCfg = JsonSerializer.Deserialize<CorePerfConfigFile>(File.ReadAllText(cfgPath));
        Assert.NotNull(stableCfg);
        Assert.False(stableCfg!.Enabled);

        Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("addon", "config/soulspire_perf_diag.json"));
        Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("resource", "addons/ashita4/config/soulspire_perf_diag.json"));
        Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("resource", "logs/soulspire_perf/core-perf-latest.json"));
    }

    [Fact]
    public void ExportBundle_MergesCoreLogs_ScrubsPiiAndPaths_Respects512KbAndSchema()
    {
        var ashitaDir = Path.Combine(_tempRoot, "AshitaClient");
        var diagDir = Path.Combine(_tempRoot, "LauncherDiags");
        var coreExportPath = PerformanceDiagnosticsService.GetCoreExportPath(ashitaDir);
        Directory.CreateDirectory(Path.GetDirectoryName(coreExportPath)!);

        var fakeCoreJson = """
        {
          "schema_version": "soulspire-core-perf-1.0.0",
          "enabled": true,
          "overhead": {
            "diag_cpu_ms_total": 1.42,
            "diag_p99_callback_ms": 0.019,
            "lua_mem_kb_delta": 124.5,
            "dropped_samples": 0
          },
          "client_flows": {
            "wm_sync": {
              "cold": {
                "n": 1,
                "p50_ms": 84.2,
                "p95_ms": 84.2,
                "p99_ms": 84.2,
                "max_ms": 84.2,
                "retries": 0,
                "timeouts": 0,
                "outcomes": { "complete": 1, "failed": 0, "cancelled": 0, "incomplete": 0 },
                "attribution_scope": "client_plus_server_rtt"
              },
              "op_cache_sync_count": 1,
              "legacy_fallback_count": 0
            }
          },
          "runtime_health": {
            "frame_ms": { "n": 180, "p50": 16.6, "p95": 17.1, "p99": 18.0, "max": 21.5, "hitches_gt_33ms": 0, "hitches_gt_100ms": 0 },
            "packet_counters": { "packets_in_oxtl": 4, "bytes_in_oxtl": 512, "sync_retries": 0, "timeouts": 0 }
          }
        }
        """;
        File.WriteAllText(coreExportPath, fakeCoreJson);

        using var svc = new PerformanceDiagnosticsService(diagDir);
        var sw = Stopwatch.StartNew();
        sw.Stop();
        svc.RecordDurationMs(true, "startup", 312.5, isColdOverride: true, outcome: "complete", scope: "client_only");
        svc.RecordDurationMs(true, "check", 125.0, isColdOverride: true, outcome: "complete", scope: "client_plus_server_rtt");
        svc.RecordDurationMs(true, "check", 48.0, isColdOverride: false, outcome: "complete", scope: "client_plus_server_rtt");
        svc.RecordDurationMs(true, "sync", 220.0, isColdOverride: true, outcome: "complete", scope: "client_only", files: 3, bytes: 8192);
        svc.RecordPolMemoryMb(512.75);

        var settings = new LauncherSettings
        {
            AshitaPath = ashitaDir,
            UpdateChannel = UpdateChannel.Testing,
            ServerTarget = ServerTargetMode.Production,
            Username = "RinSecretTestUser",
            EnablePerformanceDiagnostics = true
        };
        var manifest = new LauncherManifest
        {
            Channel = "testing",
            ManifestVersion = "2.2.2-testing.1",
            ServerCompatibility = new ManifestServerCompatibility
            {
                DockerImage = "soulspirexi/server:main-ws3-weap-002-bc56df3"
            }
        };

        var result = svc.ExportBundle(settings, manifest, "v2.2.2-testing.1", new DateTimeOffset(2026, 11, 25, 4, 0, 0, TimeSpan.Zero));
        Assert.True(result.Success, result.Message);
        Assert.True(result.ByteSize <= PerformanceDiagnosticsService.MaxBundleBytes);
        Assert.True(File.Exists(result.JsonPath));
        Assert.True(File.Exists(result.SummaryPath));

        var rawJson = File.ReadAllText(result.JsonPath);
        Assert.DoesNotContain("RinSecretTestUser", rawJson, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(@"C:\", rawJson, StringComparison.OrdinalIgnoreCase);

        using var parsed = JsonDocument.Parse(rawJson);
        Assert.Equal("client-perf-1.0.0", parsed.RootElement.GetProperty("schema_version").GetString());
        Assert.True(parsed.RootElement.GetProperty("privacy_redacted").GetBoolean());
        Assert.Equal("testing", parsed.RootElement.GetProperty("source_channel").GetString());
        Assert.Equal("v2.2.2-testing.1", parsed.RootElement.GetProperty("launcher_version").GetString());
        Assert.Equal(512.75, parsed.RootElement.GetProperty("runtime_health").GetProperty("pol_private_mb_max").GetDouble(), 2);
        Assert.True(parsed.RootElement.GetProperty("client_flows").TryGetProperty("wm_sync", out _));
        Assert.True(parsed.RootElement.GetProperty("launcher_flows").TryGetProperty("startup", out _));
        Assert.True(parsed.RootElement.GetProperty("launcher_flows").TryGetProperty("sync", out _));

        // Disabled mode records zero spans
        svc.RecordDurationMs(false, "startup", 999.0);
        var bundle2 = svc.BuildBundle(settings, manifest, "v2.2.2-testing.1");
        Assert.Equal(1, bundle2.LauncherFlows["startup"].Cold!.N);

        var scrubbed = PerformanceDiagnosticsService.ScrubText(
            @"C:\Users\SecretName\Desktop\foo from 192.168.86.117 user@example.com /home/rin/x",
            "SecretName");
        Assert.DoesNotContain("SecretName", scrubbed);
        Assert.DoesNotContain("192.168.86.117", scrubbed);
        Assert.DoesNotContain("user@example.com", scrubbed);
        Assert.DoesNotContain("/home/rin", scrubbed);
    }
}

using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class ModernClientIntegrationTests
{
    private sealed class StubHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(responder(request));
    }

    private static LauncherManifest BuildTestingModernManifest(
        bool baselineEligible = true,
        bool compatEligible = true,
        bool verified = false,
        string? baselineSha = null)
    {
        var sha = baselineSha ?? new string('a', 64);
        return new LauncherManifest
        {
            Channel = "testing",
            ManifestVersion = "2.2.3-testing.1",
            Files =
            [
                new ManifestFileEntry
                {
                    Category = "addon",
                    SourcePath = "addons/ashita4/soulspire_core/soulspire_core.lua",
                    TargetPath = "soulspire_core/soulspire_core.lua",
                    Sha256 = new string('b', 64),
                    Size = 100
                }
            ],
            ModernClient = new ManifestModernClient
            {
                Engine = "vanacore",
                Version = "0.9.9-soulspire",
                UpstreamCommit = "04545ec52120c2df527ac3c0c4ab32392cfc10c5",
                ExperimentalEligible = baselineEligible || compatEligible,
                ClientVerified = verified,
                Baseline = new ManifestModernClientPackage
                {
                    Profile = "baseline",
                    Version = "0.9.9",
                    Tag = "v0.9.9-soulspire-baseline.1",
                    CommitSha = "56ef560c02",
                    PackageUrl = "https://github.com/Infomatictek/soulspirexi-client/releases/download/v0.9.9-soulspire-baseline.1/soulspirexi-client-experimental-0.9.9-56ef560c02-win32.zip",
                    PackageSha256 = sha,
                    PackageSize = 1024,
                    ExperimentalEligible = baselineEligible,
                    ClientVerified = verified
                },
                Compat = new ManifestModernClientPackage
                {
                    Profile = "compat",
                    Version = "0.9.9",
                    Tag = "v0.9.9-soulspire-compat.1",
                    CommitSha = "a506b8bd6f",
                    PackageUrl = "https://github.com/Infomatictek/soulspirexi-client/releases/download/v0.9.9-soulspire-compat.1/soulspirexi-client-experimental-0.9.9-a506b8bd6f-win32.zip",
                    PackageSha256 = new string('c', 64),
                    PackageSize = 1024,
                    ExperimentalEligible = compatEligible,
                    ClientVerified = verified
                }
            }
        };
    }

    [Fact]
    public void ModernEngines_RemainOptInAndEnforceExplicitEligibilityAndStableLockout()
    {
        var manifest = BuildTestingModernManifest(baselineEligible: true, compatEligible: true, verified: false);

        // Stable MUST always fall back to Classic while clientVerified == false.
        var stableBaseline = new LauncherSettings { UpdateChannel = UpdateChannel.Stable, ClientEngine = ClientEngineMode.ModernBaseline };
        var stableCompat = new LauncherSettings { UpdateChannel = UpdateChannel.Stable, ClientEngine = ClientEngineMode.ModernCompat };
        Assert.Equal(ClientEngineMode.Classic, ModernClientConfigGenerator.ResolveEffectiveEngine(stableBaseline, manifest));
        Assert.Equal(ClientEngineMode.Classic, ModernClientConfigGenerator.ResolveEffectiveEngine(stableCompat, manifest));
        Assert.Equal(ClientEngineMode.Classic, ModernClientConfigGenerator.ResolveEffectiveEngine(stableBaseline, null));

        // Testing allows both Baseline and Compat when explicitly marked experimentalEligible=true.
        var testingBaseline = new LauncherSettings { UpdateChannel = UpdateChannel.Testing, ClientEngine = ClientEngineMode.ModernBaseline };
        var testingCompat = new LauncherSettings { UpdateChannel = UpdateChannel.Testing, ClientEngine = ClientEngineMode.ModernCompat };
        Assert.Equal(ClientEngineMode.ModernBaseline, ModernClientConfigGenerator.ResolveEffectiveEngine(testingBaseline, manifest));
        Assert.Equal(ClientEngineMode.ModernCompat, ModernClientConfigGenerator.ResolveEffectiveEngine(testingCompat, manifest));

        // If Testing manifest marks compat experimentalEligible=false (and clientVerified=false), fail closed to Classic.
        var baselineOnlyManifest = BuildTestingModernManifest(baselineEligible: true, compatEligible: false, verified: false);
        Assert.Equal(ClientEngineMode.ModernBaseline, ModernClientConfigGenerator.ResolveEffectiveEngine(testingBaseline, baselineOnlyManifest));
        Assert.Equal(ClientEngineMode.Classic, ModernClientConfigGenerator.ResolveEffectiveEngine(testingCompat, baselineOnlyManifest));

        // Once runtime-certified, Stable accepts the certified profile.
        var verifiedManifest = BuildTestingModernManifest(baselineEligible: true, compatEligible: true, verified: true);
        verifiedManifest.Channel = "stable";
        Assert.Equal(ClientEngineMode.ModernBaseline, ModernClientConfigGenerator.ResolveEffectiveEngine(stableBaseline, verifiedManifest));
        Assert.Equal(ClientEngineMode.ModernCompat, ModernClientConfigGenerator.ResolveEffectiveEngine(stableCompat, verifiedManifest));
    }

    [Fact]
    public void StableManifest_FailsClosedWhenModernClientIsUnverified_AndTestingValidatesShaAndHttps()
    {
        var manifest = BuildTestingModernManifest(baselineEligible: true, compatEligible: true, verified: false);
        manifest.Channel = "stable";

        var okStable = ManifestUpdateService.ValidateManifestForChannel(manifest, UpdateChannel.Stable, out var stableErr);
        Assert.False(okStable);
        Assert.Contains("modernClient.clientVerified=false", stableErr);

        // Testing accepts experimentalEligible packages with valid HTTPS URL + 64-hex SHA-256 + positive size.
        manifest.Channel = "testing";
        Assert.True(ManifestUpdateService.ValidateManifestForChannel(manifest, UpdateChannel.Testing, out var testErr), testErr);

        // Testing MUST reject tampered/malformed SHA-256 or non-HTTPS download URL.
        manifest.ModernClient!.Baseline!.PackageSha256 = "not-a-valid-sha";
        Assert.False(ManifestUpdateService.ValidateManifestForChannel(manifest, UpdateChannel.Testing, out var badShaErr));
        Assert.Contains("SHA-256", badShaErr);

        manifest.ModernClient.Baseline.PackageSha256 = new string('a', 64);
        manifest.ModernClient.Baseline.PackageUrl = "http://insecure.example.com/client.zip";
        Assert.False(ManifestUpdateService.ValidateManifestForChannel(manifest, UpdateChannel.Testing, out var badUrlErr));
        Assert.Contains("HTTPS", badUrlErr);
    }

    [Fact]
    public void ModernBaseline_DisablesAllSoulspireHooksAddonsMenusAndWritesZeroPasswords()
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            ClientEngine = ClientEngineMode.ModernBaseline,
            Username = "TestPlayer",
            EnablePivotOverlay = true,
            EnableFlintlockDualPistolsOverlay = true,
            AutoLoadCrystalSocketAddon = true,
            AutoLoadSoulHudAddon = true,
            AutoLoadFlintlockAddon = true,
            AutoLoadGearAddon = true
        };

        var ini = ModernClientConfigGenerator.BuildIniContent(
            settings,
            ClientEngineMode.ModernBaseline,
            "play.soulspirexi.com",
            @"C:\Game\PlayOnlineViewer",
            @"C:\Game\FINAL FANTASY XI");

        Assert.Contains("server=play.soulspirexi.com", ini);
        Assert.Contains("singlemenu=0", ini);
        Assert.Contains("configmenu=0", ini);
        Assert.Contains("gamesettings.extended=0", ini);
        Assert.Contains("renderer=d3d12", ini);
        Assert.Contains("enabled=0", ini); // pivot & soulspire disabled in Baseline
        Assert.Contains("[soulspire]\r\nenabled=0", ini.Replace("\r\n", "\n").Replace("\n", "\r\n"));
        Assert.DoesNotContain("[pivot.order]", ini);
        Assert.DoesNotContain("password=", ini, StringComparison.OrdinalIgnoreCase);

        var boot = ModernClientConfigGenerator.BuildBootScriptContent(settings, ClientEngineMode.ModernBaseline);
        Assert.DoesNotContain("/plugin load", boot);
        Assert.DoesNotContain("/addon load", boot);

        var iniName = ModernClientConfigGenerator.GetAccountIniFileName("TestPlayer");
        Assert.StartsWith("vanacore.", iniName);
        Assert.EndsWith(".ini", iniName);
        Assert.DoesNotContain("testplayer", iniName, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ModernCompat_EnablesDualHostNativeAndPivotOrderAndD3D11Fallback()
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            ClientEngine = ClientEngineMode.ModernCompat,
            ModernClientUseD3D11Fallback = true,
            EnablePivotOverlay = true,
            EnableFlintlockDualPistolsOverlay = true,
            AutoLoadCrystalSocketAddon = true,
            AutoLoadSoulHudAddon = true,
            AutoLoadFlintlockAddon = true,
            AutoLoadGearAddon = true
        };

        var ini = ModernClientConfigGenerator.BuildIniContent(settings, ClientEngineMode.ModernCompat, "play.soulspirexi.com", null, null);
        Assert.Contains("[pivot.order]", ini);
        Assert.Contains("0=soulspirexi", ini);
        Assert.Contains("1=flintlock-akimbo-compact", ini);
        Assert.Contains("singlemenu=0", ini);
        Assert.Contains("ashita.interface=4.30", ini);
        Assert.Contains("renderer=d3d11", ini);
        Assert.Contains("[soulspire]\r\nenabled=1", ini.Replace("\r\n", "\n").Replace("\n", "\r\n"));

        var boot = ModernClientConfigGenerator.BuildBootScriptContent(settings, ClientEngineMode.ModernCompat);
        Assert.DoesNotContain("/plugin load soulspire_native", boot);
        Assert.Contains("/addon load crystalsocket ashita", boot);
        Assert.Contains("/addon load soulspire_soulhud ashita", boot);
        Assert.Contains("/addon load soulspire_core ashita", boot);
        Assert.Contains("/addon load soulspire_flintlock ashita", boot);
        Assert.Contains("/addon load soulspire_gear ashita", boot);
        Assert.Contains("/addon load soulspire_soul_actions ashita", boot);
    }

    [Fact]
    public void BuildModernClientStartInfo_UsesPasswordStdinAndNeverExposesPasswordInArgs()
    {
        var startInfo = GameLaunchService.BuildModernClientStartInfo(
            @"C:\SoulspireXI\ModernClient\baseline",
            @"C:\SoulspireXI\ModernClient\baseline\VanaCore.exe",
            "play.soulspirexi.com",
            "HeroName",
            "vanacore.abcdef123456.ini",
            "US",
            usePasswordStdin: true);

        Assert.True(startInfo.RedirectStandardInput);
        Assert.False(startInfo.UseShellExecute);
        Assert.Contains("--password-stdin", startInfo.Arguments);
        Assert.Contains("--server play.soulspirexi.com", startInfo.Arguments);
        Assert.Contains("--user HeroName", startInfo.Arguments);
        Assert.DoesNotContain("--pass ", startInfo.Arguments);
        Assert.DoesNotContain("--password ", startInfo.Arguments);
    }

    [Fact]
    public async Task ModernClientInstallService_DownloadsVerifiesSha256InstallsIsolatedAndRejectsTamperedZip()
    {
        var root = Path.Combine(Path.GetTempPath(), "sxi-modern-install-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            var ashitaDir = Path.Combine(root, "Ashita");
            Directory.CreateDirectory(Path.Combine(ashitaDir, "plugins", "data"));
            Directory.CreateDirectory(Path.Combine(ashitaDir, "addons", "soulspire_core"));
            Directory.CreateDirectory(Path.Combine(ashitaDir, "addons", "soulspire_talents"));
            Directory.CreateDirectory(Path.Combine(ashitaDir, "addons", "soulspire_soulhud"));
            Directory.CreateDirectory(Path.Combine(ashitaDir, "addons", "kazenoeye"));
            File.WriteAllText(Path.Combine(ashitaDir, "plugins", "soulspire_native.dll"), "native-stub");
            File.WriteAllText(Path.Combine(ashitaDir, "plugins", "data", "soul-weapon-config.json"), "{\"schemaVersion\":1}");
            File.WriteAllText(Path.Combine(ashitaDir, "plugins", "data", "soul-identities.json"), "{}");
            File.WriteAllText(Path.Combine(ashitaDir, "addons", "soulspire_core", "soulspire_core.lua"), "-- core");
            File.WriteAllText(Path.Combine(ashitaDir, "addons", "soulspire_talents", "soulforge_state.lua"), "-- soulforge");
            File.WriteAllText(Path.Combine(ashitaDir, "addons", "soulspire_soulhud", "soulspire_soulhud.lua"), "-- soulhud");
            File.WriteAllText(Path.Combine(ashitaDir, "addons", "kazenoeye", "kazenoeye.lua"), "-- kazenoeye");

            // Build a valid test ZIP mimicking GitHub Release layout (VanaCore/VanaCore.exe + VanaCore/VanaCore.Core.dll).
            var zipBytes = BuildStubModernZipBytes("v1-exe", "v1-core");
            var goodSha = Convert.ToHexString(SHA256.HashData(zipBytes)).ToLowerInvariant();

            using var handler = new StubHttpHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(zipBytes)
            });
            using var http = new HttpClient(handler);
            var installer = new ModernClientInstallService(http);

            var baselineDir = ModernClientConfigGenerator.ResolveProfileDirectory(Path.Combine(root, "ModernClient"), ClientEngineMode.ModernBaseline);
            var badPkg = new ManifestModernClientPackage
            {
                Profile = "baseline",
                Version = "0.9.9",
                Tag = "v0.9.9-soulspire-baseline.1",
                CommitSha = "56ef560c02",
                PackageUrl = "https://example.test/client.zip",
                PackageSha256 = new string('f', 64),
                PackageSize = zipBytes.Length,
                ExperimentalEligible = true
            };

            // Tampered / mismatched SHA-256 MUST fail closed before extraction.
            var shaEx = await Assert.ThrowsAsync<InvalidOperationException>(() => installer.EnsureInstalledAsync(baselineDir, badPkg));
            Assert.Contains("SHA-256 verification FAILED", shaEx.Message);
            Assert.False(File.Exists(Path.Combine(baselineDir, "VanaCore.exe")));

            // Valid SHA-256 downloads, extracts cleanly (flattening VanaCore/ prefix), and records state.
            badPkg.PackageSha256 = goodSha;
            var res = await installer.EnsureInstalledAsync(baselineDir, badPkg);
            Assert.True(res.Downloaded);
            Assert.True(File.Exists(Path.Combine(baselineDir, "VanaCore.exe")));
            Assert.True(File.Exists(Path.Combine(baselineDir, "VanaCore.Core.dll")));
            Assert.True(ModernClientInstallService.IsUpToDate(baselineDir, badPkg));

            // Second call is a fast no-op (UpToDate == true).
            var res2 = await installer.EnsureInstalledAsync(baselineDir, badPkg);
            Assert.False(res2.Downloaded);
            Assert.True(res2.UpToDate);

            // SyncCompatibilityOverlayFromAshita copies into ModernClient\compat\plugins\ashita\ + data\ without mutating Ashita\.
            var compatDir = ModernClientConfigGenerator.ResolveProfileDirectory(Path.Combine(root, "ModernClient"), ClientEngineMode.ModernCompat);
            // Seed a stale root plugins\soulspire_native.dll to verify cleanup.
            Directory.CreateDirectory(Path.Combine(compatDir, "plugins"));
            File.WriteAllText(Path.Combine(compatDir, "plugins", "soulspire_native.dll"), "stale-root");

            var copied = ModernClientInstallService.SyncCompatibilityOverlayFromAshita(ashitaDir, compatDir);
            Assert.True(copied >= 6);
            Assert.True(File.Exists(Path.Combine(compatDir, "plugins", "ashita", "soulspire_native.dll")));
            Assert.False(File.Exists(Path.Combine(compatDir, "plugins", "soulspire_native.dll")));
            Assert.True(File.Exists(Path.Combine(compatDir, "plugins", "ashita", "data", "soul-weapon-config.json")));
            Assert.True(File.Exists(Path.Combine(compatDir, "plugins", "data", "soul-weapon-config.json")));
            Assert.True(File.Exists(Path.Combine(compatDir, "plugins", "ashita", "data", "soul-identities.json")));
            Assert.True(File.Exists(Path.Combine(compatDir, "addons", "ashita", "soulspire_core", "soulspire_core.lua")));
            Assert.True(File.Exists(Path.Combine(compatDir, "addons", "ashita", "soulspire_talents", "soulforge_state.lua")));
            Assert.True(File.Exists(Path.Combine(compatDir, "addons", "ashita", "soulspire_soulhud", "soulspire_soulhud.lua")));
            Assert.True(File.Exists(Path.Combine(compatDir, "addons", "ashita", "kazenoeye", "kazenoeye.lua")));
            Assert.Equal("native-stub", File.ReadAllText(Path.Combine(ashitaDir, "plugins", "soulspire_native.dll")));

            // Verify Compat boot script restores full polished Core UI, Soul HUD, Soulforge & Soul Actions
            // while omitting legacy external soulspire_native.dll and standalone soulspire_talents.
            var bootSettings = new LauncherSettings
            {
                AutoLoadCrystalSocketAddon = true,
                AutoLoadKazenoeyeAddon = true,
                AutoLoadSoulHudAddon = true,
                AutoLoadTalentsAddon = true,
                AutoLoadGearAddon = true
            };
            var boot = ModernClientConfigGenerator.BuildBootScriptContent(bootSettings, ClientEngineMode.ModernCompat);
            Assert.Contains("/addon load kazenoeye ashita", boot);
            Assert.Contains("/addon load soulspire_soulhud ashita", boot);
            Assert.Contains("/addon load soulspire_core ashita", boot);
            Assert.Contains("/addon load soulspire_soul_actions ashita", boot);
            Assert.DoesNotContain("/addon load soulspire_talents", boot);
            Assert.True(boot.IndexOf("/addon load kazenoeye ashita", StringComparison.Ordinal) <
                        boot.IndexOf("/addon load soulspire_core ashita", StringComparison.Ordinal));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public void ModernClientDiagnosticsService_ExportsSummaryAndRedactsAllSecrets()
    {
        var root = Path.Combine(Path.GetTempPath(), "sxi-modern-diag-" + Guid.NewGuid().ToString("N"));
        try
        {
            var profileDir = Path.Combine(root, "ModernClient", "baseline");
            var exportDir = Path.Combine(root, "Exports");
            Directory.CreateDirectory(Path.Combine(profileDir, "logs"));
            Directory.CreateDirectory(Path.Combine(profileDir, "scripts"));

            const string secretPass = "SuperSecretAccountPass987!";
            File.WriteAllText(
                Path.Combine(profileDir, "logs", "vanacore.log"),
                "FFXiMain.dll TimeDateStamp=0x6AE818B4 SizeOfImage=0x00C17000\n" +
                "[sigs] pattern chat_hook found at 0x10012345\n" +
                "[sigs] pattern missing_sig not found (fail)\n" +
                "Renderer initialized: D3D12 NVIDIA RTX\n" +
                $"debug leak test: password={secretPass} --pass {secretPass} Bearer tok_abc123\n");
            File.WriteAllText(Path.Combine(profileDir, "build-provenance.json"), "{\"commit_sha\":\"56ef560c02\"}");
            File.WriteAllText(Path.Combine(profileDir, "scripts", "boot.txt"), "# baseline\n");
            File.WriteAllText(Path.Combine(profileDir, "crash_2026.dmp"), "dummy-dmp");

            var settings = LauncherSettings.CreateDefault(root);
            settings.Username = "Rin";
            var gen = new ModernClientConfigGenerator();
            gen.WriteAllConfigs(profileDir, settings, ClientEngineMode.ModernBaseline, "play.soulspirexi.com", null, null);

            var diagService = new ModernClientDiagnosticsService(exportDir);
            var exported = diagService.ExportBundle(profileDir, ClientEngineMode.ModernBaseline, settings, "v2.2.3-testing.1", secretPass);

            Assert.True(exported.Success);
            Assert.True(File.Exists(exported.ZipPath));
            Assert.Contains("diagnostics-summary.json", exported.IncludedFiles);
            Assert.Contains("logs/vanacore.log", exported.IncludedFiles);
            Assert.Contains("build-provenance.json", exported.IncludedFiles);
            Assert.Contains("config/vanacore.redacted.ini", exported.IncludedFiles);

            // Inspect EVERY file in the exported ZIP and prove ZERO secrets leaked!
            using var zip = ZipFile.OpenRead(exported.ZipPath);
            foreach (var entry in zip.Entries)
            {
                using var sr = new StreamReader(entry.Open(), Encoding.UTF8);
                var body = sr.ReadToEnd();
                Assert.DoesNotContain(secretPass, body);
                Assert.DoesNotContain("tok_abc123", body);
            }

            var summaryEntry = zip.GetEntry("diagnostics-summary.json");
            Assert.NotNull(summaryEntry);
            using var summaryReader = new StreamReader(summaryEntry!.Open(), Encoding.UTF8);
            var summaryJson = summaryReader.ReadToEnd();
            Assert.Contains("0x6AE818B4", summaryJson);
            Assert.Contains("\"MatchedCount\": 1", summaryJson);
            Assert.Contains("\"FailedCount\": 1", summaryJson);
            Assert.Contains("crash_2026.dmp", summaryJson);
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public void ModernNative_Profile_DisablesAshitaCompat_And_LoadsSingleUnifiedAddon()
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            ClientEngine = ClientEngineMode.ModernNative,
            Username = "offset",
            EnablePivotOverlay = true
        };

        var folder = ModernClientConfigGenerator.GetProfileFolderName(ClientEngineMode.ModernNative);
        Assert.Equal("native", folder);
        Assert.True(ModernClientConfigGenerator.IsModernEngine(ClientEngineMode.ModernNative));

        var ini = ModernClientConfigGenerator.BuildIniContent(settings, ClientEngineMode.ModernNative, "play.soulspirexi.com", null, null);
        Assert.Contains("[soulspire]", ini);
        Assert.Contains("enabled=1", ini);
        Assert.Contains("ashita.enabled=0", ini);
        Assert.Contains("singlemenu=0", ini);

        var boot = ModernClientConfigGenerator.BuildBootScriptContent(settings, ClientEngineMode.ModernNative);
        var activeLines = boot.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim())
            .Where(l => !string.IsNullOrEmpty(l) && !l.StartsWith("#", StringComparison.Ordinal))
            .ToList();
        Assert.Contains("/addon load soulspire_core vanacore", activeLines);
        Assert.Single(activeLines, l => l.StartsWith("/addon load", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(activeLines, l => l.Contains("ashita", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(activeLines, l => l.Contains("soulspire_native", StringComparison.OrdinalIgnoreCase));

        // Verify SyncNativeOverlayFromAshita copies ONLY VanaCore-native addon + data + artwork (zero Ashita addons or DLLs)
        var root = Path.Combine(Path.GetTempPath(), $"sxi-native-overlay-{Guid.NewGuid():N}");
        var ashitaDir = Path.Combine(root, "Ashita");
        var nativeDir = Path.Combine(root, "ModernClient", "native");
        try
        {
            Directory.CreateDirectory(Path.Combine(ashitaDir, "plugins", "data"));
            File.WriteAllText(Path.Combine(ashitaDir, "plugins", "soulspire_native.dll"), "legacy-dll");
            File.WriteAllText(Path.Combine(ashitaDir, "plugins", "data", "soul-identities.json"), "{\"souls\":[]}");
            Directory.CreateDirectory(Path.Combine(ashitaDir, "addons", "vanacore", "soulspire_core"));
            File.WriteAllText(Path.Combine(ashitaDir, "addons", "vanacore", "soulspire_core", "soulspire_core.lua"), "-- native");
            Directory.CreateDirectory(Path.Combine(ashitaDir, "addons", "soulspire_core"));
            File.WriteAllText(Path.Combine(ashitaDir, "addons", "soulspire_core", "soulspire_core.lua"), "-- ashita");

            var copied = ModernClientInstallService.SyncNativeOverlayFromAshita(ashitaDir, nativeDir);
            Assert.True(copied >= 2);
            Assert.True(File.Exists(Path.Combine(nativeDir, "addons", "vanacore", "soulspire_core", "soulspire_core.lua")));
            Assert.True(File.Exists(Path.Combine(nativeDir, "data", "soul-identities.json")));
            Assert.False(File.Exists(Path.Combine(nativeDir, "plugins", "ashita", "soulspire_native.dll")));
            Assert.False(Directory.Exists(Path.Combine(nativeDir, "addons", "ashita")));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }

    [Fact]
    public void ModernClientConfigGenerator_InheritsAndPreservesCustomFfxiGamepadBindingsAcrossRelaunches()
    {
        var settings = new LauncherSettings
        {
            Username = "Rin",
            ClientEngine = ClientEngineMode.ModernNative,
            WindowWidth = 1920,
            WindowHeight = 1080
        };

        // 1. Nonstandard XInput config (swapped Confirm=0(B) / Cancel=3(A), custom axes & gameplay buttons)
        var customXInput = new FfxiGamepadConfig(
            PadMode: "1,1,1,1,1,1",
            PadSin: "8,9,13,12,10,3,2,0,1,15,-1,-1,14,-33,-33,32,32,-36,-36,35,35,6,7,5,4,11,-1,-1,-1,-1,-1,-1",
            PadExSin: "1,2,3,4",
            PadGuid: "{11111111-2222-3333-4444-555555555555}",
            Source: "FFXI Registry (US, HKLM WOW6432Node)");

        var xinputIni = ModernClientConfigGenerator.BuildIniContent(
            settings, ClientEngineMode.ModernNative, "play.soulspirexi.com", null, null, customXInput);
        Assert.Contains("gamepad.mode=1,1,1,1,1,1", xinputIni);
        Assert.Contains("gamepad.buttons=8,9,13,12,10,3,2,0,1,15,-1,-1,14,-33,-33,32,32,-36,-36,35,35,6,7,5,4,11,-1,-1,-1,-1,-1,-1", xinputIni);
        Assert.Contains("gamepad.buttons_ex=1,2,3,4", xinputIni);
        Assert.Contains("gamepad.guid={11111111-2222-3333-4444-555555555555}", xinputIni);

        // 2. DirectInput profile (6th field of padmode000 == 0) preserved verbatim
        var customDInput = new FfxiGamepadConfig(
            PadMode: "1,1,1,1,0,0",
            PadSin: "4,5,11,10,9,1,3,2,0,8,-1,-1,12,-33,-33,32,32,-36,-36,35,35,6,7,5,4,11,-1,-1,-1,-1,-1,-1",
            PadExSin: null,
            PadGuid: "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}",
            Source: "FFXI Registry (US, VirtualStore)");
        var dinputIni = ModernClientConfigGenerator.BuildIniContent(
            settings, ClientEngineMode.ModernNative, "play.soulspirexi.com", null, null, customDInput);
        Assert.Contains("gamepad.mode=1,1,1,1,0,0", dinputIni);
        Assert.Contains("gamepad.buttons=4,5,11,10,9,1,3,2,0,8,", dinputIni);
        Assert.DoesNotContain("gamepad.buttons_ex=", dinputIni);
        Assert.Contains("gamepad.guid={AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}", dinputIni);

        // 3. Missing / "-1" gamepad config does NOT write fake defaults
        var missingCfg = new FfxiGamepadConfig("-1", null, "", "-1", "Not found");
        var missingIni = ModernClientConfigGenerator.BuildIniContent(
            settings, ClientEngineMode.ModernNative, "play.soulspirexi.com", null, null, missingCfg);
        Assert.DoesNotContain("gamepad.mode=", missingIni);
        Assert.DoesNotContain("gamepad.buttons=", missingIni);
        Assert.DoesNotContain("gamepad.guid=", missingIni);

        // 4. WriteAllConfigs preserves existing customized vanacore.ini gamepad settings across subsequent relaunches
        var profileDir = Path.Combine(Path.GetTempPath(), $"sxi-gamepad-persist-{Guid.NewGuid():N}");
        try
        {
            var gen = new ModernClientConfigGenerator();
            var iniName = gen.WriteAllConfigs(profileDir, settings, ClientEngineMode.ModernNative, "play.soulspirexi.com", null, null, customXInput);
            Assert.True(gen.LastGamepadImportSucceeded);

            // Simulate user relaunching after a launcher update (no explicitGamepadConfig passed)
            var iniName2 = gen.WriteAllConfigs(profileDir, settings, ClientEngineMode.ModernNative, "play.soulspirexi.com", null, null);
            Assert.Equal(iniName, iniName2);
            Assert.True(gen.LastGamepadImportSucceeded);
            Assert.Contains("Preserved from existing vanacore.ini", gen.LastGamepadImportDiagnostic);

            var persisted = File.ReadAllText(Path.Combine(profileDir, iniName2), Encoding.UTF8);
            Assert.Contains("gamepad.mode=1,1,1,1,1,1", persisted);
            Assert.Contains("gamepad.buttons=8,9,13,12,10,3,2,0,1,15,", persisted);
            Assert.Contains("gamepad.guid={11111111-2222-3333-4444-555555555555}", persisted);
        }
        finally
        {
            if (Directory.Exists(profileDir))
            {
                Directory.Delete(profileDir, recursive: true);
            }
        }
    }

    private static byte[] BuildStubModernZipBytes(string exeBody, string coreBody)
    {
        using var ms = new MemoryStream();
        using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            WriteEntry(zip, "VanaCore/VanaCore.exe", exeBody);
            WriteEntry(zip, "VanaCore/VanaCore.Core.dll", coreBody);
            WriteEntry(zip, "VanaCore/build-provenance.json", "{\"runtime_certified\":false}");
        }
        return ms.ToArray();
    }

    private static void WriteEntry(ZipArchive zip, string path, string text)
    {
        var e = zip.CreateEntry(path);
        using var w = new StreamWriter(e.Open(), new UTF8Encoding(false));
        w.Write(text);
    }
}

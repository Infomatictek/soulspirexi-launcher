using System.IO;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class ModernClientIntegrationTests
{
    [Fact]
    public void ModernEngine_RemainsOptInAndGatedBehindTestingUntilVerified()
    {
        var stableSettings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Stable,
            ClientEngine = ClientEngineMode.Modern
        };

        var unverifiedManifest = new LauncherManifest
        {
            Channel = "stable",
            ModernClient = new ManifestModernClient
            {
                Version = "0.9.9",
                ClientVerified = false
            }
        };

        // Stable must fall back to Classic until modernClient.clientVerified == true.
        Assert.Equal(ClientEngineMode.Classic, ModernClientConfigGenerator.ResolveEffectiveEngine(stableSettings, unverifiedManifest));
        Assert.Equal(ClientEngineMode.Classic, ModernClientConfigGenerator.ResolveEffectiveEngine(stableSettings, null));

        // Testing channel allows opt-in Modern.
        var testingSettings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            ClientEngine = ClientEngineMode.Modern
        };
        Assert.Equal(ClientEngineMode.Modern, ModernClientConfigGenerator.ResolveEffectiveEngine(testingSettings, unverifiedManifest));

        // Certified Stable manifest allows opt-in Modern.
        var verifiedManifest = new LauncherManifest
        {
            Channel = "stable",
            ModernClient = new ManifestModernClient
            {
                Version = "1.0.0",
                ClientVerified = true
            }
        };
        Assert.Equal(ClientEngineMode.Modern, ModernClientConfigGenerator.ResolveEffectiveEngine(stableSettings, verifiedManifest));
    }

    [Fact]
    public void StableManifest_FailsClosedWhenModernClientIsUnverified()
    {
        var manifest = new LauncherManifest
        {
            Channel = "stable",
            ManifestVersion = "2.2.0",
            Files =
            [
                new ManifestFileEntry
                {
                    Category = "addon",
                    SourcePath = "addons/ashita4/soulspire_core/soulspire_core.lua",
                    TargetPath = "soulspire_core/soulspire_core.lua",
                    Sha256 = new string('a', 64),
                    Size = 100
                }
            ],
            ModernClient = new ManifestModernClient
            {
                Version = "0.9.9-testing",
                ClientVerified = false
            }
        };

        var ok = ManifestUpdateService.ValidateManifestForChannel(manifest, UpdateChannel.Stable, out var err);
        Assert.False(ok);
        Assert.Contains("modernClient.clientVerified=false", err);

        // Testing channel accepts unverified Modern client descriptors for playtesting.
        manifest.Channel = "testing";
        var okTesting = ManifestUpdateService.ValidateManifestForChannel(manifest, UpdateChannel.Testing, out var testingErr);
        Assert.True(okTesting, testingErr);
    }

    [Fact]
    public void ModernClientConfigGenerator_SafeLoginMode_DisablesCustomHooksAndNeverWritesPasswords()
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            ClientEngine = ClientEngineMode.Modern,
            ModernClientSafeLoginMode = true,
            Username = "TestPlayer",
            EnablePivotOverlay = true,
            EnableFlintlockDualPistolsOverlay = true
        };

        var ini = ModernClientConfigGenerator.BuildIniContent(
            settings,
            "play.soulspirexi.com",
            @"C:\Game\PlayOnlineViewer",
            @"C:\Game\FINAL FANTASY XI");

        Assert.Contains("server=play.soulspirexi.com", ini);
        Assert.Contains("singlemenu=0", ini);
        Assert.Contains("ashita.interface=4.30", ini);
        Assert.Contains("enabled=0", ini); // pivot disabled in Phase 1 safe mode
        Assert.Contains("shadows=0", ini);
        Assert.Contains("upscale=off", ini);
        Assert.DoesNotContain("password=", ini, StringComparison.OrdinalIgnoreCase);

        var boot = ModernClientConfigGenerator.BuildBootScriptContent(settings);
        Assert.DoesNotContain("/plugin load soulspire_native", boot);
        Assert.DoesNotContain("/addon load soulspire_core", boot);

        // Account INI filename must hash the username (never plaintext username).
        var iniName = ModernClientConfigGenerator.GetAccountIniFileName("TestPlayer");
        Assert.StartsWith("vanacore.", iniName);
        Assert.EndsWith(".ini", iniName);
        Assert.DoesNotContain("testplayer", iniName, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ModernClientConfigGenerator_ProgressiveMode_EnablesNativeAndPivotOrder()
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            ClientEngine = ClientEngineMode.Modern,
            ModernClientSafeLoginMode = false,
            EnablePivotOverlay = true,
            EnableFlintlockDualPistolsOverlay = true,
            AutoLoadSoulHudAddon = true,
            AutoLoadFlintlockAddon = true,
            AutoLoadGearAddon = true
        };

        var ini = ModernClientConfigGenerator.BuildIniContent(settings, "play.soulspirexi.com", null, null);
        Assert.Contains("[pivot.order]", ini);
        Assert.Contains("0=soulspirexi", ini);
        Assert.Contains("1=flintlock-akimbo-compact", ini);
        Assert.Contains("singlemenu=0", ini);
        Assert.Contains("ashita.interface=4.30", ini);

        var boot = ModernClientConfigGenerator.BuildBootScriptContent(settings);
        Assert.Contains("/plugin load soulspire_native", boot);
        Assert.Contains("/addon load soulspire_core ashita", boot);
        Assert.Contains("/addon load soulspire_flintlock ashita", boot);
        Assert.Contains("/addon load soulspire_gear ashita", boot);
    }

    [Fact]
    public void BuildModernClientStartInfo_UsesPasswordStdinAndNeverExposesPasswordInArgs()
    {
        var startInfo = GameLaunchService.BuildModernClientStartInfo(
            @"C:\SoulspireXI\ModernClient",
            @"C:\SoulspireXI\ModernClient\VanaCore.exe",
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
    public void ModernClientConfigGenerator_IsolatesDirectoryAndSupportsRollback()
    {
        var root = Path.Combine(Path.GetTempPath(), "sxi-modern-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var ashitaDir = Path.Combine(root, "Ashita");
            var modernDir = Path.Combine(root, "ModernClient");
            Directory.CreateDirectory(ashitaDir);
            Directory.CreateDirectory(modernDir);

            var ashitaSentinel = Path.Combine(ashitaDir, "sentinel.txt");
            File.WriteAllText(ashitaSentinel, "classic-untouched");
            File.WriteAllText(Path.Combine(modernDir, "VanaCore.exe"), "v1-binary");
            File.WriteAllText(Path.Combine(modernDir, "VanaCore.Core.dll"), "v1-core");

            var settings = LauncherSettings.CreateDefault(root);
            settings.Username = "Rin";
            settings.ModernClientSafeLoginMode = true;

            var gen = new ModernClientConfigGenerator();
            var iniFile = gen.WriteAllConfigs(modernDir, settings, "play.soulspirexi.com", null, null);
            Assert.True(File.Exists(Path.Combine(modernDir, iniFile)));
            Assert.True(File.Exists(Path.Combine(modernDir, "scripts", "boot.txt")));
            Assert.Equal("classic-untouched", File.ReadAllText(ashitaSentinel));

            // Snapshot, mutate, then verify rollback restores v1 binaries cleanly.
            Assert.Equal(2, ModernClientConfigGenerator.CreateRollbackSnapshot(modernDir));
            File.WriteAllText(Path.Combine(modernDir, "VanaCore.exe"), "v2-broken");
            File.WriteAllText(Path.Combine(modernDir, "VanaCore.Core.dll"), "v2-broken");

            Assert.Equal(2, ModernClientConfigGenerator.RestoreRollbackSnapshot(modernDir));
            Assert.Equal("v1-binary", File.ReadAllText(Path.Combine(modernDir, "VanaCore.exe")));
            Assert.Equal("v1-core", File.ReadAllText(Path.Combine(modernDir, "VanaCore.Core.dll")));
        }
        finally
        {
            if (Directory.Exists(root))
            {
                Directory.Delete(root, recursive: true);
            }
        }
    }
}

using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class TestingQolSettingsTests
{
    private readonly AshitaConfigGenerator _generator = new();

    private sealed class StubHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(responder(request));
    }

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    [Fact]
    public void DefaultSetting_IsEnabledOnNewAndLegacySettingsJson()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_qol_default_{Guid.NewGuid():N}");
        var launcherDir = Path.Combine(tempRoot, "Launcher");
        var appDataDir = Path.Combine(tempRoot, "AppData");
        Directory.CreateDirectory(launcherDir);
        Directory.CreateDirectory(appDataDir);

        try
        {
            var fresh = LauncherSettings.CreateDefault(launcherDir);
            Assert.True(fresh.EnableAutomaticTestingQolSettings);
            Assert.True(fresh.KeyboardBlockBindsDuringInput);
            Assert.False(fresh.KeyboardWindowsKeyEnabled);

            // Legacy settings.json without EnableAutomaticTestingQolSettings must default to Enabled (true).
            File.WriteAllText(
                Path.Combine(appDataDir, "settings.json"),
                """{"Username":"dev","WindowWidth":2560,"WindowHeight":1440}""",
                Encoding.UTF8);

            var service = new SettingsService(launcherDir, appDataDir);
            var loaded = service.Load();
            Assert.True(loaded.EnableAutomaticTestingQolSettings);
            Assert.True(loaded.KeyboardBlockBindsDuringInput);
            Assert.False(loaded.KeyboardWindowsKeyEnabled);
            Assert.Equal(2560, loaded.WindowWidth);
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Theory]
    [InlineData(UpdateChannel.Testing)]
    [InlineData(UpdateChannel.TestingRegistry24Hook)]
    [InlineData(UpdateChannel.TestingSearchLegacyText)]
    [InlineData(UpdateChannel.TestingSearchAlignedText)]
    public void ChannelSwitching_AllTestingChannelsEnableQolOnCanonicalMainServer(UpdateChannel channel)
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = channel,
            EnableAutomaticTestingQolSettings = true
        };

        // Canonical main playable test server (play.soulspirexi.com) using a Testing channel.
        var ini = _generator.BuildBootIniContent(
            settings,
            serverHost: "play.soulspirexi.com",
            useHairpin: false,
            password: null,
            xiloaderPath: "xiloader.exe",
            manifestChannel: "testing",
            serverName: "SoulspireXI");

        Assert.Contains(AshitaConfigGenerator.TestingQolIniMarker, ini);
        Assert.Contains("keyboard.blockbindsduringinput = 0", ini);
        Assert.Contains("keyboard.windowskeyenabled = 1", ini);
    }

    [Theory]
    [InlineData("staging.soulspirexi.com", "SoulspireXI")]
    [InlineData("stg-core-ui.soulspirexi.com", "SoulspireXI")]
    [InlineData("test.soulspirexi.com", "SoulspireXI")]
    [InlineData("play-staging.soulspirexi.com", "SoulspireXI")]
    [InlineData("localhost", "SoulspireXI")]
    [InlineData("127.0.0.1", "SoulspireXI")]
    [InlineData("192.168.1.50", "SoulspireXI")]
    [InlineData("10.77.0.2", "SoulspireXI")]
    [InlineData("100.64.12.34", "SoulspireXI")]
    [InlineData("unraid.tailnet.ts.net", "SoulspireXI")]
    [InlineData("play.custom.example", "SoulspireXI Staging")]
    public void ServerSwitching_StagingServersEnableQolEvenOnStableChannel(string host, string serverName)
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Stable,
            EnableAutomaticTestingQolSettings = true
        };

        var ini = _generator.BuildBootIniContent(
            settings,
            serverHost: host,
            useHairpin: false,
            password: null,
            xiloaderPath: "xiloader.exe",
            manifestChannel: "stable",
            serverName: serverName);

        Assert.Contains(AshitaConfigGenerator.TestingQolIniMarker, ini);
        Assert.Contains("keyboard.blockbindsduringinput = 0", ini);
        Assert.Contains("keyboard.windowskeyenabled = 1", ini);
    }

    [Theory]
    [InlineData("play.soulspirexi.com")]
    [InlineData("play.example.com")]
    public void ProductionServerOnStableChannel_DoesNotApplyTestingQol(string host)
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Stable,
            EnableAutomaticTestingQolSettings = true,
            KeyboardBlockBindsDuringInput = true,
            KeyboardWindowsKeyEnabled = false
        };

        var ini = _generator.BuildBootIniContent(
            settings,
            serverHost: host,
            useHairpin: false,
            password: null,
            xiloaderPath: "xiloader.exe",
            manifestChannel: "stable",
            serverName: "SoulspireXI");

        Assert.DoesNotContain(AshitaConfigGenerator.TestingQolIniMarker, ini);
        Assert.Contains("keyboard.blockbindsduringinput = 1", ini);
        Assert.Contains("keyboard.windowskeyenabled = 0", ini);
    }

    [Fact]
    public void DisablingSetting_SuppressesTestingQolOnTestingChannelAndStagingServer()
    {
        var settings = new LauncherSettings
        {
            UpdateChannel = UpdateChannel.Testing,
            EnableAutomaticTestingQolSettings = false,
            KeyboardBlockBindsDuringInput = true,
            KeyboardWindowsKeyEnabled = false
        };

        var ini = _generator.BuildBootIniContent(
            settings,
            serverHost: "staging.soulspirexi.com",
            useHairpin: false,
            password: null,
            xiloaderPath: "xiloader.exe",
            manifestChannel: "testing",
            serverName: "SoulspireXI Staging");

        Assert.DoesNotContain(AshitaConfigGenerator.TestingQolIniMarker, ini);
        Assert.Contains("keyboard.blockbindsduringinput = 1", ini);
        Assert.Contains("keyboard.windowskeyenabled = 0", ini);
    }

    [Fact]
    public void FullLifecycle_StableToTestingToRestartToStable_PreservesAndRestoresOriginalPlayerPreferences()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_qol_lifecycle_{Guid.NewGuid():N}");
        var launcherDir = Path.Combine(tempRoot, "Launcher");
        var ashitaDir = Path.Combine(launcherDir, "Ashita");
        var appDataDir = Path.Combine(tempRoot, "AppData");
        Directory.CreateDirectory(Path.Combine(ashitaDir, "config", "boot"));
        Directory.CreateDirectory(Path.Combine(ashitaDir, "scripts"));
        Directory.CreateDirectory(appDataDir);

        try
        {
            var settingsService = new SettingsService(launcherDir, appDataDir);
            var settings = settingsService.Load();
            settings.WindowWidth = 2560;
            settings.WindowHeight = 1440;
            settings.GamepadAllowBackground = false;
            settings.UpdateChannel = UpdateChannel.Stable;

            // Player manually configured Windows key enabled = 1, block binds = 1 on Stable.
            var bootIniPath = Path.Combine(ashitaDir, "config", "boot", AshitaConfigGenerator.BootConfigFileName);
            File.WriteAllText(bootIniPath, """
                [ashita.input]
                gamepad.allowbackground = 0
                keyboard.blockbindsduringinput = 1
                keyboard.windowskeyenabled = 1
                """, Encoding.UTF8);

            // Minimal script without screenshot/paste bindings yet, plus custom user bind.
            var scriptPath = Path.Combine(ashitaDir, "scripts", AshitaConfigGenerator.ScriptFileName);
            File.WriteAllText(scriptPath, string.Join(Environment.NewLine,
                "# Player custom script",
                "/load addons",
                "/wait 3",
                "/bind F11 /ambient",
                "/addon load custom_user_addon"), Encoding.UTF8);

            // 1. Switch to Testing channel (canonical main test server) and launch.
            settings.UpdateChannel = UpdateChannel.Testing;
            if (_generator.CapturePlayerInputPreferencesIfUnmanaged(ashitaDir, settings))
            {
                settingsService.Save(settings, plainPassword: null);
            }
            else
            {
                settingsService.Save(settings, plainPassword: null);
            }

            _generator.WriteAllConfigs(
                ashitaDir,
                settings,
                serverHost: "play.soulspirexi.com",
                useHairpin: false,
                password: null,
                xiloaderPath: "xiloader.exe",
                manifestChannel: "testing",
                serverName: "SoulspireXI");

            var testingIni1 = File.ReadAllText(bootIniPath, Encoding.UTF8);
            var testingScript1 = File.ReadAllText(scriptPath, Encoding.UTF8);

            Assert.Contains(AshitaConfigGenerator.TestingQolIniMarker, testingIni1);
            Assert.Contains("keyboard.blockbindsduringinput = 0", testingIni1);
            Assert.Contains("keyboard.windowskeyenabled = 1", testingIni1);
            Assert.Contains("0001 = 2560", testingIni1);
            Assert.Contains("gamepad.allowbackground = 0", testingIni1);
            Assert.Contains(AshitaConfigGenerator.DefaultScreenshotLoadLine, testingScript1);
            Assert.Contains(AshitaConfigGenerator.DefaultScreenshotBindLine, testingScript1);
            Assert.Contains(AshitaConfigGenerator.DefaultClipboardPasteBindLine, testingScript1);
            Assert.Contains("/bind F11 /ambient", testingScript1);
            Assert.Contains("/addon load custom_user_addon", testingScript1);

            // 2. Simulate launcher restart and second launch on Testing -> must be idempotent and keep original prefs intact.
            var reloaded = new SettingsService(launcherDir, appDataDir).Load();
            Assert.Equal(UpdateChannel.Testing, reloaded.UpdateChannel);
            Assert.True(reloaded.EnableAutomaticTestingQolSettings);
            Assert.True(reloaded.KeyboardBlockBindsDuringInput); // Original preserved!
            Assert.True(reloaded.KeyboardWindowsKeyEnabled);     // Original preserved!

            _generator.WriteAllConfigs(
                ashitaDir,
                reloaded,
                serverHost: "play.soulspirexi.com",
                useHairpin: false,
                password: null,
                xiloaderPath: "xiloader.exe",
                manifestChannel: "testing",
                serverName: "SoulspireXI");

            var testingIni2 = File.ReadAllText(bootIniPath, Encoding.UTF8);
            var testingScript2 = File.ReadAllText(scriptPath, Encoding.UTF8);
            Assert.Equal(testingIni1, testingIni2);
            Assert.Equal(testingScript1, testingScript2);

            // 3. Switch back to Stable on play.soulspirexi.com -> original player preferences restored cleanly.
            reloaded.UpdateChannel = UpdateChannel.Stable;
            settingsService.Save(reloaded, plainPassword: null);
            _generator.WriteAllConfigs(
                ashitaDir,
                reloaded,
                serverHost: "play.soulspirexi.com",
                useHairpin: false,
                password: null,
                xiloaderPath: "xiloader.exe",
                manifestChannel: "stable",
                serverName: "SoulspireXI");

            var stableIni = File.ReadAllText(bootIniPath, Encoding.UTF8);
            var stableScript = File.ReadAllText(scriptPath, Encoding.UTF8);

            Assert.DoesNotContain(AshitaConfigGenerator.TestingQolIniMarker, stableIni);
            Assert.Contains("keyboard.blockbindsduringinput = 1", stableIni);
            Assert.Contains("keyboard.windowskeyenabled = 1", stableIni);
            Assert.Contains("0001 = 2560", stableIni);
            Assert.Contains("gamepad.allowbackground = 0", stableIni);
            Assert.DoesNotContain(AshitaConfigGenerator.TestingQolScriptStartMarker, stableScript);
            Assert.DoesNotContain(AshitaConfigGenerator.DefaultClipboardPasteBindLine, stableScript);
            Assert.Contains("/bind F11 /ambient", stableScript);
            Assert.Contains("/addon load custom_user_addon", stableScript);
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public void BootScriptMerge_PreservesExistingCustomPasteAndScreenshotBindingsWithoutDuplication()
    {
        var existing = string.Join(Environment.NewLine,
            "# Custom player script",
            "/load addons",
            "/load screenshot",
            "/bind F10 /screenshot",
            "/bind ^v /paste",
            "/wait 3",
            "/addon load fps");

        var settings = new LauncherSettings { FpsCap = 60 };

        var testingMerged = _generator.MergeBootScriptContent(existing, settings, applyTestingQolBindings: true);
        var testingMergedTwice = _generator.MergeBootScriptContent(testingMerged, settings, applyTestingQolBindings: true);

        Assert.Equal(testingMerged, testingMergedTwice);
        Assert.Contains("/load screenshot", testingMerged);
        Assert.Contains("/bind F10 /screenshot", testingMerged);
        Assert.Contains("/bind ^v /paste", testingMerged);
        Assert.DoesNotContain(AshitaConfigGenerator.TestingQolScriptStartMarker, testingMerged);
        Assert.DoesNotContain("/bind SYSRQ /screenshot hide", testingMerged);
        Assert.DoesNotContain("/bind $^v /paste", testingMerged);
    }

    [Fact]
    public async Task ClientSynchronization_DoesNotResetTestingQolOrBootConfigs()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_qol_sync_{Guid.NewGuid():N}");
        var ashitaDir = Path.Combine(tempRoot, "Ashita");
        var bootDir = Path.Combine(ashitaDir, "config", "boot");
        var scriptsDir = Path.Combine(ashitaDir, "scripts");
        Directory.CreateDirectory(bootDir);
        Directory.CreateDirectory(scriptsDir);

        try
        {
            var settings = LauncherSettings.CreateDefault(tempRoot);
            settings.UpdateChannel = UpdateChannel.Testing;
            settings.EnableAutomaticTestingQolSettings = true;

            _generator.WriteAllConfigs(
                ashitaDir,
                settings,
                serverHost: "play.soulspirexi.com",
                useHairpin: false,
                password: null,
                xiloaderPath: "xiloader.exe",
                manifestChannel: "testing",
                serverName: "SoulspireXI");

            var bootIniPath = Path.Combine(bootDir, AshitaConfigGenerator.BootConfigFileName);
            var scriptPath = Path.Combine(scriptsDir, AshitaConfigGenerator.ScriptFileName);
            var originalBootIni = await File.ReadAllTextAsync(bootIniPath, Encoding.UTF8);
            var originalScript = await File.ReadAllTextAsync(scriptPath, Encoding.UTF8);

            var addonPayload = Encoding.UTF8.GetBytes("-- updated testing addon");
            var overwritePayload = Encoding.UTF8.GetBytes("should-never-overwrite");

            var manifest = new LauncherManifest
            {
                Channel = "testing",
                ManifestVersion = "2.2.0-testing.1",
                Repo = new ManifestRepo { RawBaseUrl = "https://updates.soulspirexi.test" },
                Files =
                [
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        SourcePath = "addons/ashita4/crystalsocket/core.lua",
                        TargetPath = "crystalsocket/core.lua",
                        Sha256 = Sha256(addonPayload),
                        Size = addonPayload.Length
                    },
                    new ManifestFileEntry
                    {
                        Category = "resource",
                        SourcePath = "config/boot/soulspirexi.ini",
                        TargetPath = "config/boot/soulspirexi.ini",
                        Sha256 = Sha256(overwritePayload),
                        Size = overwritePayload.Length
                    },
                    new ManifestFileEntry
                    {
                        Category = "resource",
                        SourcePath = "scripts/soulspirexi.txt",
                        TargetPath = "scripts/soulspirexi.txt",
                        Sha256 = Sha256(overwritePayload),
                        Size = overwritePayload.Length
                    }
                ]
            };

            using var client = new HttpClient(new StubHttpHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(addonPayload)
            }));
            var syncService = new ManifestUpdateService(client);
            var synced = await syncService.SyncSoulspireFilesAsync(manifest, settings, forceAll: false);

            Assert.Equal(1, synced);
            Assert.Equal(originalBootIni, await File.ReadAllTextAsync(bootIniPath, Encoding.UTF8));
            Assert.Equal(originalScript, await File.ReadAllTextAsync(scriptPath, Encoding.UTF8));
            Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("resource", "config/boot/soulspirexi.ini"));
            Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("resource", "scripts/soulspirexi.txt"));
            Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("resource", "scripts/default.txt"));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public void SettingsImport_ImportsKeyboardInputPrefsFromUnmanagedIniAndIgnoresTestingQolManagedIni()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"soulspire_qol_import_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);

        try
        {
            var unmanagedIni = Path.Combine(tempDir, "player.ini");
            File.WriteAllText(unmanagedIni, """
                [ashita.input]
                gamepad.allowbackground = 1
                keyboard.blockbindsduringinput = 0
                keyboard.windowskeyenabled = 1
                """, Encoding.UTF8);

            var settings = new LauncherSettings();
            var importer = new SettingsImportService();
            Assert.True(importer.TryImportFromAshitaIni(unmanagedIni, settings, gamepadOnly: false));
            Assert.False(settings.KeyboardBlockBindsDuringInput);
            Assert.True(settings.KeyboardWindowsKeyEnabled);

            // Now ensure a Testing-QoL-managed ini does NOT overwrite original preferences.
            var managedIni = Path.Combine(tempDir, "managed.ini");
            File.WriteAllText(managedIni, $"""
                [ashita.input]
                {AshitaConfigGenerator.TestingQolIniMarker}
                gamepad.allowbackground = 1
                keyboard.blockbindsduringinput = 0
                keyboard.windowskeyenabled = 1
                """, Encoding.UTF8);

            var originalSettings = new LauncherSettings
            {
                KeyboardBlockBindsDuringInput = true,
                KeyboardWindowsKeyEnabled = false
            };
            importer.TryImportFromAshitaIni(managedIni, originalSettings, gamepadOnly: false);
            Assert.True(originalSettings.KeyboardBlockBindsDuringInput);
            Assert.False(originalSettings.KeyboardWindowsKeyEnabled);
        }
        finally
        {
            if (Directory.Exists(tempDir)) Directory.Delete(tempDir, recursive: true);
        }
    }

    [Fact]
    public void SettingsService_PersistsDisabledToggleAcrossRestarts()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_qol_persist_{Guid.NewGuid():N}");
        var launcherDir = Path.Combine(tempRoot, "Launcher");
        var appDataDir = Path.Combine(tempRoot, "AppData");
        Directory.CreateDirectory(launcherDir);
        Directory.CreateDirectory(appDataDir);

        try
        {
            var service1 = new SettingsService(launcherDir, appDataDir);
            var settings = service1.Load();
            Assert.True(settings.EnableAutomaticTestingQolSettings);

            settings.EnableAutomaticTestingQolSettings = false;
            settings.UpdateChannel = UpdateChannel.Testing;
            service1.Save(settings, plainPassword: null);

            var service2 = new SettingsService(launcherDir, appDataDir);
            var reloaded = service2.Load();
            Assert.False(reloaded.EnableAutomaticTestingQolSettings);
            Assert.Equal(UpdateChannel.Testing, reloaded.UpdateChannel);
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }
}

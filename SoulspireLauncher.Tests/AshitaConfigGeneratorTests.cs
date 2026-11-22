using System.IO;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class AshitaConfigGeneratorTests
{
    private readonly AshitaConfigGenerator _generator = new();

    [Fact]
    public void BuildXiloaderCommand_IncludesHostAndHairpin_WhenEnabled()
    {
        var cmd = _generator.BuildXiloaderCommand(
            serverHost: " play.soulspirexi.example ",
            useHairpin: true,
            username: "hero",
            password: "secret",
            autoLogin: false,
            language: "US");

        Assert.Equal("--server play.soulspirexi.example --hairpin", cmd);
    }

    [Fact]
    public void BuildXiloaderCommand_IncludesQuotedCredentialsAndLanguage_WhenAutoLoginEnabled()
    {
        var cmd = _generator.BuildXiloaderCommand(
            serverHost: "127.0.0.1",
            useHairpin: false,
            username: "hero name",
            password: "p@ss \"word\"",
            autoLogin: true,
            language: "EU");

        Assert.Equal("--server 127.0.0.1 --lang EU --user \"hero name\" --pass \"p@ss \\\"word\\\"\"", cmd);
    }

    [Fact]
    public void BuildXiloaderCommand_OmitsCredentials_WhenPasswordEmpty()
    {
        var cmd = _generator.BuildXiloaderCommand(
            serverHost: "127.0.0.1",
            useHairpin: false,
            username: "hero",
            password: "",
            autoLogin: true,
            language: "JP");

        Assert.Equal("--server 127.0.0.1 --lang JP", cmd);
    }

    [Fact]
    public void BuildBootIniContent_WritesExpectedSectionsAndWindowMode()
    {
        var settings = new LauncherSettings
        {
            WindowMode = WindowModeOption.Borderless,
            WindowWidth = 2560,
            WindowHeight = 1440,
            BackgroundWidth = 4096,
            BackgroundHeight = 4096,
            MenuWidth = 1920,
            MenuHeight = 1080,
            Language = "US",
            EnablePivotOverlay = true,
            AutoCloseOnLaunch = true
        };

        var ini = _generator.BuildBootIniContent(
            settings,
            serverHost: "play.example.com",
            useHairpin: true,
            password: null,
            xiloaderPath: @"C:\Ashita\bootloader\xiloader.exe");

        Assert.Contains("[ashita.launcher]", ini);
        Assert.Contains("autoclose = 1", ini);
        Assert.Contains("file = C:\\Ashita\\bootloader\\xiloader.exe", ini);
        Assert.Contains("command = --server play.example.com --hairpin", ini);
        Assert.Contains("script = soulspirexi.txt", ini);
        Assert.Contains("pivot = 1", ini);
        Assert.Contains("pivot = soulspirexi", ini);
        Assert.Contains("0001 = 2560", ini);
        Assert.Contains("0002 = 1440", ini);
        Assert.Contains("0003 = 4096", ini);
        Assert.Contains("0034 = 3", ini);
        Assert.Contains("0037 = 1920", ini);
        Assert.Contains("0038 = 1080", ini);
    }

    [Fact]
    public void BuildBootIniContent_OmitsPivotPlugin_WhenDisabled()
    {
        var settings = new LauncherSettings
        {
            EnablePivotOverlay = false,
            WindowMode = WindowModeOption.Fullscreen
        };

        var ini = _generator.BuildBootIniContent(
            settings,
            serverHost: "127.0.0.1",
            useHairpin: false,
            password: null,
            xiloaderPath: "xiloader.exe");

        Assert.DoesNotContain("pivot = 1", ini);
        Assert.DoesNotContain("pivot = soulspirexi", ini);
        Assert.Contains("0034 = 0", ini);
    }

    [Fact]
    public void BuildPivotIniContent_SetsRootPathAndOverlayName()
    {
        var pivotIni = _generator.BuildPivotIniContent(@"C:\Ashita\polplugins\DATs");

        Assert.Contains("[settings]", pivotIni);
        Assert.Contains(@"root_path=C:\Ashita\polplugins\DATs", pivotIni);
        Assert.Contains("[overlays]", pivotIni);
        Assert.Contains("0=soulspirexi", pivotIni);
        Assert.DoesNotContain("flintlock-akimbo-compact", pivotIni);
    }

    [Fact]
    public void BuildPivotIniContent_IncludesFlintlockOverlayFirst_WhenOptedIn()
    {
        var pivotIni = _generator.BuildPivotIniContent(@"C:\Ashita\polplugins\DATs", enableFlintlockOverlay: true);

        Assert.Contains("0=flintlock-akimbo-compact", pivotIni);
        Assert.Contains("1=soulspirexi", pivotIni);
    }

    [Fact]
    public void WriteAllConfigs_EnableThenDisableFlintlockOverlay_LeavesNoStalePivotConfig()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"soulspire_pivot_toggle_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDir);
        try
        {
            var settings = new LauncherSettings
            {
                AshitaPath = tempDir,
                EnablePivotOverlay = true,
                EnableFlintlockDualPistolsOverlay = true
            };

            _generator.WriteAllConfigs(tempDir, settings, "127.0.0.1", false, null, "xiloader.exe");
            var pivotIniPath = Path.Combine(tempDir, "config", "pivot", "soulspirexi.ini");
            var enabledText = File.ReadAllText(pivotIniPath);
            Assert.Contains("0=flintlock-akimbo-compact", enabledText);
            Assert.Contains("1=soulspirexi", enabledText);

            // Disable Flintlock overlay while keeping base Pivot overlay enabled.
            settings.EnableFlintlockDualPistolsOverlay = false;
            _generator.WriteAllConfigs(tempDir, settings, "127.0.0.1", false, null, "xiloader.exe");
            var disabledText = File.ReadAllText(pivotIniPath);
            Assert.DoesNotContain("flintlock-akimbo-compact", disabledText);
            Assert.Contains("0=soulspirexi", disabledText);

            // Re-enable, then disable Pivot entirely -> boot ini omits pivot and pivot ini has no stale Flintlock line.
            settings.EnableFlintlockDualPistolsOverlay = true;
            _generator.WriteAllConfigs(tempDir, settings, "127.0.0.1", false, null, "xiloader.exe");
            settings.EnablePivotOverlay = false;
            _generator.WriteAllConfigs(tempDir, settings, "127.0.0.1", false, null, "xiloader.exe");
            var bootIniText = File.ReadAllText(Path.Combine(tempDir, "config", "boot", "soulspirexi.ini"));
            var pivotOffText = File.ReadAllText(pivotIniPath);
            Assert.DoesNotContain("pivot = 1", bootIniText);
            Assert.DoesNotContain("flintlock-akimbo-compact", pivotOffText);
        }
        finally
        {
            if (Directory.Exists(tempDir))
            {
                Directory.Delete(tempDir, recursive: true);
            }
        }
    }

    [Theory]
    [InlineData(60, "/fps 1")]
    [InlineData(30, "/fps 2")]
    [InlineData(0, "/fps 0")]
    public void MergeBootScriptContent_UpdatesFpsAndPreservesUserLines(int fpsCap, string expectedFpsLine)
    {
        var existing = string.Join(Environment.NewLine,
            "# custom script",
            "/load addons",
            "/addon load custom_addon",
            "/fps 2",
            "/addon load soulspire_talents");

        var settings = new LauncherSettings
        {
            AutoLoadTalentsAddon = true,
            FpsCap = fpsCap
        };

        var merged = _generator.MergeBootScriptContent(existing, settings);

        Assert.Contains("/addon load custom_addon", merged);
        Assert.Contains("/addon load fps", merged);
        Assert.Contains(expectedFpsLine, merged);
        Assert.Single(
            merged.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries),
            line => line.Trim().Equals("/addon load soulspire_talents", StringComparison.OrdinalIgnoreCase));
        Assert.Single(
            merged.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries),
            line => line.Trim().StartsWith("/fps ", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void MergeBootScriptContent_RemovesTalentsAddon_WhenDisabled()
    {
        var existing = string.Join(Environment.NewLine,
            "/load addons",
            "/addon load soulspire_talents",
            "/fps 1");

        var settings = new LauncherSettings
        {
            AutoLoadTalentsAddon = false,
            FpsCap = 60
        };

        var merged = _generator.MergeBootScriptContent(existing, settings);

        Assert.DoesNotContain("soulspire_talents", merged);
        Assert.Contains("/addon load crystalsocket", merged);
        Assert.Contains("/fps 1", merged);
    }

    [Fact]
    public void MergeBootScriptContent_RemovesCrystalSocketAddon_WhenDisabled()
    {
        var existing = string.Join(Environment.NewLine,
            "/load addons",
            "/addon load crystalsocket",
            "/fps 1");

        var settings = new LauncherSettings
        {
            AutoLoadTalentsAddon = true,
            AutoLoadCrystalSocketAddon = false,
            FpsCap = 60
        };

        var merged = _generator.MergeBootScriptContent(existing, settings);

        Assert.DoesNotContain("crystalsocket", merged);
        Assert.DoesNotContain("crystaljobs", merged);
        Assert.Contains("/addon load soulspire_talents", merged);
        Assert.Contains("/addon load soulspire_gear", merged);
        Assert.Contains("/fps 1", merged);
    }

    [Fact]
    public void MergeBootScriptContent_RemovesGearAddon_WhenDisabled()
    {
        var existing = string.Join(Environment.NewLine,
            "/load addons",
            "/addon load soulspire_gear",
            "/fps 1");

        var settings = new LauncherSettings
        {
            AutoLoadTalentsAddon = true,
            AutoLoadGearAddon = false,
            FpsCap = 60
        };

        var merged = _generator.MergeBootScriptContent(existing, settings);

        Assert.DoesNotContain("soulspire_gear", merged);
        Assert.Contains("/addon load soulspire_talents", merged);
        Assert.Contains("/addon load soulspire_soulhud", merged);
        Assert.Contains("/fps 1", merged);
    }

    [Fact]
    public void MergeBootScriptContent_StripsRetiredBoostAddon()
    {
        var existing = string.Join(Environment.NewLine,
            "/load addons",
            "/addon load overlords_boost",
            "/fps 1");

        var merged = _generator.MergeBootScriptContent(existing, new LauncherSettings { FpsCap = 60 });

        Assert.DoesNotContain("overlords_boost", merged);
        Assert.Contains("/addon load soulspire_soulhud", merged);
    }

    [Fact]
    public void MergeBootScriptContent_IncludesAndRemovesSoulHudAddon()
    {
        var existing = string.Join(Environment.NewLine,
            "/load addons",
            "/addon load soulspire_soulhud",
            "/fps 1");

        var settings = new LauncherSettings
        {
            AutoLoadTalentsAddon = true,
            AutoLoadSoulHudAddon = false,
            FpsCap = 60
        };

        var merged = _generator.MergeBootScriptContent(existing, settings);

        Assert.DoesNotContain("soulspire_soulhud", merged);
        Assert.Contains("/addon load soulspire_talents", merged);
        Assert.Contains("/fps 1", merged);
    }

    [Fact]
    public void MergeBootScriptContent_IncludesAndRemovesFlintlockAddon()
    {
        var added = _generator.MergeBootScriptContent(null, new LauncherSettings
        {
            AutoLoadFlintlockAddon = true
        });
        Assert.Contains("/addon load soulspire_flintlock", added);

        var removed = _generator.MergeBootScriptContent(
            "/load addons\r\n/addon load soulspire_flintlock\r\n/fps 1",
            new LauncherSettings
            {
                AutoLoadFlintlockAddon = false,
                FpsCap = 60
            });
        Assert.DoesNotContain("soulspire_flintlock", removed);
        Assert.Contains("/fps 1", removed);
    }

    [Fact]
    public void MergeBootScriptContent_IncludesAndDeduplicatesSoulspireCoreAddon()
    {
        var existing = string.Join(Environment.NewLine,
            "/load addons",
            "/addon load soulspire_core",
            "/addon load soulspire_core",
            "/fps 1");

        var merged = _generator.MergeBootScriptContent(existing, new LauncherSettings { FpsCap = 60 });

        var coreCount = merged
            .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
            .Count(line => line.Trim().Equals("/addon load soulspire_core", StringComparison.OrdinalIgnoreCase));
        Assert.Equal(1, coreCount);
        Assert.Contains("/addon load crystalsocket", merged);
        Assert.Contains("/addon load soulspire_talents", merged);
        Assert.Contains("/addon load soulspire_soulhud", merged);
        Assert.Contains("/addon load soulspire_soul_actions", merged);
    }

    [Fact]
    public void BuildBootIniContent_WritesInputAndGamepadRegistryKeys()
    {
        var settings = new LauncherSettings
        {
            FfxiPath = @"D:\PlayOnline\SquareEnix\FINAL FANTASY XI",
            GamepadAllowBackground = true,
            GamepadDisableEnumeration = true,
            UseCustomGamepadConfig = true,
            EnableGamepad = true,
            EnableXInput = true,
            PadMode = "0,1,0,1,0,0",
            PadSin = "8,9,10,11,4,5,6,7",
            PadGuid = "{1234-ABCD}"
        };

        var ini = _generator.BuildBootIniContent(
            settings,
            serverHost: "127.0.0.1",
            useHairpin: false,
            password: null,
            xiloaderPath: "xiloader.exe");

        Assert.Contains("[ashita.input]", ini);
        Assert.Contains("gamepad.allowbackground = 1", ini);
        Assert.Contains("gamepad.disableenumeration = 1", ini);
        Assert.Contains(@"0042 = D:\PlayOnline\SquareEnix\FINAL FANTASY XI", ini);
        Assert.Contains("padmode000 = 1,1,0,1,0,1", ini);
        Assert.Contains("padsin000 = 8,9,10,11,4,5,6,7", ini);
        Assert.Contains("padguid000 = {1234-ABCD}", ini);
        Assert.Contains("padexsin000 = -1", ini);
    }

    [Fact]
    public void BuildEffectivePadMode_UsesPassthroughWhenNotCustomized()
    {
        var settings = new LauncherSettings
        {
            UseCustomGamepadConfig = false,
            PadMode = string.Empty
        };

        Assert.Equal("-1", AshitaConfigGenerator.BuildEffectivePadMode(settings));
    }

    [Fact]
    public void MergeBootScriptContent_IncludesAndRemovesMetricsAddon()
    {
        var added = _generator.MergeBootScriptContent(null, new LauncherSettings
        {
            AutoLoadMetricsAddon = true
        });
        Assert.Contains("/addon load metrics", added);

        var removed = _generator.MergeBootScriptContent(
            "/load addons\r\n/addon load metrics\r\n/fps 1",
            new LauncherSettings
            {
                AutoLoadMetricsAddon = false,
                FpsCap = 60
            });
        Assert.DoesNotContain("metrics", removed);
        Assert.Contains("/fps 1", removed);
    }

    [Fact]
    public void MergeBootScriptContent_IncludesAndRemovesQolAddons()
    {
        var added = _generator.MergeBootScriptContent(null, new LauncherSettings
        {
            AutoLoadCheckerAddon = true,
            AutoLoadMobDbAddon = true,
            AutoLoadKazenoeyeAddon = true
        });
        Assert.Contains("/addon load checker", added);
        Assert.Contains("/addon load mobdb", added);
        Assert.Contains("/addon load kazenoeye", added);

        var removed = _generator.MergeBootScriptContent(
            "/load addons\r\n/addon load checker\r\n/addon load mobdb\r\n/addon load kazenoeye\r\n/fps 1",
            new LauncherSettings
            {
                AutoLoadCheckerAddon = false,
                AutoLoadMobDbAddon = false,
                AutoLoadKazenoeyeAddon = false,
                FpsCap = 60
            });
        Assert.DoesNotContain("checker", removed);
        Assert.DoesNotContain("mobdb", removed);
        Assert.DoesNotContain("kazenoeye", removed);
        Assert.Contains("/fps 1", removed);
    }
}

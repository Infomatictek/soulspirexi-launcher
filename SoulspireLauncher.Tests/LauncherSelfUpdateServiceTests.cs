using System.IO;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class LauncherSelfUpdateServiceTests
{
    [Theory]
    [InlineData("v1.0.3", 1, 0, 3)]
    [InlineData("V2.4.10", 2, 4, 10)]
    [InlineData("1.0.2", 1, 0, 2)]
    [InlineData("v1.2.3-beta.1", 1, 2, 3)]
    [InlineData("1.2", 1, 2, 0)]
    public void TryParseVersionTag_NormalizesValidTags(string tag, int major, int minor, int build)
    {
        Assert.True(LauncherSelfUpdateService.TryParseVersionTag(tag, out var parsed));
        Assert.Equal(new Version(major, minor, build), parsed);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not-a-version")]
    public void TryParseVersionTag_RejectsInvalidTags(string? tag)
    {
        Assert.False(LauncherSelfUpdateService.TryParseVersionTag(tag, out _));
    }

    [Fact]
    public void IsNewerVersion_IgnoresFourPartAssemblyRevisionZero()
    {
        var fourPartCurrent = new Version(1, 0, 2, 0);

        Assert.False(LauncherSelfUpdateService.IsNewerVersion(fourPartCurrent, "v1.0.2", out _));
        Assert.False(LauncherSelfUpdateService.IsNewerVersion(fourPartCurrent, "v1.0.1", out _));
        Assert.True(LauncherSelfUpdateService.IsNewerVersion(fourPartCurrent, "v1.0.3", out var latest));
        Assert.Equal(new Version(1, 0, 3), latest);
    }

    [Fact]
    public void ParseLatestReleaseJson_DetectsNewerExeAsset()
    {
        const string json = """
        {
          "tag_name": "v1.0.4",
          "html_url": "https://github.com/Infomatictek/soulspirexi-launcher/releases/tag/v1.0.4",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "SoulspireLauncher-win-x64.zip",
              "browser_download_url": "https://example.com/SoulspireLauncher-win-x64.zip",
              "size": 70000000
            },
            {
              "name": "SoulspireLauncher.exe",
              "browser_download_url": "https://example.com/SoulspireLauncher.exe",
              "size": 65000000
            }
          ]
        }
        """;

        var result = LauncherSelfUpdateService.ParseLatestReleaseJson(json, new Version(1, 0, 3, 0));

        Assert.True(result.UpdateAvailable);
        Assert.Equal("v1.0.4", result.LatestTag);
        Assert.Equal(new Version(1, 0, 4), result.LatestVersion);
        Assert.Equal("https://example.com/SoulspireLauncher.exe", result.DownloadUrl);
        Assert.Equal(65000000, result.ExpectedSize);
    }

    [Fact]
    public void ParseLatestReleaseJson_SkipsPrereleasesAndSameVersion()
    {
        const string prereleaseJson = """
        {
          "tag_name": "v2.0.0",
          "draft": false,
          "prerelease": true,
          "assets": [
            {
              "name": "SoulspireLauncher.exe",
              "browser_download_url": "https://example.com/SoulspireLauncher.exe",
              "size": 65000000
            }
          ]
        }
        """;

        var preResult = LauncherSelfUpdateService.ParseLatestReleaseJson(prereleaseJson, new Version(1, 0, 3, 0));
        Assert.False(preResult.UpdateAvailable);

        const string sameVersionJson = """
        {
          "tag_name": "v1.0.3",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "SoulspireLauncher.exe",
              "browser_download_url": "https://example.com/SoulspireLauncher.exe",
              "size": 65000000
            }
          ]
        }
        """;

        var sameResult = LauncherSelfUpdateService.ParseLatestReleaseJson(sameVersionJson, new Version(1, 0, 3, 0));
        Assert.False(sameResult.UpdateAvailable);
    }

    [Fact]
    public void BuildUpdaterBatchScript_WaitsForPidCopiesAndRestartsWithJustUpdatedFlag()
    {
        var script = LauncherSelfUpdateService.BuildUpdaterBatchScript(
            4242,
            @"C:\Temp\SoulspireLauncher-v1.0.4.exe",
            @"C:\Games\SoulspireXI\SoulspireLauncher.exe");

        Assert.Contains("TARGET_PID=4242", script);
        Assert.Contains(@"SRC=C:\Temp\SoulspireLauncher-v1.0.4.exe", script);
        Assert.Contains(@"DST=C:\Games\SoulspireXI\SoulspireLauncher.exe", script);
        Assert.Contains("copy /Y \"%SRC%\" \"%DST%\"", script);
        Assert.Contains($"start \"\" \"%DST%\" {LauncherSelfUpdateService.JustUpdatedArg}", script);
    }

    [Fact]
    public void BuildUpdaterBatchScript_MigratesLegacyOverlordsExeToSoulspireExe()
    {
        var script = LauncherSelfUpdateService.BuildUpdaterBatchScript(
            9999,
            @"C:\Temp\SoulspireLauncher-v2.1.0.exe",
            @"C:\Games\SoulspireXI\OverlordsLauncher.exe");

        Assert.Contains(@"DST=C:\Games\SoulspireXI\SoulspireLauncher.exe", script);
        Assert.DoesNotContain(@"DST=C:\Games\SoulspireXI\OverlordsLauncher.exe", script);
        Assert.Contains("if not exist \"%DST%\" goto cleanup", script);
    }

    [Fact]
    public void ParseReleaseListJson_IsolatesStableAndTestingChannels()
    {
        const string releasesJson = """
        [
          {
            "tag_name": "v2.1.0-testing.2",
            "html_url": "https://github.com/Infomatictek/soulspirexi-launcher/releases/tag/v2.1.0-testing.2",
            "draft": false,
            "prerelease": true,
            "assets": [
              { "name": "SoulspireLauncher.exe", "browser_download_url": "https://example.test/testing2/SoulspireLauncher.exe", "size": 65000000 }
            ]
          },
          {
            "tag_name": "v2.1.0-testing.1",
            "html_url": "https://github.com/Infomatictek/soulspirexi-launcher/releases/tag/v2.1.0-testing.1",
            "draft": false,
            "prerelease": true,
            "assets": [
              { "name": "SoulspireLauncher.exe", "browser_download_url": "https://example.test/testing1/SoulspireLauncher.exe", "size": 65000000 }
            ]
          },
          {
            "tag_name": "v2.0.1",
            "html_url": "https://github.com/Infomatictek/soulspirexi-launcher/releases/tag/v2.0.1",
            "draft": false,
            "prerelease": false,
            "assets": [
              { "name": "SoulspireLauncher.exe", "browser_download_url": "https://example.test/stable/SoulspireLauncher.exe", "size": 65000000 }
            ]
          }
        ]
        """;

        // Stable player on v2.0.1 must NOT be offered v2.1.0-testing.2
        var stableResult = LauncherSelfUpdateService.ParseReleaseListJson(
            releasesJson,
            new Version(2, 0, 1),
            UpdateChannel.Stable);
        Assert.False(stableResult.UpdateAvailable);

        // Testing player on v2.0.1 receives v2.1.0-testing.2
        var testingResult = LauncherSelfUpdateService.ParseReleaseListJson(
            releasesJson,
            new Version(2, 0, 1),
            UpdateChannel.Testing);
        Assert.True(testingResult.UpdateAvailable);
        Assert.Equal("v2.1.0-testing.2", testingResult.LatestTag);
        Assert.True(testingResult.IsPrerelease);
        Assert.EndsWith("testing2/SoulspireLauncher.exe", testingResult.DownloadUrl);

        // Testing player already on v2.1.0-testing.1 upgrades to v2.1.0-testing.2
        var testingStep = LauncherSelfUpdateService.ParseReleaseListJson(
            releasesJson,
            new Version(2, 1, 0),
            UpdateChannel.Testing,
            currentInformationalVersion: "2.1.0-testing.1");
        Assert.True(testingStep.UpdateAvailable);
        Assert.Equal("v2.1.0-testing.2", testingStep.LatestTag);
    }
}

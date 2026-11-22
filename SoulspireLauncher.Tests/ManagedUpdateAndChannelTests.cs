using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class ManagedUpdateAndChannelTests
{
    private sealed class StubHttpHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(responder(request));
    }

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    [Fact]
    public async Task SyncSoulspireFilesAsync_ChecksumMismatchAbortsWithoutModifyingLiveFiles()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_checksum_test_{Guid.NewGuid():N}");
        var ashitaDir = Path.Combine(tempRoot, "Ashita");
        var pluginDir = Path.Combine(ashitaDir, "plugins");
        Directory.CreateDirectory(pluginDir);

        try
        {
            var existingDll = Path.Combine(pluginDir, "crystaljobs.dll");
            var originalBytes = Encoding.UTF8.GetBytes("original-stable-dll");
            await File.WriteAllBytesAsync(existingDll, originalBytes);

            var expectedBytes = Encoding.UTF8.GetBytes("expected-new-dll");
            var corruptBytes = Encoding.UTF8.GetBytes("corrupted-payload");

            var manifest = new LauncherManifest
            {
                Channel = "stable",
                ManifestVersion = "2.1.0",
                Repo = new ManifestRepo { RawBaseUrl = "https://updates.soulspirexi.test" },
                Files =
                [
                    new ManifestFileEntry
                    {
                        Category = "plugin",
                        SourcePath = "plugins/ashita4/crystaljobs.dll",
                        TargetPath = "crystaljobs.dll",
                        Sha256 = Sha256(expectedBytes),
                        Size = expectedBytes.Length
                    }
                ]
            };

            var settings = LauncherSettings.CreateDefault(tempRoot);
            using var client = new HttpClient(new StubHttpHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(corruptBytes)
            }));
            var service = new ManifestUpdateService(client);

            await Assert.ThrowsAsync<InvalidDataException>(() =>
                service.SyncSoulspireFilesAsync(manifest, settings, forceAll: false));

            // Original live file MUST remain completely untouched
            Assert.Equal(originalBytes, await File.ReadAllBytesAsync(existingDll));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public async Task SyncSoulspireFilesAsync_RollsBackAllSwappedFilesOnMidBatchFailure()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_rollback_test_{Guid.NewGuid():N}");
        var ashitaDir = Path.Combine(tempRoot, "Ashita");
        var pluginDir = Path.Combine(ashitaDir, "plugins");
        var addonDir = Path.Combine(ashitaDir, "addons", "crystalsocket");
        Directory.CreateDirectory(pluginDir);
        Directory.CreateDirectory(addonDir);

        try
        {
            var addonFile = Path.Combine(addonDir, "weapon_config.lua");
            var dllFile = Path.Combine(pluginDir, "crystaljobs.dll");
            var newAddonFile = Path.Combine(addonDir, "new_feature.lua");

            var originalAddonBytes = Encoding.UTF8.GetBytes("-- original stable weapon_config");
            var originalDllBytes = Encoding.UTF8.GetBytes("original-24hook-dll");
            await File.WriteAllBytesAsync(addonFile, originalAddonBytes);
            await File.WriteAllBytesAsync(dllFile, originalDllBytes);

            var updatedAddonBytes = Encoding.UTF8.GetBytes("-- updated testing weapon_config");
            var updatedDllBytes = Encoding.UTF8.GetBytes("updated-27hook-dll");
            var newFileBytes = Encoding.UTF8.GetBytes("-- brand new testing file");

            var manifest = new LauncherManifest
            {
                Channel = "testing",
                ManifestVersion = "2.1.0-testing.1",
                Repo = new ManifestRepo { RawBaseUrl = "https://updates.soulspirexi.test" },
                Files =
                [
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        SourcePath = "channels/testing/payload/addons/ashita4/crystalsocket/weapon_config.lua",
                        TargetPath = "crystalsocket/weapon_config.lua",
                        Sha256 = Sha256(updatedAddonBytes),
                        Size = updatedAddonBytes.Length
                    },
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        SourcePath = "channels/testing/payload/addons/ashita4/crystalsocket/new_feature.lua",
                        TargetPath = "crystalsocket/new_feature.lua",
                        Sha256 = Sha256(newFileBytes),
                        Size = newFileBytes.Length
                    },
                    new ManifestFileEntry
                    {
                        Category = "plugin",
                        SourcePath = "channels/testing/payload/plugins/ashita4/crystaljobs.dll",
                        TargetPath = "crystaljobs.dll",
                        Sha256 = Sha256(updatedDllBytes),
                        Size = updatedDllBytes.Length
                    }
                ]
            };

            var settings = LauncherSettings.CreateDefault(tempRoot);
            using var client = new HttpClient(new StubHttpHandler(req =>
            {
                var path = req.RequestUri!.AbsolutePath;
                byte[] payload = path.EndsWith("weapon_config.lua") ? updatedAddonBytes
                    : path.EndsWith("new_feature.lua") ? newFileBytes
                    : updatedDllBytes;
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(payload)
                };
            }));
            var service = new ManifestUpdateService(client);

            // Simulate locked crystaljobs.dll on file #3 AFTER files #1 and #2 were swapped
            await Assert.ThrowsAsync<IOException>(() =>
                service.SyncSoulspireFilesAsync(
                    manifest,
                    settings,
                    forceAll: false,
                    beforeCommitFile: (entry, _) =>
                    {
                        if (entry.TargetPath.Equals("crystaljobs.dll", StringComparison.OrdinalIgnoreCase))
                        {
                            throw new IOException("Simulated file lock on crystaljobs.dll");
                        }
                    }));

            // File #1 must be restored to exact original bytes
            Assert.Equal(originalAddonBytes, await File.ReadAllBytesAsync(addonFile));
            // File #2 (newly created) must be deleted by rollback
            Assert.False(File.Exists(newAddonFile));
            // File #3 must remain untouched
            Assert.Equal(originalDllBytes, await File.ReadAllBytesAsync(dllFile));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public async Task SyncSoulspireFilesAsync_PreservesPlayerConfigsAndReconcilesChannelSwitch()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_channel_switch_{Guid.NewGuid():N}");
        var ashitaDir = Path.Combine(tempRoot, "Ashita");
        var playerSettingsDir = Path.Combine(ashitaDir, "addons", "crystalsocket", "settings");
        Directory.CreateDirectory(playerSettingsDir);

        try
        {
            var playerConfigPath = Path.Combine(playerSettingsDir, "settings.lua");
            var playerConfigBytes = Encoding.UTF8.GetBytes("-- player custom layout");
            await File.WriteAllBytesAsync(playerConfigPath, playerConfigBytes);

            var testingOnlyBytes = Encoding.UTF8.GetBytes("-- testing-only helper");
            var stableCoreBytes = Encoding.UTF8.GetBytes("-- stable core file");

            var testingManifest = new LauncherManifest
            {
                Channel = "testing",
                ManifestVersion = "2.1.0-testing.1",
                Repo = new ManifestRepo { RawBaseUrl = "https://updates.soulspirexi.test" },
                Files =
                [
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        SourcePath = "addons/ashita4/crystalsocket/core.lua",
                        TargetPath = "crystalsocket/core.lua",
                        Sha256 = Sha256(stableCoreBytes),
                        Size = stableCoreBytes.Length
                    },
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        SourcePath = "channels/testing/payload/addons/ashita4/crystalsocket/testing_only.lua",
                        TargetPath = "crystalsocket/testing_only.lua",
                        Sha256 = Sha256(testingOnlyBytes),
                        Size = testingOnlyBytes.Length
                    },
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        SourcePath = "addons/ashita4/crystalsocket/settings/settings.lua",
                        TargetPath = "crystalsocket/settings/settings.lua",
                        Sha256 = Sha256(Encoding.UTF8.GetBytes("-- should never overwrite")),
                        Size = 26
                    }
                ]
            };

            var stableManifest = new LauncherManifest
            {
                Channel = "stable",
                ManifestVersion = "2.1.0",
                Repo = new ManifestRepo { RawBaseUrl = "https://updates.soulspirexi.test" },
                Files =
                [
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        SourcePath = "addons/ashita4/crystalsocket/core.lua",
                        TargetPath = "crystalsocket/core.lua",
                        Sha256 = Sha256(stableCoreBytes),
                        Size = stableCoreBytes.Length
                    }
                ]
            };

            var settings = LauncherSettings.CreateDefault(tempRoot);
            settings.UpdateChannel = UpdateChannel.Testing;
            using var client = new HttpClient(new StubHttpHandler(req =>
            {
                var path = req.RequestUri!.AbsolutePath;
                var payload = path.EndsWith("testing_only.lua") ? testingOnlyBytes : stableCoreBytes;
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(payload)
                };
            }));
            var service = new ManifestUpdateService(client);

            // Sync Testing channel
            var syncedTesting = await service.SyncSoulspireFilesAsync(testingManifest, settings, forceAll: false);
            Assert.Equal(2, syncedTesting); // Protected settings.lua was skipped!
            Assert.True(File.Exists(Path.Combine(ashitaDir, "addons", "crystalsocket", "testing_only.lua")));
            Assert.Equal(playerConfigBytes, await File.ReadAllBytesAsync(playerConfigPath));

            // Switch back to Stable channel — testing_only.lua must be cleaned up, player config preserved
            settings.UpdateChannel = UpdateChannel.Stable;
            await service.SyncSoulspireFilesAsync(stableManifest, settings, forceAll: false);
            Assert.False(File.Exists(Path.Combine(ashitaDir, "addons", "crystalsocket", "testing_only.lua")));
            Assert.True(File.Exists(Path.Combine(ashitaDir, "addons", "crystalsocket", "core.lua")));
            Assert.Equal(playerConfigBytes, await File.ReadAllBytesAsync(playerConfigPath));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public void ChannelIsolation_StableRejectsTestingManifestAndResolvesDistinctPaths()
    {
        Assert.Equal("manifest.json", ManifestUpdateService.GetManifestRelativePath(UpdateChannel.Stable));
        Assert.Equal("channels/testing/manifest.json", ManifestUpdateService.GetManifestRelativePath(UpdateChannel.Testing));

        var testingManifest = new LauncherManifest
        {
            Channel = "testing",
            Files = [new ManifestFileEntry { Category = "addon", SourcePath = "a", TargetPath = "a", Sha256 = "0".PadLeft(64, '0') }]
        };

        Assert.False(ManifestUpdateService.IsValidManifestForChannel(testingManifest, UpdateChannel.Stable));
        Assert.True(ManifestUpdateService.IsValidManifestForChannel(testingManifest, UpdateChannel.Testing));
    }

    [Fact]
    public void ProtectedPlayerConfigGuard_ProtectsUserSettingsPaths()
    {
        Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("addon", "crystalsocket/settings/settings.lua"));
        Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("resource", "settings.json"));
        Assert.True(ManifestUpdateService.IsProtectedPlayerConfigPath("resource", "config/addons/metrics/settings.lua"));
        Assert.False(ManifestUpdateService.IsProtectedPlayerConfigPath("plugin", "crystaljobs.dll"));
        Assert.False(ManifestUpdateService.IsProtectedPlayerConfigPath("addon", "crystalsocket/weapon_config.lua"));
    }
}

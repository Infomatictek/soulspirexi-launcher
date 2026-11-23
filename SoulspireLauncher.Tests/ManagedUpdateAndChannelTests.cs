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
        Assert.Equal(
            "channels/testing-registry-24hook/manifest.json",
            ManifestUpdateService.GetManifestRelativePath(UpdateChannel.TestingRegistry24Hook));

        var fallback = new LauncherManifest();
        Assert.Equal("main", ManifestUpdateService.GetManifestBranch(fallback, UpdateChannel.Stable));
        Assert.Equal("main", ManifestUpdateService.GetManifestBranch(fallback, UpdateChannel.Testing));
        Assert.Equal(
            ManifestUpdateService.TestingRegistry24HookBranch,
            ManifestUpdateService.GetManifestBranch(fallback, UpdateChannel.TestingRegistry24Hook));

        var testingManifest = new LauncherManifest
        {
            Channel = "testing",
            Files = [new ManifestFileEntry { Category = "addon", SourcePath = "a", TargetPath = "a", Sha256 = "0".PadLeft(64, '0') }]
        };

        Assert.False(ManifestUpdateService.IsValidManifestForChannel(testingManifest, UpdateChannel.Stable));
        Assert.True(ManifestUpdateService.IsValidManifestForChannel(testingManifest, UpdateChannel.Testing));

        var dllSha = new string('d', 64);
        var registry24Candidate = new LauncherManifest
        {
            Channel = "testing",
            CandidateId = "registry-24hook",
            Registry = new ManifestRegistryMetadata
            {
                Version = "2026.11.22-phase2-locked",
                Hash = "de6314e97385e328",
                NativeDllCompiledHash = "de6314e97385e328",
                NativeDllSha256 = dllSha,
                NativeDllClientVerified = false,
                CrystalJobsHooks = 24
            },
            Files = [new ManifestFileEntry { Category = "plugin", SourcePath = "channels/testing-registry-24hook/payload/plugins/ashita4/crystaljobs.dll", TargetPath = "crystaljobs.dll", Sha256 = dllSha }]
        };

        Assert.False(ManifestUpdateService.IsValidManifestForChannel(registry24Candidate, UpdateChannel.Stable));
        Assert.False(ManifestUpdateService.IsValidManifestForChannel(registry24Candidate, UpdateChannel.Testing));
        Assert.True(ManifestUpdateService.IsValidManifestForChannel(registry24Candidate, UpdateChannel.TestingRegistry24Hook));
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

    [Fact]
    public void RegistryBundleValidation_BlocksUnverifiedStableDllAndMismatchedDllSha()
    {
        var dllSha = new string('a', 64);
        var unverifiedStable = new LauncherManifest
        {
            Channel = "stable",
            Registry = new ManifestRegistryMetadata
            {
                Version = "2026.11.22-phase2-locked",
                Hash = "de6314e97385e328",
                NativeDllCompiledHash = "de6314e97385e328",
                NativeDllSha256 = dllSha,
                NativeDllClientVerified = false,
                CrystalJobsHooks = 24
            },
            Files = [new ManifestFileEntry { Category = "plugin", SourcePath = "plugins/ashita4/crystaljobs.dll", TargetPath = "crystaljobs.dll", Sha256 = dllSha }]
        };

        // Stable must reject unverified new registry DLL; Testing may install it for validation.
        Assert.False(ManifestUpdateService.IsValidManifestForChannel(unverifiedStable, UpdateChannel.Stable));
        Assert.True(ManifestUpdateService.ValidateRegistryBundle(unverifiedStable, UpdateChannel.Testing, out _));

        // Once client-verified, Stable accepts it.
        unverifiedStable.Registry.NativeDllClientVerified = true;
        Assert.True(ManifestUpdateService.IsValidManifestForChannel(unverifiedStable, UpdateChannel.Stable));

        // Mismatched DLL SHA-256 must always be rejected on both channels.
        unverifiedStable.Registry.NativeDllSha256 = new string('b', 64);
        Assert.False(ManifestUpdateService.ValidateRegistryBundle(unverifiedStable, UpdateChannel.Stable, out _));
        Assert.False(ManifestUpdateService.ValidateRegistryBundle(unverifiedStable, UpdateChannel.Testing, out _));
    }

    [Fact]
    public void PreFlightLockCheck_RejectsLockedDllWithoutModifyingExistingFiles()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_locktest_{Guid.NewGuid():N}");
        try
        {
            var ashitaDir = Path.Combine(tempRoot, "Ashita");
            var pluginDir = Path.Combine(ashitaDir, "plugins");
            Directory.CreateDirectory(pluginDir);
            var dllPath = Path.Combine(pluginDir, "crystaljobs.dll");
            File.WriteAllText(dllPath, "OLD_DLL_CONTENT");

            var settings = new LauncherSettings { AshitaPath = ashitaDir };
            var pending = new[]
            {
                new ManifestFileEntry { Category = "plugin", TargetPath = "crystaljobs.dll", Sha256 = new string('c', 64) }
            };

            using (var lockStream = new FileStream(dllPath, FileMode.Open, FileAccess.Read, FileShare.None))
            {
                var ex = Assert.Throws<IOException>(() => ManifestUpdateService.EnsureTargetFilesWritable(pending, settings));
                Assert.Contains("locked", ex.Message, StringComparison.OrdinalIgnoreCase);
            }

            Assert.Equal("OLD_DLL_CONTENT", File.ReadAllText(dllPath));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public async Task FetchManifestDetailedAsync_Testing404NeverFallsBackToStable()
    {
        var handler = new StubHttpHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound)
        {
            ReasonPhrase = "Not Found"
        });
        var service = new ManifestUpdateService(new HttpClient(handler));
        var bundledStable = new LauncherManifest
        {
            Channel = "stable",
            ManifestVersion = "2.1.0",
            Repo = new ManifestRepo
            {
                Owner = "Infomatictek",
                Name = "soulspirexi-launcher",
                Branch = "main",
                RawBaseUrl = "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/main"
            },
            Files = [new ManifestFileEntry { Category = "plugin", SourcePath = "plugins/ashita4/crystaljobs.dll", TargetPath = "crystaljobs.dll", Sha256 = new string('a', 64) }]
        };

        var result = await service.FetchManifestDetailedAsync(bundledStable, localOverride: null, UpdateChannel.Testing);

        Assert.Null(result.Manifest);
        Assert.False(result.FromRemote);
        Assert.False(result.UsedBundledFallback);
        Assert.Equal(404, result.HttpStatusCode);
        Assert.NotNull(result.ErrorMessage);
        Assert.Contains("404", result.ErrorMessage);
        Assert.Contains("channels/testing/manifest.json", result.RequestedUrl);
    }

    [Fact]
    public async Task FetchManifestDetailedAsync_Stable503FallsBackToBundledStable()
    {
        var handler = new StubHttpHandler(_ => new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
        {
            ReasonPhrase = "Service Unavailable"
        });
        var service = new ManifestUpdateService(new HttpClient(handler));
        var bundledStable = new LauncherManifest
        {
            Channel = "stable",
            ManifestVersion = "2.1.0",
            Repo = new ManifestRepo
            {
                Owner = "Infomatictek",
                Name = "soulspirexi-launcher",
                Branch = "main",
                RawBaseUrl = "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/main"
            },
            Files = [new ManifestFileEntry { Category = "plugin", SourcePath = "plugins/ashita4/crystaljobs.dll", TargetPath = "crystaljobs.dll", Sha256 = new string('a', 64) }]
        };

        var result = await service.FetchManifestDetailedAsync(bundledStable, localOverride: null, UpdateChannel.Stable);

        Assert.NotNull(result.Manifest);
        Assert.Equal("stable", result.Manifest!.Channel);
        Assert.False(result.FromRemote);
        Assert.True(result.UsedBundledFallback);
        Assert.Equal(503, result.HttpStatusCode);
    }

    [Fact]
    public async Task FetchManifestDetailedAsync_RejectsIncorrectChannelMetadataAndInvalidJson()
    {
        var bundledStable = new LauncherManifest
        {
            Channel = "stable",
            ManifestVersion = "2.1.0",
            Repo = new ManifestRepo { RawBaseUrl = "https://updates.soulspirexi.test" },
            Files = [new ManifestFileEntry { Category = "plugin", SourcePath = "a", TargetPath = "a", Sha256 = new string('a', 64) }]
        };

        // 1. Testing endpoint returning channel="stable" must be rejected and never shown as Testing.
        var stableJson = """
            {"schemaVersion":1,"channel":"stable","manifestVersion":"2.1.0","files":[{"category":"plugin","sourcePath":"a","targetPath":"a","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":10}]}
            """;
        var svcWrongChannel = new ManifestUpdateService(new HttpClient(new StubHttpHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(stableJson, Encoding.UTF8, "application/json") })));
        var resWrong = await svcWrongChannel.FetchManifestDetailedAsync(bundledStable, null, UpdateChannel.Testing);
        Assert.Null(resWrong.Manifest);
        Assert.False(resWrong.UsedBundledFallback);
        Assert.Contains("Expected channel 'testing'", resWrong.ErrorMessage);

        // 2. Registry Testing endpoint returning wrong candidateId must be rejected.
        var wrongCandidateJson = """
            {"schemaVersion":1,"channel":"testing","candidateId":"default-27hook","manifestVersion":"2.1.0-testing.1","files":[{"category":"plugin","sourcePath":"a","targetPath":"a","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":10}]}
            """;
        var svcWrongCand = new ManifestUpdateService(new HttpClient(new StubHttpHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(wrongCandidateJson, Encoding.UTF8, "application/json") })));
        var resWrongCand = await svcWrongCand.FetchManifestDetailedAsync(bundledStable, null, UpdateChannel.TestingRegistry24Hook);
        Assert.Null(resWrongCand.Manifest);
        Assert.Contains("registry-24hook", resWrongCand.ErrorMessage);

        // 3. Invalid JSON on Testing channel must surface parse error and never fall back to Stable.
        var svcBadJson = new ManifestUpdateService(new HttpClient(new StubHttpHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{not-valid-json", Encoding.UTF8, "application/json") })));
        var resBadJson = await svcBadJson.FetchManifestDetailedAsync(bundledStable, null, UpdateChannel.TestingRegistry24Hook);
        Assert.Null(resBadJson.Manifest);
        Assert.Contains("Invalid manifest JSON", resBadJson.ErrorMessage);
    }

    [Fact]
    public async Task FetchManifestDetailedAsync_RegistryTestingResolvesFeatureBranchAndHash()
    {
        var requestedUrls = new List<string>();
        var dllSha = new string('d', 64);
        var validRegJson = $$"""
            {
              "schemaVersion": 1,
              "channel": "testing",
              "candidateId": "registry-24hook",
              "manifestVersion": "2.1.1-testing.registry24",
              "repo": {
                "owner": "Infomatictek",
                "name": "soulspirexi-launcher",
                "branch": "fix/native-search-label-and-testing-candidate",
                "rawBaseUrl": "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/fix/native-search-label-and-testing-candidate"
              },
              "registry": {
                "version": "2026.11.22-phase2-locked",
                "hash": "de6314e97385e328",
                "nativeDllCompiledHash": "de6314e97385e328",
                "nativeDllSha256": "{{dllSha}}",
                "nativeDllClientVerified": false,
                "crystalJobsHooks": 24
              },
              "files": [
                {
                  "category": "plugin",
                  "sourcePath": "channels/testing-registry-24hook/payload/plugins/ashita4/crystaljobs.dll",
                  "targetPath": "crystaljobs.dll",
                  "sha256": "{{dllSha}}",
                  "size": 130560
                }
              ]
            }
            """;

        var handler = new StubHttpHandler(req =>
        {
            var url = req.RequestUri!.ToString();
            requestedUrls.Add(url);
            if (url.Contains("/commits/"))
            {
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }

            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(validRegJson, Encoding.UTF8, "application/json")
            };
        });

        var service = new ManifestUpdateService(new HttpClient(handler));
        var bundledStable = new LauncherManifest
        {
            Channel = "stable",
            ManifestVersion = "2.1.0",
            Repo = new ManifestRepo
            {
                Owner = "Infomatictek",
                Name = "soulspirexi-launcher",
                Branch = "main",
                RawBaseUrl = "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/main"
            },
            Files = [new ManifestFileEntry { Category = "plugin", SourcePath = "plugins/ashita4/crystaljobs.dll", TargetPath = "crystaljobs.dll", Sha256 = new string('a', 64) }]
        };

        var result = await service.FetchManifestDetailedAsync(bundledStable, null, UpdateChannel.TestingRegistry24Hook);

        Assert.True(result.FromRemote);
        Assert.False(result.UsedBundledFallback);
        Assert.NotNull(result.Manifest);
        Assert.Equal("registry-24hook", result.Manifest!.CandidateId);
        Assert.Equal("de6314e97385e328", result.Manifest.Registry?.Hash);
        Assert.Contains(requestedUrls, u => u.Contains($"{ManifestUpdateService.TestingRegistry24HookBranch}/channels/testing-registry-24hook/manifest.json"));
    }

    [Fact]
    public void PopulateNativeDllDiagnostics_ReportsPassFailUnknownWithoutModifyingDll()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_diag_{Guid.NewGuid():N}");
        try
        {
            var ashitaDir = Path.Combine(tempRoot, "Ashita");
            var pluginDir = Path.Combine(ashitaDir, "plugins");
            Directory.CreateDirectory(pluginDir);

            // Synthetic minimal PE32 x86 (MZ + e_lfanew=0x40 + PE\0\0 + Machine=0x014C)
            var peBytes = new byte[128];
            peBytes[0] = 0x4D; peBytes[1] = 0x5A; // MZ
            BitConverter.GetBytes(0x40).CopyTo(peBytes, 0x3C);
            peBytes[0x40] = (byte)'P'; peBytes[0x41] = (byte)'E';
            BitConverter.GetBytes((ushort)0x014C).CopyTo(peBytes, 0x44); // x86

            var dllPath = Path.Combine(pluginDir, "crystaljobs.dll");
            File.WriteAllBytes(dllPath, peBytes);
            var peSha = Sha256(peBytes);

            var settings = new LauncherSettings
            {
                AshitaPath = ashitaDir,
                UpdateChannel = UpdateChannel.TestingRegistry24Hook
            };
            var manifest = new LauncherManifest
            {
                Channel = "testing",
                CandidateId = "registry-24hook",
                Registry = new ManifestRegistryMetadata
                {
                    Hash = "de6314e97385e328",
                    NativeDllCompiledHash = "de6314e97385e328",
                    NativeDllSha256 = peSha,
                    CrystalJobsHooks = 24
                },
                Files =
                [
                    new ManifestFileEntry
                    {
                        Category = "plugin",
                        SourcePath = "channels/testing-registry-24hook/payload/plugins/ashita4/crystaljobs.dll",
                        TargetPath = "crystaljobs.dll",
                        Sha256 = peSha
                    }
                ]
            };

            // PASS case (matching SHA-256 + PE32 x86, process inspection skipped -> UNKNOWN)
            var diagPass = new InstallDiagnostics();
            FfxiInstallDetector.PopulateNativeDllDiagnostics(diagPass, settings, manifest, inspectRunningProcess: false);
            Assert.Equal("PASS", diagPass.NativeDllSha256Status);
            Assert.Equal("PASS", diagPass.NativeDllArchitectureStatus);
            Assert.Equal("de6314e97385e328", diagPass.NativeRegistryCompiledHash);
            Assert.Equal("24", diagPass.NativeHookCount);
            Assert.Equal("UNKNOWN", diagPass.NativeLoadedModuleStatus);
            Assert.Equal(peBytes, File.ReadAllBytes(dllPath)); // Strictly read-only

            // FAIL case (mismatched expected SHA-256)
            manifest.Files[0].Sha256 = new string('f', 64);
            var diagFail = new InstallDiagnostics();
            FfxiInstallDetector.PopulateNativeDllDiagnostics(diagFail, settings, manifest, inspectRunningProcess: false);
            Assert.Equal("FAIL", diagFail.NativeDllSha256Status);

            // UNKNOWN expected SHA case
            var diagUnknown = new InstallDiagnostics();
            FfxiInstallDetector.PopulateNativeDllDiagnostics(diagUnknown, settings, manifest: null, inspectRunningProcess: false);
            Assert.Equal("UNKNOWN", diagUnknown.NativeDllSha256Status);
            Assert.Equal("UNKNOWN", diagUnknown.NativeExpectedDllSha256);
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public void RemoveRetiredPlugins_CleansUpObsoleteCrystalJobsWhenSoulspireNativeActive()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_mig_{Guid.NewGuid():N}");
        try
        {
            var ashitaDir = Path.Combine(tempRoot, "Ashita");
            var pluginDir = Path.Combine(ashitaDir, "plugins");
            var dataDir = Path.Combine(pluginDir, "data");
            Directory.CreateDirectory(dataDir);

            var legacyDll = Path.Combine(pluginDir, "crystaljobs.dll");
            var legacyPres = Path.Combine(dataDir, "crystaljobs-presentation.json");
            var nativeDll = Path.Combine(pluginDir, "soulspire_native.dll");
            var nativeCfg = Path.Combine(dataDir, "soulspire_native.json");
            File.WriteAllText(legacyDll, "LEGACY");
            File.WriteAllText(legacyPres, "{}");
            File.WriteAllText(nativeDll, "NATIVE");
            File.WriteAllText(nativeCfg, "{}");

            var settings = new LauncherSettings { AshitaPath = ashitaDir };
            var manifest = new LauncherManifest
            {
                Channel = "stable",
                Files =
                [
                    new ManifestFileEntry { Category = "plugin", SourcePath = "plugins/ashita4/soulspire_native.dll", TargetPath = "soulspire_native.dll", Sha256 = new string('a', 64) },
                    new ManifestFileEntry { Category = "plugin", SourcePath = "plugins/ashita4/data/soulspire_native.json", TargetPath = "data/soulspire_native.json", Sha256 = new string('b', 64) },
                ]
            };

            var removed = ManifestUpdateService.RemoveRetiredPlugins(manifest, settings);

            Assert.Equal(2, removed);
            Assert.False(File.Exists(legacyDll));
            Assert.False(File.Exists(legacyPres));
            Assert.True(File.Exists(nativeDll));
            Assert.True(File.Exists(nativeCfg));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }
}

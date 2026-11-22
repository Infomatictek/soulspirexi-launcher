using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Text;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class ManifestTests
{
    [Fact]
    public void LoadEmbeddedManifest_ContainsExpectedFilesAndDefaults()
    {
        var service = new ManifestUpdateService();
        var manifest = service.LoadEmbeddedManifest();

        Assert.Equal("SoulspireXI", manifest.ServerName);
        Assert.Equal("Infomatictek", manifest.Repo.Owner);
        Assert.Equal("soulspirexi-launcher", manifest.Repo.Name);
        Assert.True(manifest.Files.Count >= 5);
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "soulspire_talents/soulspire_talents.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "crystalsocket/crystalsocket.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "crystalsocket/job_labels.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "plugin" &&
            f.TargetPath == "crystaljobs.dll" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "crystalsocket/assets/sensei.png" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "soulspire_gear/soulspire_gear.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "soulspire_gear/data/items.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "metrics/soulspire.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "metrics/metrics.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "metrics/resources/abilities.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "metrics/resources/weapon_skills.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "metrics/windows/!window.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "soulspire_soul_actions/soulspire_soul_actions.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "soulspire_soul_actions/catalog.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "soulspire_soul_actions/presentation.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "addon" &&
            f.TargetPath == "soulspire_soul_actions/profiles.lua" &&
            !string.IsNullOrWhiteSpace(f.Sha256));
        Assert.Contains(manifest.Files, f =>
            f.Category == "dat" &&
            f.TargetPath == "ROM/118/108.DAT" &&
            !string.IsNullOrWhiteSpace(f.Sha256));

        var flintlockOverlay = Assert.Single(manifest.OptionalOverlays, o => o.Id == AshitaConfigGenerator.FlintlockOverlayId);
        Assert.False(flintlockOverlay.DefaultEnabled);
        Assert.Equal("flintlock-akimbo-compact", flintlockOverlay.OverlayFolder);
        Assert.Equal(278, flintlockOverlay.Files.Count);
        Assert.NotNull(flintlockOverlay.SoulGate);
        Assert.Equal(17, flintlockOverlay.SoulGate!.Job);
        Assert.Equal(1, flintlockOverlay.SoulGate.Branch);
        Assert.Equal("flintlock", flintlockOverlay.SoulGate.Soul);
    }

    [Fact]
    public void OptionalFlintlockOverlay_IsSkippedByDefaultAndRoutesToDedicatedFolderWhenEnabled()
    {
        var settings = new LauncherSettings
        {
            AshitaPath = Path.Combine("C:", "Games", "Ashita"),
            EnablePivotOverlay = true,
            EnableFlintlockDualPistolsOverlay = false
        };
        var manifest = new ManifestUpdateService().LoadEmbeddedManifest();

        var activeDefault = ManifestUpdateService.EnumerateActiveFiles(manifest, settings).ToList();
        Assert.DoesNotContain(activeDefault, f => f.Category == "dat-optional");

        settings.EnableFlintlockDualPistolsOverlay = true;
        var activeOptIn = ManifestUpdateService.EnumerateActiveFiles(manifest, settings).ToList();
        var optionalFiles = activeOptIn.Where(f => f.Category == "dat-optional").ToList();
        Assert.Equal(278, optionalFiles.Count);

        var sample = optionalFiles[0];
        var resolved = ManifestUpdateService.ResolveTargetFilePath(settings, sample);
        Assert.StartsWith(
            Path.Combine("C:", "Games", "Ashita", "polplugins", "DATs", "flintlock-akimbo-compact", "ROM") + Path.DirectorySeparatorChar,
            resolved,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SoulActionsAddon_InstallsUpdatesAndAutoLoadsInBootScript()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_soul_actions_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempRoot);

        try
        {
            var settings = new LauncherSettings
            {
                AshitaPath = tempRoot
            };
            var service = new ManifestUpdateService();
            var manifest = service.LoadEmbeddedManifest();

            var soulActionFiles = manifest.Files
                .Where(f => f.Category == "addon" && f.TargetPath.StartsWith("soulspire_soul_actions/", StringComparison.Ordinal))
                .ToList();
            Assert.Contains(soulActionFiles, f => f.TargetPath == "soulspire_soul_actions/soulspire_soul_actions.lua");
            Assert.Contains(soulActionFiles, f => f.TargetPath == "soulspire_soul_actions/catalog.lua");
            Assert.Contains(soulActionFiles, f => f.TargetPath == "soulspire_soul_actions/presentation.lua");
            Assert.Contains(soulActionFiles, f => f.TargetPath == "soulspire_soul_actions/profiles.lua");

            var subset = new LauncherManifest { Files = soulActionFiles };

            // Fresh install: all Soul Actions files should be detected as missing/outdated.
            var missing = service.GetOutdatedFiles(subset, settings);
            Assert.Equal(soulActionFiles.Count, missing.Count);

            // Verify target routing resolves to <ashita>/addons/soulspire_soul_actions/...
            var repoRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
            foreach (var entry in soulActionFiles)
            {
                var dest = ManifestUpdateService.ResolveTargetFilePath(settings, entry);
                Assert.StartsWith(
                    Path.Combine(tempRoot, "addons", "soulspire_soul_actions") + Path.DirectorySeparatorChar,
                    dest,
                    StringComparison.OrdinalIgnoreCase);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(Path.Combine(repoRoot, entry.SourcePath.Replace('/', Path.DirectorySeparatorChar)), dest, overwrite: true);
            }

            // Up-to-date after install.
            Assert.Empty(service.GetOutdatedFiles(subset, settings));

            // Modifying an installed addon file triggers an update.
            var mainAddon = Path.Combine(tempRoot, "addons", "soulspire_soul_actions", "soulspire_soul_actions.lua");
            File.AppendAllText(mainAddon, "\n-- modified\n");
            var outdated = service.GetOutdatedFiles(subset, settings);
            Assert.Single(outdated);
            Assert.Equal("soulspire_soul_actions/soulspire_soul_actions.lua", outdated[0].TargetPath);

            // Addon is auto-loaded at startup in soulspirexi.txt without duplicating on re-merge.
            var generator = new AshitaConfigGenerator();
            var bootScript = generator.MergeBootScriptContent(null, settings);
            Assert.Contains("/addon load soulspire_soul_actions", bootScript, StringComparison.OrdinalIgnoreCase);

            var remerged = generator.MergeBootScriptContent(bootScript, settings);
            var loadLines = remerged
                .Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
                .Count(line => line.Trim().Equals("/addon load soulspire_soul_actions", StringComparison.OrdinalIgnoreCase));
            Assert.Equal(1, loadLines);
        }
        finally
        {
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }

    [Fact]
    public void ApplyLocalOverride_UpdatesProvidedFieldsAndPreservesOthers()
    {
        var manifest = new LauncherManifest
        {
            ServerName = "SoulspireXI",
            DefaultHost = "127.0.0.1",
            UseHairpin = false,
            Ports = new ManifestPorts { Lobby = 54231, Auth = 54001, Search = 54002 }
        };

        var localOverride = new LocalServerOverride
        {
            ServerName = " SoulspireXI Live ",
            DefaultHost = " play.soulspirexi.net ",
            UseHairpin = true,
            LobbyPort = 54235
        };

        ManifestUpdateService.ApplyLocalOverride(manifest, localOverride);

        Assert.Equal("SoulspireXI Live", manifest.ServerName);
        Assert.Equal("play.soulspirexi.net", manifest.DefaultHost);
        Assert.True(manifest.UseHairpin);
        Assert.Equal(54235, manifest.Ports.Lobby);
        Assert.Equal(54001, manifest.Ports.Auth);
        Assert.Equal(54002, manifest.Ports.Search);
    }

    [Fact]
    public void ResolveTargetFilePath_RoutesDatAndAddonCategoriesCorrectly()
    {
        var settings = new LauncherSettings
        {
            AshitaPath = Path.Combine("C:", "Games", "Ashita")
        };

        var datEntry = new ManifestFileEntry
        {
            Category = "dat",
            TargetPath = "ROM/118/108.DAT"
        };
        var addonEntry = new ManifestFileEntry
        {
            Category = "addon",
            TargetPath = "soulspire_talents/soulspire_talents.lua"
        };

        var datDest = ManifestUpdateService.ResolveTargetFilePath(settings, datEntry);
        var addonDest = ManifestUpdateService.ResolveTargetFilePath(settings, addonEntry);

        Assert.Equal(
            Path.Combine("C:", "Games", "Ashita", "polplugins", "DATs", "soulspirexi", "ROM", "118", "108.DAT"),
            datDest);
        Assert.Equal(
            Path.Combine("C:", "Games", "Ashita", "addons", "soulspire_talents", "soulspire_talents.lua"),
            addonDest);
    }

    [Fact]
    public void FileMatchesHash_And_GetOutdatedFiles_DetectMissingAndModifiedFiles()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"overlords_launcher_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempRoot);

        try
        {
            var settings = new LauncherSettings
            {
                AshitaPath = tempRoot
            };

            var sampleFile = Path.Combine(tempRoot, "addons", "soulspire_talents", "soulspire_talents.lua");
            Directory.CreateDirectory(Path.GetDirectoryName(sampleFile)!);
            File.WriteAllText(sampleFile, "-- overlords test", Encoding.UTF8);

            var expectedHash = ManifestUpdateService.ComputeSha256(sampleFile);
            Assert.True(ManifestUpdateService.FileMatchesHash(sampleFile, expectedHash));
            Assert.False(ManifestUpdateService.FileMatchesHash(sampleFile, "0000000000000000"));

            var manifest = new LauncherManifest
            {
                Files =
                [
                    new ManifestFileEntry
                    {
                        Category = "addon",
                        TargetPath = "soulspire_talents/soulspire_talents.lua",
                        Sha256 = expectedHash
                    },
                    new ManifestFileEntry
                    {
                        Category = "dat",
                        TargetPath = "ROM/118/108.DAT",
                        Sha256 = "deadbeef"
                    }
                ]
            };

            var service = new ManifestUpdateService();
            var outdated = service.GetOutdatedFiles(manifest, settings, forceAll: false);
            Assert.Single(outdated);
            Assert.Equal("ROM/118/108.DAT", outdated[0].TargetPath);

            var forced = service.GetOutdatedFiles(manifest, settings, forceAll: true);
            Assert.Equal(2, forced.Count);
        }
        finally
        {
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }

    [Fact]
    public void ExtractMetricsZipToDirectory_HandlesFlatAndNestedArchives()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"overlords_metrics_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempRoot);

        try
        {
            var zipPath = Path.Combine(tempRoot, "metrics.zip");
            using (var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create))
            {
                var mainEntry = archive.CreateEntry("metrics/metrics.lua");
                using (var writer = new StreamWriter(mainEntry.Open()))
                {
                    writer.Write("-- metrics entry");
                }

                var subEntry = archive.CreateEntry("metrics/modules/parse/_parse.lua");
                using (var writer = new StreamWriter(subEntry.Open()))
                {
                    writer.Write("-- parse module");
                }
            }

            var targetDir = Path.Combine(tempRoot, "addons", "metrics");
            ManifestUpdateService.ExtractMetricsZipToDirectory(zipPath, targetDir);

            Assert.True(File.Exists(Path.Combine(targetDir, "metrics.lua")));
            Assert.True(File.Exists(Path.Combine(targetDir, "modules", "parse", "_parse.lua")));

            var embedded = new ManifestUpdateService().LoadEmbeddedManifest();
            Assert.Contains("RaraProjects/metrics", embedded.Bootstrap.MetricsLatestApiUrl);
            Assert.Contains("ThornyFFXI/mobdb", embedded.Bootstrap.MobDbLatestApiUrl);
            Assert.Contains("kazenohito/kazenoeye", embedded.Bootstrap.KazenoeyeLatestApiUrl);
        }
        finally
        {
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }

    [Fact]
    public void ExtractAddonZipToDirectory_HandlesMobDbAndKazenoeyeArchiveLayouts()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"overlords_qol_addons_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempRoot);

        try
        {
            // Layout 1: mobdb release zip (addons/mobdb/...)
            var mobdbZip = Path.Combine(tempRoot, "mobdb.zip");
            using (var archive = ZipFile.Open(mobdbZip, ZipArchiveMode.Create))
            {
                using (var writer = new StreamWriter(archive.CreateEntry("addons/mobdb/mobdb.lua").Open()))
                {
                    writer.Write("-- mobdb entry");
                }

                using (var writer = new StreamWriter(archive.CreateEntry("addons/mobdb/data/1.lua").Open()))
                {
                    writer.Write("-- zone 1");
                }
            }

            var mobdbDir = Path.Combine(tempRoot, "addons", "mobdb");
            ManifestUpdateService.ExtractAddonZipToDirectory(mobdbZip, mobdbDir, "mobdb.lua");
            Assert.True(File.Exists(Path.Combine(mobdbDir, "mobdb.lua")));
            Assert.True(File.Exists(Path.Combine(mobdbDir, "data", "1.lua")));

            // Layout 2: GitHub zipball archive (kazenohito-kazenoeye-sha/...)
            var kazenoeyeZip = Path.Combine(tempRoot, "kazenoeye.zip");
            using (var archive = ZipFile.Open(kazenoeyeZip, ZipArchiveMode.Create))
            {
                using (var writer = new StreamWriter(archive.CreateEntry("kazenohito-kazenoeye-abc123/kazenoeye.lua").Open()))
                {
                    writer.Write("-- kazenoeye entry");
                }

                using (var writer = new StreamWriter(archive.CreateEntry("kazenohito-kazenoeye-abc123/util/debuffhandler.lua").Open()))
                {
                    writer.Write("-- debuff handler");
                }
            }

            var kazenoeyeDir = Path.Combine(tempRoot, "addons", "kazenoeye");
            ManifestUpdateService.ExtractAddonZipToDirectory(kazenoeyeZip, kazenoeyeDir, "kazenoeye.lua");
            Assert.True(File.Exists(Path.Combine(kazenoeyeDir, "kazenoeye.lua")));
            Assert.True(File.Exists(Path.Combine(kazenoeyeDir, "util", "debuffhandler.lua")));
        }
        finally
        {
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }

    [Fact]
    public void EmbeddedManifest_ContainsKazenoeyeServerSyncOverlayFiles()
    {
        var embedded = new ManifestUpdateService().LoadEmbeddedManifest();

        Assert.Contains(embedded.Files, f => f.Category == "addon" && f.TargetPath == "kazenoeye/util/debuffhandler.lua");
        Assert.Contains(embedded.Files, f => f.Category == "addon" && f.TargetPath == "kazenoeye/mobhud.lua");
        Assert.Contains(embedded.Files, f => f.Category == "addon" && f.TargetPath == "kazenoeye/setting.lua");
        Assert.Contains(embedded.Files, f => f.Category == "addon" && f.TargetPath == "kazenoeye/util/texture.lua");
        Assert.Contains(embedded.Files, f => f.Category == "addon" && f.TargetPath == "kazenoeye/util/hidestatus.lua");
    }

    [Fact]
    public async Task FetchManifestAsync_PinsDownloadsToCommitShaAndRetriesTransientMismatch()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"overlords_manifest_pin_test_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempRoot);

        try
        {
            const string commitSha = "0123456789abcdef0123456789abcdef01234567";
            var payloadBytes = Encoding.UTF8.GetBytes("-- pinned talents lua\n");
            var payloadHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(payloadBytes)).ToLowerInvariant();
            var manifestJson = $$"""
            {
              "schemaVersion": 1,
              "serverName": "SoulspireXI",
              "repo": {
                "owner": "Infomatictek",
                "name": "soulspirexi-launcher",
                "branch": "main",
                "rawBaseUrl": "https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/main"
              },
              "files": [
                {
                  "category": "addon",
                  "sourcePath": "addons/ashita4/soulspire_talents/soulspire_talents.lua",
                  "targetPath": "soulspire_talents/soulspire_talents.lua",
                  "sha256": "{{payloadHash}}",
                  "size": {{payloadBytes.Length}}
                }
              ]
            }
            """;

            var fileAttempts = 0;
            var requestedUrls = new List<string>();
            using var handler = new StubHttpMessageHandler(req =>
            {
                var url = req.RequestUri!.ToString();
                requestedUrls.Add(url);

                if (url.Contains("/commits/main", StringComparison.OrdinalIgnoreCase))
                {
                    return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
                    {
                        Content = new StringContent(commitSha)
                    };
                }

                if (url.Contains($"/{commitSha}/manifest.json", StringComparison.OrdinalIgnoreCase))
                {
                    return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
                    {
                        Content = new StringContent(manifestJson, Encoding.UTF8, "application/json")
                    };
                }

                if (url.Contains($"/{commitSha}/addons/ashita4/soulspire_talents/soulspire_talents.lua", StringComparison.OrdinalIgnoreCase))
                {
                    fileAttempts++;
                    var content = fileAttempts == 1
                        ? Encoding.UTF8.GetBytes("-- stale attempt\n")
                        : payloadBytes;
                    return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
                    {
                        Content = new ByteArrayContent(content)
                    };
                }

                return new HttpResponseMessage(System.Net.HttpStatusCode.NotFound);
            });

            using var http = new HttpClient(handler);
            var service = new ManifestUpdateService(http);
            var fallback = new LauncherManifest();
            var (manifest, fromRemote) = await service.FetchManifestAsync(fallback, localOverride: null);

            Assert.True(fromRemote);
            Assert.Equal($"https://raw.githubusercontent.com/Infomatictek/soulspirexi-launcher/{commitSha}", manifest.ResolvedRawBaseUrl);

            var settings = new LauncherSettings { AshitaPath = Path.Combine(tempRoot, "Ashita") };
            var synced = await service.SyncSoulspireFilesAsync(manifest, settings, forceAll: false);

            Assert.Equal(1, synced);
            Assert.Equal(2, fileAttempts);
            Assert.True(File.Exists(Path.Combine(settings.AshitaPath, "addons", "soulspire_talents", "soulspire_talents.lua")));
        }
        finally
        {
            if (Directory.Exists(tempRoot))
            {
                Directory.Delete(tempRoot, recursive: true);
            }
        }
    }

    private sealed class StubHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(responder(request));
    }
}

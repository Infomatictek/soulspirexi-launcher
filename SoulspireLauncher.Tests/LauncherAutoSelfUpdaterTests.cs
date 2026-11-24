using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class LauncherAutoSelfUpdaterTests
{
    private static byte[] CreateSyntheticPeBytes(string marker, int size = 4096)
    {
        var bytes = new byte[Math.Max(size, 64)];
        bytes[0] = (byte)'M';
        bytes[1] = (byte)'Z';
        var tag = Encoding.ASCII.GetBytes(marker);
        Array.Copy(tag, 0, bytes, 4, Math.Min(tag.Length, bytes.Length - 4));
        return bytes;
    }

    private static (string ZipPath, string ZipSha, long ZipSize, string ExeSha, string UpdaterSha) CreateSignedReleaseZip(
        string workDir,
        byte[] exeBytes,
        byte[] updaterBytes,
        bool includeLegacyExe = false)
    {
        var zipPath = Path.Combine(workDir, "SoulspireLauncher-win-x64.zip");
        if (File.Exists(zipPath)) File.Delete(zipPath);

        using (var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create))
        {
            var exeEntry = archive.CreateEntry("SoulspireLauncher.exe");
            using (var s = exeEntry.Open()) s.Write(exeBytes, 0, exeBytes.Length);

            var updaterEntry = archive.CreateEntry("SoulspireUpdater.exe");
            using (var s = updaterEntry.Open()) s.Write(updaterBytes, 0, updaterBytes.Length);

            if (includeLegacyExe)
            {
                var legacy = archive.CreateEntry("OverlordsLauncher.exe");
                using var ls = legacy.Open();
                ls.Write(exeBytes, 0, exeBytes.Length);
            }
        }

        var exeSha = Convert.ToHexString(SHA256.HashData(exeBytes)).ToLowerInvariant();
        var updaterSha = Convert.ToHexString(SHA256.HashData(updaterBytes)).ToLowerInvariant();
        var zipSha = LauncherPackageVerifier.ComputeSha256Hex(zipPath);
        var zipSize = new FileInfo(zipPath).Length;
        return (zipPath, zipSha, zipSize, exeSha, updaterSha);
    }

    private static (string PublicKeyPem, string SignatureB64) SignMetadata(LauncherReleaseMetadata meta)
    {
        using var ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var pubPem = ecdsa.ExportSubjectPublicKeyInfoPem();
        var payload = LauncherPackageVerifier.BuildCanonicalSigningPayload(meta);
        var sig = ecdsa.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        var b64 = Convert.ToBase64String(sig);
        meta.SignatureAlgorithm = LauncherPackageVerifier.SupportedSignatureAlgorithm;
        meta.SignatureBase64 = b64;
        meta.SignatureKeyId = "test-key-1";
        return (pubPem, b64);
    }

    [Fact]
    public void CleanPerUserInstallation_CreatesVersionedLayoutAndPreservesExistingAshita()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_install_test_{Guid.NewGuid():N}");
        var portableDir = Path.Combine(tempRoot, "Downloads");
        var portableAshita = Path.Combine(portableDir, "Ashita");
        var installRoot = Path.Combine(tempRoot, "LocalAppData", "SoulspireXI", "Launcher");
        var appDataDir = Path.Combine(tempRoot, "Roaming", "SoulspireXI");
        Directory.CreateDirectory(portableAshita);
        Directory.CreateDirectory(appDataDir);

        try
        {
            var srcExe = Path.Combine(portableDir, "SoulspireLauncher.exe");
            var srcUpdater = Path.Combine(portableDir, "SoulspireUpdater.exe");
            File.WriteAllBytes(srcExe, CreateSyntheticPeBytes("LAUNCHER-2.2.0"));
            File.WriteAllBytes(srcUpdater, CreateSyntheticPeBytes("UPDATER-2.2.0"));
            File.WriteAllText(Path.Combine(portableAshita, "Ashita-cli.exe"), "stub");

            var settingsService = new SettingsService(portableDir, appDataDir);
            var settings = settingsService.Load();
            settings.UpdateChannel = UpdateChannel.TestingCoreUi;
            settings.ServerTarget = ServerTargetMode.Staging;
            settingsService.Save(settings, plainPassword: null);

            var shortcutService = new ShortcutMigrationService();
            var result = LauncherInstallationService.InstallPerUser(
                srcExe,
                srcUpdater,
                currentVersion: "2.2.0-testing.core-ui.1",
                channel: UpdateChannel.TestingCoreUi,
                settingsService: settingsService,
                settings: settings,
                plainPassword: null,
                shortcutService: shortcutService,
                createDesktopShortcut: false,
                createStartMenuShortcut: false,
                installRootOverride: installRoot);

            Assert.True(result.Success, result.Message);
            Assert.True(File.Exists(Path.Combine(installRoot, "SoulspireLauncher.exe")));
            Assert.True(File.Exists(Path.Combine(installRoot, "SoulspireUpdater.exe")));
            Assert.True(File.Exists(Path.Combine(installRoot, "releases", "2.2.0-testing.core-ui.1", "SoulspireLauncher.exe")));

            var state = LauncherInstallationService.LoadInstallState(installRoot);
            Assert.NotNull(state);
            Assert.Equal("per-user", state!.InstallMode);
            Assert.Equal("testing-core-ui", state.Channel);
            Assert.Equal("2.2.0-testing.core-ui.1", state.CurrentVersion);

            // Existing portable Ashita path and user preferences MUST be preserved
            var reloaded = new SettingsService(installRoot, appDataDir).Load();
            Assert.Equal(UpdateChannel.TestingCoreUi, reloaded.UpdateChannel);
            Assert.Equal(ServerTargetMode.Staging, reloaded.ServerTarget);
            Assert.True(reloaded.UseCustomAshitaPath);
            Assert.Equal(portableAshita, reloaded.AshitaPath);
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public async Task StableToStableUpgrade_VerifiesSignatureHashExtractsInstallsAndPrunesOldReleases()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_stable_upg_{Guid.NewGuid():N}");
        var installRoot = Path.Combine(tempRoot, "Install");
        var stagingRoot = Path.Combine(tempRoot, "Stage");
        Directory.CreateDirectory(installRoot);

        try
        {
            var oldExeBytes = CreateSyntheticPeBytes("LAUNCHER-2.2.0");
            var newExeBytes = CreateSyntheticPeBytes("LAUNCHER-2.2.1");
            var newUpdaterBytes = CreateSyntheticPeBytes("UPDATER-2.2.1");
            var targetExe = Path.Combine(installRoot, "SoulspireLauncher.exe");
            File.WriteAllBytes(targetExe, oldExeBytes);

            // Seed 2 older release directories so pruning is verified
            var oldRel1 = Path.Combine(installRoot, "releases", "2.1.8");
            var oldRel2 = Path.Combine(installRoot, "releases", "2.1.9");
            Directory.CreateDirectory(oldRel1);
            Directory.CreateDirectory(oldRel2);
            Directory.SetLastWriteTimeUtc(oldRel1, DateTime.UtcNow.AddDays(-10));
            Directory.SetLastWriteTimeUtc(oldRel2, DateTime.UtcNow.AddDays(-5));

            var (zipPath, zipSha, zipSize, exeSha, updaterSha) = CreateSignedReleaseZip(tempRoot, newExeBytes, newUpdaterBytes);
            var zipBytes = File.ReadAllBytes(zipPath);

            var meta = new LauncherReleaseMetadata
            {
                Channel = "stable",
                Version = "2.2.1",
                Tag = "v2.2.1",
                PackageType = "zip",
                AssetName = "SoulspireLauncher-win-x64.zip",
                DownloadUrl = "https://github.com/Infomatictek/soulspirexi-launcher/releases/download/v2.2.1/SoulspireLauncher-win-x64.zip",
                Sha256 = zipSha,
                Size = zipSize,
                ExecutableName = "SoulspireLauncher.exe",
                ExecutableSha256 = exeSha,
                UpdaterName = "SoulspireUpdater.exe",
                UpdaterSha256 = updaterSha,
                ReleaseUrl = "https://github.com/Infomatictek/soulspirexi-launcher/releases/tag/v2.2.1"
            };
            var (pubPem, _) = SignMetadata(meta);
            var metaJson = JsonSerializer.Serialize(meta);

            var parsed = LauncherSelfUpdateService.ParseChannelReleaseMetadataJson(
                metaJson,
                new Version(2, 2, 0),
                UpdateChannel.Stable,
                currentInformationalVersion: "2.2.0",
                trustedPublicKeyPem: pubPem,
                requireSignature: true);
            Assert.True(parsed.UpdateAvailable);
            Assert.Equal("v2.2.1", parsed.LatestTag);
            Assert.False(parsed.IsPrerelease);

            using var http = new HttpClient(new StubHttpMessageHandler(_ =>
                new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(zipBytes) }));
            var updaterSvc = new LauncherSelfUpdateService(http, trustedPublicKeyPem: pubPem, requireSignature: true);

            var staged = await updaterSvc.DownloadAndVerifyUpdateAsync(
                parsed,
                stagingRootOverride: stagingRoot,
                minimumExeBytes: 64,
                requirePeHeader: true);
            Assert.Equal(exeSha, staged.VerifiedExeSha256);
            Assert.Equal(updaterSha, staged.VerifiedUpdaterSha256);

            var plan = new LauncherUpdatePlan
            {
                InstallRoot = installRoot,
                TargetExePath = targetExe,
                StagedExePath = staged.StagedExePath,
                ExpectedExeSha256 = staged.VerifiedExeSha256,
                StagedUpdaterPath = staged.StagedUpdaterPath,
                ExpectedUpdaterSha256 = staged.VerifiedUpdaterSha256,
                CurrentVersion = "2.2.0",
                TargetVersion = "v2.2.1",
                Channel = "stable"
            };

            var applied = LauncherInstallationService.ApplyStagedUpdate(
                plan,
                requirePeHeader: true,
                minimumExeBytes: 64,
                retainedReleases: 2);
            Assert.True(applied.Success, applied.Message);
            Assert.Equal(exeSha, LauncherPackageVerifier.ComputeSha256Hex(targetExe));
            Assert.Equal(updaterSha, LauncherPackageVerifier.ComputeSha256Hex(Path.Combine(installRoot, "SoulspireUpdater.exe")));
            Assert.True(LauncherInstallationService.CanRollback(installRoot, out var state));
            Assert.Equal("2.2.0", state!.PreviousVersion);
            Assert.False(Directory.Exists(oldRel1)); // Oldest release pruned cleanly
            Assert.True(Directory.Exists(Path.Combine(installRoot, "releases", "2.2.1")));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public void TestingCoreUiChannelIsolation_UpgradesTestingWithoutAffectingStable()
    {
        var meta = new LauncherReleaseMetadata
        {
            Channel = "testing-core-ui",
            Version = "2.2.0-testing.core-ui.2",
            Tag = "v2.2.0-testing.core-ui.2",
            PackageType = "zip",
            DownloadUrl = "https://github.com/Infomatictek/soulspirexi-launcher/releases/download/v2.2.0-testing.core-ui.2/SoulspireLauncher-win-x64.zip",
            Sha256 = new string('a', 64),
            Size = 1024,
            ExecutableSha256 = new string('b', 64)
        };
        var json = JsonSerializer.Serialize(meta);

        // 1. Stable player MUST NEVER receive a Testing Core UI release
        var stableCheck = LauncherSelfUpdateService.ParseChannelReleaseMetadataJson(
            json,
            new Version(2, 1, 10),
            UpdateChannel.Stable,
            currentInformationalVersion: "2.1.10");
        Assert.False(stableCheck.UpdateAvailable);

        // 2. Testing Core UI player on .1 upgrades to .2
        var testingUpgrade = LauncherSelfUpdateService.ParseChannelReleaseMetadataJson(
            json,
            new Version(2, 2, 0),
            UpdateChannel.TestingCoreUi,
            currentInformationalVersion: "2.2.0-testing.core-ui.1");
        Assert.True(testingUpgrade.UpdateAvailable);
        Assert.Equal("v2.2.0-testing.core-ui.2", testingUpgrade.LatestTag);

        // 3. No update available when already on .2
        var upToDate = LauncherSelfUpdateService.ParseChannelReleaseMetadataJson(
            json,
            new Version(2, 2, 0),
            UpdateChannel.TestingCoreUi,
            currentInformationalVersion: "2.2.0-testing.core-ui.2");
        Assert.False(upToDate.UpdateAvailable);
    }

    [Fact]
    public async Task InterruptedDownload_CleansUpPartialFilesAndThrows()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_interrupt_{Guid.NewGuid():N}");
        var stagingRoot = Path.Combine(tempRoot, "Stage");

        try
        {
            using var http = new HttpClient(new StubHttpMessageHandler(_ =>
                new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new FailingAfterBytesStream(256)) }));
            var svc = new LauncherSelfUpdateService(http);

            var check = new LauncherUpdateCheckResult
            {
                UpdateAvailable = true,
                LatestTag = "v2.2.2",
                DownloadUrl = "https://github.com/Infomatictek/soulspirexi-launcher/releases/download/v2.2.2/SoulspireLauncher-win-x64.zip",
                PackageType = "zip",
                ExpectedSha256 = new string('a', 64),
                ExpectedSize = 4096
            };

            await Assert.ThrowsAsync<IOException>(() =>
                svc.DownloadAndVerifyUpdateAsync(check, stagingRootOverride: stagingRoot, minimumExeBytes: 64));

            // No leftover .part or stage-* folders remain
            if (Directory.Exists(stagingRoot))
            {
                Assert.Empty(Directory.GetFileSystemEntries(stagingRoot));
            }
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public async Task CorruptedPackageAndLegacyOverlordsArchive_FailClosedAndCleanStaging()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_corrupt_{Guid.NewGuid():N}");
        var stagingRoot = Path.Combine(tempRoot, "Stage");
        Directory.CreateDirectory(tempRoot);

        try
        {
            var exeBytes = CreateSyntheticPeBytes("LAUNCHER-GOOD");
            var updaterBytes = CreateSyntheticPeBytes("UPDATER-GOOD");
            var (zipPath, zipSha, zipSize, exeSha, updaterSha) = CreateSignedReleaseZip(tempRoot, exeBytes, updaterBytes);

            // Corrupt 1 byte of the ZIP in transit
            var corruptedZipBytes = File.ReadAllBytes(zipPath);
            corruptedZipBytes[^1] ^= 0xFF;

            using var http = new HttpClient(new StubHttpMessageHandler(_ =>
                new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(corruptedZipBytes) }));
            var svc = new LauncherSelfUpdateService(http);

            var check = new LauncherUpdateCheckResult
            {
                UpdateAvailable = true,
                LatestTag = "v2.2.3",
                DownloadUrl = "https://github.com/Infomatictek/soulspirexi-launcher/releases/download/v2.2.3/SoulspireLauncher-win-x64.zip",
                PackageType = "zip",
                ExpectedSha256 = zipSha,
                ExpectedSize = zipSize,
                ExpectedExecutableSha256 = exeSha,
                ExpectedUpdaterSha256 = updaterSha
            };

            var ex = await Assert.ThrowsAsync<InvalidDataException>(() =>
                svc.DownloadAndVerifyUpdateAsync(check, stagingRootOverride: stagingRoot, minimumExeBytes: 64));
            Assert.Contains("SHA-256", ex.Message, StringComparison.OrdinalIgnoreCase);

            // Archive containing forbidden legacy OverlordsLauncher.exe MUST also be rejected
            var (legacyZipPath, legacyZipSha, legacyZipSize, _, _) = CreateSignedReleaseZip(tempRoot, exeBytes, updaterBytes, includeLegacyExe: true);
            var badExtract = LauncherPackageVerifier.VerifyAndExtractZipPackage(
                legacyZipPath,
                new LauncherReleaseMetadata
                {
                    Sha256 = legacyZipSha,
                    Size = legacyZipSize,
                    ExecutableSha256 = exeSha
                },
                Path.Combine(tempRoot, "legacy-extract"),
                minimumExeBytes: 64);
            Assert.False(badExtract.Success);
            Assert.Contains("OverlordsLauncher.exe", badExtract.ErrorMessage, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public void InvalidOrTamperedSignature_FailsClosed()
    {
        var meta = new LauncherReleaseMetadata
        {
            Channel = "stable",
            Version = "2.2.1",
            Tag = "v2.2.1",
            PackageType = "zip",
            DownloadUrl = "https://github.com/Infomatictek/soulspirexi-launcher/releases/download/v2.2.1/SoulspireLauncher-win-x64.zip",
            Sha256 = new string('a', 64),
            Size = 1024,
            ExecutableSha256 = new string('b', 64)
        };
        var (pubPem, _) = SignMetadata(meta);

        // Valid signature passes
        Assert.True(LauncherPackageVerifier.VerifySignature(meta, pubPem, requireSignature: true, out _));

        // Tamper with SHA-256 after signing -> MUST fail closed
        meta.Sha256 = new string('c', 64);
        Assert.False(LauncherPackageVerifier.VerifySignature(meta, pubPem, requireSignature: true, out var err));
        Assert.Contains("signature", err, StringComparison.OrdinalIgnoreCase);

        // Missing signature when requireSignature=true -> MUST fail closed
        meta.SignatureBase64 = null;
        Assert.False(LauncherPackageVerifier.VerifySignature(meta, pubPem, requireSignature: true, out var missingErr));
        Assert.Contains("missing", missingErr, StringComparison.OrdinalIgnoreCase);

        // Untrusted non-HTTPS download URL -> MUST fail closed
        Assert.False(LauncherPackageVerifier.IsTrustedDownloadUri("http://evil.example.com/SoulspireLauncher.exe"));
        Assert.False(LauncherPackageVerifier.IsTrustedDownloadUri("https://evil.example.com/SoulspireLauncher.exe"));
    }

    [Fact]
    public async Task LockedFile_TransientLockSucceedsOnRetry_AndPermanentLockPreservesOriginal()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_lock_{Guid.NewGuid():N}");
        var installRoot = Path.Combine(tempRoot, "Install");
        Directory.CreateDirectory(installRoot);

        try
        {
            var oldBytes = CreateSyntheticPeBytes("LAUNCHER-OLD");
            var newBytes = CreateSyntheticPeBytes("LAUNCHER-NEW");
            var targetExe = Path.Combine(installRoot, "SoulspireLauncher.exe");
            var stagedExe = Path.Combine(tempRoot, "staged.exe");
            File.WriteAllBytes(targetExe, oldBytes);
            File.WriteAllBytes(stagedExe, newBytes);
            var oldSha = LauncherPackageVerifier.ComputeSha256Hex(targetExe);
            var newSha = LauncherPackageVerifier.ComputeSha256Hex(stagedExe);

            var plan = new LauncherUpdatePlan
            {
                InstallRoot = installRoot,
                TargetExePath = targetExe,
                StagedExePath = stagedExe,
                ExpectedExeSha256 = newSha,
                CurrentVersion = "2.2.0",
                TargetVersion = "v2.2.1",
                Channel = "stable"
            };

            // 1. Permanent lock -> fails cleanly, original file untouched, failure recorded in install-state.json
            using (var permLock = new FileStream(targetExe, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            {
                var failed = LauncherInstallationService.ApplyStagedUpdate(
                    plan,
                    maxLockRetries: 3,
                    retryDelayMs: 25,
                    requirePeHeader: true,
                    minimumExeBytes: 64);
                Assert.False(failed.Success);
            }
            Assert.Equal(oldSha, LauncherPackageVerifier.ComputeSha256Hex(targetExe));
            var failState = LauncherInstallationService.LoadInstallState(installRoot);
            Assert.Equal("failed", failState?.LastUpdateStatus);

            // 2. Transient lock (simulating AV scan / exiting process) -> succeeds on retry
            var transientLock = new FileStream(targetExe, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            var releaseTask = Task.Run(async () =>
            {
                await Task.Delay(120);
                transientLock.Dispose();
            });

            var succeeded = LauncherInstallationService.ApplyStagedUpdate(
                plan,
                maxLockRetries: 20,
                retryDelayMs: 50,
                requirePeHeader: true,
                minimumExeBytes: 64);
            await releaseTask;
            Assert.True(succeeded.Success, succeeded.Message);
            Assert.Equal(newSha, LauncherPackageVerifier.ComputeSha256Hex(targetExe));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public void RollbackAndInterruptedUpdateRecovery_RestorePreviousLauncherSafely()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_rollback_{Guid.NewGuid():N}");
        var installRoot = Path.Combine(tempRoot, "Install");
        Directory.CreateDirectory(installRoot);

        try
        {
            var v1Bytes = CreateSyntheticPeBytes("LAUNCHER-2.2.0");
            var v2Bytes = CreateSyntheticPeBytes("LAUNCHER-2.2.1");
            var targetExe = Path.Combine(installRoot, "SoulspireLauncher.exe");
            var stagedV2 = Path.Combine(tempRoot, "staged-v2.exe");
            File.WriteAllBytes(targetExe, v1Bytes);
            File.WriteAllBytes(stagedV2, v2Bytes);
            var v1Sha = LauncherPackageVerifier.ComputeSha256Hex(targetExe);
            var v2Sha = LauncherPackageVerifier.ComputeSha256Hex(stagedV2);

            var apply = LauncherInstallationService.ApplyStagedUpdate(
                new LauncherUpdatePlan
                {
                    InstallRoot = installRoot,
                    TargetExePath = targetExe,
                    StagedExePath = stagedV2,
                    ExpectedExeSha256 = v2Sha,
                    CurrentVersion = "2.2.0",
                    TargetVersion = "v2.2.1",
                    Channel = "testing-core-ui"
                },
                requirePeHeader: true,
                minimumExeBytes: 64);
            Assert.True(apply.Success);

            // Simulate installer crash leaving stray temp files and missing live exe
            File.WriteAllText(Path.Combine(installRoot, "SoulspireLauncher.exe.new"), "partial");
            File.WriteAllText(Path.Combine(installRoot, "download.part"), "partial");
            File.Delete(targetExe);

            var recovery = LauncherInstallationService.RecoverFromInterruptedUpdate(installRoot);
            Assert.True(recovery.RecoveredCorruptOrMissingExe);
            Assert.True(recovery.CleanedTempFilesCount >= 2);
            Assert.Equal(v1Sha, LauncherPackageVerifier.ComputeSha256Hex(targetExe));

            // Re-apply v2, then explicitly roll back to v1
            Assert.True(LauncherInstallationService.ApplyStagedUpdate(
                new LauncherUpdatePlan
                {
                    InstallRoot = installRoot,
                    TargetExePath = targetExe,
                    StagedExePath = stagedV2,
                    ExpectedExeSha256 = v2Sha,
                    CurrentVersion = "2.2.0",
                    TargetVersion = "v2.2.1",
                    Channel = "testing-core-ui"
                },
                requirePeHeader: true,
                minimumExeBytes: 64).Success);
            Assert.Equal(v2Sha, LauncherPackageVerifier.ComputeSha256Hex(targetExe));

            var rollback = LauncherInstallationService.RollbackToPrevious(installRoot);
            Assert.True(rollback.Success, rollback.Message);
            Assert.True(rollback.RolledBack);
            Assert.Equal(v1Sha, LauncherPackageVerifier.ComputeSha256Hex(targetExe));

            // Tampering with rollback backup MUST cause rollback to fail closed
            var backupPath = LauncherInstallationService.GetRollbackBackupPath(installRoot);
            File.WriteAllBytes(backupPath, CreateSyntheticPeBytes("TAMPERED"));
            Assert.False(LauncherInstallationService.CanRollback(installRoot, out _));
            var tamperedRollback = LauncherInstallationService.RollbackToPrevious(installRoot);
            Assert.False(tamperedRollback.Success);
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public async Task ActiveStagingRelayAndPostUpdateRestart_PreserveEnvironmentAndGameUpdates()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_post_upg_{Guid.NewGuid():N}");
        var installRoot = Path.Combine(tempRoot, "Install");
        var appDataDir = Path.Combine(tempRoot, "AppData");
        Directory.CreateDirectory(installRoot);
        Directory.CreateDirectory(appDataDir);

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var mockUpstream = new TcpListener(IPAddress.Loopback, 0);
        mockUpstream.Start();
        var upstreamPort = ((IPEndPoint)mockUpstream.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            try
            {
                using var serverClient = await mockUpstream.AcceptTcpClientAsync(cts.Token);
                await using var s = serverClient.GetStream();
                var buf = new byte[32];
                var n = await s.ReadAsync(buf, cts.Token);
                if (n > 0) await s.WriteAsync(buf.AsMemory(0, n), cts.Token);
                await Task.Delay(500, cts.Token);
            }
            catch { }
        }, CancellationToken.None);

        try
        {
            // 1. Verify active Staging relay holds client connection open so auto-update defers cleanly
            using var freeProbe = new TcpListener(IPAddress.Loopback, 0);
            freeProbe.Start();
            var localPort = ((IPEndPoint)freeProbe.LocalEndpoint).Port;
            freeProbe.Stop();

            using var relay = new StagingRelayService();
            Assert.True(relay.Start(new StagingRelayConfig(
                "127.0.0.1",
                [new StagingPortRoute("Auth", localPort, upstreamPort)])).Success);

            using (var activeClient = new TcpClient())
            {
                await activeClient.ConnectAsync(IPAddress.Loopback, localPort, cts.Token);
                await using var stream = activeClient.GetStream();
                await stream.WriteAsync(Encoding.UTF8.GetBytes("live"), cts.Token);
                var reply = new byte[16];
                var read = await stream.ReadAsync(reply, cts.Token);
                Assert.Equal("live", Encoding.UTF8.GetString(reply, 0, read));
                Assert.True(relay.IsRunning);
                Assert.True(relay.ActiveClientConnections >= 1);
            }
            relay.Stop();

            // 2. Verify Staging/Production settings + game manifest update checks survive launcher upgrade
            var settingsSvc = new SettingsService(installRoot, appDataDir);
            var before = settingsSvc.Load();
            before.UpdateChannel = UpdateChannel.TestingCoreUi;
            before.ServerTarget = ServerTargetMode.Staging;
            before.StagingServerHost = "192.168.86.117";
            before.StagingProfileIrcPort = 51241;
            settingsSvc.Save(before, plainPassword: null);

            var targetExe = Path.Combine(installRoot, "SoulspireLauncher.exe");
            var stagedExe = Path.Combine(tempRoot, "new.exe");
            File.WriteAllBytes(targetExe, CreateSyntheticPeBytes("V1"));
            File.WriteAllBytes(stagedExe, CreateSyntheticPeBytes("V2"));
            var newSha = LauncherPackageVerifier.ComputeSha256Hex(stagedExe);

            Assert.True(LauncherInstallationService.ApplyStagedUpdate(
                new LauncherUpdatePlan
                {
                    InstallRoot = installRoot,
                    TargetExePath = targetExe,
                    StagedExePath = stagedExe,
                    ExpectedExeSha256 = newSha,
                    CurrentVersion = "2.2.0-testing.core-ui.1",
                    TargetVersion = "v2.2.0-testing.core-ui.2",
                    Channel = "testing-core-ui"
                },
                requirePeHeader: true,
                minimumExeBytes: 64).Success);

            // Simulate restarted launcher verifying clean startup + resuming Staging & game updates
            var postRecovery = LauncherInstallationService.RecoverFromInterruptedUpdate(installRoot);
            Assert.True(postRecovery.ClearedPendingVerification);

            var after = new SettingsService(installRoot, appDataDir).Load();
            Assert.Equal(UpdateChannel.TestingCoreUi, after.UpdateChannel);
            Assert.Equal(ServerTargetMode.Staging, after.ServerTarget);
            Assert.Equal("192.168.86.117", after.StagingServerHost);
            Assert.Equal(51241, after.StagingProfileIrcPort);

            var manifestSvc = new ManifestUpdateService();
            var embedded = manifestSvc.LoadEmbeddedManifest();
            var plan = StagingRelayService.ResolveConnectionPlan(after, embedded);
            Assert.True(plan.RequiresLoopbackRelay);
            Assert.Equal(6, plan.RelayConfig!.Routes.Count);
            Assert.NotEmpty(manifestSvc.GetOutdatedFiles(embedded, after));
        }
        finally
        {
            if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, recursive: true);
        }
    }

    private sealed class StubHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(responder(request));
    }

    private sealed class FailingAfterBytesStream(int failAfterBytes) : Stream
    {
        private int _sent;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => failAfterBytes * 4;
        public override long Position { get => _sent; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_sent >= failAfterBytes)
            {
                throw new IOException("Simulated interrupted network stream.");
            }
            var toSend = Math.Min(count, failAfterBytes - _sent);
            Array.Fill(buffer, (byte)'X', offset, toSend);
            _sent += toSend;
            return toSend;
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}

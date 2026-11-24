using System.IO;
using System.Text;
using System.Text.Json;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed record LauncherInstallResult(
    bool Success,
    string InstallRoot,
    string InstalledExePath,
    string? InstalledUpdaterPath,
    bool DesktopShortcutCreated,
    bool StartMenuShortcutCreated,
    string Message);

public sealed record LauncherApplyResult(
    bool Success,
    bool RolledBack,
    string TargetExePath,
    string ActiveVersion,
    string? PreviousVersion,
    string Message);

public sealed record InterruptedUpdateRecoveryResult(
    bool RecoveredCorruptOrMissingExe,
    int CleanedTempFilesCount,
    bool ClearedPendingVerification,
    string Summary);

/// <summary>
/// Manages per-user zero-admin installation (%LOCALAPPDATA%\SoulspireXI\Launcher),
/// versioned releases/, atomic update replacement, verified rollback, old-release pruning,
/// and recovery from interrupted updates.
/// </summary>
public static class LauncherInstallationService
{
    public const string InstallStateFileName = "install-state.json";
    public const string ReleasesFolderName = "releases";
    public const string RollbackFolderName = "rollback";
    public const string LogsFolderName = "logs";
    public const string RollbackBackupFileName = "SoulspireLauncher.prev.exe";
    public const string CanonicalUpdaterExeName = "SoulspireUpdater.exe";
    public const int DefaultRetainedReleases = 2;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public static string GetDefaultPerUserInstallRoot()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return Path.Combine(localAppData, "SoulspireXI", "Launcher");
    }

    public static bool IsRunningFromPerUserInstall(string? currentExePath, string? perUserRootOverride = null)
    {
        if (string.IsNullOrWhiteSpace(currentExePath))
        {
            return false;
        }

        var root = Path.GetFullPath(perUserRootOverride ?? GetDefaultPerUserInstallRoot())
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var exeDir = Path.GetFullPath(Path.GetDirectoryName(currentExePath) ?? string.Empty)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        return string.Equals(exeDir, root, StringComparison.OrdinalIgnoreCase);
    }

    public static string GetInstallStatePath(string installRoot) =>
        Path.Combine(installRoot, InstallStateFileName);

    public static string GetRollbackBackupPath(string installRoot) =>
        Path.Combine(installRoot, RollbackFolderName, RollbackBackupFileName);

    public static string SanitizeVersionFolderName(string version)
    {
        var raw = string.IsNullOrWhiteSpace(version) ? "unknown" : version.Trim().TrimStart('v', 'V');
        var sb = new StringBuilder(raw.Length);
        foreach (var ch in raw)
        {
            sb.Append(char.IsLetterOrDigit(ch) || ch is '.' or '-' or '_' ? ch : '_');
        }

        var result = sb.ToString().Trim('.', '_');
        return string.IsNullOrWhiteSpace(result) ? "unknown" : result;
    }

    public static LauncherInstallState? LoadInstallState(string installRoot)
    {
        var path = GetInstallStatePath(installRoot);
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            var json = File.ReadAllText(path, Encoding.UTF8);
            return JsonSerializer.Deserialize<LauncherInstallState>(json, JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    public static void SaveInstallState(string installRoot, LauncherInstallState state)
    {
        Directory.CreateDirectory(installRoot);
        var path = GetInstallStatePath(installRoot);
        var tmpPath = path + $".{Environment.ProcessId}.tmp";
        var json = JsonSerializer.Serialize(state, JsonOptions);
        File.WriteAllText(tmpPath, json, Encoding.UTF8);
        File.Move(tmpPath, path, overwrite: true);
    }

    public static bool CanRollback(string installRoot, out LauncherInstallState? state)
    {
        state = LoadInstallState(installRoot);
        if (state is null ||
            string.IsNullOrWhiteSpace(state.PreviousBackupPath) ||
            !File.Exists(state.PreviousBackupPath))
        {
            return false;
        }

        if (!string.IsNullOrWhiteSpace(state.PreviousBackupSha256))
        {
            var actual = LauncherPackageVerifier.ComputeSha256Hex(state.PreviousBackupPath);
            if (!string.Equals(actual, state.PreviousBackupSha256, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// One-time per-user installation into %LOCALAPPDATA%\SoulspireXI\Launcher (no admin required).
    /// Preserves all existing player settings and any existing Ashita installation.
    /// </summary>
    public static LauncherInstallResult InstallPerUser(
        string sourceLauncherExePath,
        string? sourceUpdaterExePath,
        string currentVersion,
        UpdateChannel channel,
        SettingsService settingsService,
        LauncherSettings settings,
        string? plainPassword,
        ShortcutMigrationService shortcutService,
        bool createDesktopShortcut = true,
        bool createStartMenuShortcut = true,
        string? installRootOverride = null)
    {
        if (string.IsNullOrWhiteSpace(sourceLauncherExePath) || !File.Exists(sourceLauncherExePath))
        {
            return new LauncherInstallResult(
                false,
                installRootOverride ?? GetDefaultPerUserInstallRoot(),
                string.Empty,
                null,
                false,
                false,
                "Source SoulspireLauncher.exe could not be found.");
        }

        var installRoot = Path.GetFullPath(installRootOverride ?? GetDefaultPerUserInstallRoot());
        var releaseFolder = Path.Combine(installRoot, ReleasesFolderName, SanitizeVersionFolderName(currentVersion));
        var rollbackDir = Path.Combine(installRoot, RollbackFolderName);
        var logsDir = Path.Combine(installRoot, LogsFolderName);

        Directory.CreateDirectory(installRoot);
        Directory.CreateDirectory(releaseFolder);
        Directory.CreateDirectory(rollbackDir);
        Directory.CreateDirectory(logsDir);

        var sourceSha = LauncherPackageVerifier.ComputeSha256Hex(sourceLauncherExePath);
        var releaseExePath = Path.Combine(releaseFolder, LauncherSelfUpdateService.CanonicalLauncherExeName);
        var activeExePath = Path.Combine(installRoot, LauncherSelfUpdateService.CanonicalLauncherExeName);

        if (!SettingsService.PathsEqual(sourceLauncherExePath, releaseExePath))
        {
            File.Copy(sourceLauncherExePath, releaseExePath, overwrite: true);
        }

        if (!SettingsService.PathsEqual(sourceLauncherExePath, activeExePath))
        {
            var stagingCopy = activeExePath + ".new";
            File.Copy(releaseExePath, stagingCopy, overwrite: true);
            ReplaceFileWithRetry(stagingCopy, activeExePath, backupPath: null, maxRetries: 10, retryDelayMs: 200);
        }

        string? installedUpdaterPath = null;
        if (!string.IsNullOrWhiteSpace(sourceUpdaterExePath) && File.Exists(sourceUpdaterExePath))
        {
            var releaseUpdater = Path.Combine(releaseFolder, CanonicalUpdaterExeName);
            var activeUpdater = Path.Combine(installRoot, CanonicalUpdaterExeName);
            if (!SettingsService.PathsEqual(sourceUpdaterExePath, releaseUpdater))
            {
                File.Copy(sourceUpdaterExePath, releaseUpdater, overwrite: true);
            }
            if (!SettingsService.PathsEqual(sourceUpdaterExePath, activeUpdater))
            {
                var stagingUpdater = activeUpdater + ".new";
                File.Copy(releaseUpdater, stagingUpdater, overwrite: true);
                ReplaceFileWithRetry(stagingUpdater, activeUpdater, backupPath: null, maxRetries: 10, retryDelayMs: 200);
            }
            installedUpdaterPath = activeUpdater;
        }

        // Preserve any pre-existing Ashita installation located next to the old portable launcher
        // so moving to %LOCALAPPDATA%\SoulspireXI\Launcher never forces re-downloading Ashita/DATs.
        var oldLauncherDir = Path.GetDirectoryName(sourceLauncherExePath);
        if (!string.IsNullOrWhiteSpace(oldLauncherDir) &&
            !SettingsService.PathsEqual(oldLauncherDir, installRoot) &&
            !settings.UseCustomAshitaPath)
        {
            var existingPortableAshita = Path.Combine(oldLauncherDir, "Ashita");
            if (File.Exists(Path.Combine(existingPortableAshita, "Ashita-cli.exe")))
            {
                settings.AshitaPath = existingPortableAshita;
                settings.UseCustomAshitaPath = true;
                settingsService.Save(settings, plainPassword);
            }
        }

        var existingState = LoadInstallState(installRoot);
        var newState = new LauncherInstallState
        {
            InstallMode = "per-user",
            InstallRoot = installRoot,
            Channel = LauncherSelfUpdateService.GetChannelSlug(channel),
            CurrentVersion = currentVersion,
            CurrentReleaseDir = releaseFolder,
            ActiveExecutableSha256 = sourceSha,
            PreviousVersion = existingState?.CurrentVersion,
            PreviousBackupPath = existingState?.PreviousBackupPath,
            PreviousBackupSha256 = existingState?.PreviousBackupSha256,
            PendingVerification = false,
            LastUpdateStatus = "installed",
            UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O")
        };
        SaveInstallState(installRoot, newState);

        var desktopOk = createDesktopShortcut && shortcutService.CreateDesktopShortcut(activeExePath);
        var startMenuOk = createStartMenuShortcut && shortcutService.CreateStartMenuShortcut(activeExePath);

        return new LauncherInstallResult(
            true,
            installRoot,
            activeExePath,
            installedUpdaterPath,
            desktopOk,
            startMenuOk,
            $"Installed SoulspireXI Launcher {currentVersion} to {installRoot} (per-user, no admin required).");
    }

    /// <summary>
    /// Atomically applies a verified staged launcher update into <installRoot>, maintaining a
    /// verified rollback backup, versioned releases/ history, file-lock retries, and automatic
    /// rollback if any swap step fails.
    /// </summary>
    public static LauncherApplyResult ApplyStagedUpdate(
        LauncherUpdatePlan plan,
        int maxLockRetries = 20,
        int retryDelayMs = 250,
        bool requirePeHeader = true,
        long minimumExeBytes = LauncherPackageVerifier.DefaultMinimumValidExeBytes,
        int retainedReleases = DefaultRetainedReleases,
        Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(plan);

        var installRoot = !string.IsNullOrWhiteSpace(plan.InstallRoot)
            ? Path.GetFullPath(plan.InstallRoot)
            : Path.GetFullPath(Path.GetDirectoryName(plan.TargetExePath) ?? string.Empty);
        var targetExePath = LauncherSelfUpdateService.ResolveCanonicalTargetExePath(plan.TargetExePath);

        // 1. Re-verify staged executable SHA-256 BEFORE touching ANY live file
        var exeCheck = LauncherPackageVerifier.VerifyFileIntegrity(
            plan.StagedExePath,
            plan.ExpectedExeSha256,
            expectedSize: 0,
            minimumSizeBytes: minimumExeBytes,
            requirePeHeader: requirePeHeader);
        if (!exeCheck.IsValid)
        {
            var err = $"Aborted update before modifying live files: {exeCheck.ErrorMessage}";
            log?.Invoke(err);
            RecordFailureState(installRoot, plan, err);
            return new LauncherApplyResult(false, false, targetExePath, plan.CurrentVersion, null, err);
        }

        if (!string.IsNullOrWhiteSpace(plan.StagedUpdaterPath))
        {
            var updaterCheck = LauncherPackageVerifier.VerifyFileIntegrity(
                plan.StagedUpdaterPath,
                plan.ExpectedUpdaterSha256,
                expectedSize: 0,
                minimumSizeBytes: 64,
                requirePeHeader: requirePeHeader);
            if (!updaterCheck.IsValid)
            {
                var err = $"Aborted update: staged updater failed integrity check ({updaterCheck.ErrorMessage}).";
                log?.Invoke(err);
                RecordFailureState(installRoot, plan, err);
                return new LauncherApplyResult(false, false, targetExePath, plan.CurrentVersion, null, err);
            }
        }

        var releaseDir = Path.Combine(installRoot, ReleasesFolderName, SanitizeVersionFolderName(plan.TargetVersion));
        var rollbackDir = Path.Combine(installRoot, RollbackFolderName);
        var rollbackBackupPath = GetRollbackBackupPath(installRoot);
        var pendingNewExePath = targetExePath + ".new";
        string? preUpdateSha = null;
        var backupCreated = false;

        try
        {
            Directory.CreateDirectory(installRoot);
            Directory.CreateDirectory(releaseDir);
            Directory.CreateDirectory(rollbackDir);

            // 2. Persist verified new binary into versioned releases/<version>/
            var releaseExePath = Path.Combine(releaseDir, LauncherSelfUpdateService.CanonicalLauncherExeName);
            File.Copy(plan.StagedExePath, releaseExePath, overwrite: true);
            var releaseVerify = LauncherPackageVerifier.VerifyFileIntegrity(
                releaseExePath,
                exeCheck.ComputedSha256,
                expectedSize: exeCheck.SizeBytes,
                minimumSizeBytes: minimumExeBytes,
                requirePeHeader: requirePeHeader);
            if (!releaseVerify.IsValid)
            {
                throw new IOException($"Versioned release copy verification failed: {releaseVerify.ErrorMessage}");
            }

            // 3. Create verified rollback backup of current working executable (if present)
            if (File.Exists(targetExePath))
            {
                preUpdateSha = LauncherPackageVerifier.ComputeSha256Hex(targetExePath);
                var tmpBackup = rollbackBackupPath + ".tmp";
                File.Copy(targetExePath, tmpBackup, overwrite: true);
                var backupVerify = LauncherPackageVerifier.VerifyFileIntegrity(
                    tmpBackup,
                    preUpdateSha,
                    expectedSize: 0,
                    minimumSizeBytes: 1,
                    requirePeHeader: false);
                if (!backupVerify.IsValid)
                {
                    throw new IOException($"Failed to verify rollback backup: {backupVerify.ErrorMessage}");
                }

                File.Move(tmpBackup, rollbackBackupPath, overwrite: true);
                backupCreated = true;
                log?.Invoke($"Created verified rollback backup ({preUpdateSha[..12]}) at {rollbackBackupPath}.");
            }

            // 4. Copy verified new binary to same-volume .new file and atomically replace target
            File.Copy(releaseExePath, pendingNewExePath, overwrite: true);
            var pendingVerify = LauncherPackageVerifier.VerifyFileIntegrity(
                pendingNewExePath,
                exeCheck.ComputedSha256,
                expectedSize: exeCheck.SizeBytes,
                minimumSizeBytes: minimumExeBytes,
                requirePeHeader: requirePeHeader);
            if (!pendingVerify.IsValid)
            {
                throw new IOException($"Same-volume staged file verification failed: {pendingVerify.ErrorMessage}");
            }

            var transientSwapBackup = targetExePath + ".swap-bak";
            ReplaceFileWithRetry(pendingNewExePath, targetExePath, transientSwapBackup, maxLockRetries, retryDelayMs, log);
            SafeDeleteFile(transientSwapBackup);

            // 5. Post-swap verification of the live executable
            var postVerify = LauncherPackageVerifier.VerifyFileIntegrity(
                targetExePath,
                exeCheck.ComputedSha256,
                expectedSize: exeCheck.SizeBytes,
                minimumSizeBytes: minimumExeBytes,
                requirePeHeader: requirePeHeader);
            if (!postVerify.IsValid)
            {
                throw new IOException($"Post-swap verification failed: {postVerify.ErrorMessage}");
            }

            // 6. Update stored SoulspireUpdater.exe if bundled & verified
            if (!string.IsNullOrWhiteSpace(plan.StagedUpdaterPath) && File.Exists(plan.StagedUpdaterPath))
            {
                var releaseUpdaterPath = Path.Combine(releaseDir, CanonicalUpdaterExeName);
                File.Copy(plan.StagedUpdaterPath, releaseUpdaterPath, overwrite: true);

                var targetUpdaterPath = Path.Combine(installRoot, CanonicalUpdaterExeName);
                var pendingUpdaterPath = targetUpdaterPath + ".new";
                File.Copy(releaseUpdaterPath, pendingUpdaterPath, overwrite: true);
                ReplaceFileWithRetry(pendingUpdaterPath, targetUpdaterPath, backupPath: null, maxLockRetries, retryDelayMs, log);
            }

            // 7. Persist install-state.json & prune obsolete releases
            var existingState = LoadInstallState(installRoot);
            var updatedState = new LauncherInstallState
            {
                InstallMode = existingState?.InstallMode ??
                    (IsRunningFromPerUserInstall(targetExePath) ? "per-user" : "portable"),
                InstallRoot = installRoot,
                Channel = string.IsNullOrWhiteSpace(plan.Channel) ? "stable" : plan.Channel,
                CurrentVersion = plan.TargetVersion,
                CurrentReleaseDir = releaseDir,
                ActiveExecutableSha256 = exeCheck.ComputedSha256,
                PreviousVersion = backupCreated ? plan.CurrentVersion : existingState?.PreviousVersion,
                PreviousBackupPath = backupCreated ? rollbackBackupPath : existingState?.PreviousBackupPath,
                PreviousBackupSha256 = backupCreated ? preUpdateSha : existingState?.PreviousBackupSha256,
                PendingVerification = true,
                PendingTargetVersion = plan.TargetVersion,
                LastUpdateStatus = "installed-pending-restart",
                LastUpdateError = null,
                UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O")
            };
            SaveInstallState(installRoot, updatedState);

            PruneOldReleases(installRoot, keepLatestCount: Math.Max(1, retainedReleases), protectReleaseDir: releaseDir, log);

            var okMsg = $"Installed SoulspireXI Launcher {plan.TargetVersion} (SHA-256 {exeCheck.ComputedSha256[..12]}).";
            log?.Invoke(okMsg);
            return new LauncherApplyResult(true, false, targetExePath, plan.TargetVersion, updatedState.PreviousVersion, okMsg);
        }
        catch (Exception ex)
        {
            SafeDeleteFile(pendingNewExePath);
            var rolledBack = false;
            if (backupCreated && File.Exists(rollbackBackupPath))
            {
                try
                {
                    var restoreTmp = targetExePath + ".restore";
                    File.Copy(rollbackBackupPath, restoreTmp, overwrite: true);
                    ReplaceFileWithRetry(restoreTmp, targetExePath, backupPath: null, maxRetries: 10, retryDelayMs: 200, log);
                    rolledBack = true;
                    log?.Invoke($"Automatic rollback restored previous launcher ({plan.CurrentVersion}) after error: {ex.Message}");
                }
                catch (Exception rbEx)
                {
                    log?.Invoke($"Rollback attempt encountered an error: {rbEx.Message}");
                }
            }

            var errMsg = rolledBack
                ? $"Update to {plan.TargetVersion} failed ({ex.Message}); automatically rolled back to {plan.CurrentVersion}."
                : $"Update to {plan.TargetVersion} failed: {ex.Message}";
            RecordFailureState(installRoot, plan, errMsg);
            return new LauncherApplyResult(false, rolledBack, targetExePath, plan.CurrentVersion, plan.CurrentVersion, errMsg);
        }
    }

    /// <summary>
    /// Explicitly rolls back to the verified previous launcher backup recorded in install-state.json.
    /// </summary>
    public static LauncherApplyResult RollbackToPrevious(
        string installRoot,
        int maxLockRetries = 20,
        int retryDelayMs = 250,
        Action<string>? log = null)
    {
        var fullRoot = Path.GetFullPath(installRoot);
        var targetExePath = Path.Combine(fullRoot, LauncherSelfUpdateService.CanonicalLauncherExeName);
        var state = LoadInstallState(fullRoot);
        if (state is null || string.IsNullOrWhiteSpace(state.PreviousBackupPath) || !File.Exists(state.PreviousBackupPath))
        {
            return new LauncherApplyResult(false, false, targetExePath, state?.CurrentVersion ?? string.Empty, null,
                "No previous launcher backup is available for rollback.");
        }

        var backupCheck = LauncherPackageVerifier.VerifyFileIntegrity(
            state.PreviousBackupPath,
            state.PreviousBackupSha256,
            expectedSize: 0,
            minimumSizeBytes: 1,
            requirePeHeader: false);
        if (!backupCheck.IsValid)
        {
            return new LauncherApplyResult(false, false, targetExePath, state.CurrentVersion, state.PreviousVersion,
                $"Rollback aborted: previous backup failed SHA-256 verification ({backupCheck.ErrorMessage}).");
        }

        var restoreTmp = targetExePath + ".rollback-new";
        try
        {
            File.Copy(state.PreviousBackupPath, restoreTmp, overwrite: true);
            ReplaceFileWithRetry(restoreTmp, targetExePath, backupPath: null, maxLockRetries, retryDelayMs, log);

            var restoredVersion = string.IsNullOrWhiteSpace(state.PreviousVersion) ? "previous" : state.PreviousVersion!;
            state.CurrentVersion = restoredVersion;
            state.ActiveExecutableSha256 = backupCheck.ComputedSha256;
            state.PendingVerification = false;
            state.PendingTargetVersion = null;
            state.LastUpdateStatus = "rolled-back";
            state.LastUpdateError = null;
            state.UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O");
            SaveInstallState(fullRoot, state);

            var msg = $"Rolled back SoulspireXI Launcher to {restoredVersion}.";
            log?.Invoke(msg);
            return new LauncherApplyResult(true, true, targetExePath, restoredVersion, state.PreviousVersion, msg);
        }
        catch (Exception ex)
        {
            SafeDeleteFile(restoreTmp);
            return new LauncherApplyResult(false, false, targetExePath, state.CurrentVersion, state.PreviousVersion,
                $"Rollback failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Cleans up partial/temporary update artifacts and confirms a healthy post-update boot.
    /// </summary>
    public static InterruptedUpdateRecoveryResult RecoverFromInterruptedUpdate(string installRoot)
    {
        var fullRoot = Path.GetFullPath(installRoot);
        var cleaned = 0;
        var recoveredExe = false;
        var clearedPending = false;

        if (Directory.Exists(fullRoot))
        {
            foreach (var pattern in new[] { "*.new", "*.swap-bak", "*.restore", "*.rollback-new", "*.part", ".update-write-test-*.tmp" })
            {
                foreach (var file in Directory.GetFiles(fullRoot, pattern, SearchOption.TopDirectoryOnly))
                {
                    if (SafeDeleteFile(file))
                    {
                        cleaned++;
                    }
                }
            }
        }

        var state = LoadInstallState(fullRoot);
        if (state is not null)
        {
            var targetExe = Path.Combine(fullRoot, LauncherSelfUpdateService.CanonicalLauncherExeName);
            var exeBroken = !File.Exists(targetExe) || new FileInfo(targetExe).Length == 0;
            if (exeBroken &&
                !string.IsNullOrWhiteSpace(state.PreviousBackupPath) &&
                File.Exists(state.PreviousBackupPath))
            {
                var check = LauncherPackageVerifier.VerifyFileIntegrity(
                    state.PreviousBackupPath,
                    state.PreviousBackupSha256,
                    expectedSize: 0,
                    minimumSizeBytes: 1,
                    requirePeHeader: false);
                if (check.IsValid)
                {
                    File.Copy(state.PreviousBackupPath, targetExe, overwrite: true);
                    recoveredExe = true;
                    state.LastUpdateStatus = "recovered-from-interrupted-update";
                    state.PendingVerification = false;
                    state.UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O");
                    SaveInstallState(fullRoot, state);
                }
            }
            else if (state.PendingVerification)
            {
                state.PendingVerification = false;
                state.PendingTargetVersion = null;
                state.LastUpdateStatus = "verified";
                state.UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O");
                SaveInstallState(fullRoot, state);
                clearedPending = true;
            }
        }

        var summary = recoveredExe
            ? "Recovered SoulspireLauncher.exe from verified rollback backup after an interrupted update."
            : (cleaned > 0
                ? $"Cleaned {cleaned} leftover temporary update file(s)."
                : (clearedPending ? "Verified newly updated launcher startup." : "Install directory healthy."));

        return new InterruptedUpdateRecoveryResult(recoveredExe, cleaned, clearedPending, summary);
    }

    public static int PruneOldReleases(
        string installRoot,
        int keepLatestCount = DefaultRetainedReleases,
        string? protectReleaseDir = null,
        Action<string>? log = null)
    {
        var releasesRoot = Path.Combine(installRoot, ReleasesFolderName);
        if (!Directory.Exists(releasesRoot))
        {
            return 0;
        }

        var normalizedProtected = string.IsNullOrWhiteSpace(protectReleaseDir)
            ? null
            : Path.GetFullPath(protectReleaseDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        var dirs = new DirectoryInfo(releasesRoot)
            .GetDirectories()
            .OrderByDescending(d => d.LastWriteTimeUtc)
            .ToList();

        var removed = 0;
        var kept = 0;
        foreach (var dir in dirs)
        {
            var fullPath = dir.FullName.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (normalizedProtected is not null &&
                string.Equals(fullPath, normalizedProtected, StringComparison.OrdinalIgnoreCase))
            {
                kept++;
                continue;
            }

            if (kept < keepLatestCount)
            {
                kept++;
                continue;
            }

            try
            {
                dir.Delete(recursive: true);
                removed++;
                log?.Invoke($"Pruned old launcher release directory: {dir.Name}");
            }
            catch
            {
                // Ignore locked/old directories and retry on next update.
            }
        }

        return removed;
    }

    internal static void ReplaceFileWithRetry(
        string sourceNewFile,
        string destinationFile,
        string? backupPath,
        int maxRetries,
        int retryDelayMs,
        Action<string>? log = null)
    {
        Exception? lastException = null;
        var attempts = Math.Max(1, maxRetries);

        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            try
            {
                if (File.Exists(destinationFile))
                {
                    if (!string.IsNullOrWhiteSpace(backupPath))
                    {
                        SafeDeleteFile(backupPath);
                        File.Replace(sourceNewFile, destinationFile, backupPath, ignoreMetadataErrors: true);
                    }
                    else
                    {
                        File.Move(sourceNewFile, destinationFile, overwrite: true);
                    }
                }
                else
                {
                    File.Move(sourceNewFile, destinationFile, overwrite: true);
                }

                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                lastException = ex;
                log?.Invoke($"File lock / antivirus retry {attempt}/{attempts} for {Path.GetFileName(destinationFile)}: {ex.Message}");
                if (attempt < attempts)
                {
                    Thread.Sleep(Math.Max(10, retryDelayMs));
                }
            }
        }

        throw new IOException(
            $"Could not replace {destinationFile} after {attempts} attempts (file may be locked by another process or antivirus scan): {lastException?.Message}",
            lastException);
    }

    private static void RecordFailureState(string installRoot, LauncherUpdatePlan plan, string errorMessage)
    {
        try
        {
            var state = LoadInstallState(installRoot) ?? new LauncherInstallState
            {
                InstallRoot = installRoot,
                CurrentVersion = plan.CurrentVersion,
                Channel = plan.Channel
            };
            state.PendingVerification = false;
            state.PendingTargetVersion = null;
            state.LastUpdateStatus = "failed";
            state.LastUpdateError = errorMessage;
            state.UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O");
            SaveInstallState(installRoot, state);
        }
        catch
        {
            // Never mask the primary error during state recording.
        }
    }

    private static bool SafeDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
                return true;
            }
        }
        catch
        {
            // Ignore cleanup failure.
        }

        return false;
    }
}

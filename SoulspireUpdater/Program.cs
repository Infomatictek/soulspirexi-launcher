using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SoulspireUpdater;

/// <summary>
/// Standalone, zero-admin atomic updater & rollback executable for SoulspireXI Launcher.
/// Runs outside the active installation directory (staged in %TEMP%), waits for the parent
/// launcher process to exit, re-verifies SHA-256 + Windows PE header, performs an atomic
/// backup-and-replace with file-lock/AV retry handling, rolls back automatically on error,
/// prunes old releases, and restarts SoulspireLauncher.exe cleanly.
/// </summary>
internal static class Program
{
    private const string CanonicalLauncherExeName = "SoulspireLauncher.exe";
    private const string CanonicalUpdaterExeName = "SoulspireUpdater.exe";
    private const string InstallStateFileName = "install-state.json";
    private const string RollbackBackupFileName = "SoulspireLauncher.prev.exe";
    private const string JustUpdatedArg = "--just-updated";
    private const string RolledBackArg = "--rolled-back";
    private const string UpdateFailedArg = "--update-failed";
    private const int DefaultRetainedReleases = 2;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public static int Main(string[] args)
    {
        string? mode = null;
        string? planPath = null;
        string? installRootArg = null;
        int parentPid = 0;

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if (arg.Equals("--apply", StringComparison.OrdinalIgnoreCase))
            {
                mode = "apply";
            }
            else if (arg.Equals("--rollback", StringComparison.OrdinalIgnoreCase))
            {
                mode = "rollback";
            }
            else if (arg.Equals("--plan", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                planPath = args[++i];
            }
            else if (arg.Equals("--install-root", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                installRootArg = args[++i];
            }
            else if (arg.Equals("--parent-pid", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                int.TryParse(args[++i], out parentPid);
            }
        }

        if (string.Equals(mode, "apply", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(planPath))
        {
            return RunApply(planPath, parentPid);
        }

        if (string.Equals(mode, "rollback", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(installRootArg))
        {
            return RunRollback(installRootArg, parentPid);
        }

        return 2;
    }

    private static int RunApply(string planPath, int cliParentPid)
    {
        UpdatePlan? plan;
        try
        {
            var json = File.ReadAllText(planPath, Encoding.UTF8);
            plan = JsonSerializer.Deserialize<UpdatePlan>(json, JsonOptions);
            if (plan is null)
            {
                return 3;
            }
        }
        catch
        {
            return 3;
        }

        var installRoot = !string.IsNullOrWhiteSpace(plan.InstallRoot)
            ? Path.GetFullPath(plan.InstallRoot)
            : Path.GetFullPath(Path.GetDirectoryName(plan.TargetExePath) ?? string.Empty);
        var logFile = Path.Combine(installRoot, "logs", "updater.log");
        void Log(string msg) => AppendLog(logFile, msg);

        var pid = cliParentPid > 0 ? cliParentPid : plan.ParentProcessId;
        Log($"Starting apply operation: {plan.CurrentVersion} -> {plan.TargetVersion} (channel={plan.Channel}, parentPid={pid}).");
        WaitForProcessExit(pid, TimeSpan.FromSeconds(45), Log);

        var targetExePath = ResolveCanonicalTargetExe(plan.TargetExePath);
        var pendingNewExePath = targetExePath + ".new";
        var rollbackDir = Path.Combine(installRoot, "rollback");
        var rollbackBackupPath = Path.Combine(rollbackDir, RollbackBackupFileName);
        var releaseDir = Path.Combine(installRoot, "releases", SanitizeVersionFolder(plan.TargetVersion));
        string? preUpdateSha = null;
        var backupCreated = false;

        try
        {
            // 1. Re-verify staged executable integrity BEFORE modifying any live file
            if (string.IsNullOrWhiteSpace(plan.StagedExePath) || !File.Exists(plan.StagedExePath))
            {
                throw new FileNotFoundException("Staged launcher executable not found.", plan.StagedExePath);
            }

            if (!HasPeHeader(plan.StagedExePath))
            {
                throw new InvalidDataException("Staged launcher executable failed Windows PE header verification.");
            }

            var actualExeSha = ComputeSha256Hex(plan.StagedExePath);
            if (!string.IsNullOrWhiteSpace(plan.ExpectedExeSha256) &&
                !string.Equals(actualExeSha, plan.ExpectedExeSha256.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    $"Staged executable SHA-256 mismatch: expected {plan.ExpectedExeSha256}, got {actualExeSha}.");
            }

            if (!string.IsNullOrWhiteSpace(plan.StagedUpdaterPath) && File.Exists(plan.StagedUpdaterPath))
            {
                var actualUpdaterSha = ComputeSha256Hex(plan.StagedUpdaterPath);
                if (!string.IsNullOrWhiteSpace(plan.ExpectedUpdaterSha256) &&
                    !string.Equals(actualUpdaterSha, plan.ExpectedUpdaterSha256.Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        $"Staged updater SHA-256 mismatch: expected {plan.ExpectedUpdaterSha256}, got {actualUpdaterSha}.");
                }
            }

            Directory.CreateDirectory(installRoot);
            Directory.CreateDirectory(releaseDir);
            Directory.CreateDirectory(rollbackDir);

            // 2. Copy verified binary into versioned releases/<version>/
            var releaseExePath = Path.Combine(releaseDir, CanonicalLauncherExeName);
            File.Copy(plan.StagedExePath, releaseExePath, overwrite: true);
            if (!string.Equals(ComputeSha256Hex(releaseExePath), actualExeSha, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Versioned release copy SHA-256 mismatch.");
            }

            // 3. Back up current working launcher to rollback/SoulspireLauncher.prev.exe (with lock/AV retries)
            if (File.Exists(targetExePath))
            {
                preUpdateSha = BackupFileWithRetry(targetExePath, rollbackBackupPath, maxRetries: 25, retryDelayMs: 400, Log);
                backupCreated = true;
                Log($"Verified rollback backup saved ({preUpdateSha[..12]}).");
            }

            // 4. Copy to same-volume .new and atomically replace targetExePath with lock/AV retries
            File.Copy(releaseExePath, pendingNewExePath, overwrite: true);
            if (!string.Equals(ComputeSha256Hex(pendingNewExePath), actualExeSha, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Same-volume staged executable SHA-256 mismatch.");
            }

            var transientSwapBak = targetExePath + ".swap-bak";
            ReplaceFileWithRetry(pendingNewExePath, targetExePath, transientSwapBak, maxRetries: 25, retryDelayMs: 400, Log);
            SafeDeleteFile(transientSwapBak);

            if (!string.Equals(ComputeSha256Hex(targetExePath), actualExeSha, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Post-swap live executable SHA-256 mismatch.");
            }

            // 5. Update stored SoulspireUpdater.exe safely (this process runs from temp staging dir)
            if (!string.IsNullOrWhiteSpace(plan.StagedUpdaterPath) && File.Exists(plan.StagedUpdaterPath))
            {
                var releaseUpdaterPath = Path.Combine(releaseDir, CanonicalUpdaterExeName);
                File.Copy(plan.StagedUpdaterPath, releaseUpdaterPath, overwrite: true);

                var targetUpdaterPath = Path.Combine(installRoot, CanonicalUpdaterExeName);
                var pendingUpdaterPath = targetUpdaterPath + ".new";
                File.Copy(releaseUpdaterPath, pendingUpdaterPath, overwrite: true);
                ReplaceFileWithRetry(pendingUpdaterPath, targetUpdaterPath, backupPath: null, maxRetries: 15, retryDelayMs: 300, Log);
            }

            // 6. Persist install-state.json & prune old release folders
            var existingState = LoadInstallState(installRoot);
            var updatedState = new InstallState
            {
                InstallMode = existingState?.InstallMode ?? "per-user",
                InstallRoot = installRoot,
                Channel = string.IsNullOrWhiteSpace(plan.Channel) ? "stable" : plan.Channel,
                CurrentVersion = plan.TargetVersion,
                CurrentReleaseDir = releaseDir,
                ActiveExecutableSha256 = actualExeSha,
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
            PruneOldReleases(installRoot, DefaultRetainedReleases, releaseDir, Log);

            var restartArgs = string.IsNullOrWhiteSpace(plan.RestartArguments)
                ? $"{JustUpdatedArg} --updated-from \"{plan.CurrentVersion}\" --updated-to \"{plan.TargetVersion}\""
                : plan.RestartArguments;
            Log($"Update succeeded. Restarting {targetExePath} {restartArgs}");
            StartLauncher(targetExePath, restartArgs);
            return 0;
        }
        catch (Exception ex)
        {
            SafeDeleteFile(pendingNewExePath);
            Log($"Update failed: {ex.Message}");

            var rolledBack = false;
            if (backupCreated && File.Exists(rollbackBackupPath))
            {
                try
                {
                    var restoreTmp = targetExePath + ".restore";
                    File.Copy(rollbackBackupPath, restoreTmp, overwrite: true);
                    ReplaceFileWithRetry(restoreTmp, targetExePath, backupPath: null, maxRetries: 15, retryDelayMs: 300, Log);
                    rolledBack = true;
                    Log($"Automatic rollback restored previous launcher ({plan.CurrentVersion}).");
                }
                catch (Exception rbEx)
                {
                    Log($"Rollback error: {rbEx.Message}");
                }
            }

            var state = LoadInstallState(installRoot) ?? new InstallState
            {
                InstallRoot = installRoot,
                CurrentVersion = plan.CurrentVersion,
                Channel = plan.Channel
            };
            state.PendingVerification = false;
            state.PendingTargetVersion = null;
            state.LastUpdateStatus = rolledBack ? "failed-rolled-back" : "failed";
            state.LastUpdateError = ex.Message;
            state.UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O");
            SaveInstallState(installRoot, state);

            if (File.Exists(targetExePath))
            {
                StartLauncher(targetExePath, UpdateFailedArg);
            }

            return 1;
        }
    }

    private static int RunRollback(string installRoot, int parentPid)
    {
        var fullRoot = Path.GetFullPath(installRoot);
        var logFile = Path.Combine(fullRoot, "logs", "updater.log");
        void Log(string msg) => AppendLog(logFile, msg);

        Log($"Starting rollback in {fullRoot} (parentPid={parentPid}).");
        WaitForProcessExit(parentPid, TimeSpan.FromSeconds(45), Log);

        var targetExePath = Path.Combine(fullRoot, CanonicalLauncherExeName);
        var state = LoadInstallState(fullRoot);
        if (state is null || string.IsNullOrWhiteSpace(state.PreviousBackupPath) || !File.Exists(state.PreviousBackupPath))
        {
            Log("Rollback aborted: no previous backup recorded or file missing.");
            if (File.Exists(targetExePath))
            {
                StartLauncher(targetExePath, UpdateFailedArg);
            }
            return 1;
        }

        var restoreTmp = targetExePath + ".rollback-new";
        try
        {
            var actualSha = ComputeSha256Hex(state.PreviousBackupPath);
            if (!string.IsNullOrWhiteSpace(state.PreviousBackupSha256) &&
                !string.Equals(actualSha, state.PreviousBackupSha256.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Rollback backup SHA-256 verification failed.");
            }

            File.Copy(state.PreviousBackupPath, restoreTmp, overwrite: true);
            ReplaceFileWithRetry(restoreTmp, targetExePath, backupPath: null, maxRetries: 25, retryDelayMs: 400, Log);

            var restoredVersion = string.IsNullOrWhiteSpace(state.PreviousVersion) ? "previous" : state.PreviousVersion!;
            state.CurrentVersion = restoredVersion;
            state.ActiveExecutableSha256 = actualSha;
            state.PendingVerification = false;
            state.PendingTargetVersion = null;
            state.LastUpdateStatus = "rolled-back";
            state.LastUpdateError = null;
            state.UpdatedAtUtc = DateTimeOffset.UtcNow.ToString("O");
            SaveInstallState(fullRoot, state);

            Log($"Rollback complete -> {restoredVersion}. Restarting launcher.");
            StartLauncher(targetExePath, $"{RolledBackArg} --updated-to \"{restoredVersion}\"");
            return 0;
        }
        catch (Exception ex)
        {
            SafeDeleteFile(restoreTmp);
            Log($"Rollback failed: {ex.Message}");
            if (File.Exists(targetExePath))
            {
                StartLauncher(targetExePath, UpdateFailedArg);
            }
            return 1;
        }
    }

    private static void WaitForProcessExit(int pid, TimeSpan timeout, Action<string> log)
    {
        if (pid <= 0)
        {
            return;
        }

        try
        {
            using var proc = Process.GetProcessById(pid);
            if (!proc.HasExited)
            {
                log($"Waiting for launcher PID {pid} to exit...");
                proc.WaitForExit((int)timeout.TotalMilliseconds);
            }
        }
        catch (ArgumentException)
        {
            // Already exited.
        }
        catch (Exception ex)
        {
            log($"Process wait note: {ex.Message}");
        }

        // Small grace period for Windows file handles / Defender scan release
        Thread.Sleep(350);
    }

    private static string BackupFileWithRetry(
        string sourceFile,
        string rollbackBackupPath,
        int maxRetries,
        int retryDelayMs,
        Action<string> log)
    {
        Exception? last = null;
        var tmpBackup = rollbackBackupPath + ".tmp";
        for (var i = 1; i <= maxRetries; i++)
        {
            try
            {
                var sha = ComputeSha256Hex(sourceFile);
                File.Copy(sourceFile, tmpBackup, overwrite: true);
                if (!string.Equals(ComputeSha256Hex(tmpBackup), sha, StringComparison.OrdinalIgnoreCase))
                {
                    throw new IOException("Rollback backup SHA-256 verification failed.");
                }
                File.Move(tmpBackup, rollbackBackupPath, overwrite: true);
                return sha;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                SafeDeleteFile(tmpBackup);
                last = ex;
                log($"Lock/AV retry {i}/{maxRetries} backing up {Path.GetFileName(sourceFile)}: {ex.Message}");
                if (i < maxRetries)
                {
                    Thread.Sleep(retryDelayMs);
                }
            }
        }

        throw new IOException($"Could not back up {sourceFile} after {maxRetries} retries: {last?.Message}", last);
    }

    private static void ReplaceFileWithRetry(
        string sourceNewFile,
        string destinationFile,
        string? backupPath,
        int maxRetries,
        int retryDelayMs,
        Action<string> log)
    {
        Exception? last = null;
        for (var i = 1; i <= maxRetries; i++)
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
                last = ex;
                log($"Lock/AV retry {i}/{maxRetries} replacing {Path.GetFileName(destinationFile)}: {ex.Message}");
                if (i < maxRetries)
                {
                    Thread.Sleep(retryDelayMs);
                }
            }
        }

        throw new IOException($"Could not replace {destinationFile} after {maxRetries} retries: {last?.Message}", last);
    }

    private static void PruneOldReleases(string installRoot, int keepLatestCount, string protectReleaseDir, Action<string> log)
    {
        var releasesRoot = Path.Combine(installRoot, "releases");
        if (!Directory.Exists(releasesRoot))
        {
            return;
        }

        var normalizedProtect = Path.GetFullPath(protectReleaseDir).TrimEnd('\\', '/');
        var dirs = new DirectoryInfo(releasesRoot)
            .GetDirectories()
            .OrderByDescending(d => d.LastWriteTimeUtc)
            .ToList();

        var kept = 0;
        foreach (var dir in dirs)
        {
            var full = dir.FullName.TrimEnd('\\', '/');
            if (string.Equals(full, normalizedProtect, StringComparison.OrdinalIgnoreCase) || kept < keepLatestCount)
            {
                kept++;
                continue;
            }

            try
            {
                dir.Delete(recursive: true);
                log($"Pruned old release directory: {dir.Name}");
            }
            catch
            {
                // Ignore best-effort cleanup errors.
            }
        }
    }

    private static void StartLauncher(string exePath, string arguments)
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = exePath,
                Arguments = arguments,
                WorkingDirectory = Path.GetDirectoryName(exePath) ?? string.Empty,
                UseShellExecute = true
            });
        }
        catch
        {
            // Nothing more we can do if shell launch fails.
        }
    }

    private static string ResolveCanonicalTargetExe(string path)
    {
        var fileName = Path.GetFileName(path);
        if (string.Equals(fileName, "OverlordsLauncher.exe", StringComparison.OrdinalIgnoreCase))
        {
            return Path.Combine(Path.GetDirectoryName(path) ?? string.Empty, CanonicalLauncherExeName);
        }

        return path;
    }

    private static string SanitizeVersionFolder(string version)
    {
        var raw = string.IsNullOrWhiteSpace(version) ? "unknown" : version.Trim().TrimStart('v', 'V');
        var sb = new StringBuilder(raw.Length);
        foreach (var ch in raw)
        {
            sb.Append(char.IsLetterOrDigit(ch) || ch is '.' or '-' or '_' ? ch : '_');
        }
        var res = sb.ToString().Trim('.', '_');
        return string.IsNullOrWhiteSpace(res) ? "unknown" : res;
    }

    private static bool HasPeHeader(string filePath)
    {
        Span<byte> hdr = stackalloc byte[2];
        using var fs = File.OpenRead(filePath);
        return fs.Read(hdr) == 2 && hdr[0] == (byte)'M' && hdr[1] == (byte)'Z';
    }

    private static string ComputeSha256Hex(string filePath)
    {
        using var fs = File.OpenRead(filePath);
        return Convert.ToHexString(SHA256.HashData(fs)).ToLowerInvariant();
    }

    private static InstallState? LoadInstallState(string installRoot)
    {
        var path = Path.Combine(installRoot, InstallStateFileName);
        if (!File.Exists(path)) return null;
        try
        {
            return JsonSerializer.Deserialize<InstallState>(File.ReadAllText(path, Encoding.UTF8), JsonOptions);
        }
        catch
        {
            return null;
        }
    }

    private static void SaveInstallState(string installRoot, InstallState state)
    {
        Directory.CreateDirectory(installRoot);
        var path = Path.Combine(installRoot, InstallStateFileName);
        var tmp = path + $".{Environment.ProcessId}.tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(state, JsonOptions), Encoding.UTF8);
        File.Move(tmp, path, overwrite: true);
    }

    private static void AppendLog(string logFile, string message)
    {
        try
        {
            var dir = Path.GetDirectoryName(logFile);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.AppendAllText(logFile, $"[{DateTimeOffset.UtcNow:O}] {message}{Environment.NewLine}", Encoding.UTF8);
        }
        catch
        {
            // Never crash updater on log failure.
        }
    }

    private static void SafeDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // Ignore cleanup failure.
        }
    }

    private sealed class UpdatePlan
    {
        [JsonPropertyName("parentProcessId")] public int ParentProcessId { get; set; }
        [JsonPropertyName("installRoot")] public string InstallRoot { get; set; } = string.Empty;
        [JsonPropertyName("targetExePath")] public string TargetExePath { get; set; } = string.Empty;
        [JsonPropertyName("stagedExePath")] public string StagedExePath { get; set; } = string.Empty;
        [JsonPropertyName("expectedExeSha256")] public string ExpectedExeSha256 { get; set; } = string.Empty;
        [JsonPropertyName("stagedUpdaterPath")] public string? StagedUpdaterPath { get; set; }
        [JsonPropertyName("expectedUpdaterSha256")] public string? ExpectedUpdaterSha256 { get; set; }
        [JsonPropertyName("currentVersion")] public string CurrentVersion { get; set; } = string.Empty;
        [JsonPropertyName("targetVersion")] public string TargetVersion { get; set; } = string.Empty;
        [JsonPropertyName("channel")] public string Channel { get; set; } = "stable";
        [JsonPropertyName("restartArguments")] public string RestartArguments { get; set; } = string.Empty;
    }

    private sealed class InstallState
    {
        [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; } = 1;
        [JsonPropertyName("installMode")] public string InstallMode { get; set; } = "per-user";
        [JsonPropertyName("installRoot")] public string InstallRoot { get; set; } = string.Empty;
        [JsonPropertyName("channel")] public string Channel { get; set; } = "stable";
        [JsonPropertyName("currentVersion")] public string CurrentVersion { get; set; } = string.Empty;
        [JsonPropertyName("currentReleaseDir")] public string CurrentReleaseDir { get; set; } = string.Empty;
        [JsonPropertyName("activeExecutableSha256")] public string ActiveExecutableSha256 { get; set; } = string.Empty;
        [JsonPropertyName("previousVersion")] public string? PreviousVersion { get; set; }
        [JsonPropertyName("previousBackupPath")] public string? PreviousBackupPath { get; set; }
        [JsonPropertyName("previousBackupSha256")] public string? PreviousBackupSha256 { get; set; }
        [JsonPropertyName("pendingVerification")] public bool PendingVerification { get; set; }
        [JsonPropertyName("pendingTargetVersion")] public string? PendingTargetVersion { get; set; }
        [JsonPropertyName("lastUpdateStatus")] public string LastUpdateStatus { get; set; } = "idle";
        [JsonPropertyName("lastUpdateError")] public string? LastUpdateError { get; set; }
        [JsonPropertyName("updatedAtUtc")] public string UpdatedAtUtc { get; set; } = string.Empty;
    }
}

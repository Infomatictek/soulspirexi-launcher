using System.Diagnostics;
using System.IO;
using System.Text;

namespace SoulspireLauncher.Services;

public sealed class ShortcutMigrationResult
{
    public int MigratedCount { get; init; }
    public List<string> MigratedPaths { get; init; } = [];
}

/// <summary>
/// Safely migrates legacy Windows Desktop/Start Menu shortcuts targeting OverlordsLauncher.exe
/// to SoulspireLauncher.exe ("SoulspireXI Launcher"), without disturbing unrelated shortcuts.
/// </summary>
public sealed class ShortcutMigrationService
{
    public const string CanonicalShortcutName = "SoulspireXI Launcher.lnk";
    public const string CanonicalDescription = "SoulspireXI Launcher";
    public const string LegacyExecutableName = "OverlordsLauncher.exe";
    public const string CanonicalExecutableName = "SoulspireLauncher.exe";

    public static IReadOnlyList<string> GetDefaultShortcutSearchDirectories()
    {
        var dirs = new List<string>();
        AddIfValid(dirs, Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
        AddIfValid(dirs, Environment.GetFolderPath(Environment.SpecialFolder.StartMenu));
        AddIfValid(dirs, Environment.GetFolderPath(Environment.SpecialFolder.Programs));
        return dirs;
    }

    public static bool IsLegacyShortcutName(string fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName))
        {
            return false;
        }

        var stem = Path.GetFileNameWithoutExtension(fileName);
        return stem.Contains("Overlords", StringComparison.OrdinalIgnoreCase);
    }

    public static string ResolveMigratedShortcutPath(string existingShortcutPath)
    {
        var dir = Path.GetDirectoryName(existingShortcutPath) ?? string.Empty;
        var fileName = Path.GetFileName(existingShortcutPath);
        return IsLegacyShortcutName(fileName)
            ? Path.Combine(dir, CanonicalShortcutName)
            : existingShortcutPath;
    }

    public static string BuildMigrationPowerShellScript(
        IEnumerable<string> searchDirectories,
        string canonicalExePath)
    {
        var escapedExe = EscapePowerShellSingleQuoted(canonicalExePath);
        var escapedWorkDir = EscapePowerShellSingleQuoted(Path.GetDirectoryName(canonicalExePath) ?? string.Empty);
        var dirArray = string.Join(
            ", ",
            searchDirectories
                .Where(d => !string.IsNullOrWhiteSpace(d))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Select(d => $"'{EscapePowerShellSingleQuoted(d)}'"));

        return string.Join(
            "\r\n",
            "$ErrorActionPreference = 'SilentlyContinue'",
            "$shell = New-Object -ComObject WScript.Shell",
            $"$canonicalExe = '{escapedExe}'",
            $"$workDir = '{escapedWorkDir}'",
            $"$dirs = @({dirArray})",
            "foreach ($dir in $dirs) {",
            "  if (-not (Test-Path $dir)) { continue }",
            "  Get-ChildItem -Path $dir -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {",
            "    try {",
            "      $lnk = $shell.CreateShortcut($_.FullName)",
            "      $target = [string]$lnk.TargetPath",
            "      if ($target -and ([System.IO.Path]::GetFileName($target) -ieq 'OverlordsLauncher.exe')) {",
            "        $destPath = $_.FullName",
            "        if ($_.BaseName -imatch 'Overlords') {",
            "          $destPath = Join-Path $_.DirectoryName 'SoulspireXI Launcher.lnk'",
            "        }",
            "        $updated = $shell.CreateShortcut($destPath)",
            "        $updated.TargetPath = $canonicalExe",
            "        $updated.WorkingDirectory = $workDir",
            "        $updated.Description = 'SoulspireXI Launcher'",
            "        $updated.IconLocation = \"$canonicalExe,0\"",
            "        $updated.Arguments = $lnk.Arguments",
            "        $updated.Save()",
            "        if ($destPath -ine $_.FullName -and (Test-Path $destPath)) {",
            "          Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue",
            "        }",
            "        Write-Output $destPath",
            "      }",
            "    } catch { }",
            "  }",
            "}");
    }

    public static string BuildCreateShortcutPowerShellScript(string shortcutPath, string canonicalExePath)
    {
        var escapedShortcut = EscapePowerShellSingleQuoted(shortcutPath);
        var escapedExe = EscapePowerShellSingleQuoted(canonicalExePath);
        var escapedWorkDir = EscapePowerShellSingleQuoted(Path.GetDirectoryName(canonicalExePath) ?? string.Empty);

        return string.Join(
            "\r\n",
            "$ErrorActionPreference = 'Stop'",
            "$shell = New-Object -ComObject WScript.Shell",
            $"$lnk = $shell.CreateShortcut('{escapedShortcut}')",
            $"$lnk.TargetPath = '{escapedExe}'",
            $"$lnk.WorkingDirectory = '{escapedWorkDir}'",
            "$lnk.Description = 'SoulspireXI Launcher'",
            $"$lnk.IconLocation = '{escapedExe},0'",
            "$lnk.Save()");
    }

    public ShortcutMigrationResult MigrateLegacyShortcuts(
        string canonicalExePath,
        IEnumerable<string>? searchDirectoriesOverride = null)
    {
        if (!OperatingSystem.IsWindows() ||
            string.IsNullOrWhiteSpace(canonicalExePath) ||
            !File.Exists(canonicalExePath))
        {
            return new ShortcutMigrationResult();
        }

        var dirs = (searchDirectoriesOverride ?? GetDefaultShortcutSearchDirectories())
            .Where(d => !string.IsNullOrWhiteSpace(d) && Directory.Exists(d))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (dirs.Count == 0)
        {
            return new ShortcutMigrationResult();
        }

        try
        {
            var script = BuildMigrationPowerShellScript(dirs, canonicalExePath);
            var output = RunEncodedPowerShell(script);
            var migrated = output
                .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

            return new ShortcutMigrationResult
            {
                MigratedCount = migrated.Count,
                MigratedPaths = migrated
            };
        }
        catch
        {
            return new ShortcutMigrationResult();
        }
    }

    public bool CreateDesktopShortcut(string canonicalExePath)
    {
        if (!OperatingSystem.IsWindows() ||
            string.IsNullOrWhiteSpace(canonicalExePath) ||
            !File.Exists(canonicalExePath))
        {
            return false;
        }

        var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (string.IsNullOrWhiteSpace(desktop) || !Directory.Exists(desktop))
        {
            return false;
        }

        var shortcutPath = Path.Combine(desktop, CanonicalShortcutName);
        var script = BuildCreateShortcutPowerShellScript(shortcutPath, canonicalExePath);
        RunEncodedPowerShell(script);
        return File.Exists(shortcutPath);
    }

    private static string RunEncodedPowerShell(string script)
    {
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        using var process = Process.Start(new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {encoded}",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        });

        if (process is null)
        {
            return string.Empty;
        }

        var stdout = process.StandardOutput.ReadToEnd();
        process.WaitForExit(10000);
        return stdout;
    }

    private static void AddIfValid(List<string> dirs, string? dir)
    {
        if (!string.IsNullOrWhiteSpace(dir) && !dirs.Contains(dir, StringComparer.OrdinalIgnoreCase))
        {
            dirs.Add(dir);
        }
    }

    private static string EscapePowerShellSingleQuoted(string value) =>
        value.Replace("'", "''");
}

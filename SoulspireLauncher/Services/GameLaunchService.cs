using System.Diagnostics;
using System.IO;
using System.Text;

namespace SoulspireLauncher.Services;

public sealed class GameLaunchService
{
    public Process LaunchAshita(string ashitaDir, string bootConfigFileName = AshitaConfigGenerator.BootConfigFileName)
    {
        var ashitaCliPath = Path.Combine(ashitaDir, "Ashita-cli.exe");
        if (!File.Exists(ashitaCliPath))
        {
            throw new FileNotFoundException("Ashita-cli.exe was not found in the configured Ashita folder.", ashitaCliPath);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = ashitaCliPath,
            Arguments = bootConfigFileName,
            WorkingDirectory = ashitaDir,
            UseShellExecute = true
        };

        var process = Process.Start(startInfo);
        return process ?? throw new InvalidOperationException("Failed to start Ashita-cli.exe.");
    }

    public static string? ResolveModernClientExecutable(string modernClientDir)
    {
        if (string.IsNullOrWhiteSpace(modernClientDir))
        {
            return null;
        }

        var branded = Path.Combine(modernClientDir, "SoulspireClient.exe");
        if (File.Exists(branded))
        {
            return branded;
        }

        var upstream = Path.Combine(modernClientDir, "VanaCore.exe");
        return File.Exists(upstream) ? upstream : null;
    }

    /// <summary>
    /// Builds ProcessStartInfo for Soulspire Client (VanaCore) using --password-stdin so credentials
    /// are NEVER exposed in OS command-line arguments (PEB.CommandLine) or written to disk.
    /// </summary>
    public static ProcessStartInfo BuildModernClientStartInfo(
        string modernClientDir,
        string executablePath,
        string serverHost,
        string? username,
        string iniFileName,
        string language,
        bool usePasswordStdin)
    {
        var args = new List<string>
        {
            "--ini", QuoteArg(iniFileName),
            "--server", QuoteArg(serverHost.Trim())
        };

        if (!string.IsNullOrWhiteSpace(username))
        {
            args.Add("--user");
            args.Add(QuoteArg(username.Trim()));
        }

        if (usePasswordStdin)
        {
            args.Add("--password-stdin");
        }

        if (string.Equals(language, "EU", StringComparison.OrdinalIgnoreCase))
        {
            args.Add("--lang");
            args.Add("EU");
        }
        else if (string.Equals(language, "JP", StringComparison.OrdinalIgnoreCase))
        {
            args.Add("--lang");
            args.Add("JP");
        }

        return new ProcessStartInfo
        {
            FileName = executablePath,
            Arguments = string.Join(" ", args),
            WorkingDirectory = modernClientDir,
            UseShellExecute = false,
            RedirectStandardInput = usePasswordStdin,
            CreateNoWindow = false
        };
    }

    public Process LaunchModernClient(
        string modernClientDir,
        string serverHost,
        string? username,
        string? password,
        string iniFileName,
        string language)
    {
        var executablePath = ResolveModernClientExecutable(modernClientDir);
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            throw new FileNotFoundException(
                "Soulspire Client (SoulspireClient.exe / VanaCore.exe) was not found in the isolated ModernClient folder. " +
                "Download the Testing artifact from Infomatictek/soulspirexi-client or switch back to Classic (Ashita v4).",
                Path.Combine(modernClientDir ?? string.Empty, "VanaCore.exe"));
        }

        var hasCredentials = !string.IsNullOrWhiteSpace(username) && !string.IsNullOrEmpty(password);
        var startInfo = BuildModernClientStartInfo(
            modernClientDir,
            executablePath,
            serverHost,
            username,
            iniFileName,
            language,
            usePasswordStdin: hasCredentials);

        var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Failed to start Soulspire Client (VanaCore).");

        if (hasCredentials)
        {
            using var writer = new StreamWriter(process.StandardInput.BaseStream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), leaveOpen: false);
            writer.Write(password);
            writer.Write('\n');
            writer.Flush();
        }

        return process;
    }

    private static string QuoteArg(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        return value.IndexOfAny([' ', '\t', '"']) >= 0
            ? "\"" + value.Replace("\"", "\\\"") + "\""
            : value;
    }
}

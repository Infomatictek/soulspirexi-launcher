using System.Net;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed record EffectiveAshitaInputSettings(
    bool BlockBindsDuringInput,
    bool WindowsKeyEnabled,
    bool TestingQolApplied,
    string Reason);

public static class TestingEnvironmentQolPolicy
{
    private static readonly HashSet<string> StagingHostTokens = new(StringComparer.OrdinalIgnoreCase)
    {
        "staging",
        "stg",
        "stage",
        "test",
        "testing",
        "dev",
        "sandbox",
        "qa",
        "preprod",
        "canary",
        "local"
    };

    private static readonly string[] StagingDomainSuffixes =
    [
        ".local",
        ".internal"
    ];

    public static bool IsTestingChannel(UpdateChannel channel) =>
        channel != UpdateChannel.Stable;

    public static bool IsTestingManifestChannel(string? manifestChannel) =>
        !string.IsNullOrWhiteSpace(manifestChannel) &&
        !manifestChannel.Trim().Equals("stable", StringComparison.OrdinalIgnoreCase);

    public static bool IsStagingServer(string? serverHost, string? serverName = null)
    {
        if (!string.IsNullOrWhiteSpace(serverName) && ContainsStagingToken(serverName))
        {
            return true;
        }

        var host = NormalizeHost(serverHost);
        if (string.IsNullOrWhiteSpace(host))
        {
            return false;
        }

        if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        // Only loopback (127.0.0.1 / ::1) is treated as an explicit local dev endpoint by IP alone.
        // Private LAN/VPN IPs (10.x, 172.16-31.x, 192.168.x, 100.64.x) alone must NOT classify a Stable
        // session as Testing unless a Testing channel or explicit staging/dev server name is configured.
        if (IPAddress.TryParse(host, out var ip))
        {
            return IPAddress.IsLoopback(ip) || (ip.IsIPv4MappedToIPv6 && IPAddress.IsLoopback(ip.MapToIPv4()));
        }

        foreach (var suffix in StagingDomainSuffixes)
        {
            if (host.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return ContainsStagingToken(host);
    }

    public static bool IsTestingEnvironment(
        LauncherSettings settings,
        string? serverHost,
        string? manifestChannel = null,
        string? serverName = null) =>
        IsTestingChannel(settings.UpdateChannel) ||
        IsTestingManifestChannel(manifestChannel) ||
        IsStagingServer(serverHost, serverName);

    public static bool ShouldApplyTestingQol(
        LauncherSettings settings,
        string? serverHost,
        string? manifestChannel = null,
        string? serverName = null) =>
        settings.EnableAutomaticTestingQolSettings &&
        IsTestingEnvironment(settings, serverHost, manifestChannel, serverName);

    public static EffectiveAshitaInputSettings ResolveInputSettings(
        LauncherSettings settings,
        string? serverHost,
        string? manifestChannel = null,
        string? serverName = null)
    {
        var isTestingChannel = IsTestingChannel(settings.UpdateChannel) || IsTestingManifestChannel(manifestChannel);
        var isStagingServer = IsStagingServer(serverHost, serverName);
        var isTestingEnv = isTestingChannel || isStagingServer;

        if (!isTestingEnv)
        {
            return new EffectiveAshitaInputSettings(
                BlockBindsDuringInput: settings.KeyboardBlockBindsDuringInput,
                WindowsKeyEnabled: settings.KeyboardWindowsKeyEnabled,
                TestingQolApplied: false,
                Reason: "Stable production environment");
        }

        var envReason = (isTestingChannel, isStagingServer) switch
        {
            (true, true) => $"Testing channel ({settings.UpdateChannel}) + staging server ({NormalizeHost(serverHost)})",
            (true, false) => $"Testing channel ({settings.UpdateChannel})",
            _ => $"staging server ({NormalizeHost(serverHost)})"
        };

        if (!settings.EnableAutomaticTestingQolSettings)
        {
            return new EffectiveAshitaInputSettings(
                BlockBindsDuringInput: settings.KeyboardBlockBindsDuringInput,
                WindowsKeyEnabled: settings.KeyboardWindowsKeyEnabled,
                TestingQolApplied: false,
                Reason: $"Disabled by user ({envReason})");
        }

        return new EffectiveAshitaInputSettings(
            BlockBindsDuringInput: false,
            WindowsKeyEnabled: true,
            TestingQolApplied: true,
            Reason: envReason);
    }

    private static string NormalizeHost(string? rawHost)
    {
        if (string.IsNullOrWhiteSpace(rawHost))
        {
            return string.Empty;
        }

        var trimmed = rawHost.Trim();
        if (Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) && !string.IsNullOrWhiteSpace(uri.Host))
        {
            return uri.Host.Trim('[', ']');
        }

        if (trimmed.StartsWith('[') && trimmed.Contains(']'))
        {
            var endBracket = trimmed.IndexOf(']');
            return trimmed[1..endBracket];
        }

        // Strip trailing :port for IPv4 or hostnames (skip bare IPv6 with multiple colons).
        var firstColon = trimmed.IndexOf(':');
        if (firstColon > 0 && firstColon == trimmed.LastIndexOf(':'))
        {
            return trimmed[..firstColon].Trim();
        }

        return trimmed;
    }

    private static bool ContainsStagingToken(string value)
    {
        var tokens = value.Split(['.', '-', '_', ' ', '/', ':'], StringSplitOptions.RemoveEmptyEntries);
        foreach (var token in tokens)
        {
            if (StagingHostTokens.Contains(token))
            {
                return true;
            }
        }

        return false;
    }
}

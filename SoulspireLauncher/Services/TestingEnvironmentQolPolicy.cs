using System.Net;
using System.Net.Sockets;
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
        ".lan",
        ".internal",
        ".home",
        ".ts.net"
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

        if (IPAddress.TryParse(host, out var ip))
        {
            return IsLocalOrPrivateIp(ip);
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

    private static bool IsLocalOrPrivateIp(IPAddress ip)
    {
        if (IPAddress.IsLoopback(ip))
        {
            return true;
        }

        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (ip.IsIPv4MappedToIPv6)
            {
                return IsLocalOrPrivateIp(ip.MapToIPv4());
            }

            var bytes6 = ip.GetAddressBytes();
            // fc00::/7 (Unique Local Address) or fe80::/10 (Link-Local)
            return (bytes6[0] & 0xFE) == 0xFC || (bytes6[0] == 0xFE && (bytes6[1] & 0xC0) == 0x80);
        }

        if (ip.AddressFamily != AddressFamily.InterNetwork)
        {
            return false;
        }

        var bytes = ip.GetAddressBytes();
        return bytes[0] == 10 ||
               bytes[0] == 127 ||
               (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
               (bytes[0] == 192 && bytes[1] == 168) ||
               (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
               (bytes[0] == 169 && bytes[1] == 254);
    }
}

using System.Diagnostics;
using System.Net.Sockets;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed class ServerStatusService
{
    public async Task<ServerStatus> CheckAsync(
        string host,
        int lobbyPort,
        int searchPort,
        CancellationToken cancellationToken = default)
    {
        var cleanHost = host.Trim();
        if (string.IsNullOrWhiteSpace(cleanHost))
        {
            return new ServerStatus
            {
                IsOnline = false,
                Host = host,
                SummaryText = "No server host configured"
            };
        }

        var lobbyTask = ProbePortAsync(cleanHost, lobbyPort, cancellationToken);
        var searchTask = ProbePortAsync(cleanHost, searchPort, cancellationToken);
        await Task.WhenAll(lobbyTask, searchTask).ConfigureAwait(false);

        var (lobbyOk, lobbyMs) = lobbyTask.Result;
        var (searchOk, searchMs) = searchTask.Result;

        var isOnline = lobbyOk || searchOk;
        var latency = lobbyOk ? lobbyMs : searchMs;

        string summary;
        if (lobbyOk && searchOk)
        {
            summary = $"Online ({latency} ms)";
        }
        else if (lobbyOk)
        {
            summary = $"Lobby Online ({latency} ms • Search offline)";
        }
        else if (searchOk)
        {
            summary = $"Search Online ({latency} ms • Lobby offline)";
        }
        else
        {
            summary = "Offline / Unreachable";
        }

        return new ServerStatus
        {
            IsOnline = isOnline,
            LobbyReachable = lobbyOk,
            SearchReachable = searchOk,
            LatencyMs = latency,
            Host = cleanHost,
            CheckedAt = DateTimeOffset.UtcNow,
            SummaryText = summary
        };
    }

    public async Task<ServerStatus> CheckStagingAsync(
        string host,
        int lobbyPort,
        int searchPort,
        int profilePort,
        int profileIrcPort,
        CancellationToken cancellationToken = default)
    {
        var cleanHost = host.Trim();
        if (string.IsNullOrWhiteSpace(cleanHost))
        {
            return new ServerStatus
            {
                IsOnline = false,
                Host = host,
                ProfileReachable = false,
                ProfilePortReachable = false,
                ProfileIrcPortReachable = false,
                ProfileFailureDetail = "No staging server host configured",
                SummaryText = "No staging server host configured"
            };
        }

        var lobbyTask = ProbePortAsync(cleanHost, lobbyPort, cancellationToken);
        var searchTask = ProbePortAsync(cleanHost, searchPort, cancellationToken);
        var profileTask = ProbePortAsync(cleanHost, profilePort, cancellationToken);
        var profileIrcTask = ProbePortAsync(cleanHost, profileIrcPort, cancellationToken);
        await Task.WhenAll(lobbyTask, searchTask, profileTask, profileIrcTask).ConfigureAwait(false);

        var (lobbyOk, lobbyMs) = lobbyTask.Result;
        var (searchOk, searchMs) = searchTask.Result;
        var (profileOk, profileMs) = profileTask.Result;
        var (profileIrcOk, profileIrcMs) = profileIrcTask.Result;

        var allProfileOk = profileOk && profileIrcOk;
        var missingProfilePorts = new List<string>(2);
        if (!profileOk)
        {
            missingProfilePorts.Add($"{profilePort} (Profile)");
        }
        if (!profileIrcOk)
        {
            missingProfilePorts.Add($"{profileIrcPort} (Profile IRC)");
        }

        var profileFailureDetail = missingProfilePorts.Count > 0
            ? $"Profile server unreachable on {cleanHost}: {string.Join(", ", missingProfilePorts)}"
            : null;

        var isOnline = lobbyOk && allProfileOk;
        var latency = lobbyOk
            ? lobbyMs
            : (profileOk ? profileMs : (profileIrcOk ? profileIrcMs : searchMs));

        string summary;
        if (lobbyOk && allProfileOk && searchOk)
        {
            summary = $"Online ({latency} ms • Profile OK)";
        }
        else if (lobbyOk && allProfileOk)
        {
            summary = $"Lobby & Profile Online ({latency} ms • Search offline)";
        }
        else if (lobbyOk)
        {
            var shortMissing = new List<string>(2);
            if (!profileOk) shortMissing.Add(profilePort.ToString());
            if (!profileIrcOk) shortMissing.Add(profileIrcPort.ToString());
            summary = $"Profile Offline ({string.Join("/", shortMissing)}) • Lobby {latency} ms";
        }
        else if (allProfileOk || searchOk)
        {
            summary = "Lobby Offline (Profile/Search reachable)";
        }
        else
        {
            summary = "Offline / Unreachable";
        }

        return new ServerStatus
        {
            IsOnline = isOnline,
            LobbyReachable = lobbyOk,
            SearchReachable = searchOk,
            ProfileReachable = allProfileOk,
            ProfilePortReachable = profileOk,
            ProfileIrcPortReachable = profileIrcOk,
            ProfileFailureDetail = profileFailureDetail,
            LatencyMs = latency,
            Host = cleanHost,
            CheckedAt = DateTimeOffset.UtcNow,
            SummaryText = summary
        };
    }

    private static async Task<(bool Reachable, int ElapsedMs)> ProbePortAsync(
        string host,
        int port,
        CancellationToken cancellationToken)
    {
        if (port is <= 0 or > 65535)
        {
            return (false, 0);
        }

        var sw = Stopwatch.StartNew();
        try
        {
            using var client = new TcpClient();
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(TimeSpan.FromMilliseconds(2200));
            await client.ConnectAsync(host, port, cts.Token).ConfigureAwait(false);
            sw.Stop();
            return (true, (int)Math.Max(1, sw.ElapsedMilliseconds));
        }
        catch
        {
            return (false, 0);
        }
    }
}

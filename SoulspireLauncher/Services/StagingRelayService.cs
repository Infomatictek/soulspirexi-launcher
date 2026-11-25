using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed record StagingPortRoute(
    string Label,
    int LocalPort,
    int RemotePort);

public sealed record StagingRelayConfig(
    string RemoteHost,
    IReadOnlyList<StagingPortRoute> Routes,
    int UpstreamConnectTimeoutMs = 5000)
{
    public const string LoopbackHost = "127.0.0.1";
    public const int DefaultLocalAuthPort = 54231;
    public const int DefaultLocalDataPort = 54230;
    public const int DefaultLocalViewPort = 54001;
    public const int DefaultLocalSearchPort = 54002;
    public const int DefaultLocalProfilePort = 51220;
    public const int DefaultLocalProfileIrcPort = 51240;

    public static StagingRelayConfig CreateDefault(
        string remoteHost,
        int remoteAuthPort = LauncherSettings.DefaultStagingAuthPort,
        int remoteDataPort = LauncherSettings.DefaultStagingDataPort,
        int remoteViewPort = LauncherSettings.DefaultStagingViewPort,
        int remoteSearchPort = LauncherSettings.DefaultStagingSearchPort,
        int remoteProfilePort = LauncherSettings.DefaultStagingProfilePort,
        int remoteProfileIrcPort = LauncherSettings.DefaultStagingProfileIrcPort,
        int localAuthPort = DefaultLocalAuthPort,
        int localDataPort = DefaultLocalDataPort,
        int localViewPort = DefaultLocalViewPort,
        int localSearchPort = DefaultLocalSearchPort,
        int localProfilePort = DefaultLocalProfilePort,
        int localProfileIrcPort = DefaultLocalProfileIrcPort,
        int upstreamConnectTimeoutMs = 5000)
    {
        return new StagingRelayConfig(
            remoteHost.Trim(),
            [
                new StagingPortRoute("Login Auth", localAuthPort, remoteAuthPort),
                new StagingPortRoute("Login Data", localDataPort, remoteDataPort),
                new StagingPortRoute("Login View", localViewPort, remoteViewPort),
                new StagingPortRoute("Search / AH", localSearchPort, remoteSearchPort),
                new StagingPortRoute("Profile", localProfilePort, remoteProfilePort),
                new StagingPortRoute("Profile IRC", localProfileIrcPort, remoteProfileIrcPort),
            ],
            upstreamConnectTimeoutMs);
    }

    public bool Matches(StagingRelayConfig? other)
    {
        if (other is null ||
            !string.Equals(RemoteHost, other.RemoteHost, StringComparison.OrdinalIgnoreCase) ||
            Routes.Count != other.Routes.Count)
        {
            return false;
        }

        for (var i = 0; i < Routes.Count; i++)
        {
            if (Routes[i] != other.Routes[i])
            {
                return false;
            }
        }

        return true;
    }
}

public sealed record StagingRelayStartResult(
    bool Success,
    bool AlreadyRunning,
    int? ConflictingLocalPort,
    string? ConflictingRouteLabel,
    SocketError? SocketErrorCode,
    string Message)
{
    public static StagingRelayStartResult Ok(string message, bool alreadyRunning = false) =>
        new(true, alreadyRunning, null, null, null, message);

    public static StagingRelayStartResult Invalid(string message) =>
        new(false, false, null, null, null, message);

    public static StagingRelayStartResult Conflict(
        int localPort,
        string routeLabel,
        SocketError socketError,
        string message) =>
        new(false, false, localPort, routeLabel, socketError, message);
}

public sealed record ResolvedServerConnectionPlan(
    ServerTargetMode TargetMode,
    string DisplayHost,
    string StatusProbeHost,
    int StatusProbeLobbyPort,
    int StatusProbeSearchPort,
    int StatusProbeProfilePort,
    int StatusProbeProfileIrcPort,
    string BootServerHost,
    bool BootUseHairpin,
    bool RequiresLoopbackRelay,
    StagingRelayConfig? RelayConfig,
    int MapUdpPort,
    StagingLane? StagingLane = null,
    string? StagingLaneDisplayName = null);

/// <summary>
/// Zero-privilege, in-process loopback TCP relay for SoulspireXI Staging.
/// Maps xiloader's fixed local TCP ports (127.0.0.1:54231/54230/54001/54002/51220/51240)
/// to the isolated staging server's alternate TCP ports (55231/55230/55001/55002/51221/51241)
/// without UAC elevation, without modifying Windows netsh portproxy rules, and
/// with OS-guaranteed socket cleanup on Stop, switch to Production, or process exit.
/// </summary>
public sealed class StagingRelayService : IDisposable
{
    private readonly object _lifecycleLock = new();
    private readonly List<(StagingPortRoute Route, TcpListener Listener)> _listeners = [];
    private readonly List<Task> _acceptTasks = [];
    private readonly ConcurrentDictionary<long, ActiveRelaySession> _activeSessions = new();
    private CancellationTokenSource? _relayCts;
    private StagingRelayConfig? _activeConfig;
    private long _nextSessionId;
    private long _totalConnections;
    private long _failedUpstreamConnections;
    private bool _disposed;

    public event Action<string>? DiagnosticMessage;
    public event Action? StateChanged;

    public bool IsRunning
    {
        get
        {
            lock (_lifecycleLock)
            {
                return _listeners.Count > 0;
            }
        }
    }

    public StagingRelayConfig? ActiveConfig
    {
        get
        {
            lock (_lifecycleLock)
            {
                return _activeConfig;
            }
        }
    }

    public int ActiveClientConnections => _activeSessions.Count;
    public long TotalForwardedConnections => Interlocked.Read(ref _totalConnections);
    public long FailedUpstreamConnections => Interlocked.Read(ref _failedUpstreamConnections);

    public static ResolvedServerConnectionPlan ResolveConnectionPlan(
        LauncherSettings settings,
        LauncherManifest manifest)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(manifest);

        var mode = settings.ServerTarget;
        if (mode == ServerTargetMode.Staging)
        {
            var manifestStaging = manifest.StagingServer;
            var lanePreset = LauncherSettings.GetStagingLanePreset(settings.StagingLane);
            var remoteHost = !string.IsNullOrWhiteSpace(settings.StagingServerHost)
                ? settings.StagingServerHost.Trim()
                : (!string.IsNullOrWhiteSpace(manifestStaging?.Host)
                    ? manifestStaging.Host.Trim()
                    : LauncherSettings.DefaultStagingHost);

            var hasUntouchedCombatDefaults =
                settings.StagingAuthPort == LauncherSettings.DefaultStagingAuthPort &&
                settings.StagingDataPort == LauncherSettings.DefaultStagingDataPort &&
                settings.StagingViewPort == LauncherSettings.DefaultStagingViewPort &&
                settings.StagingSearchPort == LauncherSettings.DefaultStagingSearchPort &&
                settings.StagingProfilePort == LauncherSettings.DefaultStagingProfilePort &&
                settings.StagingProfileIrcPort == LauncherSettings.DefaultStagingProfileIrcPort;

            var useLanePresetDirectly = settings.StagingLane != StagingLane.Combat && hasUntouchedCombatDefaults;

            var authPort = useLanePresetDirectly
                ? lanePreset.AuthPort
                : (settings.StagingAuthPort is > 0 and <= 65535
                    ? settings.StagingAuthPort
                    : (settings.StagingLane == StagingLane.Combat && manifestStaging?.Ports.Auth is > 0 and <= 65535
                        ? manifestStaging.Ports.Auth
                        : lanePreset.AuthPort));
            var dataPort = useLanePresetDirectly
                ? lanePreset.DataPort
                : (settings.StagingDataPort is > 0 and <= 65535
                    ? settings.StagingDataPort
                    : (settings.StagingLane == StagingLane.Combat && manifestStaging?.Ports.Data is > 0 and <= 65535
                        ? manifestStaging.Ports.Data
                        : lanePreset.DataPort));
            var viewPort = useLanePresetDirectly
                ? lanePreset.ViewPort
                : (settings.StagingViewPort is > 0 and <= 65535
                    ? settings.StagingViewPort
                    : (settings.StagingLane == StagingLane.Combat && manifestStaging?.Ports.View is > 0 and <= 65535
                        ? manifestStaging.Ports.View
                        : lanePreset.ViewPort));
            var searchPort = useLanePresetDirectly
                ? lanePreset.SearchPort
                : (settings.StagingSearchPort is > 0 and <= 65535
                    ? settings.StagingSearchPort
                    : (settings.StagingLane == StagingLane.Combat && manifestStaging?.Ports.Search is > 0 and <= 65535
                        ? manifestStaging.Ports.Search
                        : lanePreset.SearchPort));
            var profilePort = useLanePresetDirectly
                ? lanePreset.ProfilePort
                : (settings.StagingProfilePort is > 0 and <= 65535
                    ? settings.StagingProfilePort
                    : (settings.StagingLane == StagingLane.Combat && manifestStaging?.Ports.Profile is > 0 and <= 65535
                        ? manifestStaging.Ports.Profile
                        : lanePreset.ProfilePort));
            var profileIrcPort = useLanePresetDirectly
                ? lanePreset.ProfileIrcPort
                : (settings.StagingProfileIrcPort is > 0 and <= 65535
                    ? settings.StagingProfileIrcPort
                    : (settings.StagingLane == StagingLane.Combat && manifestStaging?.Ports.ProfileIrc is > 0 and <= 65535
                        ? manifestStaging.Ports.ProfileIrc
                        : lanePreset.ProfileIrcPort));
            var mapPort = settings.StagingLane != StagingLane.Combat && settings.StagingMapPort == LauncherSettings.DefaultStagingMapPort
                ? lanePreset.MapUdpPort
                : (settings.StagingMapPort is > 0 and <= 65535
                    ? settings.StagingMapPort
                    : (settings.StagingLane == StagingLane.Combat && manifestStaging?.Ports.Map is > 0 and <= 65535
                        ? manifestStaging.Ports.Map
                        : lanePreset.MapUdpPort));

            var relayConfig = StagingRelayConfig.CreateDefault(
                remoteHost,
                authPort,
                dataPort,
                viewPort,
                searchPort,
                profilePort,
                profileIrcPort);

            // Important: BootUseHairpin MUST remain false in Staging mode because xiloader's
            // --hairpin rewrites the server-supplied zone_settings.zoneip (e.g. 192.168.86.117)
            // back to --server (127.0.0.1), which would break direct UDP map traffic on the lane's UDP port.
            return new ResolvedServerConnectionPlan(
                TargetMode: ServerTargetMode.Staging,
                DisplayHost: $"{remoteHost}:{authPort}",
                StatusProbeHost: remoteHost,
                StatusProbeLobbyPort: authPort,
                StatusProbeSearchPort: searchPort,
                StatusProbeProfilePort: profilePort,
                StatusProbeProfileIrcPort: profileIrcPort,
                BootServerHost: StagingRelayConfig.LoopbackHost,
                BootUseHairpin: false,
                RequiresLoopbackRelay: true,
                RelayConfig: relayConfig,
                MapUdpPort: mapPort,
                StagingLane: lanePreset.Lane,
                StagingLaneDisplayName: lanePreset.ShortBadgeLabel);
        }

        if (mode == ServerTargetMode.Custom && !string.IsNullOrWhiteSpace(settings.CustomServerHost))
        {
            var customHost = settings.CustomServerHost.Trim();
            var customLobby = settings.CustomLobbyPort is > 0 and <= 65535
                ? settings.CustomLobbyPort
                : manifest.Ports.Lobby;
            var customSearch = settings.CustomSearchPort is > 0 and <= 65535
                ? settings.CustomSearchPort
                : manifest.Ports.Search;

            return new ResolvedServerConnectionPlan(
                TargetMode: ServerTargetMode.Custom,
                DisplayHost: customHost,
                StatusProbeHost: customHost,
                StatusProbeLobbyPort: customLobby,
                StatusProbeSearchPort: customSearch,
                StatusProbeProfilePort: 0,
                StatusProbeProfileIrcPort: 0,
                BootServerHost: customHost,
                BootUseHairpin: settings.CustomUseHairpin,
                RequiresLoopbackRelay: false,
                RelayConfig: null,
                MapUdpPort: 54230);
        }

        var prodHost = string.IsNullOrWhiteSpace(manifest.DefaultHost)
            ? "play.soulspirexi.com"
            : manifest.DefaultHost.Trim();

        return new ResolvedServerConnectionPlan(
            TargetMode: ServerTargetMode.Production,
            DisplayHost: prodHost,
            StatusProbeHost: prodHost,
            StatusProbeLobbyPort: manifest.Ports.Lobby,
            StatusProbeSearchPort: manifest.Ports.Search,
            StatusProbeProfilePort: 0,
            StatusProbeProfileIrcPort: 0,
            BootServerHost: prodHost,
            BootUseHairpin: manifest.UseHairpin,
            RequiresLoopbackRelay: false,
            RelayConfig: null,
            MapUdpPort: 54230);
    }

    /// <summary>
    /// Rewrites an existing Ashita boot config back to the resolved non-staging target
    /// (Production or Custom) so no stale "--server 127.0.0.1" remains on disk after
    /// switching away from Staging.
    /// </summary>
    public static bool TryRestoreOrdinaryBootConfig(
        AshitaConfigGenerator configGenerator,
        LauncherSettings settings,
        LauncherManifest manifest,
        string? plainPassword)
    {
        ArgumentNullException.ThrowIfNull(configGenerator);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(manifest);

        if (settings.ServerTarget == ServerTargetMode.Staging || string.IsNullOrWhiteSpace(settings.AshitaPath))
        {
            return false;
        }

        var bootIniPath = Path.Combine(
            settings.AshitaPath,
            "config",
            "boot",
            AshitaConfigGenerator.BootConfigFileName);
        if (!File.Exists(bootIniPath))
        {
            return false;
        }

        var xiloaderPath = FfxiInstallDetector.ResolveXiloaderPath(settings.AshitaPath);
        if (string.IsNullOrWhiteSpace(xiloaderPath))
        {
            return false;
        }

        var plan = ResolveConnectionPlan(settings, manifest);
        if (plan.RequiresLoopbackRelay)
        {
            return false;
        }

        var content = configGenerator.BuildBootIniContent(
            settings,
            plan.BootServerHost,
            plan.BootUseHairpin,
            plainPassword,
            xiloaderPath);
        File.WriteAllText(bootIniPath, content);
        return true;
    }

    public StagingRelayStartResult Start(StagingRelayConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);

        var validationError = ValidateConfig(config);
        if (validationError is not null)
        {
            return StagingRelayStartResult.Invalid(validationError);
        }

        lock (_lifecycleLock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            if (_listeners.Count > 0 && _activeConfig is not null && _activeConfig.Matches(config))
            {
                return StagingRelayStartResult.Ok(
                    $"Staging TCP relay already active ({StagingRelayConfig.LoopbackHost} -> {config.RemoteHost}).",
                    alreadyRunning: true);
            }

            if (_listeners.Count > 0)
            {
                StopLocked();
            }

            var boundListeners = new List<(StagingPortRoute Route, TcpListener Listener)>(config.Routes.Count);
            try
            {
                foreach (var route in config.Routes)
                {
                    var listener = new TcpListener(IPAddress.Loopback, route.LocalPort);
                    try
                    {
                        // Enforce exclusive ownership so existing Windows portproxy rules or local
                        // services on 127.0.0.1:<port> are detected cleanly instead of shadowed.
                        listener.ExclusiveAddressUse = true;
                        listener.Start();
                        boundListeners.Add((route, listener));
                    }
                    catch (SocketException ex)
                    {
                        SafeStopListener(listener);
                        RollbackListeners(boundListeners);

                        var conflictMsg = BuildPortConflictMessage(route, ex.SocketErrorCode);
                        DiagnosticMessage?.Invoke(conflictMsg);
                        return StagingRelayStartResult.Conflict(
                            route.LocalPort,
                            route.Label,
                            ex.SocketErrorCode,
                            conflictMsg);
                    }
                }
            }
            catch (Exception ex)
            {
                RollbackListeners(boundListeners);
                var msg = $"Failed to start Staging TCP relay: {ex.Message}";
                DiagnosticMessage?.Invoke(msg);
                return StagingRelayStartResult.Invalid(msg);
            }

            var cts = new CancellationTokenSource();
            _relayCts = cts;
            _activeConfig = config;
            _listeners.AddRange(boundListeners);

            foreach (var (route, listener) in boundListeners)
            {
                var task = Task.Run(() => AcceptLoopAsync(listener, config.RemoteHost, route, config.UpstreamConnectTimeoutMs, cts.Token));
                _acceptTasks.Add(task);
            }
        }

        var routesSummary = string.Join(", ", config.Routes.Select(r => $"{r.LocalPort}->{r.RemotePort}"));
        var startedMsg = $"Staging TCP relay active on {StagingRelayConfig.LoopbackHost} ({routesSummary}) -> {config.RemoteHost} (no admin required).";
        DiagnosticMessage?.Invoke(startedMsg);
        StateChanged?.Invoke();
        return StagingRelayStartResult.Ok(startedMsg);
    }

    public void Stop()
    {
        bool wasRunning;
        lock (_lifecycleLock)
        {
            wasRunning = _listeners.Count > 0 || _activeSessions.Count > 0;
            StopLocked();
        }

        if (wasRunning)
        {
            DiagnosticMessage?.Invoke("Staging TCP relay stopped and local loopback ports released.");
            StateChanged?.Invoke();
        }
    }

    public void Dispose()
    {
        lock (_lifecycleLock)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            StopLocked();
        }

        StateChanged?.Invoke();
    }

    private void StopLocked()
    {
        try
        {
            _relayCts?.Cancel();
        }
        catch
        {
            // Ignore cancellation race during shutdown.
        }

        foreach (var (_, listener) in _listeners)
        {
            SafeStopListener(listener);
        }
        _listeners.Clear();
        _acceptTasks.Clear();

        foreach (var kvp in _activeSessions)
        {
            if (_activeSessions.TryRemove(kvp.Key, out var session))
            {
                session.Dispose();
            }
        }

        try
        {
            _relayCts?.Dispose();
        }
        catch
        {
            // Ignore dispose race.
        }

        _relayCts = null;
        _activeConfig = null;
    }

    private async Task AcceptLoopAsync(
        TcpListener listener,
        string remoteHost,
        StagingPortRoute route,
        int upstreamConnectTimeoutMs,
        CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            TcpClient? client;
            try
            {
                client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (SocketException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                DiagnosticMessage?.Invoke($"Staging relay accept error on {route.Label} ({route.LocalPort}): {ex.Message}");
                break;
            }

            _ = Task.Run(
                () => HandleClientAsync(client, remoteHost, route, upstreamConnectTimeoutMs, cancellationToken),
                CancellationToken.None);
        }
    }

    private async Task HandleClientAsync(
        TcpClient client,
        string remoteHost,
        StagingPortRoute route,
        int upstreamConnectTimeoutMs,
        CancellationToken cancellationToken)
    {
        var sessionId = Interlocked.Increment(ref _nextSessionId);
        var upstream = new TcpClient();
        var session = new ActiveRelaySession(client, upstream);
        _activeSessions[sessionId] = session;

        try
        {
            client.NoDelay = true;
            upstream.NoDelay = true;

            using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connectCts.CancelAfter(TimeSpan.FromMilliseconds(Math.Max(500, upstreamConnectTimeoutMs)));
            await upstream.ConnectAsync(remoteHost, route.RemotePort, connectCts.Token).ConfigureAwait(false);

            Interlocked.Increment(ref _totalConnections);

            await using var clientStream = client.GetStream();
            await using var upstreamStream = upstream.GetStream();

            using var pumpCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var c2u = PumpAsync(clientStream, upstreamStream, pumpCts);
            var u2c = PumpAsync(upstreamStream, clientStream, pumpCts);

            await Task.WhenAll(c2u, u2c).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Normal shutdown or upstream connect timeout.
            if (!cancellationToken.IsCancellationRequested)
            {
                Interlocked.Increment(ref _failedUpstreamConnections);
                DiagnosticMessage?.Invoke(
                    $"Staging relay upstream connect timed out for {route.Label} ({remoteHost}:{route.RemotePort}).");
            }
        }
        catch (Exception ex)
        {
            if (!cancellationToken.IsCancellationRequested)
            {
                if (!upstream.Connected)
                {
                    Interlocked.Increment(ref _failedUpstreamConnections);
                    DiagnosticMessage?.Invoke(
                        $"Staging relay could not reach {remoteHost}:{route.RemotePort} ({route.Label}): {ex.Message}");
                }
            }
        }
        finally
        {
            _activeSessions.TryRemove(sessionId, out _);
            session.Dispose();
        }
    }

    private static async Task PumpAsync(
        NetworkStream source,
        NetworkStream destination,
        CancellationTokenSource pumpCts)
    {
        try
        {
            await source.CopyToAsync(destination, 16384, pumpCts.Token).ConfigureAwait(false);
            try
            {
                destination.Socket.Shutdown(SocketShutdown.Send);
            }
            catch
            {
                // Peer may already be closed.
            }
        }
        catch
        {
            // Abrupt client crash / reset or relay stop: cancel the reverse pump cleanly.
            try
            {
                await pumpCts.CancelAsync().ConfigureAwait(false);
            }
            catch
            {
                // Ignore race.
            }
        }
    }

    private static string? ValidateConfig(StagingRelayConfig config)
    {
        if (string.IsNullOrWhiteSpace(config.RemoteHost))
        {
            return "Staging server host is empty.";
        }

        if (config.Routes is null || config.Routes.Count == 0)
        {
            return "No staging TCP routes configured.";
        }

        var isLoopbackRemote =
            string.Equals(config.RemoteHost, "localhost", StringComparison.OrdinalIgnoreCase) ||
            (IPAddress.TryParse(config.RemoteHost, out var ip) && IPAddress.IsLoopback(ip));

        var seenLocalPorts = new HashSet<int>();
        foreach (var route in config.Routes)
        {
            if (route.LocalPort is <= 0 or > 65535)
            {
                return $"Invalid local relay port {route.LocalPort} for {route.Label}.";
            }

            if (route.RemotePort is <= 0 or > 65535)
            {
                return $"Invalid remote staging port {route.RemotePort} for {route.Label}.";
            }

            if (!seenLocalPorts.Add(route.LocalPort))
            {
                return $"Duplicate local relay port {route.LocalPort}.";
            }

            if (isLoopbackRemote && route.LocalPort == route.RemotePort)
            {
                return $"Refusing loopback self-forward on port {route.LocalPort} ({route.Label}).";
            }
        }

        return null;
    }

    private static void RollbackListeners(List<(StagingPortRoute Route, TcpListener Listener)> bound)
    {
        foreach (var (_, listener) in bound)
        {
            SafeStopListener(listener);
        }
        bound.Clear();
    }

    private static void SafeStopListener(TcpListener listener)
    {
        try
        {
            listener.Stop();
        }
        catch
        {
            // Ignore shutdown errors.
        }
    }

    private static string BuildPortConflictMessage(StagingPortRoute route, SocketError error)
    {
        return
            $"Local loopback port 127.0.0.1:{route.LocalPort} ({route.Label}) is already in use ({error}). " +
            "SoulspireXI Launcher rolled back all staging relay bindings and did NOT modify or reset any existing Windows netsh portproxy rules. " +
            "Check for an existing portproxy rule ('netsh interface portproxy show v4tov4'), another SoulspireXI Launcher instance, or a local server holding that port.";
    }

    private sealed class ActiveRelaySession(TcpClient client, TcpClient upstream) : IDisposable
    {
        private int _disposed;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }

            try { client.Close(); } catch { }
            try { client.Dispose(); } catch { }
            try { upstream.Close(); } catch { }
            try { upstream.Dispose(); } catch { }
        }
    }
}

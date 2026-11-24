using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using SoulspireLauncher.Models;
using SoulspireLauncher.Services;
using Xunit;

namespace SoulspireLauncher.Tests;

public sealed class StagingConnectionTests
{
    private static int AllocateFreeLoopbackPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static async Task<TcpListener> StartEchoServerAsync(string prefix, CancellationToken ct)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();

        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                TcpClient client;
                try
                {
                    client = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
                }
                catch
                {
                    break;
                }

                _ = Task.Run(async () =>
                {
                    using (client)
                    await using (var stream = client.GetStream())
                    {
                        var buffer = new byte[1024];
                        while (!ct.IsCancellationRequested)
                        {
                            int read;
                            try
                            {
                                read = await stream.ReadAsync(buffer, ct).ConfigureAwait(false);
                            }
                            catch
                            {
                                break;
                            }

                            if (read <= 0)
                            {
                                break;
                            }

                            var payload = Encoding.UTF8.GetString(buffer, 0, read);
                            var reply = Encoding.UTF8.GetBytes($"{prefix}:{payload}");
                            await stream.WriteAsync(reply, ct).ConfigureAwait(false);
                        }
                    }
                }, CancellationToken.None);
            }
        }, CancellationToken.None);

        await Task.Yield();
        return listener;
    }

    [Fact]
    public async Task ProductionToStaging_ResolvesCorrectPlanAndForwardsAllFourTcpRoutes()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        using var authUpstream = await StartEchoServerAsync("AUTH", cts.Token);
        using var dataUpstream = await StartEchoServerAsync("DATA", cts.Token);
        using var viewUpstream = await StartEchoServerAsync("VIEW", cts.Token);
        using var searchUpstream = await StartEchoServerAsync("SRCH", cts.Token);

        var manifest = new LauncherManifest
        {
            DefaultHost = "play.soulspirexi.com",
            UseHairpin = false,
            Ports = new ManifestPorts { Lobby = 54231, Auth = 54001, Search = 54002 },
            StagingServer = new ManifestStagingServer
            {
                Host = "192.168.86.117",
                UseHairpin = false,
                Ports = new ManifestStagingPorts
                {
                    Auth = 55231,
                    Data = 55230,
                    View = 55001,
                    Search = 55002,
                    Map = 55230
                }
            }
        };

        var settings = new LauncherSettings
        {
            ServerTarget = ServerTargetMode.Production,
            CustomUseHairpin = true // Must NOT leak into Staging or Production
        };

        // 1. Production plan
        var prodPlan = StagingRelayService.ResolveConnectionPlan(settings, manifest);
        Assert.Equal(ServerTargetMode.Production, prodPlan.TargetMode);
        Assert.Equal("play.soulspirexi.com", prodPlan.BootServerHost);
        Assert.Equal("play.soulspirexi.com", prodPlan.StatusProbeHost);
        Assert.Equal(54231, prodPlan.StatusProbeLobbyPort);
        Assert.Equal(54002, prodPlan.StatusProbeSearchPort);
        Assert.False(prodPlan.RequiresLoopbackRelay);
        Assert.Null(prodPlan.RelayConfig);

        // 2. Switch Production -> Staging
        settings.ServerTarget = ServerTargetMode.Staging;
        var stagingPlan = StagingRelayService.ResolveConnectionPlan(settings, manifest);
        Assert.Equal(ServerTargetMode.Staging, stagingPlan.TargetMode);
        Assert.Equal("127.0.0.1", stagingPlan.BootServerHost);
        Assert.False(stagingPlan.BootUseHairpin); // Crucial: never override zone_settings.zoneip with 127.0.0.1
        Assert.Equal("192.168.86.117", stagingPlan.StatusProbeHost);
        Assert.Equal(55231, stagingPlan.StatusProbeLobbyPort);
        Assert.Equal(55002, stagingPlan.StatusProbeSearchPort);
        Assert.Equal(55230, stagingPlan.MapUdpPort);
        Assert.True(stagingPlan.RequiresLoopbackRelay);
        Assert.NotNull(stagingPlan.RelayConfig);
        Assert.Equal(4, stagingPlan.RelayConfig!.Routes.Count);

        // 3. Verify live bidirectional TCP forwarding across all 4 mapped ports
        var localAuth = AllocateFreeLoopbackPort();
        var localData = AllocateFreeLoopbackPort();
        var localView = AllocateFreeLoopbackPort();
        var localSearch = AllocateFreeLoopbackPort();

        var testRelayConfig = StagingRelayConfig.CreateDefault(
            remoteHost: "127.0.0.1",
            remoteAuthPort: ((IPEndPoint)authUpstream.LocalEndpoint).Port,
            remoteDataPort: ((IPEndPoint)dataUpstream.LocalEndpoint).Port,
            remoteViewPort: ((IPEndPoint)viewUpstream.LocalEndpoint).Port,
            remoteSearchPort: ((IPEndPoint)searchUpstream.LocalEndpoint).Port,
            localAuthPort: localAuth,
            localDataPort: localData,
            localViewPort: localView,
            localSearchPort: localSearch);

        using var relay = new StagingRelayService();
        var startResult = relay.Start(testRelayConfig);
        Assert.True(startResult.Success, startResult.Message);
        Assert.True(relay.IsRunning);

        // Idempotent second Start with identical config keeps relay up without error
        var secondStart = relay.Start(testRelayConfig);
        Assert.True(secondStart.Success);
        Assert.True(secondStart.AlreadyRunning);

        var expectedPairs = new (int LocalPort, string ExpectedPrefix)[]
        {
            (localAuth, "AUTH"),
            (localData, "DATA"),
            (localView, "VIEW"),
            (localSearch, "SRCH"),
        };

        foreach (var (localPort, prefix) in expectedPairs)
        {
            using var client = new TcpClient();
            await client.ConnectAsync(IPAddress.Loopback, localPort, cts.Token);
            await using var stream = client.GetStream();
            var outbound = Encoding.UTF8.GetBytes("ping");
            await stream.WriteAsync(outbound, cts.Token);

            var buf = new byte[64];
            var read = await stream.ReadAsync(buf, cts.Token);
            var response = Encoding.UTF8.GetString(buf, 0, read);
            Assert.Equal($"{prefix}:ping", response);
        }

        Assert.Equal(4, relay.TotalForwardedConnections);
    }

    [Fact]
    public void StagingToProduction_StopsRelayReleasesPortsAndRestoresBootIni()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_staging_restore_{Guid.NewGuid():N}");
        var ashitaDir = Path.Combine(tempRoot, "Ashita");
        var bootDir = Path.Combine(ashitaDir, "config", "boot");
        var bootloaderDir = Path.Combine(ashitaDir, "bootloader");
        Directory.CreateDirectory(bootDir);
        Directory.CreateDirectory(bootloaderDir);

        try
        {
            var xiloaderPath = Path.Combine(bootloaderDir, "xiloader.exe");
            File.WriteAllText(xiloaderPath, "stub", Encoding.UTF8);

            var manifest = new LauncherManifest
            {
                DefaultHost = "play.soulspirexi.com",
                UseHairpin = false,
                Ports = new ManifestPorts { Lobby = 54231, Auth = 54001, Search = 54002 }
            };

            var settings = new LauncherSettings
            {
                AshitaPath = ashitaDir,
                ServerTarget = ServerTargetMode.Staging,
                StagingServerHost = "192.168.86.117"
            };

            var generator = new AshitaConfigGenerator();
            var stagingPlan = StagingRelayService.ResolveConnectionPlan(settings, manifest);
            generator.WriteAllConfigs(
                ashitaDir,
                settings,
                stagingPlan.BootServerHost,
                stagingPlan.BootUseHairpin,
                password: null,
                xiloaderPath: xiloaderPath);

            var bootIniPath = Path.Combine(bootDir, AshitaConfigGenerator.BootConfigFileName);
            var stagingIni = File.ReadAllText(bootIniPath, Encoding.UTF8);
            Assert.Contains("command = --server 127.0.0.1", stagingIni);
            Assert.DoesNotContain("--hairpin", stagingIni);

            var p1 = AllocateFreeLoopbackPort();
            var p2 = AllocateFreeLoopbackPort();
            var p3 = AllocateFreeLoopbackPort();
            var p4 = AllocateFreeLoopbackPort();
            var config = StagingRelayConfig.CreateDefault(
                "192.168.86.117",
                localAuthPort: p1,
                localDataPort: p2,
                localViewPort: p3,
                localSearchPort: p4);

            using var relay = new StagingRelayService();
            Assert.True(relay.Start(config).Success);
            Assert.True(relay.IsRunning);

            // Switch Staging -> Production
            relay.Stop();
            Assert.False(relay.IsRunning);

            // Every local port must be immediately released and re-bindable
            foreach (var port in new[] { p1, p2, p3, p4 })
            {
                using var probe = new TcpListener(IPAddress.Loopback, port);
                probe.ExclusiveAddressUse = true;
                probe.Start();
                probe.Stop();
            }

            settings.ServerTarget = ServerTargetMode.Production;
            var restored = StagingRelayService.TryRestoreOrdinaryBootConfig(generator, settings, manifest, plainPassword: null);
            Assert.True(restored);

            var prodIni = File.ReadAllText(bootIniPath, Encoding.UTF8);
            Assert.Contains("command = --server play.soulspirexi.com", prodIni);
            Assert.DoesNotContain("--server 127.0.0.1", prodIni);
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
    public void LauncherRestart_PersistsStagingAndMigratesLegacySettingsSafely()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), $"soulspire_staging_persist_{Guid.NewGuid():N}");
        var launcherDir = Path.Combine(tempRoot, "Launcher");
        var appDataDir = Path.Combine(tempRoot, "AppData");
        Directory.CreateDirectory(launcherDir);
        Directory.CreateDirectory(appDataDir);

        try
        {
            var service = new SettingsService(launcherDir, appDataDir);

            // 1. Legacy settings with UseCustomServer=true migrate cleanly to ServerTargetMode.Custom
            File.WriteAllText(
                service.SettingsPath,
                """{"UseCustomServer":true,"CustomServerHost":"custom.example.org","CustomLobbyPort":54231}""",
                Encoding.UTF8);
            var migratedCustom = service.Load();
            Assert.Equal(ServerTargetMode.Custom, migratedCustom.ServerTarget);
            Assert.True(migratedCustom.UseCustomServer);
            Assert.Equal("custom.example.org", migratedCustom.CustomServerHost);
            Assert.Equal(LauncherSettings.DefaultStagingHost, migratedCustom.StagingServerHost);

            // 2. Legacy default Production user stays on Production (Stable unaffected)
            File.WriteAllText(service.SettingsPath, """{"UseCustomServer":false}""", Encoding.UTF8);
            var migratedProd = service.Load();
            Assert.Equal(ServerTargetMode.Production, migratedProd.ServerTarget);
            Assert.False(migratedProd.UseCustomServer);

            // 3. Staging selection persists cleanly across launcher restart without clobbering CustomServerHost
            migratedProd.CustomServerHost = "keep-my-custom.example.org";
            migratedProd.ServerTarget = ServerTargetMode.Staging;
            migratedProd.StagingServerHost = "100.64.41.78";
            migratedProd.StagingAuthPort = 55231;
            service.Save(migratedProd, plainPassword: null);

            var restartedService = new SettingsService(launcherDir, appDataDir);
            var reloaded = restartedService.Load();
            Assert.Equal(ServerTargetMode.Staging, reloaded.ServerTarget);
            Assert.False(reloaded.UseCustomServer);
            Assert.Equal("100.64.41.78", reloaded.StagingServerHost);
            Assert.Equal("keep-my-custom.example.org", reloaded.CustomServerHost);
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
    public async Task ClientCrash_AbruptResetCleansSessionAndAllowsImmediateReconnect()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        using var upstream = await StartEchoServerAsync("CRASH", cts.Token);
        var upstreamPort = ((IPEndPoint)upstream.LocalEndpoint).Port;

        var localAuth = AllocateFreeLoopbackPort();
        var config = new StagingRelayConfig(
            "127.0.0.1",
            [new StagingPortRoute("Login Auth", localAuth, upstreamPort)]);

        using var relay = new StagingRelayService();
        Assert.True(relay.Start(config).Success);

        // Simulate abrupt client crash via TCP RST (Linger=0)
        using (var crashingClient = new TcpClient())
        {
            await crashingClient.ConnectAsync(IPAddress.Loopback, localAuth, cts.Token);
            crashingClient.LingerState = new LingerOption(true, 0);
            var s = crashingClient.GetStream();
            await s.WriteAsync(Encoding.UTF8.GetBytes("hello"), cts.Token);
            var buf = new byte[32];
            var n = await s.ReadAsync(buf, cts.Token);
            Assert.Equal("CRASH:hello", Encoding.UTF8.GetString(buf, 0, n));
            // Immediate hard close without FIN
        }

        // Wait briefly for relay session cleanup
        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (relay.ActiveClientConnections > 0 && DateTime.UtcNow < deadline)
        {
            await Task.Delay(25, cts.Token);
        }

        Assert.True(relay.IsRunning);
        Assert.Equal(0, relay.ActiveClientConnections);

        // Subsequent client connects and forwards cleanly
        using var healthyClient = new TcpClient();
        await healthyClient.ConnectAsync(IPAddress.Loopback, localAuth, cts.Token);
        await using var stream = healthyClient.GetStream();
        await stream.WriteAsync(Encoding.UTF8.GetBytes("recovered"), cts.Token);
        var replyBuf = new byte[64];
        var read = await stream.ReadAsync(replyBuf, cts.Token);
        Assert.Equal("CRASH:recovered", Encoding.UTF8.GetString(replyBuf, 0, read));
    }

    [Fact]
    public async Task FailedConnection_UnreachableStagingFailsCleanlyWithoutCrashingRelay()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var unusedRemotePort = AllocateFreeLoopbackPort();
        var statusService = new ServerStatusService();

        var probe = await statusService.CheckAsync("127.0.0.1", unusedRemotePort, unusedRemotePort, cts.Token);
        Assert.False(probe.IsOnline);
        Assert.False(probe.LobbyReachable);

        var localAuth = AllocateFreeLoopbackPort();
        var config = new StagingRelayConfig(
            "127.0.0.1",
            [new StagingPortRoute("Login Auth", localAuth, unusedRemotePort)],
            UpstreamConnectTimeoutMs: 1000);

        using var relay = new StagingRelayService();
        Assert.True(relay.Start(config).Success);

        using (var client = new TcpClient())
        {
            await client.ConnectAsync(IPAddress.Loopback, localAuth, cts.Token);
            await using var stream = client.GetStream();
            var buf = new byte[16];
            try
            {
                var read = await stream.ReadAsync(buf, cts.Token);
                Assert.Equal(0, read);
            }
            catch (IOException)
            {
                // Expected peer close when upstream connect fails
            }
        }

        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (relay.FailedUpstreamConnections == 0 && DateTime.UtcNow < deadline)
        {
            await Task.Delay(25, cts.Token);
        }

        Assert.True(relay.IsRunning);
        Assert.True(relay.FailedUpstreamConnections >= 1);
        relay.Stop();
        Assert.False(relay.IsRunning);
    }

    [Fact]
    public async Task ExistingPortCollision_DetectsConflictRollsBackAtomicallyAndPreservesExistingListener()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));

        // Simulate an existing Windows netsh portproxy rule or user service holding local port #2
        using var existingUserRule = await StartEchoServerAsync("USER_RULE", cts.Token);
        var occupiedPort = ((IPEndPoint)existingUserRule.LocalEndpoint).Port;

        var freePort1 = AllocateFreeLoopbackPort();
        var freePort3 = AllocateFreeLoopbackPort();
        var freePort4 = AllocateFreeLoopbackPort();

        var config = StagingRelayConfig.CreateDefault(
            remoteHost: "192.168.86.117",
            localAuthPort: freePort1,
            localDataPort: occupiedPort,
            localViewPort: freePort3,
            localSearchPort: freePort4);

        using var relay = new StagingRelayService();
        var result = relay.Start(config);

        Assert.False(result.Success);
        Assert.False(relay.IsRunning);
        Assert.Equal(occupiedPort, result.ConflictingLocalPort);
        Assert.Equal("Login Data", result.ConflictingRouteLabel);
        Assert.Contains("portproxy", result.Message, StringComparison.OrdinalIgnoreCase);

        // Atomic rollback: freePort1 (bound BEFORE occupiedPort collided) MUST already be released
        using (var verifyReleased = new TcpListener(IPAddress.Loopback, freePort1))
        {
            verifyReleased.ExclusiveAddressUse = true;
            verifyReleased.Start();
            verifyReleased.Stop();
        }

        // Non-interference: the pre-existing listener on occupiedPort MUST remain untouched and responsive
        using var verifyUserRule = new TcpClient();
        await verifyUserRule.ConnectAsync(IPAddress.Loopback, occupiedPort, cts.Token);
        await using var stream = verifyUserRule.GetStream();
        await stream.WriteAsync(Encoding.UTF8.GetBytes("still-alive"), cts.Token);
        var buf = new byte[64];
        var read = await stream.ReadAsync(buf, cts.Token);
        Assert.Equal("USER_RULE:still-alive", Encoding.UTF8.GetString(buf, 0, read));
    }

    [Fact]
    public void InvalidConfigs_AreRejectedBeforeBindingAnyPort()
    {
        using var relay = new StagingRelayService();

        var emptyHost = StagingRelayConfig.CreateDefault("   ");
        Assert.False(relay.Start(emptyHost).Success);
        Assert.False(relay.IsRunning);

        var selfLoopPort = AllocateFreeLoopbackPort();
        var selfLoop = new StagingRelayConfig(
            "127.0.0.1",
            [new StagingPortRoute("SelfLoop", selfLoopPort, selfLoopPort)]);
        Assert.False(relay.Start(selfLoop).Success);
        Assert.False(relay.IsRunning);
    }

    [Fact]
    public async Task Dispose_ClosesActiveStreamsAndReleasesPorts()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var upstream = await StartEchoServerAsync("DISP", cts.Token);
        var upstreamPort = ((IPEndPoint)upstream.LocalEndpoint).Port;
        var localPort = AllocateFreeLoopbackPort();

        var relay = new StagingRelayService();
        Assert.True(relay.Start(new StagingRelayConfig(
            "127.0.0.1",
            [new StagingPortRoute("Auth", localPort, upstreamPort)])).Success);

        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, localPort, cts.Token);
        await using var stream = client.GetStream();
        await stream.WriteAsync(Encoding.UTF8.GetBytes("hi"), cts.Token);
        var buf = new byte[32];
        var read = await stream.ReadAsync(buf, cts.Token);
        Assert.Equal("DISP:hi", Encoding.UTF8.GetString(buf, 0, read));

        // Disposing the relay must immediately close listener + active session
        relay.Dispose();
        Assert.False(relay.IsRunning);

        // Local port must be re-bindable right away
        using var rebind = new TcpListener(IPAddress.Loopback, localPort);
        rebind.ExclusiveAddressUse = true;
        rebind.Start();
        rebind.Stop();
    }

    [Fact]
    public void TestingCoreUiManifest_DeserializesStagingServerWhileStableRemainsUntouched()
    {
        var manifestService = new ManifestUpdateService();
        var stableManifest = manifestService.LoadEmbeddedManifest();
        Assert.Null(stableManifest.StagingServer);
        Assert.Equal("play.soulspirexi.com", stableManifest.DefaultHost);

        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "manifest.json")))
        {
            dir = dir.Parent;
        }

        Assert.NotNull(dir);
        var testingCoreManifestPath = Path.Combine(dir!.FullName, "channels", "testing-core-ui", "manifest.json");
        Assert.True(File.Exists(testingCoreManifestPath), $"Missing {testingCoreManifestPath}");

        var json = File.ReadAllText(testingCoreManifestPath, Encoding.UTF8);
        var parsed = System.Text.Json.JsonSerializer.Deserialize<LauncherManifest>(json);
        Assert.NotNull(parsed);
        Assert.NotNull(parsed!.StagingServer);
        Assert.Equal("192.168.86.117", parsed.StagingServer!.Host);
        Assert.False(parsed.StagingServer.UseHairpin);
        Assert.Equal(55231, parsed.StagingServer.Ports.Auth);
        Assert.Equal(55230, parsed.StagingServer.Ports.Data);
        Assert.Equal(55001, parsed.StagingServer.Ports.View);
        Assert.Equal(55002, parsed.StagingServer.Ports.Search);
        Assert.Equal(55230, parsed.StagingServer.Ports.Map);
    }
}

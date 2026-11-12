using System.Text.Json;
using Medley.Core;
using Medley.Core.Sync;
using Medley.Sync.Account;
using Medley.Sync.Convex;
using Medley.Sync.Keys;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

/// <summary>
/// Clerk's Frontend API for the account interleavings: sign-ins make sessions, touches, tokens, restores and removals act on
/// them, and every answer comes after a random delay (a slow network), off the actor. Records which sessions are active.
/// </summary>
internal sealed class SlowClerk(int seed) : IClerkHttp
{
    private readonly object _lock = new();
    private readonly Random _random = new(seed);
    private readonly Dictionary<string, (string User, string Device)> _sessions = new();
    private readonly HashSet<string> _removed = new();
    private int _made;

    /// <summary>Sessions still active at Clerk, with who made them.</summary>
    public IReadOnlyList<(string Session, string User, string Device)> Active
    {
        get { lock (_lock) return _sessions.Where(kv => !_removed.Contains(kv.Key)).Select(kv => (kv.Key, kv.Value.User, kv.Value.Device)).ToList(); }
    }

    public async Task<ClerkResponse> SendAsync(ClerkRequest request, CancellationToken cancellationToken = default)
    {
        int delay;
        lock (_lock) delay = _random.Next(0, 40);
        await Task.Delay(delay, CancellationToken.None).ConfigureAwait(false);
        var parts = request.Url.AbsolutePath.Trim('/').Split('/');
        lock (_lock)
        {
            object? json = (request.Method, parts) switch
            {
                ("POST", [_, "client", "sign_ins", var attempt, "attempt_first_factor"]) => SignIn(attempt),
                ("POST", [_, "client", "sessions", var id, "touch"]) when IsActive(id) => new { client = ClientJson(id) },
                ("POST", [_, "client", "sessions", var id, "tokens", _]) when IsActive(id) => new { jwt = Jwt(_sessions[id].User) },
                ("POST", [_, "client", "sessions", var id, "remove"]) => Remove(id),
                ("GET", [_, "client"]) => new { response = ClientJson(null) },
                ("GET", [_, "environment"]) => new { user_settings = new { social = new { } } },
                _ => null,
            };
            if (json is null)
                return new ClerkResponse(404, JsonSerializer.SerializeToUtf8Bytes(new { errors = new[] { new { code = "resource_not_found", message = "not found" } } }), "client_token");
            return new ClerkResponse(200, JsonSerializer.SerializeToUtf8Bytes(json), "client_token");
        }
    }

    private bool IsActive(string id) => _sessions.ContainsKey(id) && !_removed.Contains(id);

    /// <summary>The attempt id is "device:user".</summary>
    private object SignIn(string attempt)
    {
        var (device, user) = (attempt.Split(':')[0], attempt.Split(':')[1]);
        var id = $"sess_{device}_{user}_{++_made}";
        _sessions[id] = (user, device);
        return new { response = new { id = attempt, status = "complete", created_session_id = id } };
    }

    private object Remove(string id)
    {
        _removed.Add(id);
        return new { response = new { id } };
    }

    private Dictionary<string, object?> ClientJson(string? last) => new()
    {
        ["object"] = "client", ["id"] = "client_1", ["last_active_session_id"] = last,
        ["sessions"] = _sessions.Where(kv => !_removed.Contains(kv.Key)).Select(kv => new Dictionary<string, object?>
        {
            ["id"] = kv.Key, ["status"] = "active",
            ["user"] = new Dictionary<string, object?> { ["id"] = kv.Value.User, ["email_addresses"] = Array.Empty<object>() },
        }).ToArray(),
    };
}

/// <summary>
/// The account-level interleavings: two devices, each an AccountService and a SyncService on one actor, two sync servers
/// each with its own Clerk app, and Clerk answering every request after a random delay. Random steps: sign-ins of two users
/// (the email flow, then sync for the sign-in shown), sign-outs, server switches, provider sign-outs here and everywhere,
/// late device lists, forced rotations, approvals and quits. Invariants: no fake server saw a violation, every call carries
/// a JWT of its token's user, no call reaches a server with another server's device token, every vault sign-out went out
/// for the registration it was asked under, the account and its Clerk client agree, a signed-out account leaves sync signed
/// out, sync is never signed in as another user than the account, and no session is left active at Clerk unshown.
/// </summary>
public class AccountInterleavingTests : IAsyncLifetime
{
    private static readonly Uri[] Servers = [new("https://server-a.convex.cloud"), new("https://server-b.convex.cloud")];
    private static readonly string[] ClerkHosts = ["clerk.server-a.test", "clerk.server-b.test"];

    private readonly List<SyncService> _services = new();

    private sealed class Device
    {
        public required string Name;
        public required MemorySecretStore Secrets;
        public required MemoryClerkStore ClerkState;
        public required MemoryAccountPreferences Preferences;
        public SyncActor Actor = null!;
        public AccountService Account = null!;
        public SyncService Sync = null!;
        public RecordingTransfer Transfer = null!;
        public readonly List<Task> Running = new();
    }

    /// <summary>config:get of whichever server is asked: its own Clerk app.</summary>
    private sealed class ServerConfiguration : IHttpPoster
    {
        public Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
        {
            var index = Array.FindIndex(Servers, s => s.Host == url.Host);
            var key = ClerkTests.PublishableKey(ClerkHosts[index]);
            return Task.FromResult((JsonSerializer.SerializeToUtf8Bytes(new { status = "success", value = new { auth = new { kind = "clerk", publishableKey = key } } }), 200));
        }
    }

    /// <summary>One Clerk instance per Clerk host, shared by both devices (as Clerk's servers are).</summary>
    private sealed class ClerkRouter(SlowClerk[] clerks) : IClerkHttp
    {
        public Task<ClerkResponse> SendAsync(ClerkRequest request, CancellationToken cancellationToken = default) =>
            clerks[Array.IndexOf(ClerkHosts, request.Url.Host)].SendAsync(request, cancellationToken);
    }

    private SyncService NewSync(Device device, FakeKeyServer[] keyServers)
    {
        var index = Array.FindIndex(Servers, s => s == device.Account.Server.Url);
        var sync = new SyncService(Servers[index], new DeviceInfo(device.Name, DevicePlatform.Ios, "t", "1"), new SyncCredentialStore(device.Secrets),
                                   device.Actor, new FakeTransport { AutoFail = true }, keyServers[index], FastOptions(fallbackAfter: 1));
        lock (_services) _services.Add(sync);
        return sync;
    }

    /// <summary>A launch: a new actor, account and sync on the device's saved state; signed in again if Clerk kept a session.</summary>
    private async Task Launch(Device device, FakeKeyServer[] keyServers, IClerkHttp clerk)
    {
        device.Actor = SyncActor.CreateDedicated(device.Name);
        device.Account = new AccountService(Servers[0], device.ClerkState, device.Actor, device.Preferences, new ServerConfiguration(), clerk) { WatchesNetwork = false };
        await device.Account.LoadAsync();
        device.Sync = NewSync(device, keyServers);
        device.Transfer = new RecordingTransfer(device.Actor) { Text = $"{device.Name}-signin" };
        await device.Sync.SignIns.RegisterAsync(device.Transfer);
        if (await device.Actor.Run(() => device.Account.IsSignedIn)) device.Running.Add(Swallow(device.Account.StartSyncAsync(device.Sync)));
    }

    public static IEnumerable<object[]> Seeds => Enumerable.Range(1, 30).Select(i => new object[] { i });

    [Theory]
    [MemberData(nameof(Seeds))]
    public async Task RandomAccountInterleavingsKeepTheInvariants(int seed)
    {
        var random = new Random(seed);
        var keyServers = new[] { new FakeKeyServer(), new FakeKeyServer() };
        var clerks = new[] { new SlowClerk(seed), new SlowClerk(seed + 1000) };
        var clerkHttp = new ClerkRouter(clerks);
        var devices = new[] { "Mac", "Phone" }.Select(n => new Device
        {
            Name = n, Secrets = new MemorySecretStore(), ClerkState = new MemoryClerkStore(), Preferences = new MemoryAccountPreferences(),
        }).ToArray();
        foreach (var device in devices) await Launch(device, keyServers, clerkHttp);
        // The device tokens each vault sign-out was asked under (null: not registered then).
        var signOutTokens = new HashSet<string?>();

        for (var step = 0; step < 24; step++)
        {
            var device = devices[random.Next(2)];
            var running = device.Running;
            var kind = random.Next(10);
            switch (kind)
            {
                case 0 or 1:
                {
                    var user = random.Next(3) == 0 ? "v" : "u";
                    var account = device.Account;
                    running.Add(Swallow(SignInFlow()));
                    async Task SignInFlow()
                    {
                        await account.VerifyEmailAsync(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, $"{device.Name}:{user}", $"{user}+clerk_test@example.test"), "424242");
                        await account.StartSyncAsync(device.Sync);
                    }
                    break;
                }
                case 2:
                    running.Add(Swallow(device.Account.SignOutAsync(device.Sync)));
                    break;
                case 3:
                {
                    // Server switch, as the app does it: sign out (sync, then Clerk), switch, and a sync service for the new server.
                    var account = device.Account;
                    var other = Servers[1 - Array.FindIndex(Servers, s => s == account.Server.Url)];
                    running.Add(Swallow(Switch()));
                    async Task Switch()
                    {
                        var old = device.Sync;
                        await account.SignOutAsync(old);
                        await account.SetServerAsync(other == Servers[0] ? null : other);
                        await device.Actor.RunAsync(async () =>
                        {
                            if (!ReferenceEquals(device.Sync, old) || account.Server.Url != other) return;
                            await old.StopAsync();
                            device.Sync = NewSync(device, keyServers);
                            await device.Sync.SignIns.RegisterAsync(device.Transfer);
                        });
                    }
                    break;
                }
                case 4:
                {
                    // A provider sign-out, asked for and recorded in one actor turn.
                    var everywhere = random.Next(2) == 0;
                    var sync = device.Sync;
                    var task = await device.Actor.Run(() =>
                    {
                        lock (signOutTokens) signOutTokens.Add(sync.Credentials?.Token);
                        return sync.SignIns.SignOutAsync(ProviderId.Spotify, everywhere);
                    });
                    running.Add(Swallow(task));
                    // The provider is signed in again later (the app's own sign-in).
                    await device.Actor.Run(() => { device.Transfer.Text ??= $"{device.Name}-signin-{step}"; });
                    break;
                }
                case 5:
                {
                    var server = keyServers[Array.FindIndex(Servers, s => s == device.Sync.Client.DeploymentUrl)];
                    if (server.Devices.Any(x => x.Name == device.Name))
                    {
                        var list = server.ListResultFor(device.Name);
                        var sync = device.Sync;
                        await Task.Delay(random.Next(5, 40));
                        await device.Actor.Run(() => sync.Apply(list));
                    }
                    break;
                }
                case 6:
                {
                    keyServers[random.Next(2)].RequireRotation(random.Next(2) == 0 ? "u" : "v");
                    break;
                }
                case 7:
                {
                    var sync = device.Sync;
                    foreach (var r in await device.Actor.Run(() => sync.KeyRequests)) running.Add(Swallow(sync.AllowKeyAsync(r)));
                    sync.ConfirmKeyCode();
                    break;
                }
                case 8:
                {
                    // Quit when idle and launch again on the same saved state (a process that quits runs nothing more).
                    await Task.WhenAll(running);
                    await device.Sync.StopAsync();
                    await Launch(device, keyServers, clerkHttp);
                    break;
                }
                case 9:
                    await Task.Delay(random.Next(20, 120));
                    break;
            }
            await Task.Delay(random.Next(5, 60));
        }
        foreach (var device in devices) await Task.WhenAll(device.Running.ToList());
        await Task.Delay(600);
        foreach (var device in devices) await device.Actor.RunAsync(device.Sync.SignIns.Settle);

        for (var i = 0; i < 2; i++)
        {
            var server = keyServers[i];
            var other = keyServers[1 - i];
            Assert.True(server.Violations.Count == 0, $"seed {seed}, server {i}: {string.Join("; ", server.Violations.Take(3))}");
            var mine = server.Devices.Select(x => x.Token).ToHashSet();
            var theirs = other.Devices.Select(x => x.Token).Where(t => !mine.Contains(t)).ToHashSet();
            foreach (var call in server.Calls.Where(c => c.Args["token"]?.StringValue is not null))
            {
                var token = call.Args["token"]!.StringValue!;
                var owner = server.Devices.FirstOrDefault(x => x.Token == token)?.Owner;
                if (owner is not null && call.Path != "account:register")
                    Assert.True(call.User == owner, $"seed {seed}: {call.Path} with {owner}'s device token went out as {call.User ?? "nobody"}");
                Assert.False(theirs.Contains(token), $"seed {seed}: {call.Path} reached server {i} with a device token of the other server");
            }
            foreach (var call in server.CallsTo("vault:signOutEverywhere"))
                Assert.True(signOutTokens.Contains(call.Args["token"]?.StringValue), $"seed {seed}: a vault sign-out went out for a registration it wasn't asked under");
        }

        foreach (var device in devices)
        {
            var (signedIn, user, clerkSession, clerkUser, generationShown, syncUser) = await device.Actor.Run(() => (
                device.Account.IsSignedIn, device.Account.User?.Id, device.Account.Clerk?.CurrentSessionId, device.Account.Clerk?.SavedUser?.Id,
                device.Account.SessionGeneration, device.Sync.AuthUserId));
            if (device.Account.Clerk is not null)
            {
                Assert.True(signedIn == (clerkSession is not null), $"seed {seed}: {device.Name} shows signed in = {signedIn} while Clerk holds {clerkSession ?? "no session"}");
                if (signedIn) Assert.Equal(user, clerkUser);
            }
            if (!signedIn) Assert.True(syncUser is null, $"seed {seed}: {device.Name} signed out of the account but sync is still signed in as {syncUser}");
            else Assert.True(syncUser is null || syncUser == user, $"seed {seed}: {device.Name} shows {user} but sync is signed in as {syncUser}");
            // Every session this device made at Clerk ended, except the one it shows.
            for (var i = 0; i < 2; i++)
            {
                var shownHere = device.Account.Server.Url == Servers[i] ? clerkSession : null;
                foreach (var active in clerks[i].Active.Where(a => a.Device == device.Name))
                    Assert.True(active.Session == shownHere, $"seed {seed}: {device.Name} left session {active.Session} ({active.User}) active at Clerk {i}, showing {shownHere ?? "none"}");
            }
        }
        Assert.Equal(0, SyncActor.Violations);
    }

    private static async Task Swallow(Task task) { try { await task; } catch (Exception) { } }

    public Task InitializeAsync() => Task.CompletedTask;

    public async Task DisposeAsync()
    {
        List<SyncService> services;
        lock (_services) services = _services.ToList();
        foreach (var s in services) await s.StopAsync();
    }
}

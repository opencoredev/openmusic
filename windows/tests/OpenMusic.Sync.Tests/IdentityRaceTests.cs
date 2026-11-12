using OpenMusic.Core;
using OpenMusic.Core.Sync;
using OpenMusic.Sync.Account;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;
using static OpenMusic.Sync.Tests.TestUtil;

namespace OpenMusic.Sync.Tests;

// The six findings of the review of e1a13fb (reproductions in /tmp/openmusic-review-e1a13fb), one class: work captured its
// identity late, or applied an effect without checking it. Each test fails on e1a13fb and passes once every operation
// carries the ticket it was created under and checks it at each effect. They use only APIs e1a13fb has, so the same file
// runs against it (the Clerk one needs the WillAdoptFinishedSession hook, inserted there the same way).

/// <summary>A transfer that records which sign-in each local deletion removed, and whether it was called off the actor.</summary>
internal sealed class RecordingTransfer(SyncActor actor) : ISignInTransfer
{
    public ProviderId Provider => ProviderId.Spotify;
    public Action? SignInDidChange { get; set; }
    public volatile bool OffActor;
    public string? Text;
    public bool RefuseSignOuts;
    public TaskCompletionSource? ExportStarted;
    public TaskCompletionSource? ReleaseExport;
    public List<string?> Deleted { get; } = new();

    public async Task<byte[]?> ExportSignInAsync()
    {
        OffActor |= !actor.IsCurrent;
        var text = Text;
        if (ReleaseExport is { } gate)
        {
            ReleaseExport = null;
            ExportStarted!.TrySetResult();
            await gate.Task;
        }
        return text is null ? null : System.Text.Encoding.UTF8.GetBytes(text);
    }

    public Task ImportSignInAsync(byte[] data)
    {
        OffActor |= !actor.IsCurrent;
        Text = System.Text.Encoding.UTF8.GetString(data);
        return Task.CompletedTask;
    }

    public Task SignOutAsync()
    {
        OffActor |= !actor.IsCurrent;
        if (RefuseSignOuts) throw new IOException("the keychain refused");
        lock (Deleted) Deleted.Add(Text);
        Text = null;
        return Task.CompletedTask;
    }
}

/// <summary>A vault endpoint whose account can be switched; records which account each vault sign-out went out as.</summary>
internal sealed class SwitchableEndpoint : IVaultEndpoint
{
    public DeviceId? SelfId => new DeviceId("me");
    public LibraryKey? LibraryKey { get; } = Keys.LibraryKey.Generate();
    public bool VaultWritesPaused => false;
    public IReadOnlyList<VaultEntry>? VaultEntries { get; set; } = Array.Empty<VaultEntry>();
    public ServerClock Clock { get; } = new();
    public string Account = "A";
    public List<string> SignedOutAs { get; } = new();
    public Task<VaultWrite> PutVaultAsync(ProviderId p, string s, string k, int r) => Task.FromResult(new VaultWrite(1, r + 1));
    public Task<VaultWrite> SignOutVaultAsync(ProviderId p, int r)
    {
        lock (SignedOutAs) SignedOutAs.Add(Account);
        return Task.FromResult(new VaultWrite(1, r + 1));
    }
}

public class IdentityRaceTests
{
    private static TaskCompletionSource Gate() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static async Task Swallow(Task task) { try { await task; } catch (Exception) { } }

    // 1 (P1, SignInSync.cs:155): a provider sign-out asked for under A captured its session inside the queued body.

    [Fact]
    public async Task AProviderSignOutAskedForUnderANeverDeletesBsSignInOrSignsBOut()
    {
        var actor = SyncActor.CreateDedicated();
        var endpoint = new SwitchableEndpoint();
        var sync = new SignInSync(new SyncCredentialStore(new MemorySecretStore()), endpoint, actor);
        var transfer = new RecordingTransfer(actor);
        await actor.Run(() => sync.BeginSession("A"));
        await sync.RegisterAsync(transfer);
        await actor.RunAsync(sync.Settle);
        // A reconcile holds the queue, so the sign-out waits behind it.
        transfer.ExportStarted = Gate();
        transfer.ReleaseExport = Gate();
        var release = transfer.ReleaseExport;
        await actor.Run(sync.ReconcileAll);
        await transfer.ExportStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var signOut = sync.SignOutAsync(ProviderId.Spotify, everywhere: true);
        // B takes over the device and brings its own sign-in before the queued sign-out runs.
        await actor.Run(() => { endpoint.Account = "B"; transfer.Text = "B-local-signin"; sync.BeginSession("B"); });
        release.SetResult();
        await Swallow(signOut.WaitAsync(TimeSpan.FromSeconds(5)));
        await actor.RunAsync(sync.Settle);
        Assert.True(signOut.IsFaulted, "the sign-out for A reports that it didn't happen");
        Assert.DoesNotContain("B-local-signin", transfer.Deleted);
        Assert.DoesNotContain("B", endpoint.SignedOutAs);
        Assert.Equal("B-local-signin", transfer.Text);
    }

    // 2 (P1, ClerkClient.cs:490): the final adoption of a sign-in had no generation check.

    [Fact]
    public async Task AnEarlierSignInsTouchAnswerNeverReplacesTheSessionOfOneThatFinishedFirst()
    {
        var fake = new FakeClerk();
        foreach (var user in new[] { "A", "B" })
        {
            fake.On($"POST /v1/client/sign_ins/{user}/attempt_first_factor", new { response = new { id = user, status = "complete", created_session_id = "sess_" + user } });
            fake.On($"POST /v1/client/sessions/sess_{user}/touch", new { client = ClerkTests.ClientJson("sess_" + user, user) });
        }
        var clerk = new ClerkClient(ClerkTests.TestKey, new MemoryClerkStore(), fake);
        var reached = Gate();
        var release = Gate();
        // A's touch answered and passed its request's check; it pauses right before adopting.
        clerk.WillAdoptFinishedSession = async () => { clerk.WillAdoptFinishedSession = null; reached.SetResult(); await release.Task; };
        var a = clerk.VerifyEmailAsync(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, "A", "a@example.test"), "424242");
        await reached.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await clerk.VerifyEmailAsync(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, "B", "b@example.test"), "424242");
        Assert.Equal("sess_B", clerk.CurrentSessionId);
        release.SetResult();
        await Swallow(a.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.True(a.IsFaulted, "A's sign-in is stale");
        Assert.Equal("sess_B", clerk.CurrentSessionId);
        Assert.Equal("B", clerk.SavedUser?.Id);
    }

    [Fact]
    public async Task AStaleSignInEndsTheSessionItMadeAtClerkAndANewSignInEndsTheOneItReplaces()
    {
        var fake = new FakeClerk();
        foreach (var user in new[] { "A", "B", "C" })
        {
            fake.On($"POST /v1/client/sign_ins/{user}/attempt_first_factor", new { response = new { id = user, status = "complete", created_session_id = "sess_" + user } });
            fake.On($"POST /v1/client/sessions/sess_{user}/touch", new { client = ClerkTests.ClientJson("sess_" + user, user) });
            fake.On($"POST /v1/client/sessions/sess_{user}/remove", new { response = new { id = "sess_" + user } });
        }
        var clerk = new ClerkClient(ClerkTests.TestKey, new MemoryClerkStore(), fake);
        var reached = Gate();
        var release = Gate();
        clerk.WillAdoptFinishedSession = async () => { clerk.WillAdoptFinishedSession = null; reached.SetResult(); await release.Task; };
        var a = clerk.VerifyEmailAsync(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, "A", "a@example.test"), "424242");
        await reached.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await clerk.VerifyEmailAsync(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, "B", "b@example.test"), "424242");
        release.SetResult();
        await Swallow(a.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath == "/v1/client/sessions/sess_A/remove")));
        // C replaces B: B is ended at Clerk, C stays.
        await clerk.VerifyEmailAsync(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, "C", "c@example.test"), "424242");
        Assert.Equal("sess_C", clerk.CurrentSessionId);
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath == "/v1/client/sessions/sess_B/remove")));
        Assert.DoesNotContain(fake.Requests, r => r.Url.AbsolutePath == "/v1/client/sessions/sess_C/remove");
    }

    // 3 (P1, AccountService.cs:320 and :335): a sign-in completion arriving after an account sign-out was shown.

    private static FakeHttp ConfigFor(string publishableKey) => new()
    {
        Respond = (_, _) => ConvexValue.Object(("status", ConvexValue.String("success")), ("value", ConvexValue.Object(("auth",
            ConvexValue.Object(("kind", ConvexValue.String("clerk")), ("publishableKey", ConvexValue.String(publishableKey))))))),
    };

    /// <summary>Holds the actor, lets a sign-out queue behind the hold, lets Clerk finish, then lets the actor go.</summary>
    private static async Task SignOutWhileCompletionIsOnItsWay(SyncActor actor, AccountService account, ClerkClient clerk, TaskCompletionSource heldClerkAnswer)
    {
        using var releaseActor = new ManualResetEventSlim();
        var entered = Gate();
        actor.Post(() => { entered.SetResult(); releaseActor.Wait(TimeSpan.FromSeconds(5)); });
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var signedOut = Gate();
        actor.Post(() => { _ = SignOut(); });
        async Task SignOut() { await account.SignOutAsync(); signedOut.SetResult(); }
        try
        {
            heldClerkAnswer.SetResult();
            Assert.True(await Eventually(() => clerk.CurrentSessionId == "sess_A"));
        }
        finally { releaseActor.Set(); }
        await signedOut.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task AnEmailSignInCompletingAfterASignOutNeverShowsAsSignedIn()
    {
        var actor = SyncActor.CreateDedicated();
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins/attempt/attempt_first_factor", new { response = new { id = "attempt", status = "complete", created_session_id = "sess_A" } });
        fake.On("POST /v1/client/sessions/sess_A/touch", new { client = ClerkTests.ClientJson("sess_A", "A") });
        fake.On("POST /v1/client/sessions/sess_A/remove", new { response = new { id = "sess_A" } });
        var touch = fake.Hold("POST /v1/client/sessions/sess_A/touch");
        var account = new AccountService(Deployment, new MemoryClerkStore(), actor, http: ConfigFor(ClerkTests.TestKey), clerkHttp: fake) { WatchesNetwork = false };
        await account.LoadAsync();
        var verify = account.VerifyEmailAsync(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, "attempt", "a@example.test"), "424242");
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath.EndsWith("/touch", StringComparison.Ordinal))));
        await SignOutWhileCompletionIsOnItsWay(actor, account, account.Clerk!, touch);
        await Swallow(verify.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Null(account.Clerk!.CurrentSessionId);
        Assert.False(await actor.Run(() => account.IsSignedIn));
        Assert.Null(await actor.Run(() => account.CurrentSignIn));
    }

    [Fact]
    public async Task ASocialSignInCompletingAfterASignOutNeverShowsAsSignedIn()
    {
        var actor = SyncActor.CreateDedicated();
        var fake = new FakeClerk();
        fake.On("GET /v1/client/sign_ins/sia_1", new { response = new { id = "sia_1", status = "complete", created_session_id = "sess_A", first_factor_verification = new { status = "verified" } } });
        fake.On("POST /v1/client/sessions/sess_A/touch", new { client = ClerkTests.ClientJson("sess_A", "A") });
        fake.On("POST /v1/client/sessions/sess_A/remove", new { response = new { id = "sess_A" } });
        var touch = fake.Hold("POST /v1/client/sessions/sess_A/touch");
        var account = new AccountService(Deployment, new MemoryClerkStore(), actor, http: ConfigFor(ClerkTests.TestKey), clerkHttp: fake) { WatchesNetwork = false };
        await account.LoadAsync();
        var complete = account.CompleteOAuthAsync(new ClerkOAuthStart(new Uri("https://accounts.example.test/oauth"), "sia_1"), new Uri("openmusic://oauth-callback?rotating_token_nonce=n"));
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath.EndsWith("/touch", StringComparison.Ordinal))));
        await SignOutWhileCompletionIsOnItsWay(actor, account, account.Clerk!, touch);
        await Swallow(complete.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Null(account.Clerk!.CurrentSessionId);
        Assert.False(await actor.Run(() => account.IsSignedIn));
    }

    // 4 (P2, AccountService.cs:179): the old server's configuration installed its Clerk app after a server switch.

    private sealed class TwoServers : IHttpPoster
    {
        public readonly TaskCompletionSource OldStarted = Gate(), ReleaseOld = Gate();
        public async Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
        {
            if (url.Host == "old.test") { OldStarted.TrySetResult(); await ReleaseOld.Task; }
            var key = ClerkTests.PublishableKey(url.Host == "old.test" ? "old.clerk.test" : "new.clerk.test");
            return (System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new { status = "success", value = new { auth = new { kind = "clerk", publishableKey = key } } }), 200);
        }
    }

    [Fact]
    public async Task TheOldServersConfigurationNeverInstallsAfterASwitchAndNeverHoldsUpTheNewOne()
    {
        var actor = SyncActor.CreateDedicated();
        var servers = new TwoServers();
        var account = new AccountService(new Uri("https://old.test"), new MemoryClerkStore(), actor, http: servers, clerkHttp: new FakeClerk()) { WatchesNetwork = false };
        var load = account.LoadAsync();
        await servers.OldStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await account.SetServerAsync(new Uri("https://new.test"));
        Assert.Equal("new.clerk.test", account.Clerk?.FrontendApi.Host);
        servers.ReleaseOld.SetResult();
        await Swallow(load.WaitAsync(TimeSpan.FromSeconds(5)));
        await actor.Run(() => { });
        Assert.Equal("new.test", account.Server.Url.Host);
        Assert.Equal("new.clerk.test", account.Clerk?.FrontendApi.Host);
    }

    // The review of 77616dc: three paths where the account layer still acted on a ticket it hadn't checked.

    private sealed class ServerKeys(TaskCompletionSource? holdOld = null) : IHttpPoster
    {
        public readonly TaskCompletionSource OldStarted = Gate();
        public async Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
        {
            if (url.Host == "old.test" && holdOld is { } hold) { OldStarted.TrySetResult(); await hold.Task.ConfigureAwait(false); }
            var key = ClerkTests.PublishableKey(url.Host == "old.test" ? "old.clerk.test" : "new.clerk.test");
            return (System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new { status = "success", value = new { auth = new { kind = "clerk", publishableKey = key } } }), 200);
        }
    }

    private static FakeClerk ClerkFor(params string[] users)
    {
        var fake = new FakeClerk();
        foreach (var user in users)
        {
            fake.On($"POST /v1/client/sign_ins/{user}/attempt_first_factor", new { response = new { id = user, status = "complete", created_session_id = "sess_" + user } }, "client_tok");
            fake.On($"POST /v1/client/sessions/sess_{user}/touch", new { client = ClerkTests.ClientJson("sess_" + user, user) }, "client_tok");
            fake.On($"POST /v1/client/sessions/sess_{user}/remove", new { response = new { id = "sess_" + user } });
        }
        return fake;
    }

    private static ClerkEmailChallenge Challenge(string user) => new(ClerkChallengeKind.SignIn, user, $"{user}@example.test");

    [Fact]
    public async Task TheOldServersLateConfigurationNeverClearsTheNewServersSavedSignIn()
    {
        var actor = SyncActor.CreateDedicated();
        var hold = Gate();
        var servers = new ServerKeys(hold);
        var store = new MemoryClerkStore();
        var account = new AccountService(new Uri("https://old.test"), store, actor, http: servers, clerkHttp: ClerkFor("B")) { WatchesNetwork = false };
        var load = account.LoadAsync();
        await servers.OldStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await account.SetServerAsync(new Uri("https://new.test"));
        await account.VerifyEmailAsync(Challenge("B"), "424242");
        Assert.Equal("sess_B", store.Load()?.SessionId);
        hold.SetResult();
        await Swallow(load.WaitAsync(TimeSpan.FromSeconds(5)));
        await actor.Run(() => { });
        Assert.Equal("sess_B", store.Load()?.SessionId);
        Assert.Equal("sess_B", account.Clerk?.CurrentSessionId);
        Assert.Equal("B", (await actor.Run(() => account.User))?.Id);
    }

    [Fact]
    public async Task ASignInStartedWhileASwitchWaitsOnTheOldRemovalNeverStaysInTheOldServersClerk()
    {
        var actor = SyncActor.CreateDedicated();
        var fake = ClerkFor("A", "B");
        var account = new AccountService(new Uri("https://old.test"), new MemoryClerkStore(), actor, http: new ServerKeys(), clerkHttp: fake) { WatchesNetwork = false };
        await account.LoadAsync();
        await account.VerifyEmailAsync(Challenge("A"), "424242");
        var oldClerk = account.Clerk!;
        // The switch waits on A's removal at the old server's Clerk; B signs in meanwhile.
        var aRemoval = fake.Hold("POST /v1/client/sessions/sess_A/remove");
        var change = account.SetServerAsync(new Uri("https://new.test"));
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath == "/v1/client/sessions/sess_A/remove")));
        await Swallow(account.VerifyEmailAsync(Challenge("B"), "424242").WaitAsync(TimeSpan.FromSeconds(5)));
        aRemoval.SetResult();
        await change.WaitAsync(TimeSpan.FromSeconds(5));
        await actor.Run(() => { });
        Assert.Equal("new.test", account.Server.Url.Host);
        Assert.Null(oldClerk.CurrentSessionId);
        // Whatever shows belongs to the Clerk of the server chosen now.
        var (user, clerk) = await actor.Run(() => (account.User, account.Clerk));
        if (user is not null)
        {
            Assert.NotSame(oldClerk, clerk);
            Assert.Equal("sess_" + user.Id, clerk!.CurrentSessionId);
        }
    }

    [Fact]
    public async Task AStaleSignInEndsItsSessionWithTheClientTokenThatMadeItEvenAfterASignOutClearedIt()
    {
        var fake = ClerkFor("A");
        var clerk = new ClerkClient(ClerkTests.TestKey, new MemoryClerkStore(), fake);
        var touch = fake.Hold("POST /v1/client/sessions/sess_A/touch");
        var verify = clerk.VerifyEmailAsync(Challenge("A"), "424242");
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath.EndsWith("/touch", StringComparison.Ordinal))));
        await clerk.SignOutAsync();
        touch.SetResult();
        await Swallow(verify.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath == "/v1/client/sessions/sess_A/remove")));
        var removal = fake.Requests.Last(r => r.Url.AbsolutePath == "/v1/client/sessions/sess_A/remove");
        Assert.Equal("client_tok", FakeClerk.Header(removal, "Authorization"));
        Assert.Null(clerk.CurrentSessionId);
    }

    // 5 (P2, SignInSync.cs:192, RetryNow, SyncCoordinator.cs:418): public methods changed actor state off the actor.

    [Fact]
    public async Task ReconcileAllFromAnotherThreadRunsTheTransferOnTheActor()
    {
        var actor = SyncActor.CreateDedicated();
        var sync = new SignInSync(new SyncCredentialStore(new MemorySecretStore()), new SwitchableEndpoint(), actor);
        var transfer = new RecordingTransfer(actor) { Text = "A-signin" };
        await actor.Run(() => sync.BeginSession("A"));
        await sync.RegisterAsync(transfer);
        await actor.RunAsync(sync.Settle);
        await Task.Run(sync.ReconcileAll);
        await actor.Run(() => { });
        await actor.RunAsync(sync.Settle);
        Assert.False(transfer.OffActor);
    }

    [Fact]
    public async Task RetryNowFromAnotherThreadRetriesTheSignOutOnTheActor()
    {
        var actor = SyncActor.CreateDedicated();
        var endpoint = new SwitchableEndpoint();
        var sync = new SignInSync(new SyncCredentialStore(new MemorySecretStore()), endpoint, actor);
        var transfer = new RecordingTransfer(actor) { Text = "A-signin", RefuseSignOuts = true };
        await actor.Run(() => sync.BeginSession("A"));
        // Another device signed out everywhere; deleting the sign-in here fails, so it is pending.
        endpoint.VaultEntries = [new VaultEntry { Provider = ProviderId.Spotify, KeyId = "", Revision = 3, UpdatedAt = 1, UpdatedBy = new DeviceId("other") }];
        await sync.RegisterAsync(transfer);
        await actor.RunAsync(sync.Settle);
        Assert.IsType<SignInStatus.Failed>(await actor.Run(() => sync.Status[ProviderId.Spotify]));
        transfer.RefuseSignOuts = false;
        transfer.OffActor = false;
        await Task.Run(sync.RetryNow);
        await actor.Run(() => { });
        await actor.RunAsync(sync.Settle);
        Assert.Contains("A-signin", transfer.Deleted);
        Assert.False(transfer.OffActor);
    }

    [Fact]
    public async Task DismissSuggestionFromAnotherThreadAnnouncesItOnTheActor()
    {
        var actor = SyncActor.CreateDedicated();
        var hub = new FakeHub();
        var now = hub.Clock.Now();
        var mac = new DeviceId("mac");
        hub.Devices = [new SyncDevice { Id = mac, Name = "Mac", Platform = DevicePlatform.Mac, Model = "m", AppVersion = "1", LastSeenAt = now }];
        hub.Playback = new Dictionary<DeviceId, RemotePlayback>
        {
            [mac] = new() { DeviceId = mac, Track = new Track { ProviderID = "t", Provider = ProviderId.Spotify, Title = "Song" }, Anchor = new PlaybackAnchor { PositionAt = now, IsPlaying = true, Rate = 1, Volume = 1 }, UpdatedAt = now },
        };
        var coordinator = new SyncCoordinator(hub, new FakePlayer(), actor);
        await actor.Run(() => { });
        var offActor = false;
        var raised = 0;
        coordinator.PropertyChanged += (_, _) => { offActor |= !actor.IsCurrent; Interlocked.Increment(ref raised); };
        await Task.Run(coordinator.DismissSuggestion);
        await actor.Run(() => { });
        Assert.True(raised > 0);
        Assert.False(offActor);
        Assert.Null(await actor.Run(() => coordinator.ContinueSuggestion));
    }

    [Fact]
    public async Task AHandoffStartedForOneAccountNeverLoadsThePlayerOrPausesTheSourceForTheNext()
    {
        var actor = SyncActor.CreateDedicated();
        var hub = new FakeHub();
        var now = hub.Clock.Now();
        var mac = new DeviceId("mac");
        var track = new Track { ProviderID = "t", Provider = ProviderId.Spotify, Title = "Song" };
        hub.Devices = [new SyncDevice { Id = mac, Name = "Mac", Platform = DevicePlatform.Mac, Model = "m", AppVersion = "1", LastSeenAt = now }];
        hub.Playback = new Dictionary<DeviceId, RemotePlayback>
        {
            [mac] = new() { DeviceId = mac, Track = track, Anchor = new PlaybackAnchor { PositionAt = now, IsPlaying = true, Rate = 1, Volume = 1 }, UpdatedAt = now },
        };
        hub.Queues[mac] = new QueueWindow { Entries = [new QueueEntry(track)], Index = 0 };
        // The account changes while the queue is on its way.
        hub.WillFetchQueue = () => Interlocked.Increment(ref hub.Session);
        var player = new FakePlayer();
        var coordinator = new SyncCoordinator(hub, player, actor);
        var error = await Assert.ThrowsAsync<SyncException>(() => coordinator.PlayHereAsync(mac));
        Assert.Equal(SyncErrorKind.AuthChanged, error.Kind);
        Assert.Empty(player.Queue);
        Assert.Empty(hub.Sent);
    }

    [Fact]
    public async Task ActorStateTouchedOffTheActorFailsInDebugBuilds()
    {
        var actor = SyncActor.CreateDedicated();
        var sync = new SignInSync(new SyncCredentialStore(new MemorySecretStore()), new SwitchableEndpoint(), actor);
        // An internal method (no dispatch of its own) called from a test thread. (Not counted: the suite asserts the count stays 0.)
        var thrown = await Task.Run(() =>
        {
            SyncActor.ExpectViolation(true);
            try { return Record.Exception(() => sync.BeginSession("A")); }
            finally { SyncActor.ExpectViolation(false); }
        });
#if DEBUG
        Assert.IsType<InvalidOperationException>(thrown);
#else
        Assert.Null(thrown);
#endif
        // Through its public method it dispatches and nothing fires.
        await Task.Run(sync.ReconcileAll);
        await actor.Run(() => { });
    }

    // 6 (P2, ConvexClient.cs:716): a one-shot query for A checked its scope once, then took B's result.

    [Fact]
    public async Task AQueryMadeForANeverReturnsAResultComputedAfterTheSwitchToB()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        try
        {
            var scope = await client.SetAuthAsync(new FakeTokens(Jwt("A")), "A");
            client.Start();
            Assert.True(await Eventually(() => transport.Sockets.Count > 0));
            var socket = transport.Sockets[0];
            socket.Open();
            Assert.True(await Eventually(() => socket.MessagesOfType("Connect").Count > 0));
            var query = client.QueryAsync("currentUser:data", ConvexValue.Object(), scope: scope);
            Assert.True(await Eventually(() => socket.MessagesOfType("ModifyQuerySet").Any(m => m["modifications"]!.ArrayValue!.Any(x => x["type"]?.StringValue == "Add"))));
            var add = socket.MessagesOfType("ModifyQuerySet").SelectMany(m => m["modifications"]!.ArrayValue!).First(x => x["type"]?.StringValue == "Add");
            var id = (int)add["queryId"]!.DoubleValue!.Value;
            await client.SetAuthAsync(new FakeTokens(Jwt("B")), "B");
            socket.Receive(Transition((0, 0), (1, 5), 0, client.CurrentIdentityVersion, Updated(id, "\"B data\"")));
            var error = await Assert.ThrowsAsync<ConvexClientException>(async () => await query.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.Equal(ConvexErrorKind.AuthChanged, error.Kind);
        }
        finally { client.Stop(); }
    }
}

public class IdentityRaceServiceTests : ServiceTests
{
    // Found by the account interleavings: a sign-in sync queued before StopAsync made a vault write afterwards, and the
    // write started the stopped service again: an old process's service, live beside the new one on the same store.

    [Fact]
    public async Task WorkQueuedBeforeAStopNeverStartsTheServiceAgain()
    {
        var server = new FakeKeyServer();
        var service = Device(server, "PC");
        await SignIn(service, "A");
        Assert.True(await WaitUntil(service, () => service.KeyStatus is KeyStatus.Available && service.VaultEntries is not null));
        var transfer = new RecordingTransfer(service.Actor) { Text = "A-signin" };
        await service.SignIns.RegisterAsync(transfer);
        await service.Actor.RunAsync(service.SignIns.Settle);
        // A reconcile waits on the export; the service stops meanwhile.
        transfer.ExportStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        transfer.ReleaseExport = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = transfer.ReleaseExport;
        await service.Actor.Run(() => { transfer.Text = "A-signin-changed"; service.SignIns.ReconcileAll(); });
        await transfer.ExportStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await service.StopAsync();
        var calls = server.Calls.Count;
        release.SetResult();
        await service.Actor.RunAsync(service.SignIns.Settle);
        await Task.Delay(300);
        Assert.Equal(calls, server.Calls.Count);
        Assert.Equal(ConnectionPhase.Stopped, service.Client.Status.State.Phase);
        // Start (or a sign-in) starts it again.
        service.Start();
        Assert.True(await Eventually(() => server.Calls.Count > calls));
    }

    // 1, through a real SyncService and the fake key server: B's device never gets A's provider sign-out.

    [Fact]
    public async Task AProviderSignOutQueuedForANeverReachesBsAccountOrBsLocalSignIn()
    {
        var server = new FakeKeyServer();
        var service = Device(server, "PC");
        await SignIn(service, "A");
        Assert.True(await WaitUntil(service, () => service.KeyStatus is KeyStatus.Available && service.VaultEntries is not null));
        var transfer = new RecordingTransfer(service.Actor);
        await service.SignIns.RegisterAsync(transfer);
        await service.Actor.RunAsync(service.SignIns.Settle);
        transfer.ExportStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        transfer.ReleaseExport = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = transfer.ReleaseExport;
        await service.Actor.Run(service.SignIns.ReconcileAll);
        await transfer.ExportStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var signOut = service.SignIns.SignOutAsync(ProviderId.Spotify, everywhere: true);
        await SignIn(service, "B");
        Assert.True(await WaitUntil(service, () => service.VaultEntries is not null && service.SignedInUserId == "B"));
        await service.Actor.Run(() => transfer.Text = "B-local-signin");
        release.SetResult();
        try { await signOut.WaitAsync(TimeSpan.FromSeconds(5)); } catch (SyncException) { }
        await service.Actor.RunAsync(service.SignIns.Settle);
        Assert.DoesNotContain(server.CallsTo("vault:signOutEverywhere"), c => c.User == "B");
        Assert.DoesNotContain("B-local-signin", transfer.Deleted);
    }
}

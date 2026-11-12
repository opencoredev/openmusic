using System.Diagnostics;
using Medley.Sync.Convex;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

/// <summary>Ports of ConvexClientTests.swift, ConvexAuthTests.swift and the identity cases of the review tests.</summary>
public class ConvexClientTests
{
    private static ConvexValue Obj(params (string, ConvexValue)[] fields) => ConvexValue.Object(fields);
    private static ConvexValue S(string s) => ConvexValue.String(s);
    private static ConvexValue F(double d) => ConvexValue.Float64(d);

    private static int QueryId(FakeSocket socket) =>
        (int)socket.MessagesOfType("ModifyQuerySet")[0]["modifications"]!.ArrayValue![0]["queryId"]!.DoubleValue!.Value;

    private static async Task<FakeSocket> Connected(FakeTransport transport, int index = 0)
    {
        Assert.True(await Eventually(() => transport.Sockets.Count == index + 1));
        var socket = transport.Sockets[index];
        socket.Open();
        Assert.True(await Eventually(() => socket.MessagesOfType("ModifyQuerySet").Count >= 1));
        return socket;
    }

    private static List<ConvexQueryResult> Collect(ConvexSubscription subscription, CancellationToken ct = default)
    {
        var items = new List<ConvexQueryResult>();
        _ = Task.Run(async () =>
        {
            try { await foreach (var r in subscription.Results.ReadAllAsync(ct)) lock (items) items.Add(r); } catch (OperationCanceledException) { }
        });
        return items;
    }

    private static int Count(List<ConvexQueryResult> items) { lock (items) return items.Count; }
    private static ConvexQueryResult At(List<ConvexQueryResult> items, int i) { lock (items) return items[i]; }

    [Fact]
    public void SyncUrlMatchesTheNpmClient()
    {
        Assert.Equal("wss://example-123.convex.cloud/api/1.49.0/sync", MakeClient(new FakeTransport()).SyncUrl.AbsoluteUri);
    }

    [Fact]
    public async Task ConnectsSubscribesAndDeliversTransitions()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        using var sub = client.Subscribe("devices:list", Obj(("token", S("t"))));
        var results = Collect(sub);
        client.Start();
        var socket = await Connected(transport);
        var connect = socket.Messages[0];
        Assert.Equal(S("Connect"), connect["type"]);
        Assert.Equal(F(0), connect["connectionCount"]);
        Assert.Equal(S("InitialConnect"), connect["lastCloseReason"]);
        Assert.Equal(36, connect["sessionId"]!.StringValue!.Length);
        var modify = socket.MessagesOfType("ModifyQuerySet")[0];
        Assert.Equal(F(0), modify["baseVersion"]);
        Assert.Equal(F(1), modify["newVersion"]);
        var add = modify["modifications"]!.ArrayValue![0];
        Assert.Equal(S("Add"), add["type"]);
        Assert.Equal(S("devices:list"), add["udfPath"]);
        Assert.Equal(ConvexValue.Array(Obj(("token", S("t")))), add["args"]);
        var id = QueryId(socket);

        socket.Receive(Transition((0, 0), (1, 5), Updated(id, "{\"n\":{\"$integer\":\"BwAAAAAAAAA=\"}}")));
        Assert.True(await Eventually(() => Count(results) == 1));
        Assert.Equal(Obj(("n", ConvexValue.Int64(7))), At(results, 0).Get());
        socket.Receive(Transition((1, 5), (1, 9), Updated(id, "{\"n\":2}")));
        Assert.True(await Eventually(() => Count(results) == 2));
        Assert.Equal(Obj(("n", F(2))), At(results, 1).Get());
        Assert.Equal(ConnectionPhase.Connected, client.Status.State.Phase);
        client.Stop();
    }

    [Fact]
    public async Task MutationsResolveOnlyAfterTheirTransition()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        client.Start();
        var socket = await Connected(transport);
        socket.Receive(Transition((0, 0), (1, 1)));
        var order = new List<string>();
        var first = client.MutationAsync("playback:publish", Obj()).ContinueWith(t => { lock (order) order.Add("first"); return t.Result; });
        Assert.True(await Eventually(() => socket.MessagesOfType("Mutation").Count == 1));
        var second = client.MutationAsync("devices:heartbeat", Obj()).ContinueWith(t => { lock (order) order.Add("second"); return t.Result; });
        Assert.True(await Eventually(() => socket.MessagesOfType("Mutation").Count == 2));
        Assert.Equal([0.0, 1.0], socket.MessagesOfType("Mutation").Select(m => m["requestId"]!.DoubleValue!.Value));
        Assert.Equal(S("playback:publish"), socket.MessagesOfType("Mutation")[0]["udfPath"]);

        // Responses arrive out of order; the second's commit timestamp is reached first.
        socket.Receive(MutationOk(1, "{\"serverNow\":2}", 20));
        socket.Receive(MutationOk(0, "{\"serverNow\":1}", 30));
        await Task.Delay(50);
        lock (order) Assert.Empty(order);   // nothing resolves before the client has seen the commit
        socket.Receive(Transition((1, 1), (1, 25)));
        Assert.True(await Eventually(() => { lock (order) return order.SequenceEqual(["second"]); }));
        socket.Receive(Transition((1, 25), (1, 30)));
        Assert.True(await Eventually(() => { lock (order) return order.SequenceEqual(["second", "first"]); }));
        Assert.Equal(Obj(("serverNow", F(1))), (await first).Value);
        Assert.Equal(Obj(("serverNow", F(2))), (await second).Value);

        // A failure resolves at once with the ConvexError payload.
        var failing = client.MutationAsync("devices:rename", Obj());
        Assert.True(await Eventually(() => socket.MessagesOfType("Mutation").Count == 3));
        socket.Receive("{\"type\":\"MutationResponse\",\"requestId\":2,\"success\":false,\"result\":\"Uncaught ConvexError\",\"logLines\":[],\"errorData\":{\"code\":\"notFound\",\"message\":\"No such device in this library.\"}}");
        var error = await Assert.ThrowsAsync<ConvexClientException>(() => failing);
        Assert.Equal("notFound", error.Code);
        Assert.Equal("No such device in this library.", error.Message);
        client.Stop();
    }

    [Fact]
    public async Task ReconnectReplaysQueriesAndUnansweredMutations()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        using var sub = client.Subscribe("playback:list", Obj(("token", S("t"))));
        var results = Collect(sub);
        client.Start();
        var first = await Connected(transport);
        var id = QueryId(first);
        first.Receive(Transition((0, 0), (1, 10), Updated(id, "1")));
        Assert.True(await Eventually(() => Count(results) == 1));
        var pending = client.MutationAsync("commands:send", Obj(("x", F(1))));
        Assert.True(await Eventually(() => first.MessagesOfType("Mutation").Count == 1));

        first.ServerClose("network down");
        Assert.True(await Eventually(() => transport.Sockets.Count == 2));
        var second = transport.Sockets[1];
        second.Open();
        Assert.True(await Eventually(() => second.MessagesOfType("Mutation").Count == 1));
        var connect = second.Messages[0];
        Assert.Equal(S("Connect"), connect["type"]);
        Assert.Equal(F(1), connect["connectionCount"]);
        Assert.Equal(S("network down"), connect["lastCloseReason"]);
        Assert.Equal(first.Messages[0]["sessionId"], connect["sessionId"]);
        Assert.Equal(S(Ts(10)), connect["maxObservedTimestamp"]);
        var replay = second.MessagesOfType("ModifyQuerySet")[0];
        Assert.Equal(F(0), replay["baseVersion"]);
        Assert.Equal(F(1), replay["newVersion"]);
        Assert.Equal([F(id)], replay["modifications"]!.ArrayValue!.Select(m => m["queryId"]!));
        Assert.Equal(F(0), second.MessagesOfType("Mutation")[0]["requestId"]);

        // The new socket starts again from version zero.
        second.Receive(Transition((0, 0), (1, 40), Updated(id, "2")));
        second.Receive(MutationOk(0, "\"done\"", 35));
        Assert.Equal(S("done"), (await pending).Value);
        Assert.True(await Eventually(() => Count(results) == 2));
        Assert.Equal(2, client.Status.Connections);
        client.Stop();
    }

    [Fact]
    public async Task ATransitionFromTheWrongVersionRestartsTheSocket()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        client.Start();
        var socket = await Connected(transport);
        socket.Receive(Transition((3, 99), (4, 100)));
        Assert.True(await Eventually(() => socket.IsClosed));
        Assert.True(await Eventually(() => transport.Sockets.Count == 2));
        client.Stop();
    }

    [Fact]
    public async Task ChunkedTransitionsAreReassembled()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        using var sub = client.Subscribe("q:a", Obj());
        var results = Collect(sub);
        client.Start();
        var socket = await Connected(transport);
        var full = Transition((0, 0), (1, 3), Updated(QueryId(socket), "\"a long value\""));
        var parts = new[] { full[..(full.Length / 2)], full[(full.Length / 2)..] };
        for (var i = 0; i < parts.Length; i++)
            socket.Receive(Obj(("type", S("TransitionChunk")), ("chunk", S(parts[i])), ("partNumber", F(i)), ("totalParts", F(2)), ("transitionId", S("x"))).JsonString());
        Assert.True(await Eventually(() => Count(results) == 1));
        Assert.Equal(S("a long value"), At(results, 0).Get());
        client.Stop();
    }

    [Fact]
    public async Task PingsKeepTheSocketAndSilenceReconnects()
    {
        var transport = new FakeTransport();
        var options = FastOptions();
        options.InactivityTimeout = TimeSpan.FromMilliseconds(150);
        var client = new ConvexClient(Deployment, transport, new FakeHttp(), options);
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        for (var i = 0; i < 4; i++)
        {
            await Task.Delay(80);
            transport.Sockets[0].Receive("{\"type\":\"Ping\"}");
        }
        Assert.Single(transport.Sockets);
        Assert.True(await Eventually(() => transport.Sockets.Count == 2));
        client.Stop();
    }

    [Fact]
    public async Task FallsBackToHttpWhenTheSocketCantConnect()
    {
        var transport = new FakeTransport { AutoFail = true };
        var http = new FakeHttp
        {
            Respond = (path, body) => path.EndsWith("/api/query")
                ? Obj(("status", S("success")), ("value", Obj(("path", body["path"]!))))
                : Obj(("status", S("success")), ("value", Obj(("serverNow", F(123))))),
        };
        var client = MakeClient(transport, http, fallbackAfter: 3);
        using var sub = client.Subscribe("devices:list", Obj(("token", S("t"))));
        var results = Collect(sub);
        client.Start();
        Assert.True(await Eventually(() => client.Status.HttpFallback));
        Assert.True(await Eventually(() => Count(results) == 1));
        Assert.Equal(Obj(("path", S("devices:list"))), At(results, 0).Get());
        var query = http.Requests.First(r => r.Path == "/api/query");
        Assert.Equal(S("convex_encoded_json"), query.Body["format"]);
        Assert.Equal(ConvexValue.Array(Obj(("token", S("t")))), query.Body["args"]);
        var result = await client.MutationAsync("devices:heartbeat", Obj(("token", S("t"))));
        Assert.Equal(Obj(("serverNow", F(123))), result.Value);
        Assert.Contains(http.Requests, r => r.Path == "/api/mutation");

        // Unchanged poll results aren't delivered again; the poll stops in the background.
        await Task.Delay(150);
        Assert.Equal(1, Count(results));
        client.SetForeground(false);
        await Task.Delay(40);
        var before = http.Requests.Count;
        await Task.Delay(200);
        Assert.Equal(before, http.Requests.Count);

        // Once the socket connects again, the fallback ends.
        transport.AutoFail = false;
        Assert.True(await Eventually(() => transport.Sockets.LastOrDefault() is { IsClosed: false }));
        transport.Sockets[^1].Open();
        Assert.True(await Eventually(() => client.Status is { State.Phase: ConnectionPhase.Connected, HttpFallback: false, Connections: 1 }));
        client.Stop();
    }

    [Fact]
    public async Task AMutationTheSocketNeverAnsweredFinishesOverHttpWhenTheFallbackStarts()
    {
        var transport = new FakeTransport();
        var http = new FakeHttp { Respond = (_, _) => Obj(("status", S("success")), ("value", Obj(("serverNow", F(7))))) };
        var client = MakeClient(transport, http, fallbackAfter: 1);
        client.Start();
        var socket = await Connected(transport);
        socket.Receive(Transition((0, 0), (1, 1)));
        var pending = client.MutationAsync("commands:send", Obj(("clientId", S("c-1"))));
        Assert.True(await Eventually(() => socket.MessagesOfType("Mutation").Count == 1));
        transport.AutoFail = true;
        socket.ServerClose("network down");
        Assert.Equal(Obj(("serverNow", F(7))), (await pending).Value);
        var retried = http.Requests.First(r => r.Path == "/api/mutation");
        Assert.Equal(S("commands:send"), retried.Body["path"]);
        Assert.Equal(ConvexValue.Array(Obj(("clientId", S("c-1")))), retried.Body["args"]);   // the retry carries the same client id
        client.Stop();
    }

    [Fact]
    public async Task AMutationWithNoAnswerFailsAfterTheTimeoutAndIsNotReplayed()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport, mutationTimeout: TimeSpan.FromMilliseconds(150));
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        var sw = Stopwatch.StartNew();
        var e = await Assert.ThrowsAsync<ConvexClientException>(() => client.MutationAsync("playback:publish", Obj()));
        Assert.Equal(ConvexErrorKind.Transport, e.Kind);
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(2));
        transport.Sockets[0].ServerClose();
        Assert.True(await Eventually(() => transport.Sockets.Count == 2));
        transport.Sockets[1].Open();
        await Task.Delay(50);
        Assert.Empty(transport.Sockets[1].MessagesOfType("Mutation"));
        client.Stop();
    }

    [Fact]
    public async Task APollAfterTheSocketDeliveredNewerValuesIsNotDroppedAsUnchanged()
    {
        var transport = new FakeTransport { AutoFail = true };
        var polled = F(1);
        var http = new FakeHttp { Respond = (_, _) => Obj(("status", S("success")), ("value", Volatile.Read(ref polled))) };
        var client = MakeClient(transport, http, fallbackAfter: 3);
        using var sub = client.Subscribe("q:x", Obj());
        var results = Collect(sub);
        client.Start();
        Assert.True(await Eventually(() => Count(results) == 1));
        transport.AutoFail = false;
        Assert.True(await Eventually(() => transport.Sockets.LastOrDefault() is { IsClosed: false }));
        var socket = transport.Sockets[^1];
        socket.Open();
        Assert.True(await Eventually(() => socket.MessagesOfType("ModifyQuerySet").Count == 1));
        socket.Receive(Transition((0, 0), (1, 5), Updated(QueryId(socket), "2")));
        Assert.True(await Eventually(() => Count(results) == 2));
        transport.AutoFail = true;
        socket.ServerClose();
        Assert.True(await Eventually(() => client.Status.HttpFallback));
        Assert.True(await Eventually(() => Count(results) == 3));
        Assert.Equal(F(1), At(results, 2).Get());
        client.Stop();
    }

    [Fact]
    public async Task SuspendClosesTheSocketKeepsTheQueriesAndStartResumes()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        using var sub = client.Subscribe("devices:list", Obj());
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => client.Status.State.Phase == ConnectionPhase.Connected));
        client.Suspend();
        Assert.True(transport.Sockets[0].IsClosed);
        Assert.Equal(ConnectionPhase.Idle, client.Status.State.Phase);
        await Task.Delay(100);
        Assert.Single(transport.Sockets);
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 2));
        transport.Sockets[1].Open();
        Assert.True(await Eventually(() => transport.Sockets[1].MessagesOfType("ModifyQuerySet").Count == 1));
        Assert.Single(transport.Sockets[1].MessagesOfType("ModifyQuerySet")[0]["modifications"]!.ArrayValue!);
        client.Stop();
    }

    [Fact]
    public async Task ActionsResolveOnTheirResponseAndAreNotReplayed()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        client.Start();
        var socket = await Connected(transport);
        var action = client.ActionAsync("files:upload", Obj(("n", F(1))));
        Assert.True(await Eventually(() => socket.MessagesOfType("Action").Count == 1));
        socket.Receive("{\"type\":\"ActionResponse\",\"requestId\":0,\"success\":true,\"result\":\"ok\",\"logLines\":[]}");
        Assert.Equal(S("ok"), await action);

        var lost = client.ActionAsync("files:upload", Obj(("n", F(2))));
        Assert.True(await Eventually(() => socket.MessagesOfType("Action").Count == 2));
        socket.ServerClose();
        Assert.True(await Eventually(() => transport.Sockets.Count == 2));
        transport.Sockets[1].Open();
        var e = await Assert.ThrowsAsync<ConvexClientException>(() => lost);
        Assert.Equal(ConvexErrorKind.Transport, e.Kind);
        Assert.Empty(transport.Sockets[1].MessagesOfType("Action"));
        client.Stop();
    }

    [Fact]
    public async Task StopFailsPendingCallsAndCancellingEndsOne()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        client.Start();
        await Connected(transport);
        using var cts = new CancellationTokenSource();
        var cancelled = client.MutationAsync("a:b", Obj(), cancellationToken: cts.Token);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelled);
        var pending = client.MutationAsync("a:c", Obj());
        client.Stop();
        Assert.Equal(ConvexErrorKind.Stopped, (await Assert.ThrowsAsync<ConvexClientException>(() => pending)).Kind);
    }

    // MARK: Authentication (ConvexAuthTests.swift)

    [Fact]
    public void JwtLifetimeDecidesTheRefresh()
    {
        var claims = JwtClaims.Decode(Jwt("u", 60))!;
        Assert.Equal(1_800_000_060, claims.Exp);
        Assert.Equal(1_800_000_000, claims.Iat);
        Assert.Equal("u", claims.Sub);
        var now = MonoClock.NowMs;
        var token = new AuthToken(Jwt("u", 60), now);
        Assert.Equal(now + 50_000, token.RefreshAt);
        Assert.False(token.NeedsRefresh(now + 49_000));
        Assert.True(token.NeedsRefresh(now + 50_000));
        Assert.Null(JwtClaims.Decode("not-a-jwt"));
        Assert.Null(new AuthToken("opaque").RefreshAt);
    }

    [Fact]
    public async Task AuthenticateGoesFirstOnEverySocket()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        await client.SetAuthAsync(new FakeTokens(Jwt("a")));
        using var sub = client.Subscribe("devices:list", Obj());
        client.Start();
        var socket = await Connected(transport);
        Assert.Equal(["Connect", "Authenticate", "ModifyQuerySet"], socket.Messages.Take(3).Select(m => m["type"]!.StringValue));
        var auth = socket.MessagesOfType("Authenticate")[0];
        Assert.Equal(S("User"), auth["tokenType"]);
        Assert.Equal(S(Jwt("a")), auth["value"]);
        Assert.Equal(F(0), auth["baseVersion"]);
        Assert.IsType<ConvexAuthState.Pending>(client.Status.Auth);
        socket.Receive(Transition((0, 0), (1, 1), 0, 1));
        Assert.True(await Eventually(() => client.Status.Auth is ConvexAuthState.Authenticated));
        socket.ServerClose();
        var second = await Connected(transport, 1);
        Assert.Equal(["Connect", "Authenticate", "ModifyQuerySet"], second.Messages.Take(3).Select(m => m["type"]!.StringValue));
        Assert.Equal(F(0), second.MessagesOfType("Authenticate")[0]["baseVersion"]);
        client.Stop();
    }

    [Fact]
    public async Task NoTokenMeansNoAuthenticate()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        await client.SetAuthAsync(new FakeTokens([null]));
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => client.Status.State.Phase == ConnectionPhase.Connected));
        Assert.Empty(transport.Sockets[0].MessagesOfType("Authenticate"));
        Assert.IsType<ConvexAuthState.None>(client.Status.Auth);
        client.Stop();
    }

    [Fact]
    public async Task RefreshesBeforeExpiryOnTheOpenSocket()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        var first = Jwt("a", 10.2);
        var second = Jwt("b", 3600);
        var tokens = new FakeTokens(first, second);
        await client.SetAuthAsync(tokens);
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => transport.Sockets[0].MessagesOfType("Authenticate").Count == 2));
        var refreshed = transport.Sockets[0].MessagesOfType("Authenticate")[1];
        Assert.Equal(S(second), refreshed["value"]);
        Assert.Equal(F(1), refreshed["baseVersion"]);
        Assert.True(tokens.ForcedRefreshes[^1]);   // a refresh skips the provider's cache
        Assert.Equal(2, client.CurrentIdentityVersion);
        client.Stop();
    }

    [Fact]
    public async Task AnAuthErrorFetchesAFreshTokenAndReconnects()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        var tokens = new FakeTokens(Jwt("stale"), Jwt("fresh"));
        await client.SetAuthAsync(tokens);
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => transport.Sockets[0].MessagesOfType("Authenticate").Count == 1));
        transport.Sockets[0].Receive("{\"type\":\"AuthError\",\"error\":\"Token expired\",\"baseVersion\":0,\"authUpdateAttempted\":true}");
        Assert.True(await Eventually(() => transport.Sockets[0].IsClosed));
        Assert.True(await Eventually(() => transport.Sockets.Count == 2));
        transport.Sockets[1].Open();
        Assert.True(await Eventually(() => transport.Sockets[1].MessagesOfType("Authenticate").Count == 1));
        Assert.Equal(S(Jwt("fresh")), transport.Sockets[1].MessagesOfType("Authenticate")[0]["value"]);
        Assert.Contains(true, tokens.ForcedRefreshes);
        client.Stop();
    }

    [Fact]
    public async Task RepeatedRefusalsGiveUpAndRunWithoutAnIdentity()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        await client.SetAuthAsync(new FakeTokens(Jwt("t1"), Jwt("t2"), Jwt("t3"), Jwt("t4")));
        client.Start();
        for (var i = 0; i < 3; i++)
        {
            Assert.True(await Eventually(() => transport.Sockets.Count == i + 1));
            transport.Sockets[i].Open();
            Assert.True(await Eventually(() => transport.Sockets[i].MessagesOfType("Authenticate").Count == 1));
            transport.Sockets[i].Receive("{\"type\":\"AuthError\",\"error\":\"No auth provider found matching the given token\",\"baseVersion\":0,\"authUpdateAttempted\":true}");
        }
        Assert.True(await Eventually(() => transport.Sockets.Count == 4));
        transport.Sockets[3].Open();
        Assert.True(await Eventually(() => client.Status.State.Phase == ConnectionPhase.Connected));
        Assert.Empty(transport.Sockets[3].MessagesOfType("Authenticate"));
        Assert.Equal(new ConvexAuthState.Failed("No auth provider found matching the given token"), client.Status.Auth);
        client.Stop();
    }

    [Fact]
    public async Task RemovingTheProviderDropsTheIdentityOnTheOpenSocket()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        await client.SetAuthAsync(new FakeTokens(Jwt("a")));
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => client.Status.State.Phase == ConnectionPhase.Connected));
        await client.SetAuthAsync(null);
        var auths = transport.Sockets[0].MessagesOfType("Authenticate");
        Assert.Equal(2, auths.Count);
        Assert.Equal(S("None"), auths[1]["tokenType"]);
        Assert.Equal(F(1), auths[1]["baseVersion"]);
        Assert.IsType<ConvexAuthState.None>(client.Status.Auth);
        client.Stop();
    }

    [Fact]
    public async Task HttpCallsCarryTheBearerToken()
    {
        var transport = new FakeTransport { AutoFail = true };
        var http = new FakeHttp();
        var client = MakeClient(transport, http, fallbackAfter: 1);
        await client.SetAuthAsync(new FakeTokens(Jwt("a")));
        client.Start();
        Assert.True(await Eventually(() => client.Status.HttpFallback));
        await client.MutationAsync("devices:heartbeat", Obj());
        Assert.Equal($"Bearer {Jwt("a")}", http.Requests.First(r => r.Path == "/api/mutation").Headers["Authorization"]);
        client.Stop();
    }

    [Fact]
    public async Task ATokenThatExpiredWhileClosedIsReplacedBeforeTheSocketOpens()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        await client.SetAuthAsync(new FakeTokens(Jwt("old", 5), Jwt("new")));
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => transport.Sockets[0].MessagesOfType("Authenticate").FirstOrDefault()?["value"] == S(Jwt("new"))));
        client.Stop();
    }

    // MARK: Identity (fourth and sixth reviews)

    [Fact]
    public async Task QueuedCallsOfAnotherIdentityFailAndTheSameUserKeepsThem()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        var scopeA = await client.SetAuthAsync(new FakeTokens(Jwt("A")), "A");
        client.Start();   // never opened: calls wait unsent
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        var forA = client.MutationAsync("account:register", Obj(), scopeA);
        // The same user again (a new token source): queued calls stay.
        var same = await client.SetAuthAsync(new FakeTokens(Jwt("A")), "A");
        Assert.Equal(scopeA, same);
        Assert.False(forA.IsCompleted);
        // Another user: they fail now and are never sent under B.
        var scopeB = await client.SetAuthAsync(new FakeTokens(Jwt("B")), "B");
        Assert.NotEqual(scopeA, scopeB);
        Assert.Equal(ConvexErrorKind.AuthChanged, (await Assert.ThrowsAsync<ConvexClientException>(() => forA)).Kind);
        // A call made for A that only gets here now is refused at once.
        Assert.Equal(ConvexErrorKind.AuthChanged, (await Assert.ThrowsAsync<ConvexClientException>(() => client.MutationAsync("x:y", Obj(), scopeA))).Kind);
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => client.Status.State.Phase == ConnectionPhase.Connected));
        await Task.Delay(30);
        Assert.Empty(transport.Sockets[0].MessagesOfType("Mutation"));
        client.Stop();
    }

    [Fact]
    public async Task ACallForBNeverGoesOutOnASocketStillSpeakingForANorOverHttpWithAsToken()
    {
        var transport = new FakeTransport();
        var http = new FakeHttp();
        var client = MakeClient(transport, http, fallbackAfter: 1);
        await client.SetAuthAsync(new FakeTokens(Jwt("A")), "A");
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => client.Status.State.Phase == ConnectionPhase.Connected));
        // B's token can't be fetched (offline): the socket drops A's identity at once, and B's call waits.
        var offline = new FakeTokens(Jwt("B")) { Throw = new HttpRequestException("offline") };
        var scopeB = await client.SetAuthAsync(offline, "B");
        var call = client.MutationAsync("account:register", Obj(), scopeB);
        await Task.Delay(60);
        var socket = transport.Sockets[0];
        Assert.Equal(S("None"), socket.MessagesOfType("Authenticate")[^1]["tokenType"]);
        Assert.Empty(socket.MessagesOfType("Mutation"));
        // The socket dies: over HTTP it still waits (no token of B), never sent with A's JWT.
        transport.AutoFail = true;
        socket.ServerClose();
        await Task.Delay(100);
        Assert.DoesNotContain(http.Requests, r => r.Path == "/api/mutation");
        // B's token arrives: the call goes out with it.
        offline.Throw = null;
        Assert.True(await Eventually(() => http.Requests.Any(r => r.Path == "/api/mutation")));
        Assert.Equal($"Bearer {Jwt("B")}", http.Requests.First(r => r.Path == "/api/mutation").Headers["Authorization"]);
        await call;
        client.Stop();
    }

    [Fact]
    public async Task ATokenOfAnotherSubjectIsNeverUsed()
    {
        var transport = new FakeTransport();
        var client = MakeClient(transport);
        var tokens = new FakeTokens(Jwt("someone-else"), Jwt("u"));
        await client.SetAuthAsync(tokens, "u");
        client.Start();
        Assert.True(await Eventually(() => transport.Sockets.Count == 1));
        transport.Sockets[0].Open();
        Assert.True(await Eventually(() => transport.Sockets[0].MessagesOfType("Authenticate").Count >= 1));
        Assert.All(transport.Sockets[0].MessagesOfType("Authenticate"), a => Assert.Equal(S(Jwt("u")), a["value"]));
        client.Stop();
    }
}

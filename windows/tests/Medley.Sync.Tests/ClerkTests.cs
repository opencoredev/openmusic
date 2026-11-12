using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Web;
using Medley.Sync.Account;
using Medley.Sync.Convex;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

/// <summary>A scripted Clerk Frontend API (port of FakeClerk in ClerkClientTests.swift).</summary>
public sealed class FakeClerk : IClerkHttp
{
    public sealed record Answer(int Status, object Json, string? Authorization = null);
    private readonly object _lock = new();
    private readonly Dictionary<string, Func<ClerkRequest, Answer>> _routes = new();
    private readonly Dictionary<string, TaskCompletionSource> _holds = new();
    private readonly List<ClerkRequest> _requests = new();
    public IReadOnlyList<ClerkRequest> Requests { get { lock (_lock) return _requests.ToList(); } }

    public void On(string route, Func<ClerkRequest, Answer> answer) { lock (_lock) _routes[route] = answer; }
    public void On(string route, object json, string? authorization = null) => On(route, _ => new Answer(200, json, authorization));
    public TaskCompletionSource Hold(string route)
    {
        var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_lock) _holds[route] = gate;
        return gate;
    }

    public async Task<ClerkResponse> SendAsync(ClerkRequest request, CancellationToken cancellationToken = default)
    {
        var key = $"{request.Method} {request.Url.AbsolutePath}";
        Func<ClerkRequest, Answer>? handler;
        TaskCompletionSource? gate;
        lock (_lock)
        {
            _requests.Add(request);
            handler = _routes.GetValueOrDefault(key);
            gate = _holds.GetValueOrDefault(key);
        }
        if (gate is not null) await gate.Task.ConfigureAwait(false);   // answers arrive off the actor, as HttpClient's do
        var answer = handler?.Invoke(request) ?? new Answer(404, new { errors = new[] { new { code = "resource_not_found", message = "not found" } } });
        return new ClerkResponse(answer.Status, JsonSerializer.SerializeToUtf8Bytes(answer.Json), answer.Authorization);
    }

    public static Dictionary<string, string> Form(ClerkRequest request)
    {
        var text = request.Body is null ? "" : Encoding.UTF8.GetString(request.Body);
        var parsed = HttpUtility.ParseQueryString(text);
        return parsed.AllKeys.OfType<string>().ToDictionary(k => k, k => parsed[k]!);
    }

    public static string? Header(ClerkRequest r, string name) => r.Headers.TryGetValue(name, out var v) ? v : null;
}

public sealed class MemoryClerkStore(ClerkState? state = null) : IClerkStateStore
{
    private ClerkState? _state = state;
    private readonly object _lock = new();
    public ClerkState? Load() { lock (_lock) return _state; }
    public void Save(ClerkState? state) { lock (_lock) _state = state; }
}

public class ClerkTests
{
    public static string PublishableKey(string host) => "pk_test_" + Convert.ToBase64String(Encoding.UTF8.GetBytes(host + "$"));
    public static readonly string TestKey = PublishableKey("clerk.medley.test").TrimEnd('=');

    public static object ClientJson(string session = "sess_1", string user = "user_1", string email = "leo@example.com") => new Dictionary<string, object?>
    {
        ["object"] = "client", ["id"] = "client_1", ["last_active_session_id"] = session,
        ["sessions"] = new[]
        {
            new Dictionary<string, object?>
            {
                ["id"] = session, ["status"] = "active",
                ["user"] = new Dictionary<string, object?>
                {
                    ["id"] = user, ["first_name"] = "Leo", ["last_name"] = null, ["primary_email_address_id"] = "idn_1",
                    ["email_addresses"] = new[] { new { id = "idn_1", email_address = email } }, ["image_url"] = "https://img.clerk.com/x.png",
                },
            },
        },
    };

    private static ClerkState Saved(string? token = "c0") => new() { FrontendApi = "https://clerk.medley.test", ClientToken = token, SessionId = "sess_1", User = new ClerkUser("user_1") };

    [Fact]
    public void ThePublishableKeyNamesTheFrontendApi()
    {
        Assert.Equal(new Uri("https://clerk.medley.test"), ClerkPublishableKey.FrontendApi(TestKey));
        Assert.Equal("clerk.medley.app", ClerkPublishableKey.FrontendApi("pk_live_" + Convert.ToBase64String("clerk.medley.app$"u8))!.Host);
        Assert.Null(ClerkPublishableKey.FrontendApi("sk_test_abc"));
        Assert.Null(ClerkPublishableKey.FrontendApi("pk_test_" + Convert.ToBase64String("no-dollar"u8)));
        Assert.Null(ClerkPublishableKey.FrontendApi("pk_test_" + Convert.ToBase64String("evil.com/path$"u8)));
        // The real dev instance's key.
        Assert.Equal("composed-snail-5070.clerk.accounts.dev", ClerkPublishableKey.FrontendApi("pk_test_Y29tcG9zZWQtc25haWwtNTA3MC5jbGVyay5hY2NvdW50cy5kZXYk")!.Host);
    }

    [Theory]
    [InlineData("clerk.example.com", true)]
    [InlineData("happy-otter-12.clerk.accounts.dev", true)]
    [InlineData("clerk.medley.app", true)]
    [InlineData("localhost", false)]
    [InlineData("clerk.localhost", false)]
    [InlineData("printer.local", false)]
    [InlineData("192.168.1.10", false)]
    [InlineData("10.0.0.1", false)]
    [InlineData("[::1]", false)]
    [InlineData("clerk.example.com:8443", false)]
    [InlineData("Clerk.Example.com", false)]
    [InlineData("user@clerk.example.com", false)]
    [InlineData("clerk.example.com/v1", false)]
    [InlineData("clerk.example.com?x=1", false)]
    [InlineData("-clerk.example.com", false)]
    [InlineData("clerk..example.com", false)]
    [InlineData("nodots", false)]
    [InlineData("clerk.example.com.", false)]
    [InlineData("clerk example.com", false)]
    [InlineData("clérk.example.com", false)]
    [InlineData("", false)]
    public void OnlyPlausiblePublicHostsAreAcceptedAsTheFrontendApi(string host, bool accepted)
    {
        Assert.Equal(accepted, ClerkPublishableKey.FrontendApi(PublishableKey(host)) is not null);
    }

    [Fact]
    public async Task ASavedSignInIsNeverSentToAnotherFrontendApi()
    {
        var evil = new FakeClerk();
        evil.On("GET /v1/client", new { response = ClientJson() });
        evil.On("GET /v1/environment", new { user_settings = new { social = new { } } });
        var store = new MemoryClerkStore(Saved("client-token-secret"));
        var clerk = new ClerkClient(PublishableKey("clerk.attacker.example"), store, evil);
        Assert.True(clerk.DiscardedStateForOtherOrigin);
        Assert.Null(store.Load());
        Assert.Null(clerk.SavedUser);
        Assert.Null(await clerk.RestoreAsync());
        Assert.Null(await clerk.GetTokenAsync(true));
        await clerk.SocialProvidersAsync();
        Assert.All(evil.Requests, r => Assert.Null(FakeClerk.Header(r, "Authorization")));

        // Its own origin keeps it; state from before origins were recorded is dropped the same way.
        var mine = new MemoryClerkStore(Saved());
        Assert.False(new ClerkClient(TestKey, mine, new FakeClerk()).DiscardedStateForOtherOrigin);
        Assert.Equal(Saved(), mine.Load());
        var legacy = new MemoryClerkStore(new ClerkState { ClientToken = "old", SessionId = "sess_1" });
        Assert.True(new ClerkClient(TestKey, legacy, new FakeClerk()).DiscardedStateForOtherOrigin);
        Assert.Null(legacy.Load());
    }

    [Fact]
    public async Task ASignOutWinsOverARestoreStillInFlight()
    {
        var fake = new FakeClerk();
        var gate = fake.Hold("GET /v1/client");
        fake.On("GET /v1/client", new { response = ClientJson() }, "rotated-after-sign-out");
        fake.On("POST /v1/client/sessions/sess_1/remove", new { response = new { id = "sess_1" } }, "also-rotated");
        var store = new MemoryClerkStore(Saved());
        var clerk = new ClerkClient(TestKey, store, fake);
        var restore = clerk.RestoreAsync();
        Assert.True(await Eventually(() => fake.Requests.Any(r => r.Url.AbsolutePath == "/v1/client")));
        await clerk.SignOutAsync();
        var remove = fake.Requests.First(r => r.Url.AbsolutePath == "/v1/client/sessions/sess_1/remove");
        Assert.Equal("c0", FakeClerk.Header(remove, "Authorization"));   // the sign-out carried the token it had
        gate.SetResult();
        await Assert.ThrowsAsync<ClerkException>(() => restore);   // stale
        Assert.Equal(new ClerkState { FrontendApi = "https://clerk.medley.test" }, store.Load());
        Assert.Null(clerk.SavedUser);
        Assert.Null(await clerk.GetTokenAsync(false));
    }

    [Fact]
    public async Task EmailCodeSignInInNativeMode()
    {
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins", new { response = new { id = "sia_1", status = "needs_first_factor", supported_first_factors = new[] { new { strategy = "email_code", email_address_id = "idn_1" } } } }, "client-jwt-1");
        fake.On("POST /v1/client/sign_ins/sia_1/prepare_first_factor", new { response = new { id = "sia_1" } }, "client-jwt-2");
        fake.On("POST /v1/client/sign_ins/sia_1/attempt_first_factor", r => FakeClerk.Form(r)["code"] == "123456"
            ? new FakeClerk.Answer(200, new { response = new { id = "sia_1", status = "complete", created_session_id = "sess_1" } })
            : new FakeClerk.Answer(422, new { errors = new[] { new { code = "form_code_incorrect", message = "Incorrect code", long_message = "Incorrect code" } } }));
        fake.On("POST /v1/client/sessions/sess_1/touch", new { response = new { }, client = ClientJson() });
        var store = new MemoryClerkStore();
        var clerk = new ClerkClient(TestKey, store, fake);

        var challenge = await clerk.StartEmailAsync("  leo@example.com ");
        Assert.Equal(new ClerkEmailChallenge(ClerkChallengeKind.SignIn, "sia_1", "leo@example.com"), challenge);
        var wrong = await Assert.ThrowsAsync<ClerkException>(() => clerk.VerifyEmailAsync(challenge, "000000"));
        Assert.Equal("form_code_incorrect", wrong.Code);
        Assert.Equal("Incorrect code", wrong.Message);
        var user = (await clerk.VerifyEmailAsync(challenge, "123 456")).User;
        Assert.Equal(new ClerkUser("user_1", "Leo", null, "leo@example.com", "https://img.clerk.com/x.png"), user);
        Assert.Equal("Leo", user.DisplayName);
        Assert.Equal("sess_1", store.Load()!.SessionId);

        var requests = fake.Requests;
        Assert.All(requests, r => Assert.Contains("_is_native=true", r.Url.Query));
        Assert.All(requests, r => Assert.Null(FakeClerk.Header(r, "Origin")));
        Assert.Null(FakeClerk.Header(requests[0], "Authorization"));
        Assert.Equal("client-jwt-1", FakeClerk.Header(requests[1], "Authorization"));
        Assert.Equal("client-jwt-2", FakeClerk.Header(requests[2], "Authorization"));
        Assert.Equal(ClerkClient.ApiVersion, FakeClerk.Header(requests[0], "clerk-api-version"));
        Assert.Equal(new Dictionary<string, string> { ["identifier"] = "leo@example.com" }, FakeClerk.Form(requests[0]));
        Assert.Equal(new Dictionary<string, string> { ["strategy"] = "email_code", ["email_address_id"] = "idn_1" }, FakeClerk.Form(requests[1]));
        Assert.Equal("client-jwt-2", store.Load()!.ClientToken);
        Assert.DoesNotContain("client-jwt", store.Load()!.ToString());
    }

    [Fact]
    public async Task AnUnknownEmailSignsUpAndAPasswordOnlyRequirementGetsARandomOne()
    {
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins", _ => new FakeClerk.Answer(422, new { errors = new[] { new { code = "form_identifier_not_found", message = "Couldn't find your account." } } }));
        fake.On("POST /v1/client/sign_ups", new { response = new { id = "sua_1", status = "missing_requirements", missing_fields = new[] { "password" }, unverified_fields = new[] { "email_address" } } });
        fake.On("POST /v1/client/sign_ups/sua_1/prepare_verification", new { response = new { id = "sua_1" } });
        fake.On("POST /v1/client/sign_ups/sua_1/attempt_verification", new { response = new { id = "sua_1", status = "missing_requirements", missing_fields = new[] { "password" }, unverified_fields = Array.Empty<string>() } });
        var passwords = new List<string>();
        fake.On("PATCH /v1/client/sign_ups/sua_1", r =>
        {
            passwords.Add(FakeClerk.Form(r)["password"]);
            return new FakeClerk.Answer(200, new { response = new { id = "sua_1", status = "complete", created_session_id = "sess_9" } });
        });
        fake.On("POST /v1/client/sessions/sess_9/touch", new { client = ClientJson("sess_9", "user_9") });
        var store = new MemoryClerkStore();
        var clerk = new ClerkClient(TestKey, store, fake);
        var challenge = await clerk.StartEmailAsync("new@example.com");
        Assert.Equal(ClerkChallengeKind.SignUp, challenge.Kind);
        Assert.Equal("user_9", (await clerk.VerifyEmailAsync(challenge, "424242")).User.Id);
        Assert.Single(passwords);
        Assert.Equal(43, passwords[0].Length);
        Assert.NotEqual(passwords[0], ClerkClient.UnusedPassword());
        Assert.DoesNotContain(passwords[0], JsonSerializer.Serialize(store.Load()));
    }

    [Fact]
    public async Task AClerkAppThatAsksForMoreThanEmailIsExplained()
    {
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins", _ => new FakeClerk.Answer(422, new { errors = new[] { new { code = "form_identifier_not_found", message = "x" } } }));
        fake.On("POST /v1/client/sign_ups", new { response = new { id = "sua_1", status = "missing_requirements" } });
        fake.On("POST /v1/client/sign_ups/sua_1/prepare_verification", new { response = new { id = "sua_1" } });
        fake.On("POST /v1/client/sign_ups/sua_1/attempt_verification", new { response = new { id = "sua_1", status = "missing_requirements", missing_fields = new[] { "password", "phone_number" } } });
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(), fake);
        var challenge = await clerk.StartEmailAsync("a@b.c");
        var e = await Assert.ThrowsAsync<ClerkException>(() => clerk.VerifyEmailAsync(challenge, "1"));
        Assert.Equal(ClerkErrorKind.UnsupportedRequirements, e.Kind);
        Assert.Equal(["password", "phone number"], e.Fields);
        Assert.DoesNotContain(fake.Requests, r => r.Method == "PATCH");
    }

    [Fact]
    public async Task ConvexTokensAreCachedUntilNearExpiryAndAnEndedSessionSignsOut()
    {
        var fake = new FakeClerk();
        var count = 0;
        fake.On("POST /v1/client/sessions/sess_1/tokens/convex", _ => new FakeClerk.Answer(200, new { @object = "token", jwt = Jwt($"t{++count}", 60) }));
        var ended = new TaskCompletionSource<ClerkSessionEnd>();
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(Saved("c")), fake);
        clerk.SetOnSessionEnded(e => ended.TrySetResult(e));
        var first = await clerk.GetTokenAsync(false);
        Assert.Equal(first, await clerk.GetTokenAsync(false));   // cached
        Assert.NotEqual(first, await clerk.GetTokenAsync(true));  // forced
        Assert.Equal(2, count);
        // The session ends at Clerk: nil, and the end names the session.
        fake.On("POST /v1/client/sessions/sess_1/tokens/convex", _ => new FakeClerk.Answer(401, new { errors = new[] { new { code = "signed_out", message = "Signed out" } } }));
        Assert.Null(await clerk.GetTokenAsync(true));
        var end = await ended.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(new ClerkSessionEnd("sess_1", "user_1"), end);
        Assert.Null(clerk.CurrentSessionId);
    }

    /// <summary>
    /// Review finding: a token refresh picked session A, then A signed out and B signed in before the request went out.
    /// A's "session not found" used to be judged in B's generation and end B. Now it is stale before it is sent, and the
    /// refresh fetches B's token instead.
    /// </summary>
    [Fact]
    public async Task ATokenRequestForAnOlderSessionNeverEndsTheNewerOne()
    {
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sessions/sess_1/tokens/convex", _ => new FakeClerk.Answer(404, new { errors = new[] { new { code = "session_not_found", message = "gone" } } }));
        fake.On("POST /v1/client/sessions/sess_1/remove", new { response = new { id = "sess_1" } });
        fake.On("POST /v1/client/sign_ins", new { response = new { id = "sia_1", supported_first_factors = new[] { new { strategy = "email_code", email_address_id = "idn_1" } } } });
        fake.On("POST /v1/client/sign_ins/sia_1/prepare_first_factor", new { response = new { id = "sia_1" } });
        fake.On("POST /v1/client/sign_ins/sia_1/attempt_first_factor", new { response = new { id = "sia_1", status = "complete", created_session_id = "sess_b" } });
        fake.On("POST /v1/client/sessions/sess_b/touch", new { client = ClientJson("sess_b", "user_b") });
        fake.On("POST /v1/client/sessions/sess_b/tokens/convex", new { jwt = Jwt("user_b") });
        var ended = 0;
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(Saved()), fake);
        clerk.SetOnSessionEnded(_ => Interlocked.Increment(ref ended));
        clerk.WillRequestToken = async () =>
        {
            clerk.WillRequestToken = null;
            await clerk.SignOutAsync();
            await clerk.VerifyEmailAsync(await clerk.StartEmailAsync("b@example.com"), "424242");
        };
        Assert.Equal(Jwt("user_b"), await clerk.GetTokenAsync(true));
        Assert.Equal("sess_b", clerk.CurrentSessionId);
        await Task.Delay(50);
        Assert.Equal(0, ended);
        Assert.DoesNotContain(fake.Requests, r => r.Url.AbsolutePath == "/v1/client/sessions/sess_1/tokens/convex");
    }

    [Fact]
    public async Task AServerErrorIsRetryableNotASignOut()
    {
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sessions/sess_1/tokens/convex", _ => new FakeClerk.Answer(503, new { errors = new[] { new { code = "internal", message = "busy" } } }));
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(Saved("c")), fake);
        await Assert.ThrowsAsync<ClerkException>(() => clerk.GetTokenAsync(true));
        Assert.Equal("sess_1", clerk.CurrentSessionId);
    }

    [Fact]
    public async Task ALaunchWhoseSavedSessionIsGoneNeverSwitchesToAnotherOne()
    {
        var fake = new FakeClerk();
        fake.On("GET /v1/client", new { response = ClientJson("sess_other", "user_other") });
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(Saved()), fake);
        var ended = new TaskCompletionSource<ClerkSessionEnd>();
        clerk.SetOnSessionEnded(e => ended.TrySetResult(e));
        Assert.Null(await clerk.RestoreAsync());
        var end = await ended.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal("sess_1", end.SessionId);
        Assert.Equal("user_other", end.NotAdopted?.Id);
        Assert.Null(clerk.CurrentSessionId);
    }

    [Fact]
    public async Task SocialSignInForAnExistingAndANewUser()
    {
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins", r => new FakeClerk.Answer(200, new
        {
            response = new { id = "sia_o", status = "needs_first_factor", first_factor_verification = new { status = "unverified", external_verification_redirect_url = "https://accounts.google.com/o/oauth2?x=1" } },
        }));
        fake.On("GET /v1/client/sign_ins/sia_o", r => new FakeClerk.Answer(200, new { response = new { id = "sia_o", status = "complete", created_session_id = "sess_2" } }));
        fake.On("POST /v1/client/sessions/sess_2/touch", new { client = ClientJson("sess_2", "user_2") });
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(), fake);
        var start = await clerk.StartOAuthAsync(ClerkOAuthProvider.Google);
        Assert.Equal("accounts.google.com", start.Url.Host);
        Assert.Equal(new Dictionary<string, string> { ["strategy"] = "oauth_google", ["redirect_url"] = "openmusic://oauth-callback" }, FakeClerk.Form(fake.Requests[0]));
        await Assert.ThrowsAsync<ClerkException>(() => clerk.CompleteOAuthAsync(start, new Uri("https://evil.example/oauth-callback")));
        var session = await clerk.CompleteOAuthAsync(start, new Uri("openmusic://oauth-callback?rotating_token_nonce=n1"));
        Assert.Equal("user_2", session.User.Id);
        Assert.Contains("rotating_token_nonce=n1", fake.Requests.Last(r => r.Url.AbsolutePath == "/v1/client/sign_ins/sia_o").Url.Query);

        // A new user: Clerk says "transferable" and the sign-up takes it over.
        var fresh = new FakeClerk();
        fresh.On("POST /v1/client/sign_ins", new { response = new { id = "sia_n", first_factor_verification = new { external_verification_redirect_url = "https://appleid.apple.com/auth" } } });
        fresh.On("GET /v1/client/sign_ins/sia_n", new { response = new { id = "sia_n", first_factor_verification = new { status = "transferable" } } });
        fresh.On("POST /v1/client/sign_ups", r => new FakeClerk.Answer(200, new { response = new { id = "sua_n", status = "complete", created_session_id = "sess_3" } }));
        fresh.On("POST /v1/client/sessions/sess_3/touch", new { client = ClientJson("sess_3", "user_3") });
        var c2 = new ClerkClient(TestKey, new MemoryClerkStore(), fresh);
        var s2 = await c2.CompleteOAuthAsync(await c2.StartOAuthAsync(ClerkOAuthProvider.Apple), new Uri("openmusic://oauth-callback"));
        Assert.Equal("user_3", s2.User.Id);
        Assert.Equal("true", FakeClerk.Form(fresh.Requests.First(r => r.Url.AbsolutePath == "/v1/client/sign_ups"))["transfer"]);
    }

    [Fact]
    public async Task ACallbackBeforeTheBrowserFinishedIsNotThisSignIns()
    {
        // A link from an earlier, cancelled attempt (or the same link opened twice) arrives while this one still waits:
        // NotFinished, nothing adopted, and the real callback afterwards still completes it.
        var fake = new FakeClerk();
        var finished = false;
        fake.On("POST /v1/client/sign_ins", new { response = new { id = "sia_a", status = "needs_first_factor", first_factor_verification = new { status = "unverified", external_verification_redirect_url = "https://appleid.apple.com/auth/authorize?x=1" } } });
        fake.On("GET /v1/client/sign_ins/sia_a", r => finished
            ? new FakeClerk.Answer(200, new { response = new { id = "sia_a", status = "complete", created_session_id = "sess_a" } })
            : new FakeClerk.Answer(200, new { response = new { id = "sia_a", status = "needs_first_factor", first_factor_verification = new { status = "unverified" } } }));
        fake.On("POST /v1/client/sessions/sess_a/touch", new { client = ClientJson("sess_a", "user_a") });
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(), fake);
        var start = await clerk.StartOAuthAsync(ClerkOAuthProvider.Apple);
        Assert.Equal("oauth_apple", FakeClerk.Form(fake.Requests[0])["strategy"]);
        Assert.Equal("appleid.apple.com", start.Url.Host);
        var early = await Assert.ThrowsAsync<ClerkException>(() => clerk.CompleteOAuthAsync(start, new Uri("openmusic://oauth-callback")));
        Assert.Equal(ClerkErrorKind.NotFinished, early.Kind);
        Assert.Null(clerk.CurrentSessionId);
        finished = true;
        var session = await clerk.CompleteOAuthAsync(start, new Uri("openmusic://oauth-callback?rotating_token_nonce=n2"));
        Assert.Equal("user_a", session.User.Id);
        Assert.Equal("sess_a", clerk.CurrentSessionId);
    }

    [Fact]
    public async Task ACancelledSocialSignInSaysSoAndAdoptsNothing()
    {
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins", new { response = new { id = "sia_c", first_factor_verification = new { status = "unverified", external_verification_redirect_url = "https://appleid.apple.com/auth" } } });
        fake.On("GET /v1/client/sign_ins/sia_c", new { response = new { id = "sia_c", status = "needs_first_factor", first_factor_verification = new { status = "failed", error = new { code = "oauth_access_denied", message = "You did not grant access", long_message = "You cancelled signing in." } } } });
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(), fake);
        var start = await clerk.StartOAuthAsync(ClerkOAuthProvider.Apple);
        var e = await Assert.ThrowsAsync<ClerkException>(() => clerk.CompleteOAuthAsync(start, new Uri("openmusic://oauth-callback")));
        Assert.Equal(ClerkErrorKind.Refused, e.Kind);
        Assert.Equal("oauth_access_denied", e.Code);
        Assert.Null(clerk.CurrentSessionId);
    }

    [Fact]
    public async Task EnvironmentListsTheEnabledSocialSignInsAppleFirst()
    {
        var fake = new FakeClerk();
        fake.On("GET /v1/environment", new
        {
            user_settings = new
            {
                social = new Dictionary<string, object>
                {
                    ["oauth_google"] = new { enabled = true, authenticatable = true },
                    ["oauth_github"] = new { enabled = true },
                    ["oauth_apple"] = new { enabled = true },
                    ["oauth_microsoft"] = new { enabled = false },
                    ["oauth_discord"] = new { enabled = true, authenticatable = false },
                },
            },
        });
        var clerk = new ClerkClient(TestKey, new MemoryClerkStore(), fake);
        Assert.Equal(["oauth_apple", "oauth_google", "oauth_github"], (await clerk.SocialProvidersAsync()).Select(p => p.Strategy));
    }
}

public class AccountServiceTests
{
    private sealed class ConfigPoster(string? key = null) : IHttpPoster
    {
        public volatile bool Online = true;
        public int Calls;
        public string? Key = key ?? ClerkTests.TestKey;
        public Task<(byte[] Body, int Status)> PostAsync(Uri url, byte[] body, IReadOnlyDictionary<string, string> headers, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref Calls);
            if (!Online) throw new HttpRequestException("offline");
            var auth = Key is null ? ConvexValue.Object(("kind", ConvexValue.String("notConfigured")))
                : ConvexValue.Object(("kind", ConvexValue.String("clerk")), ("publishableKey", ConvexValue.String(Key)));
            return Task.FromResult((ConvexValue.Object(("status", ConvexValue.String("success")), ("value", ConvexValue.Object(("auth", auth)))).JsonBytes(), 200));
        }
    }

    private static readonly Uri Hosted = new("https://hosted-1.convex.cloud");

    [Theory]
    [InlineData("https://happy-otter-123.convex.cloud", "https://happy-otter-123.convex.cloud/")]
    [InlineData("happy-otter-123.convex.cloud", "https://happy-otter-123.convex.cloud/")]
    [InlineData("http://localhost:3210", "http://localhost:3210/")]
    [InlineData("http://127.0.0.1:3210", "http://127.0.0.1:3210/")]
    [InlineData("http://example.com", null)]
    [InlineData("ftp://example.com", null)]
    [InlineData("https://user@example.com", null)]
    [InlineData("https://example.com?x=1", null)]
    public void ServerUrlsAreHttpsOrThisMachine(string text, string? expected)
    {
        Assert.Equal(expected, SyncServer.Parse(text)?.AbsoluteUri);
    }

    [Fact]
    public async Task TheServerSaysWhichClerkAppToUse()
    {
        var key = await AccountService.FetchPublishableKeyAsync(Hosted, new ConfigPoster());
        Assert.Equal(ClerkTests.TestKey, key);
        await Assert.ThrowsAsync<ClerkException>(() => AccountService.FetchPublishableKeyAsync(Hosted, new ConfigPoster { Key = null }));
        var e = await Assert.ThrowsAsync<ServerException>(() => AccountService.FetchPublishableKeyAsync(Hosted, new ConfigPoster { Online = false }));
        Assert.Equal(ServerErrorKind.Unreachable, e.Kind);
    }

    [Fact]
    public async Task ASavedSignInCountsAtLaunchEvenOfflineAndLoadsWhenBackOnline()
    {
        var actor = SyncActor.CreateDedicated("account");
        var store = new MemoryClerkStore(new ClerkState { FrontendApi = "https://clerk.medley.test", ClientToken = "c", SessionId = "sess_1", User = new ClerkUser("user_1", "Leo") });
        var poster = new ConfigPoster { Online = false };
        var account = new AccountService(Hosted, store, actor, http: poster, clerkHttp: new FakeClerk())
        {
            WatchesNetwork = false,
            RetryDelays = [TimeSpan.FromMilliseconds(50)],
        };
        var ready = new TaskCompletionSource();
        account.Ready += () => ready.TrySetResult();
        await account.LoadAsync();
        Assert.Equal("user_1", await actor.Run(() => account.User?.Id));
        Assert.NotNull(await actor.Run(() => account.ServerProblem));
        Assert.False(await actor.Run(() => account.IsReady));
        poster.Online = true;
        await ready.Task.WaitAsync(TimeSpan.FromSeconds(5));   // retried by itself
        Assert.True(await actor.Run(() => account.IsReady));
        Assert.Null(await actor.Run(() => account.ServerProblem));
        Assert.Equal("user_1", await actor.Run(() => account.User?.Id));
    }

    [Fact]
    public async Task AServerThatStartsNamingAnotherClerkHostSignsOutWithANotice()
    {
        var actor = SyncActor.CreateDedicated("account");
        var store = new MemoryClerkStore(new ClerkState { FrontendApi = "https://clerk.medley.test", ClientToken = "c", SessionId = "sess_1", User = new ClerkUser("user_1") });
        var account = new AccountService(Hosted, store, actor, http: new ConfigPoster(ClerkTests.PublishableKey("clerk.other.example")), clerkHttp: new FakeClerk()) { WatchesNetwork = false };
        var ended = new TaskCompletionSource();
        account.SessionEnded += () => ended.TrySetResult();
        await account.LoadAsync();
        await ended.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(await actor.Run(() => account.IsSignedIn));
        Assert.Contains("clerk.other.example", await actor.Run(() => account.Notice));
        Assert.Equal(new SyncSignIn("user_1", 0), await actor.Run(() => account.EndedSignIn));
        Assert.Null(store.Load()?.ClientToken);
    }

    [Fact]
    public async Task ALateNoticeThatAnOlderSessionEndedNeverEndsANewerSignIn()
    {
        var actor = SyncActor.CreateDedicated("account");
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins", new { response = new { id = "sia_1", supported_first_factors = new[] { new { strategy = "email_code", email_address_id = "idn_1" } } } });
        fake.On("POST /v1/client/sign_ins/sia_1/prepare_first_factor", new { response = new { id = "sia_1" } });
        fake.On("POST /v1/client/sign_ins/sia_1/attempt_first_factor", new { response = new { id = "sia_1", status = "complete", created_session_id = "sess_b" } });
        fake.On("POST /v1/client/sessions/sess_b/touch", new { client = ClientJson("sess_b", "user_b") });
        var store = new MemoryClerkStore(new ClerkState { FrontendApi = "https://clerk.medley.test", ClientToken = "c", SessionId = "sess_a", User = new ClerkUser("user_a") });
        var account = new AccountService(Hosted, store, actor, http: new ConfigPoster(), clerkHttp: fake) { WatchesNetwork = false };
        await account.LoadAsync();
        var endings = 0;
        account.SessionEnded += () => endings++;
        // B signs in; then the notice that A's session ended arrives (it was queued before B's sign-in finished).
        var challenge = await account.StartEmailAsync("b@example.com");
        await account.VerifyEmailAsync(challenge, "424242");
        await actor.Run(() => account.OnSessionEnded(new ClerkSessionEnd("sess_a", "user_a")));
        Assert.Equal("user_b", await actor.Run(() => account.User?.Id));
        Assert.Equal(0, endings);
        // The notice for the shown session still ends it, naming that sign-in.
        await actor.Run(() => account.OnSessionEnded(new ClerkSessionEnd("sess_b", "user_b")));
        Assert.Equal(1, endings);
        Assert.False(await actor.Run(() => account.IsSignedIn));
        Assert.Equal(new SyncSignIn("user_b", 1), await actor.Run(() => account.EndedSignIn));
    }

    private static object ClientJson(string session, string user) => ClerkTests.ClientJson(session, user);

    [Fact]
    public async Task ASignOutWhoseSnapshotWentStaleDoesNothing()
    {
        var actor = SyncActor.CreateDedicated("account");
        var fake = new FakeClerk();
        fake.On("POST /v1/client/sign_ins", new { response = new { id = "sia_1", supported_first_factors = new[] { new { strategy = "email_code", email_address_id = "idn_1" } } } });
        fake.On("POST /v1/client/sign_ins/sia_1/prepare_first_factor", new { response = new { id = "sia_1" } });
        fake.On("POST /v1/client/sign_ins/sia_1/attempt_first_factor", new { response = new { id = "sia_1", status = "complete", created_session_id = "sess_2" } });
        fake.On("POST /v1/client/sessions/sess_2/touch", new { client = ClientJson("sess_2", "user_1") });
        var store = new MemoryClerkStore(new ClerkState { FrontendApi = "https://clerk.medley.test", ClientToken = "c", SessionId = "sess_1", User = new ClerkUser("user_1") });
        var account = new AccountService(Hosted, store, actor, http: new ConfigPoster(), clerkHttp: fake) { WatchesNetwork = false };
        await account.LoadAsync();
        // The same user signs in again while the sign-out captures the session.
        account.WillReadClerkSession = async () =>
        {
            account.WillReadClerkSession = null;
            var c = await account.StartEmailAsync("leo@example.com");
            await account.VerifyEmailAsync(c, "424242");
        };
        var sync = new SyncService(Hosted, new Medley.Core.Sync.DeviceInfo("PC", Medley.Core.Sync.DevicePlatform.Windows, "t", "1"),
                                   new Keys.SyncCredentialStore(new Keys.MemorySecretStore()), actor, new FakeTransport { AutoFail = true }, new FakeHttp(), FastOptions(1));
        await account.SignOutAsync(sync);
        Assert.Equal("sess_2", store.Load()?.SessionId);
        Assert.True(await actor.Run(() => account.IsSignedIn));
        // The stale sign-out removed nothing. (sess_1, replaced by the new sign-in, is ended at Clerk by that sign-in.)
        Assert.DoesNotContain(fake.Requests, r => r.Url.AbsolutePath.EndsWith("/sess_2/remove", StringComparison.Ordinal));
        Assert.Contains(fake.Requests, r => r.Url.AbsolutePath.EndsWith("/sess_1/remove", StringComparison.Ordinal));
        await sync.StopAsync();
    }
}

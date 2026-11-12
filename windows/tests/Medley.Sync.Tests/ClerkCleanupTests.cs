using System.Text;
using System.Text.Json;
using Medley.Sync.Account;
using Xunit;

namespace Medley.Sync.Tests;

/// <summary>
/// Review of 3e77ced: a retired client (server switch) must not sign in through a retained reference, and a session Clerk
/// created for a flow that fails before adoption (network, cancellation) is ended at Clerk instead of left active.
/// </summary>
public sealed class ClerkCleanupTests
{
    static string Key(string host) => "pk_test_" + Convert.ToBase64String(Encoding.UTF8.GetBytes(host + "$"));

    sealed class Store : IClerkStateStore
    {
        public ClerkState? State;
        public ClerkState? Load() => State;
        public void Save(ClerkState? s) => State = s;
    }

    sealed class Http : IClerkHttp
    {
        public readonly List<string> Removed = [];
        public int Sent;
        public Func<ClerkRequest, CancellationToken, Task>? BeforeTouch;
        public async Task<ClerkResponse> SendAsync(ClerkRequest request, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref Sent);
            var path = request.Url.AbsolutePath;
            object response;
            if (path == "/v1/client/sign_ins")
                response = new { response = new { id = "attempt", supported_first_factors = new[] { new { strategy = "email_code", email_address_id = "email_1" } } } };
            else if (path.EndsWith("/remove"))
            {
                lock (Removed) Removed.Add(path.Split('/')[4]);
                response = new { response = new { } };
            }
            else if (path.EndsWith("/touch"))
            {
                if (BeforeTouch is { } hook) await hook(request, cancellationToken);
                response = new { client = new { sessions = new[] { new { id = "sess_A", status = "active", user = new { id = "A" } } } } };
            }
            else if (path.Contains("sign_ins/"))
                response = new { response = new { status = "complete", created_session_id = "sess_A" } };
            else
                response = new { response = new { } };
            return new ClerkResponse(200, JsonSerializer.SerializeToUtf8Bytes(response), "client-token");
        }
    }

    [Fact]
    public async Task ARetiredClientRefusesNewSignInsAndSendsNothing()
    {
        var http = new Http();
        var store = new Store();
        var clerk = new ClerkClient(Key("old.clerk.test"), store, http);
        await clerk.Retire();
        var sentBefore = http.Sent;
        var e = await Assert.ThrowsAsync<ClerkException>(() => clerk.StartEmailAsync("a@example.test"));
        Assert.Equal(ClerkErrorKind.Stale, e.Kind);
        Assert.Equal(sentBefore, http.Sent);
        Assert.Null(clerk.CurrentSessionId);
        Assert.Null(store.State?.SessionId);
    }

    [Fact]
    public async Task ARetiredClientCantFinishAChallengeStartedBeforeTheSwitch()
    {
        var http = new Http();
        var clerk = new ClerkClient(Key("old.clerk.test"), new Store(), http);
        var challenge = await clerk.StartEmailAsync("a@example.test");
        await clerk.Retire();
        var e = await Assert.ThrowsAsync<ClerkException>(() => clerk.VerifyEmailAsync(challenge, "424242"));
        Assert.Equal(ClerkErrorKind.Stale, e.Kind);
        Assert.Null(clerk.CurrentSessionId);
    }

    [Fact]
    public async Task ATouchThatFailsOnTheNetworkEndsTheCreatedSession()
    {
        var http = new Http { BeforeTouch = (_, _) => throw new IOException("connection reset") };
        var clerk = new ClerkClient(Key("old.clerk.test"), new Store(), http);
        var challenge = await clerk.StartEmailAsync("a@example.test");
        var e = await Assert.ThrowsAsync<ClerkException>(() => clerk.VerifyEmailAsync(challenge, "424242"));
        Assert.Equal(ClerkErrorKind.Network, e.Kind);
        await WaitForAsync(() => { lock (http.Removed) return http.Removed.Contains("sess_A"); });
        Assert.Null(clerk.CurrentSessionId);
    }

    [Fact]
    public async Task ACancelledTouchEndsTheCreatedSession()
    {
        using var cts = new CancellationTokenSource();
        var http = new Http
        {
            BeforeTouch = async (_, ct) => { cts.Cancel(); ct.ThrowIfCancellationRequested(); await Task.CompletedTask; },
        };
        var clerk = new ClerkClient(Key("old.clerk.test"), new Store(), http);
        var challenge = await clerk.StartEmailAsync("a@example.test");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => clerk.VerifyEmailAsync(challenge, "424242", cts.Token));
        await WaitForAsync(() => { lock (http.Removed) return http.Removed.Contains("sess_A"); });
        Assert.Null(clerk.CurrentSessionId);
    }

    static async Task WaitForAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) Assert.Fail("timed out waiting for the session removal");
            await Task.Delay(10);
        }
    }
}

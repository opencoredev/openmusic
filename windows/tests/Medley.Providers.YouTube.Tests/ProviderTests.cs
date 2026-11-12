using System.Net;
using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.InnerTube;
using Medley.Providers.YouTube.Json;
using Medley.Providers.YouTube.Sync;
using Xunit;

namespace Medley.Providers.YouTube.Tests;

/// <summary>A cookie check that waits until released (Swift: HeldCheck). Ignores cancellation on purpose.</summary>
internal sealed class HeldCheck(AccountInfo? result = null, Exception? failure = null)
{
    readonly Gate _gate = new();
    public Task Reached => _gate.Reached;
    public void Release() => _gate.Open();

    public async Task<AccountInfo> RunAsync(YouTubeMusicCredentials creds, CancellationToken ct)
    {
        await _gate.PassAsync();
        if (failure != null) throw failure;
        return result ?? new AccountInfo("Ada");
    }
}

internal static class Make
{
    public static YouTubeMusicCredentials Creds(string sid = "i", string? datasync = null) =>
        new(new Dictionary<string, string> { ["SAPISID"] = "s", ["SID"] = sid }, 0, datasync);

    public static YouTubeMusicProvider Provider(Func<YouTubeMusicCredentials, CancellationToken, Task<AccountInfo>> validate, IYouTubeMusicCredentialStore? store = null) =>
        new(new YouTubeMusicProviderOptions
        {
            ValidateAccount = validate,
            Store = store,
            Handler = new FakeHandler(r => r.Url.AbsolutePath == "/sw.js_data" ? FakeHandler.ServiceWorker() : FakeHandler.Json("{}")),
        });
}

/// <summary>Closing the sign-in window while cookies are still being checked must not sign in afterwards.</summary>
public class SignInCancellationTests
{
    [Fact]
    public async Task SignsInWhenNotCancelled()
    {
        var check = new HeldCheck();
        check.Release();
        using var provider = Make.Provider(check.RunAsync);
        await provider.SignInAsync(Make.Creds(), persist: false);
        Assert.Equal(AuthStatus.SignedIn(new AccountInfo("Ada")), provider.AuthStatus);
        Assert.True(provider.Client.IsSignedIn);
        Assert.True(provider.Capabilities.HasFlag(ProviderCapabilities.Library));
        Assert.False(provider.Capabilities.HasFlag(ProviderCapabilities.PlaylistInsert));
    }

    [Fact]
    public async Task CancelDuringCookieCheckLeavesSignedOut()
    {
        var check = new HeldCheck();
        using var provider = Make.Provider(check.RunAsync);
        var signIn = provider.SignInAsync(Make.Creds(), persist: false);
        await check.Reached;
        Assert.Equal(AuthState.SigningIn, provider.AuthStatus.State);
        provider.CancelSignIn();
        Assert.Equal(AuthStatus.SignedOut, provider.AuthStatus);
        check.Release();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => signIn);
        Assert.Equal(AuthStatus.SignedOut, provider.AuthStatus);
        Assert.False(provider.Client.IsSignedIn);
    }

    [Fact]
    public async Task CancellingTheCallerCancelsTheSignIn()
    {
        var check = new HeldCheck();
        using var provider = Make.Provider(check.RunAsync);
        using var cts = new CancellationTokenSource();
        var signIn = provider.SignInAsync(Make.Creds(), persist: false, cts.Token);
        await check.Reached;
        cts.Cancel();
        check.Release();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => signIn);
        Assert.Equal(AuthStatus.SignedOut, provider.AuthStatus);
        Assert.False(provider.Client.IsSignedIn);
    }

    [Fact]
    public async Task FailedCheckReportsTheError()
    {
        var check = new HeldCheck(failure: ProviderException.NotSignedIn());
        check.Release();
        using var provider = Make.Provider(check.RunAsync);
        var e = await Assert.ThrowsAsync<ProviderException>(() => provider.SignInAsync(Make.Creds(), persist: false));
        Assert.Equal(ProviderErrorKind.NotSignedIn, e.Kind);
        Assert.Equal(AuthStatus.Failed(ProviderException.NotSignedIn().Message), provider.AuthStatus);
        Assert.False(provider.Client.IsSignedIn);
    }

    [Fact]
    public async Task CancelKeepsAnExistingSession()
    {
        var first = new HeldCheck();
        first.Release();
        var second = new HeldCheck();
        var calls = 0;
        using var provider = Make.Provider((c, ct) => Interlocked.Increment(ref calls) == 1 ? first.RunAsync(c, ct) : second.RunAsync(c, ct));
        await provider.SignInAsync(Make.Creds(), persist: false);
        var before = provider.AuthStatus;
        var signIn = provider.SignInAsync(Make.Creds("i2"), persist: false);
        await second.Reached;
        provider.CancelSignIn();
        second.Release();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => signIn);
        Assert.Equal(before, provider.AuthStatus);
        Assert.Equal(Make.Creds(), provider.CurrentCredentials);
    }

    /// <summary>A store that refuses the cookies fails the sign-in and changes nothing (Swift: Keychain refused).</summary>
    [Fact]
    public async Task RefusedSaveFailsTheSignIn()
    {
        var check = new HeldCheck();
        check.Release();
        using var provider = Make.Provider(check.RunAsync, new RefusingStore());
        await Assert.ThrowsAsync<IOException>(() => provider.SignInAsync(Make.Creds(), persist: true));
        Assert.Equal(AuthState.Failed, provider.AuthStatus.State);
        Assert.False(provider.Client.IsSignedIn);
        Assert.Equal(SessionIdentityKind.SignedOut, provider.Session.Identity.Kind);
    }

    [Fact]
    public async Task SignOutThatCantDeleteStaysSignedIn()
    {
        var check = new HeldCheck();
        check.Release();
        var store = new RefusingStore { RefuseSave = false };
        using var provider = Make.Provider(check.RunAsync, store);
        await provider.SignInAsync(Make.Creds(), persist: true);
        store.RefuseClear = true;
        await Assert.ThrowsAsync<IOException>(() => provider.TrySignOutAsync());
        Assert.True(provider.IsSignedIn);
        await provider.SignOutAsync(); // the silent form stays signed in too
        Assert.True(provider.IsSignedIn);
        store.RefuseClear = false;
        await provider.TrySignOutAsync();
        Assert.False(provider.IsSignedIn);
        Assert.Null(store.LoadCredentials());
    }

    sealed class RefusingStore : IYouTubeMusicCredentialStore
    {
        readonly MemoryCredentialStore _inner = new();
        public bool RefuseSave { get; set; } = true;
        public bool RefuseClear { get; set; }
        public YouTubeMusicCredentials? LoadCredentials() => _inner.LoadCredentials();
        public void SaveCredentials(YouTubeMusicCredentials credentials) { if (RefuseSave) throw new IOException("refused"); _inner.SaveCredentials(credentials); }
        public void ClearCredentials() { if (RefuseClear) throw new IOException("refused"); _inner.ClearCredentials(); }
        public AccountInfo? LoadAccount() => _inner.LoadAccount();
        public void SaveAccount(AccountInfo? account) => _inner.SaveAccount(account);
    }
}

/// <summary>The session names who requests go out as, from the credentials themselves.</summary>
public class SessionTests
{
    static readonly YouTubeMusicCredentials ChannelA = Make.Creds("a", "chanA||userA");
    static readonly YouTubeMusicCredentials ChannelB = Make.Creds("b", "chanB||userA");

    [Fact]
    public void TheAccountIdIsTheDatasyncIdNeverTheHandleOrEmail()
    {
        Assert.Equal("datasync:chanA||userA", YouTubeMusicProvider.AccountIdOf(ChannelA));
        Assert.Equal("datasync:||userA", YouTubeMusicProvider.AccountIdOf(Make.Creds(datasync: "||userA")));
        Assert.Null(YouTubeMusicProvider.AccountIdOf(Make.Creds()));
        Assert.Null(YouTubeMusicProvider.AccountIdOf(Make.Creds(datasync: "||")));
        var named = new AccountInfo("Ada", detail: "@ada", id: "handle:@ada");
        Assert.Equal("datasync:chanA||userA", YouTubeMusicProvider.Identified(named, ChannelA).Id);
        Assert.Null(YouTubeMusicProvider.Identified(named, Make.Creds()).Id);
    }

    [Fact]
    public async Task APendingReplacementStillReportsThePreviousAccount()
    {
        var first = new HeldCheck(new AccountInfo("A", detail: "@a"));
        first.Release();
        var second = new HeldCheck(new AccountInfo("B", detail: "@b"));
        using var provider = Make.Provider((c, ct) => c.Equals(ChannelA) ? first.RunAsync(c, ct) : second.RunAsync(c, ct));
        Assert.Equal(SessionIdentityKind.SignedOut, provider.Session.Identity.Kind);
        await provider.SignInAsync(ChannelA, persist: false);
        Assert.Equal(SessionIdentity.ForAccount("datasync:chanA||userA"), provider.Session.Identity);
        Assert.Equal(AuthStatus.SignedIn(new AccountInfo("A", detail: "@a", id: "datasync:chanA||userA")), provider.AuthStatus);

        var before = provider.Session;
        var signIn = provider.SignInAsync(ChannelB, persist: false);
        await second.Reached;
        Assert.Equal(AuthState.SigningIn, provider.AuthStatus.State);
        Assert.Equal(before, provider.Session);
        second.Release();
        await signIn;
        Assert.Equal(SessionIdentity.ForAccount("datasync:chanB||userA"), provider.Session.Identity);
        Assert.True(provider.Session.Generation > before.Generation);
        Assert.Equal(ChannelB, provider.CurrentCredentials);
    }

    [Fact]
    public async Task ACancelledReplacementKeepsTheSameSession()
    {
        var first = new HeldCheck();
        first.Release();
        var second = new HeldCheck();
        using var provider = Make.Provider((c, ct) => c.Equals(ChannelA) ? first.RunAsync(c, ct) : second.RunAsync(c, ct));
        await provider.SignInAsync(ChannelA, persist: false);
        var before = provider.Session;
        var signIn = provider.SignInAsync(ChannelB, persist: false);
        await second.Reached;
        provider.CancelSignIn();
        second.Release();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => signIn);
        Assert.Equal(before, provider.Session);
        Assert.Equal(ChannelA, provider.CurrentCredentials);
    }

    /// <summary>A restore whose cookies Google refuses signs out and deletes them; offline keeps the saved account.</summary>
    [Fact]
    public async Task RestoreHandlesRevokedAndOffline()
    {
        var store = new MemoryCredentialStore();
        store.SaveCredentials(ChannelA);
        store.SaveAccount(new AccountInfo("A"));
        var refused = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Store = store,
            Handler = new FakeHandler(r => r.Url.AbsolutePath == "/sw.js_data" ? FakeHandler.ServiceWorker() : FakeHandler.Status(HttpStatusCode.Unauthorized)),
        });
        await refused.RestoreSessionAsync();
        Assert.Equal(AuthStatus.SignedOut, refused.AuthStatus);
        Assert.Null(store.LoadCredentials());

        store.SaveCredentials(ChannelA);
        var offline = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Store = store,
            Handler = new FakeHandler((Func<SeenRequest, HttpResponseMessage>)(_ => throw new HttpRequestException("offline"))),
        });
        await offline.RestoreSessionAsync();
        Assert.Equal(AuthStatus.SignedIn(new AccountInfo("YouTube Music", id: "datasync:chanA||userA")), offline.AuthStatus);
        Assert.Equal(ChannelA, store.LoadCredentials());
    }
}

/// <summary>A playlist write goes out only with the credentials of the account the app checked.</summary>
public class WriteBindingTests
{
    static YouTubeMusicCredentials Channel(string c) => Make.Creds("y", $"{c}||session");

    [Fact]
    public void AWriteIsBoundToTheAccountItWasCheckedFor()
    {
        var a = Channel("A");
        using var client = new InnerTubeClient(a);
        var asA = new WriteBinding(YouTubeMusicProvider.AccountIdOf(a), 0);
        client.CheckWriteBinding(asA);
        client.SetCredentials(Channel("B"));
        Assert.True(Assert.Throws<PlaylistEditException>(() => client.CheckWriteBinding(asA)).IsAccountChanged);
        client.SetCredentials(Channel("A"));
        client.CheckWriteBinding(asA);
    }

    [Fact]
    public void WithoutAnAccountIdTheCredentialsMustBeTheSameGeneration()
    {
        var plain = Make.Creds();
        using var client = new InnerTubeClient();
        var first = client.SetCredentials(plain);
        client.CheckWriteBinding(new WriteBinding(null, first));
        client.SetCredentials(plain);
        Assert.Throws<PlaylistEditException>(() => client.CheckWriteBinding(new WriteBinding(null, first)));
        client.SetCredentials(null);
        Assert.Throws<PlaylistEditException>(() => client.CheckWriteBinding(new WriteBinding(null, client.Generation)));
    }

    /// <summary>Through the provider: a bound edit after another account landed sends nothing.</summary>
    [Fact]
    public async Task ProviderRefusesAStaleBinding()
    {
        var handler = new FakeHandler(r => r.Url.AbsolutePath == "/sw.js_data" ? FakeHandler.ServiceWorker() : FakeHandler.Json("{\"status\":\"STATUS_SUCCEEDED\"}"));
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions { Handler = handler, ValidateAccount = (_, _) => Task.FromResult(new AccountInfo("A")) });
        await provider.SignInAsync(Channel("A"), persist: false);
        var account = new PlaylistWriteAccount(YouTubeMusicProvider.AccountIdOf(Channel("A")), provider.Session);
        await provider.AddAsync([new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "v1", Title = "x" }], "PLx", account);
        var edit = handler.Seen.Single(r => r.Url.AbsolutePath == "/youtubei/v1/browse/edit_playlist");
        Assert.Equal("ACTION_ADD_VIDEO", edit.Json.S("actions", "0", "action"));
        Assert.Equal("A", edit.Json.S("context", "user", "onBehalfOfUser"));
        Assert.Equal("A", edit.Headers["X-Goog-PageId"]);
        Assert.StartsWith("SAPISIDHASH ", edit.Headers["Authorization"]);

        await provider.SignInAsync(Channel("B"), persist: false);
        var e = await Assert.ThrowsAsync<PlaylistEditException>(() => provider.AddAsync([new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "v2", Title = "x" }], "PLx", account));
        Assert.True(e.IsAccountChanged);
        Assert.Single(handler.Seen, r => r.Url.AbsolutePath == "/youtubei/v1/browse/edit_playlist");
    }
}

/// <summary>A like bound to the account a menu showed never reaches the account installed after it.</summary>
public class BoundLikeTests
{
    static YouTubeMusicCredentials Channel(string c) => Make.Creds("y", $"{c}||session");

    [Fact]
    public async Task LikeBoundToAnotherAccountSendsNothing()
    {
        var handler = new FakeHandler(r => r.Url.AbsolutePath == "/sw.js_data" ? FakeHandler.ServiceWorker() : FakeHandler.Json("{}"));
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions { Handler = handler, ValidateAccount = (_, _) => Task.FromResult(new AccountInfo("A")) });
        await provider.SignInAsync(Channel("A"), persist: false);
        var shown = new PlaylistWriteAccount(YouTubeMusicProvider.AccountIdOf(Channel("A")), provider.Session);
        var track = new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "v1", Title = "x" };
        await provider.SetLikedAsync(track, true, shown);
        Assert.Single(handler.Seen, r => r.Url.AbsolutePath.StartsWith("/youtubei/v1/like/", StringComparison.Ordinal));

        await provider.SignInAsync(Channel("B"), persist: false);
        var e = await Assert.ThrowsAsync<PlaylistEditException>(() => provider.SetLikedAsync(track, false, shown));
        Assert.True(e.IsAccountChanged);
        Assert.Single(handler.Seen, r => r.Url.AbsolutePath.StartsWith("/youtubei/v1/like/", StringComparison.Ordinal));
    }
}

/// <summary>A response to a request sent with account A's cookies, arriving after B's were committed, never touches B's.</summary>
public class StaleCookieTests
{
    [Fact]
    public async Task AStaleResponseDoesNotRotateTheNewAccountsCookies()
    {
        var gate = new Gate();
        var handler = new FakeHandler(async r =>
        {
            if (!r.Url.AbsolutePath.StartsWith("/youtubei/", StringComparison.Ordinal)) return FakeHandler.Text("");
            await gate.PassAsync();
            var response = FakeHandler.Json("{}");
            response.Headers.TryAddWithoutValidation("Set-Cookie", "__Secure-3PSIDTS=rotated-for-A; Domain=.youtube.com; Path=/; Secure");
            return response;
        });
        using var client = new InnerTubeClient(handler: handler);
        var a = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SAPISID"] = "a", ["SID"] = "a", ["__Secure-3PSIDTS"] = "a-ts" }, 0, "A||s");
        var b = new YouTubeMusicCredentials(new Dictionary<string, string> { ["SAPISID"] = "b", ["SID"] = "b", ["__Secure-3PSIDTS"] = "b-ts" }, 0, "B||s");
        client.SetCredentials(a);
        var request = client.RateVideoAsync("x", true);
        await gate.Reached;
        client.SetCredentials(b);
        gate.Open();
        await request;
        Assert.Equal(b, client.CurrentCredentials);
    }

    static FakeHandler Rotating() => new(r =>
    {
        if (r.Url.AbsolutePath == "/sw.js_data") return FakeHandler.ServiceWorker();
        var response = FakeHandler.Json("{}");
        response.Headers.TryAddWithoutValidation("Set-Cookie", "__Secure-3PSIDTS=rotated; Domain=.youtube.com; Path=/; Secure");
        return response;
    });

    /// <summary>A rotation of the saved sign-in's cookies is saved (an account operation; an export runs after it).</summary>
    [Fact]
    public async Task ACurrentResponseRotatesAndSaves()
    {
        var store = new MemoryCredentialStore();
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Store = store, Handler = Rotating(), ValidateAccount = (_, _) => Task.FromResult(new AccountInfo("A")),
        });
        var transfer = new YouTubeMusicSignInTransfer(provider, new MemoryTransferStore(), persist: false);
        await provider.SignInAsync(Make.Creds(), persist: true);
        await provider.SetLikedAsync(new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "x", Title = "x" }, true);
        Assert.Equal("rotated", provider.CurrentCredentials!.Cookies["__Secure-3PSIDTS"]);
        await transfer.ExportSignInAsync(); // queued after the rotation's save
        Assert.Equal("rotated", store.LoadCredentials()!.Cookies["__Secure-3PSIDTS"]);
    }

    /// <summary>A sign-in that isn't saved never writes its rotated cookies over the saved one's.</summary>
    [Fact]
    public async Task AnUnsavedSignInsRotationIsNotSaved()
    {
        var store = new MemoryCredentialStore();
        var saved = Make.Creds("saved");
        store.SaveCredentials(saved);
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Store = store, Handler = Rotating(), ValidateAccount = (_, _) => Task.FromResult(new AccountInfo("A")),
        });
        var transfer = new YouTubeMusicSignInTransfer(provider, new MemoryTransferStore(), persist: false);
        await provider.SignInAsync(Make.Creds("other"), persist: false);
        await provider.SetLikedAsync(new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "x", Title = "x" }, true);
        await transfer.ExportSignInAsync();
        Assert.Equal("rotated", provider.CurrentCredentials!.Cookies["__Secure-3PSIDTS"]);
        Assert.Equal(saved, store.LoadCredentials());
    }
}

/// <summary>Remove from Playlist takes a song entirely: one edit per entry (<c>setVideoId</c>), every copy.</summary>
public class PlaylistRemovalTests
{
    static Track Entry(string videoId, string? setId = null) => new()
    {
        ProviderID = videoId, Provider = ProviderId.YouTubeMusic, Title = videoId, Extra = setId == null ? new Dictionary<string, string>() : new Dictionary<string, string> { ["setVideoId"] = setId },
    };

    [Fact]
    public void EveryCopyOfEachSongIsRemoved()
    {
        Track[] entries = [Entry("a", "s1"), Entry("b", "s2"), Entry("a", "s3"), Entry("c", "s4"), Entry("a", "s5")];
        Assert.Equal(
            [new PlaylistEdit.Remove("a", "s1"), new PlaylistEdit.Remove("a", "s3"), new PlaylistEdit.Remove("a", "s5")],
            YouTubeMusicProvider.RemovalEdits([Entry("a", "s1")], entries));
        Assert.Equal(4, YouTubeMusicProvider.RemovalEdits([Entry("c"), Entry("a", "s1")], entries).Count);
        Assert.Empty(YouTubeMusicProvider.RemovalEdits([Entry("z")], entries));
    }

    [Fact]
    public void ACopyWithoutAnEntryIdRefusesTheRemoval()
    {
        Track[] entries = [Entry("a", "s1"), Entry("b", "s2"), Entry("a"), Entry("c", "s4")];
        var e = Assert.Throws<PlaylistEditException>(() => YouTubeMusicProvider.RemovalEdits([Entry("a")], entries));
        Assert.Equal(1, e.UnidentifiedCount);
        Assert.Throws<PlaylistEditException>(() => YouTubeMusicProvider.RemovalEdits([Entry("b"), Entry("a")], entries));
        Assert.Equal([new PlaylistEdit.Remove("b", "s2"), new PlaylistEdit.Remove("c", "s4")], YouTubeMusicProvider.RemovalEdits([Entry("b"), Entry("c")], entries));
    }

    /// <summary>The edit request: every page of the playlist read uncached, then one browse/edit_playlist with each removal.</summary>
    [Fact]
    public async Task RemoveReadsEveryPageThenSendsOneEdit()
    {
        var playlist = Fixture.Text("playlist.json");
        var continuation = Fixture.Text("playlist_continuation.json");
        var handler = new FakeHandler(r => r.Url.AbsolutePath switch
        {
            "/sw.js_data" => FakeHandler.ServiceWorker(),
            "/youtubei/v1/browse" when r.Json.S("continuation") != null => FakeHandler.Json(continuation),
            "/youtubei/v1/browse" => FakeHandler.Json(playlist),
            "/youtubei/v1/browse/edit_playlist" => FakeHandler.Json("{\"status\":\"STATUS_SUCCEEDED\"}"),
            _ => FakeHandler.Status(HttpStatusCode.NotFound),
        });
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions { Handler = handler, ValidateAccount = (_, _) => Task.FromResult(new AccountInfo("A")) });
        await provider.SignInAsync(Make.Creds(), persist: false);
        var first = Parsing.PageParser.Playlist(Medley.Providers.YouTube.Json.JsonNav.Parse(playlist)!.AsObject(), "x").Tracks[0];
        await provider.RemoveAsync([first], "VLRDCLAK5uy_mkXiaMATud8GJQ3aX7f0nCeCqvehA9wTQ");
        var edit = handler.Seen.Single(r => r.Url.AbsolutePath == "/youtubei/v1/browse/edit_playlist").Json!;
        Assert.Equal("RDCLAK5uy_mkXiaMATud8GJQ3aX7f0nCeCqvehA9wTQ", edit.S("playlistId"));
        Assert.Equal("ACTION_REMOVE_VIDEO", edit.S("actions", "0", "action"));
        Assert.Equal(first.ProviderID, edit.S("actions", "0", "removedVideoId"));
        Assert.Equal(first.Extra["setVideoId"], edit.S("actions", "0", "setVideoId"));
        Assert.Equal(2, handler.Seen.Count(r => r.Url.AbsolutePath == "/youtubei/v1/browse"));
    }
}

/// <summary>Swift: YouTubeMusicSignInTransferTests, with fake sessions and memory stores.</summary>
public class SignInTransferTests
{
    static readonly YouTubeMusicCredentials Creds = new(
        new Dictionary<string, string> { ["SAPISID"] = "sapisid-a", ["SID"] = "sid-a", ["__Secure-1PSIDTS"] = "ts-1" }, 1, "brand||user");

    sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    static (YouTubeMusicProvider, YouTubeMusicSignInTransfer, int[]) Device(string account = "Ada", Clock? clock = null, YouTubeMusicSignInTransfer.Verifier? verify = null)
    {
        var provider = Make.Provider((_, _) => Task.FromResult(new AccountInfo(account, detail: "@" + account.ToLowerInvariant())));
        var transfer = new YouTubeMusicSignInTransfer(provider, new MemoryTransferStore(),
            verify ?? ((_, claimed, _) => Task.FromResult(claimed ?? new AccountInfo("?"))), persist: false, time: clock ?? new Clock());
        var counter = new int[1];
        transfer.SignInDidChange = () => counter[0]++;
        return (provider, transfer, counter);
    }

    [Fact]
    public async Task SignedOutExportsNothing() => Assert.Null(await Device().Item2.ExportSignInAsync());

    [Fact]
    public async Task SignInReportsAndExportsCookiesChannelAndAccount()
    {
        var (provider, transfer, counter) = Device();
        await provider.SignInAsync(Creds, persist: false);
        Assert.Equal(1, counter[0]);
        var data = (await transfer.ExportSignInAsync())!;
        var payload = YouTubeMusicSignInPayload.Decode(data);
        Assert.Equal(Creds, payload.Credentials);
        Assert.Equal("Ada", payload.Account?.Name);
        Assert.Equal(data, await transfer.ExportSignInAsync());
    }

    [Fact]
    public async Task CookieRotationDoesNotChangeTheExportUntilTheSnapshotIsADayOld()
    {
        var clock = new Clock();
        var (provider, transfer, counter) = Device(clock: clock);
        await provider.SignInAsync(Creds, persist: false);
        var first = (await transfer.ExportSignInAsync())!;
        provider.Client.SetCredentials(Creds.WithCookie("__Secure-1PSIDTS", "ts-2"));
        Assert.Equal(first, await transfer.ExportSignInAsync());
        Assert.Equal(1, counter[0]);
        clock.Now += YouTubeMusicSignInTransfer.SnapshotMaxAge + TimeSpan.FromSeconds(1);
        var later = (await transfer.ExportSignInAsync())!;
        Assert.NotEqual(first, later);
        Assert.Equal("ts-2", YouTubeMusicSignInPayload.Decode(later).Credentials.Cookies["__Secure-1PSIDTS"]);
    }

    [Fact]
    public async Task ChannelSwitchReportsAndExportsTheNewChannel()
    {
        var (provider, transfer, counter) = Device();
        await provider.SignInAsync(Creds, persist: false);
        await provider.SignInAsync(Creds.WithAccount(1, "otherbrand||user"), persist: false);
        Assert.Equal(2, counter[0]);
        Assert.Equal("otherbrand||user", YouTubeMusicSignInPayload.Decode((await transfer.ExportSignInAsync())!).Credentials.DatasyncId);
    }

    [Fact]
    public async Task ImportSignsInAndExportsExactlyWhatArrived()
    {
        var (a, transferA, _) = Device("Ada");
        await a.SignInAsync(Creds, persist: false);
        var data = (await transferA.ExportSignInAsync())!;

        var (b, transferB, counterB) = Device("Someone else");
        await transferB.ImportSignInAsync(data);
        Assert.Equal(AuthStatus.SignedIn(new AccountInfo("Ada", detail: "@ada", id: "datasync:brand||user")), b.AuthStatus);
        Assert.Equal(Creds, b.CurrentCredentials);
        Assert.Equal(1, counterB[0]);
        Assert.Equal(data, await transferB.ExportSignInAsync());
    }

    /// <summary>A Mac's payload (the Swift encoder's bytes) signs this device in, and is exported back unchanged.</summary>
    [Fact]
    public async Task ImportsAMacSignIn()
    {
        var mac = Fixture.Bytes("transfer_swift_full.json");
        var (b, transferB, _) = Device();
        await transferB.ImportSignInAsync(mac);
        Assert.Equal("Zoë \"DJ\" Ünïcode 🎧", b.AuthStatus.Account?.Name);
        Assert.Equal("datasync:brandABC||userXYZ", b.Session.Identity.AccountId);
        Assert.Equal(mac, await transferB.ExportSignInAsync());
    }

    [Fact]
    public async Task RejectedImportKeepsThisDevicesSession()
    {
        var (a, transferA, _) = Device("Ada");
        await a.SignInAsync(Creds, persist: false);
        var data = (await transferA.ExportSignInAsync())!;
        var (b, transferB, _) = Device("Bob", verify: (_, _, _) => throw ProviderException.NotSignedIn());
        var own = Make.Creds("sid-b");
        await b.SignInAsync(own, persist: false);
        var e = await Assert.ThrowsAsync<TransferException>(() => transferB.ImportSignInAsync(data));
        Assert.Equal(TransferErrorKind.Rejected, e.Kind);
        Assert.Equal("Bob", b.AuthStatus.Account?.Name);
        Assert.Equal(own, b.CurrentCredentials);
    }

    [Fact]
    public async Task NetworkFailureKeepsThisDevicesSession()
    {
        var (a, transferA, _) = Device("Ada");
        await a.SignInAsync(Creds, persist: false);
        var data = (await transferA.ExportSignInAsync())!;
        var (b, transferB, counterB) = Device("Bob", verify: (_, _, _) => throw ProviderException.Network("offline"));
        var own = Make.Creds("sid-b");
        await b.SignInAsync(own, persist: false);
        var ownExport = await transferB.ExportSignInAsync();
        var reports = counterB[0];
        Assert.Equal(TransferErrorKind.Unverified, (await Assert.ThrowsAsync<TransferException>(() => transferB.ImportSignInAsync(data))).Kind);
        Assert.Equal(own, b.CurrentCredentials);
        Assert.Equal(ownExport, await transferB.ExportSignInAsync());
        Assert.Equal(reports, counterB[0]);
        var (c, transferC, _) = Device(verify: (_, _, _) => throw ProviderException.Server(503, "unavailable"));
        Assert.Equal(TransferErrorKind.Unverified, (await Assert.ThrowsAsync<TransferException>(() => transferC.ImportSignInAsync(data))).Kind);
        Assert.False(c.IsSignedIn);
    }

    [Fact]
    public async Task GarbageAndUnusablePayloads()
    {
        var (b, transferB, _) = Device();
        Assert.Equal(TransferErrorKind.Unreadable, (await Assert.ThrowsAsync<TransferException>(() => transferB.ImportSignInAsync("refresh-1"u8.ToArray()))).Kind);
        var noSession = new YouTubeMusicSignInPayload(new YouTubeMusicCredentials(new Dictionary<string, string> { ["PREF"] = "x" }), null).Encode();
        Assert.Equal(TransferErrorKind.Unreadable, (await Assert.ThrowsAsync<TransferException>(() => transferB.ImportSignInAsync(noSession))).Kind);
        Assert.False(b.IsSignedIn);
    }

    [Fact]
    public async Task SignOutClearsTheSnapshotAndReports()
    {
        var (provider, transfer, counter) = Device();
        await provider.SignInAsync(Creds, persist: false);
        await transfer.SignOutAsync();
        Assert.Equal(2, counter[0]);
        Assert.Null(await transfer.ExportSignInAsync());
    }
}

using System.Net;
using System.Text.Json.Nodes;
using OpenMusic.Core;
using OpenMusic.Providers.YouTube.Auth;
using OpenMusic.Providers.YouTube.InnerTube;
using OpenMusic.Providers.YouTube.Json;
using OpenMusic.Providers.YouTube.Sync;
using Xunit;

namespace OpenMusic.Providers.YouTube.Tests;

/// <summary>
/// Account transitions racing in-flight work, from Sol's review of b864ad6. Each was reproduced against the first port
/// (and the Swift provider has the same gaps for 1, 2 and 5).
/// </summary>
public class AccountRaceTests
{
    static readonly YouTubeMusicCredentials A = Make.Creds("a");
    static readonly YouTubeMusicCredentials B = Make.Creds("b");

    /// <summary>1. A's late answer must not fill the cache B's requests read (same authUser, no channel: same request bytes).</summary>
    [Fact]
    public async Task AStaleAnswerDoesNotFillTheNewAccountsCache()
    {
        var gate = new Gate();
        var browses = 0;
        var handler = new FakeHandler(async r =>
        {
            if (r.Url.AbsolutePath == "/sw.js_data") return FakeHandler.ServiceWorker();
            if (Interlocked.Increment(ref browses) == 1) await gate.PassAsync();
            return FakeHandler.Json(new JsonObject { ["who"] = r.Headers["Cookie"] });
        });
        using var client = new InnerTubeClient(handler: handler);
        client.SetCredentials(A);
        var asA = client.BrowseAsync("FEmusic_home");
        await gate.Reached;
        client.SetCredentials(B);
        gate.Open();
        Assert.Contains("SID=a", (await asA).S("who"));
        var asB = await client.BrowseAsync("FEmusic_home");
        Assert.Contains("SID=b", asB.S("who"));
        Assert.Equal(2, browses);
    }

    /// <summary>2. A restore whose account check comes back 401 after B signed in neither signs B out nor deletes B.</summary>
    [Fact]
    public async Task AStaleRestoreDoesNotDeleteANewerSignIn()
    {
        var store = new MemoryCredentialStore();
        store.SaveCredentials(A);
        var gate = new Gate();
        var handler = new FakeHandler(async r =>
        {
            if (r.Url.AbsolutePath == "/sw.js_data") return FakeHandler.ServiceWorker();
            await gate.PassAsync();
            return FakeHandler.Status(HttpStatusCode.Unauthorized);
        });
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Store = store, Handler = handler, ValidateAccount = (_, _) => Task.FromResult(new AccountInfo("B")),
        });
        var restore = provider.RestoreSessionAsync();
        await gate.Reached;
        await provider.SignInAsync(B, persist: true);
        gate.Open();
        await restore;
        Assert.Equal("B", provider.AuthStatus.Account?.Name);
        Assert.Equal(B, provider.CurrentCredentials);
        Assert.Equal(B, store.LoadCredentials());
        Assert.Equal(SessionIdentityKind.Account, provider.Session.Identity.Kind);
    }

    /// <summary>
    /// 3a. A sign-out that lands while the sign-in's account summary is still being written wins: status, session, cookies
    /// and the saved summary agree. The sign-in committed first, so it may report success; the summary write that was
    /// stuck lands, then the sign-out's.
    /// </summary>
    [Fact]
    public async Task SignOutDuringTheAccountSaveWins()
    {
        var store = new GatedStore();
        using var provider = Make.Provider((_, _) => Task.FromResult(new AccountInfo("A")), store);
        var signIn = Task.Run(() => provider.SignInAsync(A, persist: true)); // the save blocks its thread
        await store.SaveGate.Reached;
        await provider.TrySignOutAsync();
        store.SaveGate.Open();
        try { await signIn; } catch (OperationCanceledException) { }
        Assert.Equal(AuthStatus.SignedOut, provider.AuthStatus);
        Assert.Equal(SessionIdentityKind.SignedOut, provider.Session.Identity.Kind);
        Assert.Null(provider.CurrentCredentials);
        Assert.Null(store.LoadCredentials());
        Assert.Null(store.LoadAccount());
    }

    /// <summary>3b. A sign-in that lands while sign-out clears the web view keeps its account.</summary>
    [Fact]
    public async Task SignInDuringTheWebClearWins()
    {
        var clear = new Gate();
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            ValidateAccount = (c, _) => Task.FromResult(new AccountInfo(c.Equals(A) ? "A" : "B")),
            ClearWebSignIn = clear.PassAsync,
            Handler = new FakeHandler(_ => FakeHandler.Json("{}")),
        });
        await provider.SignInAsync(A, persist: false);
        var signOut = provider.TrySignOutAsync();
        await clear.Reached;
        await provider.SignInAsync(B, persist: false);
        clear.Open();
        await signOut;
        Assert.Equal("B", provider.AuthStatus.Account?.Name);
        Assert.Equal(B, provider.CurrentCredentials);
    }

    /// <summary>4. An account summary the store can't write (access denied) doesn't fail or strand the sign-in.</summary>
    [Fact]
    public async Task AnUnwritableAccountSummaryStillSignsIn()
    {
        var store = new GatedStore { SaveAccountFailure = new UnauthorizedAccessException("denied") };
        store.SaveGate.Open();
        using var provider = Make.Provider((_, _) => Task.FromResult(new AccountInfo("A")), store);
        await provider.SignInAsync(A, persist: true);
        Assert.Equal("A", provider.AuthStatus.Account?.Name);
        Assert.Equal(A, store.LoadCredentials());

        var dir = Directory.CreateTempSubdirectory("ytm-ro-").FullName;
        try
        {
            var files = new ProtectedFileCredentialStore(dir, new IdentityProtector());
            Directory.CreateDirectory(Path.Combine(dir, ProtectedFileCredentialStore.AccountFile + ".tmp")); // the summary's temp path can't be written
            files.SaveAccount(new AccountInfo("A"));
            Assert.Null(files.LoadAccount());
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    /// <summary>5. An import whose check finishes after its caller cancelled, or after a sign-out, changes nothing.</summary>
    [Fact]
    public async Task AnImportSupersededDuringItsCheckChangesNothing()
    {
        var data = new YouTubeMusicSignInPayload(A, new AccountInfo("A")).Encode();
        var check = new Gate();
        using var provider = Make.Provider((_, _) => Task.FromResult(new AccountInfo("Own")));
        var transfer = new YouTubeMusicSignInTransfer(provider, new MemoryTransferStore(),
            async (_, claimed, _) => { await check.PassAsync(); return claimed!; }, persist: false); // ignores cancellation on purpose
        using var cts = new CancellationTokenSource();
        var import = transfer.ImportSignInAsync(data, cts.Token);
        await check.Reached;
        cts.Cancel();
        check.Open();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => import);
        Assert.False(provider.IsSignedIn);

        var check2 = new Gate();
        var transfer2 = new YouTubeMusicSignInTransfer(provider, new MemoryTransferStore(),
            async (_, claimed, _) => { await check2.PassAsync(); return claimed!; }, persist: false);
        await provider.SignInAsync(B, persist: false);
        var import2 = transfer2.ImportSignInAsync(data);
        await check2.Reached;
        await provider.TrySignOutAsync();
        check2.Open();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => import2);
        Assert.False(provider.IsSignedIn);
        Assert.Null(provider.CurrentCredentials);
    }

    /// <summary>6. LRCLIB timing out returns YouTube's own (unsynced) lyrics rather than throwing the timeout.</summary>
    [Fact]
    public async Task AnLrclibTimeoutKeepsYouTubesLyrics()
    {
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Handler = new FakeHandler(r => r.Url.AbsolutePath switch
            {
                "/sw.js_data" => FakeHandler.ServiceWorker(),
                "/youtubei/v1/next" => FakeHandler.Json(Fixture.Text("next.json")),
                _ => FakeHandler.Json(Fixture.Text(r.ClientName == "ANDROID_MUSIC" ? "live_lyrics_untimed.json" : "lyrics.json")),
            }),
            LrcLib = new LrcLibClient(fetch: (_, _) => throw new TaskCanceledException("The request was canceled due to the configured HttpClient.Timeout")),
        });
        var track = new Track
        {
            ProviderID = "FGBhQbmPwH8", Provider = ProviderId.YouTubeMusic, Title = "One More Time", Artists = [new ArtistRef(null, "Daft Punk")],
        };
        var lyrics = await provider.LyricsAsync(track);
        Assert.NotNull(lyrics);
        Assert.False(lyrics.IsSynced);
        // The caller's own cancellation still propagates.
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.LyricsAsync(track, cts.Token));
    }

    sealed class IdentityProtector : ISecretProtector
    {
        public byte[] Protect(byte[] plaintext) => plaintext;
        public byte[] Unprotect(byte[] ciphertext) => ciphertext;
    }

    /// <summary>A memory store whose account-summary save waits on a gate (or fails).</summary>
    sealed class GatedStore : IYouTubeMusicCredentialStore
    {
        readonly MemoryCredentialStore _inner = new();
        public Gate SaveGate { get; } = new();
        public Exception? SaveAccountFailure { get; init; }
        public YouTubeMusicCredentials? LoadCredentials() => _inner.LoadCredentials();
        public void SaveCredentials(YouTubeMusicCredentials credentials) => _inner.SaveCredentials(credentials);
        public void ClearCredentials() => _inner.ClearCredentials();
        public AccountInfo? LoadAccount() => _inner.LoadAccount();

        public void SaveAccount(AccountInfo? account)
        {
            SaveGate.PassAsync().GetAwaiter().GetResult();
            if (SaveAccountFailure != null) throw SaveAccountFailure;
            _inner.SaveAccount(account);
        }
    }
}

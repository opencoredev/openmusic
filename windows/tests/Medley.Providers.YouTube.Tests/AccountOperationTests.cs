using System.Net;
using Medley.Core;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.Sync;
using Xunit;

namespace Medley.Providers.YouTube.Tests;

/// <summary>
/// Account operations (restore, sign-in, import, sign-out, summary writes) interleaved at an await or inside a store call,
/// from Sol's review of 98aeaac (its harness, one test per scenario). Each failed on 98aeaac; the provider now runs every
/// account operation on one serial executor, so none can act on another's half-done state.
/// </summary>
public class AccountOperationTests
{
    static readonly TimeSpan Limit = TimeSpan.FromSeconds(15);

    static YouTubeMusicCredentials C(string name) => new(new Dictionary<string, string> { ["SAPISID"] = "fake", ["SID"] = name });

    /// <summary>Account checks name the account after the SID; every InnerTube request is refused (401).</summary>
    static YouTubeMusicProvider P(SteppedStore store, Func<YouTubeMusicCredentials, CancellationToken, Task<AccountInfo>>? validate = null) => new(new YouTubeMusicProviderOptions
    {
        Store = store,
        Handler = new FakeHandler(r => r.Url.AbsolutePath == "/sw.js_data" ? FakeHandler.ServiceWorker() : FakeHandler.Status(HttpStatusCode.Unauthorized)),
        ValidateAccount = validate ?? ((c, _) => Task.FromResult(new AccountInfo(c.Cookies["SID"]))),
    });

    /// <summary>An account_menu answer for an account named A.</summary>
    const string AccountMenuA = """{"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"header":{"activeAccountHeaderRenderer":{"accountName":{"runs":[{"text":"A"}]}}}}}}}]}""";

    static async Task IgnoreCancellation(Task task)
    {
        try { await task.WaitAsync(Limit); } catch (OperationCanceledException) { }
    }

    /// <summary>Finding 4: a 401 at restore whose deletion the store refuses still stops using the revoked cookies.</summary>
    [Fact]
    public async Task ARestoreThatCantDeleteRevokedCookiesStillSignsOut()
    {
        var store = new SteppedStore { RefuseClear = true };
        store.SaveCredentials(C("A"));
        store.SaveAccount(new AccountInfo("A"));
        using var provider = P(store);
        await provider.RestoreSessionAsync().WaitAsync(Limit);
        Assert.Equal(1, store.ClearAttempts);
        Assert.Equal(AuthStatus.SignedOut, provider.AuthStatus);
        Assert.Null(provider.CurrentCredentials);
        Assert.Equal(SessionIdentityKind.SignedOut, provider.Session.Identity.Kind);
    }

    /// <summary>Finding 1: restore read A's saved cookies, B signed in before restore installed them: B stays, saved and active.</summary>
    [Fact]
    public async Task ARestoreThatReadBeforeANewerSignInChangesNothing()
    {
        var store = new SteppedStore();
        store.SaveCredentials(C("A"));
        store.ReadGate = new Gate();
        using var provider = P(store);
        var restore = Task.Run(() => provider.RestoreSessionAsync());
        await store.ReadGate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(C("B"), persist: true).WaitAsync(Limit);
        store.ReadGate.Open();
        await restore.WaitAsync(Limit);
        Assert.Equal(C("B"), provider.CurrentCredentials);
        Assert.Equal(C("B"), store.Inner.LoadCredentials());
        Assert.Equal("B", provider.AuthStatus.Account?.Name);
        Assert.Equal(SessionIdentityKind.Account, provider.Session.Identity.Kind);
    }

    /// <summary>Finding 5: A's summary write paused while B signed in: the saved summary ends up B's, matching B's saved cookies.</summary>
    [Fact]
    public async Task AnOlderSignInsSummaryWriteDoesNotOverwriteTheNewerOne()
    {
        var store = new SteppedStore { AccountGate = new Gate(), GatedAccount = "A" };
        using var provider = P(store);
        var a = Task.Run(() => provider.SignInAsync(C("A"), persist: true));
        await store.AccountGate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(C("B"), persist: true).WaitAsync(Limit);
        store.AccountGate.Open();
        await IgnoreCancellation(a);
        Assert.Equal("B", provider.AuthStatus.Account?.Name);
        Assert.Equal(C("B"), store.Inner.LoadCredentials());
        Assert.Equal("B", store.LoadAccount()?.Name);
    }

    /// <summary>Finding 5, restore: restore's summary write paused while B signed in.</summary>
    [Fact]
    public async Task ARestoresSummaryWriteDoesNotOverwriteANewerSignIn()
    {
        var store = new SteppedStore();
        store.SaveCredentials(C("A"));
        store.AccountGate = new Gate();
        store.GatedAccount = "A";
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Store = store,
            Handler = new FakeHandler(r => r.Url.AbsolutePath == "/sw.js_data" ? FakeHandler.ServiceWorker() : FakeHandler.Json(AccountMenuA)),
            ValidateAccount = (c, _) => Task.FromResult(new AccountInfo(c.Cookies["SID"])),
        });
        var restore = Task.Run(() => provider.RestoreSessionAsync());
        await store.AccountGate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(C("B"), persist: true).WaitAsync(Limit);
        store.AccountGate.Open();
        await IgnoreCancellation(restore);
        Assert.Equal("B", provider.AuthStatus.Account?.Name);
        Assert.Equal(C("B"), store.Inner.LoadCredentials());
        Assert.Equal("B", store.LoadAccount()?.Name);
    }

    /// <summary>Finding 5, transfer: an import's summary write paused while B signed in.</summary>
    [Fact]
    public async Task AnImportsSummaryWriteDoesNotOverwriteANewerSignIn()
    {
        var store = new SteppedStore();
        using var provider = P(store);
        var transfer = new YouTubeMusicSignInTransfer(provider, new MemoryTransferStore(), (_, a, _) => Task.FromResult(a!), persist: true);
        store.AccountGate = new Gate();
        store.GatedAccount = "A";
        var import = Task.Run(() => transfer.ImportSignInAsync(new YouTubeMusicSignInPayload(C("A"), new AccountInfo("A")).Encode()));
        await store.AccountGate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(C("B"), persist: true).WaitAsync(Limit);
        store.AccountGate.Open();
        await IgnoreCancellation(import);
        Assert.Equal(C("B"), store.Inner.LoadCredentials());
        Assert.Equal("B", store.LoadAccount()?.Name);
        Assert.Equal(C("B"), YouTubeMusicSignInPayload.Decode((await transfer.ExportSignInAsync())!).Credentials);
    }

    /// <summary>
    /// Finding 3: O signed in; A's commit is saving (and will fail); B starts checking; A's save fails; B is cancelled.
    /// O's cookies are still the ones installed, so the status is O's, not signed out.
    /// </summary>
    [Fact]
    public async Task AFailedCommitThenACancelledReplacementKeepsTheOriginalAccount()
    {
        var store = new SteppedStore();
        var checkB = new Gate();
        using var provider = P(store, async (c, _) =>
        {
            if (c.Equals(C("B"))) await checkB.PassAsync();
            return new AccountInfo(c.Cookies["SID"]);
        });
        await provider.SignInAsync(C("O"), persist: true);
        store.CredentialGate = new Gate();
        store.GatedCredentials = C("A");
        store.RefuseGatedSave = true;
        var a = Task.Run(() => provider.SignInAsync(C("A"), persist: true));
        await store.CredentialGate.Reached.WaitAsync(Limit);
        var b = provider.SignInAsync(C("B"), persist: true);
        await checkB.Reached.WaitAsync(Limit);
        store.CredentialGate.Open();
        try { await a.WaitAsync(Limit); } catch (IOException) { } catch (OperationCanceledException) { }
        provider.CancelSignIn();
        checkB.Open();
        await IgnoreCancellation(b);
        Assert.Equal("O", provider.AuthStatus.Account?.Name);
        Assert.Equal(C("O"), provider.CurrentCredentials);
        Assert.Equal(C("O"), store.Inner.LoadCredentials());
        Assert.Equal(SessionIdentityKind.Account, provider.Session.Identity.Kind);
    }

    /// <summary>Finding 2: a local sign-in while an import is saving: the export is the live account's, not the old one's.</summary>
    [Fact]
    public async Task ALocalSignInDuringAnImportIsWhatGetsExported()
    {
        var store = new SteppedStore();
        using var provider = P(store);
        var snapshots = new MemoryTransferStore();
        var transfer = new YouTubeMusicSignInTransfer(provider, snapshots, (_, a, _) => Task.FromResult(a!), persist: true);
        await provider.SignInAsync(C("O"), persist: true);
        store.AccountGate = new Gate();
        store.GatedAccount = "A";
        var import = Task.Run(() => transfer.ImportSignInAsync(new YouTubeMusicSignInPayload(C("A"), new AccountInfo("A")).Encode()));
        await store.AccountGate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(C("B"), persist: false).WaitAsync(Limit);
        store.AccountGate.Open();
        await IgnoreCancellation(import);
        Assert.Equal("B", provider.AuthStatus.Account?.Name);
        var payload = YouTubeMusicSignInPayload.Decode((await transfer.ExportSignInAsync().WaitAsync(Limit))!);
        Assert.Equal(C("B"), payload.Credentials);
        Assert.Equal("B", payload.Account?.Name);
    }

    /// <summary>Finding 2: a local sign-out while an import is saving reports the sign-out and drops the snapshot.</summary>
    [Fact]
    public async Task ALocalSignOutDuringAnImportIsReported()
    {
        var store = new SteppedStore();
        using var provider = P(store);
        var snapshots = new MemoryTransferStore();
        var transfer = new YouTubeMusicSignInTransfer(provider, snapshots, (_, a, _) => Task.FromResult(a!), persist: true);
        var notices = 0;
        transfer.SignInDidChange = () => Interlocked.Increment(ref notices);
        await provider.SignInAsync(C("O"), persist: true);
        store.AccountGate = new Gate();
        store.GatedAccount = "A";
        var import = Task.Run(() => transfer.ImportSignInAsync(new YouTubeMusicSignInPayload(C("A"), new AccountInfo("A")).Encode()));
        await store.AccountGate.Reached.WaitAsync(Limit);
        var beforeSignOut = Volatile.Read(ref notices);
        await provider.TrySignOutAsync().WaitAsync(Limit);
        Assert.True(Volatile.Read(ref notices) > beforeSignOut, "the sign-out wasn't reported");
        store.AccountGate.Open();
        await IgnoreCancellation(import);
        Assert.Null(snapshots.Load());
        Assert.False(provider.IsSignedIn);
        Assert.Null(provider.CurrentCredentials);
        Assert.Null(store.Inner.LoadCredentials());
        Assert.Null(store.LoadAccount());
        Assert.Null(await transfer.ExportSignInAsync().WaitAsync(Limit));
    }

    // Sol's review of 2190b3d: paths that still ran outside the executor, or acted on the status instead of the
    // installed credentials. Each failed on 2190b3d.

    static string Who(SeenRequest r) => r.Headers.TryGetValue("Cookie", out var cookie) && cookie.Contains("SID=B", StringComparison.Ordinal) ? "B" : "A";

    static string Menu(string name) =>
        "{\"actions\":[{\"openPopupAction\":{\"popup\":{\"multiPageMenuRenderer\":{\"header\":{\"activeAccountHeaderRenderer\":{\"accountName\":{\"runs\":[{\"text\":\"" + name + "\"}]}}}}}}}]}";

    const string Switcher = """{"accountItem":{"accountName":{"simpleText":"A"},"isSelected":true}}""";

    static YouTubeMusicCredentials Id(string name) => new(new Dictionary<string, string> { ["SAPISID"] = "fake", ["SID"] = name }, datasyncId: name);

    static WebCookie[] WebCookiesOfA() => [new("SAPISID", "fake", ".youtube.com"), new("SID", "A", ".youtube.com")];

    static Track Song => new() { Provider = ProviderId.YouTubeMusic, ProviderID = "x", Title = "x" };

    /// <summary>A web sign-in whose prepare was still out when the listener signed out never signs in afterwards.</summary>
    [Fact]
    public async Task AWebSignInPreparedBeforeASignOutNeverCommits()
    {
        var gate = new Gate();
        var store = new MemoryCredentialStore();
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Store = store,
            Handler = new FakeHandler(async r =>
            {
                if (r.Url.AbsolutePath == "/getAccountSwitcherEndpoint")
                {
                    await gate.PassAsync();
                    return FakeHandler.Json(Switcher);
                }
                return FakeHandler.Json(r.Url.AbsolutePath == "/sw.js_data" ? "{}" : Menu(Who(r)));
            }),
        });
        var web = provider.SignInWithWebCookiesAsync(WebCookiesOfA());
        await gate.Reached.WaitAsync(Limit);
        await provider.TrySignOutAsync().WaitAsync(Limit);
        gate.Open();
        await IgnoreCancellation(web);
        Assert.Null(provider.CurrentCredentials);
        Assert.Null(store.LoadCredentials());
        Assert.False(provider.IsSignedIn);
    }

    /// <summary>Closing the window (CancelSignIn) while the web sign-in prepares stops its automatic commit.</summary>
    [Fact]
    public async Task CancelSignInStopsAWebSignInStillPreparing()
    {
        var gate = new Gate();
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Handler = new FakeHandler(async r =>
            {
                if (r.Url.AbsolutePath == "/getAccountSwitcherEndpoint")
                {
                    await gate.PassAsync();
                    return FakeHandler.Json(Switcher);
                }
                return FakeHandler.Json(r.Url.AbsolutePath == "/sw.js_data" ? "{}" : Menu(Who(r)));
            }),
        });
        var web = provider.SignInWithWebCookiesAsync(WebCookiesOfA());
        await gate.Reached.WaitAsync(Limit);
        provider.CancelSignIn();
        gate.Open();
        await IgnoreCancellation(web);
        Assert.Null(provider.CurrentCredentials);
    }

    /// <summary>A choice from an older prepare never commits a newer prepare's credentials.</summary>
    [Fact]
    public async Task AChoiceCommitsOnlyTheLoginItWasPreparedFrom()
    {
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Handler = new FakeHandler(r => FakeHandler.Json(r.Url.AbsolutePath switch
            {
                "/getAccountSwitcherEndpoint" => Switcher,
                "/sw.js_data" => "{}",
                _ => Menu(Who(r)),
            })),
            ValidateAccount = (c, _) => Task.FromResult(new AccountInfo(c.Cookies["SID"])),
        });
        var fromA = await provider.PrepareAccountsAsync(C("A")).WaitAsync(Limit);
        var fromB = await provider.PrepareAccountsAsync(C("B")).WaitAsync(Limit);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.CommitSignInAsync(fromA.Accounts[0]).WaitAsync(Limit));
        Assert.Null(provider.CurrentCredentials);
        await provider.CommitSignInAsync(fromB.Accounts[0]).WaitAsync(Limit);
        Assert.Equal("B", provider.CurrentCredentials!.Cookies["SID"]);
        // The login is let go once committed, and a sign-out drops a held one.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.CommitSignInAsync(fromB.Accounts[0]).WaitAsync(Limit));
        var again = await provider.PrepareAccountsAsync(C("A")).WaitAsync(Limit);
        await provider.TrySignOutAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.CommitSignInAsync(again.Accounts[0]).WaitAsync(Limit));
        Assert.Null(provider.CurrentCredentials);
    }

    /// <summary>An account read that went out after another account was installed names that account, not the first.</summary>
    [Fact]
    public async Task AnAccountReadNeverMixesTwoAccounts()
    {
        var gate = new Gate();
        var bootstraps = 0;
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Handler = new FakeHandler(async r =>
            {
                if (r.Url.AbsolutePath == "/sw.js_data")
                {
                    if (Interlocked.Increment(ref bootstraps) == 1) await gate.PassAsync();
                    return FakeHandler.Json("{}");
                }
                return FakeHandler.Json(Menu(Who(r)));
            }),
            ValidateAccount = (c, _) => Task.FromResult(new AccountInfo(c.Cookies["SID"])),
        });
        await provider.SignInAsync(Id("A"), persist: false);
        var read = provider.AccountAsync();
        await gate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(Id("B"), persist: false).WaitAsync(Limit);
        gate.Open();
        var account = await read.WaitAsync(Limit);
        Assert.Equal("B", account.Name);
        Assert.Equal("datasync:B", account.Id);
    }

    /// <summary>A like started as A is never sent as B.</summary>
    [Fact]
    public async Task ALikeStartedAsOneAccountIsNeverSentAsAnother()
    {
        var gate = new Gate();
        var bootstraps = 0;
        var sentAs = new List<string>();
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Handler = new FakeHandler(async r =>
            {
                if (r.Url.AbsolutePath == "/sw.js_data")
                {
                    if (Interlocked.Increment(ref bootstraps) == 1) await gate.PassAsync();
                    return FakeHandler.Json("{}");
                }
                lock (sentAs) sentAs.Add(Who(r));
                return FakeHandler.Json("{}");
            }),
            ValidateAccount = (c, _) => Task.FromResult(new AccountInfo(c.Cookies["SID"])),
        });
        await provider.SignInAsync(C("A"), persist: false);
        var like = provider.SetLikedAsync(Song, true);
        await gate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(C("B"), persist: false).WaitAsync(Limit);
        gate.Open();
        var e = await Assert.ThrowsAsync<PlaylistEditException>(() => like.WaitAsync(Limit));
        Assert.True(e.IsAccountChanged);
        Assert.DoesNotContain("B", sentAs);
        Assert.False(await provider.IsLikedAsync(Song).WaitAsync(Limit) && sentAs.Count == 0);
    }

    /// <summary>Playlist create and add started as A are never sent as B (the overloads without an account).</summary>
    [Theory]
    [InlineData("create")]
    [InlineData("add")]
    public async Task APlaylistWriteStartedAsOneAccountIsNeverSentAsAnother(string kind)
    {
        var gate = new Gate();
        var bootstraps = 0;
        var sentAs = new List<string>();
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Handler = new FakeHandler(async r =>
            {
                if (r.Url.AbsolutePath == "/sw.js_data")
                {
                    if (Interlocked.Increment(ref bootstraps) == 1) await gate.PassAsync();
                    return FakeHandler.Json("{}");
                }
                if (r.Url.AbsolutePath.Contains("playlist/create") || r.Url.AbsolutePath.Contains("edit_playlist"))
                    lock (sentAs) sentAs.Add(Who(r));
                return FakeHandler.Json("{\"playlistId\":\"PLnew\",\"status\":\"STATUS_SUCCEEDED\"}");
            }),
            ValidateAccount = (c, _) => Task.FromResult(new AccountInfo(c.Cookies["SID"])),
        });
        await provider.SignInAsync(C("A"), persist: false);
        Task write = kind switch
        {
            "create" => provider.CreatePlaylistAsync("New", null),
            _ => provider.AddAsync([Song], "PLx"),
        };
        await gate.Reached.WaitAsync(Limit);
        await provider.SignInAsync(C("B"), persist: false).WaitAsync(Limit);
        gate.Open();
        await Assert.ThrowsAnyAsync<Exception>(() => write.WaitAsync(Limit));
        lock (sentAs) Assert.DoesNotContain("B", sentAs);
    }

    /// <summary>A transfer snapshot the store refused to rewrite is never exported for the next account.</summary>
    [Fact]
    public async Task ARefusedSnapshotWriteNeverExportsThePreviousAccount()
    {
        using var provider = P(new SteppedStore());
        var snapshots = new RefusingTransferStore();
        var transfer = new YouTubeMusicSignInTransfer(provider, snapshots);
        await provider.SignInAsync(C("A"), persist: false);
        snapshots.Refuse = true;
        await provider.SignInAsync(C("B"), persist: false);
        var payload = YouTubeMusicSignInPayload.Decode((await transfer.ExportSignInAsync().WaitAsync(Limit))!);
        Assert.Equal(C("B"), payload.Credentials);
        Assert.Equal("B", payload.Account?.Name);
    }

    /// <summary>A sign-in still checking its cookies hasn't changed them: likes and Home are still the installed account's.</summary>
    [Fact]
    public async Task APendingSignInDoesNotHideTheInstalledAccountsData()
    {
        var root = System.Text.Json.Nodes.JsonNode.Parse(Fixture.Text("home.json"))!;
        var shelf = root["contents"]!["singleColumnBrowseResultsRenderer"]!["tabs"]![0]!["tabRenderer"]!["content"]!["sectionListRenderer"]!["contents"]![0]!.DeepClone();
        shelf["musicCarouselShelfRenderer"]!["header"]!["musicCarouselShelfBasicHeaderRenderer"]!["title"] = new System.Text.Json.Nodes.JsonObject { ["simpleText"] = "Listen again" };
        var personal = new System.Text.Json.Nodes.JsonObject
        {
            ["contents"] = new System.Text.Json.Nodes.JsonObject { ["sectionListRenderer"] = new System.Text.Json.Nodes.JsonObject { ["contents"] = new System.Text.Json.Nodes.JsonArray(shelf) } },
        }.ToJsonString();
        var check = new Gate();
        using var provider = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
        {
            Handler = new FakeHandler(r => FakeHandler.Json(r.Url.AbsolutePath == "/sw.js_data" ? "{}" : personal)),
            ValidateAccount = async (c, _) =>
            {
                if (c.Cookies["SID"] == "B") await check.PassAsync();
                return new AccountInfo(c.Cookies["SID"]);
            },
        });
        await provider.SignInAsync(C("A"), persist: false);
        await provider.SetLikedAsync(Song, true);
        Assert.Single(await provider.HomeAsync());
        var b = provider.SignInAsync(C("B"), persist: false);
        await check.Reached.WaitAsync(Limit);
        Assert.Equal(AuthState.SigningIn, provider.AuthStatus.State);
        Assert.True(await provider.IsLikedAsync(Song).WaitAsync(Limit));
        Assert.Single(await provider.HomeAsync().WaitAsync(Limit));
        provider.CancelSignIn();
        check.Open();
        await IgnoreCancellation(b);
        Assert.Equal(C("A"), provider.CurrentCredentials);
    }

    sealed class RefusingTransferStore : IYouTubeMusicTransferStore
    {
        YouTubeMusicTransferSnapshot? _snapshot;
        public bool Refuse;
        public YouTubeMusicTransferSnapshot? Load() => _snapshot;

        public void Save(YouTubeMusicTransferSnapshot? snapshot)
        {
            if (Refuse) throw new IOException("denied");
            _snapshot = snapshot;
        }
    }
}

/// <summary>A memory store whose calls can each be held at a gate (on the calling thread) or refused (Sol's review harness).</summary>
internal sealed class SteppedStore : IYouTubeMusicCredentialStore
{
    public readonly MemoryCredentialStore Inner = new();
    public Gate? ReadGate, AccountGate, CredentialGate;
    public string? GatedAccount;
    public YouTubeMusicCredentials? GatedCredentials;
    public bool RefuseClear, RefuseGatedSave;
    public int ClearAttempts;

    public YouTubeMusicCredentials? LoadCredentials()
    {
        var c = Inner.LoadCredentials();
        ReadGate?.PassAsync().GetAwaiter().GetResult();
        return c;
    }

    public void SaveCredentials(YouTubeMusicCredentials c)
    {
        if (c.Equals(GatedCredentials))
        {
            CredentialGate?.PassAsync().GetAwaiter().GetResult();
            if (RefuseGatedSave) throw new IOException("denied");
        }
        Inner.SaveCredentials(c);
    }

    public void ClearCredentials()
    {
        Interlocked.Increment(ref ClearAttempts);
        if (RefuseClear) throw new UnauthorizedAccessException("denied");
        Inner.ClearCredentials();
    }

    public AccountInfo? LoadAccount() => Inner.LoadAccount();

    public void SaveAccount(AccountInfo? account)
    {
        if (account?.Name == GatedAccount) AccountGate?.PassAsync().GetAwaiter().GetResult();
        Inner.SaveAccount(account);
    }
}

using System.ComponentModel;
using Medley.Core;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.InnerTube;
using Medley.Providers.YouTube.Playback;
using Medley.Providers.YouTube.Sync;

namespace Medley.Providers.YouTube;

/// <summary>Construction options for <see cref="YouTubeMusicProvider"/>.</summary>
public sealed class YouTubeMusicProviderOptions
{
    /// <summary>Where the sign-in is saved. Default: in memory only.</summary>
    public IYouTubeMusicCredentialStore? Store { get; init; }

    /// <summary>Tests only: every InnerTube request (including throwaway check clients) goes through this handler.</summary>
    public HttpMessageHandler? Handler { get; init; }

    public StreamPreference StreamPreference { get; init; } = StreamPreference.Direct;

    /// <summary>Checks cookies by fetching the account they belong to. A seam for tests; default: a real account call.</summary>
    public Func<YouTubeMusicCredentials, CancellationToken, Task<AccountInfo>>? ValidateAccount { get; init; }

    /// <summary>Lyrics fallback. Default: LRCLIB.</summary>
    public LrcLibClient? LrcLib { get; init; }

    /// <summary>
    /// Called on sign-out to sign the app's sign-in web view out of Google too (WebView2: clear the profile's cookies),
    /// so the next sign-in can pick another account. Swift: <c>YTMSignInWebView.clearWebsiteData()</c>.
    /// </summary>
    public Func<Task>? ClearWebSignIn { get; init; }

    /// <summary>
    /// Makes the engine that plays this provider's tracks from its stream resolver: the Windows app passes its
    /// MediaPlayer engine. Default: <see cref="StreamOnlyPlaybackEngine"/>, which resolves streams but plays nothing.
    /// </summary>
    public Func<YouTubeStreamResolver, IPlaybackEngine>? PlaybackEngineFactory { get; init; }

    public TimeProvider? Time { get; init; }
}

/// <summary>
/// YouTube Music through InnerTube, the API music.youtube.com itself uses (Swift: <c>YouTubeMusicProvider</c>).
/// Thread-safe. Network and parsing run off the caller's thread; <see cref="PropertyChanged"/> (AuthStatus, Session,
/// Capabilities) is raised on the <see cref="SynchronizationContext"/> the provider was created on (the UI thread), or
/// inline when there was none.
/// </summary>
/// <remarks>
/// Every operation that reads or changes the account runs on one serial executor (<see cref="AccountOperations"/>):
/// restore, sign-in (and its commit), sign-out, the sign-in transfer's import and export, and saving rotated cookies. Each
/// applies its changes in one synchronous commit (<see cref="Commit"/>): the saved credentials, the installed cookies,
/// the status and session, the account summary and the transfer snapshot change together, or not at all. Catalog requests
/// never wait for it: they read the client's current credentials and go.
/// </remarks>
public sealed class YouTubeMusicProvider : IMusicProvider, IDisposable
{
    public ProviderId Id => ProviderId.YouTubeMusic;

    const string SignInOperation = "sign-in";

    /// <summary>The provider's state: status, session, the pending sign-in, likes, the prepared login. Never held across I/O.</summary>
    readonly Lock _lock = new();
    /// <summary>One commit at a time, held across its store writes (never across an await).</summary>
    readonly Lock _commit = new();
    readonly AccountOperations _operations = new();
    readonly IYouTubeMusicCredentialStore _store;
    readonly HttpMessageHandler? _handler;
    readonly Func<YouTubeMusicCredentials, CancellationToken, Task<AccountInfo>> _validateAccount;
    readonly LrcLibClient _lrcLib;
    readonly Func<Task>? _clearWebSignIn;

    /// <summary>What the installed credentials are: signed in as their account, or signed out (or failed). Never signing in.</summary>
    AuthStatus _committed = AuthStatus.SignedOut;
    /// <summary>The sign-in operation checking its cookies; <see cref="AuthStatus"/> says signing in while it is current.</summary>
    AccountOperations.Ticket? _pendingSignIn;
    /// <summary>The operation inside its commit, which <see cref="CancelSignIn"/> can no longer stop.</summary>
    AccountOperations.Ticket? _committing;
    ProviderSession _session = new(0, SessionIdentity.SignedOut);
    /// <summary>Whether the installed credentials are the saved ones, so their rotations are saved too.</summary>
    bool _installedSaved;
    /// <summary>Like state learned for the installed credentials (replaced, never cleared, on every swap).</summary>
    Dictionary<string, bool> _likes = new(StringComparer.Ordinal);
    /// <summary>The login the last prepare confirmed, which its choices commit (<see cref="CommitSignInAsync"/>).</summary>
    PreparedLogin? _prepared;
    ISignInTransferSink? _transfer;

    /// <summary>The account summary the store should hold, written behind the commit that decided it (<see cref="FlushSummary"/>).</summary>
    readonly Lock _summaryLock = new();
    AccountInfo? _summaryWanted;
    int _summaryVersion, _summaryWritten;
    bool _summaryWriting;

    internal InnerTubeClient Client { get; }
    public YouTubeStreamResolver StreamResolver { get; }

    /// <summary>The engine that plays this provider's tracks (<see cref="YouTubeMusicProviderOptions.PlaybackEngineFactory"/>).</summary>
    public IPlaybackEngine PlaybackEngine { get; }

    readonly SynchronizationContext? _context;

    /// <summary>AuthStatus, Session and Capabilities changes, on the provider's synchronization context.</summary>
    public event PropertyChangedEventHandler? PropertyChanged;

    public YouTubeMusicProvider(YouTubeMusicProviderOptions? options = null)
    {
        options ??= new YouTubeMusicProviderOptions();
        _store = options.Store ?? new MemoryCredentialStore();
        _handler = options.Handler;
        _lrcLib = options.LrcLib ?? new LrcLibClient();
        _clearWebSignIn = options.ClearWebSignIn;
        Client = new InnerTubeClient(handler: _handler, time: options.Time) { CredentialsRotated = SaveRotation };
        StreamResolver = new YouTubeStreamResolver(Client, options.StreamPreference, time: options.Time);
        PlaybackEngine = options.PlaybackEngineFactory?.Invoke(StreamResolver) ?? new StreamOnlyPlaybackEngine(StreamResolver);
        _context = SynchronizationContext.Current;
        _validateAccount = options.ValidateAccount ?? (async (creds, ct) =>
        {
            // A throwaway client that never saves anything, so checking cookies changes nothing until the sign-in commits.
            using var probe = NewThrowawayClient();
            probe.SetCredentials(creds);
            return await probe.AccountAsync(ct).ConfigureAwait(false);
        });
    }

    InnerTubeClient NewThrowawayClient() => new(handler: _handler);

    public ProviderCapabilities Capabilities
    {
        get
        {
            var caps = ProviderCapabilities.Search | ProviderCapabilities.Home | ProviderCapabilities.Explore | ProviderCapabilities.Lyrics |
                       ProviderCapabilities.SyncedLyrics | ProviderCapabilities.Radio | ProviderCapabilities.Playback;
            if (AuthStatus.IsSignedIn) caps |= ProviderCapabilities.Library | ProviderCapabilities.Like | ProviderCapabilities.PlaylistEditing | ProviderCapabilities.Follow;
            return caps;
        }
    }

    public AuthStatus AuthStatus
    {
        get
        {
            lock (_lock) return _pendingSignIn is { IsCurrent: true } ? AuthStatus.SigningIn : _committed;
        }
    }

    /// <summary>
    /// Who requests go out as: changes exactly when the client's credentials are swapped, in the same step, so it is right
    /// even while <see cref="AuthStatus"/> says signing in and the client still holds the previous account's cookies.
    /// </summary>
    public ProviderSession Session { get { lock (_lock) return _session; } }

    public bool IsSignedIn => AuthStatus.IsSignedIn;

    /// <summary>The session's current cookies and channel, null when signed out.</summary>
    public YouTubeMusicCredentials? CurrentCredentials => Client.CurrentCredentials;

    /// <summary>Raises the property changes on the provider's context (posted when called from elsewhere).</summary>
    void RaiseChanged()
    {
        if (PropertyChanged == null) return;
        void Raise(object? _)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AuthStatus)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Session)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Capabilities)));
        }
        if (_context == null || SynchronizationContext.Current == _context) Raise(null);
        else _context.Post(Raise, null);
    }

    // MARK: Account operations

    /// <summary>
    /// Runs <paramref name="change"/> as <paramref name="ticket"/>'s commit: one commit at a time, synchronous, and only
    /// while the operation is current. A superseded operation gets <see cref="OperationCanceledException"/> and changes
    /// nothing. Once a commit started it finishes, whatever is enqueued meanwhile: the newer operation commits after it.
    /// </summary>
    T Commit<T>(AccountOperations.Ticket ticket, Func<T> change, bool raise = true)
    {
        var ran = false;
        try
        {
            lock (_commit)
            {
                lock (_lock)
                {
                    if (!ticket.IsCurrent) throw new OperationCanceledException();
                    _committing = ticket;
                }
                ran = true;
                try
                {
                    return change();
                }
                finally
                {
                    lock (_lock)
                    {
                        _committing = null;
                        if (_pendingSignIn == ticket) _pendingSignIn = null;
                    }
                }
            }
        }
        finally
        {
            if (ran && raise) RaiseChanged();
        }
    }

    void Commit(AccountOperations.Ticket ticket, Action change) => Commit(ticket, () =>
    {
        change();
        return true;
    });

    /// <summary>
    /// Inside a commit: hands the client <paramref name="creds"/> and sets the session and status with them, in one step
    /// under the provider's lock, so nothing reads one without the other.
    /// </summary>
    void Install(YouTubeMusicCredentials? creds, bool saved, AuthStatus status)
    {
        lock (_lock)
        {
            Client.SetCredentials(creds);
            _session = _session.Next(creds != null ? SessionIdentity.ForAccount(AccountIdOf(creds)) : SessionIdentity.SignedOut);
            _installedSaved = saved && creds != null;
            _likes = new Dictionary<string, bool>(StringComparer.Ordinal);
            _committed = status;
        }
    }

    /// <summary>Inside a commit: the status the installed credentials have now.</summary>
    void SetCommitted(AuthStatus status)
    {
        lock (_lock) _committed = status;
    }

    bool CommittedSignedIn
    {
        get { lock (_lock) return _committed.IsSignedIn; }
    }

    /// <summary>Inside a commit: the transfer snapshot follows the account (best effort: it holds a copy, never the only one).</summary>
    void Snapshot(YouTubeMusicCredentials? creds, AccountInfo? account, byte[]? payload = null)
    {
        try { _transfer?.Committed(creds, account, payload); } catch (Exception) { }
    }

    /// <summary>
    /// Inside a commit: the account summary the store should hold. The write itself happens after the operation
    /// (<see cref="FlushSummary"/>), since it can't fail the sign-in (Swift: nonthrowing).
    /// </summary>
    void WantSummary(AccountInfo? account)
    {
        lock (_summaryLock)
        {
            _summaryWanted = account;
            _summaryVersion++;
        }
    }

    /// <summary>
    /// Writes the wanted summary until the store holds the newest one. One writer at a time: a write that is still running
    /// (an older account's, stuck in the store) is followed by the newest, so the summary saved last is always the one the
    /// last commit decided, matching the saved credentials.
    /// </summary>
    void FlushSummary()
    {
        lock (_summaryLock)
        {
            if (_summaryWriting || _summaryWritten == _summaryVersion) return;
            _summaryWriting = true;
        }
        while (true)
        {
            AccountInfo? account;
            int version;
            lock (_summaryLock)
            {
                if (_summaryWritten == _summaryVersion)
                {
                    _summaryWriting = false;
                    return;
                }
                account = _summaryWanted;
                version = _summaryVersion;
            }
            try { _store.SaveAccount(account); } catch (Exception) { } // holds no credentials; best effort
            lock (_summaryLock) _summaryWritten = version;
        }
    }

    /// <summary>After an operation changed the account (sign-in, channel switch, import, sign-out, revoked restore).</summary>
    void AccountChanged() => _transfer?.Changed();

    /// <summary><see cref="Sync.YouTubeMusicSignInTransfer"/> keeps its snapshot in the provider's commits through this.</summary>
    internal void AttachTransfer(ISignInTransferSink sink) => Volatile.Write(ref _transfer, sink);

    /// <summary>Saves cookies a response rotated, when they are still the installed, saved ones. An account operation, never awaited.</summary>
    void SaveRotation(int generation) => _ = _operations.RunAsync("save rotated cookies", AccountOperations.Kind.Immune, ticket =>
    {
        Commit(ticket, () =>
        {
            YouTubeMusicCredentials? current = null;
            lock (_lock)
            {
                if (_installedSaved && Client.Generation == generation) current = Client.CurrentCredentials;
            }
            if (current != null)
            {
                try { _store.SaveCredentials(current); } catch (Exception) { } // best effort: the session goes on with them
            }
            return true;
        }, raise: false);
        return Task.FromResult(true);
    });

    // MARK: Account

    /// <summary>
    /// Installs the saved sign-in and checks it with YouTube. Does nothing when credentials are installed already. A
    /// sign-in or sign-out enqueued meanwhile supersedes it: it then returns, changing nothing more.
    /// </summary>
    public async Task RestoreSessionAsync(CancellationToken ct = default)
    {
        bool revoked;
        try
        {
            revoked = await _operations.RunAsync("restore", AccountOperations.Kind.Ordinary, RestoreAsync, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return; // superseded: the newer operation decided
        }
        finally
        {
            FlushSummary();
        }
        if (revoked) AccountChanged();
    }

    async Task<bool> RestoreAsync(AccountOperations.Ticket ticket)
    {
        if (Client.CurrentCredentials != null) return false;
        if (_store.LoadCredentials() is not { } creds) return false;
        var saved = _store.LoadAccount();
        // A summary that names another account (its write didn't land before a crash) isn't shown for these cookies.
        var cached = saved != null && (saved.Id == null || saved.Id == AccountIdOf(creds)) ? Identified(saved, creds) : null;
        Commit(ticket, () => Install(creds, saved: true, AuthStatus.SignedIn(cached ?? Placeholder(creds))));
        AccountInfo info;
        try
        {
            info = Identified(await Client.AccountAsync(ticket.Token).ConfigureAwait(false), creds);
        }
        catch (ProviderException e) when (e.Kind == ProviderErrorKind.NotSignedIn)
        {
            // Cookies expired or were revoked: stop using them. If the store refuses to delete them, still sign out here;
            // the next launch finds them revoked again.
            Commit(ticket, () =>
            {
                try { _store.ClearCredentials(); } catch (Exception) { }
                Install(null, saved: false, AuthStatus.SignedOut);
                WantSummary(null);
                Snapshot(null, null);
            });
            return true;
        }
        catch (Exception) when (!ticket.Token.IsCancellationRequested)
        {
            return false; // offline at launch: keep the cached account so the library stays available
        }
        Commit(ticket, () =>
        {
            SetCommitted(AuthStatus.SignedIn(info));
            WantSummary(info);
        });
        return false;
    }

    /// <summary>The account shown for restored cookies until YouTube names it.</summary>
    static AccountInfo Placeholder(YouTubeMusicCredentials creds) => new("YouTube Music", id: AccountIdOf(creds));

    /// <summary>
    /// The immutable id caches key this account by: <c>datasync:</c> plus the datasync id the account switcher gave when
    /// it was picked. Never the handle or email. Null when the credentials don't carry one (a pasted cookie header).
    /// </summary>
    public static string? AccountIdOf(YouTubeMusicCredentials creds) =>
        creds.DatasyncId is { } d && d.Any(c => c != '|' && !char.IsWhiteSpace(c)) ? "datasync:" + d : null;

    /// <summary><paramref name="info"/> with its id set from the credentials it belongs to.</summary>
    public static AccountInfo Identified(AccountInfo info, YouTubeMusicCredentials creds) => info with { Id = AccountIdOf(creds) };

    /// <summary>Signs in with a <c>Cookie:</c> header copied from a signed-in browser session (advanced fallback).</summary>
    public Task SignInWithCookieHeaderAsync(string cookieHeader, bool persist = true, CancellationToken ct = default)
    {
        var creds = YouTubeMusicCredentials.FromCookieHeader(cookieHeader)
            ?? throw ProviderException.Decoding("The cookie header needs SAPISID (or __Secure-3PAPISID) and SID cookies from music.youtube.com.");
        return SignInAsync(creds, persist, ct);
    }

    const string PrepareOperation = "prepare sign-in";

    /// <summary>
    /// Lists every account and channel reachable from <paramref name="creds"/> (each Google account signed in to that
    /// session and each brand channel under it, as YouTube's account switcher shows them). Every entry is confirmed by a
    /// real request, and a channel is kept only when selecting it actually changes the account. The credentials are held
    /// for <see cref="CommitSignInAsync"/>. With <paramref name="preferSelected"/>, the identity the session already acts
    /// as (the channel just picked on YouTube's own "Choose a channel" page) comes back alone once confirmed.
    /// </summary>
    /// <remarks>
    /// The first step of a sign-in, so an account operation like one: it supersedes older work, and a sign-out, a newer
    /// sign-in, <see cref="CancelSignIn"/> or <see cref="DiscardPreparedSignIn"/> supersedes it.
    /// </remarks>
    public Task<AccountChoiceList> PrepareAccountsAsync(YouTubeMusicCredentials creds, string sourceName = "YouTube", bool preferSelected = false,
        CancellationToken ct = default) =>
        _operations.RunAsync(PrepareOperation, AccountOperations.Kind.Supersedes, async ticket =>
        {
            var found = await PrepareAsync(ticket, creds, sourceName, 7, preferSelected).ConfigureAwait(false);
            return Hold(ticket, found);
        }, ct);

    /// <summary>The accounts and channels the current sign-in can switch to.</summary>
    public Task<AccountChoiceList> SwitchableAccountsAsync(CancellationToken ct = default) =>
        _operations.RunAsync(PrepareOperation, AccountOperations.Kind.Supersedes, async ticket =>
        {
            var current = CurrentCredentials ?? throw ProviderException.NotSignedIn();
            var found = await PrepareAsync(ticket, current, "YouTube", 7, preferSelected: false).ConfigureAwait(false);
            return Hold(ticket, found);
        }, ct);

    /// <summary>In the prepare's commit: holds its login, and ties each choice to it.</summary>
    AccountChoiceList Hold(AccountOperations.Ticket ticket, (PreparedLogin Login, AccountChoiceList List) found) => Commit(ticket, () =>
    {
        lock (_lock) _prepared = found.Login;
        return found.List;
    }, raise: false);

    /// <summary>The confirmed choices, each carrying the login it came from. Changes nothing.</summary>
    async Task<(PreparedLogin, AccountChoiceList)> PrepareAsync(AccountOperations.Ticket ticket, YouTubeMusicCredentials creds, string sourceName, int maxIndex,
        bool preferSelected)
    {
        var ct = ticket.Token;
        var login = new PreparedLogin(creds, sourceName);
        AccountChoiceList Tied(IReadOnlyList<AccountChoice> choices, bool authoritative)
        {
            if (!ticket.IsCurrent) throw new OperationCanceledException();
            return new AccountChoiceList(choices.Select(c => c with { Login = login }).ToList(), authoritative);
        }
        IReadOnlyList<AccountIdentity> listed;
        using (var probe = NewThrowawayClient())
        {
            probe.SetCredentials(creds);
            // A network or server error propagates (not treated as "no channels"). Only an empty or unreadable body
            // falls back to a per-authUser sweep, which is not authoritative.
            listed = await probe.AccountIdentitiesAsync(ct).ConfigureAwait(false);
        }
        var fromSwitcher = listed.Count > 0;

        // Only when the session holds one Google account: the web sign-in's cookies don't say which account the page
        // landed on, so with several, the switcher could report another account's pick.
        if (preferSelected && listed.Select(i => i.AuthUser).Distinct().Count() == 1 && listed.FirstOrDefault(i => i.IsSelected) is { } chosen)
        {
            // Confirm against the account's default identity too, so an ignored channel selector can't pass.
            List<AccountIdentity> subset = chosen.DelegatedSessionId == null ? [chosen] : [new AccountIdentity(chosen.AuthUser), chosen];
            var confirmed = await ConfirmedAccountsAsync(subset, creds, sweep: false, ct).ConfigureAwait(false);
            if (confirmed.FirstOrDefault(a => a.Identity.SelectorKey == chosen.SelectorKey) is { } match) return (login, Tied([match], true));
        }

        // The selected identity first, then the switcher's order.
        var candidates = fromSwitcher
            ? listed.Where(i => i.IsSelected).Concat(listed.Where(i => !i.IsSelected)).ToList()
            : Enumerable.Range(0, maxIndex + 1).Select(i => new AccountIdentity(i)).ToList();
        var accounts = await ConfirmedAccountsAsync(candidates, creds, sweep: !fromSwitcher, ct).ConfigureAwait(false);
        if (!ticket.IsCurrent) throw new OperationCanceledException();
        if (accounts.Count == 0) throw new SignInException($"{sourceName} isn't signed in to YouTube anymore. Sign in again, then try again.");
        return (login, Tied(accounts, fromSwitcher));
    }

    /// <summary>
    /// Resolves each candidate with a real <c>account_menu</c> request (a few at a time, each on its own throwaway
    /// client) and keeps the ones that are real, distinct and actually selectable. <paramref name="sweep"/> marks the bare
    /// authUser sweep, which stops at the first empty index.
    /// </summary>
    async Task<List<AccountChoice>> ConfirmedAccountsAsync(IReadOnlyList<AccountIdentity> candidates, YouTubeMusicCredentials creds, bool sweep, CancellationToken ct)
    {
        var seenSelectors = new HashSet<string>();
        var unique = candidates.Where(c => seenSelectors.Add(c.SelectorKey)).ToList();
        var infos = new AccountInfo?[unique.Count];
        if (sweep)
        {
            // One index at a time, stopping at the first gap, so a failing request past the last real account can't
            // sink the sign-in.
            using var client = NewThrowawayClient();
            for (var index = 0; index < unique.Count; index++)
            {
                ct.ThrowIfCancellationRequested();
                client.SetCredentials(creds.WithAccount(unique[index].AuthUser, unique[index].DatasyncId));
                try { infos[index] = await client.AccountAsync(ct).ConfigureAwait(false); }
                catch (ProviderException e) when (e.Kind == ProviderErrorKind.NotSignedIn)
                {
                    if (unique[index].AuthUser > 0) break;
                }
            }
        }
        else
        {
            var workers = Math.Min(6, unique.Count);
            var tasks = Enumerable.Range(0, workers).Select(async worker =>
            {
                using var client = NewThrowawayClient();
                for (var index = worker; index < unique.Count; index += workers)
                {
                    ct.ThrowIfCancellationRequested();
                    client.SetCredentials(creds.WithAccount(unique[index].AuthUser, unique[index].DatasyncId));
                    try { infos[index] = await client.AccountAsync(ct).ConfigureAwait(false); }
                    catch (ProviderException e) when (e.Kind == ProviderErrorKind.NotSignedIn) { infos[index] = null; } // no account at this selector
                }
            }).ToList();
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }

        var resolved = new List<(AccountIdentity Candidate, AccountInfo Info)>();
        for (var index = 0; index < unique.Count; index++)
        {
            if (infos[index] is not { } info)
            {
                if (sweep && unique[index].AuthUser > 0) break;
                continue;
            }
            resolved.Add((unique[index], info));
        }

        // The default (no channel) identity for each Google account, to prove a channel selector actually took.
        static string IdentityKey(AccountInfo info) => (info.Detail ?? info.Name).ToLowerInvariant();
        var baseByAuthUser = new Dictionary<int, string>();
        foreach (var entry in resolved.Where(e => e.Candidate.DelegatedSessionId == null)) baseByAuthUser[entry.Candidate.AuthUser] = IdentityKey(entry.Info);

        var accounts = new List<AccountChoice>();
        var seen = new HashSet<string>();
        foreach (var (candidate, info) in resolved)
        {
            // A channel whose selectors were ignored comes back as its account's default identity: drop it rather than
            // list a channel Medley can't switch to.
            if (candidate.DelegatedSessionId != null && baseByAuthUser.TryGetValue(candidate.AuthUser, out var b) && b == IdentityKey(info)) continue;
            var dedupe = info.Detail != null ? "r:" + IdentityKey(info) : "s:" + candidate.SelectorKey;
            if (!seen.Add(dedupe)) continue;
            accounts.Add(new AccountChoice(candidate, new AccountInfo(info.Name, info.Avatar ?? candidate.Photo, info.Detail ?? candidate.ListedByline)));
        }
        return accounts;
    }

    /// <summary>
    /// Commits the sign-in for the chosen account, with the login its prepare confirmed. Throws
    /// <see cref="OperationCanceledException"/> when that login is no longer held (discarded, signed out, or a newer
    /// prepare replaced it): a choice never commits another prepare's credentials.
    /// </summary>
    public async Task CommitSignInAsync(AccountChoice account, CancellationToken ct = default)
    {
        var login = account.Login ?? throw new OperationCanceledException();
        try
        {
            await _operations.RunAsync(SignInOperation, AccountOperations.Kind.Supersedes, ticket =>
            {
                lock (_lock)
                {
                    if (_prepared != login) throw new OperationCanceledException();
                }
                return CommitChoiceAsync(ticket, login, account);
            }, ct).ConfigureAwait(false);
            AccountChanged();
        }
        finally
        {
            FlushSummary();
        }
    }

    /// <summary>Inside a sign-in operation: checks and commits <paramref name="account"/>, then lets go of its login.</summary>
    async Task<bool> CommitChoiceAsync(AccountOperations.Ticket ticket, PreparedLogin login, AccountChoice account)
    {
        var creds = login.Credentials.WithAccount(account.Identity.AuthUser, account.Identity.DatasyncId);
        try
        {
            return await SignInAsync(ticket, creds, persist: true, committed: () =>
            {
                lock (_lock)
                {
                    if (_prepared == login) _prepared = null;
                }
            }).ConfigureAwait(false);
        }
        catch (ProviderException e) when (e.Kind == ProviderErrorKind.NotSignedIn)
        {
            throw new SignInException($"{login.SourceName} isn't signed in to YouTube anymore. Sign in again, then try again.");
        }
    }

    /// <summary>
    /// The whole web sign-in after the window collected its cookies, as one account operation: prepare (preferring the
    /// channel picked on YouTube's page), and commit straight away when there's exactly one confirmed account. Otherwise
    /// holds the login and returns the list to show. A sign-out, <see cref="CancelSignIn"/> or
    /// <see cref="DiscardPreparedSignIn"/> at any point before the commit stops it.
    /// </summary>
    public async Task<AccountChoiceList?> SignInWithWebCookiesAsync(IEnumerable<WebCookie> cookies, CancellationToken ct = default)
    {
        var creds = WebSignIn.CredentialsFromCookies(cookies) ?? throw ProviderException.NotSignedIn();
        AccountChoiceList? shown;
        try
        {
            shown = await _operations.RunAsync<AccountChoiceList?>(PrepareOperation, AccountOperations.Kind.Supersedes, async ticket =>
            {
                var (login, found) = await PrepareAsync(ticket, creds, "YouTube", 7, preferSelected: true).ConfigureAwait(false);
                if (!found.Authoritative || found.Accounts.Count != 1) return Hold(ticket, (login, found));
                await CommitChoiceAsync(ticket, login, found.Accounts[0]).ConfigureAwait(false);
                return null;
            }, ct).ConfigureAwait(false);
            if (shown == null) AccountChanged();
        }
        finally
        {
            FlushSummary();
        }
        return shown;
    }

    /// <summary>Drops the held login (window closed or cancelled), and supersedes any prepare still in flight.</summary>
    public void DiscardPreparedSignIn()
    {
        AccountOperations.Retirement retired;
        lock (_lock)
        {
            _prepared = null;
            var committing = _committing;
            retired = _operations.Stale(t => t.Name == PrepareOperation && t != committing);
        }
        _operations.Complete(retired);
    }

    /// <summary>
    /// Checks the cookies, then signs in with them, as one account operation that supersedes everything older (a restore,
    /// an import, another sign-in). Throws <see cref="OperationCanceledException"/> when <see cref="CancelSignIn"/>, a
    /// newer sign-in, a sign-out or the token got there first; the status is then left as it was.
    /// </summary>
    public async Task SignInAsync(YouTubeMusicCredentials creds, bool persist, CancellationToken ct = default)
    {
        try
        {
            await _operations.RunAsync(SignInOperation, AccountOperations.Kind.Supersedes, ticket => SignInAsync(ticket, creds, persist), ct).ConfigureAwait(false);
            AccountChanged();
        }
        finally
        {
            FlushSummary();
        }
    }

    /// <param name="committed">Inside the commit, after the swap: what the caller's operation changes with it.</param>
    async Task<bool> SignInAsync(AccountOperations.Ticket ticket, YouTubeMusicCredentials creds, bool persist, Action? committed = null)
    {
        lock (_lock)
        {
            if (!ticket.IsCurrent) throw new OperationCanceledException();
            _pendingSignIn = ticket;
            // A sign-in that's cancelled goes back to the account, or to signed out, never to an old failure.
            if (_committed.State == AuthState.Failed) _committed = AuthStatus.SignedOut;
        }
        RaiseChanged();
        // Superseded or cancelled (CancelSignIn, the caller's token): the status stops saying signing in at once.
        using var superseded = ticket.Token.Register(RaiseChanged);
        try
        {
            AccountInfo info;
            try
            {
                info = await _validateAccount(creds, ticket.Token).ConfigureAwait(false);
            }
            catch (Exception) when (!ticket.IsCurrent || ticket.Token.IsCancellationRequested)
            {
                throw new OperationCanceledException();
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                // The installed session (if any) was never touched, so a signed-in listener stays signed in.
                Commit(ticket, () =>
                {
                    if (!CommittedSignedIn) SetCommitted(AuthStatus.Failed(error.Message));
                });
                throw;
            }
            var account = Identified(info, creds);
            Commit(ticket, () =>
            {
                if (persist)
                {
                    try
                    {
                        _store.SaveCredentials(creds);
                    }
                    catch (Exception error)
                    {
                        // The store didn't take the cookies: nothing else changed, and the sign-in reports it.
                        if (!CommittedSignedIn) SetCommitted(AuthStatus.Failed(SaveFailure(error)));
                        throw;
                    }
                }
                Install(creds, saved: persist, AuthStatus.SignedIn(account));
                if (persist) WantSummary(account);
                Snapshot(creds, account);
                committed?.Invoke();
            });
            return true;
        }
        finally
        {
            bool changed;
            lock (_lock)
            {
                changed = _pendingSignIn == ticket;
                if (changed) _pendingSignIn = null;
            }
            if (changed) RaiseChanged();
        }
    }

    internal static string SaveFailure(Exception error) => $"Couldn't save the sign-in. {error.Message}";

    /// <summary>
    /// Commits a sign-in another device made (the sign-in transfer) as one account operation: checks it with
    /// <paramref name="verify"/>, then saves and installs it, with <paramref name="payload"/> as the transfer snapshot. A
    /// sign-in or sign-out enqueued meanwhile supersedes it (<see cref="OperationCanceledException"/>, nothing changed).
    /// </summary>
    internal async Task ImportSignInAsync(YouTubeMusicCredentials creds, Func<CancellationToken, Task<AccountInfo>> verify, bool persist, byte[] payload,
        CancellationToken ct)
    {
        try
        {
            await _operations.RunAsync("import", AccountOperations.Kind.Ordinary, async ticket =>
            {
                AccountInfo info;
                try
                {
                    info = await verify(ticket.Token).ConfigureAwait(false);
                }
                catch (Exception) when (!ticket.IsCurrent)
                {
                    throw new OperationCanceledException();
                }
                var account = Identified(info, creds);
                Commit(ticket, () =>
                {
                    if (persist) _store.SaveCredentials(creds); // refused: throws, nothing changed
                    Install(creds, saved: persist, AuthStatus.SignedIn(account));
                    if (persist) WantSummary(account);
                    Snapshot(creds, account, payload);
                });
                return true;
            }, ct).ConfigureAwait(false);
            AccountChanged();
        }
        finally
        {
            FlushSummary();
        }
    }

    /// <summary>
    /// Runs <paramref name="read"/> as an account operation, inside a commit, with the status and credentials installed:
    /// the transfer's export, which may retake its snapshot. Never superseded.
    /// </summary>
    internal Task<T> ReadAccountAsync<T>(Func<AuthStatus, YouTubeMusicCredentials?, T> read) =>
        _operations.RunAsync("read account", AccountOperations.Kind.Immune, ticket => Task.FromResult(Commit(ticket, () =>
        {
            AuthStatus status;
            lock (_lock) status = _committed;
            return read(status, Client.CurrentCredentials);
        }, raise: false)));

    /// <summary>
    /// Abandons a pending sign-in (checking its cookies, or waiting to) and shows the status from before it at once.
    /// Does nothing once it is committing.
    /// </summary>
    public void CancelSignIn()
    {
        AccountOperations.Retirement retired;
        bool changed;
        lock (_lock)
        {
            changed = _pendingSignIn is { IsCurrent: true } pending && pending != _committing;
            var committing = _committing;
            retired = _operations.Stale(t => t.Name is SignInOperation or PrepareOperation && t != committing);
            if (changed) _pendingSignIn = null;
        }
        _operations.Complete(retired);
        if (changed) RaiseChanged();
    }

    /// <summary>Signs out. When the saved cookies can't be deleted it stays signed in; <see cref="TrySignOutAsync"/> reports that.</summary>
    public async Task SignOutAsync()
    {
        try { await TrySignOutAsync().ConfigureAwait(false); } catch (Exception) { }
    }

    /// <summary>
    /// Deletes the saved cookies first: if the store refuses, this throws and the session stays as it was. An account
    /// operation that supersedes everything older and is never superseded itself, so a sign-in started meanwhile runs after it.
    /// </summary>
    public async Task TrySignOutAsync()
    {
        try
        {
            await _operations.RunAsync("sign-out", AccountOperations.Kind.SupersedesImmune, ticket =>
            {
                Commit(ticket, () =>
                {
                    lock (_lock) _pendingSignIn = null; // superseded with everything older
                    _store.ClearCredentials();
                    lock (_lock) _prepared = null; // a login held from before the sign-out never commits after it
                    Install(null, saved: false, AuthStatus.SignedOut);
                    WantSummary(null);
                    Snapshot(null, null);
                });
                return Task.FromResult(true);
            }).ConfigureAwait(false);
            AccountChanged();
        }
        finally
        {
            FlushSummary();
        }
        // The web view's own cookies, so the next sign-in can pick another account. Outside the operation: it changes
        // nothing here, and a sign-in started meanwhile shouldn't wait for it.
        if (_clearWebSignIn != null)
        {
            try { await _clearWebSignIn().ConfigureAwait(false); } catch (Exception) { }
        }
    }

    /// <summary>The account the current cookies belong to, asked of YouTube now.</summary>
    public Task<AccountInfo> AccountAsync(CancellationToken ct = default) => AsInstalledAsync(async (creds, _) =>
        Identified(await Client.AccountAsync(ct).ConfigureAwait(false), creds ?? throw ProviderException.NotSignedIn()));

    /// <summary>
    /// Runs a read as the credentials installed now (not the status: a sign-in still checking its cookies hasn't changed
    /// them), with their like cache. When they were swapped before it answered, it can't tell which account it read, so
    /// it asks again as the new ones.
    /// </summary>
    async Task<T> AsInstalledAsync<T>(Func<YouTubeMusicCredentials?, Dictionary<string, bool>, Task<T>> read)
    {
        for (var attempt = 0; ; attempt++)
        {
            YouTubeMusicCredentials? creds;
            int generation;
            Dictionary<string, bool> likes;
            lock (_lock)
            {
                (creds, generation) = Client.Installed;
                likes = _likes;
            }
            var result = await read(creds, likes).ConfigureAwait(false);
            if (Client.Generation == generation) return result;
            if (attempt == 4) throw new OperationCanceledException("The YouTube Music account kept changing.");
        }
    }

    /// <summary>
    /// The installed credentials' binding for a write: it goes out with these credentials or not at all, and the like
    /// cache it fills is theirs.
    /// </summary>
    (WriteBinding Binding, Dictionary<string, bool> Likes) InstalledWrite()
    {
        lock (_lock)
        {
            var (creds, generation) = Client.Installed;
            if (creds == null) throw ProviderException.NotSignedIn();
            return (new WriteBinding(null, generation), _likes);
        }
    }

    // MARK: Browse

    /// <summary>Personal shelves only when the request went out signed in (by the installed credentials, not the status).</summary>
    public Task<IReadOnlyList<Shelf>> HomeAsync(CancellationToken ct = default) => AsInstalledAsync(async (creds, _) =>
    {
        var shelves = await Client.HomeAsync(ct).ConfigureAwait(false);
        return creds != null ? shelves : AnonymousHome(shelves);
    });

    /// <summary>
    /// Shelves made from a listener's own history. Signed out, YouTube can still send some for this machine's visitor id
    /// after a few plays; Home leaves them out then.
    /// </summary>
    public static readonly IReadOnlyList<string> PersonalShelfTitles =
        ["listen again", "your mixes", "mixed for you", "liked music", "your likes", "from your library", "recommended for you", "your favorites", "recently played"];

    /// <summary><paramref name="shelves"/> without the personal ones, or the Liked Music playlist (<c>LM</c>) anywhere.</summary>
    public static IReadOnlyList<Shelf> AnonymousHome(IReadOnlyList<Shelf> shelves)
    {
        var output = new List<Shelf>();
        foreach (var shelf in shelves)
        {
            var title = shelf.Title.ToLowerInvariant();
            if (PersonalShelfTitles.Any(t => title.Contains(t, StringComparison.Ordinal))) continue;
            var items = shelf.Items.Where(i => i is not MediaItem.PlaylistItem { Playlist.ProviderID: "LM" }).ToList();
            if (items.Count > 0) output.Add(shelf with { Items = items });
        }
        return output;
    }

    public Task<IReadOnlyList<Shelf>> ExploreAsync(CancellationToken ct = default) => Client.ExploreAsync(ct);

    public Task<Shelf> ShelfAsync(string moreToken, CancellationToken ct = default) => Client.ShelfAsync(moreToken, ct);

    // MARK: Search

    public async Task<SearchResults> SearchAsync(string query, SearchScope scope, CancellationToken ct = default)
    {
        var q = query.Trim();
        if (q.Length == 0) return new SearchResults();
        return await Client.SearchAsync(q, scope, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<string>> SearchSuggestionsAsync(string query, CancellationToken ct = default) =>
        (await RichSearchSuggestionsAsync(query, ct).ConfigureAwait(false)).Queries;

    public async Task<SearchSuggestions> RichSearchSuggestionsAsync(string query, CancellationToken ct = default)
    {
        var q = query.Trim();
        if (q.Length == 0) return new SearchSuggestions([], []);
        return await Client.SuggestionsAsync(q, ct).ConfigureAwait(false);
    }

    /// <summary>Search rows and top-result cards often leave out the album. The watch queue's byline has it.</summary>
    public async Task<Track> LinkedTrackAsync(Track track, CancellationToken ct = default)
    {
        if (!(track.Album?.Id == null || !track.Artists.Any(a => a.Id != null) || track.Duration == null || track.Artwork == null)) return track;
        var linked = await Client.LinkedTrackAsync(track.ProviderID, ct).ConfigureAwait(false);
        return linked == null ? track : Filling(track, linked);
    }

    /// <summary>This track with the album and artist links (and the artwork, when it has none) another listing of the same
    /// song has. A song handed over from another device can arrive without artwork.</summary>
    public static Track Filling(Track track, Track other)
    {
        var t = track;
        if (t.Album?.Id == null && other.Album is { Id: not null } album) t = t with { Album = album };
        if (!t.Artists.Any(a => a.Id != null) && other.Artists.Any(a => a.Id != null)) t = t with { Artists = other.Artists };
        if (t.Duration == null) t = t with { Duration = other.Duration };
        if (t.Artwork == null && other.Artwork != null) t = t with { Artwork = other.Artwork };
        return t;
    }

    // MARK: Entities

    public Task<AlbumDetail> AlbumAsync(string id, CancellationToken ct = default) => Client.AlbumAsync(id, ct);
    public Task<ArtistDetail> ArtistAsync(string id, CancellationToken ct = default) => Client.ArtistAsync(id, ct);
    public Task<PlaylistDetail> PlaylistAsync(string id, CancellationToken ct = default) => Client.PlaylistAsync(id, ct: ct);
    public Task<Page<Track>> PlaylistTracksAsync(string continuation, CancellationToken ct = default) => Client.PlaylistTracksAsync(continuation, ct: ct);
    public Task<PlaylistDetail> UncachedPlaylistAsync(string id, CancellationToken ct = default) => Client.PlaylistAsync(id, uncached: true, ct);
    public Task<Page<Track>> UncachedPlaylistTracksAsync(string continuation, CancellationToken ct = default) => Client.PlaylistTracksAsync(continuation, uncached: true, ct);

    // MARK: Library

    public Task<Page<MediaItem>> LibraryAsync(LibraryKind kind, string? continuation, CancellationToken ct = default) =>
        Client.LibraryAsync(kind, continuation, ct);

    /// <summary>Sent only with the credentials installed when it was called (<see cref="PlaylistEditException.AccountChanged"/> otherwise).</summary>
    public Task SetLikedAsync(Track track, bool liked, CancellationToken ct = default) => SetLikedAsync(track, liked, InstalledWrite(), ct);

    /// <summary>
    /// The same write bound to <paramref name="account"/>, the account a menu or button was showing: nothing is sent
    /// (<see cref="PlaylistEditException.AccountChanged"/>) when another account's credentials are installed by then.
    /// </summary>
    public Task SetLikedAsync(Track track, bool liked, PlaylistWriteAccount account, CancellationToken ct = default)
    {
        (WriteBinding, Dictionary<string, bool>) write;
        // The binding and the like cache are read together, so the cache updated is the bound account's.
        lock (_lock) write = (WriteBindingFor(account), _likes);
        return SetLikedAsync(track, liked, write, ct);
    }

    async Task SetLikedAsync(Track track, bool liked, (WriteBinding Binding, Dictionary<string, bool> Likes) write, CancellationToken ct)
    {
        await Client.RateVideoAsync(track.ProviderID, liked, write.Binding, ct).ConfigureAwait(false);
        lock (_lock) write.Likes[track.ProviderID] = liked;
    }

    /// <summary>Asks the server once per track per session (<c>Extra["likeStatus"]</c> is only a hint).</summary>
    public Task<bool> IsLikedAsync(Track track, CancellationToken ct = default) => AsInstalledAsync(async (creds, likes) =>
    {
        if (creds == null) return false;
        lock (_lock)
        {
            if (likes.TryGetValue(track.ProviderID, out var known)) return known;
        }
        var liked = await Client.IsLikedAsync(track.ProviderID, ct).ConfigureAwait(false);
        lock (_lock) likes[track.ProviderID] = liked; // the cache of the credentials it was asked with; a swap replaced it
        return liked;
    });

    /// <summary>Every write goes out with the credentials installed when it was called, or not at all.</summary>
    public async Task SetSavedAsync(MediaItem item, bool saved, CancellationToken ct = default)
    {
        var write = InstalledWrite();
        switch (item)
        {
            case MediaItem.TrackItem { Track: var track }:
                await SetLikedAsync(track, saved, write, ct).ConfigureAwait(false);
                break;
            case MediaItem.AlbumItem { Album: var album }:
                var playlistId = album.Extra.GetValueOrDefault("playlistId")
                    ?? (await Client.AlbumAsync(album.ProviderID, ct).ConfigureAwait(false)).Album.Extra.GetValueOrDefault("playlistId")
                    ?? throw ProviderException.NotSupported("Saving this album");
                await Client.RatePlaylistAsync(playlistId, saved, write.Binding, ct).ConfigureAwait(false);
                break;
            case MediaItem.PlaylistItem { Playlist: var playlist }:
                if (playlist.Extra.ContainsKey("category")) throw ProviderException.NotSupported("Saving a category");
                await Client.RatePlaylistAsync(playlist.ProviderID, saved, write.Binding, ct).ConfigureAwait(false);
                break;
            case MediaItem.ArtistItem { Artist: var artist }:
                var channel = artist.Extra.GetValueOrDefault("channelId")
                    ?? (await Client.ArtistAsync(artist.ProviderID, ct).ConfigureAwait(false)).Artist.Extra.GetValueOrDefault("channelId");
                await Client.SubscribeAsync(channel ?? artist.ProviderID, saved, write.Binding, ct).ConfigureAwait(false);
                break;
        }
    }

    string? AccountName => AuthStatus.Account?.Name;

    public Task<Playlist> CreatePlaylistAsync(string title, string? description, CancellationToken ct = default) =>
        CreatePlaylistAsync(title, description, InstalledWrite().Binding, ct);

    public Task<Playlist> CreatePlaylistAsync(string title, string? description, PlaylistWriteAccount account, CancellationToken ct = default) =>
        CreatePlaylistAsync(title, description, WriteBindingFor(account), ct);

    async Task<Playlist> CreatePlaylistAsync(string title, string? description, WriteBinding? binding, CancellationToken ct)
    {
        var id = await Client.CreatePlaylistAsync(title, description, binding: binding, ct: ct).ConfigureAwait(false);
        return new Playlist { ProviderID = id, Provider = ProviderId.YouTubeMusic, Title = title, Owner = AccountName, TrackCount = 0, Summary = description, IsEditable = true };
    }

    public Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default) =>
        tracks.Count == 0 ? Task.CompletedTask : AddAsync(tracks, playlistId, InstalledWrite().Binding, ct);

    public Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount account, CancellationToken ct = default) =>
        tracks.Count == 0 ? Task.CompletedTask : AddAsync(tracks, playlistId, WriteBindingFor(account), ct);

    async Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, WriteBinding? binding, CancellationToken ct)
    {
        if (tracks.Count == 0) return;
        await Client.EditPlaylistAsync(playlistId, tracks.Select(t => (PlaylistEdit)new PlaylistEdit.Add(t.ProviderID)).ToList(), binding, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Removes every copy of each song: a playlist lists a song it holds twice once, so Remove from Playlist means the
    /// song, not one entry. The playlist's entries are read from the service (all pages, uncached).
    /// </summary>
    public Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default) =>
        tracks.Count == 0 ? Task.CompletedTask : RemoveAsync(tracks, playlistId, InstalledWrite().Binding, ct);

    public Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount account, CancellationToken ct = default) =>
        tracks.Count == 0 ? Task.CompletedTask : RemoveAsync(tracks, playlistId, WriteBindingFor(account), ct);

    async Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, WriteBinding? binding, CancellationToken ct)
    {
        if (tracks.Count == 0) return;
        var edits = RemovalEdits(tracks, await EntriesAsync(playlistId, ct).ConfigureAwait(false));
        if (edits.Count == 0) throw ProviderException.NotFound();
        await Client.EditPlaylistAsync(playlistId, edits, binding, ct).ConfigureAwait(false);
    }

    /// <summary>Not supported, as in the Swift provider (no <see cref="ProviderCapabilities.PlaylistInsert"/>).</summary>
    public Task InsertAsync(IReadOnlyList<Track> tracks, string playlistId, int position, CancellationToken ct = default) =>
        throw ProviderException.NotSupported("Adding songs at a position in a playlist");

    public Task InsertAsync(IReadOnlyList<Track> tracks, string playlistId, int position, PlaylistWriteAccount account, CancellationToken ct = default) =>
        throw ProviderException.NotSupported("Adding songs at a position in a playlist");

    public int? PlaylistEditBatchSize => null;

    /// <summary>
    /// Checked here against the session, then carried to the client, which checks it again where it picks the cookies:
    /// a swap that lands in between stops the write there.
    /// </summary>
    WriteBinding WriteBindingFor(PlaylistWriteAccount account)
    {
        lock (_lock)
        {
            var ok = _session.Identity.Kind == SessionIdentityKind.Account &&
                     (account.AccountId is { } id ? id == _session.Identity.AccountId : _session == account.Session);
            if (!ok) throw PlaylistEditException.AccountChanged();
            return new WriteBinding(account.AccountId, Client.Generation);
        }
    }

    /// <summary>
    /// One removal per entry (<c>setVideoId</c>) of each song in <paramref name="entries"/>: every copy. Refuses the whole
    /// removal, before anything is written, when a copy of one of the songs has no <c>setVideoId</c>.
    /// </summary>
    public static IReadOnlyList<PlaylistEdit> RemovalEdits(IReadOnlyList<Track> tracks, IReadOnlyList<Track> entries)
    {
        var wanted = tracks.Select(t => t.ProviderID).ToHashSet();
        var seen = new HashSet<string>();
        var edits = new List<PlaylistEdit>();
        var unidentified = 0;
        foreach (var entry in entries.Where(e => wanted.Contains(e.ProviderID)))
        {
            if (entry.Extra.GetValueOrDefault("setVideoId") is not { Length: > 0 } setId) { unidentified++; continue; }
            if (seen.Add(setId)) edits.Add(new PlaylistEdit.Remove(entry.ProviderID, setId));
        }
        if (unidentified > 0) throw PlaylistEditException.UnidentifiedCopies(unidentified);
        return edits;
    }

    /// <summary>Upper bound on pages read to find a playlist's entries (YouTube caps a playlist at 5,000 songs, 100 a page).</summary>
    public const int EntryPageLimit = 60;

    async Task<List<Track>> EntriesAsync(string playlistId, CancellationToken ct)
    {
        var detail = await Client.PlaylistAsync(playlistId, uncached: true, ct).ConfigureAwait(false);
        var all = detail.Tracks.ToList();
        var token = detail.Continuation;
        var pages = 0;
        while (token != null)
        {
            if (pages >= EntryPageLimit) throw ProviderException.NotSupported("Removing songs from a playlist this long");
            var page = await Client.PlaylistTracksAsync(token, uncached: true, ct).ConfigureAwait(false);
            all.AddRange(page.Items);
            token = page.Continuation;
            pages++;
        }
        return all;
    }

    // MARK: Playback support

    public Task<IReadOnlyList<Track>> RadioAsync(Track seed, CancellationToken ct = default) => Client.RadioForVideoAsync(seed.ProviderID, ct);

    public Task<IReadOnlyList<Track>> RadioAsync(string seedId, CancellationToken ct = default) => Client.RadioForSeedAsync(seedId, ct);

    /// <summary>
    /// YouTube's own lyrics first. When they are missing or unsynced, LRCLIB for synced lyrics. Null means no source has
    /// lyrics; when nothing was found and a source couldn't be asked, this throws, so callers don't cache an outage.
    /// </summary>
    public async Task<Lyrics?> LyricsAsync(Track track, CancellationToken ct = default)
    {
        Exception? failure = null;
        Lyrics? native = null;
        // A timeout surfaces as TaskCanceledException too: only the caller's own cancellation propagates.
        try { native = await Client.LyricsAsync(track.ProviderID, ct).ConfigureAwait(false); }
        catch (Exception e) when (!ct.IsCancellationRequested) { failure = e; }
        if (native is { IsSynced: true }) return native;
        if (track.Artists.FirstOrDefault()?.Name is { } artist)
        {
            try
            {
                var fallback = await _lrcLib.LyricsAsync(track.Title, artist, track.Album?.Title, track.Duration, ct).ConfigureAwait(false);
                if (fallback != null && (fallback.IsSynced || native == null)) return fallback;
            }
            catch (Exception e) when (!ct.IsCancellationRequested)
            {
                failure ??= e;
            }
        }
        if (native == null && failure != null) throw failure;
        return native;
    }

    // MARK: Diagnostics

    /// <summary>Sends a raw WEB_REMIX request and returns the response as indented JSON. For <c>medley-probe ytm raw</c>.</summary>
    public Task<string> DiagnosticRequestAsync(string endpoint, string bodyJson, CancellationToken ct = default) =>
        Client.RawRequestAsync(endpoint, bodyJson, ct);

    public void Dispose() => Client.Dispose();
}

/// <summary>A sign-in that can't go ahead, with a message for the person (Swift: <c>BrowserLoginError.notSignedIn</c>).</summary>
public sealed class SignInException(string message) : Exception(message);

using System.ComponentModel;
using System.Net.NetworkInformation;
using OpenMusic.Core;
using OpenMusic.Sync.Convex;

namespace OpenMusic.Sync.Account;

/// <summary>Which sync server this device uses: OpenMusic's own, or one URL the listener entered (self-hosted Convex).</summary>
public sealed record SyncServer(Uri Url, bool IsCustom)
{
    /// <summary>A server URL as typed: https (a bare host gets https), or http for this machine only. Null otherwise.</summary>
    public static Uri? Parse(string text)
    {
        var raw = text.Trim();
        if (!raw.Contains("://", StringComparison.Ordinal)) raw = "https://" + raw;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var url) || url.Host.Length == 0) return null;
        if (url.UserInfo.Length > 0 || url.Query.Length > 0 || url.Fragment.Length > 0) return null;
        var host = url.Host.ToLowerInvariant();
        var local = host is "localhost" or "127.0.0.1" or "[::1]" or "::1";
        if (!(url.Scheme == "https" || (url.Scheme == "http" && local))) return null;
        var path = url.AbsolutePath == "/" ? "" : url.AbsolutePath;
        var port = url.IsDefaultPort ? "" : $":{url.Port}";
        return new Uri($"{url.Scheme}://{url.Host}{port}{path}");
    }
}

/// <summary>Where the custom server URL is kept (the Swift apps use UserDefaults key <c>syncServerURL</c>).</summary>
public interface IAccountPreferences
{
    string? CustomServerUrl { get; set; }
}

public sealed class MemoryAccountPreferences : IAccountPreferences
{
    public string? CustomServerUrl { get; set; }
}

/// <summary>A small JSON file next to the app's settings.</summary>
public sealed class FileAccountPreferences(string path) : IAccountPreferences
{
    public string? CustomServerUrl
    {
        get
        {
            try { return File.Exists(path) ? System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path))?.GetValueOrDefault("syncServerURL") : null; }
            catch (Exception) { return null; }
        }
        set
        {
            var dict = new Dictionary<string, string>();
            if (value is not null) dict["syncServerURL"] = value;
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(dict));
        }
    }
}

public abstract record AccountState
{
    /// <summary>Reading the saved sign-in and the server's configuration.</summary>
    public sealed record Loading : AccountState;
    public sealed record SignedOut : AccountState;
    public sealed record SignedIn(ClerkUser User) : AccountState;
}

public enum ServerErrorKind { InvalidUrl, Unreachable, NotOpenMusic }

public sealed class ServerException(ServerErrorKind kind, string? detail = null) : Exception(kind switch
{
    ServerErrorKind.InvalidUrl => "Enter the server's https:// address, for example https://happy-otter-123.convex.cloud.",
    ServerErrorKind.Unreachable => $"Can't reach that server: {detail}",
    _ => $"That address doesn't run the {ProductInfo.Name} sync server.",
})
{
    public ServerErrorKind Kind { get; } = kind;
}

/// <summary>
/// The signed-in account on this device (port of <c>AccountService.swift</c>): the server choice, its Clerk app (from the
/// server's public <c>config:get</c>) and the Clerk session. After a sign-in the app calls <see cref="StartSyncAsync"/>
/// (or <c>sync.SignInAsync(account.TokenProvider!, user.Id, account.SessionGeneration)</c> on the actor), and signs out
/// with <see cref="SignOutAsync(SyncService)"/>. Runs on the same <see cref="SyncActor"/> as the SyncService.
/// <para>
/// Identity: every operation captures a <see cref="Ticket"/> (server epoch, account epoch, sign-in generation, Clerk
/// instance) on the actor before its first await. A server switch starts a new server epoch; a sign-out or a server switch
/// starts a new account epoch; a sign-in bumps the generation. Every effect checks the parts of the ticket it depends on
/// right before it happens, on the actor: a configuration installs only for the server epoch its load started in, a
/// completed sign-in is shown only if no sign-out or server switch happened since it started and Clerk still holds exactly
/// that session, and a refresh publishes only for the Clerk and session it asked. Stale work is dropped
/// (<see cref="ClerkErrorKind.Stale"/>).
/// </para>
/// </summary>
public sealed class AccountService : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>Clerk ended the shown session by itself, or the saved sign-in was dropped for another Clerk host. See <see cref="EndedSignIn"/>.</summary>
    public event Action? SessionEnded;
    /// <summary>The server's sign-in configuration loaded after a launch that couldn't load it: a saved sign-in can connect now.</summary>
    public event Action? Ready;

    public SyncActor Actor { get; }
    private readonly Uri _hostedUrl;
    private readonly IClerkStateStore _store;
    private readonly IHttpPoster _http;
    private readonly IClerkHttp _clerkHttp;
    private readonly IAccountPreferences _preferences;
    private CancellationTokenSource? _retryTask;
    private int _retryAttempt;
    private (int ServerEpoch, Task Task)? _configurationLoad;
    private bool _watchingNetwork;
    private string? _shownSessionId;
    /// <summary>Bumped by a server switch: configuration loads, retries and Clerk callbacks of the old server stop counting.</summary>
    private int _serverEpoch;
    /// <summary>Bumped by a sign-out and a server switch: sign-ins started before it never show.</summary>
    private int _accountEpoch;

    /// <summary>What an operation was started for, captured on the actor before its first await.</summary>
    internal readonly record struct Ticket(int ServerEpoch, int AccountEpoch, int Generation, ClerkClient? Clerk);

    private Ticket CurrentTicket()
    {
        Actor.AssertCurrent();
        return new Ticket(_serverEpoch, _accountEpoch, SessionGeneration, Clerk);
    }

    public IReadOnlyList<TimeSpan> RetryDelays { get; set; } = [TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(120), TimeSpan.FromSeconds(300)];
    /// <summary>Watch the network while the configuration is missing and try again when it comes back (off in tests).</summary>
    public bool WatchesNetwork { get; set; } = true;

    public AccountService(Uri hostedUrl, IClerkStateStore store, SyncActor actor, IAccountPreferences? preferences = null,
                          IHttpPoster? http = null, IClerkHttp? clerkHttp = null)
    {
        _hostedUrl = hostedUrl;
        _store = store;
        Actor = actor;
        _preferences = preferences ?? new MemoryAccountPreferences();
        _http = http ?? new HttpClientPoster();
        _clerkHttp = clerkHttp ?? new HttpClientClerkHttp();
        _server = CurrentServer();
    }

    private AccountState _state = new AccountState.Loading();
    private SyncServer _server;
    private IReadOnlyList<ClerkOAuthProvider> _socialProviders = [];
    private string? _serverProblem;
    private string? _notice;

    public AccountState State { get => _state; private set { Actor.AssertCurrent(); _state = value; Raise(nameof(State)); Raise(nameof(User)); Raise(nameof(IsSignedIn)); } }
    public SyncServer Server { get => _server; private set { Actor.AssertCurrent(); _server = value; Raise(nameof(Server)); } }
    /// <summary>Social sign-ins the server's Clerk app has on (Google, Apple, …).</summary>
    public IReadOnlyList<ClerkOAuthProvider> SocialProviders { get => _socialProviders; private set { Actor.AssertCurrent(); _socialProviders = value; Raise(nameof(SocialProviders)); } }
    /// <summary>Why signing in isn't possible right now (not set up, or unreachable). OpenMusic tries again by itself while unreachable.</summary>
    public string? ServerProblem { get => _serverProblem; private set { Actor.AssertCurrent(); _serverProblem = value; Raise(nameof(ServerProblem)); } }
    /// <summary>Something the listener should know about their sign-in, shown until they sign in again.</summary>
    public string? Notice { get => _notice; private set { Actor.AssertCurrent(); _notice = value; Raise(nameof(Notice)); } }
    public ClerkUser? User => State is AccountState.SignedIn s ? s.User : null;
    public bool IsSignedIn => User is not null;
    public ClerkClient? Clerk { get; private set; }
    /// <summary>The Convex token source for <see cref="SyncService.SignInAsync"/>, once a Clerk app is known.</summary>
    public IAuthTokenProvider? TokenProvider => Clerk;
    public bool IsReady => Clerk is not null;

    /// <summary>Bumped by every sign-in; a sign-out compares it before and after every await.</summary>
    public int SessionGeneration { get; private set; }
    /// <summary>The sign-in whose session ended last, so the app signs sync out only for it.</summary>
    public SyncSignIn? EndedSignIn { get; private set; }
    /// <summary>The sign-in shown now, for SyncService.SignInAsync (null when signed out).</summary>
    public SyncSignIn? CurrentSignIn => Actor.Read(() => User is { } user ? new SyncSignIn(user.Id, SessionGeneration) : (SyncSignIn?)null);

    private void Raise(string name)
    {
        Actor.AssertCurrent();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    private SyncServer CurrentServer() =>
        _preferences.CustomServerUrl is { } text && SyncServer.Parse(text) is { } url ? new SyncServer(url, true) : new SyncServer(_hostedUrl, false);

    // MARK: Launch

    /// <summary>Reads the server's sign-in configuration and the saved session. A saved session counts at once (offline launches stay signed in).</summary>
    public async Task LoadAsync()
    {
        await Actor.Switch();
        var saved = _store.Load();
        if (Clerk is null && State is AccountState.Loading && saved?.User is { } user && saved.SessionId is { } id) Show(new ClerkSession(id, user));
        await LoadConfiguration();
    }

    /// <summary>Tries the server's configuration again now, if it hasn't loaded (Try Again, back online, back in the foreground).</summary>
    public async Task RetryAsync()
    {
        await Actor.Switch();
        if (Clerk is not null) return;
        _retryTask?.Cancel();
        _retryTask = null;
        await LoadConfiguration();
    }

    /// <summary>
    /// Loads the configuration of the server chosen now, once: a second caller waits for the load already running for this
    /// server. The load is bound to the server epoch it started in; after a server switch its answer installs nothing.
    /// </summary>
    private Task LoadConfiguration()
    {
        Actor.AssertCurrent();
        if (Clerk is not null) return Task.CompletedTask;
        if (_configurationLoad is { } running && running.ServerEpoch == _serverEpoch && !running.Task.IsCompleted) return running.Task;
        var task = Load(_serverEpoch, Server.Url);
        _configurationLoad = (_serverEpoch, task);
        return task;

        async Task Load(int epoch, Uri server)
        {
            string key;
            try
            {
                key = await FetchPublishableKeyAsync(server, _http);
            }
            catch (Exception e)
            {
                await Actor.Switch();
                Problem(epoch, e);
                return;
            }
            await Actor.Switch();
            // Installed only for the server it was loaded for, and only once. Checked before the client is made: making
            // one reads and may clear the saved sign-in, which belongs to the server chosen now.
            if (epoch != _serverEpoch || Clerk is not null) return;
            ClerkClient clerk;
            try { clerk = MakeClerk(key, epoch); }
            catch (Exception e)
            {
                Problem(epoch, e);
                return;
            }
            _retryTask?.Cancel();
            _retryTask = null;
            _retryAttempt = 0;
            StopWatchingNetwork();
            ServerProblem = null;
            Clerk = clerk;
            if (clerk.DiscardedStateForOtherOrigin)
            {
                Notice = ClerkException.OriginChanged(clerk.FrontendApi.Host).Message;
                if (IsSignedIn) EndShownSignIn(); else ShowSignedOut();
            }
            else if (State is AccountState.SignedIn) { }
            else if (clerk.SavedSession is { } saved) Show(saved);
            else ShowSignedOut();
            Ready?.Invoke();
            _ = Actor.RunAsync(RefreshAsync);
        }
    }

    private void Problem(int epoch, Exception e)
    {
        Actor.AssertCurrent();
        if (epoch != _serverEpoch) return;   // the old server's problem isn't this one's
        ServerProblem = e.Message;
        if (State is AccountState.Loading) ShowSignedOut();
        if (e is ServerException { Kind: ServerErrorKind.Unreachable })
        {
            ScheduleRetry();
            WatchNetwork();
        }
    }

    private void WatchNetwork()
    {
        if (!WatchesNetwork || _watchingNetwork) return;
        _watchingNetwork = true;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
    }

    private void StopWatchingNetwork()
    {
        if (!_watchingNetwork) return;
        _watchingNetwork = false;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
    }

    private void OnNetworkChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable) _ = RetryAsync();
    }

    private void ScheduleRetry()
    {
        Actor.AssertCurrent();
        if (_retryTask is not null || RetryDelays.Count == 0) return;
        var delay = RetryDelays[Math.Min(_retryAttempt, RetryDelays.Count - 1)];
        _retryAttempt++;
        var cts = new CancellationTokenSource();
        _retryTask = cts;
        var epoch = _serverEpoch;
        _ = Task.Delay(delay, cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            Actor.Post(() =>
            {
                if (cts.IsCancellationRequested || epoch != _serverEpoch) return;
                _retryTask = null;
                _ = LoadConfiguration();
            });
        }, TaskScheduler.Default);
    }

    /// <summary>Asks Clerk whether the session still stands, and which social sign-ins are on. Only the session shown when it started is refreshed.</summary>
    public async Task RefreshAsync()
    {
        await Actor.Switch();
        if (Clerk is not { } clerk) return;
        var ticket = CurrentTicket();
        var asked = _shownSessionId;
        try
        {
            var providers = await clerk.SocialProvidersAsync();
            await Actor.Switch();
            if (ticket.ServerEpoch == _serverEpoch && ReferenceEquals(Clerk, clerk)) SocialProviders = providers;
        }
        catch (Exception) { }
        try
        {
            // Null: the session ended, which the client announces (SetOnSessionEnded) naming it; acted on there.
            if (await clerk.RestoreAsync() is not { } restored) return;
            await Actor.Switch();
            if (!IsCurrent(ticket) || asked is null || _shownSessionId != asked || restored.Id != asked) return;
            State = new AccountState.SignedIn(restored.User);
        }
        catch (Exception) { }   // offline: keep the saved sign-in
    }

    private bool IsCurrent(Ticket ticket)
    {
        Actor.AssertCurrent();
        return ticket.ServerEpoch == _serverEpoch && ticket.AccountEpoch == _accountEpoch && ticket.Generation == SessionGeneration && ReferenceEquals(ticket.Clerk, Clerk);
    }

    private ClerkClient MakeClerk(string key, int epoch)
    {
        Actor.AssertCurrent();
        var clerk = new ClerkClient(key, _store, _clerkHttp);
        // Bound to this Clerk instance: an end announced by an old server's Clerk changes nothing here.
        clerk.SetOnSessionEnded(ended => Actor.Post(() =>
        {
            if (epoch == _serverEpoch && ReferenceEquals(Clerk, clerk)) OnSessionEnded(ended);
        }));
        return clerk;
    }

    private void Show(ClerkSession session)
    {
        _shownSessionId = session.Id;
        State = new AccountState.SignedIn(session.User);
    }

    private void ShowSignedOut()
    {
        _shownSessionId = null;
        State = new AccountState.SignedOut();
    }

    /// <summary>Clerk ended <paramref name="ended"/>: acts only when that is the sign-in shown now.</summary>
    internal void OnSessionEnded(ClerkSessionEnd ended)
    {
        Actor.AssertCurrent();
        if (_shownSessionId is not { } shown || ended.SessionId != shown || (ended.UserId is not null && ended.UserId != User?.Id)) return;
        if (ended.NotAdopted is { } other) Notice = ClerkException.OtherSessionNotAdopted(other.DisplayName).Message;
        EndShownSignIn();
    }

    private void EndShownSignIn()
    {
        if (User is not { } user) return;
        EndedSignIn = new SyncSignIn(user.Id, SessionGeneration);
        ShowSignedOut();
        SessionEnded?.Invoke();
    }

    // MARK: Signing in

    /// <summary>
    /// The Clerk app of the server chosen when <paramref name="entry"/> was captured, loading it if needed. Throws Stale when
    /// the server changed or the account signed out meanwhile.
    /// </summary>
    private async Task<(ClerkClient Clerk, Ticket Ticket)> RequireClerk(Ticket entry)
    {
        if (Clerk is null) await LoadConfiguration();
        await Actor.Switch();
        if (entry.ServerEpoch != _serverEpoch || entry.AccountEpoch != _accountEpoch) throw ClerkException.Stale();
        var clerk = Clerk ?? throw new ServerException(ServerErrorKind.Unreachable, ServerProblem ?? "no answer");
        return (clerk, entry with { Clerk = clerk });
    }

    public async Task<ClerkEmailChallenge> StartEmailAsync(string email)
    {
        await Actor.Switch();
        var (clerk, _) = await RequireClerk(CurrentTicket());
        return await clerk.StartEmailAsync(email);
    }

    /// <summary>Completes an email sign-in. It shows only if no sign-out or server switch happened since it was called (else Stale).</summary>
    public async Task<ClerkUser> VerifyEmailAsync(ClerkEmailChallenge challenge, string code)
    {
        await Actor.Switch();
        var (clerk, ticket) = await RequireClerk(CurrentTicket());
        var session = await clerk.VerifyEmailAsync(challenge, code);
        await Actor.Switch();
        AdoptSignIn(session, ticket);
        return session.User;
    }

    public async Task<ClerkOAuthStart> StartOAuthAsync(ClerkOAuthProvider provider)
    {
        await Actor.Switch();
        var (clerk, _) = await RequireClerk(CurrentTicket());
        return await clerk.StartOAuthAsync(provider);
    }

    /// <summary>Completes a social sign-in. It shows only if no sign-out or server switch happened since it was called (else Stale).</summary>
    public async Task<ClerkUser> CompleteOAuthAsync(ClerkOAuthStart start, Uri callback)
    {
        await Actor.Switch();
        var (clerk, ticket) = await RequireClerk(CurrentTicket());
        var session = await clerk.CompleteOAuthAsync(start, callback);
        await Actor.Switch();
        AdoptSignIn(session, ticket);
        return session.User;
    }

    /// <summary>
    /// Shows a session Clerk adopted, if the ticket is still current (same server, no sign-out since) and Clerk still holds
    /// exactly this session. Another sign-in finishing since doesn't make it stale: Clerk's own generation decides which of
    /// two sign-ins wins, and whatever Clerk holds is what shows.
    /// </summary>
    private void AdoptSignIn(ClerkSession session, Ticket ticket)
    {
        Actor.AssertCurrent();
        var clerk = ticket.Clerk!;
        if (ticket.ServerEpoch != _serverEpoch || ticket.AccountEpoch != _accountEpoch || !ReferenceEquals(Clerk, clerk) || clerk.CurrentSessionId != session.Id)
        {
            // Never left half done: a session Clerk kept for a sign-in that doesn't show is ended too.
            if (clerk.CurrentSessionId == session.Id) _ = clerk.BeginSignOut(session.Id);
            throw ClerkException.Stale();
        }
        SessionGeneration++;
        Show(session);
        Notice = null;
    }

    /// <summary>
    /// Signs <paramref name="sync"/> in for the sign-in shown now, decided and started in one step on the actor: a sign-out
    /// that comes after it signs that sync sign-in out, and one that came before leaves nothing to sign in (Stale).
    /// </summary>
    public async Task StartSyncAsync(SyncService sync)
    {
        await Actor.Switch();
        if (!ReferenceEquals(sync.Actor, Actor)) throw new InvalidOperationException("The account and sync must share one actor.");
        if (User is not { } user || Clerk is not { } clerk) throw ClerkException.Stale();
        // A sync service of another server than the one signed in to: nothing of this sign-in goes there.
        if (sync.Client.DeploymentUrl != Server.Url) throw ClerkException.Stale();
        // SignInAsync switches to the actor at once (already on it) and records the request before its first await.
        await sync.SignInAsync(clerk, user.Id, SessionGeneration);
    }

    /// <summary>Ends the Clerk session. A sign-in started before it never shows; one started after it stays.</summary>
    public async Task SignOutAsync()
    {
        await Actor.Switch();
        _accountEpoch++;
        Task removal;
        if (Clerk is { } clerk) removal = clerk.BeginSignOut();   // forgotten here before this returns
        else
        {
            _store.Save(null);
            removal = Task.CompletedTask;
        }
        ShowSignedOut();
        await removal;
    }

    /// <summary>Which Clerk session (and user) is signed in now, and which sign-in it came from.</summary>
    public sealed record Session(string? SessionId, string? UserId, int Generation)
    {
        public SyncSignIn? SignIn => UserId is { } id ? new SyncSignIn(id, Generation) : null;
    }

    /// <summary>
    /// One coherent snapshot of the sign-in: the user and the generation read together, before anything is awaited, and the
    /// session id after. A sign-in that finishes during that await makes the snapshot stale (its session id dropped).
    /// </summary>
    public async Task<Session> CurrentSessionAsync()
    {
        await Actor.Switch();
        var generation = SessionGeneration;
        var userId = User?.Id;
        if (WillReadClerkSession is { } hook) await hook();
        await Actor.Switch();
        var id = Clerk?.CurrentSessionId;
        return new Session(generation == SessionGeneration ? id : null, userId, generation);
    }

    /// <summary>Tests only: runs inside CurrentSessionAsync after the user and generation are captured.</summary>
    internal Func<Task>? WillReadClerkSession { get; set; }

    public bool IsCurrent(Session session) => Actor.Read(() => session.Generation == SessionGeneration);

    /// <summary>Ends the Clerk session only if it is still <paramref name="session"/>. The check and the sign-out happen in one step.</summary>
    public async Task<bool> SignOutAsync(Session session)
    {
        await Actor.Switch();
        if (SessionGeneration != session.Generation) return false;
        Task removal;
        if (Clerk is { } clerk)
        {
            if (clerk.BeginSignOut(session.SessionId) is not { } r) return false;
            removal = r;
        }
        else
        {
            if (User?.Id != session.UserId) return false;
            _store.Save(null);
            removal = Task.CompletedTask;
        }
        _accountEpoch++;
        ShowSignedOut();
        await removal;
        return true;
    }

    /// <summary>
    /// Settings › Account › Sign Out: removes this device from sync, then ends the Clerk session it started for. A sign-in
    /// that happened meanwhile keeps its session and its sync sign-in.
    /// </summary>
    public async Task SignOutAsync(SyncService sync)
    {
        var session = await CurrentSessionAsync();
        await Actor.Switch();
        if (!IsCurrent(session)) return;
        await sync.SignOutAsync(session.SignIn);
        await SignOutAsync(session);
    }

    // MARK: Server

    /// <summary>Checks that <paramref name="text"/> is an OpenMusic server with sign-in set up. Returns the URL to save. Changes nothing.</summary>
    public async Task<Uri> CheckServerAsync(string text)
    {
        await Actor.Switch();
        var url = SyncServer.Parse(text) ?? throw new ServerException(ServerErrorKind.InvalidUrl);
        var key = await FetchPublishableKeyAsync(url, _http);
        if (ClerkPublishableKey.FrontendApi(key) is null) throw ClerkException.NotConfigured();
        return url;
    }

    /// <summary>
    /// Switches servers (null: the hosted one). The caller signs sync out first. Starts a new server epoch: the old server's
    /// configuration load, retries and sign-ins in flight install nothing.
    /// </summary>
    public async Task SetServerAsync(Uri? url)
    {
        await Actor.Switch();
        // One step, before anything is awaited: the old server's Clerk is retired (its session forgotten and ended, and it
        // never writes the store again), so no sign-in can finish through it while its removal is on its way.
        _serverEpoch++;
        _accountEpoch++;
        _configurationLoad = null;
        Task removal;
        if (Clerk is { } old) removal = old.Retire();
        else
        {
            _store.Save(null);
            removal = Task.CompletedTask;
        }
        _preferences.CustomServerUrl = url is not null && url != _hostedUrl ? url.AbsoluteUri : null;
        Server = CurrentServer();
        Clerk = null;
        _retryTask?.Cancel();
        _retryTask = null;
        _retryAttempt = 0;
        StopWatchingNetwork();
        Notice = null;
        ServerProblem = null;
        SocialProviders = [];
        _shownSessionId = null;
        State = new AccountState.Loading();
        await removal;
        await LoadAsync();
    }

    /// <summary><c>config:get</c> over HTTP: the server's Clerk publishable key. Needs no sign-in.</summary>
    public static async Task<string> FetchPublishableKeyAsync(Uri server, IHttpPoster http)
    {
        var body = ConvexValue.Object(("path", ConvexValue.String("config:get")), ("format", ConvexValue.String("convex_encoded_json")),
                                      ("args", ConvexValue.Array(ConvexValue.Object()))).JsonBytes();
        (byte[] Body, int Status) response;
        try
        {
            response = await http.PostAsync(new Uri(server, "api/query"), body,
                new Dictionary<string, string> { ["Content-Type"] = "application/json", ["Convex-Client"] = OpenMusicSyncInfo.ClientHeader });
        }
        catch (Exception e) { throw new ServerException(ServerErrorKind.Unreachable, e.Message); }
        if (response.Status is not (>= 200 and < 300 or 560)) throw new ServerException(ServerErrorKind.NotOpenMusic);
        ConvexValue parsed;
        try { parsed = ConvexValue.Parse(response.Body); } catch (Exception) { throw new ServerException(ServerErrorKind.NotOpenMusic); }
        if (parsed["status"]?.StringValue != "success" || parsed["value"]?["auth"] is not { } auth) throw new ServerException(ServerErrorKind.NotOpenMusic);
        if (auth["kind"]?.StringValue != "clerk" || auth["publishableKey"]?.StringValue is not { } key) throw ClerkException.NotConfigured();
        return key;
    }
}

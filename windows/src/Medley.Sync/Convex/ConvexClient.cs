using System.Threading.Channels;

namespace Medley.Sync.Convex;

/// <summary>The identity a call is made for, as <see cref="ConvexClient.SetAuthAsync"/> returned it.</summary>
public readonly record struct AuthScope(int Value);

/// <summary>A value with the local times its request left and its answer arrived (for clock offset estimates).</summary>
public sealed record Timed<T>(T Value, DateTimeOffset SentAt, DateTimeOffset ReceivedAt);

public enum ConvexErrorKind { Function, Transport, Http, Decoding, Stopped, AuthChanged }

/// <summary>What a Convex call can fail with. Mirrors <c>ConvexClientError</c>.</summary>
public sealed class ConvexClientException : Exception
{
    public ConvexErrorKind Kind { get; }
    /// <summary>The <c>ConvexError</c> payload, when the function threw one.</summary>
    public ConvexValue? ErrorData { get; }
    public int Status { get; }
    public string Detail { get; }

    /// <param name="detail">Text from the server (a function's error, an HTTP body) is cleaned first: Convex echoes the
    /// call's arguments, device token included, below its validation errors (<see cref="ServerText"/>).</param>
    private ConvexClientException(ConvexErrorKind kind, string detail, ConvexValue? data = null, int status = 0)
        : base(Describe(kind, ServerText.Clean(detail), data, status))
    {
        Kind = kind; Detail = ServerText.Clean(detail); ErrorData = data; Status = status;
    }

    public static ConvexClientException Function(string message, ConvexValue? data) => new(ConvexErrorKind.Function, message, data);
    public static ConvexClientException Transport(string why) => new(ConvexErrorKind.Transport, why);
    public static ConvexClientException Http(int status, string body) => new(ConvexErrorKind.Http, body, status: status);
    public static ConvexClientException Decoding(string why) => new(ConvexErrorKind.Decoding, why);
    public static ConvexClientException Stopped() => new(ConvexErrorKind.Stopped, "");
    public static ConvexClientException AuthChanged() => new(ConvexErrorKind.AuthChanged, "");

    /// <summary><c>data.code</c> of a <c>ConvexError({ code, message })</c> thrown by the backend.</summary>
    public string? Code => Kind == ConvexErrorKind.Function ? ErrorData?["code"]?.StringValue : null;

    private static string Describe(ConvexErrorKind kind, string detail, ConvexValue? data, int status) => kind switch
    {
        ConvexErrorKind.Function => data?["message"]?.StringValue is { } message ? ServerText.Clean(message) : detail,
        ConvexErrorKind.Transport => $"Can't reach the sync server: {detail}",
        ConvexErrorKind.Http => $"Sync server error {status}.",
        ConvexErrorKind.Decoding => $"Unexpected sync response: {detail}",
        ConvexErrorKind.Stopped => "Sync is stopped.",
        _ => "The account changed before this was sent.",
    };
}

public enum ConnectionPhase { Idle, Connecting, Connected, WaitingToReconnect, Stopped }

public readonly record struct ConnectionState(ConnectionPhase Phase, int Attempt = 0)
{
    public static readonly ConnectionState Idle = new(ConnectionPhase.Idle);
    public static readonly ConnectionState Connecting = new(ConnectionPhase.Connecting);
    public static readonly ConnectionState Connected = new(ConnectionPhase.Connected);
    public static readonly ConnectionState Stopped = new(ConnectionPhase.Stopped);
}

/// <summary>Connection state, whether calls go over HTTP, sockets opened so far, and the identity's state.</summary>
public sealed record ConvexStatus(ConnectionState State, bool HttpFallback, int Connections, ConvexAuthState Auth);

/// <summary>One live query result: a value or the function's error.</summary>
public sealed record ConvexQueryResult(ConvexValue? Value, ConvexClientException? Error)
{
    public ConvexValue Get() => Error is null ? Value! : throw Error;
}

/// <summary>A live query. Results arrive on <see cref="Results"/> (newest wins); dispose to unsubscribe.</summary>
public sealed class ConvexSubscription : IDisposable
{
    private readonly Action _dispose;
    private int _disposed;
    internal ConvexSubscription(ChannelReader<ConvexQueryResult> results, Action dispose) { Results = results; _dispose = dispose; }
    public ChannelReader<ConvexQueryResult> Results { get; }
    public void Dispose() { if (Interlocked.Exchange(ref _disposed, 1) == 0) _dispose(); }
}

public sealed class ConvexClientOptions
{
    public TimeSpan InitialBackoff { get; set; } = TimeSpan.FromSeconds(1);
    public TimeSpan MaxBackoff { get; set; } = TimeSpan.FromSeconds(16);
    public TimeSpan InactivityTimeout { get; set; } = TimeSpan.FromSeconds(60);
    public TimeSpan PollInterval { get; set; } = TimeSpan.FromSeconds(15);
    public int FallbackAfterFailures { get; set; } = 3;
    public bool Jitter { get; set; } = true;
    /// <summary>A mutation with no answer after this long fails with a transport error (and is not replayed later).</summary>
    public TimeSpan MutationTimeout { get; set; } = TimeSpan.FromSeconds(30);
    /// <summary>How long to wait before asking the token provider again after it couldn't answer (offline).</summary>
    public TimeSpan AuthRetryDelay { get; set; } = TimeSpan.FromSeconds(5);
}

/// <summary>
/// A small Convex client speaking the WebSocket sync protocol exactly as <c>ConvexClient.swift</c> does:
/// <list type="bullet">
/// <item>Query subscriptions; mutations resolve once the server's transitions reach their commit timestamp (read your writes).</item>
/// <item>Reconnects with jittered exponential backoff (1 s doubling to 16 s), replaying the query set and unanswered
/// mutations on the new socket. 60 s without a server message counts as a dead socket.</item>
/// <item>After 3 failed connection attempts in a row it also serves queries over HTTP (a slow poll, only while
/// <see cref="SetForeground"/> is true) and mutations over <c>POST /api/mutation</c>. Mutations the socket sent but never
/// answered are retried over HTTP, so the backend functions they call are idempotent.</item>
/// <item>Every mutation has one deadline whichever transport carries it; <see cref="Stop"/> fails it.</item>
/// <item>Every call belongs to the identity it was made under; a call goes out only with a token of its own identity
/// (the unverified <c>sub</c> is a routing guard, Convex verifies the token).</item>
/// </list>
/// All state is guarded by one lock, and every await happens outside it with an epoch check after, which gives the
/// same semantics as the Swift actor's reentrancy.
/// </summary>
public sealed class ConvexClient
{
    public Uri DeploymentUrl { get; }
    /// <summary>The npm client version whose protocol this client speaks.</summary>
    public const string ProtocolVersion = "1.49.0";

    private readonly IWebSocketTransport _transport;
    private readonly IHttpPoster _http;
    private readonly ConvexClientOptions _options;
    private readonly string _sessionId = Guid.NewGuid().ToString().ToLowerInvariant();
    private readonly object _gate = new();

    // Connection
    private IWebSocketConnection? _connection;
    private int _generation;
    private bool _openedThisAttempt;
    private ConnectionState _state = ConnectionState.Idle;
    private bool _httpFallback;
    private bool _isForeground = true;
    private int _connectionCount;
    private string? _lastCloseReason = "InitialConnect";
    private int _retries;
    private int _consecutiveFailures;
    private double? _blockedUntil;
    private CancellationTokenSource? _reconnectTimer, _inactivityTimer, _pollTask, _authRefreshTimer;
    private readonly Dictionary<int, Channel<ConvexStatus>> _statusObservers = new();

    // Authentication
    private IAuthTokenProvider? _authProvider;
    private AuthToken? _authToken;
    private ConvexAuthState _authState = new ConvexAuthState.None();
    private int _identityVersion;
    private int _authRefusals;
    private int _authEpoch;
    private int _authScope;
    private string? _authIdentity;
    private bool _identityPending;
    private string? _socketToken;
    private const int MaxAuthRefusals = 2;

    // Queries
    private sealed class LocalQuery(string path, ConvexValue args, Action<ConvexQueryResult> deliver, int? scope)
    {
        public string Path { get; } = path;
        public ConvexValue Args { get; } = args;
        public string? Journal { get; set; }
        public ConvexValue? LastDelivered { get; set; }
        public Action<ConvexQueryResult> Deliver { get; } = deliver;
        /// <summary>The identity scope the query was made for, or null for one that follows whoever is signed in.</summary>
        public int? Scope { get; } = scope;
    }

    /// <summary>
    /// Hands a result to a query, under the lock: one made for an identity that is no longer current gets AuthChanged
    /// instead, never a value computed for the next identity.
    /// </summary>
    private void Deliver(LocalQuery query, ConvexQueryResult result)
    {
        AssertLocked();
        query.Deliver(query.Scope is { } scope && scope != _authScope ? new ConvexQueryResult(null, ConvexClientException.AuthChanged()) : result);
    }

    /// <summary>Debug builds: client state changes only under the lock.</summary>
    [System.Diagnostics.Conditional("DEBUG")]
    private void AssertLocked()
    {
        if (!Monitor.IsEntered(_gate)) throw new InvalidOperationException("Convex client state changed outside its lock");
    }
    private readonly Dictionary<int, LocalQuery> _queries = new();
    private int _ids;
    private int _querySetVersion;
    private StateVersion _remoteVersion = StateVersion.Initial;
    private ConvexTimestamp? _maxObservedTimestamp;
    private (string Id, int Total, List<string> Parts)? _chunks;

    // Requests
    private enum RequestStatus { NotSent, Requested, Completed, Http }
    private sealed class PendingRequest
    {
        public required string Path;
        public required ConvexValue Args;
        public required string Message;
        public required bool IsAction;
        public RequestStatus Status;
        public ConvexTimestamp CompletedTs;
        public ConvexValue? CompletedValue;
        public DateTimeOffset CompletedAt;
        public DateTimeOffset SentAt;
        public required TaskCompletionSource<Timed<ConvexValue>> Completion;
        public CancellationTokenSource? Timeout;
        public CancellationTokenSource? HttpCancel;
        public CancellationTokenRegistration Registration;
        public required int Scope;

        public void CancelTasks()
        {
            Timeout?.Cancel();
            HttpCancel?.Cancel();
            Registration.Unregister();
        }
    }
    private readonly SortedDictionary<int, PendingRequest> _requests = new();
    private int _nextRequestId;
    private int _socketEpoch;

    public ConvexClient(Uri deploymentUrl, IWebSocketTransport? transport = null, IHttpPoster? http = null, ConvexClientOptions? options = null)
    {
        DeploymentUrl = deploymentUrl;
        _transport = transport ?? new ClientWebSocketTransport();
        _http = http ?? new HttpClientPoster();
        _options = options ?? new ConvexClientOptions();
    }

    /// <summary><c>wss://&lt;deployment&gt;/api/&lt;npm version&gt;/sync</c>, as the npm client builds it.</summary>
    public Uri SyncUrl
    {
        get
        {
            var b = new UriBuilder(DeploymentUrl) { Scheme = DeploymentUrl.Scheme == "http" ? "ws" : "wss", Path = $"/api/{ProtocolVersion}/sync" };
            if (DeploymentUrl.IsDefaultPort) b.Port = -1;
            return b.Uri;
        }
    }

    // MARK: Lifecycle

    public void Start()
    {
        lock (_gate)
        {
            if (_state.Phase is not (ConnectionPhase.Idle or ConnectionPhase.Stopped)) return;
            _state = ConnectionState.Connecting;
            OpenSocket();
        }
    }

    /// <summary>Closes the socket and stops reconnecting. Pending calls fail with Stopped.</summary>
    public void Stop()
    {
        lock (_gate)
        {
            _state = ConnectionState.Stopped;
            _generation++;
            _connection?.Close();
            _connection = null;
            foreach (var t in new[] { _reconnectTimer, _inactivityTimer, _pollTask, _authRefreshTimer }) t?.Cancel();
            _authRefreshTimer = null;
            _pollTask = null;
            _httpFallback = false;
            foreach (var request in _requests.Values)
            {
                request.CancelTasks();
                request.Completion.TrySetException(ConvexClientException.Stopped());
            }
            _requests.Clear();
            PublishStatus();
        }
    }

    /// <summary>
    /// Closes the socket and stops reconnecting (the app is in the background and not playing), keeping the query set
    /// and unanswered mutations. <see cref="Start"/> reconnects and replays both.
    /// </summary>
    public void Suspend()
    {
        lock (_gate)
        {
            if (_state.Phase is ConnectionPhase.Stopped or ConnectionPhase.Idle) return;
            _generation++;
            _connection?.Close();
            _connection = null;
            foreach (var t in new[] { _reconnectTimer, _inactivityTimer, _pollTask }) t?.Cancel();
            _pollTask = null;
            _httpFallback = false;
            _consecutiveFailures = 0;
            _retries = 0;
            _lastCloseReason = "Suspended";
            SetState(ConnectionState.Idle);
            PublishStatus();
        }
    }

    /// <summary>Gates the HTTP fallback poll: it only runs while this is true (in the foreground, or playing).</summary>
    public void SetForeground(bool foreground)
    {
        lock (_gate)
        {
            _isForeground = foreground;
            if (foreground) UpdatePolling(pollNow: true);
            else { _pollTask?.Cancel(); _pollTask = null; }
        }
    }

    /// <summary>Reconnects at once if waiting on a backoff. With <paramref name="force"/>, a connected socket is replaced too.</summary>
    public void ReconnectNow(bool force = false)
    {
        lock (_gate)
        {
            if (force && _state.Phase == ConnectionPhase.Connected) Restart("Reconnect");
            if (_state.Phase != ConnectionPhase.WaitingToReconnect) return;
            _reconnectTimer?.Cancel();
            AttemptReconnect();
        }
    }

    /// <summary>Testing aid: drops the socket as a network loss would and refuses to reconnect (socket and HTTP) for a while.</summary>
    public void SimulateNetworkLoss(TimeSpan duration)
    {
        lock (_gate)
        {
            _blockedUntil = MonoClock.NowMs + duration.TotalMilliseconds;
            _connection?.Close();
        }
    }

    public ConvexStatus Status { get { lock (_gate) return CurrentStatus(); } }

    private ConvexStatus CurrentStatus() => new(_state, _httpFallback, _connectionCount, _authState);

    /// <summary>A stream of status changes, starting with the current one (newest 8 kept).</summary>
    public ChannelReader<ConvexStatus> StatusUpdates(CancellationToken cancellationToken = default)
    {
        var channel = Channel.CreateBounded<ConvexStatus>(new BoundedChannelOptions(8) { FullMode = BoundedChannelFullMode.DropOldest });
        int id;
        lock (_gate)
        {
            id = ++_ids;
            _statusObservers[id] = channel;
            channel.Writer.TryWrite(CurrentStatus());
        }
        cancellationToken.Register(() =>
        {
            lock (_gate) _statusObservers.Remove(id);
            channel.Writer.TryComplete();
        });
        return channel.Reader;
    }

    private void PublishStatus()
    {
        var s = CurrentStatus();
        foreach (var c in _statusObservers.Values) c.Writer.TryWrite(s);
    }

    private void SetState(ConnectionState state)
    {
        if (state == _state) return;
        _state = state;
        PublishStatus();
    }

    // MARK: Timers

    /// <summary>Runs <paramref name="fire"/> under the lock after <paramref name="delay"/>, unless cancelled first.</summary>
    private CancellationTokenSource After(TimeSpan delay, Action fire)
    {
        var cts = new CancellationTokenSource();
        _ = Task.Delay(delay, cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            lock (_gate) { if (!cts.IsCancellationRequested) fire(); }
        }, TaskScheduler.Default);
        return cts;
    }

    /// <summary>Runs async <paramref name="fire"/> (outside the lock) after <paramref name="delay"/>, unless cancelled first.</summary>
    private CancellationTokenSource AfterAsync(TimeSpan delay, Func<Task> fire)
    {
        var cts = new CancellationTokenSource();
        _ = Task.Delay(delay, cts.Token).ContinueWith(async t =>
        {
            if (t.IsCanceled || cts.IsCancellationRequested) return;
            await fire().ConfigureAwait(false);
        }, TaskScheduler.Default).Unwrap();
        return cts;
    }

    // MARK: Socket

    private bool IsBlocked
    {
        get
        {
            if (_blockedUntil is not { } until) return false;
            if (MonoClock.NowMs >= until) { _blockedUntil = null; return false; }
            return true;
        }
    }

    private void OpenSocket()
    {
        _generation++;
        var gen = _generation;
        _openedThisAttempt = false;
        SetState(ConnectionState.Connecting);
        // A token that expired while the socket was closed is replaced before the socket opens.
        if (_authProvider is { } provider && (_authToken is null || _authToken.NeedsRefresh()) && !IsBlocked)
        {
            var epoch = _authEpoch;
            _ = Task.Run(async () =>
            {
                TokenFetch token;
                try { token = TokenFetch.Fetched(await provider.GetTokenAsync(true).ConfigureAwait(false)); }
                catch { token = TokenFetch.Unavailable; }
                lock (_gate) OpenAfterRefresh(token, epoch, gen);
            });
            return;
        }
        ConnectSocket(gen);
    }

    private void OpenAfterRefresh(TokenFetch token, int epoch, int gen)
    {
        if (gen != _generation || _state.Phase != ConnectionPhase.Connecting) return;
        if (epoch == _authEpoch)
        {
            if (!token.IsUnavailable)
            {
                if (token.Value is { } value) Accept(value);
                else SignedOutByProvider();
            }
        }
        ConnectSocket(gen);
    }

    private void ConnectSocket(int gen)
    {
        if (IsBlocked)
        {
            _ = Task.Run(() => { lock (_gate) Handle(new WebSocketEvent.Closed("network unavailable"), gen); });
            return;
        }
        var (conn, events) = _transport.Connect(SyncUrl);
        _connection = conn;
        _ = Task.Run(async () =>
        {
            try
            {
                await foreach (var ev in events.ReadAllAsync().ConfigureAwait(false))
                {
                    lock (_gate) Handle(ev, gen);
                }
            }
            catch (Exception) { /* channel faulted: the generation moves on with the next socket */ }
        });
    }

    private void Handle(WebSocketEvent ev, int gen)
    {
        if (gen != _generation || _state.Phase == ConnectionPhase.Stopped) return;
        switch (ev)
        {
            case WebSocketEvent.Opened: DidOpen(); break;
            case WebSocketEvent.Message m:
                ResetInactivity();
                try { HandleMessage(ServerMessage.Parse(m.Text)); }
                catch (Exception e) { Restart($"protocol error: {e.Message}"); }
                break;
            case WebSocketEvent.Closed c: DidClose(c.Reason); break;
        }
    }

    private void DidOpen()
    {
        _openedThisAttempt = true;
        _socketEpoch++;
        _consecutiveFailures = 0;
        _connection?.Send(ClientMessage.Connect(_sessionId, _connectionCount, _lastCloseReason, _maxObservedTimestamp,
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        _connectionCount++;
        _lastCloseReason = null;

        // The identity comes first, so the queries and replayed mutations below run as the signed-in user.
        if (_authToken is { } token)
        {
            _connection?.Send(ClientMessage.Authenticate(token.Value, 0));
            _identityVersion = 1;
            _socketToken = token.Value;
            SetAuthState(new ConvexAuthState.Pending());
            ScheduleAuthRefresh();
        }
        else
        {
            _identityVersion = 0;
            _socketToken = null;
        }

        // A fresh socket starts from an empty query set: add everything again.
        _remoteVersion = StateVersion.Initial;
        _querySetVersion = 1;
        _chunks = null;
        var adds = _queries.OrderBy(q => q.Key).Select(q => new ClientMessage.Add(q.Key, q.Value.Path, q.Value.Args, q.Value.Journal)).ToList();
        _connection?.Send(ClientMessage.ModifyQuerySet(0, 1, adds, []));

        // Replay unanswered and unconfirmed mutations; the server dedupes them by session and request id. One already
        // in flight over HTTP finishes there. An action already sent can't be replayed (it isn't idempotent): it fails.
        foreach (var id in _requests.Keys.ToList())
        {
            if (!_requests.TryGetValue(id, out var request)) continue;
            if (request.Status == RequestStatus.Http) continue;
            if (request.Scope != _authScope) { FailForIdentity(id); continue; }
            if (request.IsAction && request.Status == RequestStatus.Requested) { FailLostAction(id); continue; }
            if (!MaySendOnSocket(request.Scope))
            {
                request.Status = RequestStatus.NotSent;   // its identity's token isn't here yet: it waits (FlushHeld)
                continue;
            }
            if (request.Status == RequestStatus.NotSent) { request.Status = RequestStatus.Requested; request.SentAt = DateTimeOffset.UtcNow; }
            _connection?.Send(request.Message);
        }
        _httpFallback = false;
        _pollTask?.Cancel();
        _pollTask = null;
        SetState(ConnectionState.Connected);
        PublishStatus();
        ResetInactivity();
    }

    private void DidClose(string reason)
    {
        _connection = null;
        _inactivityTimer?.Cancel();
        if (!_openedThisAttempt) _consecutiveFailures++;
        _lastCloseReason = reason.Length > 120 ? reason[..120] : reason;
        if (_consecutiveFailures >= _options.FallbackAfterFailures && !_httpFallback)
        {
            _httpFallback = true;
            FlushPendingOverHttp();
            UpdatePolling(pollNow: true);
        }
        ScheduleReconnect();
    }

    private void Restart(string reason)
    {
        var old = _connection;
        _generation++;
        _connection = null;
        old?.Close();
        DidClose(reason);
    }

    private void ScheduleReconnect()
    {
        _reconnectTimer?.Cancel();
        var baseDelay = _options.InitialBackoff * (1 << Math.Min(_retries, 10));
        var delay = baseDelay < _options.MaxBackoff ? baseDelay : _options.MaxBackoff;
        if (_options.Jitter) delay *= 0.5 + Random.Shared.NextDouble() * 0.5;
        _retries++;
        SetState(new ConnectionState(ConnectionPhase.WaitingToReconnect, _retries));
        _reconnectTimer = After(delay, AttemptReconnect);
    }

    private void AttemptReconnect()
    {
        if (_state.Phase != ConnectionPhase.WaitingToReconnect) return;
        OpenSocket();
    }

    private void ResetInactivity()
    {
        _inactivityTimer?.Cancel();
        var gen = _generation;
        _inactivityTimer = After(_options.InactivityTimeout, () =>
        {
            if (gen == _generation && _state.Phase == ConnectionPhase.Connected) Restart("ServerInactivity");
        });
    }

    // MARK: Server messages

    private void HandleMessage(ServerMessage message)
    {
        switch (message)
        {
            case ServerMessage.Ping: break;
            case ServerMessage.AuthError e: AuthRefused(e.Error, e.BaseVersion); break;
            case ServerMessage.FatalError e: Restart($"FatalError: {ServerText.Clean(e.Error)}"); break;
            case ServerMessage.TransitionChunk c:
                _chunks ??= (c.TransitionId, c.TotalParts, new List<string>());
                var buffer = _chunks.Value;
                if (buffer.Id != c.TransitionId || buffer.Total != c.TotalParts || c.PartNumber != buffer.Parts.Count || c.TotalParts <= 0)
                {
                    _chunks = null;
                    throw new ConvexValueException("TransitionChunk out of order");
                }
                buffer.Parts.Add(c.Chunk);
                if (buffer.Parts.Count == buffer.Total)
                {
                    _chunks = null;
                    var full = ServerMessage.Parse(string.Concat(buffer.Parts));
                    if (full is not ServerMessage.Transition) throw new ConvexValueException("Chunks did not form a Transition");
                    HandleMessage(full);
                }
                break;
            case ServerMessage.Transition t:
                if (t.Start != _remoteVersion) throw new ConvexValueException($"Transition from {t.Start} but the client is at {_remoteVersion}");
                foreach (var modification in t.Modifications)
                {
                    switch (modification)
                    {
                        case QueryModification.Updated u when _queries.TryGetValue(u.QueryId, out var q):
                            q.Journal = u.Journal;
                            q.LastDelivered = u.Value;
                            Deliver(q, new ConvexQueryResult(u.Value, null));
                            break;
                        case QueryModification.Failed f when _queries.TryGetValue(f.QueryId, out var q):
                            q.Journal = f.Journal;
                            q.LastDelivered = null;
                            Deliver(q, new ConvexQueryResult(null, ConvexClientException.Function(f.Message, f.Data)));
                            break;
                    }
                }
                if (t.End.Identity > t.Start.Identity && t.End.Identity == _identityVersion) AuthConfirmed();
                _remoteVersion = t.End;
                Observe(t.End.Ts);
                _retries = 0;
                CompleteRequests(t.End.Ts);
                break;
            case ServerMessage.MutationSuccess s:
                Observe(s.Ts);
                if (!_requests.TryGetValue(s.RequestId, out var request) || request.IsAction) return;
                if (request.Status == RequestStatus.Completed) return;
                var receivedAt = DateTimeOffset.UtcNow;
                if (s.Ts <= _remoteVersion.Ts)
                {
                    _requests.Remove(s.RequestId);
                    request.CancelTasks();
                    request.Completion.TrySetResult(new Timed<ConvexValue>(s.Value, request.SentAt, receivedAt));
                }
                else
                {
                    request.Status = RequestStatus.Completed;
                    request.CompletedTs = s.Ts;
                    request.CompletedValue = s.Value;
                    request.CompletedAt = receivedAt;
                }
                break;
            case ServerMessage.MutationFailure f:
                if (_requests.TryGetValue(f.RequestId, out var failed) && !failed.IsAction)
                {
                    _requests.Remove(f.RequestId);
                    failed.CancelTasks();
                    failed.Completion.TrySetException(ConvexClientException.Function(f.Message, f.Data));
                }
                break;
            case ServerMessage.ActionSuccess a:
                if (_requests.TryGetValue(a.RequestId, out var action) && action.IsAction)
                {
                    _requests.Remove(a.RequestId);
                    action.CancelTasks();
                    action.Completion.TrySetResult(new Timed<ConvexValue>(a.Value, action.SentAt, DateTimeOffset.UtcNow));
                }
                break;
            case ServerMessage.ActionFailure a:
                if (_requests.TryGetValue(a.RequestId, out var failedAction) && failedAction.IsAction)
                {
                    _requests.Remove(a.RequestId);
                    failedAction.CancelTasks();
                    failedAction.Completion.TrySetException(ConvexClientException.Function(a.Message, a.Data));
                }
                break;
        }
    }

    private void Observe(ConvexTimestamp ts)
    {
        if (_maxObservedTimestamp is not { } max || max < ts) _maxObservedTimestamp = ts;
    }

    private void CompleteRequests(ConvexTimestamp upTo)
    {
        foreach (var (id, request) in _requests.ToList())
        {
            if (request.Status != RequestStatus.Completed || request.CompletedTs > upTo) continue;
            _requests.Remove(id);
            request.CancelTasks();
            request.Completion.TrySetResult(new Timed<ConvexValue>(request.CompletedValue!, request.SentAt, request.CompletedAt));
        }
    }

    // MARK: Queries

    /// <summary>Subscribes to a query. Results yield the current value and every change; dispose to unsubscribe.</summary>
    /// <remarks>
    /// With <paramref name="scope"/>, the subscription belongs to that identity: made after it changed, or once it changes,
    /// it yields AuthChanged, is taken out of the query set and yields nothing more (no value of another identity).
    /// </remarks>
    public ConvexSubscription Subscribe(string path, ConvexValue args, AuthScope? scope = null)
    {
        var channel = Channel.CreateBounded<ConvexQueryResult>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
        var canonical = ClientMessage.CanonicalUdfPath(path);
        int id;
        lock (_gate)
        {
            if (scope is { } stale && stale.Value != _authScope)
            {
                channel.Writer.TryWrite(new ConvexQueryResult(null, ConvexClientException.AuthChanged()));
                channel.Writer.TryComplete();
                return new ConvexSubscription(channel.Reader, () => { });
            }
            id = ++_ids;
            _queries[id] = new LocalQuery(canonical, args, r => channel.Writer.TryWrite(r), scope?.Value);
            if (_state.Phase == ConnectionPhase.Connected)
            {
                var baseVersion = _querySetVersion++;
                _connection?.Send(ClientMessage.ModifyQuerySet(baseVersion, _querySetVersion, [new ClientMessage.Add(id, canonical, args)], []));
            }
            else if (_httpFallback && _isForeground)
            {
                _ = PollAsync([id]);
            }
        }
        return new ConvexSubscription(channel.Reader, () =>
        {
            lock (_gate) RemoveQuery(id);
            channel.Writer.TryComplete();
        });
    }

    private void RemoveQuery(int id)
    {
        AssertLocked();
        if (!_queries.Remove(id)) return;
        if (_state.Phase == ConnectionPhase.Connected)
        {
            var baseVersion = _querySetVersion++;
            _connection?.Send(ClientMessage.ModifyQuerySet(baseVersion, _querySetVersion, [], [id]));
        }
    }

    /// <summary>Runs a query once: on the socket when connected (consistent with subscriptions), else over HTTP.</summary>
    /// <remarks><paramref name="scope"/>: the identity the query is made for; over HTTP it goes out only with that identity's token.</remarks>
    /// <remarks>
    /// With <paramref name="scope"/>, the query belongs to that identity, start to finish: refused if the identity changed
    /// before it is made, given AuthChanged if it changes while the answer is on its way, and its result is returned only
    /// if the identity is still the same as it returns.
    /// </remarks>
    public async Task<ConvexValue> QueryAsync(string path, ConvexValue args, CancellationToken cancellationToken = default, AuthScope? scope = null)
    {
        bool connected;
        lock (_gate)
        {
            if (scope is { } s && s.Value != _authScope) throw ConvexClientException.AuthChanged();
            connected = _state.Phase == ConnectionPhase.Connected;
        }
        ConvexValue value;
        if (!connected) value = await HttpCallAsync("query", path, args, scope?.Value, cancellationToken).ConfigureAwait(false);
        else
        {
            using var subscription = Subscribe(path, args, scope);
            try
            {
                var result = await subscription.Results.ReadAsync(cancellationToken).ConfigureAwait(false);
                value = result.Get();
            }
            catch (ChannelClosedException) { throw ConvexClientException.Stopped(); }
        }
        lock (_gate)
        {
            if (scope is { } s && s.Value != _authScope) throw ConvexClientException.AuthChanged();
        }
        return value;
    }

    // MARK: Mutations and actions

    /// <summary>
    /// Runs a mutation. <paramref name="scope"/> is the identity it was made for (what SetAuth returned): checked when
    /// enqueued, so a call made for an identity that changed before it got here fails with AuthChanged. Cancelling ends
    /// it with <see cref="OperationCanceledException"/>: one not sent yet never is, the answer to one sent is ignored.
    /// </summary>
    public Task<Timed<ConvexValue>> MutationAsync(string path, ConvexValue args, AuthScope? scope = null, CancellationToken cancellationToken = default) =>
        Enqueue(path, args, scope, isAction: false, cancellationToken);

    /// <summary>
    /// Runs an action. Unlike a mutation it isn't replayed: one sent on a socket that died fails (it may have run).
    /// Over HTTP it goes to <c>/api/action</c>.
    /// </summary>
    public async Task<ConvexValue> ActionAsync(string path, ConvexValue args, AuthScope? scope = null, CancellationToken cancellationToken = default) =>
        (await Enqueue(path, args, scope, isAction: true, cancellationToken).ConfigureAwait(false)).Value;

    private Task<Timed<ConvexValue>> Enqueue(string path, ConvexValue args, AuthScope? scope, bool isAction, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (_state.Phase is ConnectionPhase.Stopped or ConnectionPhase.Idle) return Task.FromException<Timed<ConvexValue>>(ConvexClientException.Stopped());
            if (scope is { } s && s.Value != _authScope) return Task.FromException<Timed<ConvexValue>>(ConvexClientException.AuthChanged());
            if (cancellationToken.IsCancellationRequested) return Task.FromCanceled<Timed<ConvexValue>>(cancellationToken);
            var canonical = ClientMessage.CanonicalUdfPath(path);
            var id = _nextRequestId++;
            var message = isAction ? ClientMessage.Action(id, canonical, args) : ClientMessage.Mutation(id, canonical, args);
            var made = _authScope;
            var connected = _state.Phase == ConnectionPhase.Connected && MaySendOnSocket(made);
            var overHttp = _httpFallback && _state.Phase != ConnectionPhase.Connected && MaySend(made);
            var request = new PendingRequest
            {
                Path = canonical, Args = args, Message = message, IsAction = isAction,
                Status = connected ? RequestStatus.Requested : RequestStatus.NotSent,
                SentAt = DateTimeOffset.UtcNow,
                Completion = new TaskCompletionSource<Timed<ConvexValue>>(TaskCreationOptions.RunContinuationsAsynchronously),
                Scope = made,
            };
            request.Timeout = After(_options.MutationTimeout, () => TimeOut(id));
            _requests[id] = request;
            if (cancellationToken.CanBeCanceled)
                request.Registration = cancellationToken.Register(() => { lock (_gate) CancelRequest(id, cancellationToken); });
            if (connected) _connection?.Send(message);
            else if (overHttp) SendOverHttp(id);
            return request.Completion.Task;
        }
    }

    private void CancelRequest(int id, CancellationToken token)
    {
        if (!_requests.Remove(id, out var request)) return;
        request.CancelTasks();
        request.Completion.TrySetCanceled(token);
    }

    private void TimeOut(int id)
    {
        if (!_requests.Remove(id, out var request)) return;
        request.CancelTasks();
        request.Completion.TrySetException(ConvexClientException.Transport("the sync server didn't answer in time"));
    }

    private void FailLostAction(int id)
    {
        if (!_requests.Remove(id, out var request)) return;
        request.CancelTasks();
        request.Completion.TrySetException(ConvexClientException.Transport("the connection was lost while the action ran"));
    }

    /// <summary>The identity calls are made for right now.</summary>
    public AuthScope CurrentScope { get { lock (_gate) return new AuthScope(_authScope); } }

    // MARK: HTTP fallback

    private void FlushPendingOverHttp()
    {
        foreach (var (id, request) in _requests.ToList())
        {
            switch (request.Status)
            {
                case RequestStatus.Completed:
                    _requests.Remove(id);
                    request.CancelTasks();
                    request.Completion.TrySetResult(new Timed<ConvexValue>(request.CompletedValue!, request.SentAt, request.CompletedAt));
                    break;
                case RequestStatus.Http: break;
                default:
                    if (request.Scope != _authScope) FailForIdentity(id);
                    else if (request.IsAction && request.Status == RequestStatus.Requested) FailLostAction(id);
                    else if (MaySend(request.Scope)) SendOverHttp(id);
                    else request.Status = RequestStatus.NotSent;   // waits for its identity's token (FlushHeld)
                    break;
            }
        }
    }

    /// <summary>Sends a pending call over HTTP. It stays in the table, so its deadline and Stop still end it.</summary>
    private void SendOverHttp(int id)
    {
        if (!_requests.TryGetValue(id, out var request)) return;
        if (request.Scope != _authScope) { FailForIdentity(id); return; }
        if (!MaySend(request.Scope)) return;
        request.Status = RequestStatus.Http;
        request.SentAt = DateTimeOffset.UtcNow;
        var cts = new CancellationTokenSource();
        request.HttpCancel = cts;
        var (kind, path, args, scope) = (request.IsAction ? "action" : "mutation", request.Path, request.Args, request.Scope);
        _ = Task.Run(async () =>
        {
            ConvexValue? value = null;
            Exception? error = null;
            try { value = await HttpCallAsync(kind, path, args, scope, cts.Token).ConfigureAwait(false); }
            catch (Exception e) { error = e; }
            lock (_gate) FinishHttp(id, request, value, error);
        });
    }

    private void FinishHttp(int id, PendingRequest sent, ConvexValue? value, Exception? error)
    {
        if (!_requests.TryGetValue(id, out var request) || !ReferenceEquals(request, sent) || request.Status != RequestStatus.Http) return;
        _requests.Remove(id);
        request.Timeout?.Cancel();
        request.Registration.Unregister();
        if (error is null)
        {
            request.Completion.TrySetResult(new Timed<ConvexValue>(value!, request.SentAt, DateTimeOffset.UtcNow));
            _ = PollAsync(null);   // read your writes: the poll brings what the mutation changed
        }
        else request.Completion.TrySetException(error);
    }

    private void UpdatePolling(bool pollNow)
    {
        if (!_httpFallback || !_isForeground || _state.Phase == ConnectionPhase.Stopped || _pollTask is not null) return;
        var cts = new CancellationTokenSource();
        _pollTask = cts;
        var interval = _options.PollInterval;
        _ = Task.Run(async () =>
        {
            try
            {
                if (!pollNow) await Task.Delay(interval, cts.Token).ConfigureAwait(false);
                while (!cts.IsCancellationRequested)
                {
                    await PollAsync(null).ConfigureAwait(false);
                    await Task.Delay(interval, cts.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) { }
        });
    }

    private async Task PollAsync(IReadOnlyList<int>? ids)
    {
        List<int> targets;
        lock (_gate)
        {
            if (!_httpFallback || !_isForeground || _state.Phase == ConnectionPhase.Connected) return;
            targets = ids?.ToList() ?? _queries.Keys.ToList();
        }
        foreach (var id in targets)
        {
            LocalQuery? q;
            int epoch, scope;
            lock (_gate)
            {
                if (!_queries.TryGetValue(id, out q)) continue;
                epoch = _socketEpoch;
                scope = _authScope;
            }
            try
            {
                // Bound to the identity current now: a poll whose identity changed while it fetched a token never goes out
                // with the next identity's token (its query belongs to a session that is ending).
                var value = await HttpCallAsync("query", q.Path, q.Args, scope, default).ConfigureAwait(false);
                lock (_gate)
                {
                    // A socket opened while this was in flight: its results are newer than this answer.
                    if (epoch != _socketEpoch || !_httpFallback || _state.Phase == ConnectionPhase.Connected) return;
                    // Asked for an identity that has ended: its answer is nobody's now.
                    if (scope != _authScope) return;
                    if (!_queries.TryGetValue(id, out var current) || current.LastDelivered == value) continue;
                    current.LastDelivered = value;
                    Deliver(current, new ConvexQueryResult(value, null));
                }
            }
            catch (ConvexClientException e)
            {
                lock (_gate)
                {
                    if (epoch != _socketEpoch || !_httpFallback || _state.Phase == ConnectionPhase.Connected || scope != _authScope) return;
                    if (e.Kind == ConvexErrorKind.Function && _queries.TryGetValue(id, out var current))
                    {
                        current.LastDelivered = null;
                        Deliver(current, new ConvexQueryResult(null, e));
                    }
                }
            }
            catch (Exception) { }
        }
    }

    /// <summary><paramref name="scope"/>: for a mutation, the identity it was made for. It is sent only with a token of that identity.</summary>
    private async Task<ConvexValue> HttpCallAsync(string kind, string path, ConvexValue args, int? scope, CancellationToken cancellationToken)
    {
        lock (_gate) { if (IsBlocked) throw ConvexClientException.Transport("network unavailable"); }
        var body = ConvexValue.Object(
            ("path", ConvexValue.String(ClientMessage.CanonicalUdfPath(path))),
            ("format", ConvexValue.String("convex_encoded_json")),
            ("args", ConvexValue.Array(args))).JsonBytes();
        var url = new Uri(DeploymentUrl, $"api/{kind}");
        var headers = new Dictionary<string, string> { ["Content-Type"] = "application/json", ["Convex-Client"] = MedleySyncInfo.ClientHeader };
        var token = await TokenForHttpAsync().ConfigureAwait(false);
        lock (_gate)
        {
            if (scope is { } sc)
            {
                if (sc != _authScope) throw ConvexClientException.AuthChanged();
                if (!MaySend(sc)) throw ConvexClientException.Transport("not signed in to the sync server yet");
            }
            // Never a token of another identity than the one calls are made for now.
            if (token is not null)
            {
                if (!Matches(token.Subject, _authIdentity)) throw ConvexClientException.AuthChanged();
                headers["Authorization"] = $"Bearer {token.Value}";
            }
        }
        (byte[] Body, int Status) response;
        try { response = await _http.PostAsync(url, body, headers, cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (ConvexClientException) { throw; }
        catch (Exception e) { throw ConvexClientException.Transport(e.Message); }
        // 560 is Convex's "the function threw" status.
        if (response.Status is not (>= 200 and < 300 or 560))
            throw ConvexClientException.Http(response.Status, System.Text.Encoding.UTF8.GetString(response.Body.AsSpan(0, Math.Min(500, response.Body.Length))));
        ConvexValue parsed;
        try { parsed = ConvexValue.Parse(response.Body); }
        catch (Exception e) { throw ConvexClientException.Decoding(e.Message); }
        return parsed["status"]?.StringValue switch
        {
            "success" => parsed["value"] ?? ConvexValue.Null,
            "error" => throw ConvexClientException.Function(parsed["errorMessage"]?.StringValue ?? "error", parsed["errorData"]),
            _ => throw ConvexClientException.Decoding("HTTP response without a status"),
        };
    }

    // MARK: Authentication

    private readonly record struct TokenFetch(bool IsUnavailable, string? Value)
    {
        public static TokenFetch Fetched(string? value) => new(false, value);
        public static readonly TokenFetch Unavailable = new(true, null);
    }

    /// <summary>
    /// Sets (or, with null, removes) the source of the user's token. <paramref name="identity"/> names who the provider
    /// signs in (the Clerk user id): when it differs from the last one, or is null, mutations made for the previous
    /// identity are never sent under this one. The same identity again keeps them.
    /// </summary>
    public async Task<AuthScope> SetAuthAsync(IAuthTokenProvider? provider, string? identity = null)
    {
        int epoch;
        AuthScope scope;
        lock (_gate)
        {
            _authEpoch++;
            epoch = _authEpoch;
            var sameIdentity = provider is not null && identity is not null && identity == _authIdentity;
            _authIdentity = provider is null ? null : identity;
            if (!sameIdentity)
            {
                _authScope++;
                foreach (var (id, request) in _requests.ToList())
                    if (request.Scope != _authScope && request.Status == RequestStatus.NotSent) FailForIdentity(id);
                // Queries made for the previous identity end now: AuthChanged, and out of the query set, so the server
                // never evaluates them for the next one.
                foreach (var (id, query) in _queries.Where(q => q.Value.Scope is { } qs && qs != _authScope).ToList())
                {
                    query.Deliver(new ConvexQueryResult(null, ConvexClientException.AuthChanged()));
                    RemoveQuery(id);
                }
                // The old identity's token goes now, and the open socket stops speaking for it, before anything awaits.
                DropIdentity();
            }
            scope = new AuthScope(_authScope);
            _authRefreshTimer?.Cancel();
            _authRefreshTimer = null;
            _authRefusals = 0;
            _authProvider = provider;
            if (provider is null)
            {
                _identityPending = false;
                DropIdentity();
                SetAuthState(new ConvexAuthState.None());
                FlushHeld();
                return scope;
            }
            if (_authToken is null) _identityPending = true;
        }
        TokenFetch token;
        try { token = TokenFetch.Fetched(await provider.GetTokenAsync(false).ConfigureAwait(false)); }
        catch { token = TokenFetch.Unavailable; }
        lock (_gate)
        {
            if (epoch == _authEpoch) Apply(token);
        }
        return scope;
    }

    private void Apply(TokenFetch token)
    {
        if (token.IsUnavailable) ScheduleAuthRetry();
        else if (token.Value is { } value) AdoptToken(value);
        else SignedOutByProvider();
    }

    private void AdoptToken(string value)
    {
        var changed = _authToken?.Value != value;
        if (!Accept(value)) return;
        if (changed)
        {
            if (_state.Phase == ConnectionPhase.Connected)
            {
                _connection?.Send(ClientMessage.Authenticate(value, _identityVersion));
                _identityVersion++;
                _socketToken = value;
            }
            SetAuthState(new ConvexAuthState.Pending());
        }
        ScheduleAuthRefresh();
        FlushHeld();
    }

    private bool Accept(string value)
    {
        var token = new AuthToken(value);
        if (!Matches(token.Subject, _authIdentity))
        {
            ScheduleAuthRetry();   // a provider answering for someone else: never sent
            return false;
        }
        _authToken = token;
        _identityPending = false;
        return true;
    }

    private static bool Matches(string? subject, string? identity) => identity is null || subject == identity;

    private bool MaySend(int scope)
    {
        if (scope != _authScope) return false;
        if (_authProvider is null) return true;
        if (_identityPending) return false;
        if (_authToken is not { } token) return true;
        return Matches(token.Subject, _authIdentity);
    }

    private bool MaySendOnSocket(int scope) => MaySend(scope) && _socketToken == _authToken?.Value;

    private void FlushHeld()
    {
        foreach (var id in _requests.Keys.ToList())
        {
            if (!_requests.TryGetValue(id, out var request) || request.Status != RequestStatus.NotSent || request.Scope != _authScope) continue;
            if (_state.Phase == ConnectionPhase.Connected)
            {
                if (!MaySendOnSocket(request.Scope)) continue;
                request.Status = RequestStatus.Requested;
                request.SentAt = DateTimeOffset.UtcNow;
                _connection?.Send(request.Message);
            }
            else if (_httpFallback) SendOverHttp(id);
        }
    }

    private void SignedOutByProvider()
    {
        _identityPending = false;
        DropIdentity();
        SetAuthState(new ConvexAuthState.None());
        FlushHeld();
    }

    private void DropIdentity()
    {
        _authToken = null;
        _authRefreshTimer?.Cancel();
        _authRefreshTimer = null;
        if (_socketToken is not null && _state.Phase == ConnectionPhase.Connected)
        {
            _connection?.Send(ClientMessage.AuthenticateNone(_identityVersion));
            _identityVersion++;
        }
        _socketToken = null;
    }

    private void SetAuthState(ConvexAuthState state)
    {
        if (state == _authState) return;
        _authState = state;
        PublishStatus();
    }

    private void AuthConfirmed()
    {
        _authRefusals = 0;
        SetAuthState(_authToken is null ? new ConvexAuthState.None() : new ConvexAuthState.Authenticated());
    }

    private void AuthRefused(string message, int? baseVersion)
    {
        if (_authProvider is null || _authToken is null) return;
        if (baseVersion is { } b && b + 1 < _identityVersion) return;   // about an identity already replaced
        _authRefusals++;
        _authToken = null;
        _authRefreshTimer?.Cancel();
        _authRefreshTimer = null;
        if (_authRefusals > MaxAuthRefusals)
        {
            _authProvider = null;
            _identityPending = false;
            SetAuthState(new ConvexAuthState.Failed(message.Length == 0 ? "The sync server refused the sign-in." : ServerText.Clean(message)));
        }
        else
        {
            _identityPending = true;   // calls wait for the fresh token OpenSocket fetches
            SetAuthState(new ConvexAuthState.Pending());
        }
        Restart("AuthError");
    }

    private void ScheduleAuthRefresh()
    {
        _authRefreshTimer?.Cancel();
        _authRefreshTimer = null;
        if (_authToken?.RefreshAt is not { } at) return;
        var epoch = _authEpoch;
        var delay = TimeSpan.FromMilliseconds(Math.Max(0, at - MonoClock.NowMs));
        _authRefreshTimer = AfterAsync(delay, () => RefreshTokenAsync(epoch));
    }

    private void ScheduleAuthRetry()
    {
        _authRefreshTimer?.Cancel();
        var epoch = _authEpoch;
        _authRefreshTimer = AfterAsync(_options.AuthRetryDelay, () => RefreshTokenAsync(epoch));
    }

    private async Task RefreshTokenAsync(int epoch)
    {
        IAuthTokenProvider? provider;
        lock (_gate)
        {
            if (epoch != _authEpoch || _state.Phase is ConnectionPhase.Stopped or ConnectionPhase.Idle) return;
            provider = _authProvider;
        }
        if (provider is null) return;
        TokenFetch token;
        try { token = TokenFetch.Fetched(await provider.GetTokenAsync(true).ConfigureAwait(false)); }
        catch { token = TokenFetch.Unavailable; }
        lock (_gate)
        {
            if (epoch != _authEpoch || _state.Phase == ConnectionPhase.Stopped) return;
            Apply(token);
        }
    }

    private async Task<AuthToken?> TokenForHttpAsync()
    {
        IAuthTokenProvider? provider;
        int epoch;
        lock (_gate)
        {
            provider = _authProvider;
            if (provider is null) return null;
            if (_authToken is { } current && !current.NeedsRefresh()) return current;
            epoch = _authEpoch;
        }
        string? fresh;
        try { fresh = await provider.GetTokenAsync(true).ConfigureAwait(false); }
        catch { lock (_gate) return _authToken; }
        lock (_gate)
        {
            if (fresh is null || epoch != _authEpoch) return _authToken;
            AdoptToken(fresh);
            return _authToken;
        }
    }

    private void FailForIdentity(int id)
    {
        if (!_requests.Remove(id, out var request)) return;
        request.CancelTasks();
        request.Completion.TrySetException(ConvexClientException.AuthChanged());
    }

    /// <summary>Testing aid: the identity version the client is at.</summary>
    public int CurrentIdentityVersion { get { lock (_gate) return _identityVersion; } }
}

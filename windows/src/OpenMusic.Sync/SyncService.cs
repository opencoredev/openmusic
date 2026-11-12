using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using OpenMusic.Core;
using OpenMusic.Core.Sync;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;

namespace OpenMusic.Sync;

/// <summary>One app-level sign-in on this device: the Clerk user and which of the sign-ins on this device it is.</summary>
public readonly record struct SyncSignIn(string UserId, int Generation);

/// <summary>
/// Who a piece of sync work is for: the account-operation epoch and the session (registration and identity scope) current
/// when it started. <see cref="SyncService.IsCurrent(SyncIdentity)"/> says whether it still is; work that awaited checks it
/// before each effect.
/// </summary>
public readonly record struct SyncIdentity(int Epoch, int Session);

/// <summary>Whether this device is registered with the account.</summary>
public abstract record Registration
{
    public sealed record None : Registration;
    public sealed record Registered(DeviceId DeviceId, LibraryId LibraryId) : Registration;
    public static readonly Registration NotRegistered = new None();
}

/// <summary>Whether this device can sync YouTube Music and Spotify sign-ins (it holds the account's vault key).</summary>
public abstract record KeyStatus
{
    public sealed record None : KeyStatus;
    /// <summary>This device holds the vault key; sign-ins sync.</summary>
    public sealed record Available : KeyStatus;
    /// <summary>Asked for the key; no device that has it answered yet.</summary>
    public sealed record Waiting : KeyStatus;
    /// <summary>A device that has the key answered: compare the code with the one it shows.</summary>
    public sealed record Comparing(KeyComparison Comparison) : KeyStatus;
    /// <summary>A device that has the key said no. RequestKeyAgain asks again.</summary>
    public sealed record Denied : KeyStatus;
    /// <summary>This attempt ended; RequestKeyAgain starts a new one. The message says what happened.</summary>
    public sealed record Failed(string Message) : KeyStatus;
    /// <summary>The key this device holds isn't the account's; sign-ins don't sync.</summary>
    public sealed record Mismatch : KeyStatus;
    /// <summary>This device holds a key the account replaced while it was away; RequestKeyAgain drops it and asks.</summary>
    public sealed record Outdated : KeyStatus;

    public static readonly KeyStatus NoneStatus = new None();
    public static readonly KeyStatus AvailableStatus = new Available();
    public static readonly KeyStatus WaitingStatus = new Waiting();
    public static readonly KeyStatus DeniedStatus = new Denied();
    public static readonly KeyStatus MismatchStatus = new Mismatch();
    public static readonly KeyStatus OutdatedStatus = new Outdated();
}

/// <summary>The code an asking device shows while it compares with the holder that answered it.</summary>
public sealed record KeyComparison(string Code, DeviceId HolderId, string HolderName, bool Allowed, bool Confirmed)
{
    /// <summary>The card's title, the same on every app. <paramref name="here"/> is "this PC".</summary>
    public string Title(string here) => (Allowed, Confirmed) switch
    {
        (false, false) => "Compare the codes",
        (false, true) => $"Waiting for {HolderName}",
        (true, false) => $"{HolderName} allowed {here}",
        _ => "Taking your sign-ins…",
    };

    public string Instructions(string here) => (Allowed, Confirmed) switch
    {
        (false, false) => $"{HolderName} shows a code too. If it's the same as this one, tap Allow on {HolderName} and Codes Match here. If it isn't, tap Codes Don't Match.",
        (false, true) => $"Tap Allow on {HolderName} to share your YouTube Music and Spotify sign-ins with {here}.",
        (true, false) => $"Tap Codes Match if {HolderName} showed this same code. If it didn't, tap Codes Don't Match: {here} then doesn't take anything.",
        _ => "Your YouTube Music and Spotify sign-ins arrive in a moment.",
    };
}

/// <summary>Another device asking for the vault key whose exchange checked out here. Show <see cref="Code"/>, then Allow or Deny.</summary>
public sealed record KeyRequest(SyncDevice Device, string Code, string Commitment)
{
    public DeviceId Id => Device.Id;
}

/// <summary>What <see cref="SignInSync"/> needs from the service.</summary>
public interface IVaultEndpoint
{
    DeviceId? SelfId { get; }
    LibraryKey? LibraryKey { get; }
    bool VaultWritesPaused { get; }
    IReadOnlyList<VaultEntry>? VaultEntries { get; }
    ServerClock Clock { get; }
    Task<VaultWrite> PutVaultAsync(ProviderId provider, string sealedText, string keyId, int baseRevision);
    Task<VaultWrite> SignOutVaultAsync(ProviderId provider, int baseRevision);
}

/// <summary>What <see cref="SettingsSync"/> needs from the service.</summary>
public interface ISettingsEndpoint
{
    DeviceId? SelfId { get; }
    IReadOnlyList<SettingEntry>? SettingEntries { get; }
    Task<double> PutSettingAsync(string key, string value, string writeId, bool ifAbsent);
}

/// <summary>What <see cref="SyncCoordinator"/> needs from the service. Raises PropertyChanged for Playback and Devices.</summary>
public interface ISyncServicing : INotifyPropertyChanged
{
    DeviceId? SelfId { get; }
    IReadOnlyList<SyncDevice> Devices { get; }
    IReadOnlyDictionary<DeviceId, RemotePlayback> Playback { get; }
    ServerClock Clock { get; }
    Func<IncomingCommand, Task<CommandResult>>? CommandHandler { get; set; }
    /// <summary>The identity work starting now belongs to (read on the actor).</summary>
    SyncIdentity Identity { get; }
    /// <summary>Whether <paramref name="identity"/> is still the current one (on the actor).</summary>
    bool IsCurrent(SyncIdentity identity);
    Task PublishAsync(PlaybackAnchor anchor, QueueWindow? queue);
    Task ClearPlaybackAsync();
    Task<QueueWindow?> FetchQueueAsync(DeviceId device);
    Task<CommandId> SendAsync(SyncCommand command, DeviceId device);
    Task<CommandResult> WaitForAckAsync(CommandId command, TimeSpan timeout);
    void SetPlaying(bool playing);
    /// <summary>Whether this device holds the account's current vault key, so it can seal what it plays and open what others
    /// play. Without it, it publishes only its anchor and can't hand playback off.</summary>
    bool CanSealContent { get; }
    /// <summary>Raised (on the actor) when the key this device seals with changes: the coordinator publishes its queue again.</summary>
    event Action? ContentKeyChanged;
}

/// <summary>
/// The sync session of this device (port of <c>SyncService.swift</c> and <c>SyncService+Keys.swift</c>): its registration
/// with the signed-in account, the device list, everyone's playback and the command channel, and the vault key moving
/// between devices. The app signs in with Clerk and calls <see cref="SignInAsync"/>: the device registers and the live
/// queries open. All state lives on <see cref="Actor"/>; every public method dispatches to it first, and
/// <see cref="PropertyChanged"/> is raised there.
/// <para>
/// Identity: every call captures the device token, the identity scope and the account-operation epoch on the actor before
/// its first await (<see cref="CallReportingCodes{T}"/>); the Convex client refuses it if the scope changed before it was
/// sent, and an answer that arrives after the epoch moved on is not returned. Live queries are bound to the session and
/// scope they were opened under and reopened when the scope changes; a command's ack goes out only for the session the
/// command arrived in; a fetched queue or device list is returned only while its session is current.
/// </para>
/// </summary>
public sealed partial class SyncService : INotifyPropertyChanged, IVaultEndpoint, ISettingsEndpoint, ISyncServicing
{
    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>Raised after the server stopped knowing this device (removed on another device). The app signs out.</summary>
    public event Action? Removed;
    /// <summary>Raised as each command arrives, before it runs, with how long it took to get here (server clock, ms).</summary>
    public event Action<IncomingCommand, double>? CommandReceived;

    public SyncActor Actor { get; }
    public ConvexClient Client { get; }
    public SignInSync SignIns { get; }
    public SettingsSync Settings { get; }
    public ServerClock Clock { get; } = new();
    /// <summary>Name, platform and model sent when this device joins. Set on the actor (from elsewhere it is posted there).</summary>
    public DeviceInfo DeviceInfo { get => _deviceInfo; set => Actor.Perform(() => _deviceInfo = value); }
    private DeviceInfo _deviceInfo;

    internal readonly SyncCredentialStore Store;
    internal SyncCredentials? Credentials
    {
        get => _credentials;
        set
        {
            var old = _credentials;
            _credentials = value;
            if (_contentHooked && (old?.LibraryKey?.Id != value?.LibraryKey?.Id || old?.LibraryId != value?.LibraryId)) ContentKeysChanged();
        }
    }
    private SyncCredentials? _credentials;
    /// <summary>Set once the constructor is done: from then on a key change opens everything again.</summary>
    private bool _contentHooked;
    /// <summary>The server's rows as they came, kept sealed so they can be opened again when this device's key changes.</summary>
    private IReadOnlyList<PlaybackRow> _playbackRows = [];
    internal IReadOnlyList<SealedSettingEntry>? SealedSettings;
    private IReadOnlyList<WireOutgoingCommand> _wireOutgoing = [];
    private string? _openingKeyMark;
    private string? _sealingKeyMark;
    public event Action? ContentKeyChanged;
    internal KeyLedger Ledger = new();
    internal LibraryKey? PendingGrantKey;
    internal readonly AccountOperations Operations = new();
    internal AuthScope? AuthScope;
    internal string? AuthUserId;
    private SyncSignIn? _authSignIn;
    internal int AppliedKeyRevision;
    internal (DeviceListResult List, string? Token)? PendingList;
    internal readonly HashSet<string> FailedKeyBlobs = new();
    /// <summary>The wall clock for rate limits and warnings (tests move it).</summary>
    internal Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;
    private bool _started;
    /// <summary>Stopped by <see cref="StopAsync"/>: stays stopped until <see cref="Start"/> or a sign-in, whatever is still queued.</summary>
    private bool _stopped;
    private readonly List<(CancellationTokenSource Cancel, ConvexSubscription Subscription)> _subscriptions = new();
    private CancellationTokenSource? _statusTask, _heartbeatTask, _suspendTask;
    private readonly List<CommandId> _handledCommands = new();
    private readonly Queue<IncomingCommand> _commandQueue = new();
    private bool _runningCommands;
    private readonly Dictionary<CommandId, Dictionary<Guid, TaskCompletionSource<CommandResult>>> _ackWaiters = new();
    private bool _isForeground = true;
    private bool _isPlaying;
    private SyncSignIn? _requestedSignIn;
    private Func<IncomingCommand, Task<CommandResult>>? _commandHandler;
    /// <summary>Bumped whenever the session ends or the identity scope changes (see <see cref="Identity"/>).</summary>
    private int _sessionVersion;

    public SyncIdentity Identity => Actor.Read(() => new SyncIdentity(Operations.Epoch, _sessionVersion));

    public bool IsCurrent(SyncIdentity identity) => Actor.Read(() => identity.Epoch == Operations.Epoch && identity.Session == _sessionVersion);

    /// <summary>Close the socket in the background when not playing (after <see cref="BackgroundGrace"/>). Off by default on desktop.</summary>
    public bool SuspendsInBackground { get; set; }
    public TimeSpan BackgroundGrace { get; set; } = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(30);
    /// <summary>The dev deployment (Convex project <c>openmusic</c>): Debug builds, tests, probes and live scripts.</summary>
    public static readonly Uri DefaultDeploymentUrl = new("https://sensible-barracuda-214.convex.cloud");
    /// <summary>The production deployment: Release builds.</summary>
    public static readonly Uri ProductionDeploymentUrl = new("https://insightful-roadrunner-835.convex.cloud");

    public SyncService(Uri deploymentUrl, DeviceInfo deviceInfo, SyncCredentialStore store, SyncActor? actor = null,
                       IWebSocketTransport? transport = null, IHttpPoster? http = null, ConvexClientOptions? options = null)
    {
        // Not shared yet: its state is set up on the creating thread.
        using var setup = SyncActor.Setup();
        _deviceInfo = deviceInfo;
        Store = store;
        Actor = actor ?? SyncActor.CreateDedicated();
        Client = new ConvexClient(deploymentUrl, transport, http, options);
        SignIns = new SignInSync(store, this);
        Settings = new SettingsSync(this, () => Clock.Now());
        if (store.Load() is { } saved && saved.DeploymentUrl == deploymentUrl)
        {
            Credentials = saved;
            _registration = new Registration.Registered(saved.DeviceId, saved.LibraryId);
        }
        LoadLedger();
        SignIns.BeginSession(Credentials is { } c ? Scope(c) : null);
        UpdateKeyStatus();
        _openingKeyMark = Credentials?.LibraryKey?.Id;
        _sealingKeyMark = ContentKey?.Id;
        _contentHooked = true;
    }

    // MARK: Observable state

    private Registration _registration = Registration.NotRegistered;
    private IReadOnlyList<SyncDevice> _devices = [];
    private IReadOnlyDictionary<DeviceId, RemotePlayback> _playback = new Dictionary<DeviceId, RemotePlayback>();
    private IReadOnlyList<OutgoingCommand> _outgoing = [];
    private IReadOnlyList<IncomingCommand> _incoming = [];
    private ConvexStatus _connection = new(ConnectionState.Idle, false, 0, new ConvexAuthState.None());
    private SyncException? _lastError;
    private IReadOnlyList<VaultEntry>? _vaultEntries;
    private IReadOnlyList<SettingEntry>? _settingEntries;
    private string? _serverKeyId;
    private KeyStatus _keyStatus = KeyStatus.NoneStatus;
    private bool _rotationNeeded;

    public Registration Registration { get => _registration; private set => Set(ref _registration, value, [nameof(SelfId), nameof(IsRegistered), nameof(SelfDevice), nameof(OtherDevices)]); }
    /// <summary>Every device of the account, this one included, oldest first.</summary>
    public IReadOnlyList<SyncDevice> Devices { get => _devices; internal set => Set(ref _devices, value, [nameof(SelfDevice), nameof(OtherDevices), nameof(KeyHolders), nameof(KeyRequests)]); }
    /// <summary>Published playback by device, this one included.</summary>
    public IReadOnlyDictionary<DeviceId, RemotePlayback> Playback { get => _playback; private set => Set(ref _playback, value); }
    /// <summary>Commands this device sent recently, newest first.</summary>
    public IReadOnlyList<OutgoingCommand> Outgoing { get => _outgoing; private set => Set(ref _outgoing, value); }
    /// <summary>Commands for this device that aren't acked yet.</summary>
    public IReadOnlyList<IncomingCommand> Incoming { get => _incoming; private set => Set(ref _incoming, value); }
    public ConvexStatus Connection { get => _connection; private set => Set(ref _connection, value); }
    public SyncException? LastError { get => _lastError; internal set => Set(ref _lastError, value); }
    public IReadOnlyList<VaultEntry>? VaultEntries { get => _vaultEntries; private set => Set(ref _vaultEntries, value); }
    public IReadOnlyList<SettingEntry>? SettingEntries { get => _settingEntries; private set => Set(ref _settingEntries, value); }
    /// <summary>Fingerprint of the vault key according to the server (null while nobody holds one).</summary>
    public string? ServerKeyId
    {
        get => _serverKeyId;
        internal set
        {
            var changed = _serverKeyId != value;
            Set(ref _serverKeyId, value, [nameof(VaultWritesPaused), nameof(KeyRequests), nameof(KeyWarning)]);
            if (changed && _contentHooked) ContentKeysChanged();
        }
    }
    public KeyStatus KeyStatus { get => _keyStatus; internal set => Set(ref _keyStatus, value, [nameof(KeyRequests), nameof(KeyWarning), nameof(LibraryKey)]); }
    /// <summary>A device that could open the vault left, so a holder must replace the key (this one does it at once).</summary>
    public bool RotationNeeded { get => _rotationNeeded; internal set => Set(ref _rotationNeeded, value, [nameof(VaultWritesPaused)]); }

    public LibraryKey? LibraryKey => Credentials?.LibraryKey;
    public DeviceId? SelfId => Registration is Registration.Registered r ? r.DeviceId : null;
    public bool IsRegistered => SelfId is not null;
    public SyncDevice? SelfDevice => Devices.FirstOrDefault(d => d.Id == SelfId);
    public IReadOnlyList<SyncDevice> OtherDevices => Devices.Where(d => d.Id != SelfId).ToList();
    /// <summary>The other devices that hold the vault key (and so can allow this one).</summary>
    public IReadOnlyList<SyncDevice> KeyHolders => OtherDevices.Where(d => d.KeyState == KeyStateKind.Holder).ToList();
    /// <summary>Devices asking for the vault key whose exchange checked out here, when this device has it.</summary>
    public IReadOnlyList<KeyRequest> KeyRequests => Actor.Read(VerifiedKeyRequests);
    /// <summary>Something about requests for the key looks wrong. Null when all is well.</summary>
    public string? KeyWarning => Actor.Read(KeyExchangeWarning);

    public bool IsOnline(SyncDevice device) => device.IsOnline(Clock.Now());
    /// <summary>Live position (seconds) of a device's playback, extrapolated on the server clock.</summary>
    public double? LivePosition(DeviceId device) => Actor.Read(() => Playback.TryGetValue(device, out var row) ? row.Anchor.Position(Clock.Now()) : (double?)null);

    public Func<IncomingCommand, Task<CommandResult>>? CommandHandler
    {
        get => _commandHandler;
        set
        {
            if (!Actor.IsCurrent) { Actor.Post(() => CommandHandler = value); return; }
            _commandHandler = value;
            if (value is not null) ProcessIncoming();
        }
    }

    private void Set<T>(ref T field, T value, string[]? dependents = null, [CallerMemberName] string? name = null)
    {
        Actor.AssertCurrent(name);
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Raise(name);
        if (dependents is not null) foreach (var d in dependents) Raise(d);
    }

    internal void Raise(string? name)
    {
        Actor.AssertCurrent(name);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    // MARK: Lifecycle

    /// <summary>Connects and, when registered, opens the live queries. Safe to call more than once.</summary>
    public void Start()
    {
        if (!Actor.IsCurrent) { Actor.Post(Start); return; }
        _stopped = false;
        if (_started) return;
        _started = true;
        var cts = new CancellationTokenSource();
        _statusTask = cts;
        var updates = Client.StatusUpdates(cts.Token);
        _ = FollowStatus(updates, cts.Token);
        Client.Start();
        if (Credentials is not null) OpenSubscriptions();
        UpdateActivity();
    }

    private async Task FollowStatus(System.Threading.Channels.ChannelReader<ConvexStatus> updates, CancellationToken token)
    {
        AccountOperations.Current.Value = null;
        try
        {
            await foreach (var status in updates.ReadAllAsync(token))
            {
                await Actor.Switch();
                if (!token.IsCancellationRequested) Connection = status;
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>
    /// Stops: a new epoch (operations queued before it never run) and the connection closes. It stays stopped: work queued
    /// before it (a sign-in sync, a settings upload) fails instead of starting the connection again. Start or a sign-in
    /// starts it.
    /// </summary>
    public async Task StopAsync()
    {
        await Actor.Switch();
        Operations.Supersede();
        _stopped = true;
        StopNow();
    }

    /// <summary>Stop without starting a new epoch: a sign-out ends with it, and must not cancel a sign-in queued after it.</summary>
    private void StopNow()
    {
        _started = false;
        CloseSubscriptions();
        _statusTask?.Cancel();
        _statusTask = null;
        Connection = new ConvexStatus(ConnectionState.Idle, false, Connection.Connections, Connection.Auth);
        _heartbeatTask?.Cancel();
        _heartbeatTask = null;
        _suspendTask?.Cancel();
        _suspendTask = null;
        Client.Stop();
    }

    /// <summary>The app moved to or from the foreground. Heartbeats and the HTTP poll run only while in the foreground or playing.</summary>
    public async Task SetForegroundAsync(bool foreground)
    {
        await Actor.Switch();
        var returning = foreground && !_isForeground;
        _isForeground = foreground;
        UpdateActivity();
        if (returning) SignIns.RetryNowOnActor();
    }

    public void SetPlaying(bool playing) => Actor.Perform(() =>
    {
        if (playing == _isPlaying) return;
        _isPlaying = playing;
        UpdateActivity();
    });

    private bool IsAwake => _isForeground || _isPlaying;

    /// <summary>After a wake from sleep: replace the socket now instead of trusting one that may have died silently.</summary>
    public void ReconnectNow(bool force = false) => Actor.Perform(() =>
    {
        if (_started) Client.ReconnectNow(force);
    });

    private void UpdateActivity()
    {
        var awake = IsAwake;
        Client.SetForeground(awake);
        if (awake && _started)
        {
            Client.Start();
            Client.ReconnectNow();
        }
        if (awake)
        {
            _suspendTask?.Cancel();
            _suspendTask = null;
        }
        else ArmSuspend();
        var active = _started && Credentials is not null && awake;
        if (active && _heartbeatTask is null)
        {
            var cts = new CancellationTokenSource();
            _heartbeatTask = cts;
            _ = HeartbeatLoop(cts.Token);
        }
        else if (!active)
        {
            _heartbeatTask?.Cancel();
            _heartbeatTask = null;
        }
    }

    private async Task HeartbeatLoop(CancellationToken token)
    {
        AccountOperations.Current.Value = null;
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Heartbeat();
                await Task.Delay(HeartbeatInterval, token);
            }
        }
        catch (OperationCanceledException) { }
    }

    private void ArmSuspend()
    {
        if (!SuspendsInBackground || !_started || IsAwake) return;
        _suspendTask?.Cancel();
        var cts = new CancellationTokenSource();
        _suspendTask = cts;
        _ = Task.Delay(BackgroundGrace, cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            Actor.Post(() => { if (!cts.IsCancellationRequested && _started && !IsAwake) Client.Suspend(); });
        }, TaskScheduler.Default);
    }

    private async Task Heartbeat()
    {
        if (Credentials?.Token is not { } token) return;
        try { await Call<ServerNowResult>("devices:heartbeat", new TokenArgs(token)); } catch (Exception) { }
        // Requests a holder held back (its hourly limit) get answered once the limit allows, without a list change.
        Operations.Enqueue("answers", _ => ResumeKeyRequests());
    }

    // MARK: Account

    /// <summary>
    /// A registration sent but not settled, saved before <c>account:register</c> is sent and kept until the server answers.
    /// One made more than 7 days ago (or more than a day in the future) is never sent again.
    /// </summary>
    internal sealed record PendingRegistration
    {
        public const string StateName = "registration.v1";
        public static readonly TimeSpan MaxAge = TimeSpan.FromDays(7);
        public static readonly TimeSpan MaxAhead = TimeSpan.FromDays(1);
        public required string Token { get; init; }
        public required string DeviceKey { get; init; }
        public required string ProposedKey { get; init; }
        public required string UserId { get; init; }
        public required string DeploymentUrl { get; init; }
        public DateTimeOffset? CreatedAt { get; init; }

        [System.Text.Json.Serialization.JsonIgnore] public DeviceKeyPair Pair => DeviceKeyPair.FromEncoded(DeviceKey)!;
        [System.Text.Json.Serialization.JsonIgnore] public LibraryKey Proposed => Keys.LibraryKey.FromEncoded(ProposedKey)!;

        public bool IsExpired(DateTimeOffset now)
        {
            if (CreatedAt is not { } created) return true;
            var age = now - created;
            return age > MaxAge || age < -MaxAhead;
        }

        public static PendingRegistration Fresh(string userId, Uri deployment, DateTimeOffset now) => new()
        {
            Token = SyncCredentials.NewDeviceToken(), DeviceKey = DeviceKeyPair.Generate().EncodedPrivateKey, ProposedKey = Keys.LibraryKey.Generate().Encoded,
            UserId = userId, DeploymentUrl = deployment.AbsoluteUri, CreatedAt = now,
        };
    }

    private PendingRegistration? _pending;

    /// <summary>A device of this installation that must still be removed from its account (by token).</summary>
    internal sealed record PendingRemoval(string Token, string UserId, string DeploymentUrl)
    {
        public const string StateName = "removals.v1";
    }

    /// <summary>
    /// Signs this device in to sync: calls carry <paramref name="auth"/>'s token from now on, the device registers with the
    /// account (once; later launches reuse the saved registration) and the live queries open. Throws when registering fails
    /// or its credentials couldn't be saved; calling again resends the same registration. Throws
    /// <see cref="OperationCanceledException"/> when a sign-out, a newer sign-in or a server change overtook it.
    /// </summary>
    public async Task SignInAsync(IAuthTokenProvider auth, string userId, int generation = 0)
    {
        await Actor.Switch();
        var signIn = new SyncSignIn(userId, generation);
        var ticket = Operations.Supersede();
        _requestedSignIn = signIn;
        await Operations.Run(ticket, t => PerformSignIn(auth, signIn, t));
    }

    private async Task PerformSignIn(IAuthTokenProvider auth, SyncSignIn signIn, AccountOperations.Ticket ticket)
    {
        var userId = signIn.UserId;
        if (Credentials is { } saved && saved.UserId != userId)
        {
            // Another user's device: removed when that user signs in here again, never just forgotten.
            if (!SetAsideForRemoval(saved.Token, saved.UserId)) throw RegistrationNotSaved;
            ForgetNow();
        }
        if (SavedPendingRegistration() is { } pendingSaved && (pendingSaved.UserId != userId || pendingSaved.DeploymentUrl != Client.DeploymentUrl.AbsoluteUri))
        {
            if (!SetAsideForRemoval(pendingSaved.Token, pendingSaved.UserId, pendingSaved.DeploymentUrl)) throw RegistrationNotSaved;
            DropPendingRegistration();
        }
        // Calls still queued for another user fail here instead of going out under this user's identity.
        var scope = await Client.SetAuthAsync(auth, userId);
        ticket.Check(Operations);
        SetIdentity(scope, userId);
        _authSignIn = signIn;
        if (!_started) Start();
        _stopped = false;
        if (Credentials is { } credentials)
        {
            SaveCredentialsOfPendingRegistration(credentials);
            CompleteRemovalsLater();
            return;
        }
        var attempt = PendingRegistrationFor(userId);
        var args = new RegisterArgs(attempt.Token, WireDeviceInfo(DeviceInfo), attempt.Pair.PublicKey, attempt.Proposed.Id,
                                    Math.Round((attempt.CreatedAt ?? Now()).ToUnixTimeMilliseconds() * 1.0));
        RegisterResult result;
        try
        {
            result = await CallReportingCodes<RegisterResult>("account:register", args, ticket);
        }
        catch (ConvexClientException e) when (RefusesRegistration(e))
        {
            // Refused, so it never landed: the next attempt starts over with a new token and key.
            if (_pending?.Token == attempt.Token) DropPendingRegistration();
            throw SyncException.From(e);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception e)
        {
            // Not known to have landed or not: the registration stays saved and is sent again as it is.
            throw SyncException.From(e);
        }
        if (Credentials is not null || _pending?.Token != attempt.Token) return;
        ServerKeyId = result.KeyId;
        // Only a key this device just made counts: an account that has a key gives it only through the exchange.
        var holdsProposal = result.KeyState == KeyStateKind.Holder && result.KeyId == attempt.Proposed.Id;
        var stored = Adopt(new SyncCredentials
        {
            DeviceId = result.DeviceId, LibraryId = result.LibraryId, Token = attempt.Token, DeploymentUrl = Client.DeploymentUrl,
            DeviceKey = attempt.Pair, UserId = userId, LibraryKey = holdsProposal ? attempt.Proposed : null,
        }, result.KeyRevision ?? 0);
        // Dropped only once the credentials holding the token and key are saved.
        if (!stored) throw RegistrationNotSaved;
        DropPendingRegistration();
        CompleteRemovalsLater();
    }

    /// <summary>
    /// Whether a Windows device registers as <c>windows</c>. On: the backend's <c>platformV</c> takes it, and the Swift apps
    /// decode it (and any platform they don't know, as a generic computer). Off registers a Windows device as <c>mac</c>,
    /// for a server from before <c>windows</c> existed.
    /// </summary>
    public static bool SendsWindowsPlatform { get; set; } = true;

    internal static OpenMusic.Core.Sync.DeviceInfo WireDeviceInfo(OpenMusic.Core.Sync.DeviceInfo info) =>
        info.Platform == DevicePlatform.Windows && !SendsWindowsPlatform ? info with { Platform = DevicePlatform.Mac } : info;

    private static SyncException RegistrationNotSaved => SyncException.Server($"{ProductInfo.Name} couldn't save this device's registration. It tries again later.");

    private void SaveCredentialsOfPendingRegistration(SyncCredentials credentials)
    {
        if (_pending is null && Store.State(PendingRegistration.StateName) is null) return;
        if (!(Store.Load() == credentials || Store.Persist(credentials))) throw RegistrationNotSaved;
        DropPendingRegistration();
    }

    private static bool RefusesRegistration(ConvexClientException e) => e.Code is "unauthorized" or "invalidArgument";

    private PendingRegistration? SavedPendingRegistration() => _pending ?? Store.StateAs<PendingRegistration>(PendingRegistration.StateName);

    private PendingRegistration PendingRegistrationFor(string userId)
    {
        if (SavedPendingRegistration() is { } saved && saved.UserId == userId && saved.DeploymentUrl == Client.DeploymentUrl.AbsoluteUri)
        {
            if (!saved.IsExpired(Now()))
            {
                _pending = saved;
                return saved;
            }
            if (!SetAsideForRemoval(saved.Token, saved.UserId, saved.DeploymentUrl)) throw RegistrationNotSaved;
            DropPendingRegistration();
        }
        var fresh = PendingRegistration.Fresh(userId, Client.DeploymentUrl, Now());
        if (!Store.PersistState(PendingRegistration.StateName, SyncCredentialStore.Encode(fresh))) throw RegistrationNotSaved;
        _pending = fresh;
        return fresh;
    }

    private void DropPendingRegistration()
    {
        _pending = null;
        if (Store.State(PendingRegistration.StateName) is not null) Store.SetState(PendingRegistration.StateName, null);
    }

    internal List<PendingRemoval> PendingRemovals => Store.StateAs<List<PendingRemoval>>(PendingRemoval.StateName) ?? new();

    private bool SetAsideForRemoval(string token, string? userId, string? deploymentUrl = null)
    {
        if (userId is null) return true;   // credentials from before accounts: no user to remove it as
        var record = new PendingRemoval(token, userId, deploymentUrl ?? Client.DeploymentUrl.AbsoluteUri);
        var all = PendingRemovals;
        if (all.Contains(record)) return true;
        all.Add(record);
        return Store.PersistState(PendingRemoval.StateName, SyncCredentialStore.Encode(all));
    }

    private void DropRemoval(PendingRemoval record)
    {
        var rest = PendingRemovals.Where(r => r != record).ToList();
        Store.SetState(PendingRemoval.StateName, rest.Count == 0 ? null : SyncCredentialStore.Encode(rest));
    }

    private void CompleteRemovalsLater()
    {
        if (AuthUserId is not { } user || !PendingRemovals.Any(r => r.UserId == user)) return;
        Operations.Enqueue("removals", CompleteRemovals);
    }

    private async Task CompleteRemovals(AccountOperations.Ticket ticket)
    {
        if (AuthUserId is not { } user) return;
        foreach (var record in PendingRemovals.Where(r => r.UserId == user && r.DeploymentUrl == Client.DeploymentUrl.AbsoluteUri))
        {
            if (record.Token == Credentials?.Token)
            {
                DropRemoval(record);   // this device's own registration now; nothing to remove
                continue;
            }
            try
            {
                var result = await WithTimeout(TimeSpan.FromSeconds(10), "The sync server",
                    ct => CallReportingCodes<UnregisterResult>("account:unregister", new TokenArgs(record.Token), ticket, ct));
                ticket.Check(Operations);
                // Kept until the server says the token is removed or refused from now on.
                if (result.Settled) DropRemoval(record);
            }
            catch (ConvexClientException e) when (e.Code == "invalidArgument")
            {
                // A malformed token can never name a device: drop it so it can't block the rest.
                DropRemoval(record);
                if (!ticket.IsValid(Operations)) return;
            }
            catch (ConvexClientException e) when (e.Code == "rateLimited")
            {
                // This withdrawal was refused; the record stays for the next sign-in, and the others still go.
                if (!ticket.IsValid(Operations)) return;
            }
            catch (Exception)
            {
                return;   // offline, or overtaken: the record stays for the next sign-in
            }
        }
    }

    /// <summary>
    /// Signs this device out of sync: removes it from the account's devices, forgets the token, keys and vault key, and
    /// closes the connection. Runs after everything enqueued before it and before anything enqueued after; never cancelled.
    /// </summary>
    public async Task SignOutAsync()
    {
        await Actor.Switch();
        var ticket = Operations.Supersede(immune: true);
        _requestedSignIn = null;
        try { await Operations.Run(ticket, PerformSignOut); } catch (Exception) { }
    }

    /// <summary>
    /// SignOut for an app-level sign-out started for <paramref name="signIn"/>: when sync is asked for, or signed in by,
    /// another sign-in by then (another user, or the same user again), this sign-out is older and does nothing.
    /// </summary>
    public async Task SignOutAsync(SyncSignIn? signIn)
    {
        await Actor.Switch();
        // Only a newer sign-in survives it; an older one (or the same) is signed out.
        if (signIn is { } s && _requestedSignIn is { } latest && IsNewer(latest, s)) return;
        var ticket = Operations.Supersede(immune: true);
        _requestedSignIn = null;
        try
        {
            await Operations.Run(ticket, async t =>
            {
                if (signIn is { } si && !IsSignedIn(si)) return;
                await PerformSignOut(t);
            });
        }
        catch (Exception) { }
    }

    /// <summary>Whether sign-in <paramref name="a"/> came after <paramref name="b"/> (generations only grow; another user is a newer sign-in only by generation).</summary>
    private static bool IsNewer(SyncSignIn a, SyncSignIn b) => a.Generation > b.Generation || (a.Generation == b.Generation && a.UserId != b.UserId);

    /// <summary>Whether the sign-out for <paramref name="signIn"/> applies: sync is signed in by it or by an older sign-in.</summary>
    private bool IsSignedIn(SyncSignIn signIn)
    {
        if (_authSignIn is { } current) return !IsNewer(current, signIn);
        if ((AuthUserId ?? Credentials?.UserId) is { } user) return user == signIn.UserId;
        return true;
    }

    /// <summary>The Clerk user sync is signed in as (null when signed out).</summary>
    public string? SignedInUserId => Actor.Read(() => AuthUserId ?? Credentials?.UserId);
    /// <summary>The app-level sign-in sync is signed in by.</summary>
    public SyncSignIn? CurrentSignIn => Actor.Read(() => AuthUserId is null ? null : _authSignIn);

    /// <summary>
    /// The identity calls are made for changed: a new session for <see cref="Identity"/>, and the live queries reopen under
    /// the new scope (results of the old one are never applied).
    /// </summary>
    private void SetIdentity(AuthScope? scope, string? userId)
    {
        Actor.AssertCurrent();
        var changed = scope != AuthScope || userId != AuthUserId;
        AuthScope = scope;
        AuthUserId = userId;
        if (!changed) return;
        _sessionVersion++;
        if (_started && Credentials is not null) OpenSubscriptions();
    }

    private async Task PerformSignOut(AccountOperations.Ticket ticket)
    {
        var keepRegistration = false;
        if (Credentials is { } credentials && SelfId is { } id)
        {
            bool removed;
            try
            {
                await WithTimeout(TimeSpan.FromSeconds(5), "The sync server",
                    ct => CallReportingCodes<ServerNowResult>("devices:remove", new DeviceArgs(credentials.Token, id), ticket, ct));
                removed = true;
            }
            catch (ConvexClientException e) when (e.Code is "unauthorized" or "notFound") { removed = true; }
            catch (Exception) { removed = false; }
            if (!removed && !SetAsideForRemoval(credentials.Token, credentials.UserId)) keepRegistration = true;
        }
        if (SavedPendingRegistration() is { } saved && saved.Token != Credentials?.Token)
        {
            var removed = false;
            if (saved.UserId == AuthUserId && saved.DeploymentUrl == Client.DeploymentUrl.AbsoluteUri)
            {
                try
                {
                    var result = await WithTimeout(TimeSpan.FromSeconds(5), "The sync server",
                        ct => CallReportingCodes<UnregisterResult>("account:unregister", new TokenArgs(saved.Token), ticket, ct));
                    removed = result.Settled;
                }
                catch (Exception) { }
            }
            if (!removed && !SetAsideForRemoval(saved.Token, saved.UserId, saved.DeploymentUrl)) keepRegistration = true;
        }
        ForgetNow(keepRegistration);
        SetIdentity(null, null);
        _authSignIn = null;
        await Client.SetAuthAsync(null);
        StopNow();
    }

    /// <summary>The user's token source changed (signed in again after the session ended). Registration is kept.</summary>
    public async Task UpdateAuthAsync(IAuthTokenProvider? auth)
    {
        await Actor.Switch();
        try
        {
            await Operations.Run(null, async ticket =>
            {
                var user = auth is null ? null : Credentials?.UserId;
                var scope = await Client.SetAuthAsync(auth, user);
                ticket.Check(Operations);
                SetIdentity(auth is null ? null : scope, user);
                if (_authSignIn?.UserId != user) _authSignIn = null;
            });
        }
        catch (Exception) { }
    }

    public async Task RenameAsync(DeviceId device, string name)
    {
        await Actor.Switch();
        await Call<ServerNowResult>("devices:rename", new RenameArgs(RequireToken(), device, name));
    }

    /// <summary>Removes a device and revokes its token. Removing this device signs it out of sync.</summary>
    public async Task RemoveAsync(DeviceId device)
    {
        await Actor.Switch();
        await Operations.Run(null, async ticket =>
        {
            var removingSelf = device == SelfId;
            try { await Call<ServerNowResult>("devices:remove", new DeviceArgs(RequireToken(), device), ticket); }
            catch (SyncException e) when (e.Kind == SyncErrorKind.UnknownDevice && removingSelf) { }
            if (removingSelf && SelfId == device) Forget();
        });
    }

    private bool Adopt(SyncCredentials fresh, int keyRevision)
    {
        var serverKey = ServerKeyId;
        EndSession();
        Credentials = fresh;
        var stored = Store.Persist(fresh);
        Registration = new Registration.Registered(fresh.DeviceId, fresh.LibraryId);
        ServerKeyId = serverKey;
        AppliedKeyRevision = keyRevision;
        SignIns.BeginSession(Scope(fresh));
        LoadLedger();
        UpdateKeyStatus();
        if (_started) OpenSubscriptions();
        UpdateActivity();
        return stored;
    }

    /// <summary>Drops the registration locally (after removal or a revoked token). Every queued operation stops (except a sign-out).</summary>
    public void Forget()
    {
        // Actor-isolated like everything else: from another thread it is posted, never run beside an operation.
        if (!Actor.IsCurrent) { Actor.Post(Forget); return; }
        Operations.Supersede();
        ForgetNow();
    }

    private void ForgetNow(bool keepRegistration = false)
    {
        EndSession();
        Credentials = null;
        if (!keepRegistration)
        {
            Store.Save(null);
            DropPendingRegistration();
        }
        _pending = null;
        Registration = Registration.NotRegistered;
        SignIns.BeginSession(null);
        LoadLedger();
        UpdateKeyStatus();
        UpdateActivity();
    }

    private void EndSession()
    {
        Actor.AssertCurrent();
        _sessionVersion++;
        CloseSubscriptions();
        LastError = null;
        Devices = [];
        Playback = new Dictionary<DeviceId, RemotePlayback>();
        Outgoing = [];
        Incoming = [];
        VaultEntries = null;
        SettingEntries = null;
        _playbackRows = [];
        SealedSettings = null;
        _wireOutgoing = [];
        ServerKeyId = null;
        _handledCommands.Clear();
        _commandQueue.Clear();
        FailedKeyBlobs.Clear();
        PendingGrantKey = null;
        RotationNeeded = false;
        AppliedKeyRevision = 0;
        PendingList = null;
        var waiters = _ackWaiters.Values.SelectMany(w => w.Values).ToList();
        _ackWaiters.Clear();
        foreach (var w in waiters) w.TrySetException(SyncException.NotPaired);
        Settings.BeginSession();
    }

    /// <summary>Which deployment, library and device local sync state belongs to.</summary>
    internal static string Scope(SyncCredentials c) => $"{c.DeploymentUrl.AbsoluteUri}|{c.LibraryId.Value}|{c.DeviceId.Value}";

    internal string RequireToken() => Credentials?.Token ?? throw SyncException.NotPaired;

    // MARK: Live queries

    private void OpenSubscriptions()
    {
        Actor.AssertCurrent();
        CloseSubscriptions();
        if (Credentials?.Token is not { } token) return;
        var args = ConvexValue.Encode(new TokenArgs(token));
        Follow<DeviceListResult>("devices:list", args, token, list => Apply(list, token));
        Follow<List<VaultEntry>>("vault:list", args, token, entries => { VaultEntries = entries; SignIns.ReconcileAll(); });
        Follow<List<SealedSettingEntry>>("settings:list", args, token, entries => { SealedSettings = entries; ApplySettings(); });
        Follow<List<PlaybackRow>>("playback:list", args, token, rows => { _playbackRows = rows; OpenPlayback(); });
        Follow<List<WireIncomingCommand>>("commands:incoming", args, token, Receive);
        Follow<List<WireOutgoingCommand>>("commands:outgoing", args, token, commands => { _wireOutgoing = commands; OpenOutgoing(); ResolveAckWaiters(); });
    }

    /// <summary>
    /// Applies each result of a live query of the session with device <paramref name="token"/>, opened under the identity
    /// scope current now, only while that session and scope are current and the subscription wasn't closed, checked on the
    /// actor right before applying it.
    /// </summary>
    private void Follow<T>(string path, ConvexValue args, string token, Action<T> apply)
    {
        var cts = new CancellationTokenSource();
        var scope = AuthScope;
        var subscription = Client.Subscribe(path, args, scope);
        _subscriptions.Add((cts, subscription));
        _ = Loop();

        async Task Loop()
        {
            AccountOperations.Current.Value = null;
            using var _ = subscription;
            try
            {
                await foreach (var result in subscription.Results.ReadAllAsync(cts.Token))
                {
                    await Actor.Switch();
                    if (cts.IsCancellationRequested) return;
                    if (Credentials?.Token != token || AuthScope != scope) continue;
                    if (result.Error is { Kind: ConvexErrorKind.AuthChanged }) continue;   // for an identity that ended
                    if (result.Error is { } error) { Report(error, token); continue; }
                    T value;
                    try { value = result.Value!.Decode<T>(); }
                    catch (Exception e) { Report(ConvexClientException.Decoding($"{path}: {e.Message}"), token); continue; }
                    apply(value);
                }
            }
            catch (OperationCanceledException) { }
        }
    }

    private void CloseSubscriptions()
    {
        // Removed from the client now, not when each loop unwinds: nothing of this session is polled under the next identity.
        foreach (var (cancel, subscription) in _subscriptions)
        {
            cancel.Cancel();
            subscription.Dispose();
        }
        _subscriptions.Clear();
    }

    /// <summary>
    /// An error from a call or a live query made with <paramref name="token"/>. Errors of a session that ended are dropped. The
    /// server no longer knowing the device signs it out, as an operation that acts only if that session is still current.
    /// </summary>
    internal void Report(Exception error, string? token)
    {
        if (error is OperationCanceledException) return;
        if (token is null || token != Credentials?.Token) return;
        var sync = SyncException.From(error);
        LastError = sync;
        if (sync.Kind != SyncErrorKind.RemovedFromLibrary) return;
        Operations.Enqueue($"removed:{token}", _ =>
        {
            if (Credentials?.Token != token) return;
            ForgetNow();
            LastError = SyncException.RemovedFromLibrary;
            Removed?.Invoke();
        });
    }

    // MARK: Commands

    /// <summary>Sends a command. A takeover's queue window is sealed for <paramref name="device"/> first (this needs the key).</summary>
    public async Task<CommandId> SendAsync(SyncCommand command, DeviceId device)
    {
        await Actor.Switch();
        var token = RequireToken();
        WireCommand wire;
        if (command.Kind == SyncCommandKind.TakeOver && command.State is { } state)
        {
            var window = new QueueWindow { Entries = state.Queue, Index = state.Index };
            wire = new WireCommand(SyncCommandKind.TakeOver, Anchor: state.Anchor, Content: SealJson(window, ContentKind.Command, device.Value));
        }
        else wire = WireCommand.Plain(command);
        var args = new SendCommandArgs(token, device, wire, Guid.NewGuid().ToString().ToUpperInvariant());
        return (await Call<SendCommandResult>("commands:send", args)).CommandId;
    }

    /// <summary>Opens the commands waiting for this device. A takeover that doesn't open here (no key yet, or sealed under
    /// another) never reaches the handler: it is acked at once with why.</summary>
    private void Receive(List<WireIncomingCommand> commands)
    {
        Actor.AssertCurrent();
        var opened = new List<IncomingCommand>();
        foreach (var wire in commands)
        {
            SyncCommand? command = wire.Command.Kind switch
            {
                SyncCommandKind.TakeOver => OpenTakeOver(wire),
                SyncCommandKind.Seek => SyncCommand.Seek(wire.Command.PositionMs ?? 0),
                SyncCommandKind.SetVolume => SyncCommand.SetVolumeTo(wire.Command.Volume ?? 0),
                var kind => new SyncCommand(kind),
            };
            if (command is not null)
            {
                opened.Add(new IncomingCommand { Id = wire.Id, FromDeviceId = wire.FromDeviceId, Command = command, CreatedAt = wire.CreatedAt, ExpiresAt = wire.ExpiresAt });
                continue;
            }
            if (_handledCommands.Contains(wire.Id)) continue;
            Remember(wire.Id);
            var reason = ContentKey is null ? CommandFailure.NeedsKey : CommandFailure.Unreadable;
            var token = Credentials?.Token;
            _ = AckUnreadable();

            async Task AckUnreadable()
            {
                AccountOperations.Current.Value = null;
                await Task.Yield();
                await Actor.Switch();
                if (token is null || Credentials?.Token != token) return;
                try { await AckAsync(wire.Id, CommandResult.Failure(reason)); } catch (Exception) { }
            }
        }
        Incoming = opened;
        ProcessIncoming();
    }

    private SyncCommand? OpenTakeOver(WireIncomingCommand wire)
    {
        if (wire.Command is not { Anchor: { } anchor, Content: { } content } || SelfId is not { } me) return null;
        if (OpenJson<QueueWindow>(content, ContentKind.Command, wire.FromDeviceId, me.Value) is not { } window
            || window.Index < 0 || window.Index >= window.Entries.Count) return null;
        return SyncCommand.TakeOver(new HandoffState { Queue = window.Entries, Index = window.Index, Anchor = anchor });
    }

    private void Remember(CommandId id)
    {
        _handledCommands.Add(id);
        if (_handledCommands.Count > 200) _handledCommands.RemoveRange(0, _handledCommands.Count - 200);
    }

    /// <summary>The outgoing list with each result opened: its sealed message, or what its reason says about the target.</summary>
    private void OpenOutgoing()
    {
        Actor.AssertCurrent();
        Outgoing = _wireOutgoing.Select(wire =>
        {
            CommandResult? result = null;
            if (wire.Result is { } r)
            {
                if (r.Ok) result = CommandResult.Success;
                else
                {
                    var reason = r.Reason ?? CommandFailure.Failed;
                    var message = r.Content is { } c ? OpenJson<ResultContent>(c, ContentKind.Result, wire.ToDeviceId, wire.Id.Value)?.Message : null;
                    var name = Devices.FirstOrDefault(d => d.Id == wire.ToDeviceId)?.Name ?? "The other device";
                    result = CommandResult.Failure(reason, message ?? reason.Message(name));
                }
            }
            return new OutgoingCommand { Id = wire.Id, ToDeviceId = wire.ToDeviceId, Kind = wire.Kind, CreatedAt = wire.CreatedAt, ExpiresAt = wire.ExpiresAt,
                                         AckedAt = wire.AckedAt, Result = result };
        }).ToList();
    }

    /// <summary>Waits until the target acks <paramref name="command"/> (seen through the live outgoing list).</summary>
    public async Task<CommandResult> WaitForAckAsync(CommandId command, TimeSpan timeout)
    {
        await Actor.Switch();
        if (Outgoing.FirstOrDefault(c => c.Id == command)?.Result is { } result) return result;
        var waiter = Guid.NewGuid();
        var tcs = new TaskCompletionSource<CommandResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_ackWaiters.TryGetValue(command, out var waiters)) _ackWaiters[command] = waiters = new();
        waiters[waiter] = tcs;
        using var cts = new CancellationTokenSource();
        _ = Task.Delay(timeout, cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            Actor.Post(() =>
            {
                if (!_ackWaiters.TryGetValue(command, out var ws) || !ws.Remove(waiter)) return;
                if (ws.Count == 0) _ackWaiters.Remove(command);
                tcs.TrySetException(SyncException.TimedOut("The other device"));
            });
        }, TaskScheduler.Default);
        try { return await tcs.Task; }
        finally { cts.Cancel(); }
    }

    private void ResolveAckWaiters()
    {
        foreach (var command in Outgoing)
        {
            if (command.Result is not { } result || !_ackWaiters.Remove(command.Id, out var waiters)) continue;
            foreach (var w in waiters.Values) w.TrySetResult(result);
        }
    }

    private void ProcessIncoming()
    {
        Actor.AssertCurrent();
        if (CommandHandler is null) return;
        var now = Clock.Now();
        foreach (var command in Incoming.Where(c => !_handledCommands.Contains(c.Id)))
        {
            Remember(command.Id);
            CommandReceived?.Invoke(command, now - command.CreatedAt);
            _commandQueue.Enqueue(command);
        }
        RunCommands();
    }

    private void RunCommands()
    {
        if (_runningCommands || _commandQueue.Count == 0) return;
        _runningCommands = true;
        _ = Loop();

        async Task Loop()
        {
            AccountOperations.Current.Value = null;
            await Task.Yield();
            while (_commandQueue.TryDequeue(out var command))
            {
                // The command came for this session; its ack goes out only while that session is current.
                var token = Credentials?.Token;
                CommandResult result;
                if (Clock.Now() > command.ExpiresAt) result = CommandResult.Failure(CommandFailure.Expired);
                else if (CommandHandler is { } handler)
                {
                    try { result = await handler(command); }
                    catch (Exception e) { result = CommandResult.Failure(CommandFailure.Failed, e.Message); }
                }
                else result = CommandResult.Failure(CommandFailure.Unavailable);
                await Actor.Switch();
                if (token is null || Credentials?.Token != token) continue;
                try { await AckAsync(command.Id, result); } catch (Exception) { }
            }
            _runningCommands = false;
        }
    }

    /// <summary>Acks a command. The server gets the outcome and a reason code; a message (it may name a song) only sealed, and
    /// only when this device holds the key; otherwise the sender shows the reason's own words.</summary>
    public async Task AckAsync(CommandId command, CommandResult result)
    {
        await Actor.Switch();
        var token = RequireToken();
        SealedContent? content = null;
        if (!result.Ok && result.Message is { } message && ContentKey is not null)
            content = SealJson(new ResultContent(message), ContentKind.Result, command.Value);
        var wire = new WireResult(result.Ok, result.EffectiveReason, content);
        await Call<ServerNowResult>("commands:ack", new AckArgs(token, command, wire));
    }

    // MARK: Playback

    /// <summary>Publishes this device's player. With <paramref name="queue"/> (it or the current index changed), what plays goes
    /// sealed; a device without the key publishes no content instead (and drops any it published under a key it no longer
    /// has). The anchor always goes.</summary>
    public async Task PublishAsync(PlaybackAnchor anchor, QueueWindow? queue)
    {
        await Actor.Switch();
        var token = RequireToken();
        PublishContent content = queue is null ? new PublishContent.Keep()
            : ContentKey is null ? new PublishContent.Drop()
            : new PublishContent.Replace(
                SealJson(new PlaybackContent(queue.Current.Track, queue.Index, queue.Entries.Count), ContentKind.Playback, ""),
                SealJson(queue, ContentKind.Queue, ""));
        await Call<PublishResult>("playback:publish", new PublishArgs(token, anchor, content));
    }

    public async Task ClearPlaybackAsync()
    {
        await Actor.Switch();
        await Call<ServerNowResult>("playback:clear", new TokenArgs(RequireToken()));
    }

    /// <summary>A device's queue window, fresh from the server. Null when it has nothing loaded.</summary>
    public async Task<QueueWindow?> FetchQueueAsync(DeviceId device)
    {
        await Actor.Switch();
        var token = Credentials?.Token;
        try
        {
            var args = ConvexValue.Encode(new DeviceArgs(RequireToken(), device));
            var scope = AuthScope;
            var value = await WithTimeout(TimeSpan.FromSeconds(15), "The sync server", ct => Client.QueryAsync("playback:queue", args, ct, scope));
            await Actor.Switch();
            // Returned only to the session that asked.
            if (Credentials?.Token != token || AuthScope != scope) throw SyncException.AuthChanged;
            if (value.IsNull) return null;
            var result = value.Decode<QueueResult>();
            if (Credentials?.LibraryKey is null) throw SyncException.NeedsKey(null);
            if (OpenJson<QueueWindow>(result.Content, ContentKind.Queue, device, "") is not { } window || window.Index < 0 || window.Index >= window.Entries.Count)
                throw SyncException.Server("That device's queue is sealed with a key this device doesn't have yet. Try again in a moment.");
            return window;
        }
        catch (Exception e)
        {
            var sync = SyncException.From(e);
            if (sync.Kind == SyncErrorKind.RemovedFromLibrary) Report(e, token);
            throw sync;
        }
    }

    /// <summary>The device list as the server has it now, outside the live query.</summary>
    internal async Task<DeviceListResult> FetchDeviceList(string token, CancellationToken cancellationToken)
    {
        Actor.AssertCurrent();
        var args = ConvexValue.Encode(new TokenArgs(token));
        var scope = AuthScope;
        var value = await WithTimeout(TimeSpan.FromSeconds(15), "The sync server", ct => Client.QueryAsync("devices:list", args, ct, scope), cancellationToken);
        await Actor.Switch();
        if (Credentials?.Token != token || AuthScope != scope) throw SyncException.AuthChanged;
        return value.Decode<DeviceListResult>();
    }

    // MARK: Vault and settings

    public async Task<VaultWrite> PutVaultAsync(ProviderId provider, string sealedText, string keyId, int baseRevision)
    {
        await Actor.Switch();
        var result = await Call<VaultWriteResult>("vault:put", new VaultPutArgs(RequireToken(), provider, sealedText, keyId, baseRevision));
        return new VaultWrite(result.UpdatedAt, result.Revision);
    }

    public async Task<VaultWrite> SignOutVaultAsync(ProviderId provider, int baseRevision)
    {
        await Actor.Switch();
        var result = await Call<VaultWriteResult>("vault:signOutEverywhere", new VaultSignOutArgs(RequireToken(), provider, baseRevision));
        return new VaultWrite(result.UpdatedAt, result.Revision);
    }

    /// <summary>Writes one setting, its value sealed under the account's key (the setting key bound in).</summary>
    public async Task<double> PutSettingAsync(string key, string value, string writeId, bool ifAbsent)
    {
        await Actor.Switch();
        var token = RequireToken();
        var sealedValue = Seal(Encoding.UTF8.GetBytes(value), ContentKind.Setting, key);
        return (await Call<UpdatedResult>("settings:put", new SettingPutArgs(token, key, sealedValue, writeId, ifAbsent ? true : null))).UpdatedAt;
    }

    // MARK: Sealed content

    /// <summary>The key this device seals content with: the vault key it holds, when it is the account's.</summary>
    internal LibraryKey? ContentKey => Credentials?.LibraryKey is { } key && key.Id == ServerKeyId ? key : null;

    public bool CanSealContent => Actor.Read(() => ContentKey is not null);

    /// <summary>Seals what this device writes (it is the writer).</summary>
    internal SealedContent Seal(byte[] plaintext, ContentKind kind, string context)
    {
        if (ContentKey is not { } key || Credentials is not { } credentials || SelfId is not { } me) throw SyncException.NeedsKey(null);
        return ContentSealing.Seal(plaintext, kind, credentials.LibraryId, me, context, key);
    }

    internal SealedContent SealJson<T>(T value, ContentKind kind, string context) =>
        Seal(JsonSerializer.SerializeToUtf8Bytes(value, Wire.Options), kind, context);

    /// <summary>Opens what <paramref name="writer"/> wrote with the key this device holds; null when it isn't under it or doesn't open.</summary>
    internal T? OpenJson<T>(SealedContent sealedContent, ContentKind kind, DeviceId writer, string context) where T : class =>
        Credentials is { LibraryKey: { } key } credentials ? ContentSealing.TryOpenJson<T>(sealedContent, kind, credentials.LibraryId, writer, context, key) : null;

    /// <summary>The key rows are opened with, or the one this device seals with, changed: open everything again, and let the
    /// coordinator publish its queue under the new key (or with no content).</summary>
    private void ContentKeysChanged()
    {
        Actor.AssertCurrent();
        var opening = Credentials?.LibraryKey?.Id;
        var sealing = ContentKey?.Id;
        if (opening == _openingKeyMark && sealing == _sealingKeyMark) return;
        var sealingChanged = sealing != _sealingKeyMark;
        _openingKeyMark = opening;
        _sealingKeyMark = sealing;
        OpenPlayback();
        ApplySettings();
        OpenOutgoing();
        if (sealingChanged) ContentKeyChanged?.Invoke();
    }

    private void OpenPlayback()
    {
        Actor.AssertCurrent();
        var rows = new Dictionary<DeviceId, RemotePlayback>();
        foreach (var row in _playbackRows)
        {
            if (rows.ContainsKey(row.DeviceId)) continue;
            var opened = new RemotePlayback
            {
                DeviceId = row.DeviceId, QueueVersion = row.QueueVersion, Anchor = row.Anchor, UpdatedAt = row.UpdatedAt,
                Content = row.Content is null ? PlaybackContentState.None : PlaybackContentState.Sealed,
            };
            if (row.Content is { } sealedContent && OpenJson<PlaybackContent>(sealedContent, ContentKind.Playback, row.DeviceId, "") is { } now)
                opened = opened with { Track = now.Track, Index = now.Index, QueueLength = now.QueueLength, Content = PlaybackContentState.Open };
            rows[row.DeviceId] = opened;
        }
        Playback = rows;
    }

    /// <summary>Hands the settings that open here to <see cref="SettingsSync"/>. Nothing until this device can seal with the
    /// account's key (<see cref="ContentKey"/>, not just a saved key: at launch the saved key is known before the server's
    /// keyId arrives, and a first sync then would try fill-ins it can't seal and lose them).</summary>
    internal void ApplySettings()
    {
        Actor.AssertCurrent();
        if (SealedSettings is not { } sealedRows || ContentKey is not { } key || Credentials is not { } credentials)
        {
            SettingEntries = null;
            return;
        }
        var opened = new List<SettingEntry>();
        foreach (var row in sealedRows)
        {
            byte[]? data;
            try { data = ContentSealing.Open(row.Value, ContentKind.Setting, credentials.LibraryId, new DeviceId(row.UpdatedBy), row.Key, key); }
            catch (ContentSealingException) { data = null; }
            if (data is not null) opened.Add(new SettingEntry(row.Key, Encoding.UTF8.GetString(data), row.UpdatedAt, row.UpdatedBy, row.WriteId));
        }
        SettingEntries = opened;
        Settings.Apply(opened, sealedRows.Select(r => r.Key).ToHashSet());
    }

    // MARK: Calls

    /// <summary>A call with the server's errors mapped: conflict to <see cref="SyncConflictException"/>, the rest to <see cref="SyncException"/>.</summary>
    internal async Task<T> Call<T>(string path, object args, AccountOperations.Ticket? ticket = null) where T : IServerTimed
    {
        var token = Credentials?.Token;
        try
        {
            return await CallReportingCodes<T>(path, args, ticket);
        }
        catch (OperationCanceledException) { throw; }
        catch (ConvexClientException e) when (e.Code == "conflict")
        {
            throw new SyncConflictException(e.ErrorData?["revision"]?.DoubleValue is { } r ? (int)r : null);
        }
        catch (Exception e)
        {
            var sync = SyncException.From(e);
            if (sync.Kind == SyncErrorKind.RemovedFromLibrary) Report(e, token);
            throw sync;
        }
    }

    /// <summary>
    /// A call with the server's error as it came. It belongs to the identity and the account epoch current when it is made,
    /// both captured before the first await: the client refuses it (AuthChanged) if the identity changed before it was sent,
    /// and an answer that arrives after the account moved on is not returned (<see cref="OperationCanceledException"/>).
    /// </summary>
    internal async Task<T> CallReportingCodes<T>(string path, object args, AccountOperations.Ticket? ticket, CancellationToken extra = default) where T : IServerTimed
    {
        Actor.AssertCurrent();
        var scope = AuthScope;
        var epoch = Operations.Epoch;
        var session = _sessionVersion;
        void Check()
        {
            if (ticket is { } t) t.Check(Operations);
            else if (epoch != Operations.Epoch) throw new OperationCanceledException();
            // The session it was made in ended (another registration or identity): its answer is nobody's now.
            if (ticket is not { Immune: true } && session != _sessionVersion) throw new OperationCanceledException();
        }
        if (!_started)
        {
            // Work queued before a stop never starts the connection again under that stop.
            if (_stopped) throw ConvexClientException.Stopped();
            Start();
        }
        Client.Start();
        Check();
        try
        {
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(ticket?.Token ?? CancellationToken.None, extra);
            Timed<ConvexValue> timed;
            try
            {
                timed = await Client.MutationAsync(path, ConvexValue.Encode(args), scope, linked.Token);
            }
            catch (Exception)
            {
                Check();
                throw;
            }
            Check();
            T value;
            try { value = timed.Value.Decode<T>(); }
            catch (Exception e) when (e is JsonException or ConvexValueException or InvalidOperationException) { throw ConvexClientException.Decoding($"{path}: {e.Message}"); }
            Clock.Record(value.ServerNow, timed.SentAt, timed.ReceivedAt);
            return value;
        }
        finally
        {
            if (!IsAwake) ArmSuspend();
        }
    }

    /// <summary>Runs <paramref name="operation"/>, throwing TimedOut(<paramref name="what"/>) if it takes longer than <paramref name="timeout"/>.</summary>
    internal static async Task<T> WithTimeout<T>(TimeSpan timeout, string what, Func<CancellationToken, Task<T>> operation, CancellationToken outer = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(outer);
        var task = operation(cts.Token);
        var delay = Task.Delay(timeout, cts.Token);
        var first = await Task.WhenAny(task, delay);
        if (first == task) { cts.Cancel(); return await task; }
        cts.Cancel();
        _ = task.ContinueWith(t => _ = t.Exception, TaskScheduler.Default);
        outer.ThrowIfCancellationRequested();
        throw SyncException.TimedOut(what);
    }
}

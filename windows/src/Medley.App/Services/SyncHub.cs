using System.ComponentModel;
using Medley.Core;
using Medley.Core.Sync;
using Medley.Providers.YouTube;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.Sync;
using Medley.Sync;
using Medley.Sync.Account;
using Medley.Sync.Keys;

namespace Medley.App.Services;

/// <summary>
/// Medley Sync on Windows (the Mac's <c>SyncHub</c>): the Medley account (<see cref="AccountService"/>, Clerk against the
/// chosen server), <see cref="SyncService"/> for this PC, the <see cref="SyncCoordinator"/> on the one player, the YouTube
/// Music sign-in transfer, and synced settings (autoplay, volume levelling, recent searches).
/// <para>Threading: the <see cref="SyncActor"/> runs on the UI thread's SynchronizationContext, so every sync callback,
/// property change and event below arrives on the UI thread, as do the player and the provider's property changes. The
/// YouTube provider does its own account work on its serial executor and resumes awaiting callers here.</para>
/// </summary>
public sealed class SyncHub : INotifyPropertyChanged
{
    /// <summary>Debug builds and probes use the dev deployment; Release builds the production one. <c>OPENMUSIC_SYNC_URL</c> overrides both.</summary>
    public static Uri HostedUrl { get; } = Environment.GetEnvironmentVariable("OPENMUSIC_SYNC_URL") is { Length: > 0 } env && Uri.TryCreate(env, UriKind.Absolute, out var u)
        ? u
#if DEBUG
        : SyncService.DefaultDeploymentUrl;
#else
        : SyncService.ProductionDeploymentUrl;
#endif

    private readonly AppServices _app;
    private readonly SyncCredentialStore _store;
    private bool _applyingSetting;
    private bool _started;
    private readonly HashSet<DeviceId> _dismissedRequests = [];

    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>A message for the shell's InfoBar: text, and whether it's a problem.</summary>
    public event Action<string, bool>? Notice;
    /// <summary>Another device asks for this PC's sign-in key (holder side). Raised once per request.</summary>
    public event Action<KeyRequest>? KeyRequested;
    /// <summary>This PC is the new device and has a code to compare.</summary>
    public event Action<KeyComparison>? CompareRequested;

    public SyncActor Actor { get; }
    public AccountService Account { get; }
    public SyncService Service { get; }
    public SyncCoordinator Coordinator { get; }
    public YouTubeMusicSignInTransfer? YouTubeTransfer { get; }

    /// <summary>Why this PC isn't syncing although the account is signed in (offline, rate limited).</summary>
    public string? ConnectFailure { get; private set; }

    public SyncHub(AppServices app)
    {
        _app = app;
        Actor = new SyncActor(SynchronizationContext.Current ?? throw new InvalidOperationException("SyncHub needs the UI thread."));
        _store = new SyncCredentialStore(app.Secrets);
        Account = new AccountService(HostedUrl, new CredentialClerkStateStore(_store), Actor,
            new FileAccountPreferences(Path.Combine(AppServices.DataDirectory, "server.json")));
        var name = (app.Options.DeviceName ?? app.Settings.Values.DeviceName ?? Environment.MachineName).Trim();
        var info = new DeviceInfo(name.Length == 0 ? "Windows PC" : name[..Math.Min(64, name.Length)], DevicePlatform.Windows,
            $"Windows {Environment.OSVersion.Version.Build} {System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}".ToLowerInvariant().Replace("windows", "Windows"),
            typeof(SyncHub).Assembly.GetName().Version?.ToString(3) ?? "0.1.0");
        Service = new SyncService(Account.Server.Url, info, _store, Actor);
        Coordinator = new SyncCoordinator(Service, new AppSyncPlayer(app.Player), Actor);
        if (app.YouTube is { } youtube)
        {
            YouTubeMusicSignInTransfer.Verifier? verify = null;
#if DEBUG
            if (app.Options.TestSignIns) verify = AcceptTestSignIns;
#endif
            YouTubeTransfer = new YouTubeMusicSignInTransfer(youtube, new DpapiTransferStore(app.Secrets), verify);
        }
    }

#if DEBUG
    /// <summary>Debug builds with <c>--test-sign-ins</c>: the probe's fake YouTube sign-ins (cookie MEDLEY_TEST_SIGNIN) are
    /// taken as their claimed account without asking Google, so the vault can be tested without a Google account.
    /// Real sign-ins are still checked with YouTube.</summary>
    private static Task<AccountInfo> AcceptTestSignIns(YouTubeMusicCredentials creds, AccountInfo? claimed, CancellationToken ct) =>
        creds.Cookies.ContainsKey(YouTubeMusicSignInPayload.TestCookie)
            ? Task.FromResult((claimed ?? new AccountInfo("Test", detail: "Test sign-in")) with { Detail = "Test sign-in" })
            : YouTubeMusicSignInTransfer.CheckWithYouTube(creds, claimed, ct);
#endif

    private void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // MARK: Start

    public void Start()
    {
        if (_started) return;
        _started = true;
        Account.PropertyChanged += (_, e) => Raise(nameof(Account));
        Account.Ready += () =>
        {
            if (Account.IsSignedIn) _ = ConnectAsync();
        };
        Account.SessionEnded += SessionEnded;
        Service.Removed += RemovedElsewhere;
        Service.PropertyChanged += Service_PropertyChanged;
        Service.CommandReceived += (c, ms) => Log.Info($"sync: command {c.Command.Kind} from {DeviceName(c.FromDeviceId)}, {ms:F0} ms after it was sent");
        Service.SignIns.Imported += i => Log.Info($"sync: {i.Provider.RawValue()} sign-in {(i.SignedOut ? "signed out everywhere" : $"imported ({i.Bytes} bytes)")}, {i.LatencyMs:F0} ms after it was written");
        Coordinator.PropertyChanged += (_, e) => Raise(e.PropertyName == nameof(SyncCoordinator.ContinueSuggestion) ? nameof(ContinueSuggestion) : nameof(Coordinator));
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            await Coordinator.AttachAsync();
            if (YouTubeTransfer is { } transfer) await Service.SignIns.RegisterAsync(new YouTubeTransferAdapter(transfer));
            await ObserveSettingsAsync();
            await Account.LoadAsync();
            Log.Info($"sync: account {(Account.IsSignedIn ? "signed in" : "signed out")}, server {(Account.Server.IsCustom ? "custom" : "hosted")}");
            if (Account.IsSignedIn) await ConnectAsync();
        }
        catch (Exception e)
        {
            Log.Error("sync start", e);
        }
    }

    /// <summary>Signs this PC in to sync as the signed-in Medley account.</summary>
    public async Task ConnectAsync()
    {
        if (!Account.IsSignedIn) return;
        try
        {
            // The account decides who sync signs in as and starts it in one step on the actor (identity tickets).
            await Account.StartSyncAsync(Service);
            ConnectFailure = null;
            Log.Info($"sync: registered as {Service.SelfId?.Value ?? "?"}, key {Describe(Service.KeyStatus)}");
        }
        catch (Exception e) when (e is OperationCanceledException || e is ClerkException { Kind: ClerkErrorKind.Stale } || e is SyncException { Kind: SyncErrorKind.AuthChanged })
        {
            // A sign-out, a newer sign-in or a server change overtook this one; it changed nothing.
            Log.Info($"sync: sign-in to sync superseded ({e.GetType().Name})");
        }
        catch (Exception e)
        {
            ConnectFailure = e.Message;
            Log.Error($"sync: sign-in to sync failed: {e.Message}");
            Notice?.Invoke($"Couldn't connect to {ProductInfo.Name} Sync. {e.Message}", true);
        }
        Raise(nameof(ConnectFailure));
    }

    /// <summary>After a sign-in (the first run or the sign-in dialog): connect; the first run counts as done.</summary>
    public async Task DidSignInAsync()
    {
        _app.Settings.Values.WelcomeDone = true;
        _app.Settings.Save();
        await ConnectAsync();
        Notice?.Invoke($"Signed in as {Account.User?.DisplayName ?? "you"}", false);
    }

    /// <summary>Settings › Account › Sign Out: removes this PC from the account's devices, then ends the Clerk session.
    /// This PC's own YouTube Music sign-in stays.</summary>
    public async Task SignOutAsync()
    {
        try
        {
            await Account.SignOutAsync(Service);
            _dismissedRequests.Clear();
            Log.Info("sync: signed out of the account");
        }
        catch (Exception e)
        {
            Notice?.Invoke($"Couldn't sign out of {ProductInfo.Name}. {e.Message}", true);
        }
    }

    /// <summary>Whether syncing through <paramref name="url"/> (null: the hosted server) needs a restart: this PC's sync
    /// service is bound to the server it started with.</summary>
    public bool NeedsRestartToUse(Uri? url) => (url ?? HostedUrl) != Service.Client.DeploymentUrl;

    /// <summary>Switches servers (null: OpenMusic's). Sync starts over against the new one, which needs a restart when the
    /// server differs from the one this PC's sync started with. <paramref name="quiet"/>: no notice (the first run says it).</summary>
    public async Task SwitchServerAsync(Uri? url, bool quiet = false)
    {
        await SignOutAsync();
        await Account.SetServerAsync(url);
        if (quiet) return;
        var where = url is null ? $"{ProductInfo.Name}'s server" : url.Host;
        Notice?.Invoke(NeedsRestartToUse(url) ? $"Using {where}. Restart {ProductInfo.Name} to finish switching." : $"Using {where}.", false);
    }

    private async void RemovedElsewhere()
    {
        Log.Info("sync: this PC was removed from the account's devices");
        // The sign-in this removal happened under: a sign-in after it (the same user again included) is left alone.
        var signIn = Service.CurrentSignIn;
        try
        {
            var session = await Account.CurrentSessionAsync();
            if (Account.IsCurrent(session) && (signIn is null || session.SignIn == signIn)) await Account.SignOutAsync(session);
            await Service.SignOutAsync(signIn);
        }
        catch (Exception e)
        {
            Log.Error("sync sign-out after removal", e);
        }
        Notice?.Invoke("This PC was removed from your devices", true);
    }

    private async void SessionEnded()
    {
        Log.Info("sync: the Clerk session ended");
        var signIn = Account.EndedSignIn;
        try { await Service.SignOutAsync(signIn); } catch (Exception e) { Log.Error("sync sign-out after session end", e); }
        Notice?.Invoke($"You were signed out of {ProductInfo.Name}", true);
    }

    // MARK: Keys

    private string _lastKey = "";
    private string _lastDevices = "";

    private void Service_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        var key = Describe(Service.KeyStatus);
        if (key != _lastKey)
        {
            _lastKey = key;
            Log.Info($"sync: key {key}");
            if (Service.KeyStatus is KeyStatus.Comparing c && !c.Comparison.Confirmed) CompareRequested?.Invoke(c.Comparison);
        }
        var devices = string.Join(", ", Service.Devices.Select(d => $"{d.Name}{(d.Id == Service.SelfId ? "*" : "")}[{d.KeyState?.ToString().ToLowerInvariant()}]"));
        if (devices != _lastDevices)
        {
            _lastDevices = devices;
            Log.Info($"sync: devices {devices}");
        }
        foreach (var request in Service.KeyRequests)
        {
            if (!_dismissedRequests.Add(request.Id)) continue;
            Log.Info($"sync: key request from {request.Device.Name}, code {request.Code}");
            KeyRequested?.Invoke(request);
        }
        Raise(nameof(Service));
    }

    /// <summary>The holder's "Allow": wraps the sign-in key to that device.</summary>
    public async Task AllowKeyAsync(KeyRequest request)
    {
        try
        {
            await Service.AllowKeyAsync(request);
            Log.Info($"sync: allowed {request.Device.Name} (code {request.Code})");
            Notice?.Invoke($"{request.Device.Name} can now use your sign-ins", false);
        }
        catch (Exception e)
        {
            Notice?.Invoke($"Couldn't share your sign-ins with {request.Device.Name}. {e.Message}", true);
        }
    }

    public async Task DenyKeyAsync(KeyRequest request)
    {
        try { await Service.DenyKeyAsync(request); }
        catch (Exception e) { Notice?.Invoke(e.Message, true); }
        Log.Info($"sync: denied {request.Device.Name}");
    }

    /// <summary>Requests the user closed without answering come back with Ask Again (the other device asks again).</summary>
    public void ForgetDismissedRequests() => _dismissedRequests.Clear();

    public static string Describe(KeyStatus status) => status switch
    {
        KeyStatus.Comparing c => $"comparing {c.Comparison.Code} with {c.Comparison.HolderName} (allowed {c.Comparison.Allowed}, confirmed {c.Comparison.Confirmed})",
        KeyStatus.Failed f => $"failed: {f.Message}",
        _ => status.GetType().Name.ToLowerInvariant(),
    };

    // MARK: Handoff

    public ContinueSuggestion? ContinueSuggestion => Coordinator.ContinueSuggestion;

    public string DeviceName(DeviceId id) => Service.Devices.FirstOrDefault(d => d.Id == id)?.Name ?? "another device";

    /// <summary>Play Here didn't start: the device and the song (null when sealed). The shell offers Try Again.</summary>
    public event Action<DeviceId, string?, SyncException>? PlayHereFailed;

    /// <summary>The device's playback row says it's playing (judged now, from the last row the server sent).</summary>
    public bool IsPlayingOn(DeviceId device) => Service.Playback.GetValueOrDefault(device)?.Anchor.IsPlaying == true;

    public async Task PlayHereAsync(DeviceId device)
    {
        try
        {
            await Coordinator.PlayHereAsync(device);
            if (Coordinator.LastHandoff is { } h)
                Log.Info($"sync: pulled from {DeviceName(device)}: queue {h.FetchMs:F0} ms, cued {h.ReadyMs:F0} ms, playing {h.TotalMs:F0} ms, position delta {h.PositionDeltaMs:F0} ms");
        }
        catch (Exception e)
        {
            Log.Error($"sync: play here failed: {e.Message}");
            var title = Service.Playback.GetValueOrDefault(device)?.Track?.Title;
            if (PlayHereFailed is { } failed) failed(device, title, SyncException.From(e));
            else Notice?.Invoke($"Couldn't play from {DeviceName(device)}. {e.Message}", true);
        }
    }

    public async Task SendToAsync(DeviceId device)
    {
        try
        {
            await Coordinator.SendToAsync(device);
            if (Coordinator.LastHandoff is { } h)
                Log.Info($"sync: pushed to {DeviceName(device)}: sent {h.FetchMs:F0} ms, playing there {h.ReadyMs:F0} ms, paused here {h.TotalMs:F0} ms");
        }
        catch (Exception e)
        {
            Log.Error($"sync: send failed: {e.Message}");
            Notice?.Invoke($"Couldn't play on {DeviceName(device)}. {e.Message}", true);
        }
    }

    public async Task RemoteAsync(DeviceId device, Func<RemoteControl, Task<CommandId>> action, string what)
    {
        try
        {
            var id = await action(Coordinator.Remote(device));
            var result = await Service.WaitForAckAsync(id, TimeSpan.FromSeconds(20));
            Log.Info($"sync: remote {what} to {DeviceName(device)}: ok {result.Ok}");
            if (!result.Ok) Notice?.Invoke($"{DeviceName(device)} couldn't {what}. {result.Message}", true);
        }
        catch (Exception e)
        {
            Notice?.Invoke($"Couldn't reach {DeviceName(device)}. {e.Message}", true);
        }
    }

    // MARK: Settings

    /// <summary>Autoplay, volume levelling, crossfade and recent searches follow the account: what another device sets
    /// applies here, what changes here is uploaded (debounced by SettingsSync).</summary>
    private async Task ObserveSettingsAsync()
    {
        var player = _app.Player;
        var settings = Service.Settings;
        await settings.ObserveAsync(SettingKeys.Autoplay, () => SettingsSync.Json(player.Autoplay), text => Apply(() => player.Autoplay = Parse(text, player.Autoplay)));
        await settings.ObserveAsync(SettingKeys.NormalizeVolume, () => SettingsSync.Json(player.NormalizationEnabled), text => Apply(() => player.NormalizationEnabled = Parse(text, player.NormalizationEnabled)));
        await settings.ObserveAsync(SettingKeys.CrossfadeSeconds, () => SettingsSync.Json(player.CrossfadeDuration), text => Apply(() =>
        {
            if (double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v)) player.CrossfadeDuration = v;
        }));
        await settings.ObserveAsync(SettingKeys.RecentSearches, () => SettingsSync.Json(_app.Settings.Values.RecentSearches), text => Apply(() =>
        {
            try
            {
                if (System.Text.Json.JsonSerializer.Deserialize(text, Medley.Core.Support.MedleyJsonContext.Default.ListString) is { } list) _app.Settings.ReplaceRecentSearches(list);
            }
            catch (System.Text.Json.JsonException) { }
        }));
        player.PropertyChanged += (_, e) =>
        {
            if (_applyingSetting) return;
            switch (e.PropertyName)
            {
                case nameof(PlayerController.Autoplay): _ = settings.SetAsync(SettingKeys.Autoplay, player.Autoplay); break;
                case nameof(PlayerController.NormalizationEnabled): _ = settings.SetAsync(SettingKeys.NormalizeVolume, player.NormalizationEnabled); break;
                case nameof(PlayerController.CrossfadeDuration): _ = settings.SetAsync(SettingKeys.CrossfadeSeconds, player.CrossfadeDuration); break;
            }
        };
        _app.Settings.RecentSearchesChanged += () =>
        {
            if (!_applyingSetting) _ = settings.SetAsync(SettingKeys.RecentSearches, _app.Settings.Values.RecentSearches.ToList());
        };
        settings.Applied += (key, value, latency) => Log.Info($"sync: setting {key} arrived, {latency:F0} ms after it was written");
    }

    private void Apply(Action apply)
    {
        _applyingSetting = true;
        try { apply(); }
        finally { _applyingSetting = false; }
    }

    private static bool Parse(string text, bool fallback) => text switch { "true" => true, "false" => false, _ => fallback };

    /// <summary>The YouTube sign-in out of this PC: here only, or (with sync and the key) on every device.</summary>
    public async Task SignOutOfYouTubeAsync(bool everywhere)
    {
        if (Service.IsRegistered) await Service.SignIns.SignOutAsync(ProviderId.YouTubeMusic, everywhere);
        else if (_app.YouTube is { } youtube) await youtube.TrySignOutAsync();
    }

    /// <summary>This PC holds the vault key: it can open what other devices play and take it over.</summary>
    public bool HasKey => Service.KeyStatus is KeyStatus.Available;

    public bool CanSignOutEverywhere => Service.IsRegistered && Service.KeyStatus is KeyStatus.Available;
}

/// <summary>The coordinator's player: the app's <see cref="PlayerController"/>, where YouTube Music plays with or without
/// a sign-in (as on the Mac), so a pull handoff of YouTube songs works on a PC that isn't signed in to YouTube.</summary>
internal sealed class AppSyncPlayer(PlayerController player) : ISyncPlayer
{
    private readonly PlayerControllerAdapter _inner = new(player);

    public IReadOnlyList<QueueEntry> Queue => _inner.Queue;
    public int? CurrentIndex => _inner.CurrentIndex;
    public QueueEntry? CurrentEntry => _inner.CurrentEntry;
    public SyncPlayerState State => _inner.State;
    public double CurrentTime => _inner.CurrentTime;
    public double? Duration => _inner.Duration;
    public double Volume { get => _inner.Volume; set => _inner.Volume = value; }
    public bool Shuffle => _inner.Shuffle;
    public RepeatMode RepeatMode => _inner.RepeatMode;
    public bool IsPlaying => _inner.IsPlaying;
    public string? LastError => _inner.LastError;
    public bool CanPlay(ProviderId provider) => provider == ProviderId.YouTubeMusic ? player.Provider(provider) is not null : _inner.CanPlay(provider);
    public void Load(IReadOnlyList<QueueEntry> queue, int index, double position, bool shuffle, RepeatMode repeatMode, bool autoplay) =>
        _inner.Load(queue, index, position, shuffle, repeatMode, autoplay);
    public void Resume() => _inner.Resume();
    public void Pause() => _inner.Pause();
    public void TogglePlayPause() => _inner.TogglePlayPause();
    public void Next() => _inner.Next();
    public void Previous() => _inner.Previous();
    public void Stop() => _inner.Stop();
    public void Seek(double seconds) => _inner.Seek(seconds);
    public event Action? Changed { add => _inner.Changed += value; remove => _inner.Changed -= value; }
}

/// <summary>Medley.Sync's view of the YouTube provider's sign-in transfer (the provider doesn't reference Medley.Sync).</summary>
internal sealed class YouTubeTransferAdapter(YouTubeMusicSignInTransfer inner) : ISignInTransfer
{
    public ProviderId Provider => ProviderId.YouTubeMusic;
    public Task<byte[]?> ExportSignInAsync() => inner.ExportSignInAsync();
    public Task ImportSignInAsync(byte[] data) => inner.ImportSignInAsync(data);
    public Task SignOutAsync() => inner.SignOutAsync();
    public Action? SignInDidChange { get => inner.SignInDidChange; set => inner.SignInDidChange = value; }
}

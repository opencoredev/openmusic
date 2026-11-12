using Medley.App.ViewModels;
using Medley.Core;
using Medley.Core.Mock;
using Medley.Core.Support;
using Medley.Providers.YouTube;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.Playback;
using Microsoft.UI.Dispatching;

namespace Medley.App.Services;

/// <summary>
/// The app's long-lived objects, created once at launch on the UI thread: the provider, the player and its MediaPlayer
/// engine, queue persistence, lyrics, the browse caches, settings, Medley Sync and the view models the shell shares.
/// Pages reach it through <see cref="App.Services"/>.
/// <para>Normal runs use YouTube Music (<see cref="YouTube"/>), its sign-in saved with DPAPI. <c>--demo</c> and
/// <c>--snapshot</c> run on the mock catalog instead (<see cref="Mock"/>), with no network, sign-in or sync.</para>
/// </summary>
public sealed class AppServices
{
    public static string DataDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), ProductInfo.FolderName);

    public AppOptions Options { get; }
    public DispatcherQueue Dispatcher { get; }
    public AppSettings Settings { get; }
    public bool IsDemo => Options.IsDemo;
    /// <summary>The music service everything browses and plays: YouTube Music, or the mock in demo runs.</summary>
    public IMusicProvider Provider { get; }
    public MockProvider? Mock { get; }
    public YouTubeMusicProvider? YouTube { get; }
    public PlayerController Player { get; }
    public MediaPlaybackEngine Engine { get; }
    public QueuePersistence? Persistence { get; }
    public LyricsService Lyrics { get; }
    public BrowseCache Cache { get; } = new();
    public BrowseDiskCache DiskCache { get; } = new(Path.Combine(DataDirectory, "cache", "browse"));
    public PlayerViewModel PlayerViewModel { get; }
    public UndoStack Undo { get; } = new();
    public DpapiSecretStore Secrets { get; } = new(Dpapi.SecretsDirectory);
    /// <summary>Medley Sync, when this isn't a demo run. Created in <see cref="StartAsync"/>.</summary>
    public SyncHub? Sync { get; private set; }

    /// <summary>The account requests are sent as changed (sign-in, sign-out, a switch, a synced sign-in arriving). Raised
    /// on the UI thread after the caches were emptied.</summary>
    public event Action? SessionChanged;

    /// <summary>Bumped on every account change; cached pages compare it to know their content is another account's.</summary>
    public int SessionVersion { get; private set; }

    private SessionIdentity _identity;

    public AppServices(AppOptions options, DispatcherQueue dispatcher)
    {
        Options = options;
        Dispatcher = dispatcher;
        Settings = new AppSettings(Path.Combine(DataDirectory, options.IsDemo ? "settings-demo.json" : "settings.json"));
        Player = new PlayerController();
        if (options.IsDemo)
        {
            MockArtwork.DemoDirectory = options.DemoArtDirectory;
            Engine = new MediaPlaybackEngine(new MockAudioResolver(options.MockAudioUrl), dispatcher);
            Mock = new MockProvider(ProviderId.YouTubeMusic, dataset: options.Dataset, engine: Engine);
            Provider = Mock;
        }
        else
        {
            MediaPlaybackEngine? engine = null;
            YouTube = new YouTubeMusicProvider(new YouTubeMusicProviderOptions
            {
                Store = new ProtectedFileCredentialStore(Dpapi.SecretsDirectory, new DpapiProtector()),
                PlaybackEngineFactory = resolver => engine = new MediaPlaybackEngine(resolver, dispatcher),
                ClearWebSignIn = YouTubeSignInWindow.ClearWebProfileAsync,
                StreamPreference = Settings.Values.StreamPreference == "hls" ? StreamPreference.Hls : StreamPreference.Direct,
            });
            Engine = engine ?? throw new InvalidOperationException("The YouTube provider didn't make its engine.");
            Provider = YouTube;
        }
        Player.Register(Provider);
        Player.Autoplay = Settings.Values.Autoplay;
        Player.NormalizationEnabled = Settings.Values.Normalize;
        Player.Volume = (float)Math.Clamp(Settings.Values.Volume, 0, 1);
        Lyrics = new LyricsService(Player);
        if (!options.NoRestore)
            Persistence = new QueuePersistence(Player, new QueueStore(Path.Combine(DataDirectory, options.IsDemo ? "queue-demo.json" : "queue.json")));
        PlayerViewModel = new PlayerViewModel(Player, Lyrics);
        _identity = Provider.Session.Identity;
        Provider.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(IMusicProvider.Session) or nameof(IMusicProvider.AuthStatus)) OnSessionMaybeChanged();
        };
        Player.PropertyChanged += (_, e) =>
        {
            switch (e.PropertyName)
            {
                case nameof(PlayerController.Autoplay):
                    Settings.Values.Autoplay = Player.Autoplay;
                    Settings.Save();
                    break;
                case nameof(PlayerController.Volume):
                    Settings.Values.Volume = Player.Volume;
                    Settings.Save();
                    break;
                case nameof(PlayerController.NormalizationEnabled):
                    Settings.Values.Normalize = Player.NormalizationEnabled;
                    Settings.Save();
                    break;
            }
        };
        LogPlayback();
    }

    private void OnSessionMaybeChanged()
    {
        var session = Provider.Session;
        if (session.Identity == _identity) return;
        var settled = session.Identity.Kind != SessionIdentityKind.Changing;
        Log.Info($"session: {_identity.Kind} -> {session.Identity.Kind}");
        _identity = session.Identity;
        Cache.Clear();
        SessionVersion++;
        if (settled) _ = Task.Run(() => DiskCache.Retain(Provider.Id, session));
        SessionChanged?.Invoke();
    }

    /// <summary>State changes, errors and (while playing) the position every 5 s go to the log, so playback can be
    /// checked over SSH where nobody can listen.</summary>
    private void LogPlayback()
    {
        var lastLogged = DateTime.MinValue;
        Player.PropertyChanged += (_, e) =>
        {
            switch (e.PropertyName)
            {
                case nameof(PlayerController.State):
                    Log.Info($"player: {Player.State} {Player.Current?.Title} at {Player.CurrentTime:0.0}s");
                    break;
                case nameof(PlayerController.LastError) when Player.LastError is { } error:
                    Log.Error($"player: {error}");
                    break;
                case nameof(PlayerController.CurrentTime) when Player.IsPlaying && DateTime.UtcNow - lastLogged > TimeSpan.FromSeconds(5):
                    lastLogged = DateTime.UtcNow;
                    Log.Info($"player: position {Player.CurrentTime:0.00}s engine {Engine.Player.PlaybackSession.Position.TotalSeconds:0.00}s of {Player.Duration:0}s ({Player.Current?.Title})");
                    break;
            }
        };
    }

    /// <summary>
    /// Restores the saved sign-in (its first, local step: the network check runs on behind it) and the saved queue
    /// (paused, nothing loaded), then starts Medley Sync. In demo runs, cues the demo song instead.
    /// </summary>
    public async Task StartAsync()
    {
        if (YouTube is { } youtube)
        {
            var restore = youtube.RestoreSessionAsync();
            _ = restore.ContinueWith(t => Log.Error("restore sign-in", t.Exception!), TaskContinuationOptions.OnlyOnFaulted);
            // Wait for the saved cookies to be installed (or a quarter second at most), so the first Home request and the
            // disk cache use the right account. The check with YouTube keeps running.
            if (File.Exists(Path.Combine(Dpapi.SecretsDirectory, ProtectedFileCredentialStore.CredentialsFile)))
            {
                var deadline = DateTime.UtcNow + TimeSpan.FromMilliseconds(250);
                while (youtube.CurrentCredentials is null && !restore.IsCompleted && DateTime.UtcNow < deadline) await Task.Delay(10);
            }
            _identity = Provider.Session.Identity;
        }
        var restored = false;
        try
        {
            restored = Persistence is not null && await Persistence.RestoreAsync();
        }
        catch (Exception e)
        {
            // A queue that can't be put back must never keep the window from opening.
            Log.Error("restore", e);
        }
        if (Mock is { } mock)
        {
            if (!restored && mock.DemoNowPlaying is { } demo)
            {
                var entries = demo.Tracks.Select(t => new QueueEntry(t, context: PlaybackContext.ForAlbum(demo.Album))).ToList();
                Player.Load(entries, demo.Index, Options.Position ?? demo.Position, shuffle: false, RepeatMode.Off, autoplay: Options.Play);
            }
            else if (!restored)
            {
                var tracks = mock.SampleTracks(12);
                Player.Load(tracks.Select(t => new QueueEntry(t)).ToList(), 0, 0, false, RepeatMode.Off, Options.Play);
            }
            else if (Options.Play)
            {
                Player.Resume();
            }
        }
        else if (restored && Options.Play)
        {
            Player.Resume();
        }
        Persistence?.Start();
        if (!IsDemo)
        {
            Sync = new SyncHub(this);
            Sync.Start();
        }
    }
}

/// <summary>Lyrics for the current song, from its provider (synced when the service or LRCLIB has them), cached per
/// song for the session.</summary>
public sealed class LyricsService(PlayerController player)
{
    private readonly Dictionary<string, Lyrics?> _cache = [];

    public Lyrics? Cached(Track track) => _cache.GetValueOrDefault(track.Id);

    public async Task<Lyrics?> LoadAsync(Track track)
    {
        if (_cache.TryGetValue(track.Id, out var hit)) return hit;
        var provider = player.Provider(track.Provider);
        Lyrics? lyrics = null;
        var failed = false;
        try
        {
            if (provider is not null && provider.Capabilities.HasFlag(ProviderCapabilities.Lyrics)) lyrics = await provider.LyricsAsync(track);
        }
        catch (Exception e)
        {
            Log.Error($"lyrics: {e.GetType().Name}: {e.Message}");
            failed = true;
        }
        // A failure (offline) isn't remembered, so coming back to the song asks again.
        if (!failed) _cache[track.Id] = lyrics;
        return lyrics;
    }
}

/// <summary>Results of browse calls for this session and account, so going back to a page shows it at once. Emptied
/// whenever the account changes.</summary>
public sealed class BrowseCache
{
    private readonly Dictionary<string, object> _items = [];

    public async Task<T> GetAsync<T>(string key, Func<Task<T>> load) where T : notnull
    {
        if (_items.TryGetValue(key, out var hit) && hit is T value) return value;
        var session = App.Services.Provider.Session;
        var loaded = await load();
        // What came back for an account that is no longer current is neither kept nor shown (the page reloads for the
        // new one; Run treats the cancellation as quiet).
        if (App.Services.Provider.Session != session) throw new OperationCanceledException("The account changed during the request.");
        _items[key] = loaded;
        return loaded;
    }

    public bool TryGet<T>(string key, out T value)
    {
        if (_items.TryGetValue(key, out var hit) && hit is T v)
        {
            value = v;
            return true;
        }
        value = default!;
        return false;
    }

    public void Set(string key, object value) => _items[key] = value;

    public void Remove(string key) => _items.Remove(key);

    public void RemoveWhere(Func<string, bool> match)
    {
        foreach (var key in _items.Keys.Where(match).ToList()) _items.Remove(key);
    }

    public void Clear() => _items.Clear();
}

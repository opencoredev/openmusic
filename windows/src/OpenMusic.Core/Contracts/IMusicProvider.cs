using System.ComponentModel;

namespace OpenMusic.Core;

// Port of Sources/OpenMusicCore/Contracts/MusicProvider.swift, minus the SwiftUI sign-in and settings views (the Windows
// app owns those; see windows/AGENTS.md).

[Flags]
public enum ProviderCapabilities
{
    None = 0,
    Search = 1 << 0,
    Home = 1 << 1,
    Library = 1 << 2,
    Lyrics = 1 << 3,
    SyncedLyrics = 1 << 4,
    Radio = 1 << 5,
    Like = 1 << 6,
    PlaylistEditing = 1 << 7,
    Follow = 1 << 8,
    Playback = 1 << 9,
    Explore = 1 << 10,
    /// <summary>Songs can be added at a given place in a playlist (<see cref="IMusicProvider.InsertAsync(IReadOnlyList{Track}, string, int, CancellationToken)"/>),
    /// so a removal can be undone exactly. Without it the app asks before removing.</summary>
    PlaylistInsert = 1 << 11,
}

/// <summary>
/// One streaming service (YouTube Music, Spotify, the mock).
/// <para>Threading: call it from the UI thread. Implementations do their network and parsing work off it
/// (<c>ConfigureAwait(false)</c>) and return; the caller's <c>await</c> resumes on the UI thread. Property changes
/// (<see cref="AuthStatus"/>) are raised on the UI thread.</para>
/// Unsupported operations throw <see cref="ProviderException"/> with <see cref="ProviderErrorKind.NotSupported"/>.
/// </summary>
public interface IMusicProvider : INotifyPropertyChanged
{
    ProviderId Id { get; }
    ProviderCapabilities Capabilities { get; }

    // Account

    AuthStatus AuthStatus { get; }
    bool IsSignedIn => AuthStatus.IsSignedIn;
    /// <summary>Restore a saved session at launch. Must not show UI.</summary>
    Task RestoreSessionAsync(CancellationToken ct = default);
    /// <summary>Signs out. When the saved sign-in can't be deleted it stays signed in (see <see cref="TrySignOutAsync"/>).</summary>
    Task SignOutAsync();
    /// <summary>Signs out, or throws and stays signed in when the saved sign-in couldn't be deleted.</summary>
    Task TrySignOutAsync() => SignOutAsync();
    /// <summary>Who requests are sent as right now. Caches keyed by account read it before and after a request.</summary>
    ProviderSession Session => ProviderSession.Derived(AuthStatus);

    // Browse

    /// <summary>"Home" / "Listen Now" shelves.</summary>
    Task<IReadOnlyList<Shelf>> HomeAsync(CancellationToken ct = default);
    /// <summary>"Explore" / "New": new releases, charts, moods and genres.</summary>
    Task<IReadOnlyList<Shelf>> ExploreAsync(CancellationToken ct = default);
    /// <summary>Expand a shelf's <see cref="Shelf.MoreToken"/> ("See All").</summary>
    Task<Shelf> ShelfAsync(string moreToken, CancellationToken ct = default);

    // Search

    Task<SearchResults> SearchAsync(string query, SearchScope scope, CancellationToken ct = default);
    Task<IReadOnlyList<string>> SearchSuggestionsAsync(string query, CancellationToken ct = default);
    /// <summary>Query completions plus direct matches (an artist, a song) when the service offers them.</summary>
    async Task<SearchSuggestions> RichSearchSuggestionsAsync(string query, CancellationToken ct = default) =>
        new(await SearchSuggestionsAsync(query, ct).ConfigureAwait(false), []);

    // Entities

    Task<AlbumDetail> AlbumAsync(string id, CancellationToken ct = default);
    Task<ArtistDetail> ArtistAsync(string id, CancellationToken ct = default);
    Task<PlaylistDetail> PlaylistAsync(string id, CancellationToken ct = default);
    Task<Page<Track>> PlaylistTracksAsync(string continuation, CancellationToken ct = default);
    /// <summary>The playlist as the service has it now, never read from or written to a cache, for the reads a playlist
    /// edit compares or counts.</summary>
    Task<PlaylistDetail> UncachedPlaylistAsync(string id, CancellationToken ct = default) => PlaylistAsync(id, ct);
    Task<Page<Track>> UncachedPlaylistTracksAsync(string continuation, CancellationToken ct = default) => PlaylistTracksAsync(continuation, ct);
    /// <summary>The track with its album and artist links filled in, for "Go to Album" and "Go to Artist".</summary>
    Task<Track> LinkedTrackAsync(Track track, CancellationToken ct = default) => Task.FromResult(track);

    // Library (requires sign-in)

    Task<Page<MediaItem>> LibraryAsync(LibraryKind kind, string? continuation, CancellationToken ct = default);
    Task SetLikedAsync(Track track, bool liked, CancellationToken ct = default);
    Task<bool> IsLikedAsync(Track track, CancellationToken ct = default);
    Task SetSavedAsync(MediaItem item, bool saved, CancellationToken ct = default);
    Task<Playlist> CreatePlaylistAsync(string title, string? description, CancellationToken ct = default);
    Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default);
    Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default);
    /// <summary>Adds <paramref name="tracks"/> so the first lands at <paramref name="position"/> (0-based). Only with
    /// <see cref="ProviderCapabilities.PlaylistInsert"/>.</summary>
    Task InsertAsync(IReadOnlyList<Track> tracks, string playlistId, int position, CancellationToken ct = default) =>
        throw ProviderException.NotSupported("Adding songs at a position in a playlist");
    /// <summary>The most songs one removal or insertion request takes (Spotify: 100). Null: each call is one request.</summary>
    int? PlaylistEditBatchSize => null;
    /// <summary>The same writes bound to <paramref name="account"/>: nothing is sent
    /// (<see cref="PlaylistEditException.AccountChanged"/>) when the credentials belong to another account by then.</summary>
    Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount account, CancellationToken ct = default) =>
        AddAsync(tracks, playlistId, ct);
    Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount account, CancellationToken ct = default) =>
        RemoveAsync(tracks, playlistId, ct);
    Task InsertAsync(IReadOnlyList<Track> tracks, string playlistId, int position, PlaylistWriteAccount account, CancellationToken ct = default) =>
        InsertAsync(tracks, playlistId, position, ct);
    Task<Playlist> CreatePlaylistAsync(string title, string? description, PlaylistWriteAccount account, CancellationToken ct = default) =>
        CreatePlaylistAsync(title, description, ct);
    /// <summary>Like or unlike bound to <paramref name="account"/>: nothing is sent (<see cref="PlaylistEditException.AccountChanged"/>)
    /// when the credentials belong to another account by then.</summary>
    Task SetLikedAsync(Track track, bool liked, PlaylistWriteAccount account, CancellationToken ct = default) =>
        SetLikedAsync(track, liked, ct);

    // Playback support

    /// <summary>Tracks to continue with after <paramref name="seed"/> (YouTube "Up next"/radio, Spotify recommendations).</summary>
    Task<IReadOnlyList<Track>> RadioAsync(Track seed, CancellationToken ct = default);
    /// <summary>Start a radio from an artist or playlist (<see cref="ArtistDetail.RadioSeed"/>, a playlist id).</summary>
    Task<IReadOnlyList<Track>> RadioAsync(string seedId, CancellationToken ct = default);
    Task<Lyrics?> LyricsAsync(Track track, CancellationToken ct = default);

    /// <summary>The engine that plays this provider's tracks. Created once and reused.</summary>
    IPlaybackEngine PlaybackEngine { get; }
}

/// <summary>Who a provider's requests are sent as, so a cache never files one account's results under another.
/// Read it before a request and again after: keep the result only when both reads are equal and neither is changing.</summary>
public readonly record struct ProviderSession(int Generation, SessionIdentity Identity)
{
    public static ProviderSession Derived(AuthStatus status) => status.State switch
    {
        AuthState.SignedIn => new(0, SessionIdentity.ForAccount(status.Account?.Id)),
        AuthState.SigningIn => new(0, SessionIdentity.Changing),
        _ => new(0, SessionIdentity.SignedOut),
    };

    /// <summary>The next session, with a new generation.</summary>
    public ProviderSession Next(SessionIdentity identity) => new(unchecked(Generation + 1), identity);
}

public enum SessionIdentityKind
{
    /// <summary>Requests carry no credentials.</summary>
    SignedOut,
    /// <summary>Requests carry this account's credentials (<see cref="SessionIdentity.AccountId"/>, null when the service
    /// gave none: such a session is never cached on disk).</summary>
    Account,
    /// <summary>Credentials are being swapped or not restored yet.</summary>
    Changing,
}

public readonly record struct SessionIdentity(SessionIdentityKind Kind, string? AccountId = null)
{
    public static SessionIdentity SignedOut => new(SessionIdentityKind.SignedOut);
    public static SessionIdentity Changing => new(SessionIdentityKind.Changing);
    public static SessionIdentity ForAccount(string? id) => new(SessionIdentityKind.Account, id);
}

/// <summary>The account a playlist write must go out as: the immutable account id the app checked and the session it
/// checked it in.</summary>
public sealed record PlaylistWriteAccount(string? AccountId, ProviderSession Session);

/// <summary>What the search field offers while typing.</summary>
public sealed record SearchSuggestions(IReadOnlyList<string> Queries, IReadOnlyList<MediaItem> Items)
{
    public static SearchSuggestions Empty { get; } = new([], []);
}

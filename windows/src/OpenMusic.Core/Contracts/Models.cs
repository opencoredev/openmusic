using System.Text.Json.Serialization;
using OpenMusic.Core.Support;

namespace OpenMusic.Core;

// Port of Sources/OpenMusicCore/Contracts/Models.swift. Types the sync server stores or relays serialize to exactly the
// JSON Swift's JSONEncoder writes (OpenMusicJson): field names as in Swift, nil optionals left out, URLs as strings.

/// <summary>The streaming services OpenMusic talks to.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ProviderId>))]
public enum ProviderId
{
    [JsonStringEnumMemberName("youtubeMusic")] YouTubeMusic,
    [JsonStringEnumMemberName("spotify")] Spotify,
}

public static class ProviderIdExtensions
{
    /// <summary>The wire and storage name: "youtubeMusic", "spotify" (Swift's raw value).</summary>
    public static string RawValue(this ProviderId id) => id == ProviderId.YouTubeMusic ? "youtubeMusic" : "spotify";

    public static string DisplayName(this ProviderId id) => id == ProviderId.YouTubeMusic ? "YouTube Music" : "Spotify";

    /// <summary>Two-letter prefix the mock catalogs put on ids ("yt", "sp").</summary>
    public static string Short(this ProviderId id) => id == ProviderId.YouTubeMusic ? "yt" : "sp";

    public static ProviderId? Parse(string raw) => raw switch
    {
        "youtubeMusic" => ProviderId.YouTubeMusic,
        "spotify" => ProviderId.Spotify,
        _ => null,
    };

    public static IReadOnlyList<ProviderId> All { get; } = [ProviderId.YouTubeMusic, ProviderId.Spotify];
}

// MARK: - Artwork

/// <summary>One rendition of an image.</summary>
public sealed record ArtworkImage
{
    [JsonPropertyName("url")] public required Uri Url { get; init; }
    [JsonPropertyName("width")] public int? Width { get; init; }
    [JsonPropertyName("height")] public int? Height { get; init; }

    public ArtworkImage() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public ArtworkImage(Uri url, int? width = null, int? height = null)
    {
        Url = url;
        Width = width;
        Height = height;
    }
}

/// <summary>All known renditions of an image. Providers fill in what they have; the UI asks for the size it needs.</summary>
public sealed record Artwork
{
    [JsonPropertyName("images")] public IReadOnlyList<ArtworkImage> Images { get => _images; init => _images = value ?? []; }
    private readonly IReadOnlyList<ArtworkImage> _images = [];

    public Artwork() { }

    public Artwork(IReadOnlyList<ArtworkImage> images) => Images = images;

    public static Artwork? FromUrl(Uri? url) => url is null ? null : new Artwork([new ArtworkImage(url)]);

    /// <summary>The smallest image at least <paramref name="pixels"/> wide, else the largest one.</summary>
    public Uri? Url(int minPixels)
    {
        var sized = Images.Where(i => i.Width is not null).OrderBy(i => i.Width ?? 0).ToList();
        var fit = sized.FirstOrDefault(i => (i.Width ?? 0) >= minPixels);
        if (fit is not null) return fit.Url;
        return sized.LastOrDefault()?.Url ?? Images.FirstOrDefault()?.Url;
    }

    public bool Equals(Artwork? other) => other is not null && Images.SequenceEqual(other.Images);

    public override int GetHashCode() => Eq.SeqHash(Images);
}

// MARK: - References

public sealed record ArtistRef
{
    [JsonPropertyName("id")] public string? Id { get; init; }
    [JsonPropertyName("name")] public required string Name { get; init; }

    public ArtistRef() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public ArtistRef(string? id, string name)
    {
        Id = id;
        Name = name;
    }
}

public sealed record AlbumRef
{
    [JsonPropertyName("id")] public string? Id { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }

    public AlbumRef() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public AlbumRef(string? id, string title)
    {
        Id = id;
        Title = title;
    }
}

// MARK: - Entities

/// <summary>A playable song (or music video on YouTube Music).</summary>
public sealed record Track
{
    /// <summary>Provider-native identifier (YouTube videoId, Spotify track id).</summary>
    [JsonPropertyName("providerID")] public required string ProviderID { get; init; }
    [JsonPropertyName("provider")] public required ProviderId Provider { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("artists")] public IReadOnlyList<ArtistRef> Artists { get => _artists; init => _artists = value ?? []; }
    private readonly IReadOnlyList<ArtistRef> _artists = [];
    [JsonPropertyName("album")] public AlbumRef? Album { get; init; }
    /// <summary>Seconds.</summary>
    [JsonPropertyName("duration")] public double? Duration { get; init; }
    [JsonPropertyName("artwork")] public Artwork? Artwork { get; init; }
    [JsonPropertyName("isExplicit")] public bool IsExplicit { get; init; }
    [JsonPropertyName("isPlayable")] public bool IsPlayable { get; init; } = true;
    [JsonPropertyName("trackNumber")] public int? TrackNumber { get; init; }
    /// <summary>Provider-specific values the provider needs later (e.g. YouTube <c>setVideoId</c>, Spotify <c>uri</c>).</summary>
    [JsonPropertyName("extra")] public IReadOnlyDictionary<string, string> Extra { get => _extra; init => _extra = value ?? Eq.EmptyExtra; }
    private readonly IReadOnlyDictionary<string, string> _extra = Eq.EmptyExtra;

    /// <summary>"youtubeMusic:&lt;providerID&gt;", unique across services.</summary>
    [JsonIgnore] public string Id => $"{Provider.RawValue()}:{ProviderID}";

    [JsonIgnore] public string ArtistLine => string.Join(", ", Artists.Select(a => a.Name));

    public bool Equals(Track? o) =>
        o is not null && ProviderID == o.ProviderID && Provider == o.Provider && Title == o.Title && Artists.SequenceEqual(o.Artists)
        && Album == o.Album && Nullable.Equals(Duration, o.Duration) && Artwork == o.Artwork && IsExplicit == o.IsExplicit
        && IsPlayable == o.IsPlayable && TrackNumber == o.TrackNumber && Eq.Dict(Extra, o.Extra);

    public override int GetHashCode() => HashCode.Combine(ProviderID, Provider, Title, Duration);
}

[JsonConverter(typeof(JsonStringEnumConverter<AlbumKind>))]
public enum AlbumKind
{
    [JsonStringEnumMemberName("album")] Album,
    [JsonStringEnumMemberName("single")] Single,
    [JsonStringEnumMemberName("ep")] Ep,
    [JsonStringEnumMemberName("compilation")] Compilation,
    [JsonStringEnumMemberName("unknown")] Unknown,
}

public sealed record Album
{
    [JsonPropertyName("providerID")] public required string ProviderID { get; init; }
    [JsonPropertyName("provider")] public required ProviderId Provider { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("artists")] public IReadOnlyList<ArtistRef> Artists { get => _artists; init => _artists = value ?? []; }
    private readonly IReadOnlyList<ArtistRef> _artists = [];
    [JsonPropertyName("year")] public int? Year { get; init; }
    [JsonPropertyName("artwork")] public Artwork? Artwork { get; init; }
    [JsonPropertyName("kind")] public AlbumKind Kind { get; init; } = AlbumKind.Album;
    [JsonPropertyName("trackCount")] public int? TrackCount { get; init; }
    [JsonPropertyName("isExplicit")] public bool IsExplicit { get; init; }
    [JsonPropertyName("extra")] public IReadOnlyDictionary<string, string> Extra { get => _extra; init => _extra = value ?? Eq.EmptyExtra; }
    private readonly IReadOnlyDictionary<string, string> _extra = Eq.EmptyExtra;

    [JsonIgnore] public string Id => $"{Provider.RawValue()}:{ProviderID}";
    [JsonIgnore] public string ArtistLine => string.Join(", ", Artists.Select(a => a.Name));

    public bool Equals(Album? o) =>
        o is not null && ProviderID == o.ProviderID && Provider == o.Provider && Title == o.Title && Artists.SequenceEqual(o.Artists)
        && Year == o.Year && Artwork == o.Artwork && Kind == o.Kind && TrackCount == o.TrackCount && IsExplicit == o.IsExplicit
        && Eq.Dict(Extra, o.Extra);

    public override int GetHashCode() => HashCode.Combine(ProviderID, Provider, Title);
}

public sealed record Artist
{
    [JsonPropertyName("providerID")] public required string ProviderID { get; init; }
    [JsonPropertyName("provider")] public required ProviderId Provider { get; init; }
    [JsonPropertyName("name")] public required string Name { get; init; }
    [JsonPropertyName("artwork")] public Artwork? Artwork { get; init; }
    /// <summary>e.g. "12.3M monthly listeners" or "Artist".</summary>
    [JsonPropertyName("subtitle")] public string? Subtitle { get; init; }
    [JsonPropertyName("extra")] public IReadOnlyDictionary<string, string> Extra { get => _extra; init => _extra = value ?? Eq.EmptyExtra; }
    private readonly IReadOnlyDictionary<string, string> _extra = Eq.EmptyExtra;

    [JsonIgnore] public string Id => $"{Provider.RawValue()}:{ProviderID}";

    public bool Equals(Artist? o) =>
        o is not null && ProviderID == o.ProviderID && Provider == o.Provider && Name == o.Name && Artwork == o.Artwork
        && Subtitle == o.Subtitle && Eq.Dict(Extra, o.Extra);

    public override int GetHashCode() => HashCode.Combine(ProviderID, Provider, Name);
}

public sealed record Playlist
{
    [JsonPropertyName("providerID")] public required string ProviderID { get; init; }
    [JsonPropertyName("provider")] public required ProviderId Provider { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("owner")] public string? Owner { get; init; }
    [JsonPropertyName("artwork")] public Artwork? Artwork { get; init; }
    [JsonPropertyName("trackCount")] public int? TrackCount { get; init; }
    [JsonPropertyName("summary")] public string? Summary { get; init; }
    /// <summary>True when the signed-in user can add and remove tracks.</summary>
    [JsonPropertyName("isEditable")] public bool IsEditable { get; init; }
    [JsonPropertyName("extra")] public IReadOnlyDictionary<string, string> Extra { get => _extra; init => _extra = value ?? Eq.EmptyExtra; }
    private readonly IReadOnlyDictionary<string, string> _extra = Eq.EmptyExtra;

    [JsonIgnore] public string Id => $"{Provider.RawValue()}:{ProviderID}";

    /// <summary><c>extra</c> key that marks a service's own liked-songs playlist where its id doesn't (sample data).</summary>
    public const string LikedSongsKey = "likedSongs";

    /// <summary>The service's own list of liked songs: YouTube Music's "Liked Music" (<c>LM</c>) or Spotify's "Liked Songs"
    /// (<c>collection</c>). Shown as Library › Liked Songs and left out of the Playlists list.</summary>
    [JsonIgnore]
    public bool IsLikedSongs
    {
        get
        {
            if (Extra.TryGetValue(LikedSongsKey, out var v) && v == "1") return true;
            return Provider switch
            {
                ProviderId.YouTubeMusic => ProviderID is "LM" or "VLLM",
                _ => ProviderID == "collection" || ProviderID.EndsWith(":collection", StringComparison.Ordinal),
            };
        }
    }

    public bool Equals(Playlist? o) =>
        o is not null && ProviderID == o.ProviderID && Provider == o.Provider && Title == o.Title && Owner == o.Owner
        && Artwork == o.Artwork && TrackCount == o.TrackCount && Summary == o.Summary && IsEditable == o.IsEditable
        && Eq.Dict(Extra, o.Extra);

    public override int GetHashCode() => HashCode.Combine(ProviderID, Provider, Title);
}

/// <summary>Anything that can appear in a shelf, search result or grid. Serializes like Swift's synthesized enum
/// coding: <c>{"album":{"_0":{…}}}</c>.</summary>
[JsonConverter(typeof(MediaItemJsonConverter))]
public abstract record MediaItem
{
    private protected MediaItem() { }

    public sealed record TrackItem(Track Track) : MediaItem;
    public sealed record AlbumItem(Album Album) : MediaItem;
    public sealed record ArtistItem(Artist Artist) : MediaItem;
    public sealed record PlaylistItem(Playlist Playlist) : MediaItem;

    public static MediaItem Of(Track t) => new TrackItem(t);
    public static MediaItem Of(Album a) => new AlbumItem(a);
    public static MediaItem Of(Artist a) => new ArtistItem(a);
    public static MediaItem Of(Playlist p) => new PlaylistItem(p);

    public string Id => this switch
    {
        TrackItem t => $"track:{t.Track.Id}",
        AlbumItem a => $"album:{a.Album.Id}",
        ArtistItem a => $"artist:{a.Artist.Id}",
        PlaylistItem p => $"playlist:{p.Playlist.Id}",
        _ => throw new InvalidOperationException(),
    };

    public ProviderId Provider => this switch
    {
        TrackItem t => t.Track.Provider,
        AlbumItem a => a.Album.Provider,
        ArtistItem a => a.Artist.Provider,
        PlaylistItem p => p.Playlist.Provider,
        _ => throw new InvalidOperationException(),
    };

    public string Title => this switch
    {
        TrackItem t => t.Track.Title,
        AlbumItem a => a.Album.Title,
        ArtistItem a => a.Artist.Name,
        PlaylistItem p => p.Playlist.Title,
        _ => throw new InvalidOperationException(),
    };

    public string? Subtitle => this switch
    {
        TrackItem t => t.Track.ArtistLine,
        AlbumItem a => a.Album.ArtistLine,
        ArtistItem a => a.Artist.Subtitle,
        PlaylistItem p => p.Playlist.Owner,
        _ => throw new InvalidOperationException(),
    };

    public Artwork? Artwork => this switch
    {
        TrackItem t => t.Track.Artwork,
        AlbumItem a => a.Album.Artwork,
        ArtistItem a => a.Artist.Artwork,
        PlaylistItem p => p.Playlist.Artwork,
        _ => throw new InvalidOperationException(),
    };
}

// MARK: - Details

public sealed record AlbumDetail(
    Album Album,
    IReadOnlyList<Track> Tracks,
    string? Summary = null,
    /// e.g. "12 songs, 48 minutes · 2021 · Label".
    string? Footnote = null,
    IReadOnlyList<Album>? MoreByArtist = null)
{
    public IReadOnlyList<Album> MoreByArtist { get; init; } = MoreByArtist ?? [];
}

public sealed record ArtistDetail(Artist Artist)
{
    public IReadOnlyList<Track> TopTracks { get => _topTracks; init => _topTracks = value ?? []; }
    private readonly IReadOnlyList<Track> _topTracks = [];
    public IReadOnlyList<Album> Albums { get => _albums; init => _albums = value ?? []; }
    private readonly IReadOnlyList<Album> _albums = [];
    public IReadOnlyList<Album> Singles { get => _singles; init => _singles = value ?? []; }
    private readonly IReadOnlyList<Album> _singles = [];
    public IReadOnlyList<Playlist> Playlists { get => _playlists; init => _playlists = value ?? []; }
    private readonly IReadOnlyList<Playlist> _playlists = [];
    public IReadOnlyList<Artist> Related { get => _related; init => _related = value ?? []; }
    private readonly IReadOnlyList<Artist> _related = [];
    /// <summary>Releases by others that feature this artist ("Appears On"). Empty when the provider doesn't have them.</summary>
    public IReadOnlyList<Album> AppearsOn { get => _appearsOn; init => _appearsOn = value ?? []; }
    private readonly IReadOnlyList<Album> _appearsOn = [];
    public string? Bio { get; init; }
    /// <summary>Provider-specific id that starts an artist radio or shuffle, if any.</summary>
    public string? RadioSeed { get; init; }
    public bool? IsFollowed { get; init; }
}

public sealed record PlaylistDetail(Playlist Playlist, IReadOnlyList<Track> Tracks)
{
    /// <summary>Opaque token for <see cref="IMusicProvider.PlaylistTracksAsync"/>.</summary>
    public string? Continuation { get; init; }
    /// <summary>Each track's place in the playlist as the service numbers its entries (0-based), when the service lists
    /// entries OpenMusic leaves out (Spotify's local files, episodes, removed songs). Null when every entry is listed.</summary>
    public IReadOnlyList<int>? Positions { get; init; }
    /// <summary>How many entries the service listed on this page, the ones left out included. Null: <c>Tracks.Count</c>.</summary>
    public int? EntryCount { get; init; }
    /// <summary>The entries left out of <c>Tracks</c> that the service still identifies, by place.</summary>
    public IReadOnlyDictionary<int, string>? UnlistedEntries { get; init; }
}

// MARK: - Browse

[JsonConverter(typeof(JsonStringEnumConverter<ShelfStyle>))]
public enum ShelfStyle
{
    /// <summary>Horizontally scrolling large cards (albums, playlists, mixes).</summary>
    [JsonStringEnumMemberName("carousel")] Carousel,
    /// <summary>Compact rows of songs, usually in columns.</summary>
    [JsonStringEnumMemberName("trackList")] TrackList,
    /// <summary>Round artist portraits.</summary>
    [JsonStringEnumMemberName("artists")] Artists,
    /// <summary>Big hero cards at the top of a page.</summary>
    [JsonStringEnumMemberName("hero")] Hero,
}

public sealed record Shelf(string Id, string Title, ShelfStyle Style, IReadOnlyList<MediaItem> Items)
{
    public string? Subtitle { get; init; }
    /// <summary>Opaque token for "See All", if the provider supports it.</summary>
    public string? MoreToken { get; init; }
}

public sealed record SearchResults
{
    public MediaItem? Top { get; init; }
    public IReadOnlyList<Track> Tracks { get => _tracks; init => _tracks = value ?? []; }
    private readonly IReadOnlyList<Track> _tracks = [];
    public IReadOnlyList<Album> Albums { get => _albums; init => _albums = value ?? []; }
    private readonly IReadOnlyList<Album> _albums = [];
    public IReadOnlyList<Artist> Artists { get => _artists; init => _artists = value ?? []; }
    private readonly IReadOnlyList<Artist> _artists = [];
    public IReadOnlyList<Playlist> Playlists { get => _playlists; init => _playlists = value ?? []; }
    private readonly IReadOnlyList<Playlist> _playlists = [];

    public bool IsEmpty => Top is null && Tracks.Count == 0 && Albums.Count == 0 && Artists.Count == 0 && Playlists.Count == 0;
}

public enum SearchScope { All, Songs, Albums, Artists, Playlists }

public enum LibraryKind { LikedSongs, Songs, Albums, Artists, Playlists, RecentlyPlayed }

public static class LibraryKindExtensions
{
    /// <summary>Swift's raw value ("likedSongs", "recentlyPlayed").</summary>
    public static string RawValue(this LibraryKind kind) => kind switch
    {
        LibraryKind.LikedSongs => "likedSongs",
        LibraryKind.Songs => "songs",
        LibraryKind.Albums => "albums",
        LibraryKind.Artists => "artists",
        LibraryKind.Playlists => "playlists",
        _ => "recentlyPlayed",
    };
}

/// <summary>One page of a paginated list.</summary>
public sealed record Page<T>(IReadOnlyList<T> Items)
{
    public string? Continuation { get; init; }
    /// <summary>For a playlist's page: each item's place in the whole playlist, when the service lists entries the page
    /// leaves out (see <see cref="PlaylistDetail.Positions"/>). Null: places follow the items.</summary>
    public IReadOnlyList<int>? Positions { get; init; }
    public int? EntryCount { get; init; }
    public IReadOnlyDictionary<int, string>? UnlistedEntries { get; init; }
}

// MARK: - Lyrics

public sealed record LyricLine
{
    /// <summary>Start time in seconds, null for unsynced lyrics.</summary>
    [JsonPropertyName("time")] public double? Time { get; init; }
    [JsonPropertyName("text")] public required string Text { get; init; }

    public LyricLine() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public LyricLine(double? time, string text)
    {
        Time = time;
        Text = text;
    }
}

public sealed record Lyrics
{
    [JsonPropertyName("lines")] public IReadOnlyList<LyricLine> Lines { get => _lines; init => _lines = value ?? []; }
    private readonly IReadOnlyList<LyricLine> _lines = [];
    [JsonPropertyName("source")] public string? Source { get; init; }

    public Lyrics() { }

    public Lyrics(IReadOnlyList<LyricLine> lines, string? source = null)
    {
        Lines = lines;
        Source = source;
    }

    [JsonIgnore] public bool IsSynced => Lines.Any(l => l.Time is not null);

    /// <summary>Index of the line playing at <paramref name="seconds"/>: the last synced line that started at or before
    /// it, null before the first line or for unsynced lyrics.</summary>
    public int? LineIndex(double seconds)
    {
        int? found = null;
        for (var i = 0; i < Lines.Count; i++)
        {
            if (Lines[i].Time is not { } t) continue;
            if (t <= seconds) found = i;
            else break;
        }
        return found;
    }

    public bool Equals(Lyrics? o) => o is not null && Source == o.Source && Lines.SequenceEqual(o.Lines);

    public override int GetHashCode() => HashCode.Combine(Source, Lines.Count);
}

// MARK: - Accounts

public sealed record AccountInfo
{
    [JsonPropertyName("name")] public required string Name { get; init; }
    [JsonPropertyName("avatar")] public Uri? Avatar { get; init; }
    /// <summary>e.g. "Premium", "Free", an email address.</summary>
    [JsonPropertyName("detail")] public string? Detail { get; init; }
    /// <summary>The service's immutable identifier for the account (Spotify's user id; YouTube's datasync id). Never a
    /// name, handle or email.</summary>
    [JsonPropertyName("id")] public string? Id { get; init; }

    public AccountInfo() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public AccountInfo(string name, Uri? avatar = null, string? detail = null, string? id = null)
    {
        Name = name;
        Avatar = avatar;
        Detail = detail;
        Id = id;
    }
}

public enum AuthState { SignedOut, SigningIn, SignedIn, Failed }

/// <summary>Swift's <c>AuthStatus</c> enum: <see cref="AuthState"/> plus the account (signed in) or message (failed).</summary>
public sealed record AuthStatus(AuthState State, AccountInfo? Account = null, string? Message = null)
{
    public static AuthStatus SignedOut { get; } = new(AuthState.SignedOut);
    public static AuthStatus SigningIn { get; } = new(AuthState.SigningIn);
    public static AuthStatus SignedIn(AccountInfo account) => new(AuthState.SignedIn, account);
    public static AuthStatus Failed(string message) => new(AuthState.Failed, null, message);

    public bool IsSignedIn => State == AuthState.SignedIn;
}

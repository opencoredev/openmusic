namespace OpenMusic.Core.Support;

/// <summary>Public web links for "Copy Link" (Swift: <c>WebLinks</c>). A provider can override with <c>Extra["url"]</c>.</summary>
public static class WebLinks
{
    public static Uri? For(MediaItem item)
    {
        var extra = item switch
        {
            MediaItem.TrackItem t => t.Track.Extra,
            MediaItem.AlbumItem a => a.Album.Extra,
            MediaItem.ArtistItem a => a.Artist.Extra,
            MediaItem.PlaylistItem p => p.Playlist.Extra,
            _ => null,
        };
        if (extra?.GetValueOrDefault("url") is { } explicitUrl && Uri.TryCreate(explicitUrl, UriKind.Absolute, out var given)) return given;
        var text = item switch
        {
            MediaItem.TrackItem { Track: var t } when t.Provider == ProviderId.YouTubeMusic => $"https://music.youtube.com/watch?v={t.ProviderID}",
            MediaItem.TrackItem { Track: var t } => $"https://open.spotify.com/track/{t.ProviderID}",
            MediaItem.AlbumItem { Album: var a } when a.Provider == ProviderId.YouTubeMusic =>
                (a.Extra.GetValueOrDefault("playlistId") ?? a.Extra.GetValueOrDefault("audioPlaylistId")) is { } list
                    ? $"https://music.youtube.com/playlist?list={list}"
                    : $"https://music.youtube.com/browse/{a.ProviderID}",
            MediaItem.AlbumItem { Album: var a } => $"https://open.spotify.com/album/{a.ProviderID}",
            MediaItem.ArtistItem { Artist: var a } when a.Provider == ProviderId.YouTubeMusic => $"https://music.youtube.com/channel/{a.ProviderID}",
            MediaItem.ArtistItem { Artist: var a } => $"https://open.spotify.com/artist/{a.ProviderID}",
            MediaItem.PlaylistItem { Playlist: var p } when p.Provider == ProviderId.YouTubeMusic =>
                $"https://music.youtube.com/playlist?list={(p.ProviderID.StartsWith("VL", StringComparison.Ordinal) ? p.ProviderID[2..] : p.ProviderID)}",
            MediaItem.PlaylistItem { Playlist: var p } => $"https://open.spotify.com/playlist/{p.ProviderID}",
            _ => null,
        };
        return text is null ? null : new Uri(text);
    }
}

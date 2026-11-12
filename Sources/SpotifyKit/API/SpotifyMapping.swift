import Foundation
import OpenMusicCore

/// Turns Spotify API objects into OpenMusic models.
enum SpotifyMapping {
    static func artwork(_ images: [SP.Image]?) -> Artwork? {
        guard let images, !images.isEmpty else { return nil }
        return Artwork(images: images.map { ArtworkImage(url: $0.url, width: $0.width, height: $0.height) })
    }

    static func artists(_ artists: [SP.SimplifiedArtist]?) -> [ArtistRef] {
        (artists ?? []).map { ArtistRef(id: $0.id, name: $0.name) }
    }

    static func year(_ releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    /// Spotify files EPs under "single". Treat 4+ track singles as EPs, the way Spotify's own apps label them.
    static func kind(_ albumType: String?, trackCount: Int?) -> AlbumKind {
        switch albumType?.lowercased() {
        case "album": .album
        case "single": (trackCount ?? 1) >= 4 ? .ep : .single
        case "compilation": .compilation
        default: .unknown
        }
    }

    static func track(_ t: SP.Track) -> Track? {
        guard let id = t.id, t.type == nil || t.type == "track" else { return nil }
        var extra: [String: String] = ["uri": t.uri ?? "spotify:track:\(id)"]
        if let disc = t.disc_number { extra["disc"] = String(disc) }
        if let isrc = t.external_ids?.isrc { extra["isrc"] = isrc }
        if let albumArtist = t.album?.artists?.first?.name { extra["albumArtist"] = albumArtist }
        return Track(
            providerID: id,
            provider: .spotify,
            title: t.name,
            artists: artists(t.artists),
            album: t.album.map { AlbumRef(id: $0.id, title: $0.name) },
            duration: t.duration_ms.map { TimeInterval($0) / 1000 },
            artwork: artwork(t.album?.images),
            isExplicit: t.explicit ?? false,
            isPlayable: isPlayable(t.is_playable, restrictions: t.restrictions, isLocal: t.is_local),
            trackNumber: t.track_number,
            extra: extra
        )
    }

    /// Album track listings omit the album; pass it in.
    static func track(_ t: SP.SimplifiedTrack, album: SP.SimplifiedAlbum) -> Track? {
        guard let id = t.id else { return nil }
        var extra: [String: String] = ["uri": t.uri ?? "spotify:track:\(id)"]
        if let disc = t.disc_number { extra["disc"] = String(disc) }
        if let albumArtist = album.artists?.first?.name { extra["albumArtist"] = albumArtist }
        return Track(
            providerID: id,
            provider: .spotify,
            title: t.name,
            artists: artists(t.artists),
            album: AlbumRef(id: album.id, title: album.name),
            duration: t.duration_ms.map { TimeInterval($0) / 1000 },
            artwork: artwork(album.images),
            isExplicit: t.explicit ?? false,
            isPlayable: isPlayable(t.is_playable, restrictions: t.restrictions, isLocal: t.is_local),
            trackNumber: t.track_number,
            extra: extra
        )
    }

    static func isPlayable(_ flag: Bool?, restrictions: SP.Restrictions?, isLocal: Bool?) -> Bool {
        if isLocal == true { return false }
        if let flag { return flag }
        return restrictions == nil
    }

    static func album(_ a: SP.SimplifiedAlbum) -> Album {
        var extra: [String: String] = ["uri": a.uri ?? "spotify:album:\(a.id)"]
        if let date = a.release_date { extra["releaseDate"] = date }
        return Album(
            providerID: a.id,
            provider: .spotify,
            title: a.name,
            artists: artists(a.artists),
            year: year(a.release_date),
            artwork: artwork(a.images),
            kind: kind(a.album_type, trackCount: a.total_tracks),
            trackCount: a.total_tracks,
            extra: extra
        )
    }

    static func artist(_ a: SP.Artist) -> Artist {
        var extra: [String: String] = ["uri": a.uri ?? "spotify:artist:\(a.id)"]
        if let genres = a.genres, !genres.isEmpty { extra["genres"] = genres.joined(separator: ",") }
        return Artist(providerID: a.id, provider: .spotify, name: a.name, artwork: artwork(a.images), subtitle: "Artist", extra: extra)
    }

    static func playlist(_ p: SP.SimplifiedPlaylist, currentUserID: String?) -> Playlist {
        var extra: [String: String] = ["uri": p.uri ?? "spotify:playlist:\(p.id)"]
        if let snapshot = p.snapshot_id { extra["snapshot"] = snapshot }
        if let ownerID = p.owner?.id { extra["ownerID"] = ownerID }
        let isOwner = currentUserID != nil && p.owner?.id == currentUserID
        return Playlist(
            providerID: p.id,
            provider: .spotify,
            title: p.name,
            owner: p.owner?.display_name ?? p.owner?.id,
            artwork: artwork(p.images),
            trackCount: (p.items ?? p.tracks)?.total,
            summary: cleanDescription(p.description),
            isEditable: isOwner || p.collaborative == true,
            extra: extra
        )
    }

    /// Playlist descriptions are HTML-escaped and may contain links.
    static func cleanDescription(_ html: String?) -> String? {
        guard var text = html, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&#x2F;": "/", "&nbsp;": " "]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func account(_ user: SP.User) -> AccountInfo {
        let detail: String? = switch user.product?.lowercased() {
        case "premium": "Premium"
        case "free", "open": "Free"
        case let other?: other.capitalized
        case nil: nil // Removed from /me for development-mode apps in February 2026.
        }
        return AccountInfo(
            name: user.display_name ?? user.id,
            avatar: user.images?.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url ?? user.images?.first?.url,
            detail: detail,
            id: user.id
        )
    }

    /// "12 songs, 48 minutes · 2021" (plus the ℗ line when Spotify sends one).
    static func albumFootnote(trackCount: Int, totalSeconds: TimeInterval, releaseDate: String?, copyright: String?) -> String {
        var parts: [String] = []
        let minutes = Int((totalSeconds / 60).rounded())
        let songs = trackCount == 1 ? "1 song" : "\(trackCount) songs"
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            parts.append("\(songs), \(h) hr \(m) min")
        } else {
            parts.append("\(songs), \(minutes) minute\(minutes == 1 ? "" : "s")")
        }
        if let releaseDate, let date = formattedDate(releaseDate) { parts.append(date) }
        var line = parts.joined(separator: " · ")
        if let copyright, !copyright.isEmpty { line += "\n\(copyright)" }
        return line
    }

    /// "2021-03-05" → "March 5, 2021"; "2021" → "2021".
    static func formattedDate(_ value: String) -> String? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first else { return nil }
        guard parts.count == 3 else { return String(year) }
        var components = DateComponents()
        components.year = year
        components.month = parts[1]
        components.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return String(year) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    /// Spotify URI for anything OpenMusic shows.
    static func uri(_ item: MediaItem) -> String {
        switch item {
        case .track(let t): t.extra["uri"] ?? "spotify:track:\(t.providerID)"
        case .album(let a): a.extra["uri"] ?? "spotify:album:\(a.providerID)"
        case .artist(let a): a.extra["uri"] ?? "spotify:artist:\(a.providerID)"
        case .playlist(let p): p.extra["uri"] ?? "spotify:playlist:\(p.providerID)"
        }
    }

    static func uri(_ track: Track) -> String { uri(.track(track)) }
}

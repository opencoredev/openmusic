import Foundation

// Codable mirrors of the Spotify Web API objects OpenMusic reads, shaped after the
// reference at developer.spotify.com/documentation/web-api (as of the February/March 2026 changes).
// Every field that Spotify has deprecated or removed for development-mode apps is optional,
// so responses decode whether or not it is present.

enum SP {
    struct Image: Decodable, Sendable, Hashable {
        var url: URL
        var width: Int?
        var height: Int?
    }

    struct ExternalIDs: Decodable, Sendable, Hashable {
        var isrc: String?
        var upc: String?
    }

    struct Restrictions: Decodable, Sendable, Hashable {
        var reason: String?
    }

    struct SimplifiedArtist: Decodable, Sendable, Hashable {
        var id: String?
        var name: String
        var uri: String?
    }

    struct Artist: Decodable, Sendable, Hashable {
        var id: String
        var name: String
        var uri: String?
        var images: [Image]?
        /// Deprecated for development-mode apps; may be absent.
        var genres: [String]?
    }

    struct SimplifiedAlbum: Decodable, Sendable, Hashable {
        var id: String
        var name: String
        var album_type: String?
        var total_tracks: Int?
        var release_date: String?
        var release_date_precision: String?
        var images: [Image]?
        var artists: [SimplifiedArtist]?
        var uri: String?
    }

    struct Copyright: Decodable, Sendable, Hashable {
        var text: String
        var type: String?
    }

    struct Album: Decodable, Sendable, Hashable {
        var id: String
        var name: String
        var album_type: String?
        var total_tracks: Int?
        var release_date: String?
        var release_date_precision: String?
        var images: [Image]?
        var artists: [SimplifiedArtist]?
        var uri: String?
        var tracks: Paging<SimplifiedTrack>?
        var copyrights: [Copyright]?
        /// Removed for development-mode apps in February 2026.
        var label: String?

        var simplified: SimplifiedAlbum {
            SimplifiedAlbum(id: id, name: name, album_type: album_type, total_tracks: total_tracks, release_date: release_date,
                            release_date_precision: release_date_precision, images: images, artists: artists, uri: uri)
        }
    }

    /// Track without album (album track listings).
    struct SimplifiedTrack: Decodable, Sendable, Hashable {
        var id: String?
        var name: String
        var artists: [SimplifiedArtist]?
        var duration_ms: Int?
        var explicit: Bool?
        var track_number: Int?
        var disc_number: Int?
        var uri: String?
        var is_playable: Bool?
        var is_local: Bool?
        var restrictions: Restrictions?
        var type: String?
    }

    /// Full track. Also decodes episodes loosely (type "episode") so playlists with podcasts don't fail.
    struct Track: Decodable, Sendable, Hashable {
        var id: String?
        var name: String
        var artists: [SimplifiedArtist]?
        var album: SimplifiedAlbum?
        var duration_ms: Int?
        var explicit: Bool?
        var track_number: Int?
        var disc_number: Int?
        var uri: String?
        var is_playable: Bool?
        var is_local: Bool?
        var restrictions: Restrictions?
        var external_ids: ExternalIDs?
        var type: String?
    }

    struct Paging<Item: Decodable & Sendable & Hashable>: Decodable, Sendable, Hashable {
        var href: String?
        var items: [Item]
        var limit: Int?
        var next: String?
        var offset: Int?
        var previous: String?
        var total: Int?
        /// Where each of `items` sat in the response's own list, counting the entries that didn't decode (`null`s), and
        /// how many entries the response listed: a playlist's places count every entry.
        var itemIndices: [Int] = []
        var rawCount = 0

        init(items: [Item], next: String? = nil, total: Int? = nil) {
            self.items = items
            self.next = next
            self.total = total
            self.itemIndices = Array(items.indices)
            self.rawCount = items.count
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            href = try c.decodeIfPresent(String.self, forKey: .href)
            // Spotify returns `null` entries in some lists (search playlists, removed tracks). Skip anything that doesn't decode.
            let raw = try c.decodeIfPresent([Lossy<Item>].self, forKey: .items) ?? []
            rawCount = raw.count
            var decoded: [Item] = [], indices: [Int] = []
            for (index, entry) in raw.enumerated() {
                if let value = entry.value { decoded.append(value); indices.append(index) }
            }
            items = decoded
            itemIndices = indices
            limit = try c.decodeIfPresent(Int.self, forKey: .limit)
            next = try c.decodeIfPresent(String.self, forKey: .next)
            offset = try c.decodeIfPresent(Int.self, forKey: .offset)
            previous = try c.decodeIfPresent(String.self, forKey: .previous)
            total = try c.decodeIfPresent(Int.self, forKey: .total)
        }

        enum CodingKeys: String, CodingKey { case href, items, limit, next, offset, previous, total }
    }

    struct Cursors: Decodable, Sendable, Hashable {
        var after: String?
        var before: String?
    }

    /// Cursor-based paging (recently played, followed artists).
    struct CursorPaging<Item: Decodable & Sendable & Hashable>: Decodable, Sendable, Hashable {
        var href: String?
        var items: [Item]
        var limit: Int?
        var next: String?
        var cursors: Cursors?
        var total: Int?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            href = try c.decodeIfPresent(String.self, forKey: .href)
            items = try c.decodeIfPresent([Lossy<Item>].self, forKey: .items)?.compactMap(\.value) ?? []
            limit = try c.decodeIfPresent(Int.self, forKey: .limit)
            next = try c.decodeIfPresent(String.self, forKey: .next)
            cursors = try c.decodeIfPresent(Cursors.self, forKey: .cursors)
            total = try c.decodeIfPresent(Int.self, forKey: .total)
        }

        enum CodingKeys: String, CodingKey { case href, items, limit, next, cursors, total }
    }

    struct Context: Decodable, Sendable, Hashable {
        var type: String?
        var uri: String?
    }

    struct PlayHistory: Decodable, Sendable, Hashable {
        var track: Track
        var played_at: String?
        var context: Context?
    }

    struct SavedTrack: Decodable, Sendable, Hashable {
        var added_at: String?
        var track: Track
    }

    struct SavedAlbum: Decodable, Sendable, Hashable {
        var added_at: String?
        var album: Album
    }

    struct User: Decodable, Sendable, Hashable {
        var id: String
        var display_name: String?
        var images: [Image]?
        var uri: String?
        /// Deprecated and removed for development-mode apps (February 2026). Present for extended-quota apps.
        var product: String?
    }

    struct PublicUser: Decodable, Sendable, Hashable {
        var id: String
        var display_name: String?
    }

    /// `{ href, total }` stub on simplified playlists.
    struct ItemsRef: Decodable, Sendable, Hashable {
        var href: String?
        var total: Int?
    }

    struct SimplifiedPlaylist: Decodable, Sendable, Hashable {
        var id: String
        var name: String
        var description: String?
        var images: [Image]?
        var owner: PublicUser?
        var `public`: Bool?
        var collaborative: Bool?
        var snapshot_id: String?
        var uri: String?
        /// Current name for the track reference.
        var items: ItemsRef?
        /// Deprecated name, still sent by some responses.
        var tracks: ItemsRef?
    }

    struct PlaylistItem: Decodable, Sendable, Hashable {
        var added_at: String?
        var is_local: Bool?
        /// Current field (February 2026).
        var item: Track?
        /// Deprecated field with the same shape.
        var track: Track?

        var content: Track? { item ?? track }
    }

    struct Playlist: Decodable, Sendable, Hashable {
        var id: String
        var name: String
        var description: String?
        var images: [Image]?
        var owner: PublicUser?
        var `public`: Bool?
        var collaborative: Bool?
        var snapshot_id: String?
        var uri: String?
        /// Present only for playlists the user owns or collaborates on (development mode).
        var items: Paging<PlaylistItem>?
        /// Deprecated name for `items`.
        var tracks: Paging<PlaylistItem>?

        var contents: Paging<PlaylistItem>? { items ?? tracks }

        var simplified: SimplifiedPlaylist {
            SimplifiedPlaylist(id: id, name: name, description: description, images: images, owner: owner, public: `public`,
                               collaborative: collaborative, snapshot_id: snapshot_id, uri: uri,
                               items: contents.map { ItemsRef(href: $0.href, total: $0.total) }, tracks: nil)
        }
    }

    struct SearchResponse: Decodable, Sendable, Hashable {
        var tracks: Paging<Track>?
        var albums: Paging<SimplifiedAlbum>?
        var artists: Paging<Artist>?
        var playlists: Paging<SimplifiedPlaylist>?
    }

    struct FollowedArtists: Decodable, Sendable, Hashable {
        var artists: CursorPaging<Artist>
    }

    /// `/artists/{id}/top-tracks`.
    struct TopTracks: Decodable, Sendable, Hashable {
        var tracks: [Track]
    }

    /// `/artists/{id}/related-artists`.
    struct Artists: Decodable, Sendable, Hashable {
        var artists: [Artist]
    }

    struct NewReleases: Decodable, Sendable, Hashable {
        var albums: Paging<SimplifiedAlbum>
    }

    struct Device: Decodable, Sendable, Hashable {
        var id: String?
        var is_active: Bool?
        var is_private_session: Bool?
        var is_restricted: Bool?
        var name: String
        var type: String?
        var volume_percent: Int?
        var supports_volume: Bool?
    }

    struct Devices: Decodable, Sendable, Hashable {
        var devices: [Device]
    }

    struct PlaybackState: Decodable, Sendable, Hashable {
        var device: Device?
        var repeat_state: String?
        var shuffle_state: Bool?
        var progress_ms: Int?
        var is_playing: Bool
        var item: Track?
        var currently_playing_type: String?
    }

    struct Snapshot: Decodable, Sendable, Hashable {
        var snapshot_id: String?
    }

    /// Web API error body: `{"error": {"status": 403, "message": "...", "reason": "PREMIUM_REQUIRED"}}`.
    struct APIErrorBody: Decodable, Sendable {
        struct Inner: Decodable, Sendable {
            var status: Int?
            var message: String?
            var reason: String?
        }
        var error: Inner
    }

    /// Accounts service error body: `{"error": "invalid_grant", "error_description": "..."}`.
    struct AuthErrorBody: Decodable, Sendable {
        var error: String
        var error_description: String?
    }
}

/// Decodes a value, or nil if that element is `null` or malformed.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

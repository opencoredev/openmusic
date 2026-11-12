import Foundation

/// Which sample data a mock provider serves.
public enum MockDataset: String, Sendable {
    /// Invented artists and procedural artwork (tests, snapshots, UI work).
    case sample
    /// Real chart albums with real cover art and a made-up listener, for screenshots (`DemoCatalog.swift`).
    /// Debug builds only: Release builds have no demo data and serve `sample` instead.
    case demo
}

/// A deterministic music catalog for one mock provider.
/// The `sample` dataset is invented: none of its names refers to a real artist or release. The `demo` dataset
/// (Debug builds only) uses real chart albums; see `DemoCatalog.swift`.
public struct MockCatalog: Sendable {
    public let provider: ProviderID
    public let dataset: MockDataset
    public internal(set) var artists: [Artist] = []
    public internal(set) var albums: [Album] = []
    public internal(set) var albumTracks: [String: [Track]] = [:]
    public internal(set) var playlists: [Playlist] = []
    public internal(set) var playlistTracks: [String: [Track]] = [:]
    public internal(set) var bios: [String: String] = [:]

    public var allTracks: [Track] { albums.flatMap { albumTracks[$0.providerID] ?? [] } }

    public init(provider: ProviderID, dataset: MockDataset = .sample) {
        #if DEBUG
        if dataset == .demo {
            self.init(demo: provider)
            return
        }
        #endif
        self.init(sample: provider)
    }

    private init(sample provider: ProviderID) {
        self.provider = provider
        self.dataset = .sample
        var rng = SeededRandom(seed: fnv1a("catalog-\(provider.rawValue)"))
        let names = provider == .youtubeMusic ? Self.ytArtists : Self.spArtists
        let albumTitles = (provider == .youtubeMusic ? Self.ytAlbums : Self.spAlbums)
        var titlePool = Self.songTitles.shuffled(using: &rng)
        var albumCursor = 0

        for (ai, name) in names.enumerated() {
            let artistID = "\(provider.short)-ar\(ai)"
            let listeners = 1 + rng.int(0..<40)
            artists.append(Artist(
                providerID: artistID, provider: provider, name: name,
                artwork: MockArtwork.artwork("portrait", artistID),
                subtitle: provider == .spotify ? "\(listeners).\(rng.int(0..<10))M monthly listeners" : "\(listeners).\(rng.int(0..<10))M subscribers"
            ))
            bios[artistID] = Self.bio(for: name, rng: &rng)

            let count = 2 + rng.int(0..<2)
            for k in 0..<count {
                let title = albumTitles[albumCursor % albumTitles.count]
                albumCursor += 1
                let albumID = "\(provider.short)-al\(albums.count)"
                let kind: AlbumKind = k == count - 1 && rng.unit() > 0.4 ? (rng.unit() > 0.5 ? .single : .ep) : .album
                let trackCount = kind == .album ? 8 + rng.int(0..<5) : (kind == .ep ? 4 : 1 + rng.int(0..<2))
                var tracks: [Track] = []
                for t in 0..<trackCount {
                    if titlePool.isEmpty { titlePool = Self.songTitles.shuffled(using: &rng) }
                    let songTitle = kind == .single && t == 0 ? title : titlePool.removeLast()
                    tracks.append(Track(
                        providerID: "\(albumID)-t\(t)", provider: provider, title: songTitle,
                        artists: [ArtistRef(id: artistID, name: name)] + (rng.unit() > 0.88 ? [ArtistRef(id: "\(provider.short)-ar\((ai + 3) % names.count)", name: names[(ai + 3) % names.count])] : []),
                        album: AlbumRef(id: albumID, title: title),
                        duration: TimeInterval(140 + rng.int(0..<170)),
                        artwork: MockArtwork.artwork("art", albumID),
                        isExplicit: rng.unit() > 0.82,
                        trackNumber: t + 1
                    ))
                }
                albumTracks[albumID] = tracks
                albums.append(Album(
                    providerID: albumID, provider: provider, title: title,
                    artists: [ArtistRef(id: artistID, name: name)],
                    year: 2014 + rng.int(0..<12),
                    artwork: MockArtwork.artwork("art", albumID),
                    kind: kind, trackCount: trackCount,
                    isExplicit: tracks.contains(where: \.isExplicit)
                ))
            }
        }

        let all = allTracks
        let playlistNames = provider == .youtubeMusic ? Self.ytPlaylists : Self.spPlaylists
        for (pi, entry) in playlistNames.enumerated() {
            let id = "\(provider.short)-pl\(pi)"
            let size = 18 + rng.int(0..<50)
            var picked: [Track] = []
            var seen = Set<String>()
            while picked.count < min(size, all.count) {
                let t = all[rng.int(0..<all.count)]
                if seen.insert(t.id).inserted { picked.append(t) }
            }
            playlistTracks[id] = picked
            playlists.append(Playlist(
                providerID: id, provider: provider, title: entry.title,
                owner: entry.mine ? "Sample Listener" : provider.displayName,
                artwork: MockArtwork.artwork("art", id),
                trackCount: picked.count,
                summary: entry.summary,
                isEditable: entry.mine,
                extra: entry.title == "Liked Music" ? [Playlist.likedSongsKey: "1"] : [:]
            ))
        }
    }

    // MARK: Lookups

    public func album(_ id: String) -> Album? { albums.first { $0.providerID == id } }
    public func artist(_ id: String) -> Artist? { artists.first { $0.providerID == id } }
    public func playlist(_ id: String) -> Playlist? { playlists.first { $0.providerID == id } }
    public func albums(by artistID: String) -> [Album] { albums.filter { $0.artists.first?.id == artistID } }
    public func tracks(by artistID: String) -> [Track] { allTracks.filter { $0.artists.contains { $0.id == artistID } } }

    public mutating func addPlaylist(_ playlist: Playlist) {
        playlists.insert(playlist, at: 0)
        playlistTracks[playlist.providerID] = []
    }

    public mutating func append(_ tracks: [Track], to playlistID: String) {
        playlistTracks[playlistID, default: []].append(contentsOf: tracks)
        if let i = playlists.firstIndex(where: { $0.providerID == playlistID }) {
            playlists[i].trackCount = playlistTracks[playlistID]?.count
        }
    }

    public mutating func insert(_ tracks: [Track], at position: Int, into playlistID: String) {
        var list = playlistTracks[playlistID, default: []]
        list.insert(contentsOf: tracks, at: max(0, min(position, list.count)))
        playlistTracks[playlistID] = list
        if let i = playlists.firstIndex(where: { $0.providerID == playlistID }) {
            playlists[i].trackCount = list.count
        }
    }

    public mutating func remove(_ ids: Set<String>, from playlistID: String) {
        playlistTracks[playlistID]?.removeAll { ids.contains($0.id) }
        if let i = playlists.firstIndex(where: { $0.providerID == playlistID }) {
            playlists[i].trackCount = playlistTracks[playlistID]?.count
        }
    }

    // MARK: Lyrics

    public func lyrics(for track: Track) -> Lyrics? {
        var rng = SeededRandom(seed: fnv1a("lyrics-\(track.id)"))
        // About one track in eight is instrumental (none in the demo, so every screenshot has lyrics).
        if rng.unit() < 0.12, dataset == .sample { return nil }
        let synced = provider == .youtubeMusic || rng.unit() > 0.3
        let verses = Self.lyricVerses.shuffled(using: &rng)
        var lines: [LyricLine] = []
        var time: TimeInterval = 6 + rng.unit() * 6
        let duration = track.duration ?? 200
        for (vi, verse) in verses.prefix(5).enumerated() {
            for line in verse {
                lines.append(LyricLine(time: synced ? time : nil, text: line))
                time += 3.2 + rng.unit() * 2.6
            }
            if vi < 4 {
                lines.append(LyricLine(time: synced ? time : nil, text: ""))
                time += 2.5
            }
            if time > duration - 10 { break }
        }
        return Lyrics(lines: lines, source: synced ? "Synced lyrics" : "Lyrics")
    }

    // MARK: Pools

    private static let ytArtists = ["Mara Vale", "The Lanterns", "Okapi", "June Harlow", "Echo Park Kids", "Sol Rivera", "Nova Lux", "Harbor & Pine", "Kestrel", "Lumen Drive"]
    private static let spArtists = ["Ivy Crane", "Coastal Static", "Rue Marlowe", "Night Swimmer", "Atlas Bloom", "The Velvet Arcade", "Tomo Hart", "Wren & Wilder", "Saffron Days", "Low Orbit"]

    private static let ytAlbums = ["Glass Harbor", "Northern Lights", "Paper Moons", "Afterglow", "Static Bloom", "City of Echoes", "Golden Hour Radio", "Satellite Hearts", "Low Tide", "Wildflower Season", "Neon Rain", "Undertow", "Silver Lining", "Late Bloomer", "Overpass", "Field Notes", "Sunday Static", "Blue Hour", "Copper Sky", "Driftwood", "Parallel Lines", "Monochrome", "Soft Focus", "Heatwave", "The Long Way", "Kites", "Open Water", "Signals"]
    private static let spAlbums = ["Velvet Hours", "Midnight Drive", "Polaroid Summer", "Quiet Machines", "Gravity Well", "Lemon Light", "Tidal", "Cassette Dreams", "Hollow Pines", "Ultraviolet", "Slow Burn", "Arcade Fire Escape", "Sea Glass", "Moth & Flame", "Postcards", "Sundial", "Echo Chamber", "Paper Planes", "Night Market", "Small Hours", "Bright Side", "Rivers", "Cinder", "Orbit", "Hourglass", "Wanderer", "Lowlands", "Daybreak"]

    private static let songTitles = [
        "Midnight Drive", "Glass Harbor", "Paper Planes", "Northern Lights", "Slow Burn", "Afterglow", "Static Bloom",
        "Velvet Hours", "Low Tide", "City of Echoes", "Golden Hour", "Satellite", "Wildflower", "Neon Rain", "Undertow",
        "Silver Lining", "Coastline", "Daydreamer", "Half Light", "Tell Me Twice", "Runaway Sun", "Ghost Town Gold",
        "Chasing Planes", "Better Weather", "Ferris Wheel", "Lighthouse", "Two Hearts, One Radio", "Ocean Avenue",
        "Little Fires", "Phosphor", "Blue Static", "Honey & Smoke", "Sleepwalker", "Open Road", "Polaroids",
        "Carousel", "Every Other Summer", "Fault Lines", "Wishing Well", "Nightswimming in July", "Paper Crowns",
        "Strangers Again", "Signal Fire", "Slow Motion", "Fever Dream", "Tangerine", "Starlight Motel", "Echoes",
        "Rooftops", "Dreamland", "Heartbeat Radio", "Lost & Found", "Gravity", "Weightless", "Sugar Rush", "Hold On",
        "Gold Rush", "Driftwood", "Mirrorball", "Firefly", "Crystal Clear", "Holding Pattern", "After Hours",
        "Rewind", "Starling", "Bloom", "Cold Water", "Wonderland", "Kaleidoscope", "Moonlit", "Afterparty",
        "Shoreline", "Avalanche", "Daylight Savings", "Monday Morning", "Parade", "Skyline", "Lullaby",
    ]

    private static let ytPlaylists: [(title: String, summary: String?, mine: Bool)] = [
        ("Liked Music", "Your liked songs", false),
        ("Morning Coffee", "Gentle songs to start the day.", true),
        ("Supermix", "An endless mix of songs you love and new ones to discover.", false),
        ("Road Trip", nil, true),
        ("Chill Mix", "Laid-back tracks based on your listening.", false),
        ("Focus Flow", "Instrumental-leaning picks to keep you in the zone.", false),
        ("Throwback Jams", nil, true),
        ("Discover Mix", "New music picked for you, refreshed every Wednesday.", false),
    ]
    private static let spPlaylists: [(title: String, summary: String?, mine: Bool)] = [
        ("Daily Mix 1", "Ivy Crane, Night Swimmer, Atlas Bloom and more", false),
        ("Discover Weekly", "Your weekly mixtape of fresh music. Enjoy new music and deep cuts picked for you.", false),
        ("Late Night Drive", "For the long way home.", true),
        ("Release Radar", "Catch all the latest music from artists you follow.", false),
        ("Workout", nil, true),
        ("Rainy Day", "Cozy songs for grey skies.", true),
        ("Indie Gold", "The best indie tracks of the last decade.", false),
        ("Dinner Party", nil, true),
    ]

    private static let lyricVerses: [[String]] = [
        ["I left the porch light on for you", "In case the night forgot your name", "The radio is humming low", "And every song still sounds the same"],
        ["We were running down the avenue", "With our pockets full of rain", "You said the city never sleeps", "But it was dreaming all the same"],
        ["Hold on, hold on", "To the shape of the morning", "Hold on, hold on", "Till the light comes pouring in"],
        ["Paper planes across the ceiling", "Every one a wish we made", "Counting down the summer evenings", "Watching all the colors fade"],
        ["And oh, it's a long way down", "From the top of the Ferris wheel", "But I'd ride it again and again", "Just to feel the way I feel"],
        ["Static on the line tonight", "Your voice is coming through in waves", "Tell me that you're on your way", "Tell me something that can stay"],
        ["We don't need the stars to shine", "We've got headlights and a song", "Turn it up and roll the windows down", "Sing it loud and sing along"],
        ["Low tide, low tide", "Leaves the secrets on the sand", "Low tide, low tide", "Puts the ocean in my hands"],
        ["Golden hour on the overpass", "Shadows long enough to hide", "I could stay here for a lifetime", "With the whole world passing by"],
        ["Every time I close my eyes", "I'm back where we began", "Two kids and a borrowed car", "And no idea of any plan"],
    ]

    private static func bio(for name: String, rng: inout SeededRandom) -> String {
        let city = ["Lisbon", "Melbourne", "Toronto", "Glasgow", "Portland", "Osaka", "Bristol", "Austin"][rng.int(0..<8)]
        let style = ["dream pop", "indie rock", "synth-pop", "alt-folk", "electronic soul", "bedroom pop"][rng.int(0..<6)]
        let year = 2010 + rng.int(0..<12)
        return "\(name) formed in \(city) in \(year), mixing \(style) with hazy field recordings and big, singable choruses. "
            + "Their self-released debut spread through late-night playlists before a run of sold-out club shows. "
            + "The newest record trades bedroom-scale production for a full band, recorded live to tape over two weeks in a converted church. "
            + "On stage the songs stretch out into long, droning codas, and the band has become known for inviting the opening act back on for the last number. "
            + "Between records they score short films and run a small cassette label for friends' projects."
    }
}

extension ProviderID {
    var short: String { self == .youtubeMusic ? "yt" : "sp" }
}

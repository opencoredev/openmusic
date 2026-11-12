import Foundation

// Writes the wire fixtures for windows/tests/Medley.Core.Tests with the real Swift JSONEncoder and the real model
// sources, plus dumps of the mock catalogs the C# port must reproduce. Run through generate.sh.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// Default JSONEncoder output, with sorted keys only so reruns don't churn the fixtures (Swift's key order is otherwise
// random per run; the tests compare objects structurally and scalar or array values byte for byte).
func write<T: Encodable>(_ name: String, _ value: T, sorted: Bool = true) throws {
    let encoder = JSONEncoder()
    if sorted { encoder.outputFormatting = [.sortedKeys] }
    try encoder.encode(value).write(to: out.appendingPathComponent("\(name).json"))
}

let uid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
let uid2 = UUID(uuidString: "0B1D3C5A-7E9F-4A2B-8C6D-1E3F5A7B9C0D")!
let full = Track(
    providerID: "dQw4w9WgXcQ", provider: .youtubeMusic, title: "Never Gonna Give You Up",
    artists: [ArtistRef(id: "UCuAXFkgsw1L7xaCfnd5JJOw", name: "Rick Astley"), ArtistRef(name: "Guest")],
    album: AlbumRef(id: "MPREb_abc", title: "Whenever You Need Somebody"),
    duration: 213.5,
    artwork: Artwork(images: [ArtworkImage(url: URL(string: "https://lh3.googleusercontent.com/abc=w120-h120")!, width: 120, height: 120),
                              ArtworkImage(url: URL(string: "https://lh3.googleusercontent.com/abc=w544-h544")!)]),
    isExplicit: true, isPlayable: true, trackNumber: 1, extra: ["setVideoId": "56B44F6D10557CC6"]
)
let minimal = Track(providerID: "4uLU6hMCjMI75M1A2tKUQC", provider: .spotify, title: "Minimal")
let album = Album(providerID: "MPREb_abc", provider: .youtubeMusic, title: "Whenever You Need Somebody", artists: [ArtistRef(id: "UC1", name: "Rick Astley")], year: 1987, kind: .album, trackCount: 10)

try write("track-full", full)
try write("track-minimal", minimal)
try write("context-album", PlaybackContext.album(album))
try write("context-radio", PlaybackContext.radio(title: "Rick Astley", seedID: "RDAMVM1", provider: .youtubeMusic))
try write("context-autoplay", PlaybackContext.autoplay)
let entry = QueueEntry(track: full, isUserQueued: true, context: .album(album), uid: uid)
let autoEntry = QueueEntry(track: minimal, isAutoplay: true, context: .autoplay, uid: uid2)
try write("queue-entry", entry)
try write("queue-entry-autoplay", autoEntry)
try write("queue-entry-no-context", QueueEntry(track: minimal, uid: uid2))
let anchor = PlaybackAnchor(positionMs: 72000, positionAt: 1_800_000_000_123, isPlaying: true, rate: 1, durationMs: 297000, volume: 0.8, shuffle: false, repeat: .all)
try write("anchor", anchor)
try write("anchor-no-duration", PlaybackAnchor(positionMs: 1500.5, positionAt: 1_800_000_000_000, isPlaying: false, durationMs: nil, volume: 1, shuffle: true, repeat: .off))
let window = QueueWindow(entries: [entry, autoEntry], index: 1)
try write("queue-window", window)
try write("command-play", SyncCommand.play)
try write("command-seek", SyncCommand.seek(positionMs: 12345))
try write("command-volume", SyncCommand.setVolume(0.25))
try write("command-takeover", SyncCommand.takeOver(HandoffState(window: window, anchor: anchor)))
try write("command-result-ok", CommandResult.success)
try write("command-result-message", CommandResult(ok: false, message: "Nothing to play"))
try write("device-info", DeviceInfo(name: "Leo's Mac", platform: .mac, model: "Mac16,10", appVersion: "0.1"))
try write("setting-bool", true)
try write("setting-double", 2.5)
try write("setting-double-whole", 12.0)
try write("setting-int", 30)
try write("setting-recent-searches", ["daft punk", "AC/DC", "Beyoncé", "say \"hi\""])
// Settings text edge cases: SettingsSync compares values as text, so these must match byte for byte.
try write("setting-tricky-strings", ["line\u{2028}sep", "para\u{2029}sep", "tab\tend", "ctl\u{1}\u{1f}", "bs\u{8}ff\u{c}", "nl\nret\r", "del\u{7f}", "é🎧", "<a&b>'"])
try write("setting-small-double", 1e-05)
try write("setting-big-double", 1.5e20)
try write("setting-fraction-double", 0.1)
try write("lyrics", Lyrics(lines: [LyricLine(time: 12.5, text: "First line"), LyricLine(time: nil, text: "")], source: "LRCLIB"))
try write("media-item-album", MediaItem.album(album))
try write("media-item-track", MediaItem.track(minimal))
try write("account-info", AccountInfo(name: "Sample Listener", avatar: URL(string: "https://example.com/a.png"), detail: "Premium", id: "abc"))
let played = PlayedTrack(track: full, playedAt: Date(timeIntervalSince1970: 1_800_000_000), context: .album(album))
try write("player-snapshot", PlayerSnapshot(queue: [entry, autoEntry], currentIndex: 0, position: 42.25, shuffle: true, repeatMode: .one,
                                            originalOrder: [uid2, uid], recentlyPlayed: [played], savedAt: Date(timeIntervalSince1970: 1_800_000_100)))
try write("player-snapshot-empty", PlayerSnapshot(queue: [], currentIndex: nil, position: 0, shuffle: false, repeatMode: .off,
                                                  originalOrder: nil, recentlyPlayed: [], savedAt: Date(timeIntervalSince1970: 1_800_000_000)))

// Mock catalogs, sorted keys, for the C# port to match exactly.
struct CatalogDump: Encodable {
    var artists: [Artist]
    var albums: [Album]
    var albumTracks: [String: [Track]]
    var playlists: [Playlist]
    var playlistTracks: [String: [String]]
    var bios: [String: String]
    var lyrics: [String: Lyrics?]
}
for dataset in [MockDataset.sample, .demo] {
    for provider in ProviderID.allCases {
        let c = MockCatalog(provider: provider, dataset: dataset)
        var lyrics: [String: Lyrics?] = [:]
        for t in c.allTracks.prefix(12) { lyrics[t.id] = c.lyrics(for: t) }
        try write("catalog-\(dataset.rawValue)-\(provider.rawValue)", CatalogDump(
            artists: c.artists, albums: c.albums, albumTracks: c.albumTracks, playlists: c.playlists,
            playlistTracks: c.playlistTracks.mapValues { $0.map(\.id) }, bios: c.bios, lyrics: lyrics), sorted: true)
    }
}
print("wrote fixtures to \(out.path)")

// The demo dataset's source data for the C# MockCatalog (windows/src/Medley.Core/Mock/DemoCatalogData.json).
struct DemoSongOut: Encodable { var title: String; var seconds: Int; var explicit: Bool; var artists: [String]? }
struct DemoAlbumOut: Encodable {
    var key: String; var service: ProviderID; var title: String; var artists: [String]; var released: String
    var kind: AlbumKind; var genre: String; var copyright: String; var tracks: [DemoSongOut]
}
struct DemoDataOut: Encodable { var albums: [DemoAlbumOut]; var artistPhotos: [String: String] }
let demo = DemoDataOut(
    albums: DemoCatalogData.albums.map { a in
        DemoAlbumOut(key: a.key, service: a.service, title: a.title, artists: a.artists, released: a.released, kind: a.kind,
                     genre: a.genre, copyright: a.copyright,
                     tracks: a.tracks.map { DemoSongOut(title: $0.title, seconds: $0.seconds, explicit: $0.explicit, artists: $0.artists) })
    },
    artistPhotos: DemoCatalogData.artistPhotos)
let demoEncoder = JSONEncoder()
demoEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try demoEncoder.encode(demo).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote demo catalog data to \(CommandLine.arguments[2])")

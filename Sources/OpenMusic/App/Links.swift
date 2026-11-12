import Foundation
import OpenMusicCore

/// Public web links for "Copy Link". Providers can override with `extra["url"]`.
nonisolated enum WebLinks {
    static func url(for item: MediaItem) -> URL? {
        if let explicit = extra(item)["url"], let url = URL(string: explicit) { return url }
        switch (item, item.provider) {
        case (.track(let t), .youtubeMusic): return URL(string: "https://music.youtube.com/watch?v=\(t.providerID)")
        case (.track(let t), .spotify): return URL(string: "https://open.spotify.com/track/\(t.providerID)")
        case (.album(let a), .youtubeMusic):
            if let list = a.extra["playlistId"] ?? a.extra["audioPlaylistId"] { return URL(string: "https://music.youtube.com/playlist?list=\(list)") }
            return URL(string: "https://music.youtube.com/browse/\(a.providerID)")
        case (.album(let a), .spotify): return URL(string: "https://open.spotify.com/album/\(a.providerID)")
        case (.artist(let a), .youtubeMusic): return URL(string: "https://music.youtube.com/channel/\(a.providerID)")
        case (.artist(let a), .spotify): return URL(string: "https://open.spotify.com/artist/\(a.providerID)")
        case (.playlist(let p), .youtubeMusic):
            let id = p.providerID.hasPrefix("VL") ? String(p.providerID.dropFirst(2)) : p.providerID
            return URL(string: "https://music.youtube.com/playlist?list=\(id)")
        case (.playlist(let p), .spotify): return URL(string: "https://open.spotify.com/playlist/\(p.providerID)")
        }
    }

    private static func extra(_ item: MediaItem) -> [String: String] {
        switch item {
        case .track(let t): t.extra
        case .album(let a): a.extra
        case .artist(let a): a.extra
        case .playlist(let p): p.extra
        }
    }
}

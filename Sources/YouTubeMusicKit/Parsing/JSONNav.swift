import Foundation
import OpenMusicCore

/// A loosely typed InnerTube JSON object. Parsing stays inside `YTMusicAPI` (off the main actor);
/// only `Sendable` models leave it.
typealias JSONObject = [String: Any]

/// Small, forgiving navigation helpers for InnerTube's deep and irregular payloads.
/// Paths mix keys and integer indices: `node.o("contents", "0", "tabRenderer")`.
extension Dictionary where Key == String, Value == Any {
    func any(_ path: [String]) -> Any? {
        var node: Any? = self
        for key in path {
            if let dict = node as? JSONObject {
                node = dict[key]
            } else if let array = node as? [Any], let i = Int(key), array.indices.contains(i) {
                node = array[i]
            } else {
                return nil
            }
        }
        return node
    }

    func o(_ path: String...) -> JSONObject? { any(path) as? JSONObject }
    func a(_ path: String...) -> [Any] { any(path) as? [Any] ?? [] }
    func s(_ path: String...) -> String? { any(path) as? String }
    func b(_ path: String...) -> Bool? { any(path) as? Bool }

    /// Text of a `{runs: [...]}` or `{simpleText: ...}` node at `path`.
    func text(_ path: String...) -> String? {
        guard let node = any(path) as? JSONObject else { return nil }
        return YTText.plain(node)
    }

    /// The single key of a renderer wrapper like `{"musicShelfRenderer": {...}}`.
    var rendererKey: String? { keys.first { $0.hasSuffix("Renderer") || $0.hasSuffix("ViewModel") } }
}

enum YTText {
    static func plain(_ node: JSONObject?) -> String? {
        guard let node else { return nil }
        if let simple = node["simpleText"] as? String { return simple }
        if let content = node["content"] as? String { return content }
        let runs = node["runs"] as? [Any] ?? []
        let joined = runs.compactMap { ($0 as? JSONObject)?["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    static func runs(_ node: JSONObject?) -> [JSONObject] {
        (node?["runs"] as? [Any] ?? []).compactMap { $0 as? JSONObject }
    }

    /// Parses "3:47" or "1:02:03" into seconds.
    static func duration(_ text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for part in parts {
            guard let n = Int(part), part.count <= 2 || total == 0 else { return nil }
            total = total * 60 + n
        }
        return TimeInterval(total)
    }

    static func isYear(_ text: String) -> Bool {
        text.count == 4 && Int(text).map { (1800...2200).contains($0) } == true
    }

    static func number(in text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)
        return Int(digits)
    }
}

/// Walks a JSON tree in document order.
enum JSONWalk {
    /// Every value stored under `key`, depth first, in document order. Does not descend into matches.
    static func all(_ key: String, in node: Any?, limit: Int = .max) -> [Any] {
        var out: [Any] = []
        func visit(_ node: Any?) {
            guard out.count < limit else { return }
            if let dict = node as? JSONObject {
                for (k, v) in dict.sortedForWalk() {
                    if k == key { out.append(v); if out.count >= limit { return } } else { visit(v) }
                }
            } else if let array = node as? [Any] {
                for v in array { visit(v) }
            }
        }
        visit(node)
        return out
    }

    static func first(_ key: String, in node: Any?) -> Any? { all(key, in: node, limit: 1).first }
    static func firstObject(_ key: String, in node: Any?) -> JSONObject? { first(key, in: node) as? JSONObject }
}

private extension Dictionary where Key == String, Value == Any {
    /// Dictionaries are unordered; visit common container keys first so document order is roughly kept.
    func sortedForWalk() -> [(String, Any)] {
        if count <= 1 { return map { ($0.key, $0.value) } }
        let priority = ["header", "contents", "content", "tabs", "items", "continuationItems", "secondaryContents"]
        return sorted { lhs, rhs in
            let l = priority.firstIndex(of: lhs.key) ?? Int.max
            let r = priority.firstIndex(of: rhs.key) ?? Int.max
            return l == r ? lhs.key < rhs.key : l < r
        }
    }
}

// MARK: - Endpoints

/// What a tap on an InnerTube item leads to.
enum YTEndpoint {
    case watch(videoId: String, playlistId: String?, musicVideoType: String?)
    case watchPlaylist(playlistId: String)
    case browse(browseId: String, params: String?, pageType: String?)

    init?(_ node: JSONObject?) {
        guard let node else { return nil }
        if let w = node["watchEndpoint"] as? JSONObject, let id = w["videoId"] as? String {
            self = .watch(videoId: id, playlistId: w["playlistId"] as? String,
                          musicVideoType: w.s("watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType"))
        } else if let b = node["browseEndpoint"] as? JSONObject, let id = b["browseId"] as? String {
            self = .browse(browseId: id, params: b["params"] as? String,
                           pageType: b.s("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"))
        } else if let w = node["watchPlaylistEndpoint"] as? JSONObject, let id = w["playlistId"] as? String {
            self = .watchPlaylist(playlistId: id)
        } else if let w = node["watchEndpoint"] as? JSONObject, let id = w["playlistId"] as? String {
            self = .watchPlaylist(playlistId: id)
        } else {
            return nil
        }
    }

    var browseId: String? { if case .browse(let id, _, _) = self { id } else { nil } }
    var pageType: String? { if case .browse(_, _, let t) = self { t } else { nil } }
}

// MARK: - Artwork

enum YTArtwork {
    /// Square sizes we offer for Google image-server URLs (they can be resized by rewriting the suffix).
    static let squareSizes = [60, 120, 226, 544, 1080]

    /// Finds the first `thumbnails` array within `node` and expands it into multiple sizes.
    static func from(_ node: Any?) -> Artwork? {
        guard let list = JSONWalk.first("thumbnails", in: node) as? [Any] else { return nil }
        return from(thumbnails: list)
    }

    static func from(thumbnails list: [Any]) -> Artwork? {
        let given: [ArtworkImage] = list.compactMap { item in
            guard let t = item as? JSONObject, var raw = t["url"] as? String else { return nil }
            if raw.hasPrefix("//") { raw = "https:" + raw }
            guard let url = URL(string: raw) else { return nil }
            return ArtworkImage(url: url, width: t["width"] as? Int, height: t["height"] as? Int)
        }
        guard let best = given.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }) else { return nil }
        if let resized = resizable(best.url) {
            return Artwork(images: resized)
        }
        if let video = videoThumbnails(best.url) {
            return Artwork(images: video)
        }
        return Artwork(images: given)
    }

    /// lh3/yt3.googleusercontent.com and yt3.ggpht.com URLs end in `=w60-h60-l90-rj` (or `=s120...`).
    static func resizable(_ url: URL) -> [ArtworkImage]? {
        let string = url.absoluteString
        guard let host = url.host, host.hasSuffix("googleusercontent.com") || host.hasSuffix("ggpht.com"),
              let eq = string.lastIndex(of: "=") else { return nil }
        let base = string[..<eq]
        let suffix = string[string.index(after: eq)...]
        // Keep flags other than size/crop (e.g. "l90", "rj") so the server returns the same format.
        let flags = suffix.split(separator: "-").filter { part in
            !(part.hasPrefix("w") || part.hasPrefix("h") || part.hasPrefix("s")) || Int(part.dropFirst()) == nil
        }
        let tail = flags.isEmpty ? "" : "-" + flags.joined(separator: "-")
        return squareSizes.compactMap { size in
            URL(string: "\(base)=w\(size)-h\(size)\(tail)").map { ArtworkImage(url: $0, width: size, height: size) }
        }
    }

    /// i.ytimg.com/vi/<id>/<name>.jpg: offer the standard renditions.
    static func videoThumbnails(_ url: URL) -> [ArtworkImage]? {
        guard url.host?.hasSuffix("ytimg.com") == true else { return nil }
        let comps = url.pathComponents // ["/", "vi", "<id>", "file.jpg"]
        guard comps.count >= 4, comps[1] == "vi" || comps[1] == "vi_webp" else { return nil }
        let id = comps[2]
        let variants: [(String, Int, Int)] = [("mqdefault", 320, 180), ("hqdefault", 480, 360), ("sddefault", 640, 480)]
        return variants.compactMap { name, w, h in
            URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg").map { ArtworkImage(url: $0, width: w, height: h) }
        }
    }

    /// Artwork for a video id, used when a response has no thumbnail.
    static func forVideo(_ videoId: String) -> Artwork? {
        URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg").flatMap { videoThumbnails($0).map(Artwork.init(images:)) }
    }
}

import Foundation

/// Client for LRCLIB (https://lrclib.net), a free, keyless lyrics database with synced (LRC) lyrics.
///
/// Lookup order: `/api/get` with the exact signature (title, artist, album, duration),
/// then `/api/search` by title and artist, picking the closest match by duration.
/// Usable by any provider as a lyrics source or fallback.
public struct LRCLibClient: Sendable {
    /// Performs one GET and returns status code and body. Injected in tests.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Int, Data)

    public static let source = "LRCLIB"

    private let baseURL: URL
    private let fetch: Fetch

    public init(baseURL: URL = URL(string: "https://lrclib.net")!, fetch: Fetch? = nil) {
        self.baseURL = baseURL
        self.fetch = fetch ?? { request in
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await HTTP.session.data(for: request)
            } catch {
                throw ProviderError.network(error.localizedDescription)
            }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    /// One LRCLIB record.
    public struct Record: Decodable, Sendable, Hashable {
        public var id: Int
        public var trackName: String?
        public var artistName: String?
        public var albumName: String?
        public var duration: Double?
        public var instrumental: Bool?
        public var plainLyrics: String?
        public var syncedLyrics: String?

        public init(id: Int, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil, duration: Double? = nil,
                    instrumental: Bool? = nil, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
            self.id = id
            self.trackName = trackName
            self.artistName = artistName
            self.albumName = albumName
            self.duration = duration
            self.instrumental = instrumental
            self.plainLyrics = plainLyrics
            self.syncedLyrics = syncedLyrics
        }
    }

    /// Lyrics for a song, synced when LRCLIB has them, else plain. Nil when nothing matches.
    @concurrent
    public func lyrics(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) async throws -> Lyrics? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        // `/api/get` needs the full signature; LRCLIB matches duration within ±2 seconds.
        if let album, !album.isEmpty, let duration, duration > 0 {
            if let record = try await get(title: title, artist: artist, album: album, duration: duration),
               let lyrics = Self.lyrics(from: record) {
                return lyrics
            }
        }
        let candidates = try await search(title: title, artist: artist)
        guard let best = Self.bestMatch(in: candidates, duration: duration) else { return nil }
        return Self.lyrics(from: best)
    }

    public func get(title: String, artist: String, album: String, duration: TimeInterval) async throws -> Record? {
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        items.removeAll { $0.value?.isEmpty ?? true }
        let (status, data) = try await fetch(request(path: "/api/get", query: items))
        switch status {
        case 200: return try? JSONDecoder().decode(Record.self, from: data)
        case 404: return nil
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.server(status, "LRCLIB")
        }
    }

    public func search(title: String, artist: String) async throws -> [Record] {
        var items = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        let (status, data) = try await fetch(request(path: "/api/search", query: items))
        switch status {
        case 200: return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        case 404: return []
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.server(status, "LRCLIB")
        }
    }

    private func request(path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        // LRCLIB asks clients to identify themselves.
        request.setValue("\(ProductInfo.name)/0.1 (native macOS music player)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Matching and parsing

    /// Prefers records within 3 s of `duration`, then synced lyrics, then the smallest duration gap.
    public static func bestMatch(in records: [Record], duration: TimeInterval?) -> Record? {
        let withText = records.filter { $0.instrumental == true || hasText($0.syncedLyrics) || hasText($0.plainLyrics) }
        let pool: [Record]
        if let duration, duration > 0 {
            let close = withText.filter { abs(($0.duration ?? .infinity) - duration) <= 3 }
            pool = close.isEmpty ? withText.filter { abs(($0.duration ?? .infinity) - duration) <= 10 } : close
        } else {
            pool = withText
        }
        return pool.min { a, b in
            let sa = hasText(a.syncedLyrics), sb = hasText(b.syncedLyrics)
            if sa != sb { return sa }
            guard let duration else { return false }
            return abs((a.duration ?? .infinity) - duration) < abs((b.duration ?? .infinity) - duration)
        }
    }

    public static func lyrics(from record: Record) -> Lyrics? {
        if let synced = record.syncedLyrics, hasText(synced) {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return Lyrics(lines: lines, source: source) }
        }
        if let plain = record.plainLyrics, hasText(plain) {
            let lines = plain.components(separatedBy: .newlines).map { LyricLine(text: $0.trimmingCharacters(in: .whitespaces)) }
            return Lyrics(lines: lines, source: source)
        }
        if record.instrumental == true {
            return Lyrics(lines: [LyricLine(text: "Instrumental")], source: source)
        }
        return nil
    }

    /// Parses LRC text into time-ordered lines.
    ///
    /// Handles `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss]`, `[mm:ss:xx]`, several timestamps on one line,
    /// and the `[offset:±ms]` tag (positive offsets shift lyrics earlier). Other tags are ignored.
    public static func parseLRC(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var lines: [(time: TimeInterval, order: Int, text: String)] = []
        var order = 0
        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTimestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let value = tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                    if let ms = Double(value) { offset = ms / 1000 }
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let lyric = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append((time, order, lyric))
                order += 1
            }
        }
        return lines
            .sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
            .map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
    }

    static func parseTimestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsPart: Double
        if parts.count == 3 {
            // [mm:ss:xx] (hundredths after a colon)
            guard let s = Int(parts[1]), let f = Int(parts[2]) else { return nil }
            secondsPart = Double(s) + Double(f) / pow(10, Double(parts[2].count))
        } else {
            guard let s = Double(parts[1]), parts[1].first?.isNumber == true else { return nil }
            secondsPart = s
        }
        guard secondsPart >= 0, secondsPart < 60 else { return nil }
        return TimeInterval(minutes * 60) + secondsPart
    }

    private static func hasText(_ s: String?) -> Bool {
        guard let s else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

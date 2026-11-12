import Foundation
import OpenMusicCore

/// The parts of a `/player` response the resolver needs.
struct PlayerInfo: Sendable {
    struct Format: Sendable, Hashable {
        var itag: Int
        var mimeType: String
        var bitrate: Int
        var url: URL?
        var isCiphered: Bool
        var contentLength: Int?
        var loudnessDb: Double?
        var audioTrackDefault: Bool

        var isAudio: Bool { mimeType.hasPrefix("audio/") }
        /// AVPlayer plays AAC in MP4. It can't play WebM/Opus.
        var isAVPlayerCompatible: Bool { mimeType.hasPrefix("audio/mp4") }
    }

    var status: String
    var reason: String?
    var formats: [Format]
    var hlsManifestURL: URL?
    var expiresIn: TimeInterval?
    var loudnessDb: Double?
    var title: String?
    /// `videoDetails.lengthSeconds`: the length of what this video plays, which can differ from the
    /// catalog's for the song (an album track mapped to its official video).
    var lengthSeconds: TimeInterval?

    init(_ root: JSONObject) {
        status = root.s("playabilityStatus", "status") ?? "ERROR"
        reason = root.s("playabilityStatus", "reason") ?? root.text("playabilityStatus", "errorScreen", "playerErrorMessageRenderer", "reason")
        let streaming = root.o("streamingData") ?? [:]
        let raw = (streaming["adaptiveFormats"] as? [Any] ?? []) + (streaming["formats"] as? [Any] ?? [])
        formats = raw.compactMap { item in
            guard let f = item as? JSONObject, let itag = f["itag"] as? Int, let mime = f["mimeType"] as? String else { return nil }
            return Format(
                itag: itag,
                mimeType: mime,
                bitrate: f["averageBitrate"] as? Int ?? f["bitrate"] as? Int ?? 0,
                url: (f["url"] as? String).flatMap(URL.init(string:)),
                isCiphered: f["signatureCipher"] != nil || f["cipher"] != nil,
                contentLength: (f["contentLength"] as? String).flatMap(Int.init),
                loudnessDb: f["loudnessDb"] as? Double,
                audioTrackDefault: f.b("audioTrack", "audioIsDefault") ?? true
            )
        }
        hlsManifestURL = (streaming["hlsManifestUrl"] as? String).flatMap(URL.init(string:))
        expiresIn = (streaming["expiresInSeconds"] as? String).flatMap(Double.init)
        loudnessDb = root.any(["playerConfig", "audioConfig", "loudnessDb"]) as? Double
        title = root.s("videoDetails", "title")
        lengthSeconds = root.s("videoDetails", "lengthSeconds").flatMap(TimeInterval.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Best directly playable audio format: AAC, unciphered, default audio track, highest bitrate.
    var bestDirectAudio: Format? {
        formats
            .filter { $0.isAudio && $0.isAVPlayerCompatible && $0.url != nil && !$0.isCiphered && $0.audioTrackDefault }
            .max { $0.bitrate < $1.bitrate }
    }
}

/// Resolves a YouTube Music track to an AVPlayer-playable audio stream.
///
/// Strategy (late 2026): ask InnerTube clients that still return playable googlevideo URLs without a
/// PO token or player-JS deciphering, in order, and verify what they return before handing it out.
///   1. VISIONOS (yt-dlp's only "JS-less" default client): HLS manifest + direct itag 140 URLs.
///   2. ANDROID_VR 1.60.19: direct itag 140 URLs (no HLS for VOD), also reports `loudnessDb`.
///   3. IOS: HLS manifest only (its direct formats need a PO token).
/// From each response we prefer the HLS audio-only rendition (itag 234, AAC ~128 kbps, the same audio as
/// itag 140) so AVPlayer skips video and gets exact durations; the direct URL is the fallback.
public actor YouTubeStreamResolver: StreamResolver {
    public struct Resolution: Sendable {
        public var stream: PlayableStream
        public var client: String
        public var itag: Int?
    }

    let client: InnerTubeClient
    private var cache: [String: Resolution] = [:]
    private var inFlight: [String: Task<Resolution, any Error>] = [:]
    /// The client that worked last; tried first next time.
    private var preferred: String?

    static let order: [(String, InnerTubeProfile)] = [
        ("VISIONOS", .visionOS),
        ("ANDROID_VR", .androidVR),
        ("IOS", .iOS),
    ]

    /// Replaces the InnerTube lookup. Tests only.
    private let fetchOverride: (@Sendable (String) async throws -> Resolution)?
    /// Uncached lookups performed. Tests and the probe.
    private(set) var fetchCount = 0

    init(client: InnerTubeClient, fetchOverride: (@Sendable (String) async throws -> Resolution)? = nil) {
        self.client = client
        self.fetchOverride = fetchOverride
    }

    public func resolveStream(for track: Track) async throws -> PlayableStream {
        try await resolve(videoId: track.providerID).stream
    }

    public func resolveStream(for track: Track, forceRefresh: Bool) async throws -> PlayableStream {
        try await resolve(videoId: track.providerID, forceRefresh: forceRefresh).stream
    }

    /// Resolve (or reuse a cached, unexpired resolution) and report which client produced it.
    /// `forceRefresh` drops the cached entry first: googlevideo can revoke a URL well before `expiresAt`.
    public func resolve(videoId: String, forceRefresh: Bool = false) async throws -> Resolution {
        if forceRefresh {
            cache.removeValue(forKey: videoId)
        } else if let hit = cache[videoId], let expiry = hit.stream.expiresAt, expiry.timeIntervalSinceNow > 600 {
            return hit
        }
        // An in-flight lookup is a new request to InnerTube, not the cached URL, so joining it is fine.
        if let task = inFlight[videoId] { return try await task.value }
        let task = Task { try await self.resolveUncached(videoId: videoId) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let result = try await task.value
        cache[videoId] = result
        if cache.count > 64, let oldest = cache.min(by: { ($0.value.stream.expiresAt ?? .distantPast) < ($1.value.stream.expiresAt ?? .distantPast) })?.key {
            cache.removeValue(forKey: oldest)
        }
        return result
    }

    /// Warm the cache for the next track so gapless/next-track starts don't wait on InnerTube.
    public func prefetch(videoId: String) {
        Task { _ = try? await self.resolve(videoId: videoId) }
    }

    public func invalidate(videoId: String) {
        cache.removeValue(forKey: videoId)
    }

    private func resolveUncached(videoId: String) async throws -> Resolution {
        fetchCount += 1
        if let fetchOverride { return try await fetchOverride(videoId) }
        do {
            return try await resolveOnce(videoId: videoId)
        } catch let ProviderError.unplayable(why) where why.contains("not a bot") {
            // The visitor id got flagged; a fresh one usually clears it.
            await client.refreshVisitor()
            return try await resolveOnce(videoId: videoId)
        }
    }

    private func resolveOnce(videoId: String) async throws -> Resolution {
        var clients = Self.order
        if let only = LaunchEnvironment.current["OPENMUSIC_YTM_CLIENT"] { // testing: force one client
            clients = clients.filter { $0.0 == only }
        }
        if let preferred, let i = clients.firstIndex(where: { $0.0 == preferred }), i > 0 {
            clients.insert(clients.remove(at: i), at: 0)
        }
        var failures: [String] = []
        for (name, profile) in clients {
            do {
                let info = try await client.player(videoId: videoId, profile: profile)
                guard info.status == "OK" else {
                    // LOGIN_REQUIRED ("confirm you're not a bot"), age gates and "made for kids" differ per client.
                    failures.append("\(name): \(info.reason ?? info.status)")
                    continue
                }
                if let resolution = try await usable(info, client: name, profile: profile) {
                    preferred = name
                    return resolution
                }
                failures.append("\(name): no playable audio")
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        throw ProviderError.unplayable(failures.joined(separator: "; "))
    }

    private func usable(_ info: PlayerInfo, client name: String, profile: InnerTubeProfile) async throws -> Resolution? {
        let expires = Date().addingTimeInterval(info.expiresIn ?? 6 * 3600)
        let headers = ["User-Agent": profile.userAgent]
        let mode = LaunchEnvironment.current["OPENMUSIC_YTM_STREAM"] // "hls" | "direct" (testing)

        // 1. HLS audio-only rendition. Preferred: AVPlayer gets exact durations and precise seeking from it.
        //    (YouTube's fragmented itag-140 MP4s carry the full duration in both `mvhd` and the fragments,
        //    and AVFoundation adds them up, reporting twice the real length.)
        if mode != "direct", let manifest = info.hlsManifestURL, let audio = try? await audioRendition(manifest, headers: headers) {
            let stream = PlayableStream(url: audio.url, httpHeaders: headers, expiresAt: expires,
                                        loudnessDB: audio.loudnessDb ?? info.bestDirectAudio?.loudnessDb ?? info.loudnessDb,
                                        mimeType: "application/vnd.apple.mpegurl", bitrate: audio.bitrate,
                                        duration: info.lengthSeconds)
            return Resolution(stream: stream, client: name + " HLS", itag: audio.itag)
        }
        // 2. Direct progressive URL (not from IOS: its direct formats need a PO token).
        if name != "IOS", mode != "hls", let format = info.bestDirectAudio, let url = format.url, await probe(url, headers: headers) {
            let stream = PlayableStream(url: url, httpHeaders: headers, expiresAt: expires,
                                        loudnessDB: format.loudnessDb ?? info.loudnessDb,
                                        mimeType: format.mimeType, bitrate: format.bitrate,
                                        duration: info.lengthSeconds)
            return Resolution(stream: stream, client: name, itag: format.itag)
        }
        return nil
    }

    /// A 2-byte range request: googlevideo answers 403 when a URL needs a PO token or is bound elsewhere.
    private func probe(_ url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 8)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await client.session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 206 || http.statusCode == 200
    }

    struct HLSRendition: Sendable {
        var url: URL
        var itag: Int?
        var bitrate: Int?
        var loudnessDb: Double?
    }

    /// Picks the AAC audio-only media playlist out of a YouTube HLS master playlist and checks it loads.
    private func audioRendition(_ manifest: URL, headers: [String: String]) async throws -> HLSRendition? {
        guard let master = try await fetchText(manifest, headers: headers),
              let rendition = Self.audioRendition(fromMaster: master),
              let media = try await fetchText(rendition.url, headers: headers), media.contains("#EXTINF") else { return nil }
        return rendition
    }

    private func fetchText(_ url: URL, headers: [String: String]) async throws -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await client.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// itag 234 is AAC ~128 kbps, 233 is AAC ~48 kbps.
    static func audioRendition(fromMaster text: String) -> HLSRendition? {
        var best: HLSRendition?
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard let uri = attrs["URI"], let url = URL(string: uri) else { continue }
            let itag = attrs["GROUP-ID"].flatMap(Int.init)
            // YT-EXT-ABSOLUTE-LOUDNESS is LUFS; YouTube's loudnessDb is relative to -14 LUFS.
            let loudness = attrs["YT-EXT-ABSOLUTE-LOUDNESS"].flatMap(Double.init).map { $0 + 14 }
            let rank = itag == 234 ? 2 : itag == 233 ? 1 : 0
            let bestRank = best?.itag == 234 ? 2 : best?.itag == 233 ? 1 : (best == nil ? -1 : 0)
            if rank > bestRank {
                best = HLSRendition(url: url, itag: itag, bitrate: itag == 234 ? 128_000 : itag == 233 ? 48_000 : nil, loudnessDb: loudness)
            }
        }
        return best
    }

    static func parseAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        func flush() {
            if !key.isEmpty { out[key] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in text {
            if inKey {
                if ch == "=" { inKey = false } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == ",", !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return out
    }
}

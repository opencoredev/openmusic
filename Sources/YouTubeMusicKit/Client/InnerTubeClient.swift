import Foundation
import MedleyCore

/// One InnerTube client identity (what the request claims to be).
struct InnerTubeProfile: Sendable, Hashable {
    var clientName: String
    var clientVersion: String
    /// Numeric id for `X-YouTube-Client-Name`.
    var clientId: Int
    var userAgent: String
    var host: String
    var extraContext: [String: String] = [:]
    var androidSdkVersion: Int?

    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    /// The music.youtube.com web client. The version is refreshed at runtime from `sw.js_data`.
    static func webRemix(version: String) -> InnerTubeProfile {
        InnerTubeProfile(clientName: "WEB_REMIX", clientVersion: version, clientId: 67, userAgent: safariUA, host: "music.youtube.com")
    }

    /// The YouTube Music Android app. The only client that returns *timed* lyrics.
    static let androidMusic = InnerTubeProfile(
        clientName: "ANDROID_MUSIC", clientVersion: "7.21.50", clientId: 21, userAgent: safariUA, host: "music.youtube.com"
    )

    // Stream clients (see `YouTubeStreamResolver`). Versions follow yt-dlp (2026-10).

    /// Apple Vision Pro app: direct (unciphered) URLs, no PO token, no player JS needed.
    static let visionOS = InnerTubeProfile(
        clientName: "VISIONOS", clientVersion: "1.02", clientId: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        host: "www.youtube.com",
        extraContext: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"]
    )

    /// Quest app: direct URLs and `loudnessDb`. Versions above 1.60 are SABR-only or blocked.
    static let androidVR = InnerTubeProfile(
        clientName: "ANDROID_VR", clientVersion: "1.60.19", clientId: 28,
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        host: "www.youtube.com",
        extraContext: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L"],
        androidSdkVersion: 32
    )

    /// iPhone app: HLS manifests (AVPlayer-native). Its direct formats need a PO token, so only HLS is used.
    static let iOS = InnerTubeProfile(
        clientName: "IOS", clientVersion: "21.26.4", clientId: 5,
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        host: "www.youtube.com",
        extraContext: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"]
    )
}

/// Low-level InnerTube transport: client context, visitor id, auth headers, and a short in-memory cache.
/// All network and JSON work runs on this actor, never on the main actor.
actor InnerTubeClient {
    static let fallbackWebRemixVersion = "1.20261027.10.00"

    private(set) var webRemixVersion = InnerTubeClient.fallbackWebRemixVersion
    private(set) var visitorData: String?
    private var credentials: YTMCredentials?
    /// Whether rotated cookies are written back to the Keychain (false for probe sessions).
    private var persistCredentials = true
    private var bootstrapTask: Task<Void, Never>?
    private var cache: [String: (expires: Date, data: Data)] = [:]
    private var cacheOrder: [String] = []
    private let cacheTTL: TimeInterval = 300
    private let cacheLimit = 48
    var hl = "en"
    var gl = "US"

    let session: URLSession

    /// `configuration`: tests only (a stub `URLProtocol`); the app uses an ephemeral session without cookies or cache.
    init(credentials: YTMCredentials? = nil, configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
        self.credentials = credentials
        // `hl` stays "en": a few heuristics read English labels ("Single", "EP", "songs").
        // `gl` follows the user's region so charts and availability match where they are.
        if let region = Locale.current.region?.identifier { gl = region }
    }

    var isSignedIn: Bool { credentials != nil }

    /// The session's cookies as they are now (rotations included). For the sign-in transfer.
    var currentCredentials: YTMCredentials? { credentials }

    func setCredentials(_ creds: YTMCredentials?, persist: Bool = true) {
        credentials = creds
        credentialGeneration &+= 1
        persistCredentials = persist
        clearCache()
        heldSwap = nil
    }

    /// Bumped on every replacement of the credentials (sign-in, swap, sign-out; not a cookie rotation, which keeps the
    /// account). A response's `Set-Cookie` updates apply only if the generation it was sent in is still current, so a
    /// slow answer to account A never rewrites account B's cookies.
    private var credentialGeneration = 0

    /// The provider's credential swap these credentials came with (`commit`); nil after credentials set any other way.
    /// Credentials given at init are swap 0, as the provider's count starts.
    private var heldSwap: Int? = 0

    /// The newest `commit` applied.
    private var commitEpoch = 0

    /// The provider's credential swaps, numbered by `epoch`: one that arrives after a newer one landed is ignored
    /// (returns false), so the client always ends with the provider's latest credentials. With `store`, first saves
    /// them to the Keychain (deletes them when nil) and throws, changing nothing, when that fails. Saving here, on
    /// this actor, keeps a cookie rotation from an in-flight request from landing between the save and the swap.
    func commit(_ creds: YTMCredentials?, persist: Bool, store: Bool, epoch: Int) throws -> Bool {
        guard epoch > commitEpoch else { return false }
        if store {
            if let creds { try creds.save() } else { try YTMCredentials.clear() }
        }
        commitEpoch = epoch
        setCredentials(creds, persist: persist)
        heldSwap = epoch
        return true
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Throws `PlaylistEditError.accountChanged` when the credentials a write would go out with now aren't the
    /// account it was checked for.
    func checkWriteBinding(_ binding: YTMWriteBinding?) throws {
        guard let binding else { return }
        guard let credentials else { throw PlaylistEditError.accountChanged }
        let held = if let expected = binding.accountID { YouTubeMusicProvider.accountID(credentials) == expected } else { heldSwap == binding.epoch }
        guard held else { throw PlaylistEditError.accountChanged }
    }

    /// The account switcher music.youtube.com shows under your avatar: every Google account signed in to the
    /// browser and every channel (brand account) under each. Parsed off the main actor (this client is an actor).
    /// Throws on a network/server failure (so the caller doesn't mistake it for "no channels"); an unreadable or
    /// unexpected body simply yields an empty list.
    func accountIdentities() async throws -> [AccountIdentity] {
        guard let credentials else { throw ProviderError.notSignedIn }
        var request = URLRequest(url: URL(string: "https://music.youtube.com/getAccountSwitcherEndpoint")!)
        request.setValue(InnerTubeProfile.safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        for (k, v) in credentials.headers() { request.setValue(v, forHTTPHeaderField: k) }
        let data = try await send(request, authenticated: true, generation: credentialGeneration)
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
        return AccountSwitcherParser.identities(fromJSON: Data(text.utf8))
    }

    func setLocale(hl: String, gl: String) {
        self.hl = hl
        self.gl = gl
    }

    // MARK: Bootstrap

    /// Reads the current WEB_REMIX version and a visitor id from `music.youtube.com/sw.js_data` (2.5 KB).
    func bootstrap() async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { await self.loadServiceWorkerData() }
        bootstrapTask = task
        await task.value
    }

    /// Drops the visitor id and fetches a new one.
    func refreshVisitor() async {
        visitorData = nil
        await loadServiceWorkerData()
    }

    private func loadServiceWorkerData() async {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/sw.js_data")!)
        request.setValue(InnerTubeProfile.safariUA, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let text = String(decoding: data, as: UTF8.self)
        if let version = Self.firstMatch(#"\b1\.20\d{6}\.\d{2}\.\d{2}\b"#, in: text) {
            webRemixVersion = version
        }
        if visitorData == nil, let visitor = Self.serviceWorkerVisitor(text) {
            visitorData = visitor
        }
    }

    /// `)]}'\n[["yt.sw.adr",null,[[[hl, gl, ..., visitorData (index 13), ...`
    static func serviceWorkerVisitor(_ text: String) -> String? {
        let body = text.hasPrefix(")]}'") ? String(text.dropFirst(4)) : text
        if let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [Any],
           let a = json.first as? [Any], a.count > 2, let b = a[2] as? [Any], let c = b.first as? [Any],
           let d = c.first as? [Any], d.count > 13, let visitor = d[13] as? String, visitor.hasPrefix("Cg") {
            return visitor
        }
        return firstMatch(#"Cg[A-Za-z0-9_\-]{20,}={0,2}"#, in: text)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Requests

    /// POST `youtubei/v1/<endpoint>` with the given client identity and return the parsed JSON.
    func post(
        _ endpoint: String,
        body: JSONObject = [:],
        profile: InnerTubeProfile? = nil,
        query: [URLQueryItem] = [],
        authenticated: Bool = true,
        cacheable: Bool = false,
        sendVisitor: Bool = true,
        binding: YTMWriteBinding? = nil
    ) async throws -> JSONObject {
        await bootstrap()
        // A bound write: the cookies are picked below, and nothing suspends between this check and the send.
        try checkWriteBinding(binding)
        let profile = profile ?? .webRemix(version: webRemixVersion)
        let useAuth = authenticated && credentials != nil && profile.host == "music.youtube.com"

        var client: JSONObject = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
            "hl": hl,
            "gl": gl,
            "userAgent": profile.userAgent,
        ]
        for (k, v) in profile.extraContext { client[k] = v }
        if let sdk = profile.androidSdkVersion { client["androidSdkVersion"] = sdk }
        let visitorData = sendVisitor ? self.visitorData : nil
        if let visitorData { client["visitorData"] = visitorData }
        var user: JSONObject = ["lockedSafetyMode": false]
        // Act as the chosen brand channel, selected by its delegated session id (same value as X-Goog-PageId),
        // the way youtube.com's own client does. A personal account has none, so this is omitted for it.
        if useAuth, let delegated = credentials?.delegatedSessionId { user["onBehalfOfUser"] = delegated }
        var payload = body
        payload["context"] = ["client": client, "user": user]

        var components = URLComponents(string: "https://\(profile.host)/youtubei/v1/\(endpoint)")!
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")] + query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(profile.clientId), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://\(profile.host)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(profile.host)/", forHTTPHeaderField: "Referer")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if useAuth, let credentials {
            for (k, v) in credentials.headers() { request.setValue(v, forHTTPHeaderField: k) }
        }

        let key = cacheable ? "\(useAuth)|\(components.url!.absoluteString)|\(String(decoding: request.httpBody ?? Data(), as: UTF8.self))" : nil
        if let key, let hit = cache[key], hit.expires > Date() {
            return try Self.object(hit.data)
        }

        if ProcessInfo.processInfo.environment["MEDLEY_YTM_DEBUG"] != nil, let body = request.httpBody {
            FileHandle.standardError.write(Data("→ \(components.url!.absoluteString)\n\(String(decoding: body, as: UTF8.self).prefix(600))\n".utf8))
        }
        let data = try await send(request, authenticated: useAuth, generation: credentialGeneration)
        let json = try Self.object(data)
        if self.visitorData == nil, sendVisitor, let v = json.s("responseContext", "visitorData") { self.visitorData = v }
        if let key { store(key, data) }
        return json
    }

    /// `generation`: the credentials the request was sent with (`credentialGeneration` when it was built).
    private func send(_ request: URLRequest, authenticated: Bool, generation: Int) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        if authenticated, generation == credentialGeneration, var creds = credentials, let url = request.url,
           creds.merge(setCookieHeaders: http.allHeaderFields, url: url) {
            credentials = creds
            // Best effort: the request goes on with the rotated cookies either way.
            if persistCredentials { try? creds.save() }
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw ProviderError.notSignedIn
        case 403: throw authenticated ? ProviderError.notSignedIn : ProviderError.server(403, Self.errorMessage(data))
        case 404: throw ProviderError.notFound
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.server(http.statusCode, Self.errorMessage(data))
        }
    }

    static func errorMessage(_ data: Data) -> String {
        if let json = try? object(data), let message = json.s("error", "message") { return message }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    static func object(_ data: Data) throws -> JSONObject {
        guard let json = try JSON.parse(data) as? JSONObject else { throw ProviderError.decoding("expected a JSON object") }
        return json
    }

    private func store(_ key: String, _ data: Data) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = (Date().addingTimeInterval(cacheTTL), data)
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    // MARK: Convenience

    func browse(_ browseId: String, params: String? = nil, cacheable: Bool = true, sendVisitor: Bool = true) async throws -> JSONObject {
        var body: JSONObject = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("browse", body: body, cacheable: cacheable, sendVisitor: sendVisitor)
    }

    /// Follows an encoded continuation token from `ContinuationToken`.
    func browseContinuation(_ token: String, cacheable: Bool = true) async throws -> JSONObject {
        if token.hasPrefix("q:") {
            let raw = String(token.dropFirst(2))
            return try await post("browse", query: [
                URLQueryItem(name: "ctoken", value: raw),
                URLQueryItem(name: "continuation", value: raw),
                URLQueryItem(name: "type", value: "next"),
            ], cacheable: cacheable)
        }
        let raw = token.hasPrefix("b:") ? String(token.dropFirst(2)) : token
        return try await post("browse", body: ["continuation": raw], cacheable: cacheable)
    }
}

/// The account a write must go out as: its datasync account id (`YouTubeMusicProvider.accountID`) the app checked, or,
/// without one, the provider's credential swap (`commit(_:persist:store:epoch:)`) it checked in.
struct YTMWriteBinding: Sendable, Hashable {
    let accountID: String?
    let epoch: Int
}

import Foundation

/// Shared URLSession tuned for an API client: HTTP/2, small cache, short timeouts.
public enum HTTP {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// For reads that must come from the service as it is now and from nothing else: a playlist edit's checks and every
    /// owner check (`/me`). No URL cache to read or fill, every request ignores local and remote caches, and no cookies
    /// are kept or sent, so no earlier response or session can label a token as another account.
    public static let uncachedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// Perform a request and return the body, mapping HTTP errors to `ProviderError`.
    public static func data(for request: URLRequest, session: URLSession = HTTP.session) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.notSignedIn
        case 404: throw ProviderError.notFound
        case 429: throw ProviderError.rateLimited
        default:
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw ProviderError.server(http.statusCode, body)
        }
    }
}

/// Loose JSON walking for APIs with deep, irregular payloads (InnerTube).
public enum JSON {
    public static func parse(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw ProviderError.decoding(error.localizedDescription) }
    }
}

public extension Dictionary where Key == String, Value == Any {
    subscript(path path: String...) -> Any? { value(at: path) }

    func value(at path: [String]) -> Any? {
        var node: Any? = self
        for key in path {
            if let dict = node as? [String: Any] {
                node = dict[key]
            } else if let array = node as? [Any], let i = Int(key), array.indices.contains(i) {
                node = array[i]
            } else {
                return nil
            }
        }
        return node
    }
}

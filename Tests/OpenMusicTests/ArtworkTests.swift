import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenMusic

/// Serves a small PNG, failing the first `failures[path]` requests for each path with a dropped connection.
private final class FlakyArtworkProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failures: [String: Int] = [:]
    nonisolated(unsafe) static var requests: [String: Int] = [:]
    static let lock = NSLock()
    static let png: Data = {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    static func set(failures count: Int, for path: String) {
        lock.withLock { failures[path] = count; requests[path] = 0 }
    }

    static func requestCount(_ path: String) -> Int { lock.withLock { requests[path] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let fail: Bool = Self.lock.withLock {
            Self.requests[path, default: 0] += 1
            let left = Self.failures[path] ?? 0
            if left > 0 { Self.failures[path] = left - 1 }
            return left > 0
        }
        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makePipeline() -> ArtworkPipeline {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FlakyArtworkProtocol.self]
    config.urlCache = nil
    return ArtworkPipeline(configuration: config)
}

@Suite struct ArtworkLoading {
    /// The judge saw covers stay placeholders until revisiting the page: a failed load was never retried.
    @Test func failedLoadRetriesWithBackoff() async {
        let path = "/retry-\(UUID().uuidString).png"
        FlakyArtworkProtocol.set(failures: 2, for: path)
        let image = await makePipeline().load(URL(string: "https://artwork.test\(path)")!, pixels: 64, retryDelays: [.milliseconds(20), .milliseconds(40)])
        #expect(image != nil)
        #expect(FlakyArtworkProtocol.requestCount(path) == 3)
    }

    /// A load that failed every attempt isn't remembered: the next request (a view reappearing) tries again.
    @Test func failureIsNotCached() async {
        let path = "/later-\(UUID().uuidString).png"
        let url = URL(string: "https://artwork.test\(path)")!
        let pipeline = makePipeline()
        FlakyArtworkProtocol.set(failures: 10, for: path)
        #expect(await pipeline.load(url, pixels: 64, retryDelays: []) == nil)
        FlakyArtworkProtocol.set(failures: 0, for: path)
        #expect(await pipeline.load(url, pixels: 64, retryDelays: []) != nil)
        // Now cached in memory: no further request.
        #expect(await pipeline.image(url, pixels: 64) != nil)
        #expect(FlakyArtworkProtocol.requestCount(path) == 1)
    }

    /// A view that went away stops retrying (it tries again when it comes back).
    @Test func cancelledCallerStopsRetrying() async {
        let path = "/gone-\(UUID().uuidString).png"
        FlakyArtworkProtocol.set(failures: 10, for: path)
        let pipeline = makePipeline()
        let url = URL(string: "https://artwork.test\(path)")!
        let task = Task { await pipeline.load(url, pixels: 64, retryDelays: [.seconds(30), .seconds(30)]) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let start = ContinuousClock.now
        #expect(await task.value == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(FlakyArtworkProtocol.requestCount(path) == 1)
    }
}

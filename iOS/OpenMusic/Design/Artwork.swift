import ImageIO
import OpenMusicCore
import SwiftUI

/// A decoded, display-ready bitmap. `CGImage` is immutable, so sharing it across threads is safe.
nonisolated struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Loads artwork: memory `NSCache` → `URLCache` on disk → network, then decodes and downsamples with ImageIO
/// to the displayed pixel size, all off the main actor. Same pipeline as the Mac app.
nonisolated final class ArtworkPipeline: Sendable {
    static let shared = ArtworkPipeline()

    private nonisolated(unsafe) let memory: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private let session: URLSession
    private let inflight = Inflight()

    private final class CacheEntry: @unchecked Sendable {
        let image: DecodedImage
        init(_ image: DecodedImage) { self.image = image }
    }

    private init() {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artwork", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    static func bucket(_ pixels: Int) -> Int {
        let buckets = [64, 128, 192, 256, 384, 512, 768, 1024, 1600]
        return buckets.first { $0 >= pixels } ?? 2048
    }

    private func key(_ url: URL, _ pixels: Int) -> NSString { "\(pixels)|\(url.absoluteString)" as NSString }

    /// Synchronous memory-cache lookup, cheap enough to call from `body`.
    func cached(_ url: URL, pixels: Int) -> CGImage? {
        memory.object(forKey: key(url, Self.bucket(pixels)))?.image.cgImage
    }

    func image(_ url: URL, pixels: Int) async -> DecodedImage? {
        let px = Self.bucket(pixels)
        let k = key(url, px)
        if let hit = memory.object(forKey: k) { return hit.image }
        let decoded = await inflight.run(k as String) { [session] in
            await Self.fetchAndDecode(url, pixels: px, session: session)
        }
        guard let decoded else { return nil }
        memory.setObject(CacheEntry(decoded), forKey: k, cost: decoded.cgImage.bytesPerRow * decoded.cgImage.height)
        return decoded
    }

    /// `image(_:pixels:)` with two retries for dropped connections.
    func load(_ url: URL, pixels: Int) async -> DecodedImage? {
        if let image = await image(url, pixels: pixels) { return image }
        for delay in [Duration.seconds(1), .seconds(3)] {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return nil }
            if let image = await image(url, pixels: pixels) { return image }
        }
        return nil
    }

    private static func fetchAndDecode(_ url: URL, pixels: Int, session: URLSession) async -> DecodedImage? {
        if MockArtwork.isMock(url) {
            return MockArtwork.render(url, pixels: pixels).map(DecodedImage.init)
        }
        let request = URLRequest(url: url)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        guard let image = downsample(data, pixels: pixels) else {
            session.configuration.urlCache?.removeCachedResponse(for: request)
            return nil
        }
        return image
    }

    static func downsample(_ data: Data, pixels: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map(DecodedImage.init)
    }

    /// Collapses concurrent requests for the same image into one.
    private actor Inflight {
        private var tasks: [String: Task<DecodedImage?, Never>] = [:]

        func run(_ key: String, _ work: @escaping @Sendable () async -> DecodedImage?) async -> DecodedImage? {
            if let task = tasks[key] { return await task.value }
            let task = Task(priority: .userInitiated) { await work() }
            tasks[key] = task
            let value = await task.value
            tasks[key] = nil
            return value
        }
    }
}

/// Artwork that fills its frame (square unless the caller crops). `points` is the displayed size, so only the
/// pixels needed are decoded. Shows a soft fill with a symbol while loading, never a spinner.
struct ArtworkView: View {
    let artwork: Artwork?
    var points: CGFloat
    var placeholder = "music.note"
    @Environment(\.displayScale) private var scale
    @State private var loaded: (url: URL, image: CGImage)?

    private var pixels: Int { Int(points * scale) }
    private var url: URL? { artwork?.url(minPixels: pixels) }

    var body: some View {
        let image = currentImage
        ZStack {
            Rectangle().fill(.fill.tertiary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: placeholder)
                    .font(.system(size: max(12, points * 0.3)))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            guard let url, currentImage == nil else { return }
            if let decoded = await ArtworkPipeline.shared.load(url, pixels: pixels) {
                withAnimation(.easeOut(duration: 0.2)) { loaded = (url, decoded.cgImage) }
            }
        }
    }

    private var currentImage: CGImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ArtworkPipeline.shared.cached(url, pixels: pixels)
    }
}

/// Nine colors sampled from artwork (a 3x3 grid), for the Now Playing backdrop's mesh. Saturation is raised a
/// little and lightness capped, so the backdrop carries the cover's color and white text still reads on it.
nonisolated struct ArtworkPalette: Equatable, Sendable {
    /// Row by row, top left first.
    var colors: [Color]

    var top: Color { colors[1] }
    var bottom: Color { colors[7] }

    static let neutral = ArtworkPalette(colors: (0..<9).map { i in Color(white: i < 3 ? 0.28 : i < 6 ? 0.2 : 0.12) })

    static func sample(_ image: CGImage) -> ArtworkPalette? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 3, height: 3))
        let px = data.bindMemory(to: UInt8.self, capacity: 36)
        // Memory order is top row first for this bitmap.
        let colors = (0..<9).map { i -> Color in
            let (r, g, b) = adjusted(Double(px[i * 4]) / 255, Double(px[i * 4 + 1]) / 255, Double(px[i * 4 + 2]) / 255)
            return Color(.sRGB, red: r, green: g, blue: b)
        }
        return ArtworkPalette(colors: colors)
    }

    /// Saturation x1.3, then luma (of the gamma values) between 0.1 and 0.42: white text keeps 4.5:1 or better.
    static func adjusted(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let luma0 = 0.2126 * r + 0.7152 * g + 0.0722 * b
        var (r, g, b) = (luma0 + (r - luma0) * 1.3, luma0 + (g - luma0) * 1.3, luma0 + (b - luma0) * 1.3)
        (r, g, b) = (min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)))
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cap = 0.42, floor = 0.1
        if luma > cap { let k = cap / luma; r *= k; g *= k; b *= k }
        if luma < floor { let lift = floor - luma; r += lift; g += lift; b += lift }
        return (r, g, b)
    }

    /// Palettes Now Playing already sampled, by artwork, so it can open on them.
    @MainActor private static var sampled: [URL: ArtworkPalette] = [:]

    @MainActor static func cached(_ artwork: Artwork?) -> ArtworkPalette? {
        artwork?.url(minPixels: 64).flatMap { sampled[$0] }
    }

    @MainActor static func remember(_ palette: ArtworkPalette, for artwork: Artwork?) {
        guard let url = artwork?.url(minPixels: 64) else { return }
        if sampled.count >= 200 { sampled.removeAll() }
        sampled[url] = palette
    }

    static func load(_ artwork: Artwork?) async -> ArtworkPalette? {
        guard let url = artwork?.url(minPixels: 64), let decoded = await ArtworkPipeline.shared.load(url, pixels: 64) else { return nil }
        let image = decoded.cgImage
        return await Task.detached(priority: .utility) { sample(image) }.value
    }
}

import CoreImage
import AppKit
import ImageIO
import MedleyCore
import SwiftUI

/// A decoded, display-ready bitmap. `CGImage` is immutable, so sharing it across threads is safe.
nonisolated struct DecodedImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Loads artwork: memory `NSCache` → `URLCache` on disk → network, then decodes and downsamples
/// with ImageIO to the displayed pixel size, all off the main thread.
nonisolated final class ArtworkPipeline: Sendable {
    static let shared = ArtworkPipeline()

    private nonisolated(unsafe) let memory: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private let session: URLSession
    private let inflight = Inflight()

    private final class CacheEntry: @unchecked Sendable {
        let image: DecodedImage
        init(_ image: DecodedImage) { self.image = image }
    }

    private convenience init() {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(ProductInfo.folderName)/Artwork", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 6
        self.init(configuration: config)
    }

    /// A pipeline with its own session (tests pass a stub protocol here).
    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    /// Waits between attempts when a load fails: a dropped connection or a throttled burst usually clears
    /// within a second or two. Failures are never cached, so a view that appears again tries again too.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(3)]

    /// Pixel sizes are bucketed so nearby sizes share one cache entry.
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

    /// `image(_:pixels:)` with retries: after a failed attempt it waits each of `retryDelays` in turn and tries
    /// again, unless the caller was cancelled (the view went away; it tries again when it comes back).
    func load(_ url: URL, pixels: Int, retryDelays: [Duration] = ArtworkPipeline.retryDelays) async -> DecodedImage? {
        if let image = await image(url, pixels: pixels) { return image }
        for delay in retryDelays {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return nil }
            if let image = await image(url, pixels: pixels) { return image }
        }
        return nil
    }

    func clearMemory() { memory.removeAllObjects() }

    func clearDisk() {
        session.configuration.urlCache?.removeAllCachedResponses()
        memory.removeAllObjects()
    }

    private static func fetchAndDecode(_ url: URL, pixels: Int, session: URLSession) async -> DecodedImage? {
        if url.scheme == MockArtwork.scheme {
            return MockArtwork.render(url, pixels: pixels).map(DecodedImage.init)
        }
        let request = URLRequest(url: url)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        guard let image = downsample(data, pixels: pixels, url: url) else {
            // A truncated or bad body must not stay in the URL cache, or every retry would decode it again.
            session.configuration.urlCache?.removeCachedResponse(for: request)
            return nil
        }
        return image
    }

    /// Each fetched image's width in pixels before downsampling, by URL (the artist hero caps how far it scales a photo).
    private nonisolated(unsafe) static let sourceWidths: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 1000
        return cache
    }()

    /// The width in pixels of the image at `url` as served, once it has been fetched in this run; nil for generated art.
    static func sourceWidth(of url: URL) -> Int? { sourceWidths.object(forKey: url.absoluteString as NSString)?.intValue }

    static func downsample(_ data: Data, pixels: Int, url: URL? = nil) -> DecodedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        if let url, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int {
            sourceWidths.setObject(NSNumber(value: width), forKey: url.absoluteString as NSString)
        }
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

        /// The fetch runs in its own task, so a caller that is cancelled (a cell scrolled away) doesn't cancel
        /// it: the image still lands in the memory cache for the next caller.
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

/// Artwork that fills its frame. Give it the size it will be displayed at (in points) so it decodes
/// only the pixels it needs. Shows a soft tint while loading, and never a spinner.
///
/// Loading is built so an image on screen never stays a placeholder: a failed load retries with backoff
/// (and again whenever the view reappears), a load that finished while the view was away is picked up from the
/// memory cache when it comes back, and once an image is showing it stays until a sharper one for the same
/// artwork replaces it, so resizing or re-rendering never drops it back to the placeholder.
struct ArtworkView: View {
    let artwork: Artwork?
    /// The displayed width in points.
    var size: CGFloat
    var cornerRadius: CGFloat = Metrics.artworkRadius
    var circle = false
    var symbol = "music.note"
    /// Which part of a cropped image stays in view, from 0 (its top edge) to 1 (its bottom edge).
    var focusY: CGFloat = 0.5

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: Loaded?

    private struct Loaded {
        /// Which artwork this is, whatever size was fetched (see `ArtworkView.identity`).
        let identity: String
        let url: URL
        let image: CGImage
    }

    private var pixels: Int { Int((size * displayScale).rounded(.up)) }
    private var url: URL? { artwork?.url(minPixels: pixels) }
    /// Same for every size of one piece of artwork.
    private var identity: String { artwork?.images.first?.url.absoluteString ?? "" }

    var body: some View {
        let url = url
        let pixels = pixels
        let identity = identity
        // An exact-size cached decode first; otherwise whatever size of this artwork was shown last.
        let image = url.flatMap { ArtworkPipeline.shared.cached($0, pixels: pixels) }
            ?? (loaded.flatMap { $0.identity == identity && url != nil ? $0.image : nil })
        let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // The fill image sits in an overlay so it can never grow the view past the frame it was given.
        Rectangle().fill(.quaternary)
            // The frame's and the image's focus lines meet, so a fill that overflows the frame by `d` points
            // is shifted up by `focusY × d`.
            .alignmentGuide(.artworkFocus) { $0.height * focusY }
            .overlay(alignment: Alignment(horizontal: .center, vertical: .artworkFocus)) {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .alignmentGuide(.artworkFocus) { $0.height * focusY }
                        .transition(.opacity)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: min(56, max(10, size * 0.26)), weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(shape)
            .overlay { ArtworkOutline(circle: circle, cornerRadius: cornerRadius) }
        // Runs on every appearance, so a view that comes back retries a load that failed or was cut short.
        .task(id: "\(ArtworkPipeline.bucket(pixels))|\(url?.absoluteString ?? "")") {
            guard let url else { return }
            if let hit = ArtworkPipeline.shared.cached(url, pixels: pixels) {
                // Cached after `body` last ran (a load that finished while this view was away): show it now.
                if loaded?.url != url { loaded = Loaded(identity: identity, url: url, image: hit) }
                return
            }
            let showing = loaded?.identity == identity
            guard let fetched = await ArtworkPipeline.shared.load(url, pixels: pixels), !Task.isCancelled else { return }
            let next = Loaded(identity: identity, url: url, image: fetched.cgImage)
            if showing {
                loaded = next
            } else {
                withAnimation(Motion.artwork) { loaded = next }
            }
        }
    }
}

extension VerticalAlignment {
    private enum ArtworkFocus: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context.height / 2 }
    }

    /// Lines up an artwork frame and its overflowing image at the same fraction of their heights.
    static let artworkFocus = VerticalAlignment(ArtworkFocus.self)
}

/// Loads the dominant artwork for backgrounds (full-screen player, artist hero).
struct ArtworkBackdrop: View {
    let artwork: Artwork?
    /// Blur radius in points at full-window size.
    var blur: CGFloat = 60
    /// Size of the copy that's blurred. 256 keeps a recognizable picture (an artist banner's surround); the
    /// full-screen player blurs a 64 px copy, so no shape in the cover survives as an edge or band across the screen.
    var sourcePixels: Int = 256
    /// White text on it: black over the picture, at least `minimum`, more where the blurred copy's middle band (what a
    /// short strip shows of a square cover) is so pale that white at `opacity` would read under 4.5:1 (`CaptionShade`).
    var caption: (minimum: Double, opacity: Double)? = nil

    @State private var image: CGImage?
    /// The black the caption needs over this picture, worked out once per image.
    @State private var captionShade: Double?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay {
                if let caption { Color.black.opacity(max(caption.minimum, captionShade ?? caption.minimum)) }
            }
            .clipped()
        // Keyed on the blur too: a new radius re-blurs and cross-fades over the image already showing.
        .task(id: "\(blur)|\(sourcePixels)|\(artwork?.url(minPixels: sourcePixels)?.absoluteString ?? "")") {
            guard let url = artwork?.url(minPixels: sourcePixels) else { image = nil; return }
            // Blur a small copy once, off the main thread. Compositing a pre-blurred image is far cheaper
            // than a live full-window blur filter, and looks the same in every renderer.
            guard let source = await ArtworkPipeline.shared.load(url, pixels: sourcePixels)?.cgImage, !Task.isCancelled else { return }
            // ~256 px stretched across a ~1500 pt window; the radius scales with the copy, so the blur's reach on
            // screen is the same, and the 64 px copy is blurred half again as far for an even wash of color.
            let scale = CGFloat(source.width) / 256
            let radius = blur / 6 * scale * (sourcePixels < 256 ? 1.5 : 1)
            let caption = caption
            let (blurred, shade) = await Task.detached(priority: .userInitiated) {
                let blurred = Self.blurred(source, radius: radius)
                let shade = caption.map { CaptionShade.needed(over: blurred ?? source, opacity: $0.opacity, minimum: $0.minimum) }
                return (blurred, shade)
            }.value
            captionShade = shade
            withAnimation(.easeOut(duration: 0.4)) { image = blurred ?? source }
        }
    }

    nonisolated private static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            .cropped(to: input.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent)
    }
}

/// How much black a caption strip needs over blurred art for its secondary line (white at some opacity) to read 4.5:1:
/// the strip composites in sRGB, so over a pixel `c` the shade `s` leaves `(1 - s) × c` and the text `o + (1 - o) ×
/// that`. Judged on the palest pixel of the image's middle band, with a little margin (4.6:1).
enum CaptionShade {
    nonisolated static let target = 4.6

    /// The least shade from `minimum` (in steps of 0.01, at most 0.9) that keeps white at `opacity` at `target` over
    /// the sRGB color `rgb` (0–1 each).
    nonisolated static func needed(over rgb: (Double, Double, Double), opacity: Double, minimum: Double) -> Double {
        var shade = minimum
        while shade < 0.9, contrast(over: rgb, shade: shade, opacity: opacity) < target { shade += 0.01 }
        return min(shade, 0.9)
    }

    /// White at `opacity` over `rgb` under `shade` black, against that background.
    nonisolated static func contrast(over rgb: (Double, Double, Double), shade: Double, opacity: Double) -> Double {
        let bg = (rgb.0 * (1 - shade), rgb.1 * (1 - shade), rgb.2 * (1 - shade))
        let ink = (opacity + (1 - opacity) * bg.0, opacity + (1 - opacity) * bg.1, opacity + (1 - opacity) * bg.2)
        return (luminance(ink) + 0.05) / (luminance(bg) + 0.05)
    }

    nonisolated static func luminance(_ c: (Double, Double, Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    /// The shade for the palest pixel in the middle 40% of `image`'s rows.
    nonisolated static func needed(over image: CGImage, opacity: Double, minimum: Double) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return minimum }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return minimum }
        var palest = (0.0, 0.0, 0.0), best = -1.0
        for row in Int(Double(h) * 0.3)..<max(Int(Double(h) * 0.3) + 1, Int(Double(h) * 0.7)) {
            for column in 0..<w {
                let i = (row * w + column) * 4
                let c = (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
                let l = luminance(c)
                if l > best { best = l; palest = c }
            }
        }
        return needed(over: palest, opacity: opacity, minimum: minimum)
    }
}

/// Library › Liked Songs' artwork where it stands in for a service's own liked-songs playlist (a Listen Again card):
/// the sidebar row's heart, white on an accent tile, so the card and the row read as the same list.
struct LikedSongsArtwork: View {
    var size: CGFloat
    var cornerRadius: CGFloat = Metrics.artworkRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color.accentColor.mix(with: .white, by: 0.12), Color.accentColor.mix(with: .black, by: 0.28)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: SidebarItem.likedSongs.symbol + ".fill")
                    .font(.system(size: max(10, size * 0.32), weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay { ArtworkOutline(cornerRadius: cornerRadius) }
            .accessibilityHidden(true)
    }
}

/// Every artwork's inner edge, in both appearances, as Music draws it: one device pixel (0.5 pt on a Retina screen)
/// inside the tile's own rounded rectangle or circle, black at 12% in light mode and white at 16% in dark mode,
/// where 12% left a near-black cover (HIT ME HARD AND SOFT) with no edge on the dark sidebar and page (round 28).
/// A plain `strokeBorder` of a fixed color: no clip, no blend, nothing that changes per frame.
struct ArtworkOutline: View {
    var circle = false
    var cornerRadius: CGFloat = Metrics.artworkRadius
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    static func color(dark: Bool) -> Color { dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12) }

    var body: some View {
        let color = Self.color(dark: scheme == .dark)
        let width = 1 / max(displayScale, 1)
        Group {
            if circle {
                Circle().strokeBorder(color, lineWidth: width)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(color, lineWidth: width)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Artwork tint

/// An artwork's average hue and saturation, Sendable so it can cross from the decode task.
nonisolated struct TintColor: Sendable, Equatable {
    let hue: Double, saturation: Double
    /// The average's HSB brightness (its brightest channel), for surfaces that must dim a pale cover more.
    var brightness: Double = 0.5

    /// A pastel in light mode and a deep tone in dark mode: a soft gray-brown average would otherwise
    /// read as a dirty gray band instead of a tint.
    func color(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hue: hue, saturation: min(saturation * 0.8, 0.5), brightness: 0.42)
            : Color(hue: hue, saturation: min(saturation * 0.7, 0.32), brightness: 0.93)
    }

    /// The hero fill: desaturated and darker than `color(for:)` in dark mode so white titles keep their
    /// contrast on any artwork; a soft pastel in light mode under dark titles.
    func heroColor(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(hue: hue, saturation: min(saturation * 0.75, 0.45), brightness: 0.34)
            : Color(hue: hue, saturation: min(saturation * 0.6, 0.28), brightness: 0.9)
    }
}

/// The average color of a piece of artwork, softened for use behind text: saturation is reduced
/// and lightness pulled toward the middle, so the wash reads as a tint, not a block of color.
/// Computed once per URL with Core Image off the main thread, then cached.
nonisolated final class ArtworkTintCache: Sendable {
    static let shared = ArtworkTintCache()

    private nonisolated(unsafe) let memory: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 400
        return cache
    }()

    private final class Entry: @unchecked Sendable {
        let tint: TintColor
        init(_ tint: TintColor) { self.tint = tint }
    }

    func cached(_ url: URL) -> TintColor? { memory.object(forKey: url.absoluteString as NSString)?.tint }

    func tint(for url: URL) async -> TintColor? {
        if let hit = cached(url) { return hit }
        // 64 px is plenty for an average and is usually already decoded for a row or the toolbar.
        guard let image = await ArtworkPipeline.shared.image(url, pixels: 64)?.cgImage else { return nil }
        let tint = await Task.detached(priority: .utility) { Self.average(image) }.value
        if let tint { memory.setObject(Entry(tint), forKey: url.absoluteString as NSString) }
        return tint
    }

    private static func average(_ image: CGImage) -> TintColor? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let ns = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Black, white or gray artwork has no meaningful hue: give it a neutral wash, never a stray red.
        if s < 0.08 || b < 0.1 { return TintColor(hue: 0, saturation: 0, brightness: Double(b)) }
        return TintColor(hue: Double(h), saturation: Double(s), brightness: Double(b))
    }
}

/// A soft wash of the artwork's color that fades into the window background, behind a page header.
struct ArtworkWash: View {
    let artwork: Artwork?
    var height: CGFloat = 520

    @Environment(\.colorScheme) private var scheme
    @State private var tint: TintColor?

    private var url: URL? { artwork?.url(minPixels: 64) }

    var body: some View {
        let shown = tint ?? url.flatMap { ArtworkTintCache.shared.cached($0) }
        let base = shown?.color(for: scheme) ?? .clear
        LinearGradient(
            stops: [
                .init(color: base.opacity(scheme == .dark ? 0.75 : 0.9), location: 0),
                .init(color: base.opacity(scheme == .dark ? 0.35 : 0.45), location: 0.5),
                .init(color: base.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { tint = nil; return }
            if let hit = ArtworkTintCache.shared.cached(url) { tint = hit; return }
            let value = await ArtworkTintCache.shared.tint(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { tint = value }
        }
    }
}

/// The album and playlist hero background: the artwork's color fills the hero (reaching up behind the
/// toolbar's glass) and then fades into the page background over `Metrics.heroFade`.
struct HeroWash: View {
    let artwork: Artwork?
    /// Height of the solid part, measured from the top of the page content.
    var heroHeight: CGFloat
    /// How far the color reaches above the content, under the toolbar.
    var topExtension: CGFloat = 160

    @Environment(\.colorScheme) private var scheme
    @State private var tint: TintColor?

    private var url: URL? { artwork?.url(minPixels: 64) }

    var body: some View {
        let shown = tint ?? url.flatMap { ArtworkTintCache.shared.cached($0) }
        let base = shown?.heroColor(for: scheme) ?? Color.primary.opacity(scheme == .dark ? 0.06 : 0.04)
        VStack(spacing: 0) {
            base
                .frame(height: heroHeight + topExtension)
            // Starts at the hero's own color so there is no seam, then eases out into the page.
            LinearGradient(
                stops: [
                    .init(color: base, location: 0),
                    .init(color: base.opacity(0.5), location: 0.4),
                    .init(color: base.opacity(0.15), location: 0.75),
                    .init(color: base.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Metrics.heroFade)
        }
        .padding(.top, -topExtension)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { tint = nil; return }
            if let hit = ArtworkTintCache.shared.cached(url) { tint = hit; return }
            let value = await ArtworkTintCache.shared.tint(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { tint = value }
        }
    }
}

/// The album hero's artwork color (`TintColor.heroColor`) as a plain fill, for surfaces that take the hero's
/// tint without its fade (Home's featured card). A neutral fill shows until the tint is known.
struct ArtworkTintFill: View {
    let artwork: Artwork?

    @Environment(\.colorScheme) private var scheme
    @State private var tint: TintColor?

    private var url: URL? { artwork?.url(minPixels: 64) }

    var body: some View {
        let shown = tint ?? url.flatMap { ArtworkTintCache.shared.cached($0) }
        Rectangle()
            .fill(shown?.heroColor(for: scheme) ?? Color.primary.opacity(scheme == .dark ? 0.06 : 0.04))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { tint = nil; return }
                if let hit = ArtworkTintCache.shared.cached(url) { tint = hit; return }
                let value = await ArtworkTintCache.shared.tint(for: url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.35)) { tint = value }
            }
    }
}

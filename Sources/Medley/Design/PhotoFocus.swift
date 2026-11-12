import CoreGraphics
import Foundation
import Vision

/// Where the subject of a photo sits, found once per artwork URL: faces first (Vision's face rectangles), then the
/// most attention-grabbing region (attention-based saliency), else nothing. The artist hero uses it to choose a
/// crop per photo instead of one fixed crop for every artist (`HeroPhotoLayout`).
nonisolated struct PhotoFocus: Sendable, Equatable {
    enum Source: String, Sendable { case face, saliency, none }

    /// The analyzed image's width over its height.
    let aspect: CGFloat
    /// What to keep in view, in unit coordinates with the origin at the image's top-left. For faces this is every
    /// face about as large as the biggest one, each grown to the whole head. Nil when nothing was found.
    let subject: CGRect?
    /// The biggest face alone (its head), tried when a group doesn't fit the banner.
    let primary: CGRect?
    let source: Source
    /// The average colors of the photo's leftmost and rightmost strips (sRGB, 0–1).
    var edges: Edges? = nil
    /// Relative luminance (0–1) of a `toneGrid` × `toneGrid` grid of cells over the photo, row by row from the top-left.
    /// The hero reads the cells under its name to choose a scrim that keeps white text at 4.5:1.
    var tones: [Float] = []
    /// The photo's average color.
    var mean: RGB? = nil
    /// The source image's width in pixels when known, so the hero never blows a small photo up past `maxUpscale`.
    var sourceWidth: Int? = nil

    static let toneGrid = 24

    struct Edges: Sendable, Equatable {
        let leading: RGB
        let trailing: RGB
    }

    struct RGB: Sendable, Equatable {
        let red: Double, green: Double, blue: Double
        func scaled(_ factor: Double) -> RGB { RGB(red: red * factor, green: green * factor, blue: blue * factor) }
    }

    /// The crop the hero used for every photo before faces were found (a fifth of the way down): still the
    /// fallback when neither faces nor a salient region show up.
    static let defaultFocusY: CGFloat = 0.2

    /// Vision's face box runs from about the eyebrows to the chin. Grown by this much of its height above (forehead
    /// and hair) and below (chin and a little neck), it covers the head, so a crop that keeps it never cuts the face.
    static let headAbove: CGFloat = 0.45
    static let headBelow: CGFloat = 0.15

    static func head(fromFace face: CGRect) -> CGRect {
        let top = max(0, face.minY - face.height * headAbove)
        let bottom = min(1, face.maxY + face.height * headBelow)
        return CGRect(x: face.minX, y: top, width: face.width, height: bottom - top)
    }
}

/// Where the artist hero draws its photo: aspect-fill across the banner, scaled and shifted so the subject sits in the
/// right part of the frame. `origin` is the photo's top-left corner in banner points; a positive `x` leaves a strip at
/// the leading edge that the photo's own left edge, stretched and blurred, fills.
nonisolated struct HeroPhotoPlacement: Equatable, Sendable {
    var size: CGSize
    var origin: CGPoint

    /// The banner point `point` in the photo's unit coordinates (top-left origin; may fall outside 0–1).
    func photoPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / max(size.width, 1), y: (point.y - origin.y) / max(size.height, 1))
    }

    /// The part of the photo inside a banner of `banner` size, in unit coordinates.
    func visibleRect(banner: CGSize) -> CGRect {
        let a = photoPoint(.zero), b = photoPoint(CGPoint(x: banner.width, y: banner.height))
        let minX = max(0, a.x), maxX = min(1, b.x), minY = max(0, a.y), maxY = min(1, b.y)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Device pixels drawn per source pixel at `scale`, or nil when the source size is unknown.
    func upscale(sourceWidth: Int?, displayScale scale: CGFloat) -> CGFloat? {
        sourceWidth.map { size.width * scale / CGFloat(max($0, 1)) }
    }
}

nonisolated extension PhotoFocus {
    /// Where the subject's center goes across the banner, as a fraction of its width: the right part of the frame,
    /// clear of the name along the bottom left.
    static let subjectTarget: ClosedRange<CGFloat> = 0.62...0.72
    /// At most this many device pixels per source pixel. A 1000 px photo across a 1207 pt banner at 2x is already
    /// 2.4; past about 2.5 a photo goes visibly soft, so it stops growing and leaves a filled strip on the left instead.
    static let maxUpscale: CGFloat = 2.5
    /// The banner's bottom 45% fades out; a face is kept above this fraction of the banner's height when it can be.
    static let clearHeight: CGFloat = 0.72

    /// The face Vision found, from a head box `head(fromFace:)` made (the inverse of its growth, unless it was clipped).
    static func face(fromHead head: CGRect) -> CGRect {
        let f = head.height / (1 + headAbove + headBelow)
        return CGRect(x: head.minX, y: min(head.maxY - f, head.minY + f * headAbove), width: head.width, height: f)
    }

    /// What to keep in view: the group of faces if its head boxes fit the banner, else the biggest face; the salient
    /// region; or nothing.
    private func keep(visibleHeight: CGFloat) -> CGRect? {
        guard let subject else { return nil }
        if source == .face, subject.height > visibleHeight, let primary { return primary }
        return subject
    }

    func placement(banner: CGSize, displayScale: CGFloat = 2) -> HeroPhotoPlacement {
        let w = max(banner.width, 1), h = max(banner.height, 1), a = max(aspect, 0.01)
        // The subject at the banner's own width decides which part to keep; its center x is where it sits in the photo.
        let keep = keep(visibleHeight: h * a / w) ?? subject
        let fx = keep.map { min(max($0.midX, 0.02), 0.98) } ?? 0.5
        let target = min(max(fx, Self.subjectTarget.lowerBound), Self.subjectTarget.upperBound)
        // As wide as it takes to put the subject at `target` with the photo's leading edge at the banner's...
        var width = target * w / fx
        // ...but not so wide that the head no longer fits above the fade...
        if source == .face, let keep { width = min(width, h * a * Self.clearHeight / max(keep.height, 0.01)) }
        // ...or the photo blurs.
        if let sourceWidth { width = min(width, CGFloat(sourceWidth) * Self.maxUpscale / max(displayScale, 1)) }
        // Never narrower than the banner's height needs, or than keeps the trailing edge covered.
        width = max(width, h * a, w * (1 - target) / (1 - fx))
        let height = width / a
        let x = max(target * w - fx * width, w - width)
        // Vertically: the head a little below the banner's top, kept above the fade, the face always in view.
        let visible = min(1, h / height)
        var top: CGFloat
        switch source {
        case .face:
            guard let keep else { top = Self.defaultFocusY * (1 - visible); break }
            let face = Self.face(fromHead: keep)
            top = keep.minY - visible * 0.06
            top = max(top, face.maxY - visible * Self.clearHeight)
            top = min(top, face.minY - visible * 0.02)
        case .saliency:
            top = (keep?.midY ?? 0.5) - visible / 2
        case .none:
            top = Self.defaultFocusY * (1 - visible)
        }
        top = min(max(top, 0), 1 - visible)
        return HeroPhotoPlacement(size: CGSize(width: width, height: height), origin: CGPoint(x: x, y: -top * height))
    }

    /// The brightest relative luminance under `rect` (banner points) for a photo drawn at `placement`. Points left of
    /// the photo read its leftmost column, which the stretched edge continues. Nil without a tone grid.
    func brightestTone(in rect: CGRect, placement: HeroPhotoPlacement) -> Double? {
        toneRange(in: rect, placement: placement)?.upperBound
    }

    /// The darkest relative luminance under `rect`, as `brightestTone`: whether dark text reads there.
    func darkestTone(in rect: CGRect, placement: HeroPhotoPlacement) -> Double? {
        toneRange(in: rect, placement: placement)?.lowerBound
    }

    private func toneRange(in rect: CGRect, placement: HeroPhotoPlacement) -> ClosedRange<Double>? {
        let n = Self.toneGrid
        guard tones.count == n * n, rect.width > 0, rect.height > 0 else { return nil }
        let a = placement.photoPoint(CGPoint(x: rect.minX, y: rect.minY))
        let b = placement.photoPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        func cell(_ v: CGFloat) -> Int { min(n - 1, max(0, Int((v * CGFloat(n)).rounded(.down)))) }
        var brightest: Float = 0, darkest: Float = 1
        for row in cell(a.y)...cell(b.y) {
            for column in cell(a.x)...cell(b.x) {
                brightest = max(brightest, tones[row * n + column])
                darkest = min(darkest, tones[row * n + column])
            }
        }
        return Double(min(darkest, brightest))...Double(brightest)
    }

    /// The black overlay needed over a surface of relative luminance `luminance` for white text to read at 4.5:1:
    /// composited in sRGB, the gray `g` it equals becomes `g × (1 − alpha)`, which has to stay at or under 0.465
    /// (luminance 0.183: (1 + 0.05) / (0.183 + 0.05) = 4.5). It aims at 0.40 (about 5.6:1): the tone grid averages
    /// each cell, so a bright strand of hair beside a letter reads brighter than its cell (council round 14 measured
    /// 4.0:1 there when it aimed at 0.46).
    ///
    /// `photoOpacity` below 1: the photo is fading into a page of sRGB gray `page` (light mode's artist header, where the
    /// photo dissolves into the white window background); the surface is then the photo's gray blended toward the page's.
    static func scrimForWhiteText(over luminance: Double, extraDarkening: Double = 0, photoOpacity: Double = 1, page: Double = 1) -> Double {
        let gray = luminance <= 0.0031308 ? luminance * 12.92 : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        let opacity = min(1, max(0, photoOpacity))
        let shown = (gray * opacity + page * (1 - opacity)) * (1 - extraDarkening)
        guard shown > 0.40 else { return 0 }
        return 1 - 0.40 / shown
    }

    /// Relative luminance of an sRGB color.
    static func luminance(_ rgb: RGB) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(rgb.red) + 0.7152 * lin(rgb.green) + 0.0722 * lin(rgb.blue)
    }

    /// Finds faces, then salient regions, in `image`. Synchronous and slow-ish (tens of milliseconds): call it off the main thread.
    static func analyze(_ image: CGImage) -> PhotoFocus {
        var focus = findSubject(image)
        focus.edges = edgeColors(image)
        (focus.tones, focus.mean) = toneGrid(image)
        return focus
    }

    /// The photo drawn into a `toneGrid`-square bitmap: each pixel's relative luminance, and the average color.
    static func toneGrid(_ image: CGImage) -> ([Float], RGB?) {
        let n = toneGrid
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ([], nil) }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var tones = [Float](repeating: 0, count: n * n)
        var sum = (0.0, 0.0, 0.0)
        // A bitmap context's first row is the image's top row.
        for i in 0..<(n * n) {
            let rgb = RGB(red: Double(pixels[i * 4]) / 255, green: Double(pixels[i * 4 + 1]) / 255, blue: Double(pixels[i * 4 + 2]) / 255)
            tones[i] = Float(luminance(rgb))
            sum.0 += rgb.red; sum.1 += rgb.green; sum.2 += rgb.blue
        }
        let count = Double(n * n)
        return (tones, RGB(red: sum.0 / count, green: sum.1 / count, blue: sum.2 / count))
    }

    /// The average color of the outer 4% of the photo on each side.
    static func edgeColors(_ image: CGImage) -> Edges? {
        let strip = max(1, image.width / 25)
        func average(_ rect: CGRect) -> RGB? {
            guard let cropped = image.cropping(to: rect) else { return nil }
            let w = min(strip, 8), h = 64
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = (0.0, 0.0, 0.0)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                sum.0 += Double(pixels[i]); sum.1 += Double(pixels[i + 1]); sum.2 += Double(pixels[i + 2])
            }
            let n = Double(w * h) * 255
            return RGB(red: sum.0 / n, green: sum.1 / n, blue: sum.2 / n)
        }
        guard let leading = average(CGRect(x: 0, y: 0, width: strip, height: image.height)),
              let trailing = average(CGRect(x: image.width - strip, y: 0, width: strip, height: image.height)) else { return nil }
        return Edges(leading: leading, trailing: trailing)
    }

    private static func findSubject(_ image: CGImage) -> PhotoFocus {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([faces])
        // Vision's boxes are normalized with the origin at the bottom-left; flip them to top-left. Faces smaller than
        // a few percent of the picture are people in the background.
        let boxes = (faces.results ?? []).map { flipped($0.boundingBox) }.filter { $0.width * $0.height >= 0.002 }
        if let largest = boxes.max(by: { area($0) < area($1) }) {
            let group = boxes.filter { area($0) >= area(largest) * 0.25 }.map(head(fromFace:))
            let union = group.dropFirst().reduce(group[0]) { $0.union($1) }
            return PhotoFocus(aspect: aspect, subject: union, primary: head(fromFace: largest), source: .face)
        }

        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([saliency])
        if let objects = saliency.results?.first?.salientObjects, let first = objects.first {
            let union = objects.dropFirst().reduce(first.boundingBox) { $0.union($1.boundingBox) }
            return PhotoFocus(aspect: aspect, subject: flipped(union), primary: nil, source: .saliency)
        }
        return PhotoFocus(aspect: aspect, subject: nil, primary: nil, source: .none)
    }

    private static func flipped(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}

/// `PhotoFocus` per artwork URL, computed once off the main thread from a 512 px decode and kept in memory.
nonisolated final class PhotoFocusCache: Sendable {
    static let shared = PhotoFocusCache()

    /// The decode size analyzed: plenty for a face that matters in a banner, and cheap for Vision.
    static let pixels = 512

    private nonisolated(unsafe) let memory: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()
    private let inflight = Inflight()

    private final class Entry: @unchecked Sendable {
        let focus: PhotoFocus
        init(_ focus: PhotoFocus) { self.focus = focus }
    }

    /// Synchronous lookup, cheap enough to call from `body`.
    func cached(_ url: URL) -> PhotoFocus? { memory.object(forKey: url.absoluteString as NSString)?.focus }

    /// The focus for the artwork at `url`, or nil when the image couldn't be loaded (the caller uses the default crop).
    func focus(for url: URL) async -> PhotoFocus? {
        if let hit = cached(url) { return hit }
        let focus = await inflight.run(url.absoluteString) {
            guard let image = await ArtworkPipeline.shared.load(url, pixels: Self.pixels)?.cgImage else { return nil }
            var focus = await Task.detached(priority: .userInitiated) { PhotoFocus.analyze(image) }.value
            focus.sourceWidth = ArtworkPipeline.sourceWidth(of: url)
            return focus
        }
        if let focus { memory.setObject(Entry(focus), forKey: url.absoluteString as NSString) }
        return focus
    }

    /// One analysis per URL at a time; the hero's placeholder and its loaded page ask for the same photo.
    private actor Inflight {
        private var tasks: [String: Task<PhotoFocus?, Never>] = [:]

        func run(_ key: String, _ work: @escaping @Sendable () async -> PhotoFocus?) async -> PhotoFocus? {
            if let task = tasks[key] { return await task.value }
            let task = Task(priority: .userInitiated) { await work() }
            tasks[key] = task
            let value = await task.value
            tasks[key] = nil
            return value
        }
    }
}

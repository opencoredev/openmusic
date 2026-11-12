import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Procedural cover art for the mock provider, so the UI and snapshots work offline.
///
/// Mock artwork URLs look like `medley-mock://art/<seed>` or `medley-mock://portrait/<seed>`.
/// The same seed always draws the same image.
public enum MockArtwork {
    public static let scheme = "medley-mock"

    /// Where the demo dataset's downloaded cover art lives (`<key>.jpg`, from scripts/demo-art.sh). Set once at
    /// launch, before anything draws. Without it (or without a file) demo art falls back to procedural covers.
    nonisolated(unsafe) public static var demoDirectory: URL?

    public static func url(_ kind: String, _ seed: String) -> URL? {
        URL(string: "\(scheme)://\(kind)/\(seed)")
    }

    public static func artwork(_ kind: String, _ seed: String) -> Artwork? {
        guard let url = url(kind, seed) else { return nil }
        return Artwork(images: [ArtworkImage(url: url, width: 1200, height: 1200)])
    }

    /// Draws the image for a mock URL at `pixels` × `pixels`. Safe to call off the main thread.
    public static func render(_ url: URL, pixels: Int) -> CGImage? {
        guard url.scheme == scheme else { return nil }
        let kind = url.host ?? "art"
        let seed = url.lastPathComponent
        let size = max(16, min(pixels, 2048))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        var rng = SeededRandom(seed: fnv1a(seed))
        let s = CGFloat(size)
        switch kind {
        case "portrait": drawPortrait(ctx, s, &rng, space)
        case "demo":
            // A downloaded cover, decoded at the size asked for.
            if let image = demoImage(seed, pixels: size) { return image }
            drawCover(ctx, s, &rng, space)
        case "mosaic":
            // Four covers in a 2×2 grid, like a generated mix's artwork.
            let keys = seed.split(separator: "+").map(String.init)
            let half = s / 2
            for (i, key) in keys.prefix(4).enumerated() {
                let rect = CGRect(x: CGFloat(i % 2) * half, y: CGFloat(1 - i / 2) * half, width: half, height: half)
                if let image = demoImage(key, pixels: size / 2) {
                    ctx.draw(image, in: rect)
                } else {
                    var r = SeededRandom(seed: fnv1a(key))
                    ctx.saveGState(); ctx.clip(to: rect); ctx.translateBy(x: rect.minX, y: rect.minY)
                    drawCover(ctx, half, &r, space)
                    ctx.restoreGState()
                }
            }
        case "liked": drawLiked(ctx, s, space)
        case "avatar": drawAvatar(ctx, s, initials: seed, space)
        default: drawCover(ctx, s, &rng, space)
        }
        return ctx.makeImage()
    }

    private static func demoImage(_ key: String, pixels: Int) -> CGImage? {
        guard let dir = demoDirectory,
              let source = CGImageSourceCreateWithURL(dir.appendingPathComponent("\(key).jpg") as CFURL, nil)
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// "Liked" playlist art: a deep violet-to-blue gradient with a white heart.
    private static func drawLiked(_ ctx: CGContext, _ s: CGFloat, _ space: CGColorSpace) {
        linear(ctx, [CGColor(srgbRed: 0.27, green: 0.13, blue: 0.85, alpha: 1), CGColor(srgbRed: 0.55, green: 0.78, blue: 0.95, alpha: 1)],
               CGPoint(x: 0, y: s), CGPoint(x: s, y: 0), space)
        let w = s * 0.36, cx = s / 2, cy = s * 0.52
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: cy - w * 0.55))
        path.addCurve(to: CGPoint(x: cx - w * 0.5, y: cy + w * 0.12), control1: CGPoint(x: cx - w * 0.18, y: cy - w * 0.32), control2: CGPoint(x: cx - w * 0.5, y: cy - w * 0.12))
        path.addArc(center: CGPoint(x: cx - w * 0.25, y: cy + w * 0.14), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(center: CGPoint(x: cx + w * 0.25, y: cy + w * 0.14), radius: w * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addCurve(to: CGPoint(x: cx, y: cy - w * 0.55), control1: CGPoint(x: cx + w * 0.5, y: cy - w * 0.12), control2: CGPoint(x: cx + w * 0.18, y: cy - w * 0.32))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
    }

    /// An account picture without a photo: initials on a warm gradient, like a Google account's monogram.
    private static func drawAvatar(_ ctx: CGContext, _ s: CGFloat, initials: String, _ space: CGColorSpace) {
        linear(ctx, [CGColor(srgbRed: 0.98, green: 0.55, blue: 0.33, alpha: 1), CGColor(srgbRed: 0.86, green: 0.25, blue: 0.52, alpha: 1)],
               CGPoint(x: 0, y: s), CGPoint(x: s, y: 0), space)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, s * 0.4, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, s * 0.4, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        guard let text = CFAttributedStringCreate(nil, initials.prefix(2).uppercased() as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: (s - bounds.width) / 2 - bounds.minX, y: (s - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
    }

    // MARK: Drawing

    private static func drawCover(_ ctx: CGContext, _ s: CGFloat, _ rng: inout SeededRandom, _ space: CGColorSpace) {
        let hue = rng.unit()
        let shift = 0.06 + rng.unit() * 0.22
        let a = hsb(hue, 0.55 + rng.unit() * 0.3, 0.55 + rng.unit() * 0.35)
        let b = hsb(hue + shift, 0.5 + rng.unit() * 0.35, 0.25 + rng.unit() * 0.35)
        let c = hsb(hue - shift * 1.4, 0.35 + rng.unit() * 0.4, 0.85 + rng.unit() * 0.15)
        linear(ctx, [a, b], CGPoint(x: 0, y: s), CGPoint(x: s, y: 0), space)

        switch Int(rng.unit() * 4) {
        case 0: // A low sun with a horizon band.
            let r = s * (0.22 + rng.unit() * 0.16)
            let center = CGPoint(x: s * (0.3 + rng.unit() * 0.4), y: s * (0.4 + rng.unit() * 0.25))
            ctx.setFillColor(c.copy(alpha: 0.92) ?? c)
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            ctx.setFillColor(b.copy(alpha: 0.85) ?? b)
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: center.y - r * 0.15))
            for i in 0..<5 {
                let y = center.y - r * 0.15 - CGFloat(i + 1) * s * 0.045
                ctx.setFillColor(c.copy(alpha: 0.18 - CGFloat(i) * 0.03) ?? c)
                ctx.fill(CGRect(x: 0, y: y, width: s, height: s * 0.012))
            }
        case 1: // Concentric rings.
            let center = CGPoint(x: s * rng.unit(), y: s * rng.unit())
            for i in stride(from: 9, through: 1, by: -1) {
                let r = s * 0.13 * CGFloat(i)
                ctx.setFillColor((i % 2 == 0 ? c : a).copy(alpha: 0.16 + 0.05 * CGFloat(9 - i)) ?? c)
                ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
        case 2: // Diagonal bands.
            ctx.saveGState()
            ctx.translateBy(x: s / 2, y: s / 2)
            ctx.rotate(by: .pi / 4 * (rng.unit() > 0.5 ? 1 : -1))
            let band = s * (0.08 + rng.unit() * 0.08)
            var x = -s
            var i = 0
            while x < s {
                ctx.setFillColor((i % 3 == 0 ? c : a).copy(alpha: i % 3 == 0 ? 0.75 : 0.22) ?? c)
                ctx.fill(CGRect(x: x, y: -s, width: band * (i % 3 == 0 ? 0.6 : 1), height: s * 2))
                x += band * 1.6
                i += 1
            }
            ctx.restoreGState()
        default: // Soft blobs.
            for _ in 0..<4 {
                let r = s * (0.18 + rng.unit() * 0.3)
                let p = CGPoint(x: s * rng.unit(), y: s * rng.unit())
                radial(ctx, [c.copy(alpha: 0.8) ?? c, c.copy(alpha: 0) ?? c], p, r, space)
            }
        }
        // Subtle vignette for depth.
        radial(ctx, [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.28)], CGPoint(x: s / 2, y: s / 2), s * 0.75, space)
    }

    private static func drawPortrait(_ ctx: CGContext, _ s: CGFloat, _ rng: inout SeededRandom, _ space: CGColorSpace) {
        let hue = rng.unit()
        let bg1 = hsb(hue, 0.35 + rng.unit() * 0.3, 0.7 + rng.unit() * 0.25)
        let bg2 = hsb(hue + 0.1, 0.5, 0.3 + rng.unit() * 0.2)
        radial(ctx, [bg1, bg2], CGPoint(x: s * 0.5, y: s * 0.62), s * 0.8, space)
        let figure = hsb(hue + 0.5, 0.25, 0.12 + rng.unit() * 0.12)
        ctx.setFillColor(figure.copy(alpha: 0.88) ?? figure)
        let headR = s * (0.15 + rng.unit() * 0.04)
        let headCenter = CGPoint(x: s * (0.47 + rng.unit() * 0.06), y: s * 0.56)
        ctx.fillEllipse(in: CGRect(x: headCenter.x - headR, y: headCenter.y - headR * 1.1, width: headR * 2, height: headR * 2.2))
        let shoulders = CGRect(x: headCenter.x - s * 0.36, y: -s * 0.25, width: s * 0.72, height: s * 0.62)
        ctx.fillEllipse(in: shoulders)
        // Rim light.
        radial(ctx, [bg1.copy(alpha: 0.35) ?? bg1, bg1.copy(alpha: 0) ?? bg1], CGPoint(x: s * 0.8, y: s * 0.8), s * 0.5, space)
    }

    private static func linear(_ ctx: CGContext, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, _ space: CGColorSpace) {
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func radial(_ ctx: CGContext, _ colors: [CGColor], _ center: CGPoint, _ radius: CGFloat, _ space: CGColorSpace) {
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    }

    private static func hsb(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
        let h = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let i = Int(h), f = h - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch i % 6 {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in s.utf8 {
        h ^= UInt64(byte)
        h = h &* 0x100_0000_01b3
    }
    return h
}

/// Small deterministic generator (SplitMix64) so mock data and art never change between runs.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}

// Hero images for posting: the Mac window and the iPhone's Now Playing on a backdrop. Run by scripts/demo-shots.sh
// (compose step); Apple frameworks only.
//
//   swiftc -O scripts/demo-compose.swift -o build/demo-compose
//   build/demo-compose <raw dir> <out dir> [<demo art dir>]
//
// Reads raw/mac-home-<mode>.png (window with shadow) and raw/ios-nowplaying-<mode>.png (simulator screenshot),
// writes out/hero-x-<mode>.png (3200x1800, 16:9 at 2x of 1600x900), out/hero-square-<mode>.png (2160x2160) and
// out/social-<mode>.png (1280x640, GitHub's social preview size). With a demo art dir (the chart-album data) the
// backdrop is the playing song's cover, blurred; without one (the sample data) it is drawn here, so the images hold
// no real artwork.
import AppKit
import CoreImage
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: demo-compose <raw dir> <out dir> [<art dir>]\n".data(using: .utf8)!)
    exit(2)
}
let raw = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2], isDirectory: true)
let art = args.count >= 4 ? URL(fileURLWithPath: args[3], isDirectory: true) : nil
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: space])

func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func save(_ image: CGImage, _ url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("\(url.lastPathComponent): \(image.width)x\(image.height)")
}

/// The cover, scaled to fill `size`, heavily blurred, then dimmed or brightened for the mode.
func backdrop(_ cover: CGImage, _ size: CGSize, dark: Bool) -> CGImage? {
    var image = CIImage(cgImage: cover)
    let scale = max(size.width, size.height) / CGFloat(cover.width) * 1.6
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    image = image.clampedToExtent().applyingGaussianBlur(sigma: max(size.width, size.height) * 0.09)
    image = image.applyingFilter("CIColorControls", parameters: [
        kCIInputSaturationKey: 1.1,
        kCIInputBrightnessKey: dark ? -0.36 : 0.08,
        kCIInputContrastKey: dark ? 1.05 : 0.92,
    ])
    // Centre crop of the scaled cover (the blurred image itself is infinite after clamping).
    let crop = CGRect(x: (CGFloat(cover.width) * scale - size.width) / 2, y: (CGFloat(cover.height) * scale - size.height) / 2,
                      width: size.width, height: size.height)
    return ci.createCGImage(image.cropped(to: crop), from: crop)
}

/// A backdrop drawn from scratch: a soft diagonal wash with large blurred colour fields, cool in dark mode and warm
/// in light mode. No artwork goes into it.
func proceduralBackdrop(_ size: CGSize, dark: Bool) -> CGImage? {
    let w = Int(size.width), h = Int(size.height)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    let base = dark ? [c(0.07, 0.06, 0.16), c(0.16, 0.07, 0.22), c(0.04, 0.10, 0.18)]
                    : [c(0.99, 0.93, 0.88), c(0.96, 0.88, 0.95), c(0.88, 0.92, 0.99)]
    if let g = CGGradient(colorsSpace: space, colors: base as CFArray, locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
    }
    // Colour fields: (centre as a fraction of the canvas, radius as a fraction of its longer side, colour).
    let fields: [(CGFloat, CGFloat, CGFloat, CGColor)] = dark
        ? [(0.18, 0.78, 0.55, c(0.95, 0.25, 0.45, 0.55)), (0.82, 0.30, 0.50, c(0.20, 0.45, 1.00, 0.50)),
           (0.55, 0.05, 0.40, c(0.55, 0.20, 0.95, 0.45)), (0.95, 0.95, 0.35, c(1.00, 0.55, 0.25, 0.30))]
        : [(0.15, 0.80, 0.55, c(1.00, 0.55, 0.45, 0.50)), (0.85, 0.25, 0.50, c(0.45, 0.60, 1.00, 0.45)),
           (0.55, 0.05, 0.40, c(0.85, 0.50, 1.00, 0.40)), (0.95, 0.95, 0.35, c(1.00, 0.80, 0.40, 0.40))]
    let long = max(size.width, size.height)
    for (x, y, r, color) in fields {
        let centre = CGPoint(x: size.width * x, y: size.height * y)
        let clear = color.copy(alpha: 0) ?? color
        if let g = CGGradient(colorsSpace: space, colors: [color, clear] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: long * r, options: [])
        }
    }
    guard let drawn = ctx.makeImage() else { return nil }
    // A light blur and fine noise keep the gradients from banding.
    var image = CIImage(cgImage: drawn).clampedToExtent().applyingGaussianBlur(sigma: long * 0.01)
    if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
        let grain = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.035),
            "inputBiasVector": CIVector(x: dark ? 1 : 0, y: dark ? 1 : 0, z: dark ? 1 : 0, w: 0),
        ])
        image = grain.composited(over: image)
    }
    let rect = CGRect(origin: .zero, size: size)
    return ci.createCGImage(image.cropped(to: rect), from: rect)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// An iPhone 17 Pro Max outline around a screenshot: titanium band, black border, Dynamic Island.
func drawPhone(_ ctx: CGContext, screen: CGImage, in rect: CGRect, dark: Bool) {
    let k = rect.width / CGFloat(screen.width)        // screen pixels -> canvas
    let border = 30 * k, band = 9 * k
    let screenRadius = 190 * k
    let body = rect.insetBy(dx: -(border + band), dy: -(border + band))
    let bodyRadius = screenRadius + border + band

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -40 * k), blur: 140 * k, color: CGColor(gray: 0, alpha: dark ? 0.6 : 0.35))
    ctx.addPath(roundedRect(body, bodyRadius))
    ctx.setFillColor(CGColor(gray: 0.18, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Titanium band: a soft vertical gradient, then the black glass border inside it.
    ctx.saveGState()
    ctx.addPath(roundedRect(body, bodyRadius))
    ctx.clip()
    let titanium = [CGColor(gray: 0.62, alpha: 1), CGColor(gray: 0.36, alpha: 1), CGColor(gray: 0.55, alpha: 1)] as CFArray
    if let g = CGGradient(colorsSpace: space, colors: titanium, locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    }
    ctx.restoreGState()
    let glass = body.insetBy(dx: band, dy: band)
    ctx.addPath(roundedRect(glass, bodyRadius - band))
    ctx.setFillColor(CGColor(gray: 0.02, alpha: 1))
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(roundedRect(rect, screenRadius))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(screen, in: rect)
    ctx.restoreGState()

    // Dynamic Island: 126x37 pt on a 440 pt wide screen.
    let islandW = rect.width * 126 / 440, islandH = rect.width * 37 / 440
    let island = CGRect(x: rect.midX - islandW / 2, y: rect.maxY - rect.width * 11 / 440 - islandH, width: islandW, height: islandH)
    ctx.addPath(roundedRect(island, islandH / 2))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
}

func drawText(_ ctx: CGContext, _ text: String, at point: CGPoint, size: CGFloat, weight: CTFontUIFontType, color: CGColor) {
    let font = CTFontCreateUIFontForLanguage(weight, size, nil)!
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

struct Layout {
    let name: String
    let size: CGSize
    let mac: CGRect        // where the window image (with its shadow) goes; top-left based, converted below
    let phoneHeight: CGFloat
    let phoneCenter: CGPoint
    let title: CGPoint
    let titleSize: CGFloat
}

let layouts = [
    Layout(name: "hero-x", size: CGSize(width: 3200, height: 1800),
           mac: CGRect(x: 110, y: 240, width: 2320, height: 0), phoneHeight: 1400, phoneCenter: CGPoint(x: 2560, y: 1020),
           title: CGPoint(x: 200, y: 150), titleSize: 96),
    Layout(name: "hero-square", size: CGSize(width: 2160, height: 2160),
           mac: CGRect(x: -10, y: 350, width: 1900, height: 0), phoneHeight: 1220, phoneCenter: CGPoint(x: 1640, y: 1430),
           title: CGPoint(x: 150, y: 170), titleSize: 92),
    // GitHub's social preview: 1280x640, drawn at 2x and scaled down when saved.
    Layout(name: "social", size: CGSize(width: 2560, height: 1280),
           mac: CGRect(x: 90, y: 225, width: 1600, height: 0), phoneHeight: 1000, phoneCenter: CGPoint(x: 2060, y: 740),
           title: CGPoint(x: 150, y: 125), titleSize: 84),
]

// The demo data's backdrop is the playing song's cover; the sample data's is drawn.
let cover = art.flatMap { load($0.appendingPathComponent("olivia-rodrigo-you-seem-pretty-sad-for-a-girl-so.jpg")) }
if art != nil && cover == nil { print("missing cover art in \(art!.path)"); exit(1) }
let tagline = "A native player for YouTube Music and Spotify. Free and open source, for Mac, iPhone and Windows."

/// `image` scaled to `size` (for the social preview, drawn at 2x).
func scaled(_ image: CGImage, to size: CGSize) -> CGImage {
    guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(origin: .zero, size: size))
    return ctx.makeImage() ?? image
}

for mode in ["dark", "light"] {
    let dark = mode == "dark"
    guard let mac = load(raw.appendingPathComponent("mac-home-\(mode).png")),
          let phone = load(raw.appendingPathComponent("ios-nowplaying-\(mode).png")) else {
        print("missing mac-home-\(mode).png or ios-nowplaying-\(mode).png in \(raw.path)"); continue
    }
    for layout in layouts {
        let w = Int(layout.size.width), h = Int(layout.size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
        let H = layout.size.height
        let bg = cover.flatMap { backdrop($0, layout.size, dark: dark) } ?? proceduralBackdrop(layout.size, dark: dark)
        if let bg { ctx.draw(bg, in: CGRect(origin: .zero, size: layout.size)) }

        // Headline, top left.
        let ink = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.06, alpha: 1)
        let soft = dark ? CGColor(gray: 1, alpha: 0.72) : CGColor(gray: 0.06, alpha: 0.66)
        drawText(ctx, "OpenMusic", at: CGPoint(x: layout.title.x, y: H - layout.title.y), size: layout.titleSize, weight: .emphasizedSystem, color: ink)
        drawText(ctx, tagline,
                 at: CGPoint(x: layout.title.x, y: H - layout.title.y - layout.titleSize * 0.95), size: layout.titleSize * 0.42, weight: .system, color: soft)

        // Mac window (its capture already has the system shadow).
        let macW = layout.mac.width, macH = macW * CGFloat(mac.height) / CGFloat(mac.width)
        ctx.interpolationQuality = .high
        ctx.draw(mac, in: CGRect(x: layout.mac.minX, y: H - layout.mac.minY - macH, width: macW, height: macH))

        // iPhone, in front, lower right.
        let phoneH = layout.phoneHeight, phoneW = phoneH * CGFloat(phone.width) / CGFloat(phone.height)
        let rect = CGRect(x: layout.phoneCenter.x - phoneW / 2, y: H - layout.phoneCenter.y - phoneH / 2, width: phoneW, height: phoneH)
        drawPhone(ctx, screen: phone, in: rect, dark: dark)

        if let image = ctx.makeImage() {
            let final = layout.name == "social" ? scaled(image, to: CGSize(width: 1280, height: 640)) : image
            save(final, out.appendingPathComponent("\(layout.name)-\(mode).png"))
        }
    }
    for name in ["mac-home", "mac-album", "mac-lyrics", "mac-queue", "mac-handoff", "ios-nowplaying", "ios-lyrics", "ios-home"] {
        let from = raw.appendingPathComponent("\(name)-\(mode).png"), to = out.appendingPathComponent("\(name)-\(mode).png")
        try? FileManager.default.removeItem(at: to)
        if (try? FileManager.default.copyItem(at: from, to: to)) != nil { print("\(to.lastPathComponent): copied") }
    }
}

// Hero images for posting: the Mac window and the iPhone's Now Playing on a backdrop made from the playing
// song's cover. Run by scripts/demo-shots.sh (compose step); Apple frameworks only.
//
//   swiftc -O scripts/demo-compose.swift -o build/demo-compose
//   build/demo-compose <raw dir> <out dir> <demo art dir>
//
// Reads raw/mac-home-<mode>.png (window with shadow) and raw/ios-nowplaying-<mode>.png (simulator screenshot),
// writes out/hero-x-<mode>.png (3200x1800, 16:9 at 2x of 1600x900) and out/hero-square-<mode>.png (2160x2160).
import AppKit
import CoreImage
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: demo-compose <raw dir> <out dir> <art dir>\n".data(using: .utf8)!)
    exit(2)
}
let raw = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2], isDirectory: true)
let art = URL(fileURLWithPath: args[3], isDirectory: true)
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
]

guard let cover = load(art.appendingPathComponent("olivia-rodrigo-you-seem-pretty-sad-for-a-girl-so.jpg")) else {
    print("missing cover art in \(art.path)"); exit(1)
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
        if let bg = backdrop(cover, layout.size, dark: dark) { ctx.draw(bg, in: CGRect(origin: .zero, size: layout.size)) }

        // Headline, top left.
        let ink = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.06, alpha: 1)
        let soft = dark ? CGColor(gray: 1, alpha: 0.72) : CGColor(gray: 0.06, alpha: 0.66)
        drawText(ctx, "OpenMusic", at: CGPoint(x: layout.title.x, y: H - layout.title.y), size: layout.titleSize, weight: .emphasizedSystem, color: ink)
        drawText(ctx, "YouTube Music and Spotify in one native player for Mac and iPhone",
                 at: CGPoint(x: layout.title.x, y: H - layout.title.y - layout.titleSize * 0.95), size: layout.titleSize * 0.42, weight: .system, color: soft)

        // Mac window (its capture already has the system shadow).
        let macW = layout.mac.width, macH = macW * CGFloat(mac.height) / CGFloat(mac.width)
        ctx.interpolationQuality = .high
        ctx.draw(mac, in: CGRect(x: layout.mac.minX, y: H - layout.mac.minY - macH, width: macW, height: macH))

        // iPhone, in front, lower right.
        let phoneH = layout.phoneHeight, phoneW = phoneH * CGFloat(phone.width) / CGFloat(phone.height)
        let rect = CGRect(x: layout.phoneCenter.x - phoneW / 2, y: H - layout.phoneCenter.y - phoneH / 2, width: phoneW, height: phoneH)
        drawPhone(ctx, screen: phone, in: rect, dark: dark)

        if let image = ctx.makeImage() { save(image, out.appendingPathComponent("\(layout.name)-\(mode).png")) }
    }
    for name in ["mac-home", "mac-album", "mac-lyrics", "mac-queue", "mac-handoff", "ios-nowplaying", "ios-lyrics", "ios-home"] {
        let from = raw.appendingPathComponent("\(name)-\(mode).png"), to = out.appendingPathComponent("\(name)-\(mode).png")
        try? FileManager.default.removeItem(at: to)
        if (try? FileManager.default.copyItem(at: from, to: to)) != nil { print("\(to.lastPathComponent): copied") }
    }
}

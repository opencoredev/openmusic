// Renders Resources/AppIcon.icns: a graphite squircle with faint record grooves and a white note.
// Runs on macOS:  swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: an 824 pt squircle centered on the 1024 canvas.
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    // Drop shadow. Core Graphics draws shadows in device pixels, ignoring the scale above, so offset and blur are
    // scaled by hand: unscaled, the 128 and 256 px sizes (a 96 pt view at 1x and 2x) got the 1024 px shadow, which the
    // canvas edge cut square (council round 25, onboarding).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    NSColor(white: 0.12, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()

    // Graphite body.
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(white: 0.30, alpha: 1), NSColor(white: 0.17, alpha: 1), NSColor(white: 0.08, alpha: 1)],
               atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!.draw(in: rect, angle: -90)

    // Faint grooves, like a record under the note.
    let center = CGPoint(x: 512, y: 512)
    for (i, r) in stride(from: 150.0, through: 420.0, by: 54.0).enumerated() {
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 5
        NSColor.white.withAlphaComponent(i.isMultiple(of: 2) ? 0.045 : 0.03).setStroke()
        ring.stroke()
    }

    // Soft top light.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    ctx.restoreGState()

    // Hairline rim, brighter at the top.
    let rimPath = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rimPath.lineWidth = 4
    NSColor.white.withAlphaComponent(0.14).setStroke()
    rimPath.stroke()

    // The note: SF Symbols' music.note, white with a slight vertical gradient and a soft shadow.
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let origin = CGPoint(x: 512 - size.width / 2 - 14, y: 512 - size.height / 2)
        let noteRect = CGRect(origin: origin, size: size)
        // Mask from the symbol, then fill the mask with a gradient.
        let mask = NSImage(size: size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 22 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        mask.draw(in: noteRect)
        ctx.restoreGState()
        if let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.saveGState()
            ctx.clip(to: noteRect, mask: cg)
            NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: 0.84, alpha: 1)])!.draw(in: noteRect, angle: -90)
            ctx.restoreGState()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(base * scale).representation(using: .png, properties: [:])!
        try! data.write(to: dir.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/AppIcon-1024.png"))
print("wrote \(dir.path)")

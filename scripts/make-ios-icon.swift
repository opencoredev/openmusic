// Renders the iOS app icon from the same art as the Mac icon (scripts/make-icon.swift): graphite with faint record
// grooves and a white note, but full bleed and square, since iOS applies its own mask and no shadow or rim.
// Runs on macOS:  swift scripts/make-ios-icon.swift
// Writes iOS/OpenMusic/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png (plus dark and tinted variants).
import AppKit

enum Variant { case light, dark, tinted }

func render(_ variant: Variant) -> NSBitmapImageRep {
    let px = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)

    switch variant {
    case .light:
        NSGradient(colors: [NSColor(white: 0.30, alpha: 1), NSColor(white: 0.17, alpha: 1), NSColor(white: 0.08, alpha: 1)],
                   atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!.draw(in: rect, angle: -90)
    case .dark:
        NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.06, alpha: 1)])!.draw(in: rect, angle: -90)
    case .tinted:
        NSColor.black.setFill()
        rect.fill()
    }

    // Faint grooves, like a record under the note.
    let center = CGPoint(x: 512, y: 512)
    for (i, r) in stride(from: 170.0, through: 520.0, by: 62.0).enumerated() {
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 6
        NSColor.white.withAlphaComponent(i.isMultiple(of: 2) ? 0.05 : 0.035).setStroke()
        ring.stroke()
    }
    if variant == .light {
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
            .draw(in: CGRect(x: 0, y: 560, width: 1024, height: 464), angle: -90)
    }

    // The note: SF Symbols' music.note, white with a slight vertical gradient.
    let config = NSImage.SymbolConfiguration(pointSize: 540, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let noteRect = CGRect(origin: CGPoint(x: 512 - size.width / 2 - 16, y: 512 - size.height / 2), size: size)
        let mask = NSImage(size: size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        if variant != .tinted {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            mask.draw(in: noteRect)
            ctx.restoreGState()
        }
        if let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.saveGState()
            ctx.clip(to: noteRect, mask: cg)
            NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(white: variant == .tinted ? 1 : 0.84, alpha: 1)])!
                .draw(in: noteRect, angle: -90)
            ctx.restoreGState()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "iOS/OpenMusic/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (variant, name) in [(Variant.light, "AppIcon-1024.png"), (.dark, "AppIcon-1024-dark.png"), (.tinted, "AppIcon-1024-tinted.png")] {
    try! render(variant).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}
print("wrote \(dir.path)")

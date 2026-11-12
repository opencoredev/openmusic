// Contact sheet for scripts/council-shots.sh: every shot named in manifest.tsv, light and dark side by side,
// as small labelled thumbnails on one image.
//   swiftc -O scripts/council-sheet.swift -o build/council-sheet
//   build/council-sheet <shots dir> <manifest.tsv> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: council-sheet <shots dir> <manifest.tsv> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
let names = ((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
let files = names.flatMap { name in ["light", "dark"].map { "\(name)-\($0).png" } }
    .filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }

// Each shot gets a light and a dark cell next to each other; three shots per row.
let cellW: CGFloat = 420, imageH: CGFloat = 270, labelH: CGFloat = 26, gap: CGFloat = 16, margin: CGFloat = 28, titleH: CGFloat = 54
let columns = 6
let rows = (files.count + columns - 1) / columns
let width = margin * 2 + CGFloat(columns) * cellW + CGFloat(columns - 1) * gap
let height = margin * 2 + titleH + CGFloat(rows) * (imageH + labelH) + CGFloat(max(0, rows - 1)) * gap

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = context
NSColor(white: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let title = "OpenMusic · council capture · \(files.count) images" as NSString
title.draw(at: NSPoint(x: margin, y: height - margin - 30),
           withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor(white: 0.1, alpha: 1)])

let label: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
for (i, file) in files.enumerated() {
    let col = i % columns, row = i / columns
    let x = margin + CGFloat(col) * (cellW + gap)
    let top = height - margin - titleH - CGFloat(row) * (imageH + labelH + gap)
    let box = NSRect(x: x, y: top - imageH, width: cellW, height: imageH)
    NSColor(white: file.hasSuffix("-dark.png") ? 0.78 : 0.86, alpha: 1).setFill()
    NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
    if let image = NSImage(contentsOf: dir.appendingPathComponent(file)), image.size.width > 0 {
        let s = min((box.width - 12) / image.size.width, (box.height - 12) / image.size.height)
        let size = NSSize(width: image.size.width * s, height: image.size.height * s)
        image.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
    }
    (file.replacingOccurrences(of: ".png", with: "") as NSString)
        .draw(in: NSRect(x: x + 2, y: top - imageH - labelH + 4, width: cellW - 4, height: labelH - 6), withAttributes: label)
}
NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[3]))
print("contact sheet: \(args[3]) (\(Int(width))x\(Int(height)), \(files.count) images)")

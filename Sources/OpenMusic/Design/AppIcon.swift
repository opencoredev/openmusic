import AppKit
import OpenMusicCore
import SwiftUI

/// The app mark, drawn in SwiftUI from the same design as the .icns (graphite, a white note).
/// The app's own icon (Resources/AppIcon.icns, in the bundle as AppIcon), as Finder and the Dock show it. The icon
/// file carries the system's margin and shadow, so `size` is the full canvas: the tile itself is about 80% of it.
/// A build run outside the bundle (`swift run`) has no icon file and draws `AppGlyph` instead.
struct AppIconImage: View {
    var size: CGFloat = 96

    private static let icon: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let icon = Self.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            AppGlyph(size: size * 0.82)
                .frame(width: size, height: size)
        }
    }
}

struct AppGlyph: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.27), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: max(1, size * 0.012))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                .offset(x: -size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
        .accessibilityHidden(true)
    }
}

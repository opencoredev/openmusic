import AppKit
import SwiftUI

// Helpers the views and self-tests share with the snapshot runner (`SnapshotRunner`, Debug builds only). They are
// compiled in every configuration and do nothing outside snapshot mode, which Release builds never enter.

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Records a view's frame (window coordinates, top-left origin) in snapshot mode, so the runner can click it.
struct DebugFrame: ViewModifier {
    let key: String
    @Environment(AppModel.self) private var model
    @Environment(\.openMusicSnapshot) private var snapshot
    @Environment(\.isLayoutMeasurement) private var measuring

    func body(content: Content) -> some View {
        if snapshot, !measuring {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.debugFrames[key] = $0 }
                .background(DebugProbe(key: key))
        } else {
            content
        }
    }
}

/// An AppKit view behind a tracked control, so a check can read the control's frame in window coordinates
/// at click time. SwiftUI's `.global` frame is relative to the hosting view, and on macOS 26 and later each
/// split-view column has its own, so a recorded frame can point at the wrong place.
@MainActor
enum DebugProbes {
    static let views = NSMapTable<NSString, NSView>.strongToWeakObjects()
    /// Every live `LayoutProbe` view with its key. `views` keeps the last one registered per key, held weakly: when
    /// SwiftUI made a throwaway copy of a row to size it (a sidebar section header), the copy registered last and
    /// was freed, and the key pointed at nothing while the header on screen kept its own probe (round 27's
    /// "signed-out caption: not found": heading no probe). `view(_:)` falls back to a live one in a window.
    static let liveProbes = NSMapTable<NSView, NSString>.weakToStrongObjects()

    /// The probe view for `key`: the one registered last, else any live one with that key that is in a window
    /// (which then becomes the registered one).
    static func view(_ key: String) -> NSView? {
        if let view = views.object(forKey: key as NSString), view.window != nil { return view }
        let enumerator = liveProbes.keyEnumerator()
        while let view = enumerator.nextObject() as? NSView {
            if view.window != nil, liveProbes.object(forKey: view) as String? == key {
                views.setObject(view, forKey: key as NSString)
                return view
            }
        }
        return views.object(forKey: key as NSString)
    }

    /// State a check reads back, such as which list has keyboard focus (set only while probes are on).
    static private(set) var notes: [String: String] = [:]

    static func note(_ key: String, _ value: String?) { notes[key] = value }

    /// The probe's frame in the window, top-left origin like `debugFrames`.
    static func windowFrame(_ key: String) -> CGRect? {
        guard let view = view(key), let window = view.window, let content = window.contentView else { return nil }
        let rect = view.convert(view.bounds, to: content)
        return content.isFlipped ? rect : CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct DebugProbe: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DebugProbes.views.setObject(view, forKey: key as NSString)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DebugProbes.views.setObject(nsView, forKey: key as NSString)
    }
}

/// Captures one of this app's own windows as the window server draws it. Capturing your own windows needs no
/// screen-recording permission, so this works over ssh where `screencapture` can't. `CGWindowListCreateImage` is
/// unavailable to Swift since macOS 15 but still exported, so it's looked up at run time; nil if it ever goes away.
@MainActor
enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    static func image(of window: NSWindow, shadow: Bool = false, fullResolution: Bool = false) -> CGImage? {
        // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming (no shadow), or with the shadow,
        // kCGWindowImageBestResolution (the screen's full pixel density). `fullResolution` adds it without the shadow.
        let options: UInt32 = shadow ? 1 << 3 : (fullResolution ? 1 << 0 | 1 << 3 : 1 << 0)
        return createImage?(.null, 1 << 3, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }

    /// `window` with everything of this app in front of it inside its frame (an attached sheet or alert), at the
    /// screen's full pixel density: what a listener sees of that window.
    static func imageWithSheets(of window: NSWindow) -> CGImage? {
        guard let rect = bounds(of: window) else { return nil }
        // kCGWindowListOptionOnScreenAboveWindow | kCGWindowListOptionIncludingWindow; bounds ignore framing, best resolution.
        return createImage?(rect, 1 << 1 | 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    /// A window's frame as the window server has it (top-left origin, points).
    static func bounds(of window: NSWindow) -> CGRect? {
        bounds(id: CGWindowID(window.windowNumber))
    }

    /// This app's on-screen pop-up menus in front of `window` (a menu button's menu is its own window, not an
    /// `NSWindow` of the app), each captured at full resolution with its window-server bounds.
    static func menuWindows(above window: NSWindow) -> [(CGImage, CGRect)] {
        // kCGWindowListOptionOnScreenAboveWindow
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(window.windowNumber)) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)),
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  let image = createImage?(.null, 1 << 3, number, 1 << 0 | 1 << 3)?.takeRetainedValue()
            else { return nil }
            return (image, rect)
        }
    }

    private static func bounds(id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }
}

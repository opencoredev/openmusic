import OpenMusicCore
import SwiftUI

/// Registers a view's frame with `DebugProbes` during `OPENMUSIC_SELFTEST=layout` or `hover`, so the self-tests can
/// check that nothing on a page reaches past its pane (the queue open in a small window once clipped the page)
/// and find the player's timeline. The council capture uses them to click a queue row. Does nothing in a normal run,
/// nor in Release builds (which have no such self-tests).
struct LayoutProbe: ViewModifier {
    let key: String
    #if DEBUG
    static let enabled = ["layout", "hover"].contains(LaunchEnvironment.current["OPENMUSIC_SELFTEST"] ?? "")
        || LaunchEnvironment.current["OPENMUSIC_SNAPSHOT_ONLY"] == "council"
    #else
    static let enabled = false
    #endif

    @Environment(\.isLayoutMeasurement) private var measuring

    func body(content: Content) -> some View {
        if Self.enabled, !measuring, !key.isEmpty {
            content.background(LayoutProbeView(key: key))
        } else {
            content
        }
    }
}

private struct LayoutProbeView: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.key = key
        DebugProbes.views.setObject(view, forKey: key as NSString)
        DebugProbes.liveProbes.setObject(key as NSString, forKey: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.key = key
        DebugProbes.views.setObject(nsView, forKey: key as NSString)
        DebugProbes.liveProbes.setObject(key as NSString, forKey: nsView)
    }

    /// Registers again when it joins a window, so the view on screen wins: when an album's loading placeholder
    /// gave way to the loaded page, the placeholder's probe updated last and then left, and the key pointed at
    /// nothing (the light `album` shot found no action row).
    final class ProbeView: NSView {
        var key = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !key.isEmpty { DebugProbes.views.setObject(self, forKey: key as NSString) }
        }
    }
}

/// Council captures only: notes when the view has keyboard focus (`DebugProbes.notes["focus"]` is `key`) and takes
/// focus when asked (`FocusProbe.request(key)`), so the Space check can put focus on a Next or sidebar Play button.
/// A button takes focus only with the system's Keyboard Navigation on. Does nothing in a normal run, or in the
/// player's and the hero's hidden measuring copies.
struct FocusProbe: ViewModifier {
    let key: String
    static let requested = Notification.Name("OpenMusicFocusProbeRequest")

    @Environment(\.isLayoutMeasurement) private var layoutMeasuring
    @Environment(\.isPlayerMeasurement) private var playerMeasuring
    @FocusState private var focused: Bool

    static func request(_ key: String) { NotificationCenter.default.post(name: requested, object: key) }

    func body(content: Content) -> some View {
        if LayoutProbe.enabled, !layoutMeasuring, !playerMeasuring {
            content
                .focused($focused)
                .onChange(of: focused) {
                    if focused { DebugProbes.note("focus", key) } else if DebugProbes.notes["focus"] == key { DebugProbes.note("focus", nil) }
                }
                .onReceive(NotificationCenter.default.publisher(for: Self.requested)) { note in
                    if note.object as? String == key { focused = true }
                }
        } else {
            content
        }
    }
}

/// Council captures only: shows a drop target's hover state (a sidebar playlist's highlight, Playing Next's insertion
/// line) without a drag, which the capture can't make: posting pointer events needs Accessibility access the app
/// doesn't have. `DropPreviewProbe.show("playlist:<id>")`, `show("queue:playNext")`, `show(nil)` to clear.
struct DropPreviewProbe: ViewModifier {
    static let requested = Notification.Name("OpenMusicDropPreviewRequest")
    let onPreview: (String?) -> Void

    static func show(_ key: String?) { NotificationCenter.default.post(name: requested, object: key) }

    func body(content: Content) -> some View {
        if LayoutProbe.enabled {
            content.onReceive(NotificationCenter.default.publisher(for: Self.requested)) { onPreview($0.object as? String) }
        } else {
            content
        }
    }
}

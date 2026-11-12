import AppKit
import ObjectiveC

/// Which part of a requested window frame to apply now while the sidebar animates in, and what to apply when the
/// animation is over.
///
/// `floor` is the window's width when the animation began, where the columns fit. Two kinds of request arrive:
/// - **Intent**, from outside the sidebar's transition: the user's live resize, a zoom or tile, a `setFrame` from the
///   app or a script. The latest one is remembered (`intent`) and is the window's size once the animation is over.
///   A widening goes through at once; a narrowing below `floor` is clamped to it until then.
/// - **SwiftUI's own frames** (`NSHostingView` resizing the window from `windowDidLayout` as the column moves). They
///   are never remembered. While the animation runs they can't take the window below `floor` or below the latest
///   intent, so a widening asked for during the animation stays (SwiftUI set the window back to 960 after a widening
///   to 1300 150 ms in, then stepped toward it: 620, 627, … 955, and the guard used to apply that 955 at its end).
///
/// Height follows the request. A clamped narrowing keeps the edge that wasn't dragged (a drag of the left edge keeps
/// the right edge).
struct ShrinkDeferral: Equatable {
    let floor: CGFloat
    /// The latest frame asked for from outside the sidebar's transition, to be the window's frame once it is over.
    private(set) var intent: NSRect?

    init(floor: CGFloat) {
        self.floor = floor
    }

    /// The narrowest the window may be right now.
    var minimumWidth: CGFloat { max(floor, intent?.width ?? 0) }

    mutating func adjust(current: NSRect, requested: NSRect, intent isIntent: Bool) -> NSRect {
        if isIntent { intent = requested }
        let minimum = minimumWidth
        guard requested.width < minimum - 0.5 else { return requested }
        let leftEdgeMoved = abs(requested.minX - current.minX) > 0.5 && abs(requested.maxX - current.maxX) <= 0.5
        let x = leftEdgeMoved ? requested.maxX - minimum : requested.minX
        return NSRect(x: x, y: requested.minY, width: minimum, height: requested.height)
    }

    /// The frame to apply when the animation is over: the latest intent, unless the window already has it; nil
    /// without one (SwiftUI's frames are its own business once the guard ends).
    func frameAtEnd(current: NSRect) -> NSRect? {
        guard let intent else { return nil }
        let same = abs(intent.minX - current.minX) <= 0.5 && abs(intent.minY - current.minY) <= 0.5
            && abs(intent.width - current.width) <= 0.5 && abs(intent.height - current.height) <= 0.5
        return same ? nil : intent
    }
}

/// Puts the window back to its width after AppKit widened it for the sidebar (`AppModel.fitPanelBesideShownSidebar`),
/// and only that widening.
///
/// `stamp` counts the window actions that decide its size (frame requests through `setFrame` from the app, the
/// user's live resize, zoom or tiling, and full screen). A resize at the starting stamp that widens the window is
/// AppKit's own (its layout, outside `setFrame`): it is the expansion to undo, and its frame is the one expected.
/// The correction applies only while the stamp is unchanged and the window is still at that frame; anything newer
/// keeps the window as it is.
struct WidthCorrection: Equatable {
    let original: NSRect
    let stamp: Int
    private(set) var expected: NSRect?

    init(original: NSRect, stamp: Int) {
        self.original = original
        self.stamp = stamp
    }

    mutating func windowResized(to frame: NSRect, stamp: Int) {
        guard stamp == self.stamp else { return }
        expected = frame.width - original.width > 1 ? frame : nil
    }

    /// The frame to put the window back to, or nil to leave it.
    func correctedFrame(current: NSRect, stamp: Int) -> NSRect? {
        guard stamp == self.stamp, let expected, current == expected else { return nil }
        return NSRect(x: current.minX, y: current.minY, width: original.width, height: current.height)
    }
}

/// Marks the one `setFrame` call the app asked for through `NSWindow.requestFrame` as intent.
///
/// The mark names the window and the frame, and the exchanged `setFrame` consumes it before calling AppKit's own
/// implementation. A frame request made while AppKit applies that frame (SwiftUI's hosting view resizing the window
/// from `windowDidLayout`, reentrantly) finds no mark and is judged by its caller, so it can't pass as the app's
/// intent and replace it (a depth counter held for the whole call let SwiftUI's 960 replace a requested 1300).
struct FrameIntentMarker: Equatable {
    private var window: ObjectIdentifier?
    private var frame: NSRect?

    /// Marks the next `setFrame(frame)` on `window` as intent; returns the mark it replaced, to put back afterwards.
    mutating func mark(_ window: ObjectIdentifier, _ frame: NSRect) -> FrameIntentMarker {
        let previous = self
        self.window = window
        self.frame = frame
        return previous
    }

    /// Whether this request is the marked one; the mark is used up either way when it matches the window.
    mutating func consume(_ window: ObjectIdentifier, _ frame: NSRect) -> Bool {
        guard self.window == window, let marked = self.frame else { return false }
        self.window = nil
        self.frame = nil
        return marked == frame
    }
}

/// Holds off shrinking the main window while the sidebar's column animates in.
///
/// Shrinking the window while AppKit animates the sidebar back (after a panel that hid it closes, 1100 → 900 pt
/// 150 ms into the animation) made SwiftUI grow the window by the width it lost, pass after pass (900, 1100, 1300,
/// … 81100 pt), until AppKit aborted ("more Update Constraints in Window passes than there are views in the
/// window"). The columns' widths fit 900 (`SplitViewTuning.neededWidth`); it is the column in flight that SwiftUI
/// can't follow. So from the moment the column starts to uncollapse (`AppModel.observeSidebarColumn`, whichever path
/// showed it) until its animation has ended, the main window can't get narrower than it was when the animation
/// began. Only requests from outside the transition count as what the window should become (`ShrinkDeferral`): a
/// narrower one is clamped to that width and applied once the animation is over, a wider one goes through and stays,
/// and SwiftUI's own frames are clamped but never remembered (`isSwiftUIFrame`).
///
/// `NSWindow.setFrame(_:display:)` and `setFrame(_:display:animate:)` are exchanged once for versions that ask
/// `adjust` first; they act only on the guarded window during the guard. Live resizing sets the frame through the
/// same method, so a drag of the window's edge is held too. SwiftUI owns the window's delegate, and
/// `windowWillResize(_:to:)` is never asked about programmatic frames, so a delegate can't do this.
@MainActor
enum SidebarAnimationGuard {
    private static weak var window: NSWindow?
    private static var deferral: ShrinkDeferral?
    private static var generation = 0
    private static var installed = false
    /// Inside `setFrame(_:display:animate:)`: AppKit's own steps toward the frame already adjusted go through as
    /// they are, and don't count as requests.
    private static var animatedDepth = 0
    /// Whether a sidebar animation is being guarded.
    static private(set) var isActive = false
    /// The frame `NSWindow.requestFrame` is about to set: the app asks for it, so it is intent wherever it is called
    /// from. Only that one call on that window counts (`FrameIntentMarker`).
    private static var intentMarker = FrameIntentMarker()

    /// The main window, whose frame requests are counted (`frameRequests`).
    private static weak var watched: NSWindow?
    /// How many times the main window was asked for a new width through `setFrame`: by the app, the user's live
    /// resize, zoom or tiling. AppKit's own layout widening the window for a column doesn't count. `AppModel` uses
    /// it to tell a newer window action from the widening it corrects (`WidthCorrection`).
    static private(set) var frameRequests = 0

    #if DEBUG
    /// `MEDLEY_RESIZE_TRACE` (`ResizeSelfTest`).
    static var debugLog: ((String) -> Void)?
    #endif

    /// Starts counting `window`'s frame requests (and installs the exchanged `setFrame` methods).
    static func watch(_ window: NSWindow?) {
        installOnce()
        watched = window
    }

    /// Guards `window` for `duration` seconds from now: a newer begin restarts the time.
    static func begin(_ window: NSWindow, duration: TimeInterval) {
        installOnce()
        guard !window.styleMask.contains(.fullScreen) else { return }
        // A guard already running keeps its floor (the narrower one) and what it holds.
        if self.window !== window || !isActive || deferral == nil {
            deferral = ShrinkDeferral(floor: window.frame.width)
        } else if let held = deferral, window.frame.width < held.floor {
            deferral = ShrinkDeferral(floor: window.frame.width)
        }
        self.window = window
        isActive = true
        generation &+= 1
        let current = generation
        #if DEBUG
        debugLog?("guard begins for \(duration) s at \(Int(window.frame.width))")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            MainActor.assumeIsolated { end(current) }
        }
    }

    /// Drops the guard and any held shrink: the window is going full screen, or something newer decides its size.
    static func cancel() {
        generation &+= 1
        isActive = false
        deferral = nil
    }

    private static func end(_ ending: Int) {
        guard ending == generation, isActive else { return }
        isActive = false
        let held = deferral
        deferral = nil
        let frame = window.flatMap { held?.frameAtEnd(current: $0.frame) }
        #if DEBUG
        debugLog?("guard ends at \(Int(window?.frame.width ?? 0)), intent \(held?.intent.map { String(Int($0.width)) } ?? "none"), applying \(frame.map { String(Int($0.width)) } ?? "nothing")")
        #endif
        guard let window, let frame, !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(frame, display: true)
    }

    fileprivate static func adjust(_ window: NSWindow, _ frame: NSRect) -> NSRect {
        // Consumed before AppKit runs, so nothing reentrant inherits it.
        let isRequested = intentMarker.consume(ObjectIdentifier(window), frame)
        guard animatedDepth == 0 else { return frame }
        if window === watched, abs(frame.width - window.frame.width) > 0.5 { frameRequests &+= 1 }
        guard isActive, window === self.window else { return frame }
        if window.styleMask.contains(.fullScreen) { cancel(); return frame }
        guard var held = deferral else { return frame }
        let fromSwiftUI = !isRequested && isSwiftUIFrame()
        let adjusted = held.adjust(current: window.frame, requested: frame, intent: !fromSwiftUI)
        deferral = held
        #if DEBUG
        let who = fromSwiftUI ? "SwiftUI's" : "intent"
        if adjusted != frame {
            debugLog?("held \(who) \(Int(frame.width)) at \(Int(window.frame.width)) to \(Int(adjusted.width)) (floor \(Int(held.floor)))\(window.inLiveResize ? " (live resize)" : "")")
        } else {
            debugLog?("let through \(who) \(Int(frame.width)) at \(Int(window.frame.width)) (floor \(Int(held.floor)))")
        }
        #endif
        return adjusted
    }

    /// Whether the frame request being handled comes from SwiftUI itself: its hosting view sets the window's frame
    /// from `windowDidLayout` (`NSHostingView.updateAnimatedWindowSize`) as the sidebar's column moves. Read from the
    /// first caller outside Medley's own code: SwiftUI or SwiftUICore for those frames, AppKit for a live resize,
    /// zoom, tile or script. App code can run under SwiftUI too (a `.task`, a button's action), so the app's own
    /// requests go through `NSWindow.requestFrame` and never get here. Runs only during a guard, for each request
    /// on the guarded window.
    private static func isSwiftUIFrame() -> Bool {
        let own = UnsafeRawPointer(#dsohandle)
        for number in Thread.callStackReturnAddresses.prefix(24) {
            guard let address = UnsafeRawPointer(bitPattern: number.uintValue) else { continue }
            var info = Dl_info()
            guard dladdr(address, &info) != 0 else { return false }
            if let base = info.dli_fbase, UnsafeRawPointer(base) == own { continue }
            guard let path = info.dli_fname else { return false }
            let image = String(cString: path)
            return image.hasSuffix("/SwiftUI") || image.hasSuffix("/SwiftUICore")
        }
        return false
    }

    fileprivate static func asIntent(_ window: NSWindow, _ frame: NSRect, _ body: () -> Void) {
        let previous = intentMarker.mark(ObjectIdentifier(window), frame)
        // Put back whatever an enclosing request had marked (normally nothing: the exchanged `setFrame` consumed it).
        defer { intentMarker = previous }
        body()
    }

    fileprivate static func enterAnimatedSetFrame() { animatedDepth += 1 }
    fileprivate static func leaveAnimatedSetFrame() { animatedDepth -= 1 }

    private static func installOnce() {
        guard !installed else { return }
        installed = true
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.setFrame(_:display:)), #selector(NSWindow.medley_guardedSetFrame(_:display:))),
            (#selector(NSWindow.setFrame(_:display:animate:)), #selector(NSWindow.medley_guardedSetFrame(_:display:animate:))),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getInstanceMethod(NSWindow.self, original),
                  let b = class_getInstanceMethod(NSWindow.self, replacement) else { continue }
            method_exchangeImplementations(a, b)
        }
    }
}

extension NSWindow {
    /// Sets the frame as the app's decision (a self-test's or a script's size, putting back a width AppKit changed):
    /// while the sidebar animates in, it is what the window becomes, like the user's resize and unlike SwiftUI's own
    /// frames (`SidebarAnimationGuard`). Use it for every frame the app sets on the main window.
    func requestFrame(_ frame: NSRect, display: Bool = true) {
        SidebarAnimationGuard.asIntent(self, frame) { setFrame(frame, display: display) }
    }

    func requestFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        SidebarAnimationGuard.asIntent(self, frame) { setFrame(frame, display: display, animate: animate) }
    }

    // After the exchange these names call AppKit's own implementations.
    @objc fileprivate func medley_guardedSetFrame(_ frame: NSRect, display: Bool) {
        medley_guardedSetFrame(SidebarAnimationGuard.adjust(self, frame), display: display)
    }

    @objc fileprivate func medley_guardedSetFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        let adjusted = SidebarAnimationGuard.adjust(self, frame)
        SidebarAnimationGuard.enterAnimatedSetFrame()
        defer { SidebarAnimationGuard.leaveAnimatedSetFrame() }
        medley_guardedSetFrame(adjusted, display: display, animate: animate)
    }
}

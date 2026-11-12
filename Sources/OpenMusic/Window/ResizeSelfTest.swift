#if DEBUG
import AppKit
import OpenMusicCore
import SwiftUI

/// `OPENMUSIC_MOCK=1 OPENMUSIC_SELFTEST=resize OPENMUSIC_SELFTEST_OUT=<file>`: shrinks the main window while the sidebar
/// and the lyrics or queue panel are both open, which aborted in AppKit's Update Constraints pass ("more Update
/// Constraints in Window passes than there are views in the window") at 1100 pt. Run it with
/// `scripts/mac-selftest.sh resize <runs>` on the Mac.
///
/// From 1440×900 with the sidebar at its ideal width, for each panel: shrink in 20 pt steps to 1100, then 960 and
/// the minimum; jump straight to 1100, 960 and the minimum; shrink during the panel's open animation; shrink right
/// after the panel closes (while the sidebar comes back); drag the window's corner the way a person does; and the
/// widest columns (sidebar 300, panel 520) shrunk in steps and in one jump; and showing the sidebar while the panel
/// is open at 1200 (beside a 310 pt panel), 1220 (beside a 520 pt panel), 1180, 1150, 1100, 960 and 900 pt, with a click on the toolbar's button, the View menu's ⌃⌘S item, the
/// `columnVisibility` binding and AppKit's own `toggleSidebar`. After each settled step the split view must fit the window (nothing pushed off its right edge), the
/// page must keep its 420 pt minimum, the window must keep the width it was given (no growing to fit the columns),
/// and the panel and the sidebar must be open or hidden as the rule in `AppModel.showSidebarBesidePanel` says: they
/// share the window only from `bothWidth` up; below it opening a panel or narrowing the window hides the sidebar,
/// showing the sidebar closes a panel it doesn't fit beside (`keepsPanel`), and closing a panel brings back a
/// sidebar it hid.
/// Then, with a panel: shrinking the moment the sidebar starts to come back (`guard`, by `setFrame` and by a drag),
/// widening the window right after AppKit showed the sidebar and closed the panel (`widen`), and showing the
/// sidebar in native full screen (`fullscreen`), and reopening a panel dragged to 520 pt while the sidebar was hidden,
/// beside the sidebar at 1220 pt, where it must come back no wider than the room left (`reopen`,
/// `OPENMUSIC_RESIZE_REOPEN` cycles per panel, default 4), and reopening it before the close has settled (`rapid`,
/// `OPENMUSIC_RESIZE_RAPID_DELAYS`, default 0,50,150,400 ms); and without one, View › Show/Hide Sidebar's enabled state (`menu`)
/// and a relaunch with a narrow saved frame, the sidebar's saved width and lyrics open at once (`relaunch`: the
/// first launch saves the state and ends with `RELAUNCH`, and `scripts/mac-selftest.sh` launches the app again).
/// `OPENMUSIC_RESIZE_ONLY=sidebar,steps,jump,opening,closing,guard,drag,toggle,reopen,rapid,widen,fullscreen,wide,menu,relaunch` picks scenarios,
/// `OPENMUSIC_RESIZE_PANELS=lyrics,queue` panels, and `OPENMUSIC_RESIZE_WIDTHS=960,900` and
/// `OPENMUSIC_RESIZE_PATHS=toolbar,menu,binding,appkit` the `toggle` cases; `OPENMUSIC_RESIZE_TRACE=1` logs the sidebar
/// rule's decisions and the column caps. Writes a line before each step, so a crash shows where it happened, then a
/// last line with PASS or FAIL, and quits.
@MainActor
struct ResizeSelfTest {
    let model: AppModel
    let output: URL

    /// The window's minimum: `MainWindow`'s `.frame(minWidth: 900)`.
    static let minimum: CGFloat = 900
    /// The narrowest window holding the sidebar at its minimum (190) beside the page (420) and a panel at its ideal
    /// width (310): 420 + 2 × 190 + 310 + 2 on macOS 26 and later, where the page's column counts the sidebar twice,
    /// and 420 + 190 + 310 + 2 before. Written out here rather than read from `SplitViewTuning`, so the test checks
    /// the app's arithmetic instead of repeating it.
    static var bothWidth: CGFloat {
        if #available(macOS 26.0, *) { 1112 } else { 922 }
    }
    /// Whether showing the sidebar keeps a panel this wide: the sidebar at its 232 ideal width fits beside it (at
    /// least its 310 ideal) and the page, the sidebar counted twice on macOS 26 and later (see `bothWidth`).
    static func keepsPanel(window: CGFloat, panel: CGFloat) -> Bool {
        let sidebar: CGFloat
        if #available(macOS 26.0, *) { sidebar = 2 * 232 } else { sidebar = 232 }
        return window >= 420 + sidebar + max(panel, 310) + 2
    }

    func run() async {
        if LaunchEnvironment.current["OPENMUSIC_SELFTEST_RELAUNCHED"] != nil { return await relaunched() }
        var log: [String] = []
        func note(_ line: String) {
            log.append(line)
            try? log.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        let env = LaunchEnvironment.current
        let only = env["OPENMUSIC_RESIZE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
        let panels = env["OPENMUSIC_RESIZE_PANELS"].map { $0.split(separator: ",").compactMap { InspectorPanel(rawValue: String($0)) } }
            ?? [.lyrics, .queue]

        while model.mainWindow == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let window = model.mainWindow, let yt = model.provider(.youtubeMusic) as? MockProvider,
              let root = window.contentView, let (sidebarController, sidebarItem) = SplitViewTuning.sidebarItem(in: root)
        else { return note("setup: FAIL") }
        let album = yt.catalog.albums[0]
        if let detail = try? await yt.album(id: album.providerID) {
            model.play(detail.tracks, startAt: 0, from: .init(title: album.title))
        }

        func setWidth(_ width: CGFloat) {
            window.requestFrame(NSRect(x: 60, y: 60, width: width, height: 900), display: true)
        }
        func sidebarWidth() -> CGFloat {
            sidebarItem.isCollapsed ? 0 : sidebarController.splitView.arrangedSubviews.first?.frame.width ?? 0
        }
        func panelWidth() -> CGFloat { SplitViewTuning.inspectorWidth(in: window) ?? 0 }
        /// The page's visible width: the window less the sidebar and the panel floating over the page's column.
        func pageWidth() -> CGFloat { root.bounds.width - sidebarWidth() - panelWidth() }
        /// How far the split view reaches past the window's right edge.
        func overflow() -> CGFloat {
            (SplitViewTuning.inspectorSplitView(in: root).map { $0.convert($0.bounds, to: root).maxX } ?? 0) - root.bounds.maxX
        }
        func state() -> String {
            "window \(Int(window.frame.width)), sidebar \(sidebarItem.isCollapsed ? "hidden" : String(Int(sidebarWidth()))), "
                + "panel \(SplitViewTuning.inspectorWidth(in: window).map { String(Int($0)) } ?? "closed"), page \(Int(pageWidth()))"
        }
        var ok = true
        /// The settled layout fits the window and leaves the page its minimum, the window kept the width it was
        /// given, and the panel and the sidebar are open or hidden as expected (nil: either).
        func check(_ label: String, width: CGFloat, panel: Bool, sidebar: Bool?) {
            var problems: [String] = []
            if overflow() > 1 { problems.append("split view \(Int(overflow())) pt past the window's edge") }
            if pageWidth() < 420 - 3 { problems.append("page under 420") }
            if abs(window.frame.width - width) > 1 { problems.append("window \(Int(window.frame.width)) wide, expected \(Int(width))") }
            let panelOpen = SplitViewTuning.inspectorWidth(in: window) != nil
            if (model.inspector != nil) != panel || panelOpen != panel {
                problems.append("panel \(model.inspector?.rawValue ?? "closed") (on screen: \(panelOpen)), expected \(panel ? "open" : "closed")")
            }
            let shown = model.columnVisibility != .detailOnly
            if shown == sidebarItem.isCollapsed { problems.append("sidebar binding \(shown ? "shown" : "hidden") but the column \(sidebarItem.isCollapsed ? "collapsed" : "shown")") }
            if let sidebar, shown != sidebar { problems.append("sidebar \(shown ? "shown" : "hidden"), expected \(sidebar ? "shown" : "hidden")") }
            ok = ok && problems.isEmpty
            note("\(label): \(state())\(problems.map { ", \($0) FAIL" }.joined())")
        }
        /// Menu commands reach the app only while it is active with the main window in front, as for a person choosing
        /// them (View › Show/Hide Sidebar is disabled otherwise). On the shared Mac another app can take the front
        /// during a run, so a menu step first brings the window back and says so.
        func bringToFront(_ label: String) async {
            guard !NSApp.isActive || NSApp.keyWindow !== window else { return }
            note("\(label): bringing the window to the front (app active \(NSApp.isActive), window key \(NSApp.keyWindow === window))")
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
        }
        /// With a panel open, the sidebar stays only in a window wide enough for both.
        func sidebarBeside(_ width: CGFloat) -> Bool { width >= Self.bothWidth }
        func setSidebarWidth(_ width: CGFloat) {
            guard !sidebarItem.isCollapsed else { return }
            sidebarController.splitView.setPosition(width, ofDividerAt: 0)
        }
        /// Back to 1440 with the sidebar shown at its ideal width and no panel. The sidebar's width persists between
        /// launches, so every scenario starts from the same one.
        func reset() async {
            if model.inspector != nil { model.inspector = nil; try? await Task.sleep(for: .seconds(1)) }
            setWidth(1440)
            try? await Task.sleep(for: .milliseconds(500))
            if model.columnVisibility != .all { model.columnVisibility = .all; try? await Task.sleep(for: .seconds(1)) }
            setSidebarWidth(232)
            try? await Task.sleep(for: .milliseconds(300))
        }
        /// Opens `panel` at 1440 with the sidebar shown and waits for it to settle (lyrics widen to 420 at 0.6 s).
        func open(_ panel: InspectorPanel) async {
            await reset()
            model.toggleInspector(panel)
            try? await Task.sleep(for: .seconds(1.6))
        }
        func shrinkInSteps(_ name: String, to target: CGFloat, panel: Bool) async {
            var width = window.frame.width
            while width - 20 >= target {
                width -= 20
                note("\(name): shrinking to \(Int(width))")
                setWidth(width)
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(500))
            check("\(name): at \(Int(width))", width: width, panel: panel, sidebar: panel ? sidebarBeside(width) : true)
        }

        try? await Task.sleep(for: .seconds(1))
        await reset()
        note("setup: \(state()), playing \(model.player.current?.title ?? "-")")
        // `OPENMUSIC_RESIZE_TRACE=1` logs the sidebar rule's decisions and the column caps as they happen.
        if env["OPENMUSIC_RESIZE_TRACE"] != nil {
            // Milliseconds since tracing began, to line the trace up with a crash report or the system log.
            let t0 = Date()
            func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
            SplitViewTuning.debugLog = { note("  trace \(ms()): \($0)") }
            model.debugSidebarTrace = { note("  trace \(ms()): \($0)") }
            SidebarAnimationGuard.debugLog = { note("  trace \(ms()): \($0)") }
        }

        let targets: [CGFloat] = [1100, 960, Self.minimum]
        if wanted("sidebar") {
            // No panel, the sidebar dragged to its 300 maximum: the page's column alone then needs 420 + 2 × 300.
            for jump in [false, true] {
                await reset()
                if let sidebar = sidebarController.splitView.arrangedSubviews.first {
                    note("sidebar wide: dragging the sidebar's edge to 300, \(state())")
                    dragDivider(in: window, at: sidebar.convert(sidebar.bounds, to: nil).maxX + 0.5, by: 300 - sidebarWidth())
                    try? await Task.sleep(for: .milliseconds(800))
                }
                check("sidebar wide: dragged", width: 1440, panel: false, sidebar: true)
                if jump {
                    note("sidebar wide: jump to \(Int(Self.minimum))")
                    setWidth(Self.minimum)
                    try? await Task.sleep(for: .milliseconds(700))
                    check("sidebar wide: jump to \(Int(Self.minimum)) done", width: Self.minimum, panel: false, sidebar: true)
                } else {
                    await shrinkInSteps("sidebar wide steps", to: Self.minimum, panel: false)
                }
            }
        }
        for panel in panels {
            let name = panel.rawValue
            if wanted("steps") {
                await open(panel)
                check("\(name) steps: opened", width: 1440, panel: true, sidebar: true)
                await shrinkInSteps("\(name) steps", to: 1100, panel: true)
                for target in targets.dropFirst() {
                    note("\(name) steps: shrinking to \(Int(target))")
                    setWidth(target)
                    try? await Task.sleep(for: .milliseconds(600))
                    check("\(name) steps: at \(Int(target))", width: target, panel: true, sidebar: sidebarBeside(target))
                }
            }
            if wanted("jump") {
                for target in targets {
                    await open(panel)
                    note("\(name) jump 1440 -> \(Int(target)): \(state())")
                    setWidth(target)
                    try? await Task.sleep(for: .milliseconds(700))
                    check("\(name) jump 1440 -> \(Int(target)): done", width: target, panel: true, sidebar: sidebarBeside(target))
                }
            }
            if wanted("opening") {
                // During the open animation, and around the divider move at 0.6 s that widens lyrics.
                for delay in [0, 100, 250, 550, 650, 1150] {
                    for target in [1100, Self.minimum] {
                        await reset()
                        note("\(name) opening, shrink to \(Int(target)) after \(delay) ms")
                        model.toggleInspector(panel)
                        try? await Task.sleep(for: .milliseconds(delay))
                        setWidth(target)
                        try? await Task.sleep(for: .milliseconds(1400))
                        // The sidebar may hide as the panel opens (it starts at 232 pt), even where a 190 pt one would fit.
                        check("\(name) opening, shrink to \(Int(target)) after \(delay) ms: done", width: target, panel: true,
                              sidebar: sidebarBeside(target) ? nil : false)
                    }
                }
            }
            if wanted("closing") {
                // A panel opened under 1120 pt hides the sidebar, which comes back 0.3 s after it closes.
                for delay in [0, 150, 300, 350, 450, 700] {
                    await reset()
                    setWidth(1100)
                    try? await Task.sleep(for: .milliseconds(500))
                    model.toggleInspector(panel)
                    try? await Task.sleep(for: .milliseconds(1400))
                    note("\(name) closing at 1100, shrink to \(Int(Self.minimum)) after \(delay) ms: \(state())")
                    model.inspector = nil
                    try? await Task.sleep(for: .milliseconds(delay))
                    setWidth(Self.minimum)
                    try? await Task.sleep(for: .milliseconds(1200))
                    // The sidebar hidden for the panel comes back: it fits beside the page alone at 900.
                    check("\(name) closing, shrink after \(delay) ms: done", width: Self.minimum, panel: false, sidebar: true)
                }
            }
            if wanted("guard") {
                // The window shrinks (by `setFrame`, and by dragging its corner) the moment the sidebar's column
                // starts to come back after the panel closes: the window keeps its width until the column is in
                // (`SidebarAnimationGuard`), then takes the width it was given.
                for how in ["setFrame", "drag"] {
                    await reset()
                    setWidth(1100)
                    try? await Task.sleep(for: .milliseconds(500))
                    model.toggleInspector(panel)
                    try? await Task.sleep(for: .milliseconds(1400))
                    note("\(name) guard (\(how)) at 1100: \(state())")
                    model.inspector = nil
                    var waited = 0
                    while sidebarItem.isCollapsed, waited < 1500 {
                        try? await Task.sleep(for: .milliseconds(5))
                        waited += 5
                    }
                    note("\(name) guard (\(how)): column uncollapsing after \(waited) ms, shrinking to \(Int(Self.minimum))")
                    if how == "drag" {
                        dragCorner(of: window, by: Self.minimum - window.frame.width)
                        // The queued drag runs on the next turns of the main loop, inside the guard's 0.8 s.
                        try? await Task.sleep(for: .milliseconds(150))
                    } else {
                        setWidth(Self.minimum)
                    }
                    let held = abs(window.frame.width - 1100) <= 1
                    ok = ok && held && !sidebarItem.isCollapsed
                    note("\(name) guard (\(how)): right after the shrink the window is \(Int(window.frame.width))\(held ? "" : ", expected 1100 until the sidebar is in FAIL")")
                    try? await Task.sleep(for: .milliseconds(1400))
                    check("\(name) guard (\(how)): done", width: Self.minimum, panel: false, sidebar: true)
                }
            }
            if wanted("drag") {
                await open(panel)
                for target in targets {
                    let before = window.frame.width
                    note("\(name) drag corner \(Int(before)) -> \(Int(target)): \(state())")
                    dragCorner(of: window, by: target - before)
                    try? await Task.sleep(for: .milliseconds(800))
                    let moved = abs(window.frame.width - target) <= 2
                    ok = ok && moved
                    check("\(name) drag corner to \(Int(target)): done\(moved ? "" : " (the window did not follow the drag) FAIL")",
                          width: window.frame.width, panel: true, sidebar: sidebarBeside(window.frame.width))
                }
            }
            if wanted("toggle") {
                // Showing the sidebar while the panel is open: a click on the toolbar's button, the View menu's item
                // (⌃⌘S), the binding, and the split view controller's `toggleSidebar` (AppKit's own path, for anything
                // else that shows the column). The panel stays when the sidebar at its ideal width fits beside it at
                // its current width (`keepsPanel`), and closes otherwise; the window keeps its width either way. From
                // 1180 down opening the panel hides the sidebar (1180 is under the 1196 pt the 232 pt sidebar needs beside
                // a 310 pt panel). At 1200 and 1220 it doesn't (unless the panel comes back at an earlier 520 pt drag,
                // `AppModel.fitInspector`), so the sidebar is hidden by hand and the panel set to 310 (kept, the sidebar capped at 234) or dragged to its 520
                // maximum (closed).
                let cases: [(window: CGFloat, panel: CGFloat?)] = [(1200, 310), (1220, InspectorMetrics.maxWidth), (1180, nil), (1150, nil),
                                                                   (1100, nil), (960, nil), (Self.minimum, nil)]
                let paths = env["OPENMUSIC_RESIZE_PATHS"].map { Set($0.split(separator: ",").map(String.init)) }
                let widths = env["OPENMUSIC_RESIZE_WIDTHS"].map { Set($0.split(separator: ",").compactMap { Double($0) }) }
                for (target, handPanel) in cases where widths?.contains(Double(target)) ?? true {
                    for path in ["toolbar", "menu", "binding", "appkit"] where paths?.contains(path) ?? true {
                        await reset()
                        setWidth(target)
                        try? await Task.sleep(for: .milliseconds(500))
                        model.toggleInspector(panel)
                        try? await Task.sleep(for: .milliseconds(1400))
                        if let handPanel {
                            if model.columnVisibility != .detailOnly {
                                SplitViewTuning.toggleSidebar(in: window)
                                try? await Task.sleep(for: .milliseconds(1000))
                            }
                            SplitViewTuning.setInspectorWidth(handPanel, in: window)
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                        let label = "\(name) show sidebar at \(Int(target)) with the \(path)"
                        note("\(label): \(state())")
                        let kept = Self.keepsPanel(window: target, panel: panelWidth())
                        switch path {
                        case "toolbar":
                            guard let button = Self.sidebarToolbarButton(in: window) else {
                                ok = false
                                note("\(label): no sidebar button in the toolbar FAIL")
                                continue
                            }
                            let frame = button.convert(button.bounds, to: nil)
                            post(in: window, from: NSPoint(x: frame.midX, y: frame.midY), by: 0)
                        case "appkit": SplitViewTuning.toggleSidebar(in: window)
                        case "menu":
                            await bringToFront(label)
                            guard let (menu, index) = Self.sidebarMenuItem() else {
                                ok = false
                                note("\(label): no View menu item with ⌃⌘S FAIL")
                                continue
                            }
                            Self.click(menu, index)
                        default: model.columnVisibility = .all
                        }
                        try? await Task.sleep(for: .milliseconds(1400))
                        check("\(label): done", width: target, panel: kept, sidebar: true)
                    }
                }
            }
            /// With the sidebar hidden, the panel dragged to its 520 pt maximum: the width AppKit keeps wanting after
            /// it closes. False (and a FAIL) when the drag didn't get there.
            func widenWithSidebarHidden(_ label: String) async -> Bool {
                if !sidebarItem.isCollapsed {
                    SplitViewTuning.toggleSidebar(in: window)
                    try? await Task.sleep(for: .milliseconds(1000))
                }
                SplitViewTuning.setInspectorWidth(InspectorMetrics.maxWidth, in: window)
                try? await Task.sleep(for: .milliseconds(500))
                guard sidebarItem.isCollapsed, abs(panelWidth() - InspectorMetrics.maxWidth) <= 1 else {
                    ok = false
                    note("\(label): setup: panel \(Int(panelWidth())) with the sidebar \(sidebarItem.isCollapsed ? "hidden" : "shown"), expected 520 beside a hidden sidebar FAIL")
                    return false
                }
                return true
            }
            /// Samples the window every 10 ms for `duration` after a panel opens: whenever the sidebar shows, the columns
            /// must fit (`SplitViewTuning.neededWidth`). Returns the widest panel seen beside the sidebar.
            func sampleOpen(_ label: String, for duration: Int = 1400) async -> CGFloat {
                var peak: CGFloat = 0, worst: CGFloat = 0
                for _ in 0..<(duration / 10) {
                    let sidebar = sidebarWidth()
                    if sidebar > 0 {
                        peak = max(peak, panelWidth())
                        worst = max(worst, SplitViewTuning.neededWidth(sidebar: sidebar, panel: panelWidth()) - root.bounds.width)
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                if worst > 1 {
                    ok = false
                    note("\(label): the columns needed \(Int(worst)) pt more than the window while opening (panel up to \(Int(peak)) beside the sidebar) FAIL")
                }
                return peak
            }
            /// After a reopen: whether the sidebar was hidden although the panel came back within the room beside it.
            var reopens = 0, needlessHides = 0
            func countHide(_ label: String) {
                reopens += 1
                let room = SplitViewTuning.panelRoom(windowWidth: root.bounds.width, sidebarWidth: SplitViewTuning.sidebarIdealWidth)
                if model.inspector != nil, panelWidth() > 0, sidebarItem.isCollapsed, panelWidth() <= room + 0.5 {
                    needlessHides += 1
                    note("\(label): sidebar hidden although the panel came back at \(Int(panelWidth())), within the \(Int(room)) pt beside it")
                }
            }
            if wanted("reopen") {
                // A panel dragged to 520 while the sidebar was hidden and then closed comes back in a 1220 pt window with
                // the sidebar shown, after the window went to 1440 and back with the panel closed (as between the
                // `toggle` cases). AppKit keeps wanting the 520 and can bring the column back at it whatever the
                // panel's maximum: 1406 pt needed beside the 232 pt sidebar, and AppKit aborted. Closing narrows such
                // a panel first (`AppModel.normalizePanelBeforeClose`), and an open that may still come back too wide
                // hides the sidebar (`AppModel.fitInspector`). Whenever the sidebar shows during the open the columns
                // must fit, sampled through the animation; the window keeps its width. Each step of the setup is
                // checked: the panel at 520, then closed, the sidebar back. The panel closes in turn by showing the
                // sidebar through the binding (the rule closes it), by AppKit's `toggleSidebar`, and by closing it first
                // and then showing the sidebar. Reopens that hide the sidebar although the panel fits are counted.
                let cycles = env["OPENMUSIC_RESIZE_REOPEN"].flatMap { Int($0) } ?? 4
                var closedBy = "nothing"
                for cycle in 0...cycles {
                    await reset()
                    setWidth(1220)
                    try? await Task.sleep(for: .milliseconds(500))
                    let label = "\(name) reopen \(cycle) at 1220 after closing at 520 by \(closedBy)"
                    if cycle > 0 { note("\(label): \(state())") }
                    model.toggleInspector(panel)
                    let peak = await sampleOpen(label)
                    if cycle > 0 {
                        check("\(label): opened (widest \(Int(peak)) beside the sidebar)", width: 1220, panel: true, sidebar: nil)
                        countHide(label)
                    }
                    guard cycle < cycles else { break }
                    guard await widenWithSidebarHidden("\(name) reopen \(cycle + 1)") else { continue }
                    closedBy = ["binding", "appkit", "closing first"][cycle % 3]
                    switch cycle % 3 {
                    case 0: model.columnVisibility = .all
                    case 1: SplitViewTuning.toggleSidebar(in: window)
                    default:
                        model.inspector = nil
                        try? await Task.sleep(for: .milliseconds(1000))
                        SplitViewTuning.toggleSidebar(in: window)
                    }
                    try? await Task.sleep(for: .milliseconds(1400))
                    if model.inspector != nil || SplitViewTuning.inspectorWidth(in: window) != nil || sidebarItem.isCollapsed
                        || model.columnVisibility == .detailOnly {
                        ok = false
                        note("\(name) reopen \(cycle + 1): setup: after closing by \(closedBy): \(state()), expected the panel closed and the sidebar shown FAIL")
                    }
                }
            }
            if wanted("rapid") {
                // The same panel, dragged to 520 with the sidebar hidden, closes and opens again before the close has
                // settled: 0, 50, 150 and 400 ms later, as itself and as the other panel (lyrics ↔ queue), closed by
                // showing the sidebar (the rule closes it and brings the sidebar back) or closed first and then the
                // sidebar shown through AppKit. The column may still be closing, or AppKit may not yet show what it
                // wants, so the open can't rely on the closed column's frame (`SplitViewTuning.panelRestoreBound`).
                // Every reopen must end open, and with the sidebar back where both fit.
                let other: InspectorPanel = panel == .lyrics ? .queue : .lyrics
                let delays = env["OPENMUSIC_RESIZE_RAPID_DELAYS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [0, 50, 150, 400]
                for delay in delays {
                    for switching in [false, true] {
                        for byRule in [true, false] {
                            let next = switching ? other : panel
                            let label = "\(name) rapid: closed \(byRule ? "by showing the sidebar" : "first"), \(next.rawValue) \(delay) ms later at 1220"
                            await reset()
                            setWidth(1220)
                            try? await Task.sleep(for: .milliseconds(500))
                            model.toggleInspector(panel)
                            try? await Task.sleep(for: .milliseconds(1400))
                            guard await widenWithSidebarHidden(label) else { continue }
                            if byRule {
                                model.columnVisibility = .all
                            } else {
                                model.toggleInspector(panel)
                                SplitViewTuning.toggleSidebar(in: window)
                            }
                            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                            if model.inspector != nil {
                                ok = false
                                note("\(label): setup: the panel didn't close: \(state()) FAIL")
                                continue
                            }
                            model.toggleInspector(next)
                            // A reopen that overlaps the close waits for it to settle (`AppModel.toggleInspector`,
                            // at most 1.5 s), then must stay open: SwiftUI's write-back of the close used to close it
                            // again about 230 ms after a reopen 50–150 ms after the close.
                            let peak = await sampleOpen(label, for: 1600)
                            var waited = 1600
                            while model.inspector == nil, waited < 2000 {
                                try? await Task.sleep(for: .milliseconds(50))
                                waited += 50
                            }
                            try? await Task.sleep(for: .milliseconds(1000))
                            let open = model.inspector == next && SplitViewTuning.inspectorWidth(in: window) != nil
                            if !open {
                                ok = false
                                note("\(label): the panel isn't open 1 s after the reopen went ahead: \(state()) FAIL")
                            }
                            check("\(label): opened (widest \(Int(peak)) beside the sidebar)", width: 1220, panel: true, sidebar: nil)
                            countHide(label)
                        }
                    }
                }
            }
            if reopens > 0 { note("\(name) reopens: the sidebar hid needlessly on \(needlessHides) of \(reopens)") }
            if wanted("widen") {
                // AppKit shows the sidebar beside a panel it doesn't fit beside (960 pt, panel 310): the panel closes.
                // A widening of the window right after it (a zoom, a tile, a script) is never undone by the width
                // correction, which puts back only a widening AppKit made itself (`WidthCorrection`), nor by SwiftUI:
                // at 150 ms it is still animating the window for the sidebar's return and sets it back to its own
                // width (960, then steps up toward 955), and the guard keeps the window at the widening and never
                // applies SwiftUI's frames when it ends (`ShrinkDeferral`). Both delays must end at 1300.
                for delay in [150, 350] {
                    await reset()
                    setWidth(960)
                    try? await Task.sleep(for: .milliseconds(500))
                    model.toggleInspector(panel)
                    try? await Task.sleep(for: .milliseconds(1400))
                    note("\(name) widen \(delay) ms after AppKit shows the sidebar at 960: \(state())")
                    let corrections = model.debugWidthCorrections
                    SplitViewTuning.toggleSidebar(in: window)
                    try? await Task.sleep(for: .milliseconds(delay))
                    setWidth(1300)
                    let immediate = abs(window.frame.width - 1300) <= 1
                    ok = ok && immediate
                    if !immediate { note("\(name) widen \(delay) ms: right after the widening the window is \(Int(window.frame.width)), expected 1300 FAIL") }
                    try? await Task.sleep(for: .milliseconds(1400))
                    let label = "\(name) widen \(delay) ms after AppKit shows the sidebar: done"
                    if model.debugWidthCorrections != corrections { ok = false; note("\(label): the width correction undid the widening FAIL") }
                    check(label, width: 1300, panel: false, sidebar: true)
                }
            }
            if wanted("fullscreen") {
                // In native full screen with the panel open and the sidebar hidden, showing the sidebar by ⌃⌘S, the
                // binding or AppKit settles: the sidebar shows, and the panel stays where both fit beside the page
                // (the window is as wide as the screen). Before, the binding's path and AppKit's restore reset each
                // other over and over.
                await reset()
                model.toggleInspector(panel)
                try? await Task.sleep(for: .milliseconds(1400))
                note("\(name) full screen: entering, \(state())")
                window.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(3))
                let full = window.frame.width
                if !window.styleMask.contains(.fullScreen) { ok = false; note("\(name) full screen: did not enter full screen FAIL") }
                for path in ["menu", "binding", "appkit"] {
                    if model.inspector != panel { model.inspector = panel; try? await Task.sleep(for: .milliseconds(1400)) }
                    if model.columnVisibility != .detailOnly { model.columnVisibility = .detailOnly; try? await Task.sleep(for: .milliseconds(1000)) }
                    let label = "\(name) full screen, show sidebar with the \(path)"
                    note("\(label): \(state())")
                    let kept = Self.keepsPanel(window: full, panel: panelWidth())
                    let decisions = model.debugSidebarDecisions
                    switch path {
                    case "menu":
                        await bringToFront(label)
                        guard let (menu, index) = Self.sidebarMenuItem() else { ok = false; note("\(label): no ⌃⌘S item FAIL"); continue }
                        Self.click(menu, index)
                    case "appkit": SplitViewTuning.toggleSidebar(in: window)
                    default: model.columnVisibility = .all
                    }
                    try? await Task.sleep(for: .milliseconds(1400))
                    let settled = model.debugSidebarDecisions
                    try? await Task.sleep(for: .milliseconds(500))
                    let spinning = model.debugSidebarDecisions != settled || settled - decisions > 6
                    ok = ok && !spinning
                    if spinning { note("\(label): the sidebar rule ran \(model.debugSidebarDecisions - decisions) times and kept running FAIL") }
                    check("\(label): done", width: full, panel: kept, sidebar: true)
                }
                window.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(3))
                check("\(name) full screen: left", width: window.frame.width, panel: model.inspector != nil, sidebar: nil)
            }
            if wanted("wide") {
                // The widest columns: the sidebar's and then the panel's divider dragged to their maximums (300, 520).
                for jump in [false, true] {
                    await open(panel)
                    if let sidebar = sidebarController.splitView.arrangedSubviews.first {
                        note("\(name) wide: dragging the sidebar's edge to 300, \(state())")
                        dragDivider(in: window, at: sidebar.convert(sidebar.bounds, to: nil).maxX + 0.5, by: 300 - sidebarWidth())
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                    if let split = SplitViewTuning.inspectorSplitView(in: root), let column = split.arrangedSubviews.last {
                        note("\(name) wide: dragging the panel's edge to 520, \(state())")
                        dragDivider(in: window, at: column.convert(column.bounds, to: nil).minX - split.dividerThickness / 2,
                                    by: -(InspectorMetrics.maxWidth - panelWidth()))
                        try? await Task.sleep(for: .milliseconds(800))
                    }
                    check("\(name) wide: dragged", width: 1440, panel: true, sidebar: true)
                    if jump {
                        note("\(name) wide: jump to \(Int(Self.minimum))")
                        setWidth(Self.minimum)
                        try? await Task.sleep(for: .milliseconds(700))
                        check("\(name) wide: jump to \(Int(Self.minimum)) done", width: Self.minimum, panel: true, sidebar: sidebarBeside(Self.minimum))
                    } else {
                        await shrinkInSteps("\(name) wide steps", to: Self.minimum, panel: true)
                    }
                }
            }
        }
        if wanted("menu") {
            // View › Show/Hide Sidebar is enabled only with the main window open and in front, as `SidebarCommands`'
            // item was; with the window closed it does nothing.
            await reset()
            func itemEnabled() -> Bool? {
                guard let (menu, index) = Self.sidebarMenuItem() else { return nil }
                // SwiftUI refreshes its items when the menu is about to open.
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                return menu.items[index].isEnabled
            }
            await bringToFront("menu")
            let front = itemEnabled()
            // The shortcut hides the sidebar and shows it again.
            Self.pressSidebarShortcut(in: window)
            try? await Task.sleep(for: .milliseconds(1000))
            let hid = model.columnVisibility == .detailOnly && sidebarItem.isCollapsed
            Self.pressSidebarShortcut(in: window)
            try? await Task.sleep(for: .milliseconds(1000))
            let showed = model.columnVisibility != .detailOnly && !sidebarItem.isCollapsed
            window.orderOut(nil)
            try? await Task.sleep(for: .milliseconds(800))
            let closed = itemEnabled()
            Self.pressSidebarShortcut(in: window)
            if let (menu, index) = Self.sidebarMenuItem() { Self.click(menu, index) }
            try? await Task.sleep(for: .milliseconds(800))
            let unchanged = model.columnVisibility == .all && !sidebarItem.isCollapsed
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(800))
            let back = itemEnabled()
            let good = front == true && hid && showed && closed == false && unchanged && back == true
            ok = ok && good
            note("menu: ⌃⌘S enabled with the window in front \(front.map(String.init) ?? "missing") (shortcut hid \(hid), showed \(showed)), "
                 + "with it closed \(closed.map(String.init) ?? "missing") (sidebar \(unchanged ? "unchanged" : "toggled")), back \(back.map(String.init) ?? "missing")\(good ? "" : " FAIL")")
        }
        await reset()
        check("back at 1440", width: 1440, panel: false, sidebar: true)
        if wanted("relaunch") {
            // Saves a narrow frame with the sidebar dragged to 300 and lyrics open, then asks the runner to launch the
            // app again (`OPENMUSIC_SELFTEST_RELAUNCHED`, `relaunched()`).
            setSidebarWidth(300)
            try? await Task.sleep(for: .milliseconds(500))
            model.toggleInspector(.lyrics)
            try? await Task.sleep(for: .milliseconds(1600))
            setWidth(Self.minimum)
            try? await Task.sleep(for: .milliseconds(800))
            note("relaunch: quitting at \(state()), sidebar dragged to 300 before")
            note("\(Self.relaunchLine) ok=\(ok)")
            NSApp.terminate(nil)
            return
        }
        note("resize with the sidebar and a panel open: \(ok ? "PASS" : "FAIL")")
        NSApp.terminate(nil)
    }

    /// The last line asking `scripts/mac-selftest.sh` to launch the app again, with `OPENMUSIC_SELFTEST_RELAUNCHED=1`.
    static let relaunchLine = "RELAUNCH"

    /// The second launch of the `relaunch` case: the window comes back at the narrow frame the first launch saved,
    /// with the sidebar's saved width, and lyrics open right away, before the window is watched. Nothing may abort,
    /// and once settled the columns must fit with the sidebar hidden beside the panel, as at that width before.
    func relaunched() async {
        var log = ((try? String(contentsOf: output, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var ok = log.last?.hasSuffix("ok=true") == true
        if log.last?.hasPrefix(Self.relaunchLine) == true { log.removeLast() }
        func note(_ line: String) {
            log.append(line)
            try? log.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        if !ok { note("relaunch: the first launch had failed checks FAIL") }
        let env = LaunchEnvironment.current
        if env["OPENMUSIC_RESIZE_TRACE"] != nil {
            SplitViewTuning.debugLog = { note("  trace: \($0)") }
            model.debugSidebarTrace = { note("  trace: \($0)") }
            SidebarAnimationGuard.debugLog = { note("  trace: \($0)") }
        }
        note("relaunched: window \(model.mainWindow.map { String(Int($0.frame.width)) } ?? "not yet"), binding \(model.columnVisibility == .detailOnly ? "hidden" : "shown")")
        if env["OPENMUSIC_RESIZE_RELAUNCH_PANEL"] != "0" { model.inspector = .lyrics }
        while model.mainWindow == nil { try? await Task.sleep(for: .milliseconds(20)) }
        guard let window = model.mainWindow, let root = window.contentView,
              let (sidebarController, sidebarItem) = SplitViewTuning.sidebarItem(in: root)
        else { return note("relaunch: no window FAIL") }
        func sidebarWidth() -> CGFloat {
            sidebarItem.isCollapsed ? 0 : sidebarController.splitView.arrangedSubviews.first?.frame.width ?? 0
        }
        func state() -> String {
            "window \(Int(window.frame.width)), sidebar \(sidebarItem.isCollapsed ? "hidden" : String(Int(sidebarWidth()))), "
                + "panel \(SplitViewTuning.inspectorWidth(in: window).map { String(Int($0)) } ?? "closed"), binding \(model.columnVisibility == .detailOnly ? "hidden" : "shown")"
        }
        note("relaunched, lyrics \(model.inspector == nil ? "closed" : "opening"): \(state())")
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if env["OPENMUSIC_RESIZE_TRACE"] != nil { note("  trace: \(state())") }
        }
        let width = window.frame.width
        let overflow = (SplitViewTuning.inspectorSplitView(in: root).map { $0.convert($0.bounds, to: root).maxX } ?? 0) - root.bounds.maxX
        let panel = SplitViewTuning.inspectorWidth(in: window) ?? 0
        let page = root.bounds.width - sidebarWidth() - panel
        var problems: [String] = []
        if abs(width - Self.minimum) > 1 { problems.append("window \(Int(width)), expected the saved \(Int(Self.minimum))") }
        if overflow > 1 { problems.append("split view \(Int(overflow)) pt past the window's edge") }
        if page < 420 - 3 { problems.append("page \(Int(page)), under 420") }
        let withPanel = env["OPENMUSIC_RESIZE_RELAUNCH_PANEL"] != "0"
        if withPanel, model.inspector != .lyrics || panel == 0 { problems.append("lyrics not open") }
        if (model.columnVisibility != .detailOnly) == sidebarItem.isCollapsed { problems.append("sidebar binding and column disagree") }
        if withPanel, !sidebarItem.isCollapsed, width < Self.bothWidth { problems.append("sidebar shown beside the panel at \(Int(width))") }
        ok = ok && problems.isEmpty
        note("relaunched, settled: \(state())\(problems.map { ", \($0) FAIL" }.joined())")
        // Leave the saved state as the other runs expect it: 1440 wide, sidebar at 232, no panel.
        model.inspector = nil
        try? await Task.sleep(for: .seconds(1))
        window.requestFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        try? await Task.sleep(for: .milliseconds(500))
        if model.columnVisibility != .all { model.columnVisibility = .all; try? await Task.sleep(for: .seconds(1)) }
        if !sidebarItem.isCollapsed { sidebarController.splitView.setPosition(232, ofDividerAt: 0) }
        try? await Task.sleep(for: .milliseconds(300))
        note("resize with the sidebar and a panel open: \(ok ? "PASS" : "FAIL")")
        NSApp.terminate(nil)
    }

    /// The View menu's Show/Hide Sidebar item (⌃⌘S, from `SidebarCommands`) and its menu.
    static func sidebarMenuItem() -> (NSMenu, Int)? {
        func search(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.keyEquivalent.lowercased() == "s", item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.control, .command] {
                    return (menu, index)
                }
                if let sub = item.submenu, let found = search(sub) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// Chooses a menu item the way a click does: SwiftUI brings its items up to date as the menu opens.
    static func click(_ menu: NSMenu, _ index: Int) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        menu.performActionForItem(at: index)
    }

    /// Presses ⌃⌘S in the main menu, as the keyboard does.
    static func pressSidebarShortcut(in window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: "\u{13}", charactersIgnoringModifiers: "s",
                                           isARepeat: false, keyCode: 1) else { return }
        _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    }

    /// The toolbar's Show/Hide Sidebar button (SwiftUI's own, for `NavigationSplitView`).
    static func sidebarToolbarButton(in window: NSWindow) -> NSView? {
        window.toolbar?.items.first { $0.itemIdentifier.rawValue.hasSuffix("navigationSplitView.toggleSidebar") }?.view
    }

    /// Drags a split view divider at `x` (window coordinates) by `dx`, the way a pointer does (see `dragCorner`).
    private func dragDivider(in window: NSWindow, at x: CGFloat, by dx: CGFloat) {
        let start = NSPoint(x: x, y: window.frame.height / 2)
        post(in: window, from: start, by: dx)
    }

    /// Drags the window's bottom-right corner by `dx` the way a pointer does: the drag and mouse-up are queued,
    /// then the mouse-down is delivered, and the window's resize tracking loop reads the queued events (it is in a
    /// live resize throughout).
    private func dragCorner(of window: NSWindow, by dx: CGFloat) {
        post(in: window, from: NSPoint(x: window.frame.width - 2, y: 2), by: dx)
    }

    private func post(in window: NSWindow, from start: NSPoint, by dx: CGFloat) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        let steps = 24
        for i in 1...steps {
            if let e = event(.leftMouseDragged, NSPoint(x: start.x + dx * CGFloat(i) / CGFloat(steps), y: start.y)) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        if let up = event(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y)) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, start) { window.sendEvent(down) }
    }
}
#endif

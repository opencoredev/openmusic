import AppKit
import MedleyCore
import SwiftUI

// Debug builds only: Release builds have no self-test entry points.
#if DEBUG
/// `MEDLEY_MOCK=1 MEDLEY_SELFTEST=layout MEDLEY_SELFTEST_OUT=<file>`: runs the app normally and measures
/// layout that screenshots only show by eye. For every page type, at 1440×900 and 960×620, with and without
/// the queue open, it scrolls each vertical scroll view to its end and checks that the end of a page's content
/// sits above the floating player's top edge (the sidebar and inspector run to the window's bottom), and that
/// the player sits inside the page's pane. Writes one line per check, then quits.
@MainActor
struct LayoutSelfTest {
    let model: AppModel
    let output: URL

    func run() async {
        var log: [String] = []
        func note(_ line: String) {
            log.append(line)
            try? log.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
        }
        while model.mainWindow == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let window = model.mainWindow,
              let yt = model.provider(.youtubeMusic) as? MockProvider
        else { return note("setup: FAIL") }
        try? await Task.sleep(for: .seconds(1))

        let album = yt.catalog.albums[0]
        let artist = yt.catalog.artists[0]
        let playlist = yt.catalog.playlists.max(by: { ($0.trackCount ?? 0) < ($1.trackCount ?? 0) }) ?? yt.catalog.playlists[0]
        let shelf = (try? await yt.home())?.first { !$0.items.isEmpty }
        if let detail = try? await yt.album(id: album.providerID) {
            model.play(detail.tracks, startAt: 0, from: .init(title: album.title))
        }

        let pages: [(String, @MainActor (AppModel) async -> Void)] = [
            ("home", { $0.select(.home) }),
            ("new", { $0.select(.explore) }),
            ("album", { m in m.select(.home); try? await Task.sleep(for: .milliseconds(200)); m.path = [.album(.youtubeMusic, id: album.providerID, preview: album)] }),
            ("artist", { m in m.select(.home); try? await Task.sleep(for: .milliseconds(200)); m.path = [.artist(.youtubeMusic, id: artist.providerID, preview: artist)] }),
            ("playlist", { m in m.select(.home); try? await Task.sleep(for: .milliseconds(200)); m.path = [.playlist(.youtubeMusic, id: playlist.providerID, preview: playlist)] }),
            ("search", { m in m.select(.search); m.searchText = "night" }),
            ("songs", { m in m.searchText = ""; m.select(.songs) }),
            ("see-all", { m in
                m.select(.home)
                try? await Task.sleep(for: .milliseconds(200))
                if let shelf { m.path = [.shelf(.youtubeMusic, shelf)] }
            }),
        ]

        var allOK = true
        var widthOK = true
        for (w, h) in [(1440, 900), (960, 620), (900, 620)] {
            for panel in [InspectorPanel?.none, .queue] where !(w == 900 && panel == nil) {
                model.inspector = nil
                try? await Task.sleep(for: .milliseconds(500))
                window.requestFrame(NSRect(x: 60, y: 60, width: w, height: h), display: true)
                try? await Task.sleep(for: .milliseconds(600))
                model.inspector = panel
                try? await Task.sleep(for: .milliseconds(800))
                for (name, go) in pages {
                    await go(model)
                    try? await Task.sleep(for: .seconds(1.2))
                    // The floating player's top edge, in points above the window's bottom; page content must end
                    // at least `FloatingPlayer.gap` above it. Without a probe, the capsule's designed height.
                    let capsuleTop = DebugProbes.windowFrame("player-capsule").map { (window.contentView?.bounds.height ?? 0) - $0.minY }
                        ?? FloatingPlayer.height + FloatingPlayer.inset
                    func required(_ label: String) -> CGFloat {
                        // The sidebar and inspector run full height; only the page sits under the player.
                        label == "page" ? capsuleTop + FloatingPlayer.gap : 0
                    }
                    // Lazy lists grow as they scroll: scroll to the end until the document stops growing.
                    var results = Self.scrollEnds(in: window)
                    for _ in 0..<8 where results.contains(where: { $0.endAboveWindowBottom < required($0.label) - 0.5 }) {
                        try? await Task.sleep(for: .milliseconds(300))
                        results = Self.scrollEnds(in: window)
                    }
                    for r in results {
                        let ok = r.endAboveWindowBottom >= required(r.label) - 0.5
                        allOK = allOK && ok
                        note(String(format: "%@ %dx%d %@ %@: content ends %.0f pt above the window bottom (needs %.0f; player top %.0f), frame %@, insets %.0f: %@",
                                    name, w, h, panel.map { $0.rawValue } ?? "no-panel", r.label, r.endAboveWindowBottom, required(r.label), capsuleTop,
                                    NSStringFromRect(r.frame), r.insetBottom, ok ? "PASS" : "FAIL"))
                    }
                    if results.isEmpty { note("\(name) \(w)x\(h): no vertical scroll view found: NOT CHECKED") }
                    // Nothing on the page reaches past its pane (the queue open at 960 once clipped the playlist on
                    // both sides): the page content, the hero's action row, the Find field and the duration column.
                    if let page = results.first(where: { $0.label == "page" })?.frame {
                        // The page's scroll view reaches under the floating sidebar and the panel; its visible
                        // pane ends at the sidebar's trailing edge and the panel's leading edge.
                        // Within the window: an overflowing page once pushed its own scroll view past the edge.
                        var pane = page.intersection(NSRect(origin: .zero, size: window.frame.size))
                        if model.columnVisibility != .detailOnly, let sidebar = Self.sidebarFrame(in: window), sidebar.maxX > pane.minX {
                            pane = NSRect(x: sidebar.maxX, y: pane.minY, width: pane.maxX - sidebar.maxX, height: pane.height)
                        }
                        if model.inspector != nil, let panel = SplitViewTuning.inspectorSplitView(in: window.contentView)?.arrangedSubviews.last,
                           !panel.isHidden {
                            let edge = panel.convert(panel.bounds, to: nil).minX
                            if edge < pane.maxX { pane.size.width = edge - pane.minX }
                        }
                        var parts: [String] = []
                        var ok = true
                        for key in Self.widthProbes {
                            guard let probe = DebugProbes.views.object(forKey: key as NSString), probe.window === window,
                                  !probe.isHiddenOrHasHiddenAncestor, let f = DebugProbes.windowFrame(key), f.width > 0 else { continue }
                            let inside = f.minX >= pane.minX - 1 && f.maxX <= pane.maxX + 1
                            ok = ok && inside
                            parts.append(String(format: "%@ x %.0f–%.0f%@", key, f.minX, f.maxX, inside ? "" : " (OUTSIDE)"))
                        }
                        widthOK = widthOK && ok
                        note(String(format: "%@ %dx%d %@ width: pane x %.0f–%.0f; %@: %@", name, w, h, panel.map { $0.rawValue } ?? "no-panel",
                                    pane.minX, pane.maxX, parts.isEmpty ? "no probes" : parts.joined(separator: ", "), ok ? "PASS" : "FAIL"))
                    }
                }
            }
        }
        model.inspector = nil
        note("bottom inset, every page: \(allOK ? "PASS" : "FAIL")")
        note("no content wider than its pane, every page, with and without the queue: \(widthOK ? "PASS" : "FAIL")")
        await checkFind(window: window, playlist: playlist)
        NSApp.terminate(nil)
    }

    /// ⌘F on a long playlist focuses its "Find in playlist" field; typing narrows the rows; ⌘F again goes to
    /// the sidebar search. On a page without the field, ⌘F goes straight to the sidebar search.
    private func checkFind(window: NSWindow, playlist: Playlist) async {
        func note(_ line: String) {
            let old = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            try? (old + line + "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        func focusKind() -> String {
            guard let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField else { return "none" }
            return field is NSSearchField ? "sidebar search" : "page field"
        }
        window.requestFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        model.select(.home)
        try? await Task.sleep(for: .milliseconds(300))
        model.path = [.playlist(.youtubeMusic, id: playlist.providerID, preview: playlist)]
        try? await Task.sleep(for: .seconds(1.5))
        window.makeFirstResponder(nil)
        let before = Self.pageDocumentHeight(in: window)
        performMenuItem("Search")
        try? await Task.sleep(for: .milliseconds(600))
        let first = focusKind()
        note("⌘F on \"\(playlist.title)\" (\(playlist.trackCount ?? 0) songs) focuses: \(first): \(first == "page field" ? "PASS" : "FAIL")")
        // Type the first word of a song's title deep in the list.
        let tracks = (try? await model.provider(.youtubeMusic)?.playlist(id: playlist.providerID).tracks) ?? []
        let word = tracks.last.map { String($0.title.split(separator: " ").first ?? "") } ?? "a"
        for ch in word {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                            charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) {
                    window.sendEvent(e)
                }
            }
        }
        try? await Task.sleep(for: .seconds(2))
        let after = Self.pageDocumentHeight(in: window)
        note(String(format: "typing \"%@\" narrows the list: page height %.0f → %.0f pt: %@", word, before, after, after < before - 200 ? "PASS" : "FAIL"))
        performMenuItem("Search")
        try? await Task.sleep(for: .milliseconds(600))
        let second = focusKind()
        note("⌘F again focuses: \(second): \(second == "sidebar search" ? "PASS" : "FAIL")")
        model.searchText = ""
        model.select(.home)
        try? await Task.sleep(for: .seconds(1))
        window.makeFirstResponder(nil)
        performMenuItem("Search")
        try? await Task.sleep(for: .milliseconds(600))
        let home = focusKind()
        note("⌘F on Home focuses: \(home): \(home == "sidebar search" ? "PASS" : "FAIL")")
    }

    private static func pageDocumentHeight(in window: NSWindow) -> CGFloat {
        guard let root = window.contentView else { return 0 }
        func find(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(find) }
        return find(root)
            .filter { $0.convert($0.bounds, to: nil).width > 400 && $0.verticalScroller != nil }
            .compactMap { $0.documentView?.frame.height }
            .max() ?? 0
    }

    private func performMenuItem(_ title: String) {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (i, item) in menu.items.enumerated() {
                if item.title == title, item.submenu == nil { return (menu, i) }
                if let sub = item.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        if let main = NSApp.mainMenu, let (menu, index) = find(main) {
            menu.update()
            menu.performActionForItem(at: index)
        }
    }

    /// The sidebar's list, in window coordinates.
    static func sidebarFrame(in window: NSWindow) -> NSRect? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        return allScrollViews(in: root).map { $0.convert($0.bounds, to: nil) }
            .first { $0.minX < 20 && $0.width > 150 && $0.width < 400 }
    }

    /// `LayoutProbe` keys checked against the page's pane.
    static let widthProbes = ["page-content", "hero-actions", "find-field", "row-trailing", "search-header", "player-capsule"]

    struct ScrollEnd {
        let label: String
        let frame: NSRect
        let insetBottom: CGFloat
        let endAboveWindowBottom: CGFloat
    }

    /// Scrolls every vertical, scrollable scroll view to its end and reports where its document ends,
    /// in points above the window's bottom edge.
    static func scrollEnds(in window: NSWindow) -> [ScrollEnd] {
        guard let root = window.contentView?.superview ?? window.contentView else { return [] }
        var out: [ScrollEnd] = []
        for sv in allScrollViews(in: root) {
            guard let doc = sv.documentView, !sv.isHidden, sv.window != nil else { continue }
            let frame = sv.convert(sv.bounds, to: nil)
            guard frame.width > 200, frame.height > 150, doc.frame.height > sv.contentView.bounds.height + 1 else { continue }
            let clip = sv.contentView
            var bounds = clip.bounds
            bounds.origin.y = doc.isFlipped ? 1e7 : -1e7
            clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
            sv.reflectScrolledClipView(clip)
            doc.layoutSubtreeIfNeeded()
            let end = doc.convert(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.maxY : doc.bounds.minY), to: nil).y
            let label = frame.minX < 10 && frame.width < 400 ? "sidebar" : frame.maxX >= (window.contentView?.bounds.width ?? 0) - 2 && frame.width < 500 && frame.minX > 300 ? "inspector" : "page"
            out.append(ScrollEnd(label: label, frame: frame, insetBottom: sv.contentInsets.bottom, endAboveWindowBottom: end))
        }
        return out
    }

    private static func allScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let sv = view as? NSScrollView { found.append(sv) }
        for sub in view.subviews { found += allScrollViews(in: sub) }
        return found
    }
}
#endif

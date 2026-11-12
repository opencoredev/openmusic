import AppKit

/// Adjusts the `NSSplitViewController` behind the main window's `NavigationSplitView`, for behavior SwiftUI
/// doesn't expose.
@MainActor
enum SplitViewTuning {
    /// The page's minimum width (`DetailStack`'s frame).
    nonisolated static let pageMinWidth: CGFloat = 420
    /// The sidebar column's width limits (`Sidebar`).
    nonisolated static let sidebarMinWidth: CGFloat = 190
    nonisolated static let sidebarIdealWidth: CGFloat = 232
    nonisolated static let sidebarMaxWidth: CGFloat = 300

    /// How many times the window's width has to hold the sidebar's (see `neededWidth`): twice on macOS 26 and
    /// later, once before.
    nonisolated static let sidebarShare: CGFloat = {
        if #available(macOS 26.0, *) { 2 } else { 1 }
    }()

    /// The window width the sidebar, the page and the lyrics/queue panel need at these widths (0 for a hidden one).
    ///
    /// On macOS 26 and later the page's column runs under the sidebar and the panel, which reach it as safe-area
    /// insets, and SwiftUI measures the column's minimum inside them: the page's 420 plus the sidebar plus the
    /// panel. SwiftUI's sidebar column counts the sidebar once more, because the detail column also runs under it.
    /// So the window needs 420 + 2 × sidebar + panel: 1281 pt for sidebar 220 and lyrics 421, measured with
    /// `OPENMUSIC_SELFTEST=resize`. AppKit takes those minimums as constants from the current widths and can't narrow
    /// a column to meet them. When the window is narrower, the panel's split view gets one width from SwiftUI and
    /// another from its constraints on every layout pass, and AppKit aborts with "more Update Constraints in Window
    /// passes than there are views in the window". Without a panel the split view runs past the window's edge.
    /// Before macOS 26 the columns sit side by side, and the window needs 420 + sidebar + panel (`sidebarShare`).
    nonisolated static func neededWidth(sidebar: CGFloat, panel: CGFloat, sidebarShare: CGFloat = sidebarShare) -> CGFloat {
        pageMinWidth + sidebarShare * sidebar + panel + 2
    }

    /// How wide the panel can be in a window this wide, beside a sidebar this wide (0 when hidden).
    nonisolated static func panelRoom(windowWidth: CGFloat, sidebarWidth: CGFloat, sidebarShare: CGFloat = sidebarShare) -> CGFloat {
        windowWidth - neededWidth(sidebar: sidebarWidth, panel: 0, sidebarShare: sidebarShare)
    }

    /// How wide the sidebar can be in a window this wide, beside a panel this wide (0 when closed).
    nonisolated static func sidebarRoom(windowWidth: CGFloat, panelWidth: CGFloat, sidebarShare: CGFloat = sidebarShare) -> CGFloat {
        ((windowWidth - neededWidth(sidebar: 0, panel: panelWidth, sidebarShare: sidebarShare)) / sidebarShare).rounded(.down)
    }

    /// Whether the sidebar can be shown beside an open panel this wide (counted as at least its ideal width) in a
    /// window this wide: 1196 pt at the panel's ideal width on macOS 26 and later, 964 before (the sidebar's ideal is 232). It takes the sidebar's
    /// ideal width, not its minimum: SwiftUI brings a shown sidebar back at its ideal width and the panel at its
    /// own, and with less room the two columns' caps chased each other (sidebar 220 / panel 288, then 209 / 310)
    /// and left the split view past the window's edge. Below it the one asked for last wins
    /// (`AppModel.showSidebarBesidePanel`).
    nonisolated static func sidebarFitsBesidePanel(windowWidth: CGFloat, panelWidth: CGFloat = InspectorMetrics.idealWidth,
                                                   sidebarShare: CGFloat = sidebarShare) -> Bool {
        let panel = max(panelWidth, InspectorMetrics.idealWidth)
        return neededWidth(sidebar: sidebarIdealWidth, panel: panel, sidebarShare: sidebarShare) <= windowWidth + 0.5
    }

    /// The sidebar's width, or 0 when it's collapsed.
    static func sidebarWidth(in window: NSWindow?) -> CGFloat {
        guard let root = window?.contentView else { return 0 }
        return Columns(root).sidebarWidth
    }

    /// The sidebar's and the panel's split view items, found in one walk of the window (this runs on every step of a
    /// live resize).
    private struct Columns {
        var sidebar: (controller: NSSplitViewController, item: NSSplitViewItem)?
        var panel: (controller: NSSplitViewController, item: NSSplitViewItem)?

        @MainActor init(_ root: NSView) {
            for controller in splitViewControllers(in: root) {
                for item in controller.splitViewItems {
                    if item.behavior == .sidebar { sidebar = (controller, item) }
                    if item.behavior == .inspector { panel = (controller, item) }
                }
            }
        }

        @MainActor var sidebarWidth: CGFloat {
            guard let sidebar, !sidebar.item.isCollapsed else { return 0 }
            return sidebar.controller.splitView.arrangedSubviews.first?.frame.width ?? 0
        }

        @MainActor var panelWidth: CGFloat {
            guard let panel, !panel.item.isCollapsed, let view = panel.controller.splitView.arrangedSubviews.last, !view.isHidden else { return 0 }
            return view.frame.width
        }
    }

    /// Narrows the panel, then the sidebar, toward their minimums until the columns fit the window
    /// (`neededWidth`). Returns false when they still don't, and the sidebar has to hide. The panel counts as at least
    /// `panelFloor` wide and doesn't narrow below it: a panel that is opening is still narrow, and settles at its
    /// ideal width when the animation ends. Call outside layout, before AppKit lays out the window's new size.
    static func narrowColumnsToFit(_ window: NSWindow?, panelFloor: CGFloat) -> Bool {
        guard let window, let root = window.contentView else { return true }
        let width = root.bounds.width
        let columns = Columns(root)
        var sidebar = columns.sidebarWidth
        var panel = max(columns.panelWidth, panelFloor)
        guard neededWidth(sidebar: sidebar, panel: panel) > width else { return true }
        if panel > 0 {
            let fitted = max(InspectorMetrics.minWidth, panelFloor, panelRoom(windowWidth: width, sidebarWidth: sidebar))
            if fitted < panel - 1 { setInspectorWidth(fitted, in: window); panel = fitted }
        }
        if sidebar > 0, neededWidth(sidebar: sidebar, panel: panel) > width, let controller = columns.sidebar?.controller {
            let fitted = max(sidebarMinWidth, sidebarRoom(windowWidth: width, panelWidth: panel))
            if fitted < sidebar - 1 { controller.splitView.setPosition(fitted, ofDividerAt: 0); sidebar = fitted }
        }
        return neededWidth(sidebar: sidebar, panel: panel) <= width + 1
    }

    /// Caps how wide a divider drag can make the sidebar and the panel, given the other's current width and the
    /// window's, so a drag can't make the columns need more than the window has. The caps stay inside the
    /// columns' own limits (`Sidebar`, `InspectorMetrics`). Call outside layout.
    static func limitColumnWidths(in window: NSWindow?) {
        guard let root = window?.contentView else { return }
        let width = root.bounds.width
        let columns = Columns(root)
        func cap(_ item: NSSplitViewItem, _ value: CGFloat, _ low: CGFloat, _ high: CGFloat) {
            let capped = min(high, max(low, value.rounded(.down)))
            if abs(item.maximumThickness - capped) > 0.5 { item.maximumThickness = capped }
        }
        if let item = columns.sidebar?.item {
            cap(item, sidebarRoom(windowWidth: width, panelWidth: columns.panelWidth), sidebarMinWidth, sidebarMaxWidth)
            #if DEBUG
            debugLog?("limit width \(width) panel \(columns.panelWidth) sidebar \(columns.sidebarWidth) sidebarMax \(item.maximumThickness)")
            #endif
        }
        // Only an open panel: the cap follows the sidebar's width, which changes on every frame of its animation.
        if let item = columns.panel?.item, !item.isCollapsed {
            cap(item, panelRoom(windowWidth: width, sidebarWidth: columns.sidebarWidth), InspectorMetrics.minWidth, InspectorMetrics.maxWidth)
        }
    }

    #if DEBUG
    /// `OPENMUSIC_RESIZE_TRACE` (`ResizeSelfTest`).
    static var debugLog: ((String) -> Void)?
    #endif

    /// Before the sidebar shows beside an open panel (`sidebarFitsBesidePanel`): caps the sidebar at the room the
    /// panel leaves, so it comes in no wider. The panel keeps its width. Call outside layout.
    static func capSidebarBesidePanel(in window: NSWindow?) {
        guard let root = window?.contentView else { return }
        let width = root.bounds.width
        let columns = Columns(root)
        guard let item = columns.sidebar?.item, columns.panelWidth > 0 else { return }
        let capped = min(sidebarMaxWidth, max(sidebarMinWidth, sidebarRoom(windowWidth: width, panelWidth: columns.panelWidth)))
        if abs(item.maximumThickness - capped) > 0.5 { item.maximumThickness = capped }
        #if DEBUG
        debugLog?("cap sidebar at \(capped) beside panel \(columns.panelWidth) in \(width)")
        #endif
    }

    /// The lyrics/queue panel column the restore bound belongs to, and the bound: the widest the column has been
    /// since it was made or last narrowed to its ideal (`normalizePanel`), never less than the ideal.
    ///
    /// AppKit keeps a panel's last width (a 520 pt drag made while the sidebar was hidden) as the width it wants
    /// after the panel closes, and can bring the column back at it whatever maximum the next open sets; a panel held
    /// under its maximum springs back to it once the cap lifts. Beside the 232 pt sidebar in a 1220 pt window
    /// (1406 pt needed) AppKit aborted in its Update Constraints pass. The closed column's frame isn't a bound on
    /// that width: after a 520 pt queue closed it read 310, then 520 40 ms later, and it isn't collapsed yet while the
    /// panel is still closing. So every width the column shows, open or closed, raises the bound
    /// (`notePanelWidth`), and only a divider move that measurably took lowers it.
    private static weak var boundPanelItem: NSSplitViewItem?
    private static var panelBound = InspectorMetrics.idealWidth

    /// The width the lyrics/queue panel can come back at when it opens now: at least its ideal (see `panelBound`).
    static func panelRestoreBound(in window: NSWindow?) -> CGFloat {
        guard let root = window?.contentView, let panel = Columns(root).panel,
              let view = panel.controller.splitView.arrangedSubviews.last else { return InspectorMetrics.idealWidth }
        notePanelWidth(item: panel.item, width: view.frame.width)
        return panelBound
    }

    /// After the panel's split view resized its columns (posted from inside layout; this only reads and records).
    static func notePanelWidth(in split: NSSplitView) {
        guard let controller = split.delegate as? NSSplitViewController,
              let item = controller.splitViewItems.last, item.behavior == .inspector,
              let view = split.arrangedSubviews.last else { return }
        notePanelWidth(item: item, width: view.frame.width)
    }

    private static func notePanelWidth(item: NSSplitViewItem, width: CGFloat) {
        if boundPanelItem !== item {
            // A new column: nothing is known of what it wants beyond what it shows.
            boundPanelItem = item
            panelBound = InspectorMetrics.idealWidth
        }
        panelBound = max(panelBound, min(width, InspectorMetrics.maxWidth))
    }

    /// Moves the open panel's divider to `width` and, once the panel measures that wide, lowers the restore bound to
    /// it: dragging the divider is what sets the width AppKit brings the column back at. Returns whether it took.
    /// Call outside layout, while the panel is open.
    @discardableResult
    static func normalizePanel(to width: CGFloat, in window: NSWindow?) -> Bool {
        guard let root = window?.contentView, let panel = Columns(root).panel, !panel.item.isCollapsed,
              let view = panel.controller.splitView.arrangedSubviews.last, !view.isHidden else { return false }
        notePanelWidth(item: panel.item, width: view.frame.width)
        setInspectorWidth(width, in: window)
        let took = abs(view.frame.width - width) <= 1
        #if DEBUG
        debugLog?("panel normalized to \(width): \(took ? "took" : "kept \(view.frame.width)"), bound \(took ? width : panelBound)")
        #endif
        if took, boundPanelItem === panel.item { panelBound = max(InspectorMetrics.idealWidth, width) }
        return took
    }

    /// Closes the lyrics/queue panel's column at once, without animation, so the next layout pass no longer has it.
    /// SwiftUI's inspector binding follows; set it too.
    static func collapsePanel(in window: NSWindow?) {
        guard let root = window?.contentView, let item = Columns(root).panel?.item, !item.isCollapsed else { return }
        item.isCollapsed = true
    }

    /// Collapses the sidebar at once, without animation, so the next layout pass no longer has it. SwiftUI's
    /// `columnVisibility` follows; set it too.
    static func collapseSidebar(in window: NSWindow?) {
        guard let root = window?.contentView, let item = Columns(root).sidebar?.item, !item.isCollapsed else { return }
        item.isCollapsed = true
    }

    /// Showing the sidebar takes its width from the page instead of growing the window.
    ///
    /// AppKit's default for a sidebar item is `.preferResizingSplitViewWithFixedSiblings`: showing it keeps the
    /// page's width and widens the window by the sidebar's width. Closing the queue in a 960 pt window brings
    /// the sidebar back, so the window grew to 1181 pt and stayed that wide. Call outside SwiftUI updates.
    static func keepWindowWidthWhenShowingSidebar(in window: NSWindow?) {
        guard let root = window?.contentView else { return }
        for controller in splitViewControllers(in: root) {
            for item in controller.splitViewItems where item.behavior == .sidebar {
                if item.collapseBehavior != .preferResizingSiblingsWithFixedSplitView {
                    item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
                }
            }
        }
    }

    /// Shows the sidebar without widening the window. Setting `columnVisibility` to `.all` makes SwiftUI keep
    /// the page's width and grow the window by the sidebar's width (960 → 1181 pt after closing the queue), even
    /// with the sidebar item set to resize its siblings. So the sidebar item is uncollapsed through AppKit, the
    /// way the toolbar's sidebar button does it; SwiftUI then follows with its binding. `sync` sets the binding
    /// only if SwiftUI hasn't, and the frame is put back if that still widened it (a window the user narrowed
    /// meanwhile stays as narrow).
    /// `stillWanted` is checked before each delayed step, so a newer inspector action (reopening the queue)
    /// cancels the rest of the restore.
    static func showSidebarKeepingWidth(in window: NSWindow?, isSynced: @escaping () -> Bool,
                                        stillWanted: @escaping () -> Bool = { true }, sync: @escaping () -> Void) {
        guard let window, !window.styleMask.contains(.fullScreen), let root = window.contentView,
              let item = splitViewControllers(in: root).flatMap(\.splitViewItems).first(where: { $0.behavior == .sidebar })
        else { return sync() }
        keepWindowWidthWhenShowingSidebar(in: window)
        let frame = window.frame
        if item.isCollapsed { item.animator().isCollapsed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak window] in
            guard stillWanted(), !isSynced() else { return }
            sync()
            DispatchQueue.main.async {
                guard stillWanted(), let window, window.frame.width - frame.width > 1, !window.styleMask.contains(.fullScreen) else { return }
                window.requestFrame(NSRect(x: frame.minX, y: window.frame.minY, width: frame.width, height: window.frame.height), display: true, animate: false)
            }
        }
    }

    /// Section headers ("Playlists", "Recently Played") scroll with their rows, as in Music's and Finder's sidebars.
    /// The list's table floats them by default: the top one stuck under the search field with rows sliding behind
    /// it, a hard cut right below the field.
    static func scrollSidebarHeadersAway(in window: NSWindow?) {
        guard let root = window?.contentView else { return }
        let tables = allViews(of: NSTableView.self, in: root)
        guard let sidebar = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
              sidebar.convert(sidebar.bounds, to: nil).minX < 40 else { return }
        if sidebar.floatsGroupRows { sidebar.floatsGroupRows = false }
    }

    private static func allViews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for sub in view.subviews { found += allViews(of: type, in: sub) }
        return found
    }

    /// Sets the lyrics/queue panel's width the way dragging its divider does. The column's min, ideal and max stay
    /// the constants in `InspectorMetrics` (changing those re-solves the split view and has looped it); this only
    /// moves the divider, inside those limits. Call outside SwiftUI updates.
    static func setInspectorWidth(_ width: CGFloat, in window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen), let split = inspectorSplitView(in: window.contentView),
              let panel = split.arrangedSubviews.last, !panel.isHidden else { return }
        let target = min(InspectorMetrics.maxWidth, max(InspectorMetrics.minWidth, width))
        guard abs(panel.frame.width - target) > 1 else { return }
        split.setPosition(split.bounds.width - target - split.dividerThickness, ofDividerAt: split.arrangedSubviews.count - 2)
    }

    /// The panel's current width, or nil when it isn't showing.
    static func inspectorWidth(in window: NSWindow?) -> CGFloat? {
        guard let panel = inspectorSplitView(in: window?.contentView)?.arrangedSubviews.last, !panel.isHidden else { return nil }
        return panel.frame.width
    }

    /// Diagnostics: every split item's behavior, collapsed state, thickness limits and width, and the panel's fitting size.
    static func describeColumns(in window: NSWindow?) -> String {
        guard let root = window?.contentView else { return "no window" }
        var parts: [String] = []
        for controller in splitViewControllers(in: root) {
            for item in controller.splitViewItems {
                let view = item.viewController.view
                parts.append("\(item.behavior.rawValue)\(item.isCollapsed ? " collapsed" : ""): w \(Int(view.frame.width)), min \(Int(item.minimumThickness)), max \(Int(item.maximumThickness)), pref \(String(format: "%.2f", item.preferredThicknessFraction)), hold \(item.holdingPriority.rawValue), fit \(Int(view.fittingSize.width)), autosave \(controller.splitView.autosaveName ?? "none")")
            }
        }
        return parts.joined(separator: " | ")
    }

    /// The split view holding the inspector column: the deepest vertical one with two or more columns.
    static func inspectorSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        for sub in view.subviews {
            if let found = inspectorSplitView(in: sub) { return found }
        }
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 { return split }
        return nil
    }

    /// The split view controller holding the sidebar, and the sidebar's item.
    static func sidebarItem(in root: NSView) -> (NSSplitViewController, NSSplitViewItem)? {
        for controller in splitViewControllers(in: root) {
            if let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) { return (controller, item) }
        }
        return nil
    }

    /// Hides or shows the sidebar the way the toolbar's sidebar button does.
    static func toggleSidebar(in window: NSWindow?) {
        guard let root = window?.contentView, let (controller, _) = sidebarItem(in: root) else { return }
        controller.toggleSidebar(nil)
    }

    fileprivate static func splitViewControllers(in view: NSView) -> [NSSplitViewController] {
        var found: [NSSplitViewController] = []
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
            found.append(controller)
        }
        for sub in view.subviews { found += splitViewControllers(in: sub) }
        return found
    }
}

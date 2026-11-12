import AppKit
import MedleyCore

/// The rows selected in an album or playlist track list, keyed by the rows' ids (`Track.id`: a playlist lists each song
/// once, its pages deduplicated as they load, `PlaylistPager`), so a sort or a filter never moves the selection to
/// another song. The rules are a Mac table's, as in Library › Songs:
///
/// - a click selects only that row; ⌘-click adds or removes one row; ⇧-click selects from the anchor (the row last
///   clicked without ⇧) to the clicked row, keeping what ⌘-clicks added outside that range;
/// - ↑/↓ select the next row alone; ⇧↑/⇧↓ move the range's far end (the lead) from the anchor;
/// - ⌘A selects every row; Escape clears.
///
/// `order` is always the rows' ids in the order shown.
struct TrackSelection: Equatable {
    private(set) var ids: Set<String> = []
    /// Where a ⇧-click or ⇧-arrow range starts.
    private(set) var anchor: String?
    /// The range's moving end: the row ↑/↓ move from, and where the list's focus cursor sits.
    private(set) var lead: String?
    /// What stays selected outside the anchor's range (rows ⌘-clicked before it was set).
    private var base: Set<String> = []

    enum Click: Equatable {
        /// A plain click: only this row.
        case select
        /// ⌘-click: add or remove this row.
        case toggle
        /// ⇧-click: the range from the anchor.
        case extend

        init(_ flags: NSEvent.ModifierFlags) {
            if flags.contains(.command) { self = .toggle } else if flags.contains(.shift) { self = .extend } else { self = .select }
        }
    }

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The selected items in the order shown.
    func selected<T>(_ items: [T], id: (T) -> String) -> [T] {
        items.filter { ids.contains(id($0)) }
    }

    func selected(_ tracks: [Track]) -> [Track] { selected(tracks, id: \.id) }

    /// Positions of the selected rows in `order`.
    func indices(in order: [String]) -> [Int] {
        order.indices.filter { ids.contains(order[$0]) }
    }

    mutating func click(_ id: String, _ kind: Click, in order: [String]) {
        switch kind {
        case .select:
            select(id)
        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
            lead = id
            base = ids.subtracting([id])
        case .extend:
            guard let anchor, order.contains(anchor) else { return select(id) }
            lead = id
            ids = base.union(range(from: anchor, to: id, in: order))
        }
    }

    /// Only `id`, which becomes the anchor and the lead.
    mutating func select(_ id: String) {
        ids = [id]
        anchor = id
        lead = id
        base = []
    }

    /// ↑/↓ (`delta` −1 or 1), ⇧ to extend. With nothing selected, selects `cursor` (the outlined row) first.
    /// Returns the lead, to scroll to.
    @discardableResult
    mutating func move(_ delta: Int, extending: Bool, in order: [String], cursor: String?) -> String? {
        guard !order.isEmpty else { return nil }
        guard !ids.isEmpty else {
            if let cursor { select(cursor) }
            return lead
        }
        let from = lead.flatMap { order.firstIndex(of: $0) } ?? indices(in: order).first ?? 0
        let next = order[min(max(0, from + delta), order.count - 1)]
        if extending, let anchor, order.contains(anchor) {
            lead = next
            ids = base.union(range(from: anchor, to: next, in: order))
        } else {
            select(next)
        }
        return lead
    }

    /// ⌘A: every row. The anchor and lead stay where they were (the first row when there were none).
    mutating func selectAll(_ order: [String]) {
        ids = Set(order)
        if anchor == nil { anchor = order.first }
        if lead == nil { lead = order.first }
        base = []
    }

    /// Escape: nothing selected. The lead stays, so the focus cursor stays where the selection was.
    mutating func clear() {
        ids = []
        base = []
        anchor = nil
    }

    /// The list's rows changed from `old` to `new`. While `holding` (the rows are for now a shorter part of the list,
    /// a refreshed playlist loading its pages again), rows missing from `new` stay selected, so a selected song on a
    /// later page is still selected when its page is back; otherwise rows that went leave (`keep`).
    mutating func rowsChanged(from old: [String], to new: [String], holding: Bool) {
        if !holding { keep(new, previous: old) }
    }

    /// The rows changed (a filter, a reload, songs removed): rows no longer shown leave the selection. When the anchor
    /// or the lead went, the selected row nearest to where it was (inside the range, from `previous`, the order before
    /// the change, when known) takes its place, so ⇧-click and ⇧↑/⇧↓ go on extending what is still selected; what
    /// stays selected outside the new range is kept as the ⌘-clicked part.
    mutating func keep(_ order: [String], previous: [String]? = nil) {
        let shown = Set(order)
        guard !ids.isSubset(of: shown) || !base.isSubset(of: shown) || anchor.map(shown.contains) == false
            || (!ids.isEmpty && lead.map(shown.contains) == false) else { return }
        let oldAnchor = anchor, oldLead = lead
        ids.formIntersection(shown)
        base.formIntersection(shown)
        guard !ids.isEmpty else {
            anchor = nil
            base = []
            if let oldLead, !shown.contains(oldLead) { lead = Self.nearest(to: oldLead, among: order, previous: previous) }
            return
        }
        // The selected rows in the order shown, and, when the previous order is known, the ones between the old anchor
        // and the old lead, nearest the anchor first.
        let selectedInOrder = order.filter(ids.contains)
        var inRange: [String] = []
        if let previous, let a = oldAnchor.flatMap(previous.firstIndex(of:)), let l = oldLead.flatMap(previous.firstIndex(of:)) {
            let step = a <= l ? 1 : -1
            inRange = stride(from: a, through: l, by: step).map { previous[$0] }.filter(ids.contains)
        }
        if let oldAnchor, shown.contains(oldAnchor) {
            anchor = oldAnchor
        } else {
            // Inside the old range first; else the selected row closest to where the anchor sat (a ⌘-clicked anchor of
            // a discontiguous selection: A, ⌘G, ⌘H, H removed → G, not A).
            anchor = inRange.first ?? oldAnchor.flatMap { Self.closest(to: $0, among: ids, previous: previous) } ?? selectedInOrder.first
        }
        if let oldLead, shown.contains(oldLead) {
            lead = oldLead
        } else {
            lead = inRange.last ?? anchor
        }
        // A new anchor or lead: what lies outside their range stays as the ⌘-clicked part.
        if anchor != oldAnchor || lead != oldLead, let anchor, let lead {
            base = ids.subtracting(range(from: anchor, to: lead, in: order))
        }
    }

    /// The row of `order` closest to where `id` sat in `previous` (the one after it, else before), for a lead whose row
    /// went.
    private static func nearest(to id: String, among order: [String], previous: [String]?) -> String? {
        guard let previous, let i = previous.firstIndex(of: id) else { return order.first }
        let shown = Set(order)
        if let after = previous[(i + 1)...].first(where: shown.contains) { return after }
        return previous[..<i].last(where: shown.contains) ?? order.first
    }

    /// The member of `candidates` nearest to `id`'s position in `previous` (the earlier one on a tie), nil when
    /// `previous` doesn't place them.
    private static func closest(to id: String, among candidates: Set<String>, previous: [String]?) -> String? {
        guard let previous, let i = previous.firstIndex(of: id) else { return nil }
        var best: (distance: Int, id: String)?
        for (j, other) in previous.enumerated() where candidates.contains(other) {
            let d = abs(j - i)
            if best == nil || d < best!.distance { best = (d, other) }
        }
        return best?.id
    }

    private func range(from a: String, to b: String, in order: [String]) -> Set<String> {
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return [b] }
        return Set(order[min(i, j)...max(i, j)])
    }
}

import AppKit
import os

/// One line of text that fits its width without cutting a word (Home's featured cards' "Remi Wolf, SZA, Ella Langley
/// and more"). A list of names ending in "and more" drops names from its end and keeps "and more" ("Remi Wolf, SZA
/// and more"); other text ends after the last whole word that fits, with "…".
///
/// The variants and their widths are worked out once per string and size (AppKit's measure, kept), so picking one
/// while the page resizes is a lookup and a comparison. The caller turns its width into the index of the variant
/// (`index(fitting:…)`) in an `onGeometryChange` whose action runs only when that index changes, not every frame.
/// That transform is a nonisolated closure, so nothing here is tied to the main actor; the caches sit behind a lock.
nonisolated enum FittedLine {
    private static let more = " and more"
    /// Long descriptions are cut to this many words before any measuring.
    private static let maxWords = 40
    /// Texts whose variants are kept: every card subtitle and artist line on a long page (Home has well over 200),
    /// so a resize finds them all instead of working them out again each frame.
    private static let maxCachedTexts = 1000

    private struct Caches: Sendable {
        var variants: [String: [String]] = [:]
        var widths: [String: CGFloat] = [:]
    }

    private static let caches = OSAllocatedUnfairLock(initialState: Caches())

    /// The text's variants, longest first. The first is the text itself.
    static func variants(of text: String) -> [String] {
        if let cached = caches.withLock({ $0.variants[text] }) { return cached }
        let result = makeVariants(of: text)
        caches.withLock {
            if $0.variants.count > Self.maxCachedTexts { $0.variants.removeAll() }
            $0.variants[text] = result
        }
        return result
    }

    /// A list of names (a song's artists) as one line: all of them, then fewer with "and more" ("HUNTR/X, EJAE and
    /// more"), then the first name cut after a whole word. One name: `variants(of:)`.
    static func variants(ofNames names: [String]) -> [String] {
        let names = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard names.count > 1 else { return variants(of: names.first ?? "") }
        let key = "\u{1}names|" + names.joined(separator: "\u{1}")
        if let cached = caches.withLock({ $0.variants[key] }) { return cached }
        let result = makeVariants(ofNames: names)
        caches.withLock {
            if $0.variants.count > Self.maxCachedTexts { $0.variants.removeAll() }
            $0.variants[key] = result
        }
        return result
    }

    /// A label and a list of names on one line ("Single · " and an album's artists). Whole names first: the label with
    /// each whole-name variant ("Single · Olivia Rodrigo and more"), then those without the label ("Olivia Rodrigo and
    /// more", in a card too narrow for both), and only then a name cut after a whole word, label kept ("Single ·
    /// Olivia Rodrigo…", which round 27's search card read with room for "Olivia Rodrigo and more").
    static func variants(prefix: String, names: [String]) -> [String] {
        let key = "\u{1}prefix|" + prefix + "\u{1}" + names.joined(separator: "\u{1}")
        if let cached = caches.withLock({ $0.variants[key] }) { return cached }
        let all = variants(ofNames: names)
        let whole = all.filter { !$0.hasSuffix("…") }
        let result = whole.map { prefix + $0 } + whole + all.filter { $0.hasSuffix("…") }.map { prefix + $0 }
        caches.withLock {
            if $0.variants.count > Self.maxCachedTexts { $0.variants.removeAll() }
            $0.variants[key] = result
        }
        return result
    }

    /// Without the caches, for tests.
    static func makeVariants(ofNames names: [String]) -> [String] {
        let full = names.joined(separator: ", ")
        guard names.count > 1 else { return makeVariants(of: full) }
        // The "and more" list of every name, less its first variant (all names and "and more", which says nothing).
        var out = [full]
        for variant in makeVariants(of: full + more).dropFirst() where !out.contains(variant) { out.append(variant) }
        return out
    }

    /// Without the caches, for tests.
    static func makeVariants(of text: String) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [text] }
        var out = [text]
        func add(_ variant: String) {
            if !variant.isEmpty, !out.contains(variant) { out.append(variant) }
        }
        // What to cut word by word when no whole variant fits: the text, or a list's first name ("Remi Wolf…",
        // "Remi…"; "Remi Wolf and…" would read as a slip).
        var last = text
        var keepsAll = false
        if text.hasSuffix(more) {
            let names = text.dropLast(more.count).components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
            if names.allSatisfy({ !$0.isEmpty }) {
                for count in stride(from: names.count - 1, through: 1, by: -1) {
                    add(names.prefix(count).joined(separator: ", ") + more)
                }
                last = names[0]
                keepsAll = true
            }
        }
        let words = last.split(separator: " ", omittingEmptySubsequences: true).prefix(maxWords + 1)
        if keepsAll { add(words.joined(separator: " ") + "…") }
        if words.count > 1 {
            for count in stride(from: words.count - 1, through: 1, by: -1) {
                let head = words.prefix(count).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",;:·–—-&").union(.whitespaces))
                if !head.isEmpty { add(head + "…") }
            }
        }
        return out
    }

    /// The index of the first variant whose one-line width fits `width`, else the last (shortest).
    static func index(of variants: [String], fitting width: CGFloat, measure: (String) -> CGFloat) -> Int {
        variants.firstIndex { measure($0) <= width } ?? max(0, variants.count - 1)
    }

    /// `index(of:fitting:measure:)` with the system font's regular weight at `size`.
    static func index(of text: String, fitting width: CGFloat, size: CGFloat) -> Int {
        index(of: variants(of: text), fitting: width) { self.width($0, size: size) }
    }

    /// The one-line width `text` may take to fit `lines` lines of `width`: the width itself for one line; for more,
    /// that many widths less the widest word for each break (a line ends before a word no wider than that).
    static func room(for text: String, width: CGFloat, lines: Int, size: CGFloat) -> CGFloat {
        guard lines > 1 else { return width }
        let widest = text.split(separator: " ").prefix(maxWords + 1).map { self.width(String($0), size: size) }.max() ?? 0
        return CGFloat(lines) * width - CGFloat(lines - 1) * widest
    }

    /// One-line width in the system font's regular weight, with 2 pt of slack for rounding between AppKit's measure
    /// and SwiftUI's.
    static func width(_ text: String, size: CGFloat) -> CGFloat {
        let key = "\(size)|\(text)"
        if let width = caches.withLock({ $0.widths[key] }) { return width }
        let width = ceil(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]).size().width) + 2
        caches.withLock {
            if $0.widths.count > 8000 { $0.widths.removeAll() }
            $0.widths[key] = width
        }
        return width
    }
}

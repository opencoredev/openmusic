import MedleyCore
import SwiftUI

/// Narrowing a long album or playlist to the songs that match what's typed.
enum TrackFilter {
    /// Lists longer than this get a "Find in…" field.
    static let minimumCount = 25

    /// Indices of `tracks` whose title, artists or album contain every word of `query`
    /// (ignoring case and accents). An empty query matches everything.
    static func matches(_ tracks: [Track], query: String) -> [Int] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(tracks.indices) }
        return tracks.indices.filter { i in
            let t = tracks[i]
            let haystack = [t.title, t.artistLine, t.album?.title ?? ""].joined(separator: " ")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// The small "Find in playlist" field in a long list's action row. While it's on screen, ⌘F focuses it
/// (a second ⌘F, or ⌘F while it already has focus, goes to the sidebar search as usual). Escape clears it,
/// then leaves it.
struct TrackFilterField: View {
    @Binding var text: String
    let prompt: String

    @Environment(AppModel.self) private var model
    @Environment(\.isLayoutMeasurement) private var measuring
    @FocusState private var focused: Bool
    @State private var owner = UUID()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .accessibilityLabel(prompt)
                .onKeyPress(.escape) {
                    if text.isEmpty { focused = false } else { text = "" }
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        // 140–220 pt: it gives way before the page clips (the queue open in a small window); its ideal is the
        // minimum, so a row only wraps it onto its own line when even that doesn't fit.
        .frame(minWidth: 140, idealWidth: 140, maxWidth: 220, minHeight: 30, maxHeight: 30)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 0.5)
                .animation(Motion.hover, value: focused)
        }
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .layoutPriority(1)
        .modifier(LayoutProbe(key: "find-field"))
        // A hidden copy measured for layout (`isLayoutMeasurement`) is never ⌘F's field.
        .onAppear { if !measuring { model.registerPageFind(owner) } }
        .onDisappear { if !measuring { model.unregisterPageFind(owner) } }
        .onChange(of: model.pageFindFocusRequest) { if !measuring { focused = true } }
    }
}

/// Shown in place of the rows when nothing matches.
struct NoFilterMatches: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No songs match “\(query)”")
                .font(.system(size: 15, weight: .semibold))
            Text("Try a song title, an artist or an album.")
                .font(.callout)
                .foregroundStyle(.readableSecondary)
            Button("Clear Search", action: clear)
                .buttonStyle(SubtleLinkStyle(readable: true))
                .font(.callout.weight(.medium))
                .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

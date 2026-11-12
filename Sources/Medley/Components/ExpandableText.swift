import SwiftUI

/// A paragraph clipped to a few lines with a "More" button, shown only when the text is actually truncated
/// at this width. `.inline` expands it in place (artist bios); `.popover` opens the full text beside the
/// button and leaves the surrounding layout alone (album and playlist notes in the page header).
struct ExpandableText: View {
    enum Mode { case inline, popover }

    let text: String
    var lineLimit = 3
    var font: Font = .callout
    var lineSpacing: CGFloat = 0
    var mode: Mode = .inline
    /// Title shown above the text in the popover.
    var title: String? = nil
    /// Snapshot runs click this through its recorded frame.
    var debugKey: String? = nil

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clippedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > clippedHeight + 1 }
    private var expandsInline: Bool { mode == .inline && isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            paragraph
                .lineLimit(expandsInline ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !expandsInline { clippedHeight = $0 } }
                .background(alignment: .topLeading) {
                    // The same text with no line limit, laid out at the same width, to tell whether the limit clips it.
                    paragraph
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        .accessibilityHidden(true)
                }
            if isTruncated || expandsInline {
                Button(expandsInline ? "Less" : "More") {
                    if mode == .inline {
                        withAnimation(Motion.Expansion.inlineText.animation(reduce: reduceMotion)) { isExpanded.toggle() }
                    } else {
                        isExpanded = true
                    }
                }
                .buttonStyle(SubtleLinkStyle(base: .primary))
                .font(.callout.weight(.semibold))
                .accessibilityHint(expandsInline ? "Shows less of the text" : "Shows the full text")
                .modifier(OptionalDebugFrame(key: debugKey))
                .popover(isPresented: Binding(get: { mode == .popover && isExpanded }, set: { isExpanded = $0 }), arrowEdge: .bottom) {
                    FullTextPopover(title: title, text: text)
                }
            }
        }
    }

    private var paragraph: some View {
        Text(text)
            .font(font)
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

private struct FullTextPopover: View {
    let title: String?
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let title {
                    Text(title).font(.headline)
                }
                Text(text)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 440, alignment: .leading)
            // The header styles its notes as secondary; the full text reads as body copy. The label color itself, not
            // `.primary`, which can resolve against the header's own secondary style.
            .foregroundStyle(Color.primary)
        }
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OptionalDebugFrame: ViewModifier {
    let key: String?

    func body(content: Content) -> some View {
        if let key { content.modifier(DebugFrame(key: key)) } else { content }
    }
}

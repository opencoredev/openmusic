import SwiftUI

nonisolated enum PanelMetrics {
    /// Where the panel's header text starts; the lyric lines and the queue's section headings start there too.
    static let leadingInset: CGFloat = 16
}

/// The compact header on the lyrics and queue panels: a title, optional accessories, and a close button.
struct PanelHeader<Accessory: View>: View {
    let title: String
    /// 15 pt in the window's inspector; the full-screen player's Playing Next uses 22 pt.
    var titleSize: CGFloat = 15
    var topInset: CGFloat = 10
    @ViewBuilder var accessory: Accessory
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.quaternary.opacity(0.8)))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(IconButtonStyle(tint: .secondary))
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.leading, PanelMetrics.leadingInset)
        .padding(.trailing, 10)
        .padding(.top, topInset)
        .padding(.bottom, 6)
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(title: String, close: @escaping () -> Void) {
        self.init(title: title, accessory: { EmptyView() }, close: close)
    }
}

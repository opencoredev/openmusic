import OpenMusicCore
import SwiftUI

/// A one-line offer that sits just above the player capsule, such as "Continue from iPhone". Set
/// `AppModel.playerBanner` to show one and nil to hide it. It is part of the page's bottom inset, so page content
/// ends above it instead of scrolling under it.
struct PlayerBanner: Identifiable, Equatable {
    let id: String
    var symbol: String
    var title: String
    var subtitle: String?
    var actionTitle: String
    var action: @MainActor () -> Void
    /// Runs after the close button hides the banner.
    var onDismiss: @MainActor () -> Void = {}
    /// Shown in place of the symbol, with the symbol as a small badge (the song another device plays).
    var artwork: Artwork? = nil
    /// A second line read on every redraw, for live values such as "Daft Punk · 1:02".
    var liveDetail: (@MainActor () -> String)? = nil
    /// True while the action runs: the button shows a spinner and is disabled.
    var isBusy: @MainActor () -> Bool = { false }
    /// Redraw `liveDetail` every second.
    var ticks = false

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.symbol == b.symbol && a.title == b.title && a.subtitle == b.subtitle && a.actionTitle == b.actionTitle
            && a.artwork == b.artwork && a.ticks == b.ticks
    }
}

/// Shows `AppModel.playerBanner` in the player's glass, sliding up from the capsule.
struct PlayerBannerSlot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.playerBanner {
                PlayerBannerView(banner: banner) {
                    model.playerBanner = nil
                    banner.onDismiss()
                }
                .padding(.bottom, FloatingPlayer.gap)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)))
                .id(banner.id)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.playerBanner)
    }
}

private struct PlayerBannerView: View {
    let banner: PlayerBanner
    let dismiss: () -> Void

    var body: some View {
        let busy = banner.isBusy()
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: banner.liveDetail == nil ? .regular : .medium))
                        .foregroundStyle(banner.liveDetail == nil ? .secondary : .primary)
                }
                if let detail = banner.liveDetail {
                    TimelineView(.periodic(from: .now, by: banner.ticks ? 1 : 3600)) { _ in
                        Text(detail())
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            Button { banner.action() } label: {
                ZStack {
                    Text(banner.actionTitle).opacity(busy ? 0 : 1)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(busy)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(IconButtonStyle(tint: .secondary))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, banner.artwork == nil ? 16 : 8)
        .padding(.trailing, 10)
        .frame(height: banner.liveDetail == nil ? 52 : 60)
        .frame(maxWidth: 520)
        .modifier(BannerGlass())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.subtitle.map { "\(banner.title): \($0)" } ?? banner.title)
    }

    @ViewBuilder private var leading: some View {
        if let artwork = banner.artwork {
            ArtworkView(artwork: artwork, size: 44, cornerRadius: 8)
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: banner.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 4, y: 4)
                }
                .padding(.trailing, 2)
                .accessibilityHidden(true)
        } else {
            Image(systemName: banner.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
    }
}

/// The same glass as the player capsule.
private struct BannerGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

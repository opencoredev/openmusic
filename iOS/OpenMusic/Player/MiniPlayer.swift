import OpenMusicCore
import SwiftUI

/// The tab bar's bottom accessory: artwork, title, play/pause and next. Tapping it opens Now Playing.
/// When the tab bar minimizes on scroll it shows inline, and Next drops out to make room.
struct MiniPlayer: View {
    let namespace: Namespace.ID
    @Environment(AppModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let player = model.player
        let track = player.current
        HStack(spacing: 10) {
            ArtworkView(artwork: track?.artwork, points: 34)
                .frame(width: 34, height: 34)
                .clipShape(.rect(cornerRadius: 6))
                .matchedTransitionSource(id: "nowplaying", in: namespace)
            VStack(alignment: .leading, spacing: 0) {
                Text(track?.title ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let artist = track?.artistLine, placement != .inline {
                    Text(artist).font(.caption).foregroundStyle(.secondaryText).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .disabled(track == nil)
            if placement != .inline {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Next")
                .disabled(track == nil)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .contentShape(.rect)
        .onTapGesture { model.presentNowPlaying() }
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Now Playing") { model.presentNowPlaying() }
    }
}

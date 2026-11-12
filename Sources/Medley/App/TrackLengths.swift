import MedleyCore
import SwiftUI

/// Song lengths for rows: the real length once the player has heard the song's stream (`KnownLengths`),
/// so an album, playlist, search or queue row never contradicts the player bar.
extension AppModel {
    /// The length a row should show for `track`. Reading it in a view body makes that row follow this
    /// one song's length; it doesn't redraw on the player's time ticks.
    func displayDuration(for track: Track) -> TimeInterval? {
        player.knownLengths.displayDuration(for: track)
    }

    /// Tooltip for a row's duration when the stream is more than 10 s away from the listing, e.g.
    /// "YouTube Music plays a 6:46 version of this song (the album lists 5:46)." nil otherwise.
    func durationNote(for track: Track) -> String? {
        guard let m = player.knownLengths.mismatch(for: track) else { return nil }
        return Self.durationNote(service: track.provider.displayName, real: m.real, listed: m.listed, onAlbum: track.album != nil)
    }

    static func durationNote(service: String, real: TimeInterval, listed: TimeInterval, onAlbum: Bool) -> String {
        let source = onAlbum ? "the album lists" : "its listing says"
        return "\(service) plays a \(real.clock) version of this song (\(source) \(listed.clock))."
    }
}

/// `DurationText` for a song: its real length once known, with the version tooltip when the listing is off.
struct TrackDurationText: View {
    @Environment(AppModel.self) private var model
    let track: Track
    var font: Font = .rowSecondary
    var minWidth: CGFloat? = Metrics.durationWidth

    init(_ track: Track, font: Font = .rowSecondary, minWidth: CGFloat? = Metrics.durationWidth) {
        self.track = track
        self.font = font
        self.minWidth = minWidth
    }

    var body: some View {
        let note = model.durationNote(for: track)
        DurationText(model.displayDuration(for: track), font: font, minWidth: minWidth)
            .help(note ?? "")
            .accessibilityHint(note ?? "")
    }
}

/// "Alt. version", just before a row's duration when the service plays a recording more than 10 s away from
/// the listing's length (Veridis Quo: 6:46 for the album's 5:46). The duration's tooltip says which is which.
struct AltVersionLabel: View {
    @Environment(AppModel.self) private var model
    let track: Track

    var body: some View {
        if let note = model.durationNote(for: track) {
            Text("Alt. version")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .help(note)
                .accessibilityLabel("Alternate version")
                .accessibilityHint(note)
        }
    }
}

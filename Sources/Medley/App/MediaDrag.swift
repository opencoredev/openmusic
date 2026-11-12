import CoreTransferable
import MedleyCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A song, album, playlist or artist dragged inside Medley. Declared in `Resources/Info.plist`.
    nonisolated static let medleyItem = UTType(exportedAs: "dev.openmusic.item", conformingTo: .data)
}

/// What a dragged song, album, playlist or artist carries. Medley's own drops (a playlist in the sidebar, Playing
/// Next) read the item itself; other apps get plain text: the share link on the first line, Medley's id for the item
/// on the second (just the id when the item has no link).
nonisolated struct MediaDragItem: Codable, Hashable, Sendable, Transferable {
    let item: MediaItem

    init(_ item: MediaItem) { self.item = item }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .medleyItem)
        ProxyRepresentation(exporting: \.plainText)
    }

    var plainText: String {
        guard let link = WebLinks.url(for: item)?.absoluteString else { return item.id }
        return "\(link)\n\(item.id)"
    }
}

/// A drag source with Medley's preview: the artwork (round for an artist) and the title, as Music's drags show. The
/// payload is the same `MediaDragItem`, registered on an item provider when a drag starts.
///
/// `onDrag`, not `.draggable`: on every row and card `.draggable` added about 27 dropped frames to
/// `scripts/sidebar-bench.sh` (96–100 against 69–71 without it, run back to back), hitches where a sidebar move starts;
/// `onDrag` measured 79 and 83, in the range of the commit before drag and drop (74, 85).
struct MediaDraggable: ViewModifier {
    let item: MediaItem

    func body(content: Content) -> some View {
        content.onDrag {
            let provider = NSItemProvider()
            provider.register(MediaDragItem(item))
            return provider
        } preview: {
            MediaDragPreview(item: item)
        }
    }
}

extension View {
    /// Makes the view a drag source for `item` (`MediaDragItem`), with the artwork-and-title preview.
    func mediaDraggable(_ item: MediaItem) -> some View { modifier(MediaDraggable(item: item)) }
}

/// The drag image: 40 pt artwork and the title on a small rounded material plate.
struct MediaDragPreview: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(artwork: item.artwork, size: 40, cornerRadius: 5, circle: item.isArtist)
                .frame(width: 40, height: 40)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize()
        }
        .padding(6)
        .padding(.trailing, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension MediaItem {
    var isArtist: Bool { if case .artist = self { true } else { false } }
}

// MARK: - Drops

extension AppModel {
    /// Where a drop on Playing Next lands: before the rest of Up Next, or after it.
    enum QueueDrop: Equatable { case playNext, addToQueue }

    /// Whether a drop of `items` onto `playlist` can add anything: the playlist is the listener's own, and at least
    /// one item is a song, album or playlist from the playlist's service (an artist isn't a list of songs, and the
    /// other service's songs can't go in it).
    func canDrop(_ items: [MediaDragItem], on playlist: Playlist) -> Bool {
        playlist.isEditable && items.contains { Self.droppable($0.item, on: playlist) }
    }

    private static func droppable(_ item: MediaItem, on playlist: Playlist) -> Bool {
        guard item.provider == playlist.provider else { return false }
        switch item {
        case .track: return true
        case .album: return true
        case .playlist(let p): return p.providerID != playlist.providerID
        case .artist: return false
        }
    }

    /// Songs, albums or playlists dropped on a playlist in the sidebar: their songs are appended, in the order
    /// dragged, and "Added to <playlist>" confirms it (`add(_:to:)`). Returns false (the drop is refused and the
    /// drag image slides back) when nothing in it can go there; items from the other service are skipped with a
    /// notice saying so.
    @discardableResult
    func drop(_ items: [MediaDragItem], on playlist: Playlist) -> Bool {
        guard canDrop(items, on: playlist) else {
            if playlist.isEditable, let other = items.first(where: { $0.item.provider != playlist.provider }) {
                show(Notice(text: "\(other.item.provider.displayName) songs can’t go in a \(playlist.provider.displayName) playlist.",
                            symbol: "exclamationmark.triangle.fill", kind: .failure))
            }
            return false
        }
        // One edit at a time: while the playlist has a change in flight (or one waiting on Try Again) the drop is refused,
        // with the reason (`refusesEdit`).
        guard !refusesEdit(playlist) else { return false }
        let accepted = items.map(\.item).filter { Self.droppable($0, on: playlist) }
        lastDrop = Task {
            let resolved = await resolvedTracks(accepted)
            guard !resolved.tracks.isEmpty else { return }
            await add(resolved.tracks, to: playlist, parts: resolved.parts).value
        }
        return true
    }

    /// Songs, albums, playlists or artists dropped on Playing Next: above Up Next they play next, below it they go
    /// at the end of Up Next (before Autoplay), with the same confirmation as the menu items.
    @discardableResult
    func dropOnQueue(_ items: [MediaDragItem], at position: QueueDrop) -> Bool {
        guard !items.isEmpty else { return false }
        lastDrop = Task {
            let resolved = await resolvedTracks(items.map(\.item))
            let tracks = resolved.tracks
            guard !tracks.isEmpty else { return }
            // One notice for the drop: a playlist only partly loaded says which part went, and stays until closed.
            let part = resolved.parts.isEmpty ? nil : Self.partPhrase(resolved.parts)
            switch position {
            case .playNext:
                player.playNext(tracks)
                if let part { showPartial("Playing \(part) next") }
                else { show(Notice(text: "Playing next", symbol: "text.line.first.and.arrowtriangle.forward")) }
            case .addToQueue:
                player.addToQueue(tracks)
                if let part { showPartial("Added \(part) to the queue") }
                else { show(Notice(text: "Added to queue", symbol: "text.line.last.and.arrowtriangle.forward")) }
            }
        }
        return true
    }

    /// Every item's songs in order: a song as itself, a collection through `tracks(for:)` (which reports a failure),
    /// and the collections only partly loaded, for the drop's notice.
    private func resolvedTracks(_ items: [MediaItem]) async -> (tracks: [Track], parts: [PartLoaded]) {
        var out: [Track] = []
        var parts: [PartLoaded] = []
        for item in items {
            if case .track(let track) = item { out.append(track); continue }
            if let resolved = await tracks(for: item) {
                out += resolved.tracks
                if let part = resolved.part { parts.append(part) }
            }
        }
        return (out, parts)
    }
}

import OpenMusicCore
import AppKit
import SwiftUI

/// Context menu for a song. Every item checks the provider's capabilities and sign-in.
struct TrackMenu: View {
    let track: Track
    /// The playlist the song is shown in, to offer "Remove from Playlist".
    var playlist: Playlist? = nil
    /// "Go to Album “GUTS”": for rows that leave the album off their own text (search songs).
    var namesAlbum = false
    /// How many entries the song has in `playlist` (its row's "2×"): Remove then names the copies it takes.
    var copies = 1
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let provider = model.provider(track.provider)
        let signedIn = provider?.isSignedIn ?? false
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(.track(track)) }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue(.track(track)) }
        Divider()
        if signedIn, model.can(.like, track.provider) {
            let liked = model.isLiked(track)
            Button(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart") { model.toggleLike(track) }
        }
        if signedIn, model.can(.playlistEditing, track.provider) {
            AddToPlaylistMenu(provider: track.provider) { [track] in [track] }
            if let playlist, playlist.isEditable {
                // Undoable where the service can put the song back in place; otherwise the window asks first.
                // Disabled while the playlist finishes another change (one edit at a time, `AppModel.canEdit`).
                Button(Self.removeTitle(songs: 1, copies: copies), systemImage: "minus.circle") { model.requestRemove([track], from: playlist, undoManager: undoManager) }
                    .disabled(!model.canEdit(playlist))
            }
        }
        Divider()
        // The same two items everywhere a song appears. When a listing (search rows, top results) left the
        // links out, the app asks the service on demand and says so if the song has no album.
        if track.artists.filter({ $0.id != nil }).count > 1 {
            GoToArtistItems(artists: track.artists, provider: track.provider)
        } else {
            Button("Go to Artist", systemImage: "music.mic") { model.goToArtistResolving(track) }
        }
        Button(albumItemTitle, systemImage: "square.stack") { model.goToAlbumResolving(track) }
        if model.can(.radio, track.provider) {
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { model.startRadio(track) }
        }
        Divider()
        Button("Copy Link", systemImage: "link") { model.copyLink(.track(track)) }
    }

    /// The Remove item, which takes every copy of each song: "Remove from Playlist" when each is in the playlist once,
    /// else the copies it takes ("Remove Both Copies", "Remove All 3 Copies"; a selection's copies in all).
    static func removeTitle(songs: Int, copies: Int) -> String {
        guard copies > songs else { return "Remove from Playlist" }
        return copies == 2 ? "Remove Both Copies" : "Remove All \(copies) Copies"
    }

    private var albumItemTitle: String {
        guard namesAlbum, let album = track.album?.title, !album.isEmpty else { return "Go to Album" }
        return "Go to Album “\(album)”"
    }
}

/// Context menu for several selected songs (an album's or playlist's rows), acting on all of them in the order shown:
/// Play Next, Add to Queue, Add to Playlist and Remove from Playlist (one removal with one Undo, or one confirmation
/// where the service can't put songs back in place).
struct TracksMenu: View {
    /// The selected rows, in the order shown.
    let tracks: [Track]
    var playlist: Playlist? = nil
    /// Every entry the selected songs have in `playlist`, copies counted: Remove names them when there are more.
    var copies = 0
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        // Songs from one service can go into its playlists; a mixed selection offers only the queue.
        let provider = tracks.first.map(\.provider)
        let oneService = provider.map { p in tracks.allSatisfy { $0.provider == p } } ?? false
        let signedIn = provider.flatMap { model.provider($0)?.isSignedIn } ?? false
        Text("\(tracks.count) Songs")
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(tracks) }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue(tracks) }
        if let provider, oneService, signedIn, model.can(.playlistEditing, provider) {
            Divider()
            AddToPlaylistMenu(provider: provider) { [tracks] in tracks }
            if let playlist, playlist.isEditable, playlist.provider == provider {
                let songs = AppModel.eachOnce(tracks)
                Button(TrackMenu.removeTitle(songs: songs.count, copies: max(copies, songs.count)), systemImage: "minus.circle") {
                    model.requestRemove(songs, from: playlist, undoManager: undoManager)
                }
                .disabled(!model.canEdit(playlist))
            }
        }
    }
}

/// Context menu for an album, playlist or artist.
struct CollectionMenu: View {
    let item: MediaItem
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .track(let track) = item {
            TrackMenu(track: track)
        } else {
            let provider = model.provider(item.provider)
            let signedIn = provider?.isSignedIn ?? false
            Button("Play", systemImage: "play") { model.play(item) }
            Button("Shuffle", systemImage: "shuffle") { model.play(item, shuffled: true) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(item) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue(item) }
            Divider()
            if signedIn {
                // "Add to Library"/"Remove from Library", "Follow"/"Unfollow": the model's one state per collection,
                // the same the album, playlist and artist pages show.
                if let save = model.saveAction(for: item) {
                    Button(save.title, systemImage: save.symbol) { model.setSaved(item, saved: save.target) }
                }
                if case .album = item, model.can(.playlistEditing, item.provider) {
                    AddToPlaylistMenu(provider: item.provider) { [model, item] in
                        await model.tracks(for: item)?.tracks ?? []
                    }
                }
            }
            if let entry = SidebarEntry(item) {
                if model.collections.isPinned(entry.id) {
                    Button("Unpin from Sidebar", systemImage: "pin.slash") { model.unpinFromSidebar(entry.id) }
                } else {
                    Button("Pin to Sidebar", systemImage: "pin") { model.pinToSidebar(entry) }
                }
            }
            if case .album(let album) = item {
                GoToArtistItems(artists: album.artists, provider: album.provider)
            }
            if model.can(.radio, item.provider) {
                switch item {
                case .artist(let a):
                    Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        model.startRadio(seedID: a.extra["radioSeed"] ?? a.providerID, title: a.name, provider: a.provider, origin: item)
                    }
                case .playlist(let p):
                    Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") {
                        model.startRadio(seedID: p.providerID, title: p.title, provider: p.provider, origin: item)
                    }
                default:
                    EmptyView()
                }
            }
            Divider()
            Button("Copy Link", systemImage: "link") { model.copyLink(item) }
        }
    }
}

/// "Add to Playlist ▸" listing the provider's editable playlists, plus "New Playlist…".
struct AddToPlaylistMenu: View {
    let provider: ProviderID
    let tracks: @MainActor () async -> [Track]
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist…") {
                Task {
                    let resolved = await tracks()
                    model.newPlaylistRequest = .init(provider: provider, tracks: resolved)
                }
            }
            let playlists = model.editablePlaylists(provider)
            if !playlists.isEmpty {
                Divider()
                ForEach(playlists) { playlist in
                    Button(playlist.title) {
                        Task {
                            let resolved = await tracks()
                            model.add(resolved, to: playlist)
                        }
                    }
                    .disabled(!model.canEdit(playlist))
                }
            }
        }
    }
}

struct GoToArtistItems: View {
    let artists: [ArtistRef]
    let provider: ProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        let linked = artists.filter { $0.id != nil }
        if linked.count == 1, let artist = linked.first {
            Button("Go to Artist", systemImage: "music.mic") { model.goToArtist(artist, provider: provider) }
        } else if linked.count > 1 {
            Menu("Go to Artist", systemImage: "music.mic") {
                ForEach(linked, id: \.self) { artist in
                    Button(artist.name) { model.goToArtist(artist, provider: provider) }
                }
            }
        }
    }
}

/// What a `MoreButton`'s dots are drawn in. A pull-down menu's borderless label is drawn by AppKit as a template
/// image in the control's own text color, whatever foreground style SwiftUI puts around it, so the ink is part of
/// the label image itself.
enum MoreButtonInk: Equatable {
    /// The control's text color (the label color), as AppKit draws a template.
    case label
    /// A quieter gray at rest: the opaque `readableSecondary` gray of the row's other secondary text.
    case quiet
    /// White, on the focused accent selection.
    case white
}

/// The "…" button that appears on hover and opens the same menu as right-click.
struct MoreButton<MenuContent: View>: View {
    var size: CGFloat = 15
    var ink: MoreButtonInk = .label
    @ViewBuilder var content: MenuContent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Menu {
            // A pull-down menu drops its items' symbols unless asked; the right-click menu shows them.
            content.labelStyle(.titleAndIcon)
        } label: {
            glyph
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    /// White and the quiet gray are palette symbol images, which AppKit draws in their own colors (not a template it
    /// would tint). The gray is resolved for the appearance here, so the image changes with light and dark.
    @ViewBuilder private var glyph: some View {
        if let color = paletteColor, let image = Self.image(size: size, color: color) {
            Image(nsImage: image)
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: size, weight: .semibold))
        }
    }

    private var paletteColor: NSColor? {
        switch ink {
        case .label: nil
        case .white: .white
        case .quiet:
            NSColor(white: colorScheme == .dark ? (contrast == .increased ? 0.86 : ReadableSecondary.dark)
                                                : (contrast == .increased ? 0.2 : ReadableSecondary.light), alpha: 1)
        }
    }

    private static func image(size: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        image.isTemplate = false
        return image
    }
}

/// A row's "…" that the keyboard reaches too. A SwiftUI `Menu` takes Tab focus only with the system's Keyboard
/// Navigation setting on (off by default), so this is a focusable view of its own: Tab lands on it with the setting
/// either way, Space, Return or ↓ open the menu, and a click opens it as before. The menu is the same SwiftUI content
/// as the right-click menu, hosted in an `NSMenu` (`NSHostingMenu`) under the button, with the items' symbols.
///
/// `focused` reports keyboard focus, so the row can show the button and its highlight (`hovering || focused`) instead
/// of hiding them until the pointer comes by. Keyboard focus shows as a 2 pt accent ring around the button. A click
/// takes focus too (`.focusable` does), but a pointer-opened menu draws no ring: the button shows a pressed fill
/// instead while its menu is up, and leaves no focus behind once the menu closes, as a native button does with the
/// setting off.
struct KeyboardMoreButton<MenuContent: View>: View {
    var size: CGFloat = 15
    @Binding var focused: Bool
    /// Names the focused button for the council capture's log (`DebugProbes`).
    var probeNote: String? = nil
    /// Its tooltip and VoiceOver label ("More actions for Opalite").
    var label = "More"
    /// The menu opens above the button (the floating player at the window's bottom) instead of below it.
    var opensAbove = false
    var weight: Font.Weight = .semibold
    /// The square it takes (and clicks land in): 24 pt in rows, 32 pt for the hero's round More.
    var side: CGFloat = 24
    /// A round button (the hero's More): clicks land in the circle and the focus ring follows it.
    var circular = false
    /// The menu draws in the dark appearance whatever the system's (the full-screen player, the mini player on dark
    /// artwork): a SwiftUI `colorScheme` doesn't reach an `NSMenu`, which otherwise follows the app's appearance.
    var forceDark = false
    @ViewBuilder var content: MenuContent

    @Environment(AppModel.self) private var model
    @FocusState private var hasFocus: Bool
    @State private var anchor = MenuAnchor.Holder()
    /// The focus came from a click, not Tab: no ring for it.
    @State private var openedByPointer = false
    /// A menu opened by a click is up: the glyph sits on a pressed fill.
    @State private var pointerMenuOpen = false

    var body: some View {
        // The glyph takes the caller's foreground style (white on the artist photo), which a SwiftUI `Menu`'s
        // borderless label ignores.
        Image(systemName: "ellipsis")
            .font(.system(size: size, weight: weight))
            .frame(width: side, height: side)
            .contentShape(circular ? AnyShape(Circle()) : AnyShape(Rectangle()))
            .background {
                if pointerMenuOpen {
                    // 24 pt in rows; a round button (the hero's, the full-screen player's) fills its own circle.
                    Circle().fill(.quaternary).frame(width: circular ? side : 24, height: circular ? side : 24)
                }
            }
            .background(MenuAnchor(holder: anchor))
            .overlay {
                if hasFocus && !openedByPointer {
                    Group {
                        if circular {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                    .padding(-2)
                    .allowsHitTesting(false)
                }
            }
            // `.edit`, not the default: the default's activation interaction took Space for a primary action this
            // view doesn't have, before `onKeyPress` saw it.
            .focusable(interactions: .edit)
            .focused($hasFocus)
            .focusEffectDisabled()
            .onTapGesture {
                openedByPointer = true
                pointerMenuOpen = true
                open(keepFocus: false)
            }
            .onKeyPress(keys: [.space, .return, .downArrow]) { press in
                if LayoutProbe.enabled { DebugProbes.note("more-open", "key \(press.key == .space ? "Space" : press.key == .return ? "Return" : "Down")") }
                openedByPointer = false
                open(keepFocus: true)
                return .handled
            }
            .onChange(of: hasFocus) {
                focused = hasFocus
                if !hasFocus { openedByPointer = false }
                // Space opens this menu while it has focus: `onKeyPress` handles it, so it never reaches the app-wide
                // play/pause (`SpaceFallback`).
                if LayoutProbe.enabled, let probeNote { DebugProbes.note("more-focus", hasFocus ? probeNote : nil) }
            }
            .help(label)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityAction { open(keepFocus: true) }
    }

    /// Opens the menu under the button on the next turn of the run loop, so the key press or click that asked for
    /// it has finished first. A run-loop block, not a main-actor task: `popUp` tracks the menu until it closes, and
    /// inside a task it would hold the main queue all that time (playback time, notices and everything else on the
    /// main actor would stop).
    private func open(keepFocus: Bool) {
        guard let view = anchor.view else {
            if LayoutProbe.enabled { DebugProbes.note("more-open", "no anchor view") }
            return
        }
        let request = MenuRequest(menu: NSHostingMenu(rootView: content.labelStyle(.titleAndIcon).environment(model)), view: view,
                                  above: opensAbove, dark: forceDark) {
            if !keepFocus { hasFocus = false }
            openedByPointer = false
            pointerMenuOpen = false
        }
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { request.run() }
        }
    }
}

/// A menu to pop up under a view, handed to a run-loop block.
private final class MenuRequest: @unchecked Sendable {
    let menu: NSMenu
    let view: NSView
    let above: Bool
    let dark: Bool
    let done: @MainActor () -> Void

    init(menu: NSMenu, view: NSView, above: Bool = false, dark: Bool = false, done: @escaping @MainActor () -> Void) {
        self.menu = menu
        self.view = view
        self.above = above
        self.dark = dark
        self.done = done
    }

    @MainActor func run() {
        if LayoutProbe.enabled { DebugProbes.note("more-open", "popping up \(menu.items.count) items in \(view.window == nil ? "no window" : "the window")") }
        KeyboardMoreMenu.current = menu
        if dark { menu.appearance = NSAppearance(named: .darkAqua) }
        // The point is the menu's top-left corner: under the button, or a menu's height above its top.
        let height = menu.size.height
        // Leading edge on the button's, unless the menu would run past the window's trailing edge (the mini player's
        // "…" sits near it): then it moves left to end 8 pt inside the window.
        var x: CGFloat = 0
        if let window = view.window {
            let room = window.frame.width - view.convert(view.bounds, to: nil).minX - 8
            if menu.size.width > room { x = room - menu.size.width }
        }
        let point = above
            ? NSPoint(x: x, y: view.isFlipped ? -4 - height : view.bounds.maxY + 4 + height)
            : NSPoint(x: x, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: point, in: view)
        KeyboardMoreMenu.current = nil
        done()
    }
}

/// The menu a `KeyboardMoreButton` has open, so the council capture can pick an item from it.
@MainActor
enum KeyboardMoreMenu {
    static var current: NSMenu?
}

/// An AppKit view behind the button, for `NSMenu.popUp(positioning:at:in:)` to place the menu against.
private struct MenuAnchor: NSViewRepresentable {
    @MainActor final class Holder { weak var view: NSView? }
    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { holder.view = nsView }
}

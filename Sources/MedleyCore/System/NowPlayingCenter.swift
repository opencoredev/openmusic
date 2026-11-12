#if os(macOS)
import AppKit
typealias NowPlayingImage = NSImage
#else
import UIKit
typealias NowPlayingImage = UIImage
#endif
import Foundation
import MediaPlayer

/// Publishes the current track to Control Center / the menu bar Now Playing widget and routes media keys,
/// AirPods and Touch Bar commands to the `PlayerController`.
///
/// Updates happen on track, state and seek changes only; the system extrapolates elapsed time from the rate,
/// so there is no per-tick work.
@MainActor
public final class NowPlayingCenter {
    private weak var player: PlayerController?
    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
    private var handlerID: UUID?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: String?
    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    private var artworkOrder: [URL] = []
    private static let artworkCacheLimit = 24

    /// Shown as the heart in Control Center when set. Called with the current track.
    public var onLike: (@MainActor (Track) -> Void)? { didSet { updateFeedbackCommands() } }
    public var onDislike: (@MainActor (Track) -> Void)? { didSet { updateFeedbackCommands() } }
    /// Runs before a transport command (play, pause, next, previous, a seek) from the media keys, Control Center or a
    /// headset: the app's chance to treat it as the listener's newest playback choice.
    public var willRunTransportCommand: (@MainActor () -> Void)?
    /// Whether the current track is liked; drives the like command's active state.
    public var isCurrentTrackLiked = false { didSet { commandCenter.likeCommand.isActive = isCurrentTrackLiked } }

    public init(player: PlayerController, infoCenter: MPNowPlayingInfoCenter = .default(), commandCenter: MPRemoteCommandCenter = .shared()) {
        self.player = player
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
    }

    public func start() {
        guard handlerID == nil, let player else { return }
        handlerID = player.addChangeHandler { [weak self] change in
            self?.playerChanged(change)
        }
        registerCommands()
        publish(includeArtwork: true)
    }

    public func stop() {
        if let handlerID { player?.removeChangeHandler(handlerID) }
        handlerID = nil
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        artworkTask?.cancel()
        infoCenter.nowPlayingInfo = nil
        setPlaybackState(.stopped)
    }

    // MARK: Info

    private func playerChanged(_ change: PlayerChange) {
        switch change {
        case .track: publish(includeArtwork: true)
        case .state, .timing: publish(includeArtwork: false)
        case .queue: updateTransportAvailability()
        }
    }

    private func publish(includeArtwork: Bool) {
        guard let player, let track = player.current else {
            infoCenter.nowPlayingInfo = nil
            setPlaybackState(.stopped)
            return
        }
        var info = Self.makeInfo(
            track: track,
            elapsed: player.currentTime,
            duration: player.duration,
            isPlaying: player.state == .playing,
            queueIndex: player.currentIndex,
            queueCount: player.queue.count
        )
        if let url = track.artwork?.url(minPixels: 600) {
            if let cached = artworkCache[url] {
                info[MPMediaItemPropertyArtwork] = cached
            } else if includeArtwork || artworkTrackID != track.id {
                loadArtwork(url, for: track.id)
            } else if let existing = infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
                info[MPMediaItemPropertyArtwork] = existing
            }
        }
        infoCenter.nowPlayingInfo = info
        setPlaybackState(Self.playbackState(for: player.state))
        updateTransportAvailability()
    }

    /// The `nowPlayingInfo` dictionary for a track, without artwork.
    static func makeInfo(track: Track, elapsed: TimeInterval, duration: TimeInterval?, isPlaying: Bool, queueIndex: Int?, queueCount: Int) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
        ]
        if let album = track.album?.title { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = duration ?? track.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let number = track.trackNumber { info[MPMediaItemPropertyAlbumTrackNumber] = number }
        if let queueIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        }
        return info
    }

    /// `MPNowPlayingInfoCenter.playbackState` drives the menu bar widget on macOS. iOS reads the playback
    /// rate in `nowPlayingInfo` instead, and the property doesn't exist there.
    private func setPlaybackState(_ state: MPNowPlayingPlaybackState) {
        #if os(macOS)
        infoCenter.playbackState = state
        #endif
    }

    /// What was last published, for the in-app self-test (iOS has no readable `playbackState`).
    public var publishedInfo: [String: Any]? { infoCenter.nowPlayingInfo }

    static func playbackState(for state: PlaybackState) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing, .buffering, .loading: .playing
        case .paused, .failed: .paused
        case .idle, .ended: .stopped
        }
    }

    private func loadArtwork(_ url: URL, for trackID: String) {
        artworkTask?.cancel()
        artworkTrackID = trackID
        artworkTask = Task { [weak self] in
            guard let data = try? await HTTP.session.data(from: url).0 else { return }
            // Decode off the main actor; NSImage(data:) and UIImage(data:) are thread-safe for this.
            let box = await Task.detached(priority: .utility) { () -> ImageBox? in
                NowPlayingImage(data: data).map(ImageBox.init)
            }.value
            guard let self, let box, !Task.isCancelled else { return }
            let artwork = Self.artwork(from: box)
            self.cache(artwork, for: url)
            guard self.player?.current?.id == trackID, var info = self.infoCenter.nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = artwork
            self.infoCenter.nowPlayingInfo = info
        }
    }

    /// MediaPlayer may call command handlers off the main thread. The handler is built in a nonisolated
    /// context so it carries no main-actor isolation check, then hops to the main actor itself.
    nonisolated private static func handler(_ run: @escaping @MainActor @Sendable (TimeInterval?) -> Bool) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            if Thread.isMainThread {
                return MainActor.assumeIsolated { run(position) } ? .success : .commandFailed
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = run(position) } }
            return .success
        }
    }

    /// MediaPlayer calls the request handler on its own background queue, so it must not be main-actor
    /// isolated (an isolated closure traps there). `nonisolated` keeps the closure off the main actor.
    nonisolated private static func artwork(from box: ImageBox) -> MPMediaItemArtwork {
        let image = box.image
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { @Sendable _ in image }
    }

    private func cache(_ artwork: MPMediaItemArtwork, for url: URL) {
        artworkCache[url] = artwork
        artworkOrder.removeAll { $0 == url }
        artworkOrder.append(url)
        while artworkOrder.count > Self.artworkCacheLimit {
            artworkCache[artworkOrder.removeFirst()] = nil
        }
    }

    // MARK: Commands

    private func registerCommands() {
        guard commandTargets.isEmpty else { return }
        add(commandCenter.playCommand, transport: true) { player, _ in player.resume() }
        add(commandCenter.pauseCommand, transport: true) { player, _ in player.pause() }
        add(commandCenter.togglePlayPauseCommand, transport: true) { player, _ in player.togglePlayPause() }
        add(commandCenter.nextTrackCommand, transport: true) { player, _ in player.next() }
        add(commandCenter.previousTrackCommand, transport: true) { player, _ in player.previous() }
        add(commandCenter.stopCommand, transport: true) { player, _ in player.pause() }
        add(commandCenter.changePlaybackPositionCommand, transport: true) { player, position in
            if let position { player.seek(to: position) }
        }
        add(commandCenter.likeCommand) { [weak self] player, _ in
            if let track = player.current { self?.onLike?(track) }
        }
        add(commandCenter.dislikeCommand) { [weak self] player, _ in
            if let track = player.current { self?.onDislike?(track) }
        }
        commandCenter.likeCommand.localizedTitle = "Love"
        commandCenter.dislikeCommand.localizedTitle = "Suggest Less"
        updateFeedbackCommands()
        updateTransportAvailability()
    }

    private func add(_ command: MPRemoteCommand, transport: Bool = false, _ action: @escaping @MainActor (PlayerController, TimeInterval?) -> Void) {
        let run: @MainActor @Sendable (TimeInterval?) -> Bool = { [weak self] position in
            guard let self, let player = self.player else { return false }
            if transport { self.willRunTransportCommand?() }
            action(player, position)
            return true
        }
        let target = command.addTarget(handler: Self.handler(run))
        command.isEnabled = true
        commandTargets.append((command, target))
    }

    private func updateFeedbackCommands() {
        commandCenter.likeCommand.isEnabled = onLike != nil
        commandCenter.dislikeCommand.isEnabled = onDislike != nil
    }

    private func updateTransportAvailability() {
        guard let player, !commandTargets.isEmpty else { return }
        let hasTrack = player.current != nil
        commandCenter.nextTrackCommand.isEnabled = hasTrack
        commandCenter.previousTrackCommand.isEnabled = hasTrack
        commandCenter.changePlaybackPositionCommand.isEnabled = hasTrack && player.duration != nil
    }
}

/// NSImage/UIImage isn't Sendable, but this one is never mutated after decoding, and MediaPlayer
/// calls the artwork handler from its own queue.
private final class ImageBox: @unchecked Sendable {
    let image: NowPlayingImage
    init(_ image: NowPlayingImage) { self.image = image }
}

import Foundation
import OpenMusicCore

// Swift mirrors of the validators in sync/convex/model.ts. Field names match the wire exactly.

/// A device's id in the sync backend (a Convex document id).
public struct DeviceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}

public struct LibraryID: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct CommandID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public var description: String { rawValue }
}

/// Server clock in milliseconds since 1970 (`Date.now()` on the backend).
public typealias ServerMillis = Double

/// The platform a device runs. A platform this build doesn't know (an app made after it) decodes as `unknown`, which the
/// apps show with a generic computer icon, so a new kind of device in the list never breaks them.
public enum DevicePlatform: String, Codable, Sendable, Hashable {
    case mac, ios, windows, android, linux
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DevicePlatform(rawValue: raw) ?? .unknown
    }
}

/// What a device says about itself when it joins.
public struct DeviceInfo: Codable, Sendable, Hashable {
    public var name: String
    public var platform: DevicePlatform
    /// Hardware model identifier, e.g. "Mac16,10" or "iPhone17,1".
    public var model: String
    public var appVersion: String

    public init(name: String, platform: DevicePlatform, model: String, appVersion: String) {
        self.name = name
        self.platform = platform
        self.model = model
        self.appVersion = appVersion
    }
}

/// Whether a device holds the account's vault key (the key YouTube Music and Spotify sign-ins are sealed with).
public enum KeyStateKind: String, Codable, Sendable, Hashable {
    /// Has it.
    case holder
    /// Asks for it; devices that have it show "Allow <device> to use your sign-ins?".
    case requested
    /// A device that has it said no.
    case denied
    /// A device wrapped it to this one, which hasn't opened it yet.
    case granted
}

/// One of the account's devices (`devices:list`).
public struct SyncDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: DeviceID
    public var name: String
    public var platform: DevicePlatform
    public var model: String
    public var appVersion: String
    public var createdAt: ServerMillis
    public var lastSeenAt: ServerMillis
    /// nil only for devices from before accounts.
    public var keyState: KeyStateKind?
    /// Its X25519 public key (base64). Holders wrap the vault key to it.
    public var publicKey: String?
    /// Its verification exchange, while it asks for the vault key.
    public var exchange: KeyExchangeRow?

    public init(id: DeviceID, name: String, platform: DevicePlatform, model: String, appVersion: String,
                createdAt: ServerMillis, lastSeenAt: ServerMillis, keyState: KeyStateKind? = nil, publicKey: String? = nil,
                exchange: KeyExchangeRow? = nil) {
        self.id = id
        self.name = name
        self.platform = platform
        self.model = model
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.keyState = keyState
        self.publicKey = publicKey
        self.exchange = exchange
    }

    /// Seen in the last 90 s (`SyncLimits.onlineWindow`), judged on the server clock.
    public func isOnline(serverNow: ServerMillis) -> Bool {
        serverNow - lastSeenAt < SyncLimits.onlineWindow * 1000
    }
}

/// A device's verification exchange as the server relays it (`devices:list`). Every field is public. Devices never
/// trust it for anything but transport: each keeps its own record of what it sent and first received.
public enum KeyExchangeRow: Codable, Sendable, Hashable {
    /// The asking device committed to a secret nonce.
    case committed(commitment: String)
    /// A holder answered with its device key and a nonce of its own.
    case answered(commitment: String, holder: DeviceID, holderKey: String, holderNonce: String)
    /// The asking device revealed its nonce.
    case revealed(commitment: String, holder: DeviceID, holderKey: String, holderNonce: String, nonce: String)

    public var commitment: String {
        switch self {
        case .committed(let c), .answered(let c, _, _, _), .revealed(let c, _, _, _, _): c
        }
    }

    /// The holder's answer, once there is one.
    public var answer: (holder: DeviceID, holderKey: String, holderNonce: String)? {
        switch self {
        case .committed: nil
        case .answered(_, let h, let k, let n), .revealed(_, let h, let k, let n, _): (h, k, n)
        }
    }

    public var revealedNonce: String? { if case .revealed(_, _, _, _, let nonce) = self { nonce } else { nil } }

    private enum CodingKeys: String, CodingKey { case phase, commitment, holder, holderKey, holderNonce, nonce }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let commitment = try c.decode(String.self, forKey: .commitment)
        switch try c.decode(String.self, forKey: .phase) {
        case "committed":
            self = .committed(commitment: commitment)
        case "answered":
            self = .answered(commitment: commitment, holder: try c.decode(DeviceID.self, forKey: .holder),
                             holderKey: try c.decode(String.self, forKey: .holderKey), holderNonce: try c.decode(String.self, forKey: .holderNonce))
        case "revealed":
            self = .revealed(commitment: commitment, holder: try c.decode(DeviceID.self, forKey: .holder),
                             holderKey: try c.decode(String.self, forKey: .holderKey), holderNonce: try c.decode(String.self, forKey: .holderNonce),
                             nonce: try c.decode(String.self, forKey: .nonce))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .phase, in: c, debugDescription: "unknown exchange phase \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commitment, forKey: .commitment)
        switch self {
        case .committed:
            try c.encode("committed", forKey: .phase)
        case .answered(_, let holder, let key, let nonce):
            try c.encode("answered", forKey: .phase)
            try c.encode(holder, forKey: .holder)
            try c.encode(key, forKey: .holderKey)
            try c.encode(nonce, forKey: .holderNonce)
        case .revealed(_, let holder, let key, let holderNonce, let nonce):
            try c.encode("revealed", forKey: .phase)
            try c.encode(holder, forKey: .holder)
            try c.encode(key, forKey: .holderKey)
            try c.encode(holderNonce, forKey: .holderNonce)
            try c.encode(nonce, forKey: .nonce)
        }
    }
}

public enum SyncLimits {
    public static let onlineWindow: TimeInterval = 90
    public static let queueBefore = 20
    public static let queueAfter = 100
    public static let commandTTL: TimeInterval = 120
    /// A paused device is suggested for "Continue from …" this long after it paused.
    public static let continueWindow: TimeInterval = 30 * 60
}

/// Where playback is, as an anchor: `positionMs` was true at server time `positionAt`.
public struct PlaybackAnchor: Codable, Sendable, Hashable {
    public var positionMs: Double
    public var positionAt: ServerMillis
    public var isPlaying: Bool
    public var rate: Double
    public var durationMs: Double?
    public var volume: Double
    public var shuffle: Bool
    public var `repeat`: RepeatMode

    public init(positionMs: Double, positionAt: ServerMillis, isPlaying: Bool, rate: Double = 1, durationMs: Double?, volume: Double, shuffle: Bool, repeat: RepeatMode) {
        self.positionMs = positionMs
        self.positionAt = positionAt
        self.isPlaying = isPlaying
        self.rate = rate
        self.durationMs = durationMs
        self.volume = volume
        self.shuffle = shuffle
        self.repeat = `repeat`
    }

    /// Live position in seconds at server time `serverNow`, clamped to the track's length.
    public func position(atServerTime serverNow: ServerMillis) -> TimeInterval {
        var ms = positionMs
        if isPlaying { ms += max(0, serverNow - positionAt) * rate }
        if let durationMs, durationMs > 0 { ms = min(ms, durationMs) }
        return max(0, ms) / 1000
    }
}

/// One device's published playback (`playback:list`), opened. The anchor (where and how it plays) is always there;
/// what plays is there only when the device published it sealed under a key this device holds. Otherwise `track`,
/// `index` and `queueLength` are nil and `content` says why: show "Playing on Riley's Mac · 2:13" without a title.
public struct RemotePlayback: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        /// Opened with this device's key.
        case open
        /// Sealed under a key this device doesn't hold (it has none yet, or the blob is under a retired key).
        case sealed
        /// The device publishes no content (it has no key).
        case none
    }

    public var deviceId: DeviceID
    public var track: Track?
    /// Index of `track` within the device's queue window.
    public var index: Int?
    public var queueLength: Int?
    public var queueVersion: Int
    public var anchor: PlaybackAnchor
    public var updatedAt: ServerMillis
    public var content: Content

    public init(deviceId: DeviceID, track: Track?, index: Int?, queueLength: Int?, queueVersion: Int, anchor: PlaybackAnchor,
                updatedAt: ServerMillis, content: Content? = nil) {
        self.deviceId = deviceId
        self.track = track
        self.index = index
        self.queueLength = queueLength
        self.queueVersion = queueVersion
        self.anchor = anchor
        self.updatedAt = updatedAt
        self.content = content ?? (track == nil ? .none : .open)
    }
}

extension RemotePlayback {
    /// "Title · Artist" when this device can read what plays there; nil while it's sealed from this device (show only
    /// the device, its state and position: "Playing on Riley's Mac · 2:13").
    public var trackLine: String? { track.map { "\($0.title) · \($0.artistLine)" } }
}

extension DevicePlatform {
    /// Whether the app on it sets its own volume from a remote command. iPhones (and Android phones) play at the system
    /// volume, which apps can't set.
    public var takesVolumeCommands: Bool {
        switch self {
        case .mac, .windows, .linux: true
        case .ios, .android, .unknown: false
        }
    }
}

/// A playback row as the server has it (`playback:list`).
struct PlaybackRow: Decodable, Sendable, Hashable {
    var deviceId: DeviceID
    /// `PlaybackContent`, sealed (kind `playback`); nil from a device without the key.
    var content: SealedContent?
    var queueVersion: Int
    var anchor: PlaybackAnchor
    var updatedAt: ServerMillis
}

/// A queue window: up to 20 entries before the current one and 100 after it.
public struct QueueWindow: Codable, Sendable, Hashable {
    public var entries: [QueueEntry]
    public var index: Int

    public init(entries: [QueueEntry], index: Int) {
        self.entries = entries
        self.index = index
    }

    /// The window of `queue` around `current`.
    public init?(queue: [QueueEntry], current: Int?) {
        guard let current, queue.indices.contains(current) else { return nil }
        let start = max(0, current - SyncLimits.queueBefore)
        let end = min(queue.count, current + 1 + SyncLimits.queueAfter)
        entries = Array(queue[start..<end])
        index = current - start
    }

    public var current: QueueEntry { entries[index] }
}

/// What `takeOver` carries: everything needed to continue playback elsewhere.
public struct HandoffState: Codable, Sendable, Hashable {
    public var queue: [QueueEntry]
    public var index: Int
    public var anchor: PlaybackAnchor

    public init(queue: [QueueEntry], index: Int, anchor: PlaybackAnchor) {
        self.queue = queue
        self.index = index
        self.anchor = anchor
    }

    public init(window: QueueWindow, anchor: PlaybackAnchor) {
        self.init(queue: window.entries, index: window.index, anchor: anchor)
    }
}

public enum SyncCommand: Sendable, Hashable {
    case play
    case pause
    case toggle
    case next
    case previous
    case stop
    case seek(positionMs: Double)
    /// 0...1
    case setVolume(Double)
    case takeOver(HandoffState)

    public enum Kind: String, Codable, Sendable, Hashable {
        case play, pause, toggle, next, previous, stop, seek, setVolume, takeOver
    }

    public var kind: Kind {
        switch self {
        case .play: .play
        case .pause: .pause
        case .toggle: .toggle
        case .next: .next
        case .previous: .previous
        case .stop: .stop
        case .seek: .seek
        case .setVolume: .setVolume
        case .takeOver: .takeOver
        }
    }
}

/// A command as it travels (`commands:send`, `commands:incoming`). Every kind but `takeOver` carries only numbers; a
/// takeover's queue window is sealed (kind `command`, the target device in the authenticated data), its anchor not.
enum WireCommand: Codable, Sendable, Hashable {
    case plain(SyncCommand)
    case takeOver(anchor: PlaybackAnchor, content: SealedContent)

    private enum CodingKeys: String, CodingKey { case kind, positionMs, volume, anchor, content }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(SyncCommand.Kind.self, forKey: .kind) {
        case .play: self = .plain(.play)
        case .pause: self = .plain(.pause)
        case .toggle: self = .plain(.toggle)
        case .next: self = .plain(.next)
        case .previous: self = .plain(.previous)
        case .stop: self = .plain(.stop)
        case .seek: self = .plain(.seek(positionMs: try c.decode(Double.self, forKey: .positionMs)))
        case .setVolume: self = .plain(.setVolume(try c.decode(Double.self, forKey: .volume)))
        case .takeOver: self = .takeOver(anchor: try c.decode(PlaybackAnchor.self, forKey: .anchor), content: try c.decode(SealedContent.self, forKey: .content))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .takeOver(let anchor, let content):
            try c.encode(SyncCommand.Kind.takeOver, forKey: .kind)
            try c.encode(anchor, forKey: .anchor)
            try c.encode(content, forKey: .content)
        case .plain(let command):
            try c.encode(command.kind, forKey: .kind)
            switch command {
            case .seek(let ms): try c.encode(ms, forKey: .positionMs)
            case .setVolume(let v): try c.encode(v, forKey: .volume)
            case .play, .pause, .toggle, .next, .previous, .stop: break
            // Never sent in the clear: `SyncService.send` seals it first.
            case .takeOver: throw EncodingError.invalidValue(command, .init(codingPath: c.codingPath, debugDescription: "a takeover is sealed"))
            }
        }
    }
}

/// Why a command failed, from a fixed list (the server takes no free text). A message with details, which may name a
/// song, travels sealed beside it, and only from a device that holds the key.
public enum CommandFailure: String, Codable, Sendable, Hashable {
    case expired, unavailable, nothingToPlay, needsKey, unreadable, providerUnavailable, playbackFailed, failed

    /// What the sender shows when no sealed message came (or it didn't open there). `device` is the target's name.
    public func message(device: String) -> String {
        switch self {
        case .expired: "The command expired before it reached \(device)."
        case .unavailable: "\(device) can't run commands right now."
        case .nothingToPlay: "Nothing is loaded on \(device)."
        case .needsKey: "\(device) doesn't have your sign-in key yet. Allow it on a device that has your sign-ins, then try again."
        case .unreadable: "\(device) couldn't open what this device sent. Try again in a moment."
        case .providerUnavailable: "That service isn't signed in on \(device)."
        case .playbackFailed: "\(device) couldn't play it."
        case .failed: "That didn't work on \(device)."
        }
    }
}

/// What a command did. On the wire a failure is its `reason` plus, from a device holding the key, its `message` sealed.
public struct CommandResult: Sendable, Hashable {
    public var ok: Bool
    public var message: String?
    /// Why it failed (nil on success).
    public var reason: CommandFailure?

    public init(ok: Bool, message: String? = nil, reason: CommandFailure? = nil) {
        self.ok = ok
        self.message = message
        self.reason = ok ? nil : (reason ?? .failed)
    }

    public static let success = CommandResult(ok: true)
    public static func failure(_ message: String, reason: CommandFailure = .failed) -> CommandResult {
        CommandResult(ok: false, message: message, reason: reason)
    }
}

/// A result as it travels (`commands:ack`, `commands:outgoing`).
struct WireResult: Codable, Sendable, Hashable {
    var ok: Bool
    var reason: CommandFailure?
    /// `ResultContent`, sealed (kind `result`, the command id in the authenticated data).
    var content: SealedContent?
}

/// A command waiting for this device (`commands:incoming`), opened.
public struct IncomingCommand: Sendable, Hashable, Identifiable {
    public var id: CommandID
    public var fromDeviceId: DeviceID
    public var command: SyncCommand
    public var createdAt: ServerMillis
    public var expiresAt: ServerMillis

    public init(id: CommandID, fromDeviceId: DeviceID, command: SyncCommand, createdAt: ServerMillis, expiresAt: ServerMillis) {
        self.id = id
        self.fromDeviceId = fromDeviceId
        self.command = command
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

struct WireIncomingCommand: Decodable, Sendable {
    var id: CommandID
    var fromDeviceId: DeviceID
    var command: WireCommand
    var createdAt: ServerMillis
    var expiresAt: ServerMillis
}

struct WireOutgoingCommand: Decodable, Sendable {
    var id: CommandID
    var toDeviceId: DeviceID
    var kind: SyncCommand.Kind
    var createdAt: ServerMillis
    var expiresAt: ServerMillis
    var ackedAt: ServerMillis?
    var result: WireResult?
}

/// A command this device sent (`commands:outgoing`), and whether it was acked.
public struct OutgoingCommand: Sendable, Hashable, Identifiable {
    public var id: CommandID
    public var toDeviceId: DeviceID
    public var kind: SyncCommand.Kind
    public var createdAt: ServerMillis
    public var expiresAt: ServerMillis
    public var ackedAt: ServerMillis?
    public var result: CommandResult?
}

// MARK: - Function argument and result shapes

struct TokenArgs: Encodable, Sendable { var token: String }
struct ServerNowResult: Decodable, Sendable { var serverNow: ServerMillis }

struct RegisterArgs: Encodable, Sendable {
    var token: String
    var device: DeviceInfo
    var publicKey: String
    /// The vault key fingerprint this device proposes: an account without a key adopts it.
    var keyId: String?
    /// When the device made this registration (ms since 1970, its clock): the same in every attempt. The server
    /// refuses one older than it remembers removed tokens for.
    var createdAt: Double
}
struct RegisterResult: Decodable, Sendable {
    var deviceId: DeviceID
    var libraryId: LibraryID
    var keyId: String?
    var keyState: KeyStateKind
    /// The account's key revision this answer reflects (absent from older servers).
    var keyRevision: Int?
    var serverNow: ServerMillis
}
/// `account:unregister`: removes the device a token names, for a device that never learned its id.
/// `account:unregister`. `cancelled`: the server recorded the withdrawal, so no copy of that registration can land
/// later (absent from older servers, which don't record it).
struct UnregisterResult: Decodable, Sendable {
    var removed: Bool
    var cancelled: Bool?
    var serverNow: ServerMillis

    /// Whether the token's registration is settled for good: removed, or refused from now on.
    var settled: Bool { removed || cancelled == true }
}
/// `keys:claim`: the fresh key and the key revision of the state in which this device saw no key. The server refuses
/// the claim (`conflict`) if the revision moved since, so it can't land later on a state the device never saw.
struct ClaimKeyArgs: Encodable, Sendable {
    var token: String
    var keyId: String
    /// Required by the server.
    var keyRevision: Int
}
/// `keys:claim` and `keys:rotate` answer with the account's key revision after the change (absent from older servers).
struct ClaimKeyResult: Decodable, Sendable { var keyId: String; var keyRevision: Int?; var serverNow: ServerMillis }
struct RotateKeyResult: Decodable, Sendable { var keyRevision: Int?; var serverNow: ServerMillis }
struct GrantKeyArgs: Encodable, Sendable { var token: String; var deviceId: DeviceID; var keyId: String; var wrapped: String; var commitment: String }
struct AcceptKeyArgs: Encodable, Sendable { var token: String; var keyId: String }
/// `keys:release`: the key this device gives up, and what it examined before deciding (the account's key and the
/// rotated key waiting on its row, each nil for none), which the server compares with its state now.
struct ReleaseKeyArgs: Encodable, Sendable {
    var token: String
    var keyId: String
    var accountKeyId: String?
    var rekeyKeyId: String?
    /// The account's key revision in the state it examined; the server refuses the release if it moved since. Required.
    var keyRevision: Int

    enum CodingKeys: String, CodingKey { case token, keyId, accountKeyId, rekeyKeyId, keyRevision }

    // The nil fields are sent as null: the server requires them.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(accountKeyId, forKey: .accountKeyId)
        try container.encode(rekeyKeyId, forKey: .rekeyKeyId)
        try container.encode(keyRevision, forKey: .keyRevision)
    }
}
struct RequestKeyArgs: Encodable, Sendable { var token: String; var commitment: String }
struct AnswerKeyArgs: Encodable, Sendable { var token: String; var deviceId: DeviceID; var commitment: String; var nonce: String }
struct RevealKeyArgs: Encodable, Sendable { var token: String; var commitment: String; var nonce: String }
struct RotateKeyArgs: Encodable, Sendable {
    struct Wrap: Encodable, Sendable { var deviceId: DeviceID; var wrapped: String }
    struct Reseal: Encodable, Sendable {
        var provider: ProviderID
        var baseRevision: Int
        /// nil for a row the rotating device couldn't open; it is sent as null (the field is required).
        var sealed: String?

        enum CodingKeys: String, CodingKey { case provider, baseRevision, sealed }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider)
            try c.encode(baseRevision, forKey: .baseRevision)
            try c.encode(sealed, forKey: .sealed)
        }
    }
    /// A settings row re-sealed under the new key, at the time it was read (nil: it didn't open; the row goes).
    struct ResealSetting: Encodable, Sendable {
        var key: String
        var baseUpdatedAt: ServerMillis
        var value: SealedContent?

        enum CodingKeys: String, CodingKey { case key, baseUpdatedAt, value }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(baseUpdatedAt, forKey: .baseUpdatedAt)
            try c.encode(value, forKey: .value)
        }
    }
    var token: String
    var fromKeyId: String
    var keyId: String
    var wraps: [Wrap]
    var vault: [Reseal]
    var settings: [ResealSetting]
}

struct VaultPutArgs: Encodable, Sendable { var token: String; var provider: ProviderID; var sealed: String; var keyId: String; var baseRevision: Int }
struct VaultSignOutArgs: Encodable, Sendable { var token: String; var provider: ProviderID; var baseRevision: Int }
struct UpdatedResult: Decodable, Sendable { var updatedAt: ServerMillis; var serverNow: ServerMillis }
struct VaultWriteResult: Decodable, Sendable { var updatedAt: ServerMillis; var revision: Int; var serverNow: ServerMillis }
struct SettingPutArgs: Encodable, Sendable { var token: String; var key: String; var value: SealedContent; var writeId: String?; var ifAbsent: Bool? }
/// The vault key wrapped to this device by `fromDeviceId`, waiting for this device to open and accept it.
struct KeyGrantRow: Decodable, Sendable, Equatable {
    var keyId: String
    var wrapped: String
    var fromDeviceId: DeviceID
    /// The exchange it came out of (nil on grants from before the exchange, which can't be opened).
    var commitment: String?
}

/// A rotated vault key wrapped to this device (a holder), made with the key it replaces.
struct RekeyRow: Decodable, Sendable, Equatable {
    var keyId: String
    var fromKeyId: String
    var wrapped: String
    var fromDeviceId: DeviceID
}

struct DeviceListResult: Decodable, Sendable {
    var selfId: DeviceID
    var libraryId: LibraryID
    var keyId: String?
    /// A device that could open the vault left; a holder must replace the key.
    var rotationNeeded: Bool?
    /// The account's key revision (`libraries.keyRevision`): it grows with every change to the key state, so a list
    /// older than one already applied is recognised and ignored. Absent from older servers (treated as 0).
    var keyRevision: Int?
    var devices: [SyncDevice]
    var grant: KeyGrantRow?
    var rekey: RekeyRow?
}

struct RenameArgs: Encodable, Sendable { var token: String; var deviceId: DeviceID; var name: String }
struct DeviceArgs: Encodable, Sendable { var token: String; var deviceId: DeviceID }
/// `keys:deny`: the exchange the holder's listener answered.
struct DenyKeyArgs: Encodable, Sendable { var token: String; var deviceId: DeviceID; var commitment: String }

/// `playback:publish`. `content`: what plays, sealed (`replace`), none because this device has no key (`drop`, sent as
/// null), or unchanged (`keep`, left out).
struct PublishArgs: Encodable, Sendable {
    enum Content: Sendable {
        case keep
        case drop
        case replace(playback: SealedContent, queue: SealedContent)
    }
    var token: String
    var anchor: PlaybackAnchor
    var content: Content

    private enum CodingKeys: String, CodingKey { case token, anchor, content }
    private struct Sealed: Encodable { var playback: SealedContent; var queue: SealedContent }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(anchor, forKey: .anchor)
        switch content {
        case .keep: break
        case .drop: try c.encodeNil(forKey: .content)
        case .replace(let playback, let queue): try c.encode(Sealed(playback: playback, queue: queue), forKey: .content)
        }
    }
}
struct PublishResult: Decodable, Sendable {
    var serverNow: ServerMillis
    var positionAt: ServerMillis
    var queueVersion: Int
}

struct QueueResult: Decodable, Sendable {
    /// A `QueueWindow`, sealed (kind `queue`).
    var content: SealedContent
    var version: Int
}

struct SendCommandArgs: Encodable, Sendable {
    var token: String
    var toDeviceId: DeviceID
    var command: WireCommand
    /// Unique per command, so a send retried over another transport is stored once.
    var clientId: String
}
struct SendCommandResult: Decodable, Sendable { var commandId: CommandID; var expiresAt: ServerMillis; var serverNow: ServerMillis }
struct AckArgs: Encodable, Sendable { var token: String; var commandId: CommandID; var result: WireResult }

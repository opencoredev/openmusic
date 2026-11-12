import Foundation
import MedleyCore

/// Everything sync reports to the UI. Messages are written to be shown as they are.
public enum SyncError: LocalizedError, Sendable, Equatable {
    /// Not signed in to an account on this device (or not registered with it yet).
    case notPaired
    /// The sync server needs a sign-in: the Clerk session ended or its token was refused.
    case notSignedIn
    /// This device was removed from the account's devices (its token no longer works). The app signs out.
    case removedFromLibrary
    case signInTransferFailed(String)
    /// The vault key this device holds isn't the account's.
    case libraryKeyMismatch
    /// A vault key grant couldn't be made or opened.
    case keyGrantFailed(String)
    case unknownDevice
    case deviceOffline(String)
    case nothingPlaying(String)
    /// The track's service can't play on this device (not signed in, or not available).
    case providerUnavailable(ProviderID, deviceName: String?)
    case playbackFailed(String)
    case commandFailed(String)
    case timedOut(String)
    /// Moving playback needs the account's sign-in key on both devices: what plays is sealed with it. `device` is the
    /// device that lacks it; nil means this one.
    case needsKey(device: String?)
    case server(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired: "Sign in to sync this device with your others."
        case .notSignedIn: "Your sign-in expired. Sign in again to sync."
        case .removedFromLibrary: "This device was removed from your devices. Sign in again to sync."
        case .signInTransferFailed(let why): "Your sign-ins couldn't be synced: \(why)."
        case .libraryKeyMismatch: "This device's sign-in key isn't your account's."
        case .keyGrantFailed(let why): "Your sign-ins couldn't be shared with this device: \(why)."
        case .unknownDevice: "That device isn't in your devices any more."
        case .deviceOffline(let name): "\(name) isn't online."
        case .nothingPlaying(let name): "Nothing is playing on \(name)."
        case .providerUnavailable(let provider, let device):
            if let device { "\(provider.displayName) isn't signed in on \(device)." }
            else { "\(provider.displayName) isn't signed in on this device." }
        case .playbackFailed(let why): "Couldn't start playback: \(why)"
        case .commandFailed(let why): why
        case .timedOut(let what): "\(what) didn't respond in time."
        case .needsKey(let device):
            if let device { "\(device) doesn't have your sign-in key yet, so it can't take over playback. Allow it on a device that has your sign-ins first." }
            else { "This device doesn't have your sign-in key yet, so it can't see or continue what plays elsewhere. Allow it on a device that has your sign-ins first." }
        case .server(let why): why
        case .network(let why): why
        }
    }

    static func from(_ error: any Error) -> SyncError {
        if let sync = error as? SyncError { return sync }
        if let convex = error as? ConvexClientError {
            switch convex.code {
            case "unauthorized": return .removedFromLibrary
            case "unauthenticated": return .notSignedIn
            case "notFound": return .unknownDevice
            default: break
            }
            switch convex {
            case .transport, .stopped, .authChanged: return .network(convex.localizedDescription)
            default: return .server(convex.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }
}

import Foundation
import OpenMusicCore

/// The short reason a failure notice gives after "Couldn't …": never the error's own text, which can be a server
/// code or a response body. Also says whether a second attempt could work, which decides the Try Again button.
struct FailureReason: Equatable {
    let text: String
    let isRecoverable: Bool

    /// `write`: the action changed something on the service (a like, a playlist edit), so a refusal reads as the
    /// service not accepting the change. `service` names it when known.
    init(_ error: any Error, write: Bool = false, service: ProviderID? = nil) {
        let name = service?.displayName ?? "The service"
        let refused = write ? "\(name) didn’t accept the change." : "\(name) didn’t respond as expected."
        switch error {
        case let error as ProviderError:
            switch error {
            case .notSignedIn: self.init("Sign in to do this.", recoverable: false)
            case .rateLimited: self.init("Try again in a moment.", recoverable: true)
            case .network(let message): self = Self.network(offline: Self.offlineMessages.contains(message), service: name)
            case .notFound: self.init("It’s no longer available.", recoverable: false)
            case .notSupported: self.init("\(name) doesn’t support this.", recoverable: false)
            case .unplayable: self.init("This song can’t be played.", recoverable: false)
            case .server(let code, _) where (500..<600).contains(code): self.init(refused, recoverable: true)
            case .server, .decoding: self.init(refused, recoverable: write)
            }
        case PlaylistEditError.accountChanged:
            // Nothing was sent: the credentials it would have gone out with were another account's by then.
            self.init("Your \(name) sign-in was changing.", recoverable: true)
        case PlaylistEditError.unidentifiedCopies:
            // Nothing was written: the service listed a copy it gave no way to remove.
            self.init("\(name) didn’t say how to remove every copy, so nothing was removed.", recoverable: false)
        case is PlaylistSignInChanging:
            // Nothing was sent: the sign-in was being swapped, so the request might have gone out as another account.
            self.init("Your \(name) sign-in was changing.", recoverable: true)
        case is PlaylistReadIncomplete:
            self.init("\(name) didn’t list the whole playlist.", recoverable: true)
        case let error as URLError:
            self = Self.network(offline: Self.offlineCodes.contains(error.code), service: name)
        default:
            self.init(write ? refused : "Try again in a moment.", recoverable: true)
        }
    }

    private init(_ text: String, recoverable: Bool) {
        self.text = text
        self.isRecoverable = recoverable
    }

    private static func network(offline: Bool, service: String) -> FailureReason {
        FailureReason(offline ? "You’re offline." : "\(service) can’t be reached.", recoverable: true)
    }

    /// URLSession codes that mean this Mac has no connection (not that the service is down).
    private static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]

    /// `HTTP` wraps transport errors as `ProviderError.network(localizedDescription)`; these are the texts of
    /// `offlineCodes`, so an offline Mac still reads as offline after the wrapping.
    private static let offlineMessages: Set<String> = Set(offlineCodes.map { URLError($0).localizedDescription })
}

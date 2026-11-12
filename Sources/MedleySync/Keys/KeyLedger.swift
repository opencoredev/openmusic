import Foundation
import MedleyCore

/// What this device recorded of its key exchanges, in the credential store (`sync.credentials.state.keys.v1`) for
/// one deployment, library and device. Each side of an exchange keeps its own copy of what it sent and what it
/// first received, and computes the code from that, never from what the server shows later. Nothing here is
/// secret beyond an asking device's nonce before it reveals it, which the credential store keeps like the rest.
struct KeyLedger: Codable, Equatable {
    /// Which deployment, library and device this belongs to.
    var scope: String?
    /// This device's own request for the key (while it has none).
    var attempt: Attempt?
    /// Answers this device gave as a holder, by the asking device's commitment.
    var answers: [String: Answer] = [:]
    /// Failed or refused exchanges, on either side, for the warning and the pause.
    var failures: [Failure] = []
    /// When this device started requests by itself (not the listener's Ask Again), for its own limit.
    var automaticAttempts: [Date] = []

    struct Attempt: Codable, Equatable {
        /// The secret this device committed to. Revealed only after a holder answered.
        var nonce: Data
        var commitment: String
        var startedAt: Date
        /// The answer as this device first received it. A different answer shown later is ignored.
        var answer: Answered?
        var revealed = false
        /// The listener tapped Codes Match here.
        var confirmed = false
        /// Set when the attempt is over without a key.
        var outcome: Outcome?
    }

    struct Answered: Codable, Equatable {
        var holder: DeviceID
        var holderKey: String
        var holderNonce: Data
    }

    enum Outcome: String, Codable, Equatable {
        case codesDidNotMatch, grantDidNotOpen, tooManyAttempts
    }

    struct Answer: Codable, Equatable {
        var device: DeviceID
        /// The asking device's public key when this device answered (the commitment covers it).
        var recipientKey: String
        var nonce: Data
        var at: Date
        var sent = false
        /// The nonce the asking device revealed, once it matched its commitment.
        var revealedNonce: Data?
        var state: AnswerState = .waiting
    }

    enum AnswerState: String, Codable, Equatable {
        /// Answered; the asking device hasn't revealed its nonce yet.
        case waiting
        /// The revealed nonce matches the commitment: the listener is asked.
        case verified
        /// The revealed nonce (or this device's own nonce, as relayed) doesn't match: refused.
        case tampered
        case allowed, denied
    }

    struct Failure: Codable, Equatable {
        var at: Date
        var kind: FailureKind
    }

    enum FailureKind: String, Codable, Equatable {
        /// An exchange this device answered didn't check out (someone changed it on the way).
        case tampered
        /// The listener tapped Don't Allow here.
        case denied
        /// The listener said the codes didn't match here.
        case codesDidNotMatch
        /// A grant or rotated key that should have opened here didn't.
        case didNotOpen
    }

    static let stateName = "keys.v1"

    func failures(since date: Date) -> [Failure] { failures.filter { $0.at >= date } }

    /// Drops what is too old to matter for any limit or warning.
    mutating func prune(now: Date) {
        let day = now.addingTimeInterval(-24 * 3600)
        failures.removeAll { $0.at < day }
        automaticAttempts.removeAll { $0 < day }
        answers = answers.filter { $0.value.at >= day }
    }
}

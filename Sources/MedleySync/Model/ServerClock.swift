import Foundation

/// Estimates the server clock from `serverNow` in mutation results.
///
/// Each sample assumes the server stamped `serverNow` halfway through the round trip, so its error is at most
/// half the round trip. The estimate uses the sample with the shortest round trip among the last few, which
/// rejects samples slowed by a busy network, and keeps following drift as old samples fall out.
public struct ServerClock: Sendable, Hashable {
    public struct Sample: Sendable, Hashable {
        /// server - local, in ms.
        public var offsetMs: Double
        public var roundTripMs: Double
    }

    public private(set) var samples: [Sample] = []
    public static let maxSamples = 8

    public init() {}

    /// server - local in ms; 0 until the first sample.
    public var offsetMs: Double {
        samples.min { $0.roundTripMs < $1.roundTripMs }?.offsetMs ?? 0
    }

    public var hasSample: Bool { !samples.isEmpty }

    public mutating func record(serverNow: ServerMillis, sentAt: Date, receivedAt: Date) {
        let sent = sentAt.timeIntervalSince1970 * 1000
        let received = receivedAt.timeIntervalSince1970 * 1000
        let roundTrip = max(0, received - sent)
        samples.append(Sample(offsetMs: serverNow - (sent + received) / 2, roundTripMs: roundTrip))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    /// The server time now (ms).
    public func now(_ local: Date = Date()) -> ServerMillis {
        local.timeIntervalSince1970 * 1000 + offsetMs
    }

    /// The local `Date` of a server time.
    public func localDate(_ server: ServerMillis) -> Date {
        Date(timeIntervalSince1970: (server - offsetMs) / 1000)
    }
}

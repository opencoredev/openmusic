/// Key requests the listener closed without answering ("Don't Allow", or the alert closed), so the "Allow …?" alert
/// doesn't come straight back for them. Each is remembered by its exchange, not only its device: when that device
/// asks again (Ask Again, a new commitment), the alert shows the new request.
public struct DismissedKeyRequests: Sendable, Equatable {
    private var exchanges: [DeviceID: String] = [:]

    public init() {}

    /// This request's alert was closed.
    public mutating func dismiss(_ request: SyncService.KeyRequest) { exchanges[request.id] = request.commitment }

    /// The listener asked to see `device`'s request again (Settings › Account's Allow).
    public mutating func show(_ device: DeviceID) { exchanges[device] = nil }

    public mutating func removeAll() { exchanges = [:] }

    public func contains(_ request: SyncService.KeyRequest) -> Bool { exchanges[request.id] == request.commitment }

    /// The first request whose alert wasn't closed.
    public func firstShown(in requests: [SyncService.KeyRequest]) -> SyncService.KeyRequest? {
        requests.first { !contains($0) }
    }
}

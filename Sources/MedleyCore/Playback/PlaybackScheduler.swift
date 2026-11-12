import Foundation

/// A cancellable one-shot action created by a `PlaybackScheduler`.
@MainActor
public final class ScheduledAction {
    private var onCancel: (() -> Void)?

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// Clock and one-shot timers for the player (sleep timer, persistence debounce).
/// Injected so tests can drive time by hand. Nothing here polls: every action is a single deadline.
@MainActor
public protocol PlaybackScheduler: AnyObject {
    var now: Date { get }
    /// Runs `action` on the main actor once, `delay` seconds from now, unless cancelled first.
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ScheduledAction
}

/// The production scheduler: wall clock plus one `Task.sleep` per scheduled action.
@MainActor
public final class SystemScheduler: PlaybackScheduler {
    public init() {}

    public var now: Date { Date() }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ScheduledAction {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            action()
        }
        return ScheduledAction { task.cancel() }
    }
}

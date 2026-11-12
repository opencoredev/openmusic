import Foundation

/// The one serial executor for a `SyncService`'s account and key operations: sign-in, sign-out, registration,
/// applying a device list, claims, releases, rotations, grants and their answers, Ask Again, removing a device.
///
/// An operation runs to completion, awaits included, before the next one starts, so no operation ever sees another
/// one's half-done state: a stale answer can't resume in the middle of a newer operation and act on state that
/// operation changed. Operations run in the order they were enqueued.
///
/// Every operation holds a `Ticket` with the epoch it was enqueued in. A sign-in, a sign-out, `forget()` and
/// `stop()` start a new epoch (`supersede`): operations of the old epoch that haven't run yet never run their
/// bodies, and the running one is cancelled (its pending calls end with `CancellationError`) and stops at its next
/// `check()`. A sign-out is the exception: it is never cancelled once enqueued, because it is what removes this
/// device from the account; whatever comes after it waits for it.
///
/// Rules for code running inside an operation:
/// - after every await, call `ticket.check()` before touching state (the calls in `SyncService` that take a ticket
///   do it for you);
/// - never wait for another operation: `run` called from inside the running operation runs the body inline, as part
///   of it, instead of deadlocking on itself; follow-up work is `enqueue`d and runs after.
@MainActor
final class AccountOperations {
    /// What an operation was enqueued for. A ticket stops being valid when a newer epoch starts, unless it is immune
    /// (a sign-out).
    struct Ticket: Sendable {
        let epoch: Int
        let immune: Bool
        fileprivate let operations: ObjectIdentifier

        /// Throws `CancellationError` once this operation was superseded (or its task cancelled).
        @MainActor func check(_ queue: AccountOperations) throws {
            if immune { return }
            guard epoch == queue.epoch, !Task.isCancelled else { throw CancellationError() }
        }

        @MainActor func isValid(_ queue: AccountOperations) -> Bool { (try? check(queue)) != nil }
    }

    /// Bumped by `supersede`. Operations of an older epoch never run.
    private(set) var epoch = 0
    /// The end of the queue: the next operation starts once this opens (its operation finished, or was abandoned).
    private var tail: Latch?
    /// The latch of every operation queued or running.
    private var latches: [Int: Latch] = [:]
    /// The operation running now, and whether it can be cancelled.
    private var running: (serial: Int, immune: Bool)?
    /// The task of every operation queued or running.
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var serial = 0
    /// Ids of enqueued operations not finished yet, so one isn't queued twice.
    private var pendingIDs: Set<String> = []
    /// Completed operations, for tests.
    private(set) var completed = 0

    @TaskLocal static var current: Int?

    init() {}

    /// A ticket for an operation enqueued now, in the current epoch.
    func ticket() -> Ticket { Ticket(epoch: epoch, immune: false, operations: ObjectIdentifier(self)) }

    /// Starts a new epoch and returns its ticket: everything enqueued before (except a sign-out) won't run, and the
    /// running operation, unless it is a sign-out, is cancelled.
    ///
    /// A cancelled operation is also abandoned: the queue goes on without waiting for it to unwind, since it may be
    /// suspended in an await that doesn't end on cancellation (a token fetch, a request already on the wire). That
    /// is safe because an operation checks its ticket after every await and, superseded, changes nothing more.
    func supersede(immune: Bool = false) -> Ticket {
        epoch += 1
        if let running, !running.immune {
            tasks[running.serial]?.cancel()
            latches[running.serial]?.open()
            self.running = nil
        }
        return Ticket(epoch: epoch, immune: immune, operations: ObjectIdentifier(self))
    }

    /// Whether an operation with this id is queued or running.
    func isPending(_ id: String) -> Bool { pendingIDs.contains(id) }

    /// Whether the caller runs inside the operation running now.
    private var isInsideRunning: Bool {
        guard let current = Self.current, let running else { return false }
        return current == running.serial
    }

    /// Runs `body` as an operation once every earlier one finished, and returns its result. Called from inside the
    /// running operation, it runs `body` at once, as part of that operation, with its ticket.
    func run<T: Sendable>(_ ticket: Ticket? = nil, _ body: @escaping @MainActor (Ticket) async throws -> T) async throws -> T {
        let ticket = ticket ?? self.ticket()
        if isInsideRunning { return try await body(ticket) }
        let box = ResultBox<T>()
        let task = schedule(ticket) { ticket in
            do { box.result = .success(try await body(ticket)) } catch { box.result = .failure(error) }
        }
        await task.value
        guard let result = box.result else { throw CancellationError() }
        return try result.get()
    }

    /// Queues `body` without waiting for it. With an `id`, nothing is queued while an operation with the same id is
    /// still queued or running (`until: .finished`), or still queued (`until: .started`).
    func enqueue(_ id: String? = nil, until: Dedup = .finished, _ body: @escaping @MainActor (Ticket) async -> Void) {
        if let id {
            guard pendingIDs.insert(id).inserted else { return }
        }
        let ticket = self.ticket()
        _ = schedule(ticket) { [weak self] ticket in
            if let id, until == .started { self?.pendingIDs.remove(id) }
            await body(ticket)
            if let id, until == .finished { self?.pendingIDs.remove(id) }
        } skipped: { [weak self] in
            if let id { self?.pendingIDs.remove(id) }
        }
    }

    enum Dedup { case started, finished }

    /// An operation that never awaits (a tap that only moves local state, like Codes Match): run at once when nothing
    /// is queued or running, which is when the queue would run it anyway, else queued after what is there.
    func perform(_ body: @escaping @MainActor () -> Void) {
        if running == nil, tasks.isEmpty { body() } else { enqueue { _ in body() } }
    }

    @discardableResult
    private func schedule(_ ticket: Ticket, _ body: @escaping @MainActor (Ticket) async -> Void,
                          skipped: (@MainActor () -> Void)? = nil) -> Task<Void, Never> {
        let previous = tail
        serial += 1
        let number = serial
        let latch = Latch()
        // A new task doesn't inherit the operation it was enqueued from: it is its own operation. Its body can't
        // start before this function returns (both run on the main actor), so `tasks` has it by then.
        let task = Self.$current.withValue(nil) {
            Task { @MainActor [weak self] in
                await previous?.wait()
                guard let self else { return }
                defer {
                    self.tasks[number] = nil
                    self.latches[number] = nil
                    if self.running?.serial == number { self.running = nil }
                    latch.open()
                }
                guard ticket.isValid(self) else {
                    skipped?()
                    return
                }
                self.running = (number, ticket.immune)
                await Self.$current.withValue(number) {
                    await body(ticket)
                }
                self.completed += 1
            }
        }
        tasks[number] = task
        latches[number] = latch
        tail = latch
        return task
    }

    /// Waits until everything queued now has run (tests).
    func drain() async {
        while let tail {
            await tail.wait()
            if self.tail === tail { return }
        }
    }
}

/// Opens once; everyone waiting, and everyone who waits after, goes on.
@MainActor
final class Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

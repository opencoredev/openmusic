import Foundation
import OpenMusicCore
@testable import OpenMusicSync

/// The account and key functions of the backend (`sync/convex/account.ts`, `keys.ts` and friends), in memory, for
/// several real `SyncService`s talking to it over the HTTP fallback. It models what the review cases need:
///
/// - **Clerk ownership.** Every call names its user by the `sub` of its `Authorization: Bearer` JWT (none:
///   `unauthenticated`). Each user has a library of their own, created by their first registration and gone with their
///   last device; a device token works only for the user whose library has it (`unauthorized` otherwise), so a
///   registration sent with the wrong user's token lands in that user's library, as on the real server.
/// - **Delayed commits.** `delay(_:)` parks the next request to a function: the device gets no answer (a transport
///   error, as a timeout), and the request runs when the test calls `commitDelayed()`, after whatever else happened.
/// - **Key revisions** that move as the backend's do: on every key mutation that succeeds (`keys:request`, `answer`,
///   `reveal`, `grant`, `accept` and `deny` bump even when they change nothing, as the backend does before it looks;
///   a claim or rotation retry and a release by a non-holder don't), on a device joining or leaving, and on test
///   changes.
/// - The server's rules: device tokens are single-use (every removal retires its token, and `account:register`
///   refuses retired and withdrawn tokens for their user; `account:unregister` records withdrawals, rate limited and
///   capped per user, with the backend's limits and expiry; `legacyUnregister` turns all of it off, as on an older
///   server), claims and releases compare-and-swap on the revision the device examined (both required), retired keys
///   never claimed again, claims and rotations answering with the revision after them, and a full library evicting
///   the device seen least recently (`maxDevices`). A registration's `createdAt` is recorded with the call but not
///   checked for age here (the fake's clock isn't the device's); the backend's check is tested in `sync/convex`.
///
/// Tests can also make it misbehave the way a malicious server could: change what one device sees of another's
/// exchange, or set any device's state directly.
final class FakeKeyServer: @unchecked Sendable {
    struct Exchange: Equatable, Sendable {
        var commitment: String
        var holder: String?
        var holderKey: String?
        var holderNonce: String?
        var nonce: String?
    }

    struct Rekey: Equatable, Sendable {
        var keyId: String
        var fromKeyId: String
        var wrapped: String
        var by: String
    }

    enum State: Equatable, Sendable {
        case holder(rekey: Rekey?)
        case requested(Exchange?)
        case denied
        case granted(keyId: String, wrapped: String, by: String, commitment: String)

        var kind: String {
            switch self {
            case .holder: "holder"
            case .requested: "requested"
            case .denied: "denied"
            case .granted: "granted"
            }
        }

        var canOpenVault: Bool { if case .holder = self { true } else if case .granted = self { true } else { false } }
    }

    struct Device: Sendable {
        var id: String
        var name: String
        var token: String
        var publicKey: String
        var state: State
        /// The newest key this device was given (`deviceKeys.exposedKeyId`).
        var exposedKeyId: String?
        /// The Clerk user whose library the device is in.
        var owner: String = ""
        /// When it last made a call (server time), for eviction.
        var lastSeen: Double = 0
    }

    /// Why a device token is refused for a user (`cancelledRegistrations.reason`).
    enum Refusal: Sendable, Equatable {
        case retired
        case withdrawn
    }

    /// A malicious server answering `keys:answer` with `conflict` after it read the nonce.
    enum AnswerMischief: Sendable {
        /// The asking device stays committed to the same commitment, so the holder sees it again.
        case conflictAndShowAgain
        /// The asking device "asks anew": a new commitment the server made up (one per code it wants to try).
        case conflictAndNewCommitment
    }

    struct Row: Sendable {
        var provider: String
        var sealed: String?
        var cleared = false
        var keyId: String
        var revision: Int
        var updatedAt: Double
        var updatedBy: String
    }

    struct Call: Sendable {
        var device: String
        var path: String
        var args: ConvexValue
        /// The `sub` of the JWT it carried (nil: none).
        var user: String? = nil
    }

    /// One user's library.
    struct Library: Sendable {
        /// "lib" for the first library the server makes (the one most tests use), "lib-2", "lib-3"… after it.
        var id = "lib"
        var keyId: String?
        var rotationNeeded = false
        var vault: [Row] = []
        var keyRevision = 0
        var retired: Set<String> = []
        /// Sealed content, as the backend keeps it (`playback`, `queues`, `settings`, `commands`): raw values by
        /// device id, setting key, or in order.
        var playback: [String: ConvexValue] = [:]
        var queues: [String: ConvexValue] = [:]
        var settings: [String: ConvexValue] = [:]
        var commands: [FakeCommand] = []
        /// The key the last rotation replaced: content a device publishes about itself is still taken under it.
        var previousKey: String?
    }

    struct FakeCommand: Sendable {
        var id: String
        var from: String
        var to: String
        var command: ConvexValue
        var createdAt: Double
        var result: ConvexValue?
    }

    private let lock = NSLock()
    private var _devices: [Device] = []
    private var _libraries: [String: Library] = [:]
    /// The user of the call being handled (or of the device a test helper acts on): the library the `_keyId`,
    /// `_rotationNeeded`, `_vault` and `_keyRevision` accessors mean.
    private var current = ""
    /// The user whose library the plain accessors (`keyId`, `vault`, `keyRevision`, `setLibrary`, `putRow`) mean: the
    /// one named last by a call.
    private var _focus: String?
    private var _calls: [Call] = []
    private var time: Double = 1_000_000
    private var _rewrite: (@Sendable (_ viewer: String, _ subject: String, _ exchange: Exchange) -> Exchange)?
    private var _answerMischief: AnswerMischief?
    private var _loseClaimAnswer = false
    private var _refuseClaims = false
    private var _away: Set<String> = []
    private var _onClaim: (@Sendable (String) -> Void)?
    private var _loseRegisterAnswer = false
    private var _refuseRegistrations = false
    private var _onRegister: (@Sendable (String) -> Void)?
    private var _loseRotateAnswer = false
    private var _unreachable = false
    /// Refused device tokens by "<user>|<token>": retired (their device was removed) or withdrawn, until `expiresAt`.
    private var _refused: [String: (reason: Refusal, expiresAt: Double)] = [:]
    /// New withdrawals per user in the current hour: (window start, count).
    private var _withdrawalWindow: [String: (start: Double, count: Int)] = [:]
    private var _legacyUnregister = false
    private var _maxDevices = 32
    /// Paths whose next requests are parked, and how many more.
    private var _delays: [String: Int] = [:]
    private var _parked: [(path: String, args: ConvexValue, user: String?)] = []
    /// Keys each device token is known to have had in the clear (proposed at registration, claimed, rotated to or
    /// from, accepted), whatever happened to the call. A device can only have learned a key one of these ways.
    private var _knows: [String: Set<String>] = [:]
    /// Resets of the vault key while a remaining device could still reach the key (it knows it, or a rotated key
    /// waiting on its row was made from a key it knows): a recoverable vault cleared.
    private var _violations: [String] = []
    /// The revision at which each device's rotation to a key, or claim of a key, reached the server.
    private var _arrivals: [String: [String: Int]] = [:]

    // MARK: The current library

    private var lib: Library {
        get { _libraries[current] ?? Library() }
        set {
            var library = newValue
            if _libraries[current] == nil {
                librariesMade += 1
                library.id = librariesMade == 1 ? "lib" : "lib-\(librariesMade)"
            }
            _libraries[current] = library
        }
    }
    private var librariesMade = 0
    private var _keyId: String? {
        get { lib.keyId }
        set { lib.keyId = newValue }
    }
    private var _rotationNeeded: Bool {
        get { lib.rotationNeeded }
        set { lib.rotationNeeded = newValue }
    }
    private var _vault: [Row] {
        get { lib.vault }
        set { lib.vault = newValue }
    }
    private var _keyRevision: Int {
        get { lib.keyRevision }
        set { lib.keyRevision = newValue }
    }
    /// The key state changed: the revision moves on.
    private func bump() { _keyRevision += 1 }
    /// Indices of the devices in the current library.
    private var mine: [Int] { _devices.indices.filter { _devices[$0].owner == current } }

    private func focusing<T>(_ user: String?, _ body: () -> T) -> T {
        let saved = current
        current = user ?? _focus ?? ""
        defer { current = saved }
        return body()
    }

    // MARK: Observing

    var violations: [String] { lock.withLock { _violations } }
    /// The revision at which `token`'s call naming `keyId` (a rotation to it, or a claim of it) reached the server.
    func arrival(_ token: String, _ keyId: String) -> Int? { lock.withLock { _arrivals[token]?[keyId] } }
    private func learn(_ token: String, _ keys: String?...) {
        for key in keys.compactMap({ $0 }) { _knows[token, default: []].insert(key) }
    }

    /// Every device, of every user.
    var devices: [Device] { lock.withLock { _devices } }
    func devices(of user: String) -> [Device] { devices.filter { $0.owner == user } }
    var keyId: String? { lock.withLock { focusing(nil) { _keyId } } }
    func keyId(of user: String) -> String? { lock.withLock { focusing(user) { _keyId } } }
    var keyRevision: Int { lock.withLock { focusing(nil) { _keyRevision } } }
    func keyRevision(of user: String) -> Int { lock.withLock { focusing(user) { _keyRevision } } }
    var vault: [Row] { lock.withLock { focusing(nil) { _vault } } }
    var calls: [Call] { lock.withLock { _calls } }
    func calls(_ path: String, by device: String? = nil) -> [Call] {
        calls.filter { $0.path == path && (device == nil || $0.device == device) }
    }
    func device(named name: String) -> Device? { devices.first { $0.name == name } }
    /// Requests parked by `delay` that haven't run yet.
    var parked: Int { lock.withLock { _parked.count } }
    /// Why `token` is refused for `user` now, nil when it isn't.
    func refusal(_ token: String, user: String) -> Refusal? { lock.withLock { refused("\(user)|\(token)") } }

    // The backend's limits (`sync/convex/model.ts`), in the fake's milliseconds.
    static let refusalTTL: Double = 30 * 24 * 3600_000
    static let withdrawalsPerHour = 10
    static let maxWithdrawals = 50

    /// Moves the server's clock on (refusals expire, withdrawal windows pass).
    func advanceTime(_ milliseconds: Double) { lock.withLock { time += milliseconds } }

    /// `name` makes a call now (as a heartbeat would): it is the device seen most recently.
    func touch(_ name: String) {
        lock.withLock {
            guard let i = _devices.firstIndex(where: { $0.name == name }) else { return }
            _devices[i].lastSeen = tick()
        }
    }

    /// Devices per library; registering one more evicts the device seen least recently (the backend's 32 by default).
    func setMaxDevices(_ count: Int) { lock.withLock { _maxDevices = count } }

    // MARK: Behaviour

    /// A malicious server: what `viewer` sees of `subject`'s exchange in `devices:list`.
    func rewrite(_ change: (@Sendable (_ viewer: String, _ subject: String, _ exchange: Exchange) -> Exchange)?) {
        lock.withLock { _rewrite = change }
    }

    func answerMischief(_ mischief: AnswerMischief?) { lock.withLock { _answerMischief = mischief } }

    /// Takes a claim but answers with an error, as when the answer is lost on the way. `onClaim` runs as the claim
    /// arrives (the device has sent it).
    func loseClaimAnswer(_ lose: Bool, onClaim: (@Sendable (String) -> Void)? = nil) {
        lock.withLock {
            _loseClaimAnswer = lose
            _onClaim = onClaim
        }
    }

    /// Takes every registration but answers with an error, as when the answer is lost on the way. `onRegister` runs
    /// as a registration arrives (the device has sent it), with its token.
    func loseRegisterAnswer(_ lose: Bool, onRegister: (@Sendable (String) -> Void)? = nil) {
        lock.withLock {
            _loseRegisterAnswer = lose
            _onRegister = onRegister
        }
    }

    /// Takes the next rotation but answers with an error, and the rotating device then can't reach the server (as
    /// when the answer is lost and the app quits before it hears anything more).
    func loseRotateAnswer(_ lose: Bool) { lock.withLock { _loseRotateAnswer = lose } }

    /// Refuses every registration (`unauthorized`), as for a token that names a device of another account.
    func refuseRegistrations(_ refuse: Bool) { lock.withLock { _refuseRegistrations = refuse } }

    /// Nothing reaches the server: every call fails (offline), registration included.
    func setUnreachable(_ unreachable: Bool) { lock.withLock { _unreachable = unreachable } }

    /// A device that can't reach the server: every call it makes fails.
    func setAway(_ name: String, _ away: Bool) {
        lock.withLock { if away { _away.insert(name) } else { _away.remove(name) } }
    }

    /// Refuses every claim (`forbidden`), as for a key the account used before.
    func refuseClaims(_ refuse: Bool) { lock.withLock { _refuseClaims = refuse } }

    /// `account:unregister` as an older server ran it: nothing recorded, and no `cancelled` in the answer. Removed
    /// devices aren't retired either.
    func legacyUnregister(_ legacy: Bool) { lock.withLock { _legacyUnregister = legacy } }

    /// Parks the next `count` requests to `path`: each one is sent but gets no answer (the device sees a transport
    /// error), and runs only when `commitDelayed()` is called.
    func delay(_ path: String, count: Int = 1) { lock.withLock { _delays[path, default: 0] += count } }

    /// Runs every parked request now, in the order sent. Their answers go nowhere.
    func commitDelayed() {
        lock.withLock {
            let parked = _parked
            _parked = []
            _delays = [:]
            for request in parked { _ = process(request.path, request.args, user: request.user, sent: true) }
        }
    }

    /// A device the server made up (or that registered elsewhere), asking with `commitment`.
    func addAskingDevice(_ name: String, commitment: String, publicKey: String = DeviceKeyPair.generate().publicKey) {
        lock.withLock {
            focusing(nil) {
                _devices.append(Device(id: "made-up-\(_devices.count + 1)-\(UUID().uuidString.prefix(4))", name: name, token: UUID().uuidString,
                                       publicKey: publicKey, state: .requested(Exchange(commitment: commitment)), owner: current))
                bump()
            }
        }
    }

    /// A malicious (or simply other) server writing state directly.
    func set(_ name: String, state: State) {
        lock.withLock {
            guard let i = _devices.firstIndex(where: { $0.name == name }) else { return }
            focusing(_devices[i].owner) {
                _devices[i].state = state
                bump()
            }
        }
    }
    func setLibrary(keyId: String?, rotationNeeded: Bool) {
        lock.withLock {
            focusing(nil) {
                _keyId = keyId
                _rotationNeeded = rotationNeeded
                bump()
            }
        }
    }
    func putRow(_ row: Row) { lock.withLock { focusing(nil) { storeRow(row) } } }

    private func storeRow(_ row: Row) {
        _vault.removeAll { $0.provider == row.provider }
        _vault.append(row)
    }

    /// Removes a device the way `devices:remove` does: rotation when it could open the vault, a reset when nobody left can.
    func remove(_ name: String) {
        lock.withLock {
            guard let i = _devices.firstIndex(where: { $0.name == name }) else { return }
            focusing(_devices[i].owner) { removeDevice(at: i) }
        }
    }

    /// Deletes a device of the current library with the effects of `deleteDevice`: the last one out takes the library
    /// along; otherwise a device that could open the vault forces a rotation, or a reset when nobody left can.
    private func removeDevice(at i: Int) {
        let gone = _devices.remove(at: i)
        lib.playback[gone.id] = nil
        lib.queues[gone.id] = nil
        lib.commands.removeAll { $0.from == gone.id || $0.to == gone.id }
        // Every removal retires the token, as `deleteDevice` does.
        if !_legacyUnregister { refuse(gone.token, user: gone.owner, .retired) }
        guard !mine.isEmpty else {
            _libraries[current] = nil
            return
        }
        if _keyId != nil, !resetIfStranded(), gone.state.canOpenVault || gone.exposedKeyId == _keyId {
            _rotationNeeded = true
        }
        bump()
    }

    /// `resetIfStranded`: a key nobody left can open is reset. Returns whether it reset.
    @discardableResult
    private func resetIfStranded() -> Bool {
        guard let current = _keyId, !mine.contains(where: { _devices[$0].state.canOpenVault }) else { return false }
        for i in mine {
            let d = _devices[i]
            let known = _knows[d.token] ?? []
            var reachable = known.contains(current)
            if case .holder(let r?) = d.state, r.keyId == current, known.contains(r.fromKeyId) { reachable = true }
            if reachable { _violations.append("reset of \(current) while \(d.name) (\(d.state.kind)) could still reach it") }
        }
        lib.retired.insert(current)
        // Settings were sealed under the lost key: deleted, as `resetVaultKey` does.
        lib.settings = [:]
        lib.previousKey = nil
        _keyId = nil
        _rotationNeeded = false
        for j in _vault.indices where _vault[j].sealed != nil {
            _vault[j] = Row(provider: _vault[j].provider, sealed: nil, cleared: true, keyId: String(repeating: "0", count: 32),
                            revision: _vault[j].revision + 1, updatedAt: tick(), updatedBy: _vault[j].updatedBy)
        }
        for j in mine { _devices[j].state = .requested(nil) }
        bump()
        return true
    }

    func http() -> FakeHTTP {
        let http = FakeHTTP()
        http.handle = { [self] _, body, headers in try self.handle(body, headers: headers) }
        return http
    }

    private func tick() -> Double {
        time += 1
        return time
    }

    private func refused(_ key: String) -> Refusal? {
        guard let record = _refused[key], record.expiresAt > time else { return nil }
        return record.reason
    }

    private func refuse(_ token: String, user: String, _ reason: Refusal) {
        let key = "\(user)|\(token)"
        let expiresAt = time + Self.refusalTTL
        // A withdrawal of a token whose device is then removed becomes a retirement; nothing turns back.
        let kept = refused(key) == .retired ? Refusal.retired : reason
        _refused[key] = (kept, max(expiresAt, _refused[key]?.expiresAt ?? 0))
    }

    // MARK: Answers

    private func ok(_ value: ConvexValue) -> ConvexValue { .object(["status": .string("success"), "value": value]) }
    private func now() -> ConvexValue { ok(.object(["serverNow": .float64(tick())])) }
    private func fail(_ code: String, _ message: String, revision: Int? = nil) -> ConvexValue {
        var data: [String: ConvexValue] = ["code": .string(code), "message": .string(message)]
        if let revision { data["revision"] = .float64(Double(revision)) }
        return .object(["status": .string("error"), "errorMessage": .string(message), "errorData": .object(data)])
    }

    private static let queries: Set<String> = ["devices:list", "vault:list", "settings:list", "playback:list", "commands:incoming",
                                               "commands:outgoing", "playback:queue"]

    private func handle(_ body: ConvexValue, headers: [String: String]) throws -> ConvexValue {
        try lock.withLock {
            guard let path = body["path"]?.stringValue, let args = firstArgs(body) else { return fail("invalidArgument", "no args") }
            let user = headers["Authorization"].flatMap(IdentityAudit.subject)
            if !Self.queries.contains(path), let left = _delays[path], left > 0 {
                _delays[path] = left - 1
                let token = args["token"]?.stringValue ?? ""
                _calls.append(Call(device: _devices.first { $0.token == token }?.name ?? "?", path: path, args: args, user: user))
                _parked.append((path, args, user))
                throw URLError(.timedOut)
            }
            return process(path, args, user: user)
        }
    }

    /// Runs one request. `sent`: it reached the server earlier (parked by `delay`), so the device being offline now
    /// doesn't stop it.
    private func process(_ path: String, _ args: ConvexValue, user: String?, sent: Bool = false) -> ConvexValue {
        let token = args["token"]?.stringValue ?? ""
        let named = _devices.firstIndex { $0.token == token }
        _calls.append(Call(device: named.map { _devices[$0].name } ?? "?", path: path, args: args, user: user))
        guard let user else { return fail("unauthenticated", "Sign in first.") }
        _focus = user
        return focusing(user) { () -> ConvexValue in
            if path == "account:register" { return register(args, token: token, sent: sent) }
            if path == "account:unregister" { return unregister(token: token, sent: sent) }
            if _unreachable, !sent { return fail("unavailable", "Can't reach the server.") }
            // A token names a device of the caller's own library only.
            guard let me = named, _devices[me].owner == user else { return fail("unauthorized", "Unknown device.") }
            if _away.contains(_devices[me].name), !sent { return fail("unavailable", "Can't reach the server.") }
            _devices[me].lastSeen = tick()   // a call that reached the server: seen now
            switch path {
            case "devices:list": return list(viewer: me)
            case "vault:list": return ok(.array(_vault.map(row)))
            case "playback:publish": return publish(args, me: me)
            case "playback:clear":
                lib.playback[_devices[me].id] = nil
                lib.queues[_devices[me].id] = nil
                return now()
            case "playback:list": return ok(.array(Array(lib.playback.values)))
            case "playback:queue": return ok(lib.queues[args["deviceId"]?.stringValue ?? ""] ?? .null)
            case "settings:put": return putSetting(args, me: me)
            case "settings:list": return ok(.array(lib.settings.keys.sorted().compactMap { lib.settings[$0] }))
            case "commands:send": return sendCommand(args, me: me)
            case "commands:ack": return ack(args, me: me)
            case "commands:incoming":
                let mine = lib.commands.filter { $0.to == _devices[me].id && $0.result == nil }
                return ok(.array(mine.map { c in
                    .object(["id": .string(c.id), "fromDeviceId": .string(c.from), "command": c.command, "createdAt": .float64(c.createdAt),
                             "expiresAt": .float64(c.createdAt + 120_000)])
                }))
            case "commands:outgoing":
                let sent = lib.commands.filter { $0.from == _devices[me].id }.reversed()
                return ok(.array(sent.map { c in
                    var o: [String: ConvexValue] = ["id": .string(c.id), "toDeviceId": .string(c.to), "kind": c.command["kind"] ?? .null,
                                                    "createdAt": .float64(c.createdAt), "expiresAt": .float64(c.createdAt + 120_000)]
                    if let result = c.result {
                        o["result"] = result
                        o["ackedAt"] = .float64(c.createdAt + 1)
                    }
                    return .object(o)
                }))
            case "vault:put": return put(args, me: me)
            case "keys:request": return request(args, me: me)
            case "keys:answer": return answer(args, me: me)
            case "keys:reveal": return reveal(args, me: me)
            case "keys:grant": return grant(args, me: me)
            case "keys:accept": return accept(args, me: me)
            case "keys:deny": return deny(args, me: me)
            case "keys:claim": return claim(args, me: me)
            case "keys:rotate":
                let answer = rotate(args, me: me)
                guard _loseRotateAnswer else { return answer }
                _loseRotateAnswer = false
                _away.insert(_devices[me].name)
                return fail("internal", "The answer was lost.")
            case "keys:release": return release(args, me: me)
            case "devices:remove":
                guard let target = target(args) else { return fail("notFound", "No such device") }
                removeDevice(at: target)
                return now()
            default: return now()
            }
        }
    }

    private func register(_ args: ConvexValue, token: String, sent: Bool) -> ConvexValue {
        if _unreachable, !sent { return fail("unavailable", "Can't reach the server.") }
        _onRegister?(token)
        if _refuseRegistrations { return fail("unauthorized", "Unknown device.") }
        if refused("\(current)|\(token)") != nil { return fail("unauthorized", "This device signed out.") }
        let answer = registered(args, token: token)
        return _loseRegisterAnswer ? fail("internal", "The answer was lost.") : answer
    }

    private func registered(_ args: ConvexValue, token: String) -> ConvexValue {
        if let known = _devices.first(where: { $0.token == token }) {
            guard known.owner == current else { return fail("unauthorized", "Unknown device.") }
            return ok(.object(["deviceId": .string(known.id), "libraryId": .string(lib.id), "keyId": _keyId.map(ConvexValue.string) ?? .null,
                               "keyState": .string(known.state.kind), "keyRevision": .float64(Double(_keyRevision)), "serverNow": .float64(tick())]))
        }
        let id = "d\(_devices.count + 1)-\(UUID().uuidString.prefix(4))"
        // A full library loses the device seen least recently (`evictIfFull`).
        if mine.count >= _maxDevices, let stalest = mine.min(by: { _devices[$0].lastSeen < _devices[$1].lastSeen }) {
            removeDevice(at: stalest)
        }
        let proposed = args["keyId"]?.stringValue
        let state: State
        if _keyId == nil, let proposed, !lib.retired.contains(proposed) {
            _keyId = proposed
            learn(token, proposed)
            state = .holder(rekey: nil)
        } else {
            state = .requested(nil)
        }
        _devices.append(Device(id: id, name: args["device"]?["name"]?.stringValue ?? id, token: token, publicKey: args["publicKey"]?.stringValue ?? "",
                               state: state, exposedKeyId: state == .holder(rekey: nil) ? _keyId : nil, owner: current, lastSeen: tick()))
        bump()
        return ok(.object(["deviceId": .string(id), "libraryId": .string(lib.id), "keyId": _keyId.map(ConvexValue.string) ?? .null,
                           "keyState": .string(state.kind), "keyRevision": .float64(Double(_keyRevision)), "serverNow": .float64(tick())]))
    }

    /// `account:unregister`: a device of the caller's is removed (its token retired, never limited); any other token
    /// is recorded as withdrawn, rate limited and capped per user, a retry of a recorded one free.
    private func unregister(token: String, sent: Bool) -> ConvexValue {
        let caller = _devices.first { $0.token == token }
        if !sent, _unreachable || _away.contains(where: { name in caller?.name == name }) { return fail("unavailable", "Can't reach the server.") }
        var answer: [String: ConvexValue] = ["removed": .bool(false), "serverNow": .float64(tick())]
        if !_legacyUnregister { answer["cancelled"] = .bool(true) }
        if let i = _devices.firstIndex(where: { $0.token == token && $0.owner == current }) {
            removeDevice(at: i)
            answer["removed"] = .bool(true)
            return ok(.object(answer))
        }
        guard !_legacyUnregister, refused("\(current)|\(token)") == nil else { return ok(.object(answer)) }
        let hour: Double = 3600_000
        let start = time - time.truncatingRemainder(dividingBy: hour)
        let window: (start: Double, count: Int) = _withdrawalWindow[current].flatMap { $0.start == start ? $0 : nil } ?? (start, 0)
        let withdrawn = _refused.filter { $0.key.hasPrefix("\(current)|") && $0.value.reason == .withdrawn && $0.value.expiresAt > time }
        guard window.count < Self.withdrawalsPerHour, withdrawn.count < Self.maxWithdrawals else {
            return fail("rateLimited", "Too many sign-outs of unknown devices. Try again later.")
        }
        _withdrawalWindow[current] = (start, window.count + 1)
        refuse(token, user: current, .withdrawn)
        return ok(.object(answer))
    }

    private func exchangeValue(_ e: Exchange) -> ConvexValue {
        var o: [String: ConvexValue] = ["commitment": .string(e.commitment), "at": .float64(time)]
        if let holder = e.holder, let key = e.holderKey, let nonce = e.holderNonce {
            o["holder"] = .string(holder)
            o["holderKey"] = .string(key)
            o["holderNonce"] = .string(nonce)
            if let revealed = e.nonce {
                o["phase"] = .string("revealed")
                o["nonce"] = .string(revealed)
            } else {
                o["phase"] = .string("answered")
            }
        } else {
            o["phase"] = .string("committed")
        }
        return .object(o)
    }

    /// What `devices:list` answers the device with `token` now, nil when no device has it.
    func listResult(token: String) -> DeviceListResult? {
        let value = lock.withLock { () -> ConvexValue? in
            guard let i = _devices.firstIndex(where: { $0.token == token }) else { return nil }
            return focusing(_devices[i].owner) { list(viewer: i)["value"] }
        }
        return value.flatMap { try? $0.decode(DeviceListResult.self) }
    }

    /// What `devices:list` answers `name` now (to hand it to that device later, as a list that arrived late).
    func listResult(for name: String) throws -> DeviceListResult {
        let value = lock.withLock { () -> ConvexValue? in
            guard let i = _devices.firstIndex(where: { $0.name == name }) else { return nil }
            return focusing(_devices[i].owner) { list(viewer: i)["value"] }
        }
        return try (value ?? .null).decode(DeviceListResult.self)
    }

    private func list(viewer: Int) -> ConvexValue {
        let me = _devices[viewer]
        let rows: [ConvexValue] = mine.map { _devices[$0] }.map { d in
            var exchange: ConvexValue = .null
            if case .requested(let e?) = d.state { exchange = exchangeValue(_rewrite?(me.name, d.name, e) ?? e) }
            return .object(["id": .string(d.id), "name": .string(d.name), "platform": .string("ios"), "model": .string("m"),
                            "appVersion": .string("1"), "createdAt": .float64(1), "lastSeenAt": .float64(time),
                            "keyState": .string(d.state.kind), "publicKey": .string(d.publicKey), "exchange": exchange])
        }
        var grant: ConvexValue = .null
        var rekey: ConvexValue = .null
        switch me.state {
        case .granted(let keyId, let wrapped, let by, let commitment):
            grant = .object(["keyId": .string(keyId), "wrapped": .string(wrapped), "fromDeviceId": .string(by), "commitment": .string(commitment)])
        case .holder(let r?):
            rekey = .object(["keyId": .string(r.keyId), "fromKeyId": .string(r.fromKeyId), "wrapped": .string(r.wrapped), "fromDeviceId": .string(r.by)])
        default: break
        }
        return ok(.object(["selfId": .string(me.id), "libraryId": .string(lib.id), "keyId": _keyId.map(ConvexValue.string) ?? .null,
                           "rotationNeeded": .bool(_rotationNeeded), "keyRevision": .float64(Double(_keyRevision)),
                           "devices": .array(rows), "grant": grant, "rekey": rekey]))
    }

    private func row(_ r: Row) -> ConvexValue {
        .object(["provider": .string(r.provider), "sealed": r.sealed.map(ConvexValue.string) ?? .null, "cleared": .bool(r.cleared),
                 "keyId": .string(r.keyId), "revision": .float64(Double(r.revision)), "updatedAt": .float64(r.updatedAt), "updatedBy": .string(r.updatedBy)])
    }

    private func put(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard let provider = args["provider"]?.stringValue, let base = args["baseRevision"]?.doubleValue.map({ Int($0) }) else { return fail("invalidArgument", "args") }
        guard args["keyId"]?.stringValue == _keyId else { return fail("forbidden", "This data is sealed with a key the library doesn't use.") }
        guard !_rotationNeeded else { return fail("forbidden", "Your account's key is being replaced.") }
        let current = _vault.first { $0.provider == provider }?.revision ?? 0
        guard base == current else { return fail("conflict", "Another device changed this sign-in first.", revision: current) }
        let at = tick()
        storeRow(Row(provider: provider, sealed: args["sealed"]?.stringValue, keyId: _keyId ?? "", revision: current + 1, updatedAt: at, updatedBy: _devices[me].id))
        return ok(.object(["updatedAt": .float64(at), "revision": .float64(Double(current + 1)), "serverNow": .float64(at)]))
    }

    /// Another device of the caller's library, by `deviceId`.
    private func target(_ args: ConvexValue) -> Int? {
        _devices.firstIndex { $0.id == args["deviceId"]?.stringValue && $0.owner == current }
    }

    private func request(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard let commitment = args["commitment"]?.stringValue else { return fail("invalidArgument", "commitment") }
        bump()   // before anything, as the backend does: a no-op request moves the revision too
        if case .holder = _devices[me].state { return now() }
        if case .requested(let e?) = _devices[me].state, e.commitment == commitment {
            resetIfStranded()
            return now()
        }
        _devices[me].state = .requested(Exchange(commitment: commitment))
        resetIfStranded()
        return now()
    }

    private func answer(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard case .holder = _devices[me].state else { return fail("forbidden", "not a holder") }
        guard let t = target(args), case .requested(var e?) = _devices[t].state, e.commitment == args["commitment"]?.stringValue,
              let nonce = args["nonce"]?.stringValue else { return fail("conflict", "That device isn't asking any more.") }
        if let holder = e.holder {
            guard holder == _devices[me].id, e.holderNonce == nonce else { return fail("conflict", "Another device answered first.") }
            bump()   // a retry: the backend bumps before it looks
            return now()
        }
        switch _answerMischief {
        case .conflictAndShowAgain?:
            return fail("conflict", "Another device answered first.")
        case .conflictAndNewCommitment?:
            _devices[t].state = .requested(Exchange(commitment: KeyExchange.nonce().base64EncodedString()))
            bump()
            return fail("conflict", "That device isn't asking any more.")
        case nil:
            break
        }
        e.holder = _devices[me].id
        e.holderKey = _devices[me].publicKey
        e.holderNonce = nonce
        _devices[t].state = .requested(e)
        bump()
        return now()
    }

    private func reveal(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard case .requested(var e?) = _devices[me].state, e.commitment == args["commitment"]?.stringValue, e.holder != nil,
              let nonce = args["nonce"]?.stringValue else { return fail("conflict", "No device has answered yet.") }
        if let revealed = e.nonce {
            guard revealed == nonce else { return fail("conflict", "already revealed") }
            bump()   // a retry: the backend bumps before it looks
            return now()
        }
        e.nonce = nonce
        _devices[me].state = .requested(e)
        bump()
        return now()
    }

    private func grant(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard case .holder = _devices[me].state else { return fail("forbidden", "not a holder") }
        guard args["keyId"]?.stringValue == _keyId else { return fail("forbidden", "That isn't your account's key.") }
        guard !_rotationNeeded else { return fail("conflict", "Your account's key is being replaced.") }
        if let t = target(args), case .granted(_, let wrapped, let by, let commitment) = _devices[t].state, by == _devices[me].id,
           wrapped == args["wrapped"]?.stringValue, commitment == args["commitment"]?.stringValue {
            bump()   // a retry of the grant that landed: the backend bumps before it looks
            return now()
        }
        guard let t = target(args), case .requested(let e?) = _devices[t].state, e.nonce != nil, e.holder == _devices[me].id,
              let commitment = args["commitment"]?.stringValue, e.commitment == commitment,
              let wrapped = args["wrapped"]?.stringValue, let keyId = _keyId else { return fail("conflict", "That device's request changed.") }
        _devices[t].state = .granted(keyId: keyId, wrapped: wrapped, by: _devices[me].id, commitment: commitment)
        _devices[t].exposedKeyId = keyId
        bump()
        return now()
    }

    private func accept(_ args: ConvexValue, me: Int) -> ConvexValue {
        let keyId = args["keyId"]?.stringValue
        learn(_devices[me].token, keyId)
        switch _devices[me].state {
        case .holder(let rekey?) where rekey.keyId == keyId:
            _devices[me].state = .holder(rekey: nil)
        case .holder:
            break
        case .granted(let granted, _, _, _) where granted == keyId && keyId == _keyId:
            _devices[me].state = .holder(rekey: nil)
        default:
            return fail("forbidden", "There is no grant of that key for this device.")
        }
        bump()   // the backend bumps on every accept that succeeds, a no-op included
        return now()
    }

    private func deny(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard case .holder = _devices[me].state else { return fail("forbidden", "not a holder") }
        // Only the exchange named, when one is (the backend leaves a newer one alone).
        if let t = target(args), case .requested(let exchange) = _devices[t].state,
           args["commitment"]?.stringValue.map({ $0 == exchange?.commitment }) ?? true {
            _devices[t].state = .denied
        }
        bump()   // the backend bumps on every deny that succeeds, a no-op included
        return now()
    }

    /// `keys:release`: a holder whose key isn't the account's stops counting as one, if the account key, the rotated
    /// key waiting for it and the revision are still the ones it examined.
    private func release(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard case .holder(let rekey) = _devices[me].state else { return now() }
        guard let held = args["keyId"]?.stringValue else { return fail("invalidArgument", "keyId") }
        guard held != _keyId else { return fail("conflict", "This device has your account's key.") }
        guard args["accountKeyId"]?.stringValue == _keyId else { return fail("conflict", "Your account's key changed.") }
        guard args["rekeyKeyId"]?.stringValue == rekey?.keyId else { return fail("conflict", "A new key is waiting for this device.") }
        guard let seen = args["keyRevision"]?.doubleValue.map({ Int($0) }) else { return fail("invalidArgument", "keyRevision") }
        guard seen == _keyRevision else { return fail("conflict", "Your account's keys changed since this device looked.") }
        _devices[me].state = .requested(nil)
        bump()
        resetIfStranded()
        return now()
    }

    /// `keys:claim`, compare-and-swap on the revision the device examined (when it sends one).
    private func claim(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard let keyId = args["keyId"]?.stringValue else { return fail("invalidArgument", "keyId") }
        guard let seen = args["keyRevision"]?.doubleValue.map({ Int($0) }) else { return fail("invalidArgument", "keyRevision") }
        learn(_devices[me].token, keyId)
        _arrivals[_devices[me].token, default: [:]][keyId] = _keyRevision
        _onClaim?(keyId)
        if _refuseClaims { return fail("forbidden", "That key was used before. Make a new one.") }
        if let current = _keyId {
            if current == keyId, case .holder = _devices[me].state {
                return ok(.object(["keyId": .string(keyId), "keyRevision": .float64(Double(_keyRevision)), "serverNow": .float64(tick())]))
            }
            return fail("forbidden", "Your account already has a key.")
        }
        if lib.retired.contains(keyId) { return fail("forbidden", "That key was used before. Make a new one.") }
        guard seen == _keyRevision else { return fail("conflict", "Your account's keys changed since this device looked.") }
        _keyId = keyId
        _rotationNeeded = false
        _devices[me].state = .holder(rekey: nil)
        _devices[me].exposedKeyId = keyId
        bump()
        if _loseClaimAnswer { return fail("internal", "The answer was lost.") }
        return ok(.object(["keyId": .string(keyId), "keyRevision": .float64(Double(_keyRevision)), "serverNow": .float64(tick())]))
    }

    // MARK: Sealed content (playback, queues, settings, commands)

    /// Content is taken only sealed (`{ v: 1, keyId, sealed }`) under the account's key, or for what a device publishes
    /// about itself the key the last rotation replaced, as on the backend.
    private func accepts(_ sealed: ConvexValue?, previous: Bool) -> Bool {
        guard let sealed, sealed["v"]?.doubleValue == 1, let keyId = sealed["keyId"]?.stringValue, let text = sealed["sealed"]?.stringValue,
              Data(base64Encoded: text) != nil, let current = _keyId else { return false }
        return keyId == current || (previous && keyId == lib.previousKey)
    }

    private func publish(_ args: ConvexValue, me: Int) -> ConvexValue {
        let id = _devices[me].id
        var row: [String: ConvexValue] = ["deviceId": .string(id), "content": .null, "queueVersion": .float64(0)]
        if case .object(let old)? = lib.playback[id] { row = old }
        var version = row["queueVersion"]?.doubleValue ?? 0
        switch args["content"] {
        case nil: break
        case .null?:
            if row["content"] != .null || lib.queues[id] != nil { version += 1 }
            row["content"] = .null
            lib.queues[id] = nil
        case let content?:
            guard accepts(content["playback"], previous: true), accepts(content["queue"], previous: true) else {
                return fail("forbidden", "This data is sealed with a key your account doesn't use.")
            }
            version += 1
            row["content"] = content["playback"]
            lib.queues[id] = .object(["content": content["queue"] ?? .null, "version": .float64(version)])
        }
        let at = tick()
        row["queueVersion"] = .float64(version)
        row["anchor"] = args["anchor"]
        row["updatedAt"] = .float64(at)
        lib.playback[id] = .object(row)
        let positionAt = args["anchor"]?["positionAt"]?.doubleValue ?? at
        return ok(.object(["serverNow": .float64(at), "positionAt": .float64(min(at, positionAt)), "queueVersion": .float64(version)]))
    }

    private func putSetting(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard let key = args["key"]?.stringValue else { return fail("invalidArgument", "key") }
        guard accepts(args["value"], previous: false) else { return fail("forbidden", "This data is sealed with a key your account doesn't use.") }
        if args["ifAbsent"] == .bool(true), let existing = lib.settings[key] {
            return ok(.object(["updatedAt": existing["updatedAt"] ?? .float64(0), "serverNow": .float64(tick())]))
        }
        let at = tick()
        var row: [String: ConvexValue] = ["key": .string(key), "value": args["value"] ?? .null, "updatedAt": .float64(at), "updatedBy": .string(_devices[me].id)]
        if let writeId = args["writeId"], writeId != .null { row["writeId"] = writeId }
        lib.settings[key] = .object(row)
        return ok(.object(["updatedAt": .float64(at), "serverNow": .float64(at)]))
    }

    private func sendCommand(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard let command = args["command"], let to = args["toDeviceId"]?.stringValue else { return fail("invalidArgument", "command") }
        if command["kind"]?.stringValue == "takeOver", !accepts(command["content"], previous: true) {
            return fail("forbidden", "This data is sealed with a key your account doesn't use.")
        }
        let at = tick()
        let id = "c\(lib.commands.count + 1)"
        lib.commands.append(FakeCommand(id: id, from: _devices[me].id, to: to, command: command, createdAt: at))
        return ok(.object(["commandId": .string(id), "expiresAt": .float64(at + 120_000), "serverNow": .float64(at)]))
    }

    private func ack(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard let id = args["commandId"]?.stringValue, let i = lib.commands.firstIndex(where: { $0.id == id && $0.to == _devices[me].id }) else {
            return fail("notFound", "No such command for this device.")
        }
        guard let result = args["result"] else { return fail("invalidArgument", "result") }
        if result["message"] != nil { return fail("invalidArgument", "Object contains extra field `message`") }
        if let content = result["content"], content != .null, !accepts(content, previous: true) {
            return fail("forbidden", "This data is sealed with a key your account doesn't use.")
        }
        if lib.commands[i].result == nil { lib.commands[i].result = result }
        return now()
    }

    /// Every content row the server holds, as JSON: what a dump of its tables would show.
    var contentDump: String {
        lock.withLock {
            _libraries.values.map { l in
                let commands = l.commands.map { c in ConvexValue.object(["command": c.command, "result": c.result ?? .null]) }
                return ConvexValue.object(["playback": .array(Array(l.playback.values)), "queues": .array(Array(l.queues.values)),
                                           "settings": .array(Array(l.settings.values)), "commands": .array(commands)]).jsonString()
            }.joined(separator: "\n")
        }
    }

    /// The calls a device made to `path`, with their arguments as JSON: what the server was sent.
    func sentJSON(_ path: String) -> [String] {
        lock.withLock { _calls.filter { $0.path == path }.map { $0.args.jsonString() } }
    }

    private func rotate(_ args: ConvexValue, me: Int) -> ConvexValue {
        guard case .holder = _devices[me].state else { return fail("forbidden", "not a holder") }
        guard let from = args["fromKeyId"]?.stringValue, let to = args["keyId"]?.stringValue else { return fail("invalidArgument", "keys") }
        learn(_devices[me].token, from, to)
        _arrivals[_devices[me].token, default: [:]][to] = _keyRevision
        if _keyId == to, !_rotationNeeded { return ok(.object(["keyRevision": .float64(Double(_keyRevision)), "serverNow": .float64(tick())])) }
        guard _keyId == from else { return fail("conflict", "Your account's key changed.") }
        guard to != from, !lib.retired.contains(to) else { return fail("forbidden", "Use a new key.") }
        guard case .array(let wraps) = args["wraps"], case .array(let reseal) = args["vault"] else { return fail("invalidArgument", "lists") }
        let others = mine.filter { i in
            if case .holder = _devices[i].state { return i != me }
            return false
        }
        let wrapped = Dictionary(wraps.compactMap { w in w["deviceId"]?.stringValue.map { ($0, w["wrapped"]?.stringValue ?? "") } }, uniquingKeysWith: { a, _ in a })
        guard wrapped.count == others.count, others.allSatisfy({ wrapped[_devices[$0].id] != nil }) else { return fail("conflict", "Your devices changed.") }
        let sealedRows = _vault.filter { $0.sealed != nil }
        guard reseal.count == sealedRows.count else { return fail("conflict", "Your sign-ins changed.") }
        // Every settings row, re-sealed under the new key (null: deleted), at the time it was read.
        guard case .array(let resealedSettings) = args["settings"] ?? .array([]), resealedSettings.count == lib.settings.count,
              resealedSettings.allSatisfy({ r in
                  r["key"]?.stringValue.flatMap { lib.settings[$0]?["updatedAt"] } == r["baseUpdatedAt"]
              }) else { return fail("conflict", "Your settings changed.") }
        for r in resealedSettings where r["value"] != .null {
            guard r["value"]?["keyId"]?.stringValue == to else { return fail("forbidden", "Seal settings with the new key.") }
        }
        for r in reseal {
            guard let provider = r["provider"]?.stringValue, let row = sealedRows.first(where: { $0.provider == provider }),
                  r["baseRevision"]?.doubleValue.map({ Int($0) }) == row.revision else { return fail("conflict", "Your sign-ins changed.") }
        }
        for r in reseal {
            guard let provider = r["provider"]?.stringValue, let row = _vault.first(where: { $0.provider == provider }) else { continue }
            let sealed = r["sealed"]?.stringValue
            storeRow(Row(provider: provider, sealed: sealed, keyId: sealed == nil ? String(repeating: "0", count: 32) : to,
                         revision: row.revision + 1, updatedAt: tick(), updatedBy: _devices[me].id))
        }
        for i in others {
            if case .holder(let pending) = _devices[i].state, pending != nil {
                _devices[i].state = .requested(nil)
            } else {
                _devices[i].state = .holder(rekey: Rekey(keyId: to, fromKeyId: from, wrapped: wrapped[_devices[i].id] ?? "", by: _devices[me].id))
                _devices[i].exposedKeyId = to
            }
        }
        for i in mine { if case .granted = _devices[i].state { _devices[i].state = .requested(nil) } }
        for r in resealedSettings {
            guard let key = r["key"]?.stringValue, case .object(var row)? = lib.settings[key] else { continue }
            if r["value"] == .null {
                lib.settings[key] = nil
                continue
            }
            row["value"] = r["value"]
            row["updatedAt"] = .float64(tick())
            row["updatedBy"] = .string(_devices[me].id)
            row["writeId"] = nil
            lib.settings[key] = .object(row)
        }
        lib.previousKey = from
        _devices[me].exposedKeyId = to
        lib.retired.insert(from)
        _keyId = to
        _rotationNeeded = false
        bump()
        return ok(.object(["keyRevision": .float64(Double(_keyRevision)), "serverNow": .float64(tick())]))
    }
}

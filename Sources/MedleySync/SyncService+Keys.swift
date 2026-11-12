import Foundation
import MedleyCore

// How the vault key reaches and leaves devices (docs/accounts-design.md, "Sign-in vault key"). The server relays
// everything here and is trusted with none of it:
//
// - A device without the key asks with a commitment, reveals its nonce only after a holder answered, shows the code
//   from its own record of the exchange, and takes a key only from a grant that opens under that exchange and only
//   after the listener confirmed the code here (`confirmKeyCode`). Until then it uploads nothing.
// - A holder answers each commitment once with a fresh nonce, checks the revealed nonce against the commitment,
//   and asks the listener only about exchanges that checked out. It answers a limited number per hour and stops
//   after repeated failures, which `keyWarning` shows. Every answer it gives counts, whatever the server says
//   about it afterwards, and a request always gets the same nonce (`KeyExchange.answerNonce`), one that covers
//   every field of the request the code covers.
// - A held key is pinned: no grant replaces it. It changes only by a rotation wrapped with it (`KeyRotation`), or
//   when this device claims a fresh key it made for an account left without one.
extension SyncService {
    /// Answers a holder gives per hour, to anyone. More wait.
    static let answersPerHour = 6
    /// Failed or refused exchanges in a day after which a holder stops answering until the day has passed.
    static let failuresBeforePause = 5
    /// Requests an asking device starts by itself per hour (a new exchange after one was dropped). The listener's
    /// Ask Again doesn't count.
    static let automaticAttemptsPerHour = 3

    // MARK: Ledger

    func loadLedger() {
        let scope = credentials.map(Self.scope)
        let saved = store.state(KeyLedger.stateName).flatMap { try? JSONDecoder().decode(KeyLedger.self, from: $0) }
        if let saved, scope != nil, saved.scope == scope {
            ledger = saved
        } else {
            ledger = KeyLedger(scope: scope)
            saveLedger()
        }
        pendingGrantKey = nil
    }

    func saveLedger() {
        ledger.prune(now: now())
        store.setState(KeyLedger.stateName, try? JSONEncoder().encode(ledger))
    }

    /// Queues `work` as an account operation (`AccountOperations`) unless one with the same id is still queued or
    /// running. It runs only for the session it was queued in (the same device token) and in the same epoch; calls
    /// it makes with the ticket stop it once anything supersedes it.
    func once(_ id: String, _ work: @escaping @MainActor (SyncService, AccountOperations.Ticket) async -> Void) {
        let token = credentials?.token
        operations.enqueue(id) { [weak self] ticket in
            guard let self, self.credentials?.token == token else { return }
            await work(self, ticket)
        }
    }

    // MARK: The device list

    /// A `devices:list` result arrived (the live query, a poll, or a fetch). It is applied as an account operation,
    /// after whatever runs now. While one waits, a newer one replaces it; an older one never replaces a newer one.
    /// `token` is the session the list was fetched for: a list for another session is dropped.
    func apply(_ list: DeviceListResult, token: String? = nil) {
        let token = token ?? credentials?.token
        if let waiting = pendingList, waiting.token == token, (waiting.list.keyRevision ?? 0) > (list.keyRevision ?? 0) { return }
        pendingList = (list, token)
        operations.enqueue("apply", until: .started) { [weak self] _ in
            guard let self, let next = self.pendingList else { return }
            self.pendingList = nil
            guard next.token != nil, next.token == self.credentials?.token else { return }
            self.applyNow(next.list)
        }
    }

    /// Everything a new `devices:list` result moves along, in order. Runs inside an account operation.
    ///
    /// Observations are monotonic: a list whose `keyRevision` is older than one this session already applied is
    /// ignored whole (two HTTP polls answered out of order, a fetch racing the live query). Nothing is decided from
    /// it, and no recovery material (a saved rotation key, a pending claim) is dropped because of it.
    func applyNow(_ list: DeviceListResult) {
        guard let credentials, list.selfId == credentials.deviceID else { return }
        let revision = list.keyRevision ?? 0
        guard revision >= appliedKeyRevision else { return }
        appliedKeyRevision = revision
        devices = list.devices
        let keyChanged = serverKeyID != list.keyId
        serverKeyID = list.keyId
        let rotation = list.rotationNeeded ?? false
        let rotationChanged = rotationNeeded != rotation
        rotationNeeded = rotation
        settleSavedRotation(rekey: list.rekey, revision: revision)
        settleSavedClaim(rekey: list.rekey, revision: revision)
        receiveRekey(list.rekey)
        retryAcceptIfNeeded(grant: list.grant)
        answerKeyRequests()
        checkRevealedRequests()
        advanceOwnRequest(grant: list.grant)
        claimLibraryKeyIfNeeded(serverKey: list.keyId)
        rotateKeyIfNeeded()
        releaseKeyIfStranded(rekey: list.rekey)
        updateKeyStatus()
        if keyChanged || rotationChanged { signIns.reconcileAll() }
    }

    /// Answers requests that waited for the hourly limit (the heartbeat calls it, as an operation).
    func resumeKeyRequests() {
        answerKeyRequests()
        updateKeyStatus()
    }

    /// Whether this device holds the key the account uses now.
    var holdsCurrentKey: Bool {
        // The observed `serverKeyID` before the unobserved `credentials`, so a view reading this always hears of a change.
        guard let server = serverKeyID, let key = credentials?.libraryKey else { return false }
        return key.id == server
    }

    /// Sign-ins don't upload while this device can't be sure its key is the account's: before the server named the
    /// key, while it doesn't match, and while the key is being replaced.
    public var vaultWritesPaused: Bool { !holdsCurrentKey || rotationNeeded }

    func updateKeyStatus() {
        guard let credentials else { keyStatus = .none; return }
        if let key = credentials.libraryKey {
            keyStatus = serverKeyID == nil || serverKeyID == key.id ? .available : keyIsOutdated ? .outdated : .mismatch
            return
        }
        if let outcome = ledger.attempt?.outcome {
            keyStatus = .failed(Self.message(outcome))
            return
        }
        if selfDevice?.keyState == .denied {
            keyStatus = .denied
            return
        }
        guard let attempt = ledger.attempt, attempt.revealed, let answer = attempt.answer,
              let transcript = requesterTranscript(attempt, credentials) else {
            keyStatus = .waiting
            return
        }
        let name = devices.first { $0.id == answer.holder }?.name ?? "your other device"
        keyStatus = .comparing(KeyComparison(code: transcript.code, holderID: answer.holder, holderName: name,
                                             allowed: pendingGrantKey != nil, confirmed: attempt.confirmed))
    }

    static func message(_ outcome: KeyLedger.Outcome) -> String {
        switch outcome {
        case .codesDidNotMatch:
            "The codes didn't match, so this device didn't take your sign-ins. Ask again, and allow it only when both devices show the same code."
        case .grantDidNotOpen:
            "What your other device sent didn't open here, so this device didn't take it. Ask again."
        case .tooManyAttempts:
            "\(ProductInfo.name) stopped asking for your sign-ins after several tries. Open \(ProductInfo.name) on your other device, then ask again."
        }
    }

    func keyExchangeWarning() -> String? {
        #if DEBUG
        if let previewWarning { return previewWarning }
        #endif
        let at = now()
        let recent = ledger.failures(since: at.addingTimeInterval(-24 * 3600))
        if recent.contains(where: { $0.kind == .tampered }) {
            return "A request for your sign-ins was changed on its way to this device, so \(ProductInfo.name) refused it. If this happens again, your sync server may not be trustworthy."
        }
        if recent.count >= 2 {
            return "\(recent.count) requests for your sign-ins failed or were refused today. If they weren't yours, remove devices you don't know and sign out of your account's other sessions."
        }
        if holdsCurrentKey, !answeringAllowed() {
            return "\(ProductInfo.name) paused answering requests for your sign-ins after several tries. It answers again later."
        }
        return nil
    }

    // MARK: Asking for the key

    /// Confirms the codes match (the listener compared this device's code with the holder's). The key is taken
    /// once the holder's grant is here too, whichever comes first.
    public func confirmKeyCode() {
        operations.perform { [weak self] in self?.confirmKeyCodeNow() }
    }

    private func confirmKeyCodeNow() {
        guard var attempt = ledger.attempt, attempt.outcome == nil, attempt.answer != nil, attempt.revealed else { return }
        attempt.confirmed = true
        ledger.attempt = attempt
        saveLedger()
        if pendingGrantKey != nil { commitGrantedKey() } else { updateKeyStatus() }
    }

    /// The codes don't match: this attempt ends and no key from it is ever used.
    public func rejectKeyCode() {
        operations.perform { [weak self] in self?.rejectKeyCodeNow() }
    }

    private func rejectKeyCodeNow() {
        guard var attempt = ledger.attempt, attempt.outcome == nil else { return }
        attempt.outcome = .codesDidNotMatch
        ledger.attempt = attempt
        ledger.failures.append(.init(at: now(), kind: .codesDidNotMatch))
        pendingGrantKey = nil
        saveLedger()
        updateKeyStatus()
    }

    /// This device holds a key, the account uses another one, and the server lists this device as asking: it missed
    /// two rotations while it was away (the second one couldn't be wrapped to a key it never took), or it stepped
    /// down itself because nothing here could reach the current key (`releaseKeyIfStranded`). The held key is kept
    /// until the listener asks again (`requestKeyAgain()`); the server saying so is never enough to drop it.
    var keyIsOutdated: Bool {
        guard let key = credentials?.libraryKey, let server = serverKeyID, server != key.id,
              credentials?.nextLibraryKey?.id != server, credentials?.claimingLibraryKey?.id != server else { return false }
        return selfDevice?.keyState == .requested || selfDevice?.keyState == .denied
    }

    /// Asks the devices that have the vault key again, with a new exchange (after a no, a mismatch or a failure).
    /// On a device whose key is out of date (`keyIsOutdated`), the listener asking is what drops the old key first;
    /// the current one then comes only through the code comparison, like on a new device.
    public func requestKeyAgain() async throws {
        try await operations.run { ticket in try await self.performRequestKeyAgain(ticket) }
    }

    private func performRequestKeyAgain(_ ticket: AccountOperations.Ticket) async throws {
        guard var credentials else { return }
        if credentials.libraryKey != nil {
            guard keyIsOutdated else { return }
            credentials.libraryKey = nil
            credentials.nextLibraryKey = nil
            credentials.nextLibraryKeyRevision = nil
            self.credentials = credentials
            store.save(credentials)
            ledger.attempt = nil
            pendingGrantKey = nil
        }
        guard let attempt = startAttempt(automatic: false) else { return }
        updateKeyStatus()
        _ = try await call("keys:request", RequestKeyArgs(token: credentials.token, commitment: attempt.commitment), as: ServerNowResult.self, ticket: ticket)
    }

    /// A new exchange: a fresh nonce and its commitment. nil when the automatic limit is reached (the attempt then
    /// reads "stopped asking").
    @discardableResult
    func startAttempt(automatic: Bool) -> KeyLedger.Attempt? {
        guard let credentials else { return nil }
        let at = now()
        if automatic {
            if ledger.automaticAttempts.filter({ $0 > at.addingTimeInterval(-3600) }).count >= Self.automaticAttemptsPerHour {
                if ledger.attempt == nil || ledger.attempt?.outcome == nil {
                    let nonce = KeyExchange.nonce()
                    var stopped = KeyLedger.Attempt(nonce: nonce, commitment: "", startedAt: at)
                    stopped.outcome = .tooManyAttempts
                    ledger.attempt = stopped
                    saveLedger()
                }
                return nil
            }
            ledger.automaticAttempts.append(at)
        }
        let nonce = KeyExchange.nonce()
        guard let commitment = KeyExchange.commitment(publicKey: credentials.deviceKey.publicKey, nonce: nonce) else { return nil }
        let attempt = KeyLedger.Attempt(nonce: nonce, commitment: commitment, startedAt: at)
        ledger.attempt = attempt
        pendingGrantKey = nil
        saveLedger()
        return attempt
    }

    func requesterTranscript(_ attempt: KeyLedger.Attempt, _ credentials: SyncCredentials) -> KeyExchange.Transcript? {
        guard let answer = attempt.answer else { return nil }
        return KeyExchange.Transcript(libraryID: credentials.libraryID, requester: credentials.deviceID, requesterKey: credentials.deviceKey.publicKey,
                                      requesterNonce: attempt.nonce, holder: answer.holder, holderKey: answer.holderKey,
                                      holderNonce: answer.holderNonce)
    }

    /// Moves this device's own request along: commit, record the first answer, reveal, open the grant.
    func advanceOwnRequest(grant: KeyGrantRow?) {
        guard let credentials, credentials.libraryKey == nil, serverKeyID != nil, let own = selfDevice else { return }
        switch own.keyState {
        case .holder?, .denied?:
            // A holder without a key here can do nothing; a denied device waits for Ask Again.
            return
        case .granted?:
            receiveGrant(grant, credentials: credentials)
        case .requested?, nil:
            continueRequest(own)
        }
    }

    private func continueRequest(_ own: SyncDevice) {
        var attempt: KeyLedger.Attempt
        if let current = ledger.attempt {
            guard current.outcome == nil else { return }
            attempt = current
        } else {
            guard let started = startAttempt(automatic: true) else { updateKeyStatus(); return }
            attempt = started
        }
        let exchange = own.exchange
        guard exchange?.commitment == attempt.commitment else {
            if attempt.answer == nil {
                sendRequest(attempt.commitment)
            } else if let started = startAttempt(automatic: true) {
                // The exchange was dropped after a holder answered (it left, or the key was replaced): start over.
                sendRequest(started.commitment)
            }
            return
        }
        guard let answer = exchange?.answer else { return }
        if attempt.answer == nil {
            guard let nonce = Data(base64Encoded: answer.holderNonce), nonce.count == 32 else { return }
            attempt.answer = .init(holder: answer.holder, holderKey: answer.holderKey, holderNonce: nonce)
            ledger.attempt = attempt
            saveLedger()
        }
        // Reveal only after an answer was recorded, and only for this attempt's first answer.
        guard !attempt.revealed else { return }
        let commitment = attempt.commitment
        let nonce = attempt.nonce.base64EncodedString()
        once("reveal:\(commitment)") { service, ticket in
            guard let token = service.credentials?.token, service.ledger.attempt?.commitment == commitment else { return }
            do {
                _ = try await service.call("keys:reveal", RevealKeyArgs(token: token, commitment: commitment, nonce: nonce), as: ServerNowResult.self, ticket: ticket)
                guard service.ledger.attempt?.commitment == commitment else { return }
                service.ledger.attempt?.revealed = true
                service.saveLedger()
                service.updateKeyStatus()
            } catch is CancellationError {
            } catch {
                service.lastError = SyncError.from(error)
            }
        }
    }

    private func sendRequest(_ commitment: String) {
        once("request:\(commitment)") { service, ticket in
            guard let token = service.credentials?.token, service.ledger.attempt?.commitment == commitment else { return }
            do {
                _ = try await service.call("keys:request", RequestKeyArgs(token: token, commitment: commitment), as: ServerNowResult.self, ticket: ticket)
            } catch is CancellationError {
            } catch {
                service.lastError = SyncError.from(error)
            }
        }
    }

    /// A holder wrapped the key to this device. It counts only if it belongs to this device's current exchange and
    /// opens under the transcript this device recorded; it is used only once the listener confirmed the code.
    private func receiveGrant(_ grant: KeyGrantRow?, credentials: SyncCredentials) {
        guard var attempt = ledger.attempt, attempt.outcome == nil else { return }
        guard let grant, grant.commitment == attempt.commitment, attempt.revealed,
              let transcript = requesterTranscript(attempt, credentials) else {
            // A grant that belongs to no exchange of this device (an old one, or made up): ask anew.
            if let started = startAttempt(automatic: true) { sendRequest(started.commitment) }
            return
        }
        if pendingGrantKey == nil {
            guard !failedKeyBlobs.contains(grant.wrapped) else { return }
            do {
                pendingGrantKey = try KeyExchange.unwrap(grant.wrapped, transcript: transcript, requester: credentials.deviceKey, keyId: grant.keyId)
            } catch {
                failedKeyBlobs.insert(grant.wrapped)
                attempt.outcome = .grantDidNotOpen
                ledger.attempt = attempt
                ledger.failures.append(.init(at: now(), kind: .didNotOpen))
                saveLedger()
                lastError = SyncError.from(error)
                return
            }
        }
        if attempt.confirmed { commitGrantedKey() }
    }

    /// Keeps the key from a grant that opened and whose code the listener confirmed, and tells the server.
    ///
    /// The key is saved before anything else changes: once the server hears `keys:accept` it deletes the grant and
    /// lists this device as a holder, so a key that only lived in memory would be gone after a relaunch with no way
    /// back (Ask Again leaves holders alone). When the save fails, the grant, the opened key and the attempt all
    /// stay, nothing is acknowledged, and the next device list tries again.
    private func commitGrantedKey() {
        guard let key = pendingGrantKey, var credentials, credentials.libraryKey == nil else { return }
        credentials.libraryKey = key
        guard store.persist(credentials) else {
            lastError = .server("\(ProductInfo.name) couldn't save the key for your sign-ins. It tries again in a moment.")
            return
        }
        self.credentials = credentials
        pendingGrantKey = nil
        ledger.attempt = nil
        saveLedger()
        updateKeyStatus()
        signIns.reconcileAll()
        acceptKey(key.id)
    }

    private func acceptKey(_ keyId: String) {
        once("accept:\(keyId)") { service, ticket in
            guard let token = service.credentials?.token else { return }
            _ = try? await service.call("keys:accept", AcceptKeyArgs(token: token, keyId: keyId), as: ServerNowResult.self, ticket: ticket)
        }
    }

    /// This device took a granted key but the server still shows the grant (the accept didn't arrive): say it again.
    private func retryAcceptIfNeeded(grant: KeyGrantRow?) {
        guard let grant, let key = credentials?.libraryKey, key.id == grant.keyId, selfDevice?.keyState == .granted else { return }
        acceptKey(key.id)
    }

    // MARK: Answering as a holder

    private func answeringAllowed() -> Bool {
        let at = now()
        let lastHour = ledger.answers.values.filter { $0.at > at.addingTimeInterval(-3600) }.count
        let failures = ledger.failures(since: at.addingTimeInterval(-24 * 3600)).count
        return lastHour < Self.answersPerHour && failures < Self.failuresBeforePause
    }

    /// Answers each new commitment once, while this device holds the account's key. The nonce is fresh for each
    /// request and the same for a request shown again (`KeyExchange.answerNonce`, which covers the asking device's id
    /// and key as well as its commitment); every answer stays in the ledger and counts toward `answersPerHour`,
    /// whatever the server replies.
    private func answerKeyRequests() {
        guard holdsCurrentKey, let credentials else { return }
        for device in otherDevices {
            guard device.keyState == .requested, case .committed(let commitment)? = device.exchange, let publicKey = device.publicKey else { continue }
            if let answer = ledger.answers[commitment] {
                if !answer.sent, answer.device == device.id { sendAnswer(commitment, answer) }
                continue
            }
            guard answeringAllowed() else { continue }
            guard let nonce = KeyExchange.answerNonce(holder: credentials.deviceKey, holderID: credentials.deviceID, libraryID: credentials.libraryID,
                                                      requester: device.id, requesterKey: publicKey, commitment: commitment) else { continue }
            let answer = KeyLedger.Answer(device: device.id, recipientKey: publicKey, nonce: nonce, at: now())
            // Recorded before it is sent: this nonce is the only one this device ever uses for this request.
            ledger.answers[commitment] = answer
            saveLedger()
            sendAnswer(commitment, answer)
        }
    }

    private func sendAnswer(_ commitment: String, _ answer: KeyLedger.Answer) {
        once("answer:\(commitment)") { service, ticket in
            guard let token = service.credentials?.token, service.ledger.answers[commitment]?.sent == false else { return }
            let args = AnswerKeyArgs(token: token, deviceId: answer.device, commitment: commitment, nonce: answer.nonce.base64EncodedString())
            do {
                _ = try await service.call("keys:answer", args, as: ServerNowResult.self, ticket: ticket)
                service.ledger.answers[commitment]?.sent = true
                service.saveLedger()
            } catch is SyncConflict {
                // Another holder answered first, or the device asked anew. Or the server says so after reading the
                // nonce, to have this device answer the same commitment again: the record stays (it counts toward
                // the hourly limit and keeps this commitment's one nonce) and isn't sent again.
                service.ledger.answers[commitment]?.sent = true
                service.saveLedger()
            } catch {}
        }
    }

    /// An exchange this device answered was revealed: check the nonce against the commitment (and that this
    /// device's own nonce came back unchanged). One that doesn't check out is refused and never shown.
    private func checkRevealedRequests() {
        guard let me = selfID else { return }
        for device in otherDevices {
            guard case .revealed(let commitment, let holder, _, let holderNonce, let nonce)? = device.exchange, holder == me,
                  var answer = ledger.answers[commitment], answer.device == device.id, answer.state == .waiting else { continue }
            let revealed = Data(base64Encoded: nonce)
            guard holderNonce == answer.nonce.base64EncodedString(), let revealed, revealed.count == 32,
                  KeyExchange.commitment(publicKey: answer.recipientKey, nonce: revealed) == commitment else {
                answer.state = .tampered
                ledger.answers[commitment] = answer
                ledger.failures.append(.init(at: now(), kind: .tampered))
                saveLedger()
                let target = device.id
                once("deny:\(commitment)") { service, ticket in
                    guard let token = service.credentials?.token else { return }
                    _ = try? await service.call("keys:deny", DenyKeyArgs(token: token, deviceId: target, commitment: commitment), as: ServerNowResult.self, ticket: ticket)
                }
                continue
            }
            answer.revealedNonce = revealed
            answer.state = .verified
            ledger.answers[commitment] = answer
            saveLedger()
        }
    }

    func holderTranscript(_ answer: KeyLedger.Answer, revealed: Data, _ credentials: SyncCredentials) -> KeyExchange.Transcript {
        KeyExchange.Transcript(libraryID: credentials.libraryID, requester: answer.device, requesterKey: answer.recipientKey,
                               requesterNonce: revealed, holder: credentials.deviceID, holderKey: credentials.deviceKey.publicKey,
                               holderNonce: answer.nonce)
    }

    func verifiedKeyRequests() -> [KeyRequest] {
        #if DEBUG
        if let previewRequests { return previewRequests }
        #endif
        // Every observed input is read before anything can return early. `credentials` isn't observed: when this
        // returned at `guard let credentials` (a launch before sign-in), the only thing a view showing the requests
        // depended on was `previewRequests`, and the "Allow …?" alert never came up for a real request.
        let others = otherDevices, me = selfID, answers = ledger.answers, current = holdsCurrentKey
        guard let credentials, current, let me else { return [] }
        return others.compactMap { device in
            guard device.keyState == .requested, case .revealed(let commitment, let holder, _, _, _)? = device.exchange, holder == me,
                  let answer = answers[commitment], answer.device == device.id, answer.state == .verified,
                  let revealed = answer.revealedNonce else { return nil }
            return KeyRequest(device: device, code: holderTranscript(answer, revealed: revealed, credentials).code, commitment: commitment)
        }
    }

    /// Gives the vault key to a device whose code the listener compared: sealed for the exchange, so only that
    /// device opens it. Replaces the key first when a device that could open the vault left.
    public func allowKey(for request: KeyRequest) async throws {
        try await operations.run { ticket in try await self.performAllowKey(request, ticket) }
    }

    private func performAllowKey(_ request: KeyRequest, _ ticket: AccountOperations.Ticket) async throws {
        guard let answer = ledger.answers[request.commitment], answer.state == .verified, let revealed = answer.revealedNonce else {
            throw SyncError.keyGrantFailed("that request changed; check its code again")
        }
        if rotationNeeded { try await performRotation(ticket) }
        guard let credentials, let key = credentials.libraryKey, key.id == serverKeyID else { throw SyncError.libraryKeyMismatch }
        let transcript = holderTranscript(answer, revealed: revealed, credentials)
        let wrapped = try KeyExchange.wrap(key, transcript: transcript, holder: credentials.deviceKey)
        let args = GrantKeyArgs(token: credentials.token, deviceId: answer.device, keyId: key.id, wrapped: wrapped, commitment: request.commitment)
        _ = try await call("keys:grant", args, as: ServerNowResult.self, ticket: ticket)
        ledger.answers[request.commitment]?.state = .allowed
        saveLedger()
    }

    /// Says no to a device asking for the vault key. It stops asking until it asks again. Only for the exchange the
    /// listener saw: a request that ended or was replaced (the device asked again) throws, and the server leaves a
    /// newer exchange alone too (`keys:deny` with the commitment).
    public func denyKey(for request: KeyRequest) async throws {
        try await operations.run { ticket in
            guard self.verifiedKeyRequests().contains(where: { $0.id == request.id && $0.commitment == request.commitment }) else {
                throw SyncError.keyGrantFailed("that request changed; check its code again")
            }
            let args = DenyKeyArgs(token: try self.requireToken(), deviceId: request.device.id, commitment: request.commitment)
            _ = try await self.call("keys:deny", args, as: ServerNowResult.self, ticket: ticket)
            self.ledger.answers[request.commitment]?.state = .denied
            self.ledger.failures.append(.init(at: self.now(), kind: .denied))
            self.saveLedger()
        }
    }

    // MARK: Rotation

    private func rotateKeyIfNeeded() {
        guard rotationNeeded, holdsCurrentKey, vaultEntries != nil, sealedSettings != nil else { return }
        once("rotate") { service, ticket in
            guard service.rotationNeeded, service.holdsCurrentKey else { return }
            try? await service.performRotation(ticket)
        }
    }

    /// Replaces the account's vault key: a fresh key, wrapped (with the old key mixed in) to every other holder,
    /// and every sealed vault row re-sealed under it at its next revision. Runs as an account operation.
    func rotateKey() async throws {
        try await operations.run { ticket in try await self.performRotation(ticket) }
    }

    func performRotation(_ ticket: AccountOperations.Ticket) async throws {
        guard var credentials, let old = credentials.libraryKey, serverKeyID == old.id else { throw SyncError.libraryKeyMismatch }
        guard let entries = vaultEntries, let settingRows = sealedSettings, let me = selfID else {
            throw SyncError.server("Your sign-ins haven't loaded yet. Try again in a moment.")
        }
        let next = credentials.nextLibraryKey ?? LibraryKey.generate()
        if credentials.nextLibraryKey == nil {
            credentials.nextLibraryKey = next
            // Settled only by a list newer than this one (`settleSavedRotation`).
            credentials.nextLibraryKeyRevision = appliedKeyRevision
            guard store.persist(credentials) else { throw SyncError.server("\(ProductInfo.name) couldn't save a new key for your sign-ins. Try again in a moment.") }
            self.credentials = credentials
        }
        var wraps: [RotateKeyArgs.Wrap] = []
        for device in otherDevices where device.keyState == .holder {
            guard let publicKey = device.publicKey else { continue }
            let wrapped = try KeyRotation.wrap(next, replacing: old, to: publicKey, libraryID: credentials.libraryID, deviceID: device.id)
            wraps.append(.init(deviceId: device.id, wrapped: wrapped))
        }
        let vault = entries.filter { $0.sealed != nil }.map { entry -> RotateKeyArgs.Reseal in
            let opened: Data? = entry.keyId != old.id ? nil : entry.sealed.flatMap { sealed in
                entry.revision == 0
                    ? try? SignInSealing.openLegacy(sealed, provider: entry.provider, key: old)
                    : try? SignInSealing.open(sealed, provider: entry.provider, revision: entry.revision, key: old)
            }
            let sealed = opened.flatMap { try? SignInSealing.seal($0, provider: entry.provider, revision: entry.revision + 1, key: next) }
            return .init(provider: entry.provider, baseRevision: entry.revision, sealed: sealed)
        }
        // Every settings value, re-sealed under the new key in the same transaction, so settings never sit under a key
        // the account retired. The server makes this device the row's writer, so it seals as itself; a row that
        // doesn't open with the old key is deleted (nobody could read it).
        let settings = settingRows.map { row -> RotateKeyArgs.ResealSetting in
            let opened = try? ContentSealing.open(row.value, kind: .setting, library: credentials.libraryID, writer: row.updatedBy, context: row.key, key: old)
            let resealed = opened.flatMap { try? ContentSealing.seal($0, kind: .setting, library: credentials.libraryID, writer: me, context: row.key, key: next) }
            return .init(key: row.key, baseUpdatedAt: row.updatedAt, value: resealed)
        }
        let args = RotateKeyArgs(token: credentials.token, fromKeyId: old.id, keyId: next.id, wraps: wraps, vault: vault, settings: settings)
        let decidedAt = appliedKeyRevision
        let result: RotateKeyResult
        do {
            result = try await call("keys:rotate", args, as: RotateKeyResult.self, ticket: ticket)
        } catch SyncError.server(let message) where message.contains("new key") {
            // Refused outright (a key the account used before): it never landed, so the next rotation makes a new one.
            if var current = self.credentials, current.nextLibraryKey == next {
                current.nextLibraryKey = nil
                current.nextLibraryKeyRevision = nil
                self.credentials = current
                store.save(current)
            }
            throw SyncError.server(message)
        }
        // The answer is an observation like a device list: it must be newer than the state the rotation was decided
        // on (the rotation moved the revision), or it proves nothing, and the saved key stays for a list to settle.
        guard observe(result.keyRevision, after: decidedAt) else { return }
        adoptRotatedKey(next)
    }

    /// An answer that reports the key revision after a change this device made (`keys:claim`, `keys:rotate`). It
    /// counts only if it is newer than `decidedAt`, the revision the change was decided on (the change moved it), and
    /// not older than what this session already applied; then it is applied like a device list's revision, so older
    /// lists are ignored from now on. An answer without a revision (an older server) counts, as before.
    func observe(_ revision: Int?, after decidedAt: Int) -> Bool {
        guard let revision else { return true }
        guard revision > decidedAt, revision >= appliedKeyRevision else { return false }
        appliedKeyRevision = revision
        return true
    }

    private func adoptRotatedKey(_ next: LibraryKey) {
        guard var credentials else { return }
        credentials.libraryKey = next
        credentials.nextLibraryKey = nil
        credentials.nextLibraryKeyRevision = nil
        self.credentials = credentials
        store.save(credentials)
        serverKeyID = next.id
        rotationNeeded = false
        updateKeyStatus()
        signIns.reconcileAll()
    }

    /// A rotation this device started whose answer didn't arrive: the server's key says whether it landed. When the
    /// server has moved past it with a rotation made from it (another holder took it and rotated again while this
    /// device was away), the saved key is kept for `receiveRekey` to open that rotation with: it is the only key
    /// that can.
    ///
    /// The saved key is dropped only on proof that it can no longer matter, from a list newer than the one the
    /// rotation was decided on (`nextLibraryKeyRevision`): the account moved to a key that is neither the one it was
    /// made from nor itself, and nothing waiting for this device was made from it. A rotation can only land on the key
    /// it was made from, which never comes back, so it can't land later. The account still on the key it was made
    /// from proves nothing (the rotation may still be on its way, or is retried with the same key), so it stays.
    private func settleSavedRotation(rekey: RekeyRow?, revision: Int) {
        guard var credentials, let next = credentials.nextLibraryKey else { return }
        if serverKeyID == next.id {
            adoptRotatedKey(next)
            return
        }
        if rekey?.fromKeyId == next.id { return }
        let fresh = revision > (credentials.nextLibraryKeyRevision ?? Int.max)
        guard fresh, serverKeyID != credentials.libraryKey?.id else { return }
        credentials.nextLibraryKey = nil
        credentials.nextLibraryKeyRevision = nil
        self.credentials = credentials
        store.save(credentials)
    }

    /// Another holder replaced the key: open the new key with this device's key pair and the key it was made from,
    /// the key this device holds or one it rotated to itself and never heard back about (`nextLibraryKey`). Either
    /// is a key only holders have, so a wrap that opens came from a holder. A wrap that doesn't open is refused and
    /// the held key stays.
    private func receiveRekey(_ rekey: RekeyRow?) {
        guard let rekey, var credentials, let me = selfID else { return }
        if credentials.libraryKey?.id == rekey.keyId {
            acceptKey(rekey.keyId)
            return
        }
        guard let old = heldKeys(credentials).first(where: { $0.id == rekey.fromKeyId }),
              rekey.keyId == serverKeyID, !failedKeyBlobs.contains(rekey.wrapped) else { return }
        do {
            let new = try KeyRotation.unwrap(rekey.wrapped, with: credentials.deviceKey, replacing: old, libraryID: credentials.libraryID,
                                             deviceID: me, keyId: rekey.keyId)
            credentials.libraryKey = new
            credentials.nextLibraryKey = nil
            credentials.nextLibraryKeyRevision = nil
            // Saved before it's acknowledged (see `commitGrantedKey`): an unsaved rotated key stays unaccepted, the
            // held key and any saved rotation stay as they were, and the next list opens the wrap again.
            guard store.persist(credentials) else {
                lastError = .server("\(ProductInfo.name) couldn't save the new key for your sign-ins. It tries again in a moment.")
                return
            }
            self.credentials = credentials
            updateKeyStatus()
            signIns.reconcileAll()
            acceptKey(new.id)
        } catch {
            failedKeyBlobs.insert(rekey.wrapped)
            ledger.failures.append(.init(at: now(), kind: .didNotOpen))
            saveLedger()
            lastError = SyncError.from(error)
        }
    }

    /// The server lists this device as a holder, but the key it holds isn't the account's and nothing here can
    /// reach the current one: no rotation or claim of its own is pending, and no rotated key waits that it could
    /// open (it was lost, or made from a key this device never had). As a `holder` it could never ask again, and an
    /// account whose only "holders" are like it would never be reset. So it tells the server it doesn't have the key
    /// (`keys:release`, refused when the server's key is the one named) and becomes a device that asks: its status
    /// turns `outdated`, and the held key is still kept until the listener taps Ask Again (`requestKeyAgain()`). If
    /// no device left can open the vault, the server resets the key and the next device to notice claims one.
    ///
    /// The list that suggested this may be stale (a poll answered late), so the decision is never made from it: the
    /// device fetches the account's state again, applies it (which tries every key it holds against a rotated key
    /// waiting for it, `receiveRekey`), and releases only if that state still leaves it stranded, telling the server
    /// the account key and waiting rotation it examined. The server refuses the release when either changed since.
    func releaseKeyIfStranded(rekey: RekeyRow?) {
        guard let credentials, let held = credentials.libraryKey, let server = serverKeyID, server != held.id,
              selfDevice?.keyState == .holder, !operations.isPending("rotate"), credentials.nextLibraryKey?.id != server,
              credentials.claimingLibraryKey == nil, !operations.isPending("claim") else { return }
        if let rekey, canOpen(rekey, accountKey: server) { return }
        once("release:\(held.id)") { service, ticket in
            await service.releaseAfterLookingAgain(held, ticket)
        }
    }

    /// Whether a rotated key waiting for this device may open with a key it holds (it is tried in `receiveRekey`).
    private func canOpen(_ rekey: RekeyRow, accountKey: String) -> Bool {
        guard let credentials, rekey.keyId == accountKey, !failedKeyBlobs.contains(rekey.wrapped) else { return false }
        return heldKeys(credentials).contains { $0.id == rekey.fromKeyId }
    }

    /// Every key this device holds that a rotation could have been made from: the key it uses and one it rotated to
    /// itself without hearing back.
    private func heldKeys(_ credentials: SyncCredentials) -> [LibraryKey] {
        [credentials.libraryKey, credentials.nextLibraryKey].compactMap { $0 }
    }

    /// Runs as one account operation, so nothing else changes this device's keys between the fresh look and the
    /// release: the decision and the call are made on the same state.
    private func releaseAfterLookingAgain(_ held: LibraryKey, _ ticket: AccountOperations.Ticket) async {
        guard let token = credentials?.token, credentials?.libraryKey == held else { return }
        let fresh: DeviceListResult
        do {
            fresh = try await fetchDeviceList(token: token)
            try ticket.check(operations)
        } catch is CancellationError {
            return
        } catch {
            guard ticket.isValid(operations) else { return }
            lastError = SyncError.from(error)
            report(error, token: token)
            return
        }
        guard credentials?.token == token, fresh.selfId == selfID else { return }
        // An answer older than what this device already applied decides nothing.
        guard (fresh.keyRevision ?? 0) >= appliedKeyRevision else { return }
        // Fresher than the list that brought this device here: a rotated key it can open is taken now.
        applyNow(fresh)
        guard let credentials, credentials.libraryKey == held, let account = fresh.keyId, account != held.id,
              fresh.devices.first(where: { $0.id == fresh.selfId })?.keyState == .holder, !operations.isPending("rotate"),
              credentials.nextLibraryKey == nil, credentials.claimingLibraryKey == nil,
              !operations.isPending("claim") else { return }
        if let rekey = fresh.rekey, canOpen(rekey, accountKey: account) { return }
        let args = ReleaseKeyArgs(token: token, keyId: held.id, accountKeyId: account, rekeyKeyId: fresh.rekey?.keyId, keyRevision: fresh.keyRevision ?? 0)
        do {
            _ = try await call("keys:release", args, as: ServerNowResult.self, ticket: ticket)
        } catch is SyncConflict {
            // The server's key is the one held after all, or the account changed since this device looked: the
            // next device list decides again.
        } catch is CancellationError {
        } catch {
            lastError = SyncError.from(error)
        }
    }

    // MARK: An account without a key

    /// An account whose vault key is gone (nobody who could open it is left, or it never had one) gets one from the
    /// first device that notices: it makes a fresh key and claims it. A device that loses that race asks the winner.
    ///
    /// The key is saved (`claimingLibraryKey`) before the claim is sent, and a retry sends the same key: if the server
    /// took the claim and the answer was lost, or the app quit, the account's only key is still here, and
    /// `settleSavedClaim` adopts it once the server names it.
    func claimLibraryKeyIfNeeded(serverKey: String?) {
        guard serverKey == nil, credentials != nil else { return }
        once("claim") { service, ticket in
            guard var credentials = service.credentials, service.serverKeyID == nil else { return }
            let token = credentials.token
            // Always a key this device made for this claim: the account starts over with a key no removed device had.
            let key: LibraryKey
            if let saved = credentials.claimingLibraryKey {
                key = saved
            } else {
                key = LibraryKey.generate()
                credentials.claimingLibraryKey = key
                // The state the claim is decided on: the server takes it only on that revision (compare-and-swap),
                // and a list newer than it settles the saved key (`settleSavedClaim`).
                credentials.claimingLibraryKeyRevision = service.appliedKeyRevision
                guard service.store.persist(credentials) else {
                    service.lastError = .server("\(ProductInfo.name) couldn't save a new key for your sign-ins. It tries again later.")
                    return
                }
                service.credentials = credentials
            }
            // A retry sends the revision the claim was first decided on, never a newer one: the claim may already be
            // on its way with it, and must never be able to land on a later state than the one it was made for.
            let decidedAt = credentials.claimingLibraryKeyRevision ?? 0
            do {
                let args = ClaimKeyArgs(token: token, keyId: key.id, keyRevision: decidedAt)
                let result = try await service.callReportingCodes("keys:claim", args, as: ClaimKeyResult.self, ticket: ticket)
                guard result.keyId == key.id, service.credentials?.token == token else { return }
                // Adopting it is safe whatever revision the answer names (only this device ever had the key); the
                // revision counts as an observation only when it is newer than what this session saw.
                _ = service.observe(result.keyRevision, after: decidedAt)
                service.adoptClaimedKey(key)
            } catch is CancellationError {
                // Overtaken: the key stays saved for whoever settles it.
            } catch let error as ConvexClientError where error.code == "forbidden" || error.code == "conflict" {
                // Refused: the account has a key again, this one is retired, or the account changed since this device
                // looked. It didn't land, and no copy of it can land later (the revision it carries is gone for good),
                // so the next claim makes a new key from what the account looks like then.
                service.dropClaimingKey(key)
                service.updateKeyStatus()
            } catch {
                // Not known to have landed: the key stays saved, and the next device list settles it.
                if SyncError.from(error) == .removedFromLibrary { service.report(error, token: token) }
                service.updateKeyStatus()
            }
        }
    }

    /// Takes the claimed key as this device's. `serverKey` is the key the account names now (nil: the claimed one).
    private func adoptClaimedKey(_ key: LibraryKey, serverKey: String? = nil) {
        guard var credentials else { return }
        credentials.libraryKey = key
        credentials.nextLibraryKey = nil
        credentials.nextLibraryKeyRevision = nil
        credentials.claimingLibraryKey = nil
        credentials.claimingLibraryKeyRevision = nil
        self.credentials = credentials
        store.save(credentials)
        serverKeyID = serverKey ?? key.id
        ledger.attempt = nil
        pendingGrantKey = nil
        saveLedger()
        updateKeyStatus()
        signIns.reconcileAll()
    }

    private func dropClaimingKey(_ key: LibraryKey) {
        guard var credentials, credentials.claimingLibraryKey == key else { return }
        credentials.claimingLibraryKey = nil
        credentials.claimingLibraryKeyRevision = nil
        self.credentials = credentials
        store.save(credentials)
    }

    /// A claim this device sent whose answer didn't arrive: the server's key says whether it landed. Adopting it is
    /// safe whatever the server says, since only this device ever had that key.
    ///
    /// The server takes a claim only on the revision it was decided on (`claimingLibraryKeyRevision`, compare-and-
    /// swap), and that claim would move the revision on with the account naming its key. So a list newer than that
    /// revision settles it for good: naming the key, it landed; naming another key or none, it didn't and never can.
    /// The one exception is a rotation made from the claimed key waiting for this device (it landed, and a holder it
    /// gave the key to rotated since): the key is taken, and the rotation opens with it. A list at that revision or
    /// older proves nothing, and the key stays.
    private func settleSavedClaim(rekey: RekeyRow?, revision: Int) {
        guard let credentials, let claiming = credentials.claimingLibraryKey, !operations.isPending("claim") else { return }
        if serverKeyID == claiming.id || rekey?.fromKeyId == claiming.id {
            adoptClaimedKey(claiming, serverKey: serverKeyID)
        } else if let decidedAt = credentials.claimingLibraryKeyRevision, revision > decidedAt {
            // Another device claimed first (this one asks it), or the account moved on without this claim.
            dropClaimingKey(claiming)
        }
    }
}

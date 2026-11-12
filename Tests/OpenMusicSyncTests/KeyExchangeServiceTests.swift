import Foundation
import OpenMusicCore
import Observation
import Testing
@testable import OpenMusicSync

/// The key exchange between real `SyncService`s through `FakeKeyServer`, with the server honest and not.
@MainActor
@Suite(.serialized) struct KeyExchangeServiceTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String, store: MemoryCredentialStore = MemoryCredentialStore()) -> SyncService {
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: store, transport: transport, http: server.http(), options: fastOptions(fallbackAfter: 1))
    }

    func signIn(_ service: SyncService) async throws {
        try await service.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
    }

    func comparison(_ service: SyncService) -> SyncService.KeyComparison? {
        if case .comparing(let c) = service.keyStatus { c } else { nil }
    }

    /// The Mac holds the key; the phone (already signed in to Spotify) asks for it. Returns both, once both show a code.
    func macAndAskingPhone(_ server: FakeKeyServer, phoneSignIn: FakeSignIn? = nil) async throws -> (mac: SyncService, phone: SyncService) {
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        #expect(mac.keyStatus == .available)
        let phone = device(server, "Leo's iPhone")
        if let phoneSignIn { phone.signIns.register(phoneSignIn) }
        try await signIn(phone)
        #expect(await waitUntil { comparison(phone) != nil })
        return (mac, phone)
    }

    @Test func bothDevicesShowOneCodeAndTheKeyMovesOnlyAfterAllowThereAndConfirmHere() async throws {
        let server = FakeKeyServer()
        let spotify = FakeSignIn(.spotify, "the phone's own spotify sign-in")
        let (mac, phone) = try await macAndAskingPhone(server, phoneSignIn: spotify)
        #expect(await waitUntil { mac.keyRequests.count == 1 })
        let request = try #require(mac.keyRequests.first)
        let code = try #require(comparison(phone)).code
        #expect(request.code == code && request.device.name == "Leo's iPhone")
        #expect(comparison(phone)?.holderName == "Leo's Mac")
        // The holder answered once, after the commitment; the phone revealed once, after the answer.
        #expect(server.calls("keys:answer", by: "Leo's Mac").count == 1)
        #expect(server.calls("keys:reveal", by: "Leo's iPhone").count == 1)

        try await mac.allowKey(for: request)
        #expect(await waitUntil { comparison(phone)?.allowed == true })
        // Allowed there, not confirmed here: no key, nothing uploaded.
        #expect(phone.libraryKey == nil)
        #expect(server.calls("vault:put", by: "Leo's iPhone").isEmpty)

        phone.confirmKeyCode()
        #expect(await waitUntil { phone.keyStatus == .available })
        #expect(phone.libraryKey == mac.libraryKey)
        #expect(await waitUntil { server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        // Only now, with a verified key, does the phone's existing sign-in go up.
        #expect(await waitUntil { server.calls("vault:put", by: "Leo's iPhone").count == 1 })
        mac.stop()
        phone.stop()
    }

    /// What a view showing the holder's requests depends on (the "Allow …?" alert), read the way SwiftUI reads it:
    /// once, then again after each change it was told about. The live run of 2026-11-06 found the alert never came up:
    /// read before sign-in, the requests depended only on the unobserved credentials.
    @Test func aViewReadingTheRequestsBeforeSignInHearsOfTheRequest() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        let seen = RequestsObserver(mac)
        let paused = PausedObserver(mac)
        #expect(seen.count == 0 && paused.paused)
        try await signIn(mac)
        // The first device makes the key: the vault opens, and a view showing that hears of it.
        #expect(mac.vaultWritesPaused == false)
        #expect(await waitUntil { paused.paused == false })
        let phone = device(server, "Leo's iPhone")
        try await signIn(phone)
        #expect(await waitUntil { mac.keyRequests.count == 1 })
        #expect(await waitUntil { seen.count == 1 })
        mac.stop()
        phone.stop()
    }

    /// Sol's review of the merge: "Don't Allow" remembered the device, so after it asked again the holder's alert
    /// never showed its new request. Dismissals belong to one exchange.
    @Test func aDeviceThatAsksAgainAfterDontAllowIsShownAgain() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await macAndAskingPhone(server)
        #expect(await waitUntil { mac.keyRequests.count == 1 })
        let first = try #require(mac.keyRequests.first)
        var dismissed = DismissedKeyRequests()
        #expect(dismissed.firstShown(in: mac.keyRequests) == first)
        // Don't Allow, as the alert's button does it.
        dismissed.dismiss(first)
        try await mac.denyKey(for: first)
        #expect(dismissed.firstShown(in: mac.keyRequests) == nil)
        #expect(await waitUntil { phone.keyStatus == .denied })

        try await phone.requestKeyAgain()
        #expect(await waitUntil { mac.keyRequests.first.map { $0.commitment != first.commitment } == true })
        let second = try #require(dismissed.firstShown(in: mac.keyRequests))
        #expect(second.id == first.id && second.commitment != first.commitment)
        // Settings › Account's Allow brings a dismissed one back too.
        dismissed.dismiss(second)
        #expect(dismissed.firstShown(in: mac.keyRequests) == nil)
        dismissed.show(second.id)
        #expect(dismissed.firstShown(in: mac.keyRequests) == second)
        mac.stop()
        phone.stop()
    }

    /// Sol's re-check: Don't Allow on an alert whose device asked again since must not deny the new exchange, here or
    /// on the server.
    @Test func aStaleDontAllowLeavesTheNewExchangeAlone() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await macAndAskingPhone(server)
        #expect(await waitUntil { mac.keyRequests.count == 1 })
        let stale = try #require(mac.keyRequests.first)
        phone.rejectKeyCode()
        try await phone.requestKeyAgain()
        #expect(await waitUntil { mac.keyRequests.first.map { $0.commitment != stale.commitment } == true })
        await #expect(throws: SyncError.self) { try await mac.denyKey(for: stale) }
        #expect(server.calls("keys:deny", by: "Leo's Mac").isEmpty)
        if case .requested = server.device(named: "Leo's iPhone")?.state {} else {
            Issue.record("the new exchange was denied: \(String(describing: server.device(named: "Leo's iPhone")?.state))")
        }
        // The current one can still be answered.
        try await mac.denyKey(for: try #require(mac.keyRequests.first))
        #expect(await waitUntil { phone.keyStatus == .denied })
        mac.stop()
        phone.stop()
    }

    @Test func confirmingBeforeTheHolderAllowsWorksToo() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await macAndAskingPhone(server)
        phone.confirmKeyCode()
        // Codes Match is an account operation: it runs once whatever runs now has finished.
        #expect(await waitUntil { comparison(phone)?.confirmed == true })
        #expect(phone.libraryKey == nil)
        #expect(await waitUntil { mac.keyRequests.count == 1 })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        #expect(await waitUntil { phone.keyStatus == .available })
        #expect(phone.libraryKey == mac.libraryKey)
        mac.stop()
        phone.stop()
    }

    @Test func codesThatDontMatchEndTheAttemptAndALaterGrantIsNeverUsed() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await macAndAskingPhone(server)
        phone.rejectKeyCode()
        #expect(await waitUntil { if case .failed = phone.keyStatus { true } else { false } })
        #expect(await waitUntil { mac.keyRequests.count == 1 })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.libraryKey == nil)
        guard case .failed = phone.keyStatus else { Issue.record("expected failed, got \(phone.keyStatus)"); return }

        // Ask Again starts a new exchange with a new commitment.
        let first = try #require(server.calls("keys:request", by: "Leo's iPhone").last?.args["commitment"]?.stringValue)
        try await phone.requestKeyAgain()
        let second = try #require(server.calls("keys:request", by: "Leo's iPhone").last?.args["commitment"]?.stringValue)
        #expect(first != second)
        #expect(await waitUntil { comparison(phone) != nil })
        mac.stop()
        phone.stop()
    }

    /// A server that changes the revealed nonce on its way to the holder (to steer the code) is caught: the holder
    /// never shows the request, refuses it, and warns.
    @Test func aHolderRefusesAnExchangeThatWasChangedOnTheWay() async throws {
        let server = FakeKeyServer()
        let fakeNonce = KeyExchange.nonce().base64EncodedString()
        server.rewrite { viewer, _, exchange in
            var e = exchange
            if viewer == "Leo's Mac", e.nonce != nil { e.nonce = fakeNonce }
            return e
        }
        let (mac, phone) = try await macAndAskingPhone(server)
        #expect(await waitUntil { server.calls("keys:deny", by: "Leo's Mac").count == 1 })
        #expect(mac.keyRequests.isEmpty)
        #expect(mac.keyWarning?.contains("changed on its way") == true)
        #expect(phone.libraryKey == nil)
        mac.stop()
        phone.stop()
    }

    /// A server that changes the holder's own nonce as relayed back to it is caught the same way.
    @Test func aHolderRefusesAnExchangeWhoseAnswerWasChanged() async throws {
        let server = FakeKeyServer()
        let other = KeyExchange.nonce().base64EncodedString()
        server.rewrite { viewer, _, exchange in
            var e = exchange
            if viewer == "Leo's Mac", e.nonce != nil { e.holderNonce = other }
            return e
        }
        let (mac, phone) = try await macAndAskingPhone(server)
        #expect(await waitUntil { server.calls("keys:deny", by: "Leo's Mac").count == 1 })
        #expect(mac.keyRequests.isEmpty)
        mac.stop()
        phone.stop()
    }

    /// The asking device keeps the first answer it saw: a server swapping the answer after the reveal (to make the
    /// phone show a code of its choosing) changes nothing on the phone.
    @Test func theAskingDeviceKeepsTheFirstAnswerItSaw() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await macAndAskingPhone(server)
        let code = try #require(comparison(phone)?.code)
        let impostor = DeviceKeyPair.generate().publicKey
        server.rewrite { viewer, _, exchange in
            var e = exchange
            if viewer == "Leo's iPhone" {
                e.holderKey = impostor
                e.holderNonce = KeyExchange.nonce().base64EncodedString()
            }
            return e
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(comparison(phone)?.code == code)
        #expect(server.calls("keys:reveal", by: "Leo's iPhone").count == 1)
        mac.stop()
        phone.stop()
    }

    /// The residual risk the design used to accept: a server handing a brand-new device a key of its own. Its grant
    /// can't open under the exchange the phone recorded (it doesn't have the Mac's private key), so the phone takes
    /// nothing and uploads nothing.
    @Test func aGrantTheServerMadeUpNeverOpensAndNothingIsUploaded() async throws {
        let server = FakeKeyServer()
        let spotify = FakeSignIn(.spotify, "the phone's spotify")
        let (mac, phone) = try await macAndAskingPhone(server, phoneSignIn: spotify)
        phone.confirmKeyCode()
        let phoneRow = try #require(server.device(named: "Leo's iPhone"))
        guard case .requested(let exchange?) = phoneRow.state, let holderNonce = exchange.holderNonce, let nonce = exchange.nonce else {
            Issue.record("exchange not revealed"); return
        }
        // The server knows every public value; it wraps its own key as "the Mac" using a key pair of its own.
        let serverPair = DeviceKeyPair.generate()
        let serverKey = LibraryKey.generate()
        let transcript = KeyExchange.Transcript(libraryID: LibraryID(rawValue: "lib"), requester: DeviceID(phoneRow.id), requesterKey: phoneRow.publicKey,
                                                requesterNonce: try #require(Data(base64Encoded: nonce)), holder: DeviceID(exchange.holder ?? ""),
                                                holderKey: serverPair.publicKey, holderNonce: try #require(Data(base64Encoded: holderNonce)))
        let forged = try KeyExchange.wrap(serverKey, transcript: transcript, holder: serverPair)
        server.setLibrary(keyId: serverKey.id, rotationNeeded: false)
        server.set("Leo's iPhone", state: .granted(keyId: serverKey.id, wrapped: forged, by: exchange.holder ?? "", commitment: exchange.commitment))
        #expect(await waitUntil { if case .failed = phone.keyStatus { true } else { false } })
        #expect(phone.libraryKey == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.calls("vault:put", by: "Leo's iPhone").isEmpty)
        #expect(server.calls("keys:accept", by: "Leo's iPhone").isEmpty)
        mac.stop()
        phone.stop()
    }

    /// A device that holds a key never replaces it from a grant, nor from a "rotation" not made with its key, and
    /// writes nothing while the server names another key. With no way to the key the server names, it steps down
    /// (`keys:release`); alone, the account then starts over with a fresh key of its own, never the server's.
    @Test func aHeldKeyIsPinned() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        let spotify = FakeSignIn(.spotify, "mac spotify")
        mac.signIns.register(spotify)
        try await signIn(mac)
        let held = try #require(mac.libraryKey)
        #expect(await waitUntil { server.calls("vault:put", by: "Leo's Mac").count == 1 })

        // A grant of another key, wrapped to the Mac: ignored.
        let other = LibraryKey.generate()
        let macRow = try #require(server.device(named: "Leo's Mac"))
        let pair = DeviceKeyPair.generate()
        let t = KeyExchange.Transcript(libraryID: LibraryID(rawValue: "lib"), requester: DeviceID(macRow.id), requesterKey: macRow.publicKey,
                                       requesterNonce: KeyExchange.nonce(), holder: DeviceID("x"), holderKey: pair.publicKey, holderNonce: KeyExchange.nonce())
        server.set("Leo's Mac", state: .granted(keyId: other.id, wrapped: try KeyExchange.wrap(other, transcript: t, holder: pair), by: "x", commitment: "c"))
        try await Task.sleep(for: .milliseconds(250))
        #expect(mac.libraryKey == held)

        // A real rotation, made with the held key, is taken.
        let next = LibraryKey.generate()
        server.setLibrary(keyId: next.id, rotationNeeded: false)
        let genuine = try KeyRotation.wrap(next, replacing: held, to: macRow.publicKey, libraryID: LibraryID(rawValue: "lib"), deviceID: DeviceID(macRow.id))
        server.set("Leo's Mac", state: .holder(rekey: .init(keyId: next.id, fromKeyId: held.id, wrapped: genuine, by: "x")))
        #expect(await waitUntil { mac.libraryKey == next })
        #expect(await waitUntil { mac.keyStatus == .available })

        // A "rotation" to a server key, wrapped without the held key: refused, and nothing is sealed for that key.
        // The Mac can't reach the key the server names, so it steps down; alone, the account is reset and it claims
        // a fresh key of its own.
        server.setLibrary(keyId: other.id, rotationNeeded: false)
        let forged = try KeyRotation.wrap(other, replacing: LibraryKey.generate(), to: macRow.publicKey, libraryID: LibraryID(rawValue: "lib"), deviceID: DeviceID(macRow.id))
        server.set("Leo's Mac", state: .holder(rekey: .init(keyId: other.id, fromKeyId: next.id, wrapped: forged, by: "x")))
        spotify.localChange("mac spotify, rotated")
        #expect(await waitUntil { !server.calls("keys:release", by: "Leo's Mac").isEmpty })
        #expect(await waitUntil { mac.keyStatus == .available && mac.libraryKey?.id == server.keyId })
        let fresh = try #require(mac.libraryKey)
        #expect(fresh != other && fresh != next && fresh != held)
        #expect(server.calls("vault:put", by: "Leo's Mac").allSatisfy { $0.args["keyId"]?.stringValue != other.id })
        mac.stop()
    }

    /// A device that could open the vault left: a remaining holder replaces the key, re-seals the vault and wraps
    /// the new key to the other holders, who take it.
    @Test func removingAHolderRotatesTheKeyAcrossTheRemainingHolders() async throws {
        let server = FakeKeyServer()
        let spotify = FakeSignIn(.spotify, "mac spotify")
        let mac = device(server, "Leo's Mac")
        mac.signIns.register(spotify)
        try await signIn(mac)
        #expect(await waitUntil { server.calls("vault:put", by: "Leo's Mac").count == 1 })
        let phone = device(server, "Leo's iPhone")
        let phoneSpotify = FakeSignIn(.spotify)
        phone.signIns.register(phoneSpotify)
        try await signIn(phone)
        #expect(await waitUntil { mac.keyRequests.count == 1 && comparison(phone) != nil })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        phone.confirmKeyCode()
        #expect(await waitUntil { phone.keyStatus == .available && phoneSpotify.text == "mac spotify" })
        let old = try #require(mac.libraryKey)
        let revision = try #require(server.vault.first?.revision)

        // A third holder, now lost, is removed.
        server.setLibrary(keyId: old.id, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != old.id && server.calls("keys:rotate").contains { $0.args["keyId"]?.stringValue == server.keyId } })
        #expect(await waitUntil { mac.libraryKey?.id == server.keyId && phone.libraryKey?.id == server.keyId })
        #expect(mac.libraryKey != old)
        let row = try #require(server.vault.first)
        #expect(row.revision == revision + 1 && row.keyId == server.keyId)
        let key = try #require(mac.libraryKey)
        #expect(try SignInSealing.open(try #require(row.sealed), provider: .spotify, revision: row.revision, key: key) == Data("mac spotify".utf8))
        #expect(await waitUntil { mac.keyStatus == .available && phone.keyStatus == .available })
        // Sign-ins keep syncing under the new key.
        spotify.localChange("mac spotify 2")
        #expect(await waitUntil { phoneSpotify.text == "mac spotify 2" })
        mac.stop()
        phone.stop()
    }

    /// A holder answers a limited number of new requests per hour, and warns after repeated failures.
    @Test func aHolderRateLimitsAnswersAndWarnsAboutFailures() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        let clock = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        mac.now = { clock.value }
        try await signIn(mac)
        // Eight devices ask (the server, or someone with the Clerk session, can make up as many as it likes).
        var askers: [SyncService] = []
        for i in 0..<8 {
            let other = device(server, "Asker \(i)")
            try await signIn(other)
            #expect(await waitUntil { !server.calls("keys:request", by: "Asker \(i)").isEmpty })
            askers.append(other)
        }
        defer { for other in askers { other.stop() } }
        #expect(await waitUntil { server.calls("keys:answer", by: "Leo's Mac").count == SyncService.answersPerHour })
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.calls("keys:answer", by: "Leo's Mac").count == SyncService.answersPerHour)
        #expect(mac.keyWarning?.contains("paused") == true)
        // An hour later the next change to the device list (or the next heartbeat) answers the rest.
        clock.value = clock.value.addingTimeInterval(3601)
        let late = device(server, "Asker 8")
        try await signIn(late)
        askers.append(late)
        #expect(await waitUntil { server.calls("keys:answer", by: "Leo's Mac").count == 9 })
        mac.stop()
    }

    /// A server that reads a holder's nonce and then replies `conflict` used to make the holder forget the answer:
    /// it could show the same commitment again for another nonce, or make up new commitments one after another,
    /// grinding codes until one matched a code it had fixed on another device. Every answer counts toward the
    /// hourly limit whatever the reply, and a commitment shown again gets the same nonce, even once the holder's
    /// record of it is gone.
    @Test func aServerReplyingConflictGetsOneNoncePerCommitmentAndNoMoreAnswersThanTheLimit() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        let clock = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        mac.now = { clock.value }
        try await signIn(mac)
        let answers = { server.calls("keys:answer", by: "Leo's Mac") }
        let nonces = { (commitment: String) in
            Set(answers().filter { $0.args["commitment"]?.stringValue == commitment }.compactMap { $0.args["nonce"]?.stringValue })
        }
        let commitment = KeyExchange.nonce().base64EncodedString()
        server.answerMischief(.conflictAndShowAgain)
        server.addAskingDevice("Made-up iPad", commitment: commitment)
        #expect(await waitUntil { !answers().isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        // What the heartbeat does every 30 s: answer what waits.
        mac.resumeKeyRequests()
        try await Task.sleep(for: .milliseconds(200))
        #expect(answers().count == 1)
        #expect(nonces(commitment).count == 1)

        // A new made-up commitment after every conflict: the hourly limit still holds.
        server.answerMischief(.conflictAndNewCommitment)
        server.set("Made-up iPad", state: .requested(.init(commitment: KeyExchange.nonce().base64EncodedString())))
        let answered = { Set(answers().compactMap { $0.args["commitment"]?.stringValue }) }
        #expect(await waitUntil { answered().count == SyncService.answersPerHour })
        try await Task.sleep(for: .milliseconds(400))
        #expect(answered().count == SyncService.answersPerHour)
        #expect(mac.keyWarning?.contains("paused") == true)

        // Two days on, with the record of the first answer gone, the first commitment shown again gets the same nonce.
        clock.value = clock.value.addingTimeInterval(2 * 24 * 3600)
        mac.ledger.answers.removeAll()
        server.answerMischief(.conflictAndShowAgain)
        server.set("Made-up iPad", state: .requested(.init(commitment: commitment)))
        #expect(await waitUntil { answers().filter { $0.args["commitment"]?.stringValue == commitment }.count == 2 })
        #expect(nonces(commitment).count == 1)
        mac.stop()
    }

    /// A holder offline through two rotations is moved back to asking by the server (it can't open a wrap made
    /// with a key it never took). It keeps its old key and asks nothing by itself; Ask Again drops the old key and
    /// gets the current one through the code comparison.
    @Test func aHolderThatMissedTwoRotationsKeepsItsKeyUntilTheListenerAsksAgain() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let phoneStore = MemoryCredentialStore()
        var phone = device(server, "Leo's iPhone", store: phoneStore)
        try await signIn(phone)
        #expect(await waitUntil { mac.keyRequests.count == 1 && comparison(phone) != nil })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        phone.confirmKeyCode()
        #expect(await waitUntil { phone.keyStatus == .available })
        let old = try #require(phone.libraryKey)
        server.setAway("Leo's iPhone", true)
        phone.stop()

        // Two devices that had the key leave while the phone is away: the Mac rotates twice.
        server.setLibrary(keyId: old.id, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != old.id && mac.libraryKey?.id == server.keyId })
        let second = server.keyId
        server.setLibrary(keyId: second, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != second && mac.libraryKey?.id == server.keyId })
        #expect(server.device(named: "Leo's iPhone")?.state == .requested(nil))

        server.setAway("Leo's iPhone", false)
        phone = device(server, "Leo's iPhone", store: phoneStore)
        try await signIn(phone)
        #expect(await waitUntil { phone.keyStatus == .outdated })
        let asked = server.calls("keys:request", by: "Leo's iPhone").count
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.libraryKey == old)
        #expect(server.calls("keys:request", by: "Leo's iPhone").count == asked)

        try await phone.requestKeyAgain()
        #expect(phone.libraryKey == nil)
        #expect(await waitUntil { mac.keyRequests.count == 1 && comparison(phone) != nil })
        #expect(mac.keyRequests.first?.code == comparison(phone)?.code)
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        phone.confirmKeyCode()
        #expect(await waitUntil { phone.keyStatus == .available })
        #expect(phone.libraryKey == mac.libraryKey && phone.libraryKey?.id == server.keyId)
        mac.stop()
        phone.stop()
    }

    /// Ask Again on a device that holds the account's key does nothing.
    @Test func askAgainNeverDropsTheAccountsKey() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let held = try #require(mac.libraryKey)
        #expect(await waitUntil { mac.keyStatus == .available })
        try await mac.requestKeyAgain()
        #expect(mac.libraryKey == held && mac.keyStatus == .available)
        #expect(server.calls("keys:request", by: "Leo's Mac").isEmpty)
        mac.stop()
    }

    /// A lone holder whose key the server no longer names, with nothing that leads to the named key, steps down
    /// (`keys:release`) instead of staying a holder of nothing; nobody left can open the vault, so the account is
    /// reset and the device claims a fresh key of its own, never the one the server named.
    @Test func aLoneHolderThatCantReachTheAccountsKeyStartsOverWithAFreshKey() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let held = try #require(mac.libraryKey)
        let named = LibraryKey.generate()
        server.setLibrary(keyId: named.id, rotationNeeded: false)
        #expect(await waitUntil { !server.calls("keys:release", by: "Leo's Mac").isEmpty })
        #expect(server.calls("keys:release", by: "Leo's Mac").first?.args["keyId"]?.stringValue == held.id)
        #expect(await waitUntil { mac.keyStatus == .available && mac.libraryKey?.id == server.keyId })
        #expect(mac.libraryKey != held && mac.libraryKey != named)
        #expect(server.calls("keys:request", by: "Leo's Mac").isEmpty)
        mac.stop()
    }

    /// The fresh key of a claim is saved before the claim goes out. When the server took it and the answer was
    /// lost, the device adopts it from the next device list, and so does the next launch if the app quit first.
    @Test func aClaimWhoseAnswerWasLostKeepsItsKey() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        try await signIn(mac)
        let old = try #require(mac.libraryKey)
        let saved = LockedBox<SyncCredentials?>(nil)
        server.loseClaimAnswer(true) { _ in saved.value = store.load() }
        server.setLibrary(keyId: nil, rotationNeeded: false)
        #expect(await waitUntil { server.keyId != nil })
        let claimed = try #require(server.keyId)
        #expect(saved.value?.claimingLibraryKey?.id == claimed)
        #expect(await waitUntil { mac.libraryKey?.id == claimed && mac.keyStatus == .available })
        #expect(mac.libraryKey != old && store.load()?.claimingLibraryKey == nil)
        mac.stop()

        // The app quit right after sending: launching from what was saved then adopts the key the server took.
        let relaunched = device(server, "Leo's Mac", store: MemoryCredentialStore(saved.value))
        try await signIn(relaunched)
        #expect(await waitUntil { relaunched.libraryKey?.id == claimed && relaunched.keyStatus == .available })
        relaunched.stop()
    }

    /// A claim the server refused never landed: its saved key is dropped, and the next claim makes a new one
    /// instead of sending a refused (perhaps retired) key forever.
    @Test func aRefusedClaimMakesANewKeyNextTime() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        server.refuseClaims(true)
        server.setLibrary(keyId: nil, rotationNeeded: false)
        let claimed = { Set(server.calls("keys:claim", by: "Leo's Mac").compactMap { $0.args["keyId"]?.stringValue }) }
        // At least one: a repeated delivery of the same device list may already have made a second claim (with a
        // new key, which is fine); what must never happen is a claim resending a refused key (checked below).
        #expect(await waitUntil { claimed().count >= 1 }, "claims so far: \(claimed().count)")
        // The next device list change tries again.
        server.addAskingDevice("Leo's iPad", commitment: KeyExchange.nonce().base64EncodedString())
        #expect(await waitUntil { claimed().count >= 2 })
        #expect(server.calls("keys:claim", by: "Leo's Mac").count == claimed().count)
        mac.stop()
    }

    @Test func anAccountLeftWithoutAKeyGetsAFreshOneNeverTheOldOne() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let old = try #require(mac.libraryKey)
        server.setLibrary(keyId: nil, rotationNeeded: false)
        #expect(await waitUntil { server.keyId != nil && mac.libraryKey?.id == server.keyId })
        #expect(mac.libraryKey != old)
        mac.stop()
    }

    // MARK: Registration whose answer was lost

    func registrations(_ server: FakeKeyServer) -> [(token: String, keyId: String)] {
        server.calls("account:register").compactMap { call in
            guard let token = call.args["token"]?.stringValue, let keyId = call.args["keyId"]?.stringValue else { return nil }
            return (token, keyId)
        }
    }

    /// The first device's token and proposed key are saved before `account:register` goes out. When the server took
    /// it and the answer was lost, the next attempt in the same session sends the same registration and adopts the
    /// key the server took, so the account's only holder is this device and not an orphaned row.
    @Test func aRegistrationWhoseAnswerWasLostKeepsItsKeyAndToken() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        let atSend = LockedBox<SyncService.PendingRegistration?>(nil)
        server.loseRegisterAnswer(true) { _ in atSend.value = savedRegistration(store) }
        await #expect(throws: SyncError.self) { try await signIn(mac) }
        let row = try #require(server.device(named: "Leo's Mac"))
        let sent = try #require(atSend.value)
        #expect(sent.token == row.token && sent.proposedKey.id == server.keyId && row.state == .holder(rekey: nil))
        #expect(!mac.isRegistered && mac.libraryKey == nil)

        server.loseRegisterAnswer(false)
        try await signIn(mac)
        #expect(server.devices.count == 1 && Set(registrations(server).map(\.token)) == [row.token])
        #expect(mac.selfID?.rawValue == row.id && mac.libraryKey?.id == server.keyId)
        #expect(await waitUntil { mac.keyStatus == .available })
        #expect(store.load()?.token == row.token && store.load()?.libraryKey?.id == server.keyId)
        #expect(savedRegistration(store) == nil)
        mac.stop()
    }

    /// The app quit before the lost answer: the next launch sends the same registration from what was saved.
    @Test func aRegistrationWhoseAnswerWasLostIsAdoptedAfterARelaunch() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.loseRegisterAnswer(true)
        await #expect(throws: SyncError.self) { try await signIn(mac) }
        mac.stop()
        let row = try #require(server.device(named: "Leo's Mac"))

        server.loseRegisterAnswer(false)
        let relaunched = device(server, "Leo's Mac", store: store)
        try await signIn(relaunched)
        #expect(server.devices.count == 1 && Set(registrations(server).map(\.token)) == [row.token])
        #expect(relaunched.selfID?.rawValue == row.id && relaunched.libraryKey?.id == server.keyId)
        #expect(await waitUntil { relaunched.keyStatus == .available })
        // It holds the account's key, so nothing needs claiming or asking.
        #expect(server.calls("keys:claim").isEmpty && server.calls("keys:request").isEmpty)
        #expect(savedRegistration(store) == nil)
        relaunched.stop()
    }

    /// A refused registration never landed: nothing of it is kept, and the next attempt (this session or the next
    /// launch) starts with a new token and key.
    @Test func aRefusedRegistrationStartsFresh() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.refuseRegistrations(true)
        await #expect(throws: SyncError.self) { try await signIn(mac) }
        #expect(savedRegistration(store) == nil && server.devices.isEmpty)

        server.refuseRegistrations(false)
        try await signIn(mac)
        let sent = registrations(server)
        #expect(sent.count == 2 && sent[0].token != sent[1].token && sent[0].keyId != sent[1].keyId)
        #expect(mac.libraryKey?.id == sent[1].keyId && server.keyId == sent[1].keyId)
        #expect(await waitUntil { mac.keyStatus == .available })
        mac.stop()

        // The same after a relaunch: a refusal leaves nothing saved to send again.
        let other = FakeKeyServer()
        other.refuseRegistrations(true)
        let phoneStore = MemoryCredentialStore()
        let phone = device(other, "Leo's iPhone", store: phoneStore)
        await #expect(throws: SyncError.self) { try await signIn(phone) }
        phone.stop()
        other.refuseRegistrations(false)
        let relaunched = device(other, "Leo's iPhone", store: phoneStore)
        try await signIn(relaunched)
        let tokens = registrations(other).map(\.token)
        #expect(tokens.count == 2 && tokens[0] != tokens[1])
        relaunched.stop()
    }

    /// The server took the registration but names another key by the time the device asks again (or lists the
    /// device as asking): the proposed key is dropped, never adopted, and the device asks like any other.
    @Test func aLostRegistrationTheServerNamesAnotherKeyForDropsItsKey() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.loseRegisterAnswer(true)
        await #expect(throws: SyncError.self) { try await signIn(mac) }
        let proposed = try #require(savedRegistration(store)).proposedKey
        server.set("Leo's Mac", state: .requested(nil))
        server.setLibrary(keyId: LibraryKey.generate().id, rotationNeeded: false)

        server.loseRegisterAnswer(false)
        try await signIn(mac)
        #expect(mac.isRegistered && mac.libraryKey == nil && store.load()?.libraryKey == nil)
        #expect(server.keyId != proposed.id && savedRegistration(store) == nil)
        mac.stop()
    }

    /// A registration saved for another user is never sent for this one.
    @Test func aSavedRegistrationIsOnlyForItsUser() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.loseRegisterAnswer(true)
        await #expect(throws: SyncError.self) { try await signIn(mac) }
        mac.stop()
        server.loseRegisterAnswer(false)
        let relaunched = device(server, "Leo's Mac", store: store)
        try await relaunched.signIn(auth: FakeTokens([jwt("v")]), userID: "v")
        let tokens = registrations(server).map(\.token)
        #expect(tokens.count == 2 && tokens[0] != tokens[1] && store.load()?.userID == "v")
        relaunched.stop()
    }
}

/// The registration a device saved before sending it and hasn't settled yet.
func savedRegistration(_ store: any SyncCredentialStore) -> SyncService.PendingRegistration? {
    store.state(SyncService.PendingRegistration.stateName).flatMap { try? JSONDecoder().decode(SyncService.PendingRegistration.self, from: $0) }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ value: Date) { _value = value }
    var value: Date {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Reads `keyRequests` under observation tracking and reads again after every change, as a SwiftUI view does.
@MainActor
final class RequestsObserver {
    private let service: SyncService
    private(set) var count = -1
    init(_ service: SyncService) { self.service = service; read() }
    private func read() {
        count = withObservationTracking { service.keyRequests.count } onChange: { [weak self] in
            Task { @MainActor in self?.read() }
        }
    }
}

/// The same for `vaultWritesPaused`.
@MainActor
final class PausedObserver {
    private let service: SyncService
    private(set) var paused = true
    init(_ service: SyncService) { self.service = service; read() }
    private func read() {
        paused = withObservationTracking { service.vaultWritesPaused } onChange: { [weak self] in
            Task { @MainActor in self?.read() }
        }
    }
}

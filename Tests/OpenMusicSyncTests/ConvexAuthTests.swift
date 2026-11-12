import Foundation
import Testing
@testable import OpenMusicSync

/// A token source that hands out the next token of a list (the last one again once the list runs out), or nil.
actor FakeTokens: AuthTokenProvider {
    private var tokens: [String?]
    private(set) var calls: [Bool] = []
    var fails = false

    init(_ tokens: [String?]) { self.tokens = tokens }

    func token(forceRefresh: Bool) async throws -> String? {
        calls.append(forceRefresh)
        if fails { throw URLError(.notConnectedToInternet) }
        return tokens.count > 1 ? tokens.removeFirst() : tokens.first ?? nil
    }

    func setFails(_ value: Bool) { fails = value }
    func set(_ next: [String?]) { tokens = next }
}

/// A JWT with the given lifetime (signature not checked by the client). The same arguments give the same text.
func jwt(_ name: String, lifetime: Double = 3600, issuedAt: Double = 1_800_000_000) -> String {
    func part(_ json: String) -> String { Data(json.utf8).base64URLEncodedString() }
    return "\(part(#"{"alg":"RS256"}"#)).\(part(#"{"sub":"\#(name)","iat":\#(issuedAt),"exp":\#(issuedAt + lifetime)}"#)).sig"
}

func identityTransition(querySet: (Int, Int), ts: (UInt64, UInt64), identity: (Int, Int)) -> String {
    #"{"type":"Transition","startVersion":{"querySet":\#(querySet.0),"ts":"\#(ConvexTimestamp(value: ts.0).encoded)","identity":\#(identity.0)},"endVersion":{"querySet":\#(querySet.1),"ts":"\#(ConvexTimestamp(value: ts.1).encoded)","identity":\#(identity.1)},"modifications":[]}"#
}

@Suite(.serialized) struct ConvexAuthTests {
    func makeClient(_ transport: FakeTransport, http: HTTPPoster = FakeHTTP(), fallbackAfter: Int = 3) -> ConvexClient {
        ConvexClient(deploymentURL: URL(string: "https://x.convex.cloud")!, transport: transport, http: http, options: fastOptions(fallbackAfter: fallbackAfter))
    }

    @Test func jwtLifetimeDecidesTheRefresh() throws {
        let claims = try #require(JWTClaims(jwt("u", lifetime: 60)))
        #expect(claims.exp == 1_800_000_060 && claims.iat == 1_800_000_000)
        let now = ContinuousClock.now
        let token = AuthToken(jwt("u", lifetime: 60), receivedAt: now)
        #expect(token.refreshAt == now + .seconds(50))
        #expect(!token.needsRefresh(at: now + .seconds(49)))
        #expect(token.needsRefresh(at: now + .seconds(50)))
        #expect(JWTClaims("not-a-jwt") == nil)
        #expect(AuthToken("opaque").refreshAt == nil)
    }

    @Test func authenticateGoesFirstOnEverySocket() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        let tokens = FakeTokens([jwt("a")])
        await client.setAuth(tokens)
        _ = client.subscribe("devices:list", args: .object([:]))
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { transport.sockets[0].messages(ofType: "ModifyQuerySet").count >= 1 })
        let types = transport.sockets[0].messages.compactMap { $0["type"]?.stringValue }
        #expect(Array(types.prefix(3)) == ["Connect", "Authenticate", "ModifyQuerySet"])
        let auth = try #require(transport.sockets[0].messages(ofType: "Authenticate").first)
        #expect(auth["tokenType"] == .string("User") && auth["value"] == .string(jwt("a")) && auth["baseVersion"] == .float64(0))
        #expect(await client.status.auth == .pending)

        // The server confirms: a transition that advances the identity.
        transport.sockets[0].receive(identityTransition(querySet: (0, 1), ts: (0, 1), identity: (0, 1)))
        #expect(await eventually { await client.status.auth == .authenticated })

        // A new socket authenticates again from version 0, before its query set.
        transport.sockets[0].serverClose()
        #expect(await eventually { transport.sockets.count == 2 })
        transport.sockets[1].open()
        #expect(await eventually { transport.sockets[1].messages(ofType: "ModifyQuerySet").count >= 1 })
        let again = transport.sockets[1].messages.compactMap { $0["type"]?.stringValue }
        #expect(Array(again.prefix(3)) == ["Connect", "Authenticate", "ModifyQuerySet"])
        #expect(transport.sockets[1].messages(ofType: "Authenticate").first?["baseVersion"] == .float64(0))
        await client.stop()
    }

    @Test func noProviderMeansNoAuthenticate() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await client.setAuth(FakeTokens([nil]))
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { await client.status.state == .connected })
        #expect(transport.sockets[0].messages(ofType: "Authenticate").isEmpty)
        #expect(await client.status.auth == .none)
        await client.stop()
    }

    @Test func refreshesBeforeExpiryOnTheOpenSocket() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        // 10.2 s lifetime: refreshed 10 s early, 0.2 s after it arrived.
        let first = jwt("a", lifetime: 10.2)
        let second = jwt("b", lifetime: 3600)
        let tokens = FakeTokens([first, second])
        await client.setAuth(tokens)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { transport.sockets[0].messages(ofType: "Authenticate").count == 2 })
        let refreshed = transport.sockets[0].messages(ofType: "Authenticate")[1]
        #expect(refreshed["value"] == .string(second) && refreshed["baseVersion"] == .float64(1))
        #expect(await tokens.calls.last == true, "a refresh skips the provider's cache")
        #expect(await client.currentIdentityVersion == 2)
        await client.stop()
    }

    @Test func anAuthErrorFetchesAFreshTokenAndReconnects() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        let tokens = FakeTokens([jwt("stale"), jwt("fresh")])
        await client.setAuth(tokens)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { transport.sockets[0].messages(ofType: "Authenticate").count == 1 })
        transport.sockets[0].receive(#"{"type":"AuthError","error":"Token expired","baseVersion":0,"authUpdateAttempted":true}"#)
        #expect(await eventually { transport.sockets[0].isClosed })
        #expect(await eventually { transport.sockets.count == 2 })
        transport.sockets[1].open()
        #expect(await eventually { transport.sockets[1].messages(ofType: "Authenticate").count == 1 })
        #expect(transport.sockets[1].messages(ofType: "Authenticate")[0]["value"] == .string(jwt("fresh")))
        #expect(await tokens.calls.contains(true))
        await client.stop()
    }

    @Test func repeatedRefusalsGiveUpAndRunWithoutAnIdentity() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await client.setAuth(FakeTokens([jwt("t1"), jwt("t2"), jwt("t3"), jwt("t4")]))
        await client.start()
        for i in 0..<3 {
            #expect(await eventually { transport.sockets.count == i + 1 })
            transport.sockets[i].open()
            #expect(await eventually { transport.sockets[i].messages(ofType: "Authenticate").count == 1 })
            transport.sockets[i].receive(#"{"type":"AuthError","error":"No auth provider found matching the given token","baseVersion":0,"authUpdateAttempted":true}"#)
        }
        #expect(await eventually { transport.sockets.count == 4 })
        transport.sockets[3].open()
        #expect(await eventually { await client.status.state == .connected })
        #expect(transport.sockets[3].messages(ofType: "Authenticate").isEmpty)
        #expect(await client.status.auth == .failed("No auth provider found matching the given token"))
        await client.stop()
    }

    @Test func removingTheProviderDropsTheIdentityOnTheOpenSocket() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await client.setAuth(FakeTokens([jwt("a")]))
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { await client.status.state == .connected })
        await client.setAuth(nil)
        let auths = transport.sockets[0].messages(ofType: "Authenticate")
        #expect(auths.count == 2)
        #expect(auths[1]["tokenType"] == .string("None") && auths[1]["baseVersion"] == .float64(1))
        #expect(await client.status.auth == .none)
        await client.stop()
    }

    @Test func httpCallsCarryTheBearerToken() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let http = FakeHTTP()
        let client = makeClient(transport, http: http, fallbackAfter: 1)
        await client.setAuth(FakeTokens([jwt("a")]))
        await client.start()
        #expect(await eventually { await client.status.httpFallback })
        _ = try await client.mutation("devices:heartbeat", args: .object([:]))
        let sent = try #require(http.requests.first { $0.path == "/api/mutation" })
        #expect(sent.headers["Authorization"] == "Bearer \(jwt("a"))")
        await client.stop()
    }

    @Test func aTokenThatExpiredWhileClosedIsReplacedBeforeTheSocketOpens() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        // Already inside its refresh window when it arrives.
        let tokens = FakeTokens([jwt("old", lifetime: 5), jwt("new")])
        await client.setAuth(tokens)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { transport.sockets[0].messages(ofType: "Authenticate").first?["value"] == .string(jwt("new")) })
        await client.stop()
    }
}

import Foundation

// The Convex WebSocket sync protocol, as spoken by `convex/src/browser/sync/protocol.ts` (npm `convex` 1.49).
// Client messages are JSON objects with a `type`; timestamps (`ts`) are u64 sent as base64 of 8 little-endian bytes.

/// A server timestamp. Compared numerically; sent back as its original base64 text.
struct ConvexTimestamp: Comparable, Hashable, Sendable {
    var value: UInt64
    var encoded: String { ConvexValue.base64LE(value) }

    static let zero = ConvexTimestamp(value: 0)

    init(value: UInt64) { self.value = value }

    init?(encoded: String) {
        guard let bits = ConvexValue.bitsFromBase64LE(encoded) else { return nil }
        value = bits
    }

    static func < (a: ConvexTimestamp, b: ConvexTimestamp) -> Bool { a.value < b.value }
}

struct StateVersion: Equatable, Sendable {
    var querySet: Int
    var ts: ConvexTimestamp
    var identity: Int

    static let initial = StateVersion(querySet: 0, ts: .zero, identity: 0)
}

enum QueryModification: Sendable, Equatable {
    case updated(queryID: Int, value: ConvexValue, journal: String?)
    case failed(queryID: Int, message: String, data: ConvexValue?, journal: String?)
    case removed(queryID: Int)
}

enum ServerMessage: Sendable, Equatable {
    case transition(start: StateVersion, end: StateVersion, modifications: [QueryModification])
    case transitionChunk(chunk: String, partNumber: Int, totalParts: Int, transitionID: String)
    case mutationSuccess(requestID: Int, value: ConvexValue, ts: ConvexTimestamp)
    case mutationFailure(requestID: Int, message: String, data: ConvexValue?)
    case actionResponse(requestID: Int)
    /// `baseVersion` is the identity version the error is about; `authUpdateAttempted` says it answers an
    /// `Authenticate` (rather than a function that ran with an expired token).
    case authError(String, baseVersion: Int?, authUpdateAttempted: Bool)
    case fatalError(String)
    case ping

    static func parse(_ text: String) throws -> ServerMessage {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            throw ConvexValueError("Server message is not an object with a type")
        }
        func int(_ key: String, in dict: [String: Any] = object) throws -> Int {
            guard let n = dict[key] as? NSNumber else { throw ConvexValueError("\(type).\(key) is missing") }
            return n.intValue
        }
        func string(_ key: String, in dict: [String: Any] = object) throws -> String {
            guard let s = dict[key] as? String else { throw ConvexValueError("\(type).\(key) is missing") }
            return s
        }
        func ts(_ key: String, in dict: [String: Any] = object) throws -> ConvexTimestamp {
            guard let t = ConvexTimestamp(encoded: try string(key, in: dict)) else { throw ConvexValueError("\(type).\(key) is malformed") }
            return t
        }
        func version(_ key: String) throws -> StateVersion {
            guard let v = object[key] as? [String: Any] else { throw ConvexValueError("\(type).\(key) is missing") }
            return StateVersion(querySet: try int("querySet", in: v), ts: try ts("ts", in: v), identity: try int("identity", in: v))
        }
        func optionalValue(_ raw: Any?) throws -> ConvexValue? {
            guard let raw else { return nil }
            return try ConvexValue(json: raw)
        }

        switch type {
        case "Ping":
            return .ping
        case "Transition":
            let mods = (object["modifications"] as? [[String: Any]]) ?? []
            return .transition(start: try version("startVersion"), end: try version("endVersion"), modifications: try mods.map { m in
                let id = try int("queryId", in: m)
                switch m["type"] as? String {
                case "QueryUpdated":
                    return .updated(queryID: id, value: try ConvexValue(json: m["value"] ?? NSNull()), journal: m["journal"] as? String)
                case "QueryFailed":
                    return .failed(queryID: id, message: (m["errorMessage"] as? String) ?? "Query failed",
                                   data: try optionalValue(m["errorData"]), journal: m["journal"] as? String)
                case "QueryRemoved":
                    return .removed(queryID: id)
                default:
                    throw ConvexValueError("Unknown modification \(m["type"] ?? "nil")")
                }
            })
        case "TransitionChunk":
            return .transitionChunk(chunk: try string("chunk"), partNumber: try int("partNumber"),
                                    totalParts: try int("totalParts"), transitionID: try string("transitionId"))
        case "MutationResponse":
            let id = try int("requestId")
            if (object["success"] as? Bool) == true {
                return .mutationSuccess(requestID: id, value: try ConvexValue(json: object["result"] ?? NSNull()), ts: try ts("ts"))
            }
            return .mutationFailure(requestID: id, message: (object["result"] as? String) ?? "Mutation failed",
                                    data: try optionalValue(object["errorData"]))
        case "ActionResponse":
            return .actionResponse(requestID: try int("requestId"))
        case "AuthError":
            return .authError((object["error"] as? String) ?? "", baseVersion: (object["baseVersion"] as? NSNumber)?.intValue,
                              authUpdateAttempted: (object["authUpdateAttempted"] as? Bool) ?? false)
        case "FatalError":
            return .fatalError((object["error"] as? String) ?? "")
        default:
            throw ConvexValueError("Unknown server message \(type)")
        }
    }
}

enum ClientMessage {
    static func connect(sessionID: String, connectionCount: Int, lastCloseReason: String?, maxObservedTimestamp: ConvexTimestamp?, clientTs: Double) -> String {
        var fields: [String: ConvexValue] = [
            "type": .string("Connect"),
            "sessionId": .string(sessionID),
            "connectionCount": .float64(Double(connectionCount)),
            "lastCloseReason": lastCloseReason.map(ConvexValue.string) ?? .null,
            "clientTs": .float64(clientTs.rounded()),
        ]
        if let maxObservedTimestamp { fields["maxObservedTimestamp"] = .string(maxObservedTimestamp.encoded) }
        return ConvexValue.object(fields).jsonString()
    }

    struct Add {
        var queryID: Int
        var path: String
        var args: ConvexValue
        var journal: String?
    }

    static func modifyQuerySet(base: Int, new: Int, adds: [Add], removes: [Int]) -> String {
        var modifications: [ConvexValue] = adds.map { add in
            var m: [String: ConvexValue] = [
                "type": .string("Add"),
                "queryId": .float64(Double(add.queryID)),
                "udfPath": .string(add.path),
                "args": .array([add.args]),
            ]
            if let journal = add.journal { m["journal"] = .string(journal) }
            return .object(m)
        }
        modifications += removes.map { .object(["type": .string("Remove"), "queryId": .float64(Double($0))]) }
        return ConvexValue.object([
            "type": .string("ModifyQuerySet"),
            "baseVersion": .float64(Double(base)),
            "newVersion": .float64(Double(new)),
            "modifications": .array(modifications),
        ]).jsonString()
    }

    static func mutation(requestID: Int, path: String, args: ConvexValue) -> String {
        ConvexValue.object([
            "type": .string("Mutation"),
            "requestId": .float64(Double(requestID)),
            "udfPath": .string(path),
            "args": .array([args]),
        ]).jsonString()
    }
}

/// `module:function`, the canonical form the sync protocol uses ("devices" → "devices:default").
func canonicalUdfPath(_ path: String) -> String {
    var p = path
    if p.hasSuffix(".js") { p.removeLast(3) }
    return p.contains(":") ? p : "\(p):default"
}

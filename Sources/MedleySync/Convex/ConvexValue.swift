import Foundation

/// A Convex value, encoded on the wire as Convex JSON (`convexToJson` in the npm package, `values/value.ts`):
/// numbers are float64, int64 travels as `{"$integer": base64(8 bytes LE)}`, bytes as `{"$bytes": base64}`, and
/// floats JSON can't spell (NaN, ±Infinity, -0) as `{"$float": base64(8 bytes LE)}`.
public enum ConvexValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int64(Int64)
    case float64(Double)
    case string(String)
    case bytes(Data)
    case array([ConvexValue])
    case object([String: ConvexValue])

    public subscript(key: String) -> ConvexValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .float64(let d): d
        case .int64(let i): Double(i)
        default: nil
        }
    }
}

public struct ConvexValueError: Error, Equatable, Sendable, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Encoding to Convex JSON text

extension ConvexValue {
    /// The Convex JSON text of this value.
    public func jsonString() -> String {
        var out = ""
        write(to: &out)
        return out
    }

    public func jsonData() -> Data { Data(jsonString().utf8) }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int64(let i): out += #"{"$integer":"\#(Self.base64LE(UInt64(bitPattern: i)))"}"#
        case .float64(let d):
            if d.isNaN || d.isInfinite || (d == 0 && d.sign == .minus) {
                out += #"{"$float":"\#(Self.base64LE(d.bitPattern))"}"#
            } else {
                out += Self.formatNumber(d)
            }
        case .string(let s): Self.writeString(s, to: &out)
        case .bytes(let data): out += #"{"$bytes":"\#(data.base64EncodedString())"}"#
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            // Sorted keys keep the text stable, which tests and query identity rely on.
            for (i, key) in fields.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                Self.writeString(key, to: &out)
                out += ":"
                fields[key]!.write(to: &out)
            }
            out += "}"
        }
    }

    static func formatNumber(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return String(Int64(d)) }
        return "\(d)"
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    static func base64LE(_ bits: UInt64) -> String {
        var le = bits.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }.base64EncodedString()
    }

    static func bitsFromBase64LE(_ text: String) -> UInt64? {
        guard let data = Data(base64Encoded: text), data.count == 8 else { return nil }
        var value: UInt64 = 0
        for (i, byte) in data.enumerated() { value |= UInt64(byte) << (8 * UInt64(i)) }
        return value
    }
}

// MARK: - Decoding from Convex JSON

extension ConvexValue {
    /// Parses Convex JSON text.
    public static func parse(_ data: Data) throws -> ConvexValue {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try ConvexValue(json: object)
    }

    /// Converts a `JSONSerialization` value in Convex JSON form, decoding `$integer`, `$float` and `$bytes`.
    public init(json: Any) throws {
        switch json {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .float64(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(ConvexValue.init(json:)))
        case let dict as [String: Any]:
            if dict.count == 1, let entry = dict.first, entry.key.hasPrefix("$") {
                let key = entry.key
                guard let text = entry.value as? String else { throw ConvexValueError("Malformed \(key) field") }
                switch key {
                case "$integer":
                    guard let bits = Self.bitsFromBase64LE(text) else { throw ConvexValueError("Malformed $integer") }
                    self = .int64(Int64(bitPattern: bits))
                case "$float":
                    guard let bits = Self.bitsFromBase64LE(text) else { throw ConvexValueError("Malformed $float") }
                    self = .float64(Double(bitPattern: bits))
                case "$bytes":
                    guard let data = Data(base64Encoded: text) else { throw ConvexValueError("Malformed $bytes") }
                    self = .bytes(data)
                default:
                    throw ConvexValueError("Unsupported Convex type \(key)")
                }
                return
            }
            var fields: [String: ConvexValue] = [:]
            for (key, value) in dict { fields[key] = try ConvexValue(json: value) }
            self = .object(fields)
        default:
            throw ConvexValueError("Unexpected JSON value \(type(of: json))")
        }
    }
}

// MARK: - Codable bridge

extension ConvexValue {
    /// Encodes a `Codable` value through `JSONEncoder`. Numbers become float64, which matches `v.number()`.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try ConvexValue.parse(data)
    }

    /// Decodes a `Codable` value through `JSONDecoder`. int64 becomes a JSON integer and bytes base64.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: try plainJSON(), options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func plainJSON() throws -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .int64(let i): return NSNumber(value: i)
        case .float64(let d):
            guard d.isFinite else { throw ConvexValueError("\(d) has no JSON form") }
            return NSNumber(value: d)
        case .string(let s): return s
        case .bytes(let data): return data.base64EncodedString()
        case .array(let items): return try items.map { try $0.plainJSON() }
        case .object(let fields): return try fields.mapValues { try $0.plainJSON() }
        }
    }
}

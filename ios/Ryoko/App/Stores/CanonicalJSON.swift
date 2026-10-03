import CryptoKit
import Foundation

/// Canonical JSON and the profile version, matching contracts/src/canonical.ts:
///
/// - object keys sorted by UTF-16 code unit, no whitespace;
/// - strings escaped like `JSON.stringify` (only `"`, `\` and control characters);
/// - numbers written like JavaScript: integral values without a fraction.
///
/// `Profile.version` is the lowercase hex SHA-256 of the canonical JSON of the
/// profile without `version`. The server treats it as an opaque cache key; only
/// the device needs to compute it consistently.
nonisolated enum CanonicalJSON {
    /// The canonical JSON of any `Encodable` value.
    static func string<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        let tree = try JSONDecoder().decode(JSONValue.self, from: data)
        var out = ""
        write(tree, to: &out)
        return out
    }

    /// The content-hash version of a profile (its `version` field is ignored).
    static func profileVersion(_ profile: Profile) throws -> String {
        let data = try JSONEncoder().encode(profile)
        guard case var .object(fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw EncodingError.invalidValue(profile, .init(codingPath: [], debugDescription: "A profile must encode as an object"))
        }
        fields.removeValue(forKey: "version")
        var canonical = ""
        write(.object(fields), to: &canonical)
        return sha256Hex(canonical)
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writer

    private static func write(_ value: JSONValue, to out: inout String) {
        switch value {
        case .null:
            out += "null"
        case let .bool(flag):
            out += flag ? "true" : "false"
        case let .number(number):
            out += javaScriptNumber(number)
        case let .string(text):
            writeString(text, to: &out)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, to: &out)
            }
            out += "]"
        case let .object(fields):
            out += "{"
            let keys = fields.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                writeString(key, to: &out)
                out += ":"
                write(fields[key]!, to: &out)
            }
            out += "}"
        }
    }

    /// `JSON.stringify` escaping: quote, backslash, the short escapes, and
    /// `\u00xx` for other control characters. Everything else is written as is.
    private static func writeString(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20:
                out += String(format: "\\u%04x", s.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// JavaScript's number formatting for the values a profile holds: integral
    /// values print without a fraction; others use the shortest round-trip form.
    private static func javaScriptNumber(_ number: Double) -> String {
        if number.isFinite, number == number.rounded(), abs(number) < 1e21 {
            return String(Int64(number))
        }
        return "\(number)"
    }
}

/// A parsed JSON value, used to re-serialize canonically.
nonisolated enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([JSONValue].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

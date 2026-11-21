import Foundation

/// A JSON value, read the way the Dart and web players read untyped JSON:
/// fields are checked for their type one by one, so a missing or mistyped
/// field falls back instead of failing the whole answer.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Any JSON number.
    public var numberValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Parses JSON text; nil when it is not JSON.
    public static func decode(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON with keys in sorted order and `/` unescaped (as
    /// `JSON.stringify` and Dart's `jsonEncode` write it).
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a JSONValue fails only for a non-finite double.
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// `.string(value)`, or `.null` for nil.
    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    static func optional(_ value: Int?) -> JSONValue {
        value.map(JSONValue.int) ?? .null
    }

    static func optional(_ value: Double?) -> JSONValue {
        value.map(JSONValue.double) ?? .null
    }
}

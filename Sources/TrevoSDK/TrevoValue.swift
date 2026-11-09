import Foundation

/// A JSON value: an event property, a parameter value, or part of a config payload.
public enum TrevoValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TrevoValue])
    case object([String: TrevoValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [TrevoValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: TrevoValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension TrevoValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension TrevoValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension TrevoValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension TrevoValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension TrevoValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension TrevoValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: TrevoValue...) { self = .array(elements) }
}

extension TrevoValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, TrevoValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension TrevoValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TrevoValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: TrevoValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // JSON.stringify writes 3, not 3.0, so a property reads the same from every SDK.
            if value.rounded() == value, abs(value) < Self.maxSafeInteger {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    static let maxSafeInteger: Double = 9_007_199_254_740_992
}

enum JSON {
    static func decode(_ data: Data) throws -> TrevoValue {
        try JSONDecoder().decode(TrevoValue.self, from: data)
    }

    static func decode(_ text: String) throws -> TrevoValue {
        try decode(Data(text.utf8))
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
}

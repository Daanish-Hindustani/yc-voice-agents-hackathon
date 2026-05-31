import Foundation

/// Codable sum type for arbitrary JSON values.
///
/// Used by `FunctionCall.args` (and, in the next PR,
/// `FunctionResponse.response`) where the wire format carries
/// arbitrary-shaped JSON whose schema is determined by the calling
/// agent at runtime, not statically. Using `[String: JSONValue]`
/// rather than `[String: Any]` keeps the types `Sendable` and
/// `Equatable` and lets the supervisor pattern-match on the
/// argument shape before dispatching to a tool.
///
/// Decoding strategy: try each scalar variant in turn, then arrays,
/// then objects. Integer-vs-double disambiguation matters: JSON
/// numbers like `5` should decode as `.int(5)` (so a tool that
/// expects `Int` doesn't get a `Double`), while `5.5` decodes as
/// `.double(5.5)`. Swift's `JSONDecoder` will happily decode `5`
/// as either; we order the attempts so `Int` wins for whole
/// numbers.
///
/// **Overflow caveat:** integers larger than `Int.max` (≥ 2^63)
/// fail the `Int` decode and fall through to `Double`, which has
/// 53 bits of mantissa — those values land as imprecise doubles.
/// Tool argument schemas should keep numeric IDs within `Int`
/// range. The current Gemini tool surface (pids, window ids,
/// element indices) is well inside that bound.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        // Int before Double — JSON's `5` should land as .int(5),
        // not .double(5.0). Tools downstream may pattern-match on
        // the case explicitly.
        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Value is not a recognized JSON type"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    /// Unwrap this value as `Bool` if it is one, otherwise nil.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Unwrap this value as `Int` if it is one. Does NOT coerce a
    /// `.double` to `Int` — callers that expect either should
    /// pattern-match both cases explicitly.
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    /// Unwrap this value as `Double` if it is one. Like `intValue`,
    /// no cross-case coercion.
    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }

    /// Unwrap this value as `String` if it is one.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Unwrap this value as `[JSONValue]` if it is one.
    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// Unwrap this value as `[String: JSONValue]` if it is one.
    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
}

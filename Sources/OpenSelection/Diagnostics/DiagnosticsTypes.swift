// DiagnosticsTypes.swift
// OpenSelection
//
// Structured logging primitives, literal-only messages, and closed-field vocabulary
// guaranteeing privacy by construction.
import Foundation

/// Severity levels for diagnostics and structured event emission.
public enum LogLevel: UInt8, Sendable, Comparable, Codable, CaseIterable {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case fault = 5

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Core functional categories within OpenSelection.
public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case monitor
    case ax
    case gate
    case cascade
    case pasteboard
    case enrichment
    case inspector
}

/// Literal-only message ensuring that dynamic user text, selected strings, or clipboard
/// contents can NEVER be interpolated into log messages at compile-time.
///
/// Because this type conforms to `ExpressibleByStringLiteral` but NOT `ExpressibleByStringInterpolation`,
/// writing `"selected \(text)"` produces a compiler error.
public struct LogMessage: ExpressibleByStringLiteral, Sendable, CustomStringConvertible {
    public let text: StaticString

    public init(stringLiteral value: StaticString) {
        self.text = value
    }

    public var description: String {
        "\(text)"
    }
}

/// Coarse indicator of text presence, avoiding exposure of string lengths or content.
public enum TextPresence: String, Sendable, Codable, Equatable {
    case absent
    case empty
    case nonEmpty
}

/// Closed value vocabulary for event fields. Deliberately omits free-form strings.
public enum FieldValue: Sendable, Equatable, Codable {
    case int(Int64)
    case bool(Bool)
    case micros(UInt32)
    case presence(TextPresence)
    case ax(AXErrorCode)
    case token(String)

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let v):
            try container.encode("int", forKey: .type)
            try container.encode(v, forKey: .value)
        case .bool(let v):
            try container.encode("bool", forKey: .type)
            try container.encode(v, forKey: .value)
        case .micros(let v):
            try container.encode("micros", forKey: .type)
            try container.encode(v, forKey: .value)
        case .presence(let v):
            try container.encode("presence", forKey: .type)
            try container.encode(v, forKey: .value)
        case .ax(let v):
            try container.encode("ax", forKey: .type)
            try container.encode(v, forKey: .value)
        case .token(let v):
            try container.encode("token", forKey: .type)
            try container.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "int":
            let v = try container.decode(Int64.self, forKey: .value)
            self = .int(v)
        case "bool":
            let v = try container.decode(Bool.self, forKey: .value)
            self = .bool(v)
        case "micros":
            let v = try container.decode(UInt32.self, forKey: .value)
            self = .micros(v)
        case "presence":
            let v = try container.decode(TextPresence.self, forKey: .value)
            self = .presence(v)
        case "ax":
            let v = try container.decode(AXErrorCode.self, forKey: .value)
            self = .ax(v)
        case "token":
            let v = try container.decode(String.self, forKey: .value)
            self = .token(v)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown field value type: \(type)")
        }
    }
}

/// A structured diagnostic event emitted during selection retrieval or monitoring.
public struct DiagnosticEvent: Sendable, Codable {
    public let traceID: TraceID
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let fields: [String: FieldValue]
    public let offsetMicros: UInt64

    internal init(
        traceID: TraceID,
        level: LogLevel,
        category: LogCategory,
        message: StaticString,
        fields: [String: FieldValue],
        offsetMicros: UInt64
    ) {
        self.traceID = traceID
        self.level = level
        self.category = category
        self.message = "\(message)"
        self.fields = fields
        self.offsetMicros = offsetMicros
    }

    internal init(
        traceID: TraceID,
        level: LogLevel,
        category: LogCategory,
        rawMessage: String,
        fields: [String: FieldValue],
        offsetMicros: UInt64
    ) {
        self.traceID = traceID
        self.level = level
        self.category = category
        self.message = rawMessage
        self.fields = fields
        self.offsetMicros = offsetMicros
    }
}

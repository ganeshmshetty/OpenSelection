// OSLogSink.swift
// OpenSelection
//
// Built-in sink forwarding structured events to Apple Unified Logging (os.Logger).
import Foundation
import os

/// Diagnostics sink streaming structured events to `os.Logger`.
public struct OSLogSink: OpenSelectionDiagnosticsSink {
    public let minimumLevel: LogLevel
    private let subsystem: String

    public init(subsystem: String = "com.openselection", minimumLevel: LogLevel = .debug) {
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
    }

    public func record(_ event: DiagnosticEvent) {
        let logger = Logger(subsystem: subsystem, category: event.category.rawValue)
        let formattedFields = event.fields.map { "\($0.key)=\(Self.format($0.value))" }.sorted().joined(separator: " ")
        let line = formattedFields.isEmpty
            ? "[\(event.traceID)] \(event.message)"
            : "[\(event.traceID)] \(event.message) [\(formattedFields)]"

        switch event.level {
        case .trace:
            logger.debug("\(line, privacy: .public)")
        case .debug:
            logger.debug("\(line, privacy: .public)")
        case .info:
            logger.info("\(line, privacy: .public)")
        case .warning:
            logger.warning("\(line, privacy: .public)")
        case .error:
            logger.error("\(line, privacy: .public)")
        case .fault:
            logger.fault("\(line, privacy: .public)")
        }
    }

    private static func format(_ value: FieldValue) -> String {
        switch value {
        case .int(let v):
            return "\(v)"
        case .bool(let v):
            return v ? "true" : "false"
        case .micros(let v):
            return "\(v)µs"
        case .presence(let v):
            return v.rawValue
        case .ax(let v):
            return v.rawValue
        case .token(let v):
            return v
        }
    }
}

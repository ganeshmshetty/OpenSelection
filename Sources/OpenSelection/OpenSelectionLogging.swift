// OpenSelectionLogging.swift
// OpenSelection
//
// Backward-compatibility shim mapping legacy logger closures into DiagnosticsHub.
import Foundation
import os

@available(*, deprecated, message: "Install an OpenSelectionDiagnosticsSink into DiagnosticsHub.shared")
public enum OpenSelectionLogging: Sendable {
    private static let defaultLogger = Logger(subsystem: "com.openselection", category: "retrieval")
    private static let customLoggerLock = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    private struct LegacyClosureSink: OpenSelectionDiagnosticsSink {
        let minimumLevel: LogLevel = .trace
        let closure: @Sendable (String) -> Void

        func record(_ event: DiagnosticEvent) {
            closure("[\(event.traceID)] \(event.message)")
        }
    }

    /// Pluggable logger closure for custom logging backends.
    public static var logger: (@Sendable (String) -> Void)? {
        get {
            customLoggerLock.withLock { $0 }
        }
        set {
            customLoggerLock.withLock { $0 = newValue }
            if let newValue {
                DiagnosticsHub.shared.install(LegacyClosureSink(closure: newValue))
            }
        }
    }

    public static func log(_ message: String) {
        if let custom = logger {
            custom(message)
        } else {
            defaultLogger.debug("\(message, privacy: .public)")
        }
    }
}

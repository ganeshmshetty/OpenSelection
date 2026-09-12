// OpenSelectionLogging.swift
// OpenSelection
//
// Dual logging facade: forwards to a pluggable closure when configured,
// defaulting to Apple system log (`os.Logger(subsystem: "com.openselection", category: "retrieval")`).
import Foundation
import os

public enum OpenSelectionLogging: Sendable {
    private static let defaultLogger = Logger(subsystem: "com.openselection", category: "retrieval")
    private static let customLoggerLock = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    /// Pluggable logger closure for custom logging backends.
    public static var logger: (@Sendable (String) -> Void)? {
        get {
            customLoggerLock.withLock { $0 }
        }
        set {
            customLoggerLock.withLock { $0 = newValue }
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

// SignpostSink.swift
// OpenSelection
//
// Diagnostics sink emitting signposts to Instruments via OSSignposter.
import Foundation
import os

/// Diagnostics sink emitting Instruments intervals and points of interest via `OSSignposter`.
public struct SignpostSink: OpenSelectionDiagnosticsSink, Sendable {
    public let minimumLevel: LogLevel
    private let signposter: OSSignposter

    public init(
        subsystem: String = "com.openselection",
        category: String = "retrieval",
        minimumLevel: LogLevel = .debug
    ) {
        self.signposter = OSSignposter(subsystem: subsystem, category: category)
        self.minimumLevel = minimumLevel
    }

    public func record(_ event: DiagnosticEvent) {
        guard signposter.isEnabled else { return }
        let signpostID = OSSignpostID(event.traceID.rawValue)
        signposter.emitEvent(
            "DiagnosticEvent",
            id: signpostID,
            "[\(event.traceID.rawValue, privacy: .public)] \(event.category.rawValue, privacy: .public): \(event.message, privacy: .public)"
        )
    }

    public func finish(_ report: CascadeReport) {
        guard signposter.isEnabled else { return }
        let signpostID = OSSignpostID(report.traceID.rawValue)
        signposter.emitEvent(
            "CascadeFinished",
            id: signpostID,
            "[\(report.traceID.rawValue, privacy: .public)] total=\(report.totalMicros)µs"
        )
    }
}

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
        let signpostID = signposter.makeSignpostID()
        signposter.emitEvent(
            "DiagnosticEvent",
            id: signpostID,
            "\(event.category.rawValue, privacy: .public): \(event.message, privacy: .public)"
        )
    }

    public func finish(_ report: CascadeReport) {
        guard signposter.isEnabled else { return }
        let signpostID = signposter.makeSignpostID()
        signposter.emitEvent(
            "CascadeFinished",
            id: signpostID,
            "total=\(report.totalMicros)µs"
        )
    }
}

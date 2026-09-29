// DiagnosticsHub.swift
// OpenSelection
//
// Central coordination hub for diagnostics event dispatch, sink registration,
// and performance reporting without caller thread contention.
import Foundation
import os

/// Protocol for host applications or adapters to consume diagnostics events and cascade reports.
public protocol OpenSelectionDiagnosticsSink: Sendable {
    var minimumLevel: LogLevel { get }
    func record(_ event: DiagnosticEvent)
    func finish(_ report: CascadeReport)
}

extension OpenSelectionDiagnosticsSink {
    public func finish(_ report: CascadeReport) {}
}

/// Mode governing when comprehensive `CascadeReport` structures are constructed and dispatched.
public enum ReportMode: Sendable, Codable {
    case off
    case onFailureOrSlow
    case always
}

/// Registration token returned when installing a sink into DiagnosticsHub.
public struct SinkToken: Sendable, Hashable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Thread-safe central diagnostics coordinator.
public final class DiagnosticsHub: Sendable {
    public static let shared = DiagnosticsHub()

    private struct State: Sendable {
        var sinks: [(token: SinkToken, sink: any OpenSelectionDiagnosticsSink)] = [
            (token: SinkToken(), sink: OSLogSink(minimumLevel: .info))
        ]
        var floor: LogLevel? = .info
        var reportMode: ReportMode = .off
        var slowThresholdMicros: UInt64 = 40_000 // 40ms default
        var droppedEventCount: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.openselection.diagnostics", qos: .utility)

    public init() {}

    /// Installs a new diagnostics sink and returns a token that can be used to remove it.
    @discardableResult
    public func install(_ sink: some OpenSelectionDiagnosticsSink) -> SinkToken {
        let token = SinkToken()
        state.withLock { s in
            s.sinks.append((token: token, sink: sink))
            recalculateFloor(&s)
        }
        return token
    }

    /// Removes a previously installed sink by its token.
    public func removeSink(_ token: SinkToken) {
        state.withLock { s in
            s.sinks.removeAll { $0.token == token }
            recalculateFloor(&s)
        }
    }

    /// Resets configuration to default state with system logger.
    public func reset() {
        state.withLock { s in
            s.sinks = [(token: SinkToken(), sink: OSLogSink(minimumLevel: .info))]
            s.reportMode = .off
            s.slowThresholdMicros = 40_000
            s.droppedEventCount = 0
            recalculateFloor(&s)
        }
    }

    /// Removes all installed sinks including the default OSLogSink (primarily used in tests).
    public func removeAllSinks() {
        state.withLock { s in
            s.sinks.removeAll()
            s.floor = nil
            s.reportMode = .off
            s.slowThresholdMicros = 40_000
            s.droppedEventCount = 0
        }
    }

    /// Checks if a cascade report should be constructed for the given outcome and duration.
    public func isReportRequired(outcome: FinalOutcome? = nil, elapsedMicros: UInt64? = nil) -> Bool {
        state.withLock { s in
            switch s.reportMode {
            case .off:
                return false
            case .always:
                return !s.sinks.isEmpty
            case .onFailureOrSlow:
                guard !s.sinks.isEmpty else { return false }
                guard let outcome else { return true }
                let failed = outcome != .selection(strategy: .axTextControl, presence: .nonEmpty)
                    && outcome != .selection(strategy: .axWebArea, presence: .nonEmpty)
                    && outcome != .selection(strategy: .officeScript, presence: .nonEmpty)
                    && outcome != .selection(strategy: .menuCopy, presence: .nonEmpty)
                    && outcome != .selection(strategy: .keyboardCopy, presence: .nonEmpty)
                let slow = (elapsedMicros ?? 0) >= s.slowThresholdMicros
                return failed || slow
            }
        }
    }

    /// Configures the report generation mode.
    public func setReportMode(_ mode: ReportMode) {
        state.withLock { $0.reportMode = mode }
    }

    /// Configures the slow threshold in microseconds for `.onFailureOrSlow` mode.
    public func setSlowThreshold(microseconds: UInt64) {
        state.withLock { $0.slowThresholdMicros = microseconds }
    }

    /// Fast lock-free-ish level check to avoid overhead on unobserved levels.
    @inline(__always)
    public func isEnabled(_ level: LogLevel) -> Bool {
        guard let floor = state.withLock({ $0.floor }) else { return false }
        return level >= floor
    }

    /// Logs a structured message with static string and safe fields when no trace is available.
    public func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: LogMessage,
        fields: [String: FieldValue] = [:]
    ) {
        guard isEnabled(level) else { return }
        let event = DiagnosticEvent(
            traceID: TraceID(rawValue: 0),
            level: level,
            category: category,
            message: message.text,
            fields: fields,
            offsetMicros: 0
        )
        emit(event)
    }

    /// Dispatches a structured event to all interested sinks asynchronously.
    public func emit(_ event: DiagnosticEvent) {
        let matchingSinks: [any OpenSelectionDiagnosticsSink] = state.withLock { s in
            guard let floor = s.floor, event.level >= floor else { return [] }
            return s.sinks.map(\.sink).filter { event.level >= $0.minimumLevel }
        }

        guard !matchingSinks.isEmpty else { return }

        queue.async {
            for sink in matchingSinks {
                sink.record(event)
            }
        }
    }

    /// Dispatches a completed cascade report to all installed sinks asynchronously.
    public func emitReport(_ report: CascadeReport) {
        let sinks: [any OpenSelectionDiagnosticsSink] = state.withLock { s in
            switch s.reportMode {
            case .off:
                return []
            case .always:
                return s.sinks.map(\.sink)
            case .onFailureOrSlow:
                let failed = report.outcome != .selection(strategy: .axTextControl, presence: .nonEmpty)
                    && report.outcome != .selection(strategy: .axWebArea, presence: .nonEmpty)
                    && report.outcome != .selection(strategy: .officeScript, presence: .nonEmpty)
                    && report.outcome != .selection(strategy: .menuCopy, presence: .nonEmpty)
                    && report.outcome != .selection(strategy: .keyboardCopy, presence: .nonEmpty)
                let slow = UInt64(report.totalMicros) >= s.slowThresholdMicros
                return (failed || slow) ? s.sinks.map(\.sink) : []
            }
        }

        guard !sinks.isEmpty else { return }

        queue.async {
            for sink in sinks {
                sink.finish(report)
            }
        }
    }

    /// Flushes all pending diagnostic queue operations.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private static func recalculateFloor(_ state: inout State) {
        if state.sinks.isEmpty {
            state.floor = nil
        } else {
            state.floor = state.sinks.map(\.sink.minimumLevel).min()
        }
    }

    private func recalculateFloor(_ state: inout State) {
        Self.recalculateFloor(&state)
    }
}

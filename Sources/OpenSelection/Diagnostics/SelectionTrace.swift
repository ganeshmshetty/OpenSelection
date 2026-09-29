// SelectionTrace.swift
// OpenSelection
//
// Lifecycle correlation and request-level tracing across selection retrieval.
import Foundation
import os

/// Unique identifier for correlating an end-to-end selection retrieval lifecycle.
public struct TraceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String {
        "Trace#\(rawValue)"
    }
}

/// The origin trigger that initiated selection retrieval.
public struct TriggerSource: Sendable, Codable, Equatable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String

    public init(stringLiteral value: String) {
        self.raw = value
    }

    public init(raw: String) {
        self.raw = raw
    }

    public static let mouseUp = TriggerSource(raw: "mouseUp")
    public static let doubleClick = TriggerSource(raw: "doubleClick")
    public static let dragEnd = TriggerSource(raw: "dragEnd")
    public static let keyboardShortcut = TriggerSource(raw: "keyboardShortcut")
    public static let programmatic = TriggerSource(raw: "programmatic")

    public var description: String { raw }
}

/// A request-scoped trace tracking timing and emitting correlated events.
public final class SelectionTrace: Sendable {
    private static let idCounter = OSAllocatedUnfairLock<UInt64>(initialState: 1)

    public let id: TraceID
    public let parent: TraceID?
    public let trigger: TriggerSource
    private let startInstant: ContinuousClock.Instant

    public init(id: TraceID, parent: TraceID? = nil, trigger: TriggerSource = .programmatic) {
        self.id = id
        self.parent = parent
        self.trigger = trigger
        self.startInstant = ContinuousClock.now
    }

    public static func create(trigger: TriggerSource = .programmatic, parent: TraceID? = nil) -> SelectionTrace {
        let nextID = idCounter.withLock { count in
            let id = count
            count += 1
            return id
        }
        return SelectionTrace(id: TraceID(rawValue: nextID), parent: parent, trigger: trigger)
    }

    public var elapsedMicros: UInt64 {
        let elapsed = ContinuousClock.now - startInstant
        let sec = max(0, elapsed.components.seconds)
        let atto = max(0, elapsed.components.attoseconds)
        return UInt64(sec) * 1_000_000 + UInt64(atto / 1_000_000_000_000)
    }

    public func log(
        _ level: LogLevel,
        _ category: LogCategory,
        _ message: LogMessage,
        fields: [String: FieldValue] = [:]
    ) {
        guard DiagnosticsHub.shared.isEnabled(level) else { return }
        let event = DiagnosticEvent(
            traceID: id,
            level: level,
            category: category,
            message: message.text,
            fields: fields,
            offsetMicros: elapsedMicros
        )
        DiagnosticsHub.shared.emit(event)
    }

    private let recordedAttempts = OSAllocatedUnfairLock<[StrategyAttempt]>(initialState: [])
    private let recordedTarget = OSAllocatedUnfairLock<TargetSnapshot?>(initialState: nil)

    public func recordAttempt(_ attempt: StrategyAttempt) {
        recordedAttempts.withLock { $0.append(attempt) }
    }

    public func recordTarget(_ target: TargetSnapshot) {
        recordedTarget.withLock { $0 = target }
    }

    public func buildReport(outcome: FinalOutcome) -> CascadeReport {
        let attempts = recordedAttempts.withLock { $0 }
        let target = recordedTarget.withLock { $0 }
        let total = UInt32(min(UInt64(UInt32.max), elapsedMicros))
        return CascadeReport(
            traceID: id,
            trigger: trigger,
            target: target,
            totalMicros: total,
            outcome: outcome,
            attempts: attempts,
            dropped: 0
        )
    }
}

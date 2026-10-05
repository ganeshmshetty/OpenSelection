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
    @TaskLocal public static var current: SelectionTrace?

    private static let idCounter = OSAllocatedUnfairLock<UInt64>(initialState: 1)

    public let id: TraceID
    public let parent: TraceID?
    public let trigger: TriggerSource
    private let startInstant: ContinuousClock.Instant
    /// Wall-clock instant after which blocking AX work for the current inspect attempt must
    /// stop issuing new queries. Refreshed to a fresh watchdog-sized budget by every
    /// `inspectWithWatchdog` attempt (initial read and each settle retry), so each worker is
    /// bounded individually: a stalled target app cannot park a worker — and its
    /// concurrency-gate permit — far past the deadline, while lagging-but-responsive apps
    /// keep a full budget on every attempt. `nil` means unbounded (traces that never drive
    /// live AX keep legacy behavior).
    ///
    /// Remaining time is always derived from the monotonic `instant`, never the wall clock:
    /// the watchdog sleeps on a monotonic basis too, so an NTP step or sleep/wake cycle
    /// cannot inflate a worker's budget past its watchdog.
    private let deadlineState = OSAllocatedUnfairLock<(wall: Date?, instant: ContinuousClock.Instant?)>(initialState: (nil, nil))
    public var deadline: Date? {
        deadlineState.withLock { $0.wall }
    }

    /// Monotonic seconds left in the current AX budget, clamped at zero, or `nil` when no
    /// deadline constrains this trace.
    public var remainingAXBudget: TimeInterval? {
        deadlineState.withLock { state in
            guard let instant = state.instant else { return nil }
            let remaining = instant - ContinuousClock.now
            return max(0, Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1_000_000_000_000_000_000)
        }
    }

    /// Starts a fresh watchdog-sized AX budget for the next inspect attempt on this trace.
    public func refreshDeadline(_ date: Date) {
        deadlineState.withLock { state in
            state.wall = date
            let interval = date.timeIntervalSinceNow
            let wholeSeconds = Int64(floor(interval))
            let attoseconds = Int64((interval - Double(wholeSeconds)) * 1_000_000_000_000_000_000)
            state.instant = ContinuousClock.now.advanced(
                by: Duration(secondsComponent: wholeSeconds, attosecondsComponent: attoseconds)
            )
        }
    }

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

    private let readStatus = OSAllocatedUnfairLock<SelectionReadStatus>(initialState: .noSelection)

    public var selectionReadStatus: SelectionReadStatus { readStatus.withLock { $0 } }
    public func recordReadStatus(_ status: SelectionReadStatus) { readStatus.withLock { $0 = status } }

    private let metrics = OSAllocatedUnfairLock<[String: UInt64]>(initialState: [:])
    private let restored = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    public func addMetric(_ key: String, _ value: UInt64 = 1) {
        metrics.withLock { $0[key, default: 0] += value }
    }

    public func recordClipboardRestored(_ value: Bool) { restored.withLock { $0 = value } }

    public func complete(status: SelectionReadStatus, configured: SelectionStrategy, winner: SelectionStrategy?, bundleID: String? = nil) {
        var fields: [String: FieldValue] = [
            "bundleID": .token(bundleID ?? "unknown"),
            "outcome": .token(status.rawValue), "trigger": .token(trigger.raw),
            "configuredStrategy": .token(configured.rawValue),
            "winningStrategy": .token(winner?.rawValue ?? "none"),
            "elapsedMicros": .micros(UInt32(clamping: elapsedMicros))
        ]
        for (key, value) in metrics.withLock({ $0 }) {
            fields[key] = .int(Int64(clamping: value))
        }
        if let value = restored.withLock({ $0 }) { fields["clipboardRestored"] = .bool(value) }
        if let target = recordedTarget.withLock({ $0 }) {
            fields["bundleID"] = .token(target.bundleID ?? "unknown")
        }
        let attempts = recordedAttempts.withLock { $0 }
        fields["attempts"] = .int(Int64(attempts.count))
        if let first = attempts.first, attempts.count > 1 {
            let reason: String
            switch first.outcome {
            case .empty(let value): reason = String(describing: value)
            case .timedOut: reason = "timedOut"
            case .failed: reason = "failed"
            case .skipped: reason = "skipped"
            case .cancelled: reason = "cancelled"
            case .succeeded: reason = "richEnrichment"
            }
            fields["fallbackReason"] = .token(reason)
        }
        let level: LogLevel = status == .selection ? .info
            : (status == .timedOut || status == .failed || status == .targetChanged ? .warning
                : (status == .cancelled ? .trace : .debug))
        log(level, .cascade, "selection completed", fields: fields)
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
            dropped: 0,
            readStatus: selectionReadStatus,
            metrics: metrics.withLock { $0 },
            clipboardRestored: restored.withLock { $0 }
        )
    }
}

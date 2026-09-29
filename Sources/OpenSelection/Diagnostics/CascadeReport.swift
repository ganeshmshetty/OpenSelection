// CascadeReport.swift
// OpenSelection
//
// Structured reporting of the multi-tier selection retrieval cascade.
import CoreGraphics
import Foundation

/// Coarse indicator of system CPU architecture.
public enum TargetArchitecture: String, Sendable, Codable, Equatable {
    case arm64
    case x86_64
    case unknown
}

/// Fingerprint of the target application's UI framework.
public enum FrameworkFingerprint: String, Sendable, Codable, Equatable {
    case native
    case webkit
    case chromium
    case electron
    case office
    case terminal
    case catalyst
    case java
    case qt
    case unknown
}

/// Coarse cursor classification for report snapshots.
public enum CursorKind: String, Sendable, Codable, Equatable {
    case iBeam
    case arrow
    case pointingHand
    case other
}

/// Snapshot of the target application without any window titles or user data.
public struct TargetSnapshot: Sendable, Codable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let architecture: TargetArchitecture
    public let isRosettaTranslated: Bool
    public let framework: FrameworkFingerprint
    public let cursor: CursorKind?
    public let windowBounds: CGRect?

    public init(
        pid: Int32,
        bundleID: String? = nil,
        architecture: TargetArchitecture = .arm64,
        isRosettaTranslated: Bool = false,
        framework: FrameworkFingerprint = .unknown,
        cursor: CursorKind? = nil,
        windowBounds: CGRect? = nil
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.architecture = architecture
        self.isRosettaTranslated = isRosettaTranslated
        self.framework = framework
        self.cursor = cursor
        self.windowBounds = windowBounds
    }
}

/// Final outcome of a selection retrieval operation.
public enum FinalOutcome: Sendable, Codable, Equatable {
    case selection(strategy: SelectionStrategy, presence: TextPresence)
    case none
    case cancelled
}

/// Specific reason why a retrieval strategy was skipped before execution.
public enum SkipReason: String, Sendable, Codable, Equatable {
    case cursorMismatch
    case noTextEvidence
    case notApplicableRole
    case secureField
    case menuItemDisabled
    case menuItemMissing
    case deadlineExhausted
    case blockedByPolicy
    case foreignOverlayPresent
    case windowMovedOrResized
    case earlierStrategyAuthoritative
}

/// Specific reason why an executed strategy produced no text.
public enum EmptyReason: String, Sendable, Codable, Equatable {
    case noSelection
    case rangeZero
    case valueNil
    case pasteboardUnchanged
    case whitespaceOnly
}

/// Specific reason why an executed strategy failed.
public enum StrategyFailureReason: String, Sendable, Codable, Equatable {
    case axError
    case scriptError
    case eventPostFailed
    case permissionDenied
    case timeout
}

/// Outcome of an individual strategy attempt in the cascade.
public enum StrategyOutcome: Sendable, Codable, Equatable {
    case succeeded
    case skipped(SkipReason)
    case timedOut
    case empty(EmptyReason)
    case failed(StrategyFailureReason)
    case cancelled
}

/// Summary of an individual strategy execution within the cascade.
public struct StrategyAttempt: Sendable, Codable, Equatable {
    public let strategy: SelectionStrategy
    public let outcome: StrategyOutcome
    public let startOffsetMicros: UInt32
    public let durationMicros: UInt32
    public let axErrorCode: AXErrorCode?

    public init(
        strategy: SelectionStrategy,
        outcome: StrategyOutcome,
        startOffsetMicros: UInt32,
        durationMicros: UInt32,
        axErrorCode: AXErrorCode? = nil
    ) {
        self.strategy = strategy
        self.outcome = outcome
        self.startOffsetMicros = startOffsetMicros
        self.durationMicros = durationMicros
        self.axErrorCode = axErrorCode
    }
}

/// Comprehensive diagnostics report for a single selection retrieval run.
public struct CascadeReport: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let traceID: TraceID
    public let trigger: TriggerSource
    public let target: TargetSnapshot?
    public let totalMicros: UInt32
    public let outcome: FinalOutcome
    public let attempts: [StrategyAttempt]
    public let dropped: Int

    public init(
        schemaVersion: Int = CascadeReport.currentSchemaVersion,
        traceID: TraceID,
        trigger: TriggerSource,
        target: TargetSnapshot? = nil,
        totalMicros: UInt32,
        outcome: FinalOutcome,
        attempts: [StrategyAttempt] = [],
        dropped: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.traceID = traceID
        self.trigger = trigger
        self.target = target
        self.totalMicros = totalMicros
        self.outcome = outcome
        self.attempts = attempts
        self.dropped = dropped
    }
}

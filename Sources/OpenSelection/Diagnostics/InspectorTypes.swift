// InspectorTypes.swift
// OpenSelection
//
// Data structures and schemas for the OpenSelection diagnostic inspector.
import ApplicationServices
import Foundation

/// Target definition for diagnostic inspection.
public enum InspectionTarget: Sendable {
    case frontmost
    case pid(pid_t)
    case bundleID(String)
    case focusedAfter(delay: TimeInterval)
}

/// Options controlling depth, budget, and invasiveness of the inspector.
public struct InspectionOptions: Sendable {
    public var depth: Int
    public var nodeBudget: Int
    public var deadlineSeconds: TimeInterval
    public var allowIntrusiveProbes: Bool

    public init(
        depth: Int = 10,
        nodeBudget: Int = 100,
        deadlineSeconds: TimeInterval = 3.0,
        allowIntrusiveProbes: Bool = false
    ) {
        self.depth = depth
        self.nodeBudget = nodeBudget
        self.deadlineSeconds = deadlineSeconds
        self.allowIntrusiveProbes = allowIntrusiveProbes
    }
}

/// Host system environment information.
public struct SystemInfo: Sendable, Codable, Equatable {
    public let osVersion: String
    public let architecture: TargetArchitecture
    public let isAXTrusted: Bool
    public let hostBundleID: String?

    public init(
        osVersion: String,
        architecture: TargetArchitecture,
        isAXTrusted: Bool,
        hostBundleID: String?
    ) {
        self.osVersion = osVersion
        self.architecture = architecture
        self.isAXTrusted = isAXTrusted
        self.hostBundleID = hostBundleID
    }
}

/// Accessibility capabilities and enhanced flags for an inspected target.
public struct AXCapabilities: Sendable, Codable, Equatable {
    public let isManualAccessibilitySettable: Bool
    public let isManualAccessibilityEnabled: Bool
    public let isEnhancedUserInterfaceSettable: Bool
    public let isEnhancedUserInterfaceEnabled: Bool

    public init(
        isManualAccessibilitySettable: Bool = false,
        isManualAccessibilityEnabled: Bool = false,
        isEnhancedUserInterfaceSettable: Bool = false,
        isEnhancedUserInterfaceEnabled: Bool = false
    ) {
        self.isManualAccessibilitySettable = isManualAccessibilitySettable
        self.isManualAccessibilityEnabled = isManualAccessibilityEnabled
        self.isEnhancedUserInterfaceSettable = isEnhancedUserInterfaceSettable
        self.isEnhancedUserInterfaceEnabled = isEnhancedUserInterfaceEnabled
    }
}

/// Non-leaking probe outcome for accessibility attributes.
public enum ProbeResult: Sendable, Codable, Equatable {
    case presence(TextPresence)
    case error(AXErrorCode)
    case notApplicable
}

/// Sanitized snapshot of an individual accessibility element without content or titles.
public struct ElementSnapshot: Sendable, Codable, Equatable {
    public let role: String?
    public let subrole: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let supportedAttributes: [String]
    public let supportedParameterized: [String]
    public let actions: [String]
    public let selectedText: ProbeResult
    public let selectedRange: ProbeResult
    public let selectedRangeBounds: ProbeResult
    public let markerRangeSupport: ProbeResult?
    public let childrenCount: Int?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        supportedAttributes: [String] = [],
        supportedParameterized: [String] = [],
        actions: [String] = [],
        selectedText: ProbeResult = .notApplicable,
        selectedRange: ProbeResult = .notApplicable,
        selectedRangeBounds: ProbeResult = .notApplicable,
        markerRangeSupport: ProbeResult? = nil,
        childrenCount: Int? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.enabled = enabled
        self.focused = focused
        self.supportedAttributes = supportedAttributes
        self.supportedParameterized = supportedParameterized
        self.actions = actions
        self.selectedText = selectedText
        self.selectedRange = selectedRange
        self.selectedRangeBounds = selectedRangeBounds
        self.markerRangeSupport = markerRangeSupport
        self.childrenCount = childrenCount
    }
}

/// Evaluated viability of a retrieval strategy in preflight.
public struct StrategyPreflight: Sendable, Codable, Equatable {
    public let strategy: SelectionStrategy
    public let viable: Bool
    public let reason: String

    public init(strategy: SelectionStrategy, viable: Bool, reason: String) {
        self.strategy = strategy
        self.viable = viable
        self.reason = reason
    }
}

/// Non-intrusive probe of Edit -> Copy menu item availability.
public struct MenuCopyProbe: Sendable, Codable, Equatable {
    public let editMenuFound: Bool
    public let copyItemPresent: Bool
    public let copyItemEnabled: Bool
    public let shortcutMatchesCommandC: Bool

    public init(
        editMenuFound: Bool,
        copyItemPresent: Bool,
        copyItemEnabled: Bool,
        shortcutMatchesCommandC: Bool
    ) {
        self.editMenuFound = editMenuFound
        self.copyItemPresent = copyItemPresent
        self.copyItemEnabled = copyItemEnabled
        self.shortcutMatchesCommandC = shortcutMatchesCommandC
    }
}

/// Comprehensive diagnostics report generated by OpenSelectionInspector.
public struct TargetDiagnostics: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let system: SystemInfo
    public let target: TargetSnapshot
    public let accessibility: AXCapabilities
    public let focusChain: [ElementSnapshot]
    public let subtree: [ElementSnapshot]
    public let strategyPreflight: [StrategyPreflight]
    public let menuCopy: MenuCopyProbe?
    public let liveRun: CascadeReport?

    public init(
        schemaVersion: Int = TargetDiagnostics.currentSchemaVersion,
        generatedAt: Date = Date(),
        system: SystemInfo,
        target: TargetSnapshot,
        accessibility: AXCapabilities = AXCapabilities(),
        focusChain: [ElementSnapshot] = [],
        subtree: [ElementSnapshot] = [],
        strategyPreflight: [StrategyPreflight] = [],
        menuCopy: MenuCopyProbe? = nil,
        liveRun: CascadeReport? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.system = system
        self.target = target
        self.accessibility = accessibility
        self.focusChain = focusChain
        self.subtree = subtree
        self.strategyPreflight = strategyPreflight
        self.menuCopy = menuCopy
        self.liveRun = liveRun
    }

    public func renderJSON(pretty: Bool = true) -> Data {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    public func renderText() -> String {
        var lines: [String] = []
        lines.append("=== OpenSelection Target Diagnostics ===")
        lines.append("Schema Version: \(schemaVersion)")
        lines.append("Timestamp: \(generatedAt)")
        lines.append("")
        lines.append("--- System ---")
        lines.append("OS Version: \(system.osVersion)")
        lines.append("Arch: \(system.architecture.rawValue)")
        lines.append("AX Trusted: \(system.isAXTrusted)")
        if let host = system.hostBundleID {
            lines.append("Host Bundle: \(host)")
        }
        lines.append("")
        lines.append("--- Target Application ---")
        lines.append("PID: \(target.pid)")
        lines.append("Bundle ID: \(target.bundleID ?? "unknown")")
        lines.append("Framework: \(target.framework.rawValue)")
        lines.append("Rosetta: \(target.isRosettaTranslated)")
        if let cursor = target.cursor {
            lines.append("Cursor: \(cursor.rawValue)")
        }
        lines.append("")
        lines.append("--- Accessibility Capabilities ---")
        lines.append("AXManualAccessibility: \(accessibility.isManualAccessibilityEnabled) (settable: \(accessibility.isManualAccessibilitySettable))")
        lines.append("AXEnhancedUserInterface: \(accessibility.isEnhancedUserInterfaceEnabled) (settable: \(accessibility.isEnhancedUserInterfaceSettable))")
        lines.append("")
        lines.append("--- Strategy Preflights ---")
        for preflight in strategyPreflight {
            let status = preflight.viable ? "[VIABLE]" : "[BLOCKED]"
            lines.append("  \(preflight.strategy.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(status) - \(preflight.reason)")
        }
        lines.append("")
        if let menu = menuCopy {
            lines.append("--- Menu Copy Probe ---")
            lines.append("Edit Menu Found: \(menu.editMenuFound)")
            lines.append("Copy Present: \(menu.copyItemPresent)")
            lines.append("Copy Enabled: \(menu.copyItemEnabled)")
            lines.append("Shortcut ⌘C: \(menu.shortcutMatchesCommandC)")
            lines.append("")
        }
        lines.append("--- Focus Chain (\(focusChain.count) elements) ---")
        for (i, elem) in focusChain.enumerated() {
            let roleStr = elem.role ?? "unknown"
            let subroleStr = elem.subrole.map { "/\($0)" } ?? ""
            lines.append("  [\(i)] \(roleStr)\(subroleStr) (attrs: \(elem.supportedAttributes.count), actions: \(elem.actions.count))")
        }
        if let live = liveRun {
            lines.append("")
            lines.append("--- Live Cascade Run ---")
            lines.append("Trace ID: \(live.traceID)")
            lines.append("Total Time: \(live.totalMicros)µs")
            lines.append("Outcome: \(live.outcome)")
            lines.append("Attempts: \(live.attempts.count)")
            for att in live.attempts {
                lines.append("  * \(att.strategy.rawValue): \(att.outcome) in \(att.durationMicros)µs")
            }
        }
        return lines.joined(separator: "\n")
    }
}

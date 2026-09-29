// SelectionRetrievalCoordinator.swift
// OpenSelection
//
// Routes a selection-retrieval request through the gate (skip-roles / cursor class), resolves the
// app's retrieval mode, and delegates to the matching strategy. The blocking AX snapshot
// (AXElementInspector.inspect) runs off the cooperative pool on a dedicated queue, raced against
// configuration.axReadTimeout so a slow or unresponsive target app can never hang the caller.
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import os

public struct CopyEvidence: Sendable, Equatable {
    public enum Strength: Int, Sendable, Comparable {
        case weak = 0
        case strong = 1

        public static func < (lhs: Strength, rhs: Strength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let reason: String
    public let strength: Strength

    public init(_ reason: String, _ strength: Strength) {
        self.reason = reason
        self.strength = strength
    }
}

public struct CopyRequest: Sendable {
    public let trigger: SelectionRetrievalCoordinator.CopyTrigger
    public let evidence: CopyEvidence

    public init(trigger: @escaping SelectionRetrievalCoordinator.CopyTrigger, evidence: CopyEvidence) {
        self.trigger = trigger
        self.evidence = evidence
    }

    @MainActor
    public func callAsFunction() {
        trigger()
    }
}

public struct SelectionRetrievalCoordinator: Sendable {
    public typealias TargetProvider = @Sendable (SelectionTrace?) -> AXElementInspector.Target
    public typealias SimpleTargetProvider = @Sendable () -> AXElementInspector.Target
    public typealias CopyTrigger = PasteboardCopyEngine.CopyTrigger
    public typealias LegacyCopyCapture = @Sendable (@escaping CopyTrigger) async -> SelectionResult?
    public typealias CopyCapture = @Sendable (CopyRequest) async -> SelectionResult?
    public typealias MenuPress = @Sendable (AXUIElement?) -> Void
    public typealias ScriptRunner = @Sendable (String) async throws -> String

    /// Dedicated concurrent queue for blocking AX work (the inspect snapshot and the Edit ▸ Copy
    /// AXPress). Concurrent so a blocked accessibility call cannot prevent later inspectWithWatchdog
    /// and pressCopyMenuWithWatchdog work from starting.
    private static let axInspectQueue = DispatchQueue(label: "com.openselection.ax-inspect", qos: .userInitiated, attributes: .concurrent)

    /// Regulates concurrent accessibility inspect and menu-press calls up to `configuration.axMaxConcurrentInspects`.
    private actor InspectConcurrencyGate {
        private var inFlight = 0
        func tryAcquire(limit: Int) -> Bool {
            guard inFlight < limit else { return false }
            inFlight += 1
            return true
        }
        func release() {
            inFlight -= 1
        }
    }
    private static let inspectGate = InspectConcurrencyGate()

    public let configuration: SelectionConfiguration
    private let inspect: TargetProvider
    private let copyCapture: CopyCapture
    private let menuPress: MenuPress
    private let scriptRunner: ScriptRunner

    /// Designated initializer accepting a trace-aware target provider.
    public init(
        configuration: SelectionConfiguration = .default,
        inspect: @escaping TargetProvider = { trace in AXElementInspector.inspect(trace: trace) },
        copyCapture: CopyCapture? = nil,
        menuPress: @escaping MenuPress = Self.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = Self.defaultScriptRunner
    ) {
        self.configuration = configuration
        self.inspect = inspect
        self.copyCapture = copyCapture ?? { request in
            await PasteboardCopyEngine(configuration: configuration).capture(trigger: request.trigger)
        }
        self.menuPress = menuPress
        self.scriptRunner = scriptRunner
    }

    /// Convenience initializer accepting a parameterless target provider.
    public init(
        configuration: SelectionConfiguration = .default,
        inspect: @escaping SimpleTargetProvider,
        copyCapture: CopyCapture? = nil,
        menuPress: @escaping MenuPress = Self.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = Self.defaultScriptRunner
    ) {
        self.init(
            configuration: configuration,
            inspect: { _ in inspect() },
            copyCapture: copyCapture,
            menuPress: menuPress,
            scriptRunner: scriptRunner
        )
    }

    /// Convenience initializer accepting inspectWithTrace explicitly.
    public init(
        configuration: SelectionConfiguration = .default,
        inspectWithTrace: @escaping TargetProvider,
        copyCapture: CopyCapture? = nil,
        menuPress: @escaping MenuPress = Self.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = Self.defaultScriptRunner
    ) {
        self.init(
            configuration: configuration,
            inspect: inspectWithTrace,
            copyCapture: copyCapture,
            menuPress: menuPress,
            scriptRunner: scriptRunner
        )
    }

    /// Overload supporting legacy copyCapture closures taking CopyTrigger directly.
    public init(
        configuration: SelectionConfiguration = .default,
        inspect: @escaping SimpleTargetProvider,
        legacyCopyCapture: @escaping LegacyCopyCapture,
        menuPress: @escaping MenuPress = Self.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = Self.defaultScriptRunner
    ) {
        self.init(
            configuration: configuration,
            inspect: { _ in inspect() },
            copyCapture: { request in await legacyCopyCapture(request.trigger) },
            menuPress: menuPress,
            scriptRunner: scriptRunner
        )
    }

    /// Overload supporting legacy copyCapture closures with trace-aware target provider.
    public init(
        configuration: SelectionConfiguration = .default,
        inspect: @escaping TargetProvider = { trace in AXElementInspector.inspect(trace: trace) },
        legacyCopyCapture: @escaping LegacyCopyCapture,
        menuPress: @escaping MenuPress = Self.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = Self.defaultScriptRunner
    ) {
        self.init(
            configuration: configuration,
            inspect: inspect,
            copyCapture: { request in await legacyCopyCapture(request.trigger) },
            menuPress: menuPress,
            scriptRunner: scriptRunner
        )
    }

    /// Default AppleScript runner for Office selection retrieval.
    public static func defaultScriptRunner(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorInfo: NSDictionary?
                let appleScript = NSAppleScript(source: script)
                let descriptor = appleScript?.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
                    continuation.resume(throwing: NSError(domain: "OpenSelection.AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
                } else if let descriptor {
                    continuation.resume(returning: Self.extractString(from: descriptor))
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Extracts text from AppleScript descriptors, recursively flattening nested lists (e.g. Excel cell ranges).
    public static func extractString(from descriptor: NSAppleEventDescriptor) -> String {
        if let str = descriptor.stringValue {
            return str
        }
        if descriptor.numberOfItems > 0 {
            var rows: [String] = []
            for i in 1...descriptor.numberOfItems {
                guard let item = descriptor.atIndex(i) else { continue }
                if item.numberOfItems > 0 {
                    var cols: [String] = []
                    for j in 1...item.numberOfItems {
                        if let cellStr = item.atIndex(j)?.stringValue {
                            cols.append(cellStr)
                        }
                    }
                    rows.append(cols.joined(separator: "\t"))
                } else if let val = item.stringValue {
                    rows.append(val)
                }
            }
            return rows.joined(separator: "\n")
        }
        return ""
    }

    /// Press the Edit ▸ Copy menu item in `app`'s menu bar.
    public static func pressEditCopyMenu(app: AXUIElement?) {
        AXMenuNavigator.press(.copy, in: app)
    }

    // MARK: - Retrieval Methods

    /// Reads the current selection and context details for an app under `policy`.
    public func retrieveDetails(
        for app: AppIdentity = AppIdentity(),
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true,
        trigger: TriggerSource = .programmatic,
        trace: SelectionTrace? = nil
    ) async -> (result: SelectionResult?, isEditable: Bool) {
        let activeTrace = trace ?? SelectionTrace.create(trigger: trigger)
        let bundleID = app.bundleIdentifier ?? "unknown"
        activeTrace.log(.debug, .cascade, "retrieval started", fields: [
            "bundleID": .token(bundleID),
            "cursor": .token(cursor.rawValue)
        ])

        let target = await inspectWithWatchdog(trace: activeTrace)
        guard let target else {
            activeTrace.log(.warning, .ax, "ax inspect timed out", fields: [
                "bundleID": .token(bundleID)
            ])
            if trace != nil || DiagnosticsHub.shared.isReportRequired(outcome: FinalOutcome.none, elapsedMicros: activeTrace.elapsedMicros) {
                let report = activeTrace.buildReport(outcome: FinalOutcome.none)
                DiagnosticsHub.shared.emitReport(report)
            }
            return (nil, false)
        }

        let isEditable = Self.isEditableContext(target)

        var targetPID: pid_t = app.processIdentifier ?? 0
        if targetPID == 0, let axApp = target.focusedApp {
            var pid: pid_t = 0
            if AXUIElementGetPid(axApp, &pid) == .success {
                targetPID = pid
            }
        }
        if targetPID == 0 {
            targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        }

        var targetArch: TargetArchitecture
        #if arch(arm64)
        targetArch = .arm64
        #elseif arch(x86_64)
        targetArch = .x86_64
        #else
        targetArch = .unknown
        #endif

        var isRosetta = false
        if targetPID > 0, let running = NSRunningApplication(processIdentifier: targetPID) {
            #if arch(arm64)
            if running.executableArchitecture == NSBundleExecutableArchitectureX86_64 {
                targetArch = .x86_64
                isRosetta = true
            } else if running.executableArchitecture == NSBundleExecutableArchitectureARM64 {
                targetArch = .arm64
            }
            #elseif arch(x86_64)
            if running.executableArchitecture == NSBundleExecutableArchitectureX86_64 {
                targetArch = .x86_64
            }
            #endif
        }

        let targetSnapshot = TargetSnapshot(
            pid: targetPID,
            bundleID: app.bundleIdentifier ?? NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier,
            architecture: targetArch,
            isRosettaTranslated: isRosetta,
            framework: Self.frameworkFingerprint(for: app.bundleIdentifier),
            cursor: Self.cursorKind(from: cursor),
            windowBounds: target.bounds
        )
        activeTrace.recordTarget(targetSnapshot)

        // Gate 1: skip UI roles that can never hold a text selection.
        let isWeb = target.webArea != nil || target.role == "AXWebArea" || target.containedInRoles.contains("AXWebArea")
        if let role = target.role, policy.gate.skipRoles.contains(role) {
            if !(isWeb && role == "AXButton") {
                activeTrace.log(.debug, .gate, "role is gated", fields: [
                    "bundleID": .token(bundleID),
                    "role": .token(role)
                ])
                if trace != nil || DiagnosticsHub.shared.isReportRequired(outcome: FinalOutcome.none, elapsedMicros: activeTrace.elapsedMicros) {
                    let report = activeTrace.buildReport(outcome: FinalOutcome.none)
                    DiagnosticsHub.shared.emitReport(report)
                }
                return (nil, isEditable)
            }
        }

        // Gate 2: only read when the cursor class suggests a text context.
        if cursor != .unknown, !policy.gate.allowedCursors.contains(cursor) {
            activeTrace.log(.debug, .gate, "cursor not allowed", fields: [
                "bundleID": .token(bundleID),
                "cursor": .token(cursor.rawValue)
            ])
            if trace != nil || DiagnosticsHub.shared.isReportRequired(outcome: FinalOutcome.none, elapsedMicros: activeTrace.elapsedMicros) {
                let report = activeTrace.buildReport(outcome: FinalOutcome.none)
                DiagnosticsHub.shared.emitReport(report)
            }
            return (nil, isEditable)
        }

        // Whole-container select gesture (⌘A, ⌘L) landing on a row selection (Finder, Mail, table views)
        if isSelectAll, Self.isRowSelectionContext(target) {
            activeTrace.log(.debug, .gate, "select-all on row-selection element skipped")
            if trace != nil || DiagnosticsHub.shared.isReportRequired(outcome: FinalOutcome.none, elapsedMicros: activeTrace.elapsedMicros) {
                let report = activeTrace.buildReport(outcome: FinalOutcome.none)
                DiagnosticsHub.shared.emitReport(report)
            }
            return (nil, isEditable)
        }

        activeTrace.log(.debug, .cascade, "gate passed", fields: [
            "bundleID": .token(bundleID),
            "strategy": .token(policy.retrievalMode.rawValue)
        ])

        // Waive the copy-evidence gate when a synthetic copy is the only read that can possibly
        // succeed, decided structurally rather than by bundle identity:
        // 1. The app is a known copy-fallback app (the OneNote allowlist), or
        // 2. the inspect target exposes no text surface at all — no selected text/range, no text
        //    role, no containing AXWebArea. An AX tree like that (OneNote-class native opaque
        //    canvases) can never yield AX evidence, so requiring it permanently skips the one
        //    strategy that works. Web/Electron canvases stay protected: an AXWebArea ancestor
        //    makes the target text-bearing, so Figma-style object drags still require evidence.
        //
        // Item-selection surfaces are excluded from (2). A drag across a Photos grid, Mail list or
        // Finder column selects *items*, not text, and an opaque grid is exactly as evidence-free as
        // a OneNote canvas — but posting a real ⌘C there copies image/file data and stalls the
        // capture for the full polling timeout, so those targets keep the evidence requirement.
        let isItemSelectionSurface = target.role.map { Self.rowSelectionRoles.contains($0) } == true
            || !target.containedInRoles.isDisjoint(with: Self.rowSelectionRoles)
        let evidenceRequired = requireCopyEvidence
            && !AppMatching.isCopyFallbackApp(app.bundleIdentifier)
            && (Self.isTextBearing(target) || isItemSelectionSurface)
        if requireCopyEvidence, !evidenceRequired, let bID = app.bundleIdentifier {
            activeTrace.log(.debug, .gate, "copy allowed without ax evidence", fields: ["bundleID": .token(bID)])
        }

        let readResult = Self.nonBlank(await read(
            for: app,
            target: target,
            policy: policy,
            cursor: cursor,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: evidenceRequired,
            trace: activeTrace
        ))

        let finalOutcome: FinalOutcome
        if let readResult {
            finalOutcome = .selection(strategy: readResult.strategy, presence: .nonEmpty)
        } else {
            finalOutcome = .none
        }

        if trace != nil || DiagnosticsHub.shared.isReportRequired(outcome: finalOutcome, elapsedMicros: activeTrace.elapsedMicros) {
            let report = activeTrace.buildReport(outcome: finalOutcome)
            DiagnosticsHub.shared.emitReport(report)
            let resultWithDiagnostics = readResult?.withDiagnostics(report)
            return (resultWithDiagnostics, isEditable)
        } else {
            return (readResult, isEditable)
        }
    }

    /// Convenience for NSRunningApplication.
    public func retrieveDetails(
        for app: NSRunningApplication?,
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true,
        trigger: TriggerSource = .programmatic,
        trace: SelectionTrace? = nil
    ) async -> (result: SelectionResult?, isEditable: Bool) {
        await retrieveDetails(
            for: AppIdentity(app),
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence,
            trigger: trigger,
            trace: trace
        )
    }

    /// Reads the current selection for `app` under `policy`.
    public func retrieve(
        for app: AppIdentity = AppIdentity(),
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true,
        trigger: TriggerSource = .programmatic,
        trace: SelectionTrace? = nil
    ) async -> SelectionResult? {
        await retrieveDetails(
            for: app,
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence,
            trigger: trigger,
            trace: trace
        ).result
    }

    /// Convenience for NSRunningApplication.
    public func retrieve(
        for app: NSRunningApplication?,
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true,
        trigger: TriggerSource = .programmatic,
        trace: SelectionTrace? = nil
    ) async -> SelectionResult? {
        await retrieve(
            for: AppIdentity(app),
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence,
            trigger: trigger,
            trace: trace
        )
    }

    // MARK: - Internal Cascade & Execution

    private func read(
        for app: AppIdentity,
        target: AXElementInspector.Target,
        policy: SelectionPolicy,
        cursor: CursorClass,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true,
        trace: SelectionTrace
    ) async -> SelectionResult? {
        let bundleID = app.bundleIdentifier ?? "unknown"
        var strategies = strategyCascade(for: policy, target: target, bundleIdentifier: app.bundleIdentifier)
        if !allowCopyFallback {
            let nonCopy = strategies.filter { $0 != .keyboardCopy && $0 != .menuCopy }
            if nonCopy.isEmpty {
                // The overlay gate forbids the synthetic ⌘C, not reading. An app whose cascade is
                // copy-only (Typora, CotEditor) would otherwise be left with nothing to try and
                // return nil, so the popup never appears while any overlay is up. The AX strategies
                // post no events, so degrading to them keeps the gate's promise and can still read
                // the selection (Electron/web views expose it via AXWebArea).
                strategies = [.axTextControl, .axWebArea]
                trace.log(.debug, .gate, "overlay gate active, trying ax only", fields: ["bundleID": .token(bundleID)])
            } else {
                strategies = nonCopy
            }
        }

        for (index, strategy) in strategies.enumerated() {
            let attemptStart = UInt32(min(UInt64(UInt32.max), trace.elapsedMicros))
            if index > 0 {
                let previous = strategies[index - 1]
                trace.log(.debug, .cascade, "strategy fallback", fields: [
                    "bundleID": .token(bundleID),
                    "fromStrategy": .token(previous.rawValue),
                    "toStrategy": .token(strategy.rawValue)
                ])
            }
            var evidence: CopyEvidence? = nil
            if strategy == .keyboardCopy || strategy == .menuCopy {
                if requireCopyEvidence {
                    if let ev = Self.copyEvidence(
                        strategy,
                        target: target,
                        cursor: cursor,
                        bundleID: app.bundleIdentifier,
                        isFallbackFromAX: index > 0
                    ) {
                        evidence = ev
                        trace.log(.debug, .gate, "copy strategy permitted", fields: [
                            "bundleID": .token(bundleID),
                            "strategy": .token(strategy.rawValue),
                            "evidence": .token(ev.reason)
                        ])
                    } else {
                        trace.log(.debug, .gate, "copy strategy skipped, no evidence", fields: [
                            "bundleID": .token(bundleID),
                            "strategy": .token(strategy.rawValue)
                        ])
                        let duration = UInt32(min(UInt64(UInt32.max), trace.elapsedMicros - UInt64(attemptStart)))
                        trace.recordAttempt(StrategyAttempt(
                            strategy: strategy,
                            outcome: .skipped(.noTextEvidence),
                            startOffsetMicros: attemptStart,
                            durationMicros: duration
                        ))
                        continue
                    }
                } else {
                    evidence = CopyEvidence("waived-ax-blind-surface", .strong)
                }
            }
            let (rawResult, outcome) = await run(strategy, app: app, target: target, evidence: evidence, trace: trace)
            if let result = Self.nonBlank(rawResult) {
                let duration = UInt32(min(UInt64(UInt32.max), trace.elapsedMicros - UInt64(attemptStart)))
                trace.recordAttempt(StrategyAttempt(
                    strategy: strategy,
                    outcome: .succeeded,
                    startOffsetMicros: attemptStart,
                    durationMicros: duration
                ))
                if index > 0 {
                    trace.log(.info, .cascade, "fallback strategy succeeded", fields: [
                        "bundleID": .token(bundleID),
                        "strategy": .token(strategy.rawValue)
                    ])
                } else {
                    trace.log(.info, .cascade, "primary strategy succeeded", fields: [
                        "bundleID": .token(bundleID),
                        "strategy": .token(strategy.rawValue)
                    ])
                }
                return await enrichRichContent(
                    result,
                    strategy: strategy,
                    app: app,
                    target: target,
                    allowCopyFallback: allowCopyFallback,
                    trace: trace
                )
            } else {
                let duration = UInt32(min(UInt64(UInt32.max), trace.elapsedMicros - UInt64(attemptStart)))
                trace.recordAttempt(StrategyAttempt(
                    strategy: strategy,
                    outcome: outcome,
                    startOffsetMicros: attemptStart,
                    durationMicros: duration
                ))
            }
        }
        trace.log(.info, .cascade, "all strategies exhausted", fields: ["bundleID": .token(bundleID)])
        return nil
    }

    private static func cursorKind(from cursor: CursorClass) -> CursorKind {
        switch cursor {
        case .beam: return .iBeam
        case .arrow: return .arrow
        case .pointingHand: return .pointingHand
        default: return .other
        }
    }

    private static func frameworkFingerprint(for bundleID: String?) -> FrameworkFingerprint {
        guard let bundleID else { return .unknown }
        if AppMatching.isBrowser(bundleID) {
            return bundleID == "com.apple.Safari" ? .webkit : .chromium
        }
        if AppMatching.isMultiProcess(bundleID) {
            return .electron
        }
        if AppMatching.isMicrosoftOffice(bundleID) {
            return .office
        }
        if AppMatching.isTerminal(bundleID) {
            return .terminal
        }
        return .native
    }

    private func enrichRichContent(
        _ result: SelectionResult,
        strategy: SelectionStrategy,
        app: AppIdentity,
        target: AXElementInspector.Target,
        allowCopyFallback: Bool = true,
        trace: SelectionTrace
    ) async -> SelectionResult {
        guard configuration.enrichRichContent else { return result }
        guard allowCopyFallback else { return result }
        guard result.html == nil && result.rtf == nil else { return result }
        guard strategy != .keyboardCopy && strategy != .menuCopy && strategy != .officeScript else { return result }
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return result }
        // The winning result is substantial text read from the target app by a non-copy strategy
        // (copy strategies are excluded above), so a real text selection is already established.
        // Checking `target` for evidence here would be wrong anyway: the web-area cascade may have
        // retrieved the text from a fresh settle-retry snapshot, leaving `target` (the original
        // inspect) stale and evidence-free.
        let bundleIsBrowser = AppMatching.isBrowser(bundleID)
        let isMultiProcessApp = AppMatching.isMultiProcess(bundleID)
        let isRichDocumentApp = AppMatching.isRichDocumentApp(bundleID)
        let hasWebArea = target.webArea != nil || target.role == "AXWebArea" || target.containedInRoles.contains("AXWebArea")
        guard bundleIsBrowser || isMultiProcessApp || isRichDocumentApp || hasWebArea else { return result }
        trace.log(.debug, .enrichment, "enriching via pasteboard rich capture", fields: ["bundleID": .token(bundleID)])
        // Keep the capture when it carries anything the AX read cannot express: HTML, RTF,
        // multi-line text, or app-private pasteboard flavors (e.g. `com.apple.notes.richtext`).
        // A single-line capture with only flavors must still replace the flavorless AX result.
        let (capturedRaw, _) = await run(
            .keyboardCopy,
            app: app,
            target: target,
            evidence: CopyEvidence("rich-enrichment", .strong),
            trace: trace
        )
        guard let captured = Self.nonBlank(capturedRaw),
              captured.html != nil || captured.rtf != nil || !captured.flavors.isEmpty || captured.text.contains("\n") else {
            return result
        }
        return SelectionResult(
            text: captured.text,
            bounds: result.bounds ?? captured.bounds,
            html: captured.html,
            rtf: captured.rtf,
            flavors: captured.flavors,
            sourceApp: result.sourceApp,
            strategy: strategy,
            isEditable: result.isEditable
        )
    }

    private func strategyCascade(
        for policy: SelectionPolicy,
        target: AXElementInspector.Target,
        bundleIdentifier: String?
    ) -> [SelectionStrategy] {
        switch policy.retrievalMode {
        case .axTextControl:
            if let bundleIdentifier, Self.isMicrosoftOffice(bundleIdentifier) {
                return [.officeScript]
            }
            if target.webArea != nil || target.role == "AXWebArea" || target.containedInRoles.contains("AXWebArea") {
                return [.axWebArea, .keyboardCopy]
            }
            if bundleIdentifier == "com.apple.Preview" {
                return [.axTextControl, .keyboardCopy]
            }
            if let bundleIdentifier, AppMatching.isStrictlyNative(bundleIdentifier) {
                return [.axTextControl]
            }
            return [.axTextControl, .keyboardCopy]

        case .axWebArea, .browserScript:
            return [.axWebArea, .keyboardCopy]

        case .menuCopy:
            return [.menuCopy]

        case .keyboardCopy:
            // Electron/Chromium apps (Discord, Slack, VS Code, Linear…) expose their selection
            // through AX once accessibility is active. Try those non-destructive reads before
            // posting a synthetic ⌘C, so the copy is a genuine last resort rather than the
            // default even when AX can see the selection.
            if AppMatching.isMultiProcess(bundleIdentifier) {
                if target.webArea != nil || target.role == "AXWebArea" || target.containedInRoles.contains("AXWebArea") {
                    return [.axWebArea, .keyboardCopy]
                }
                return [.axTextControl, .keyboardCopy]
            }
            return [.keyboardCopy]

        case .officeScript:
            return [.officeScript]
        }
    }

    private func run(
        _ strategy: SelectionStrategy,
        app: AppIdentity,
        target: AXElementInspector.Target,
        evidence: CopyEvidence? = nil,
        trace: SelectionTrace? = nil
    ) async -> (result: SelectionResult?, outcome: StrategyOutcome) {
        switch strategy {
        case .axTextControl:
            if let res = AXTextControlStrategy.read(from: target) {
                return (res, .succeeded)
            }
            if let len = Self.rangeLength(of: target), len == 0 {
                return (nil, .empty(.rangeZero))
            }
            return (nil, .empty(.noSelection))

        case .axWebArea:
            var snapshot: AXElementInspector.Target? = target
            var attempts = 0
            while attempts < configuration.webAreaSettleMaxRetries {
                if let snapshot, let result = AXWebAreaStrategy.read(from: snapshot) {
                    return (result, .succeeded)
                }
                attempts += 1
                if attempts < configuration.webAreaSettleMaxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(configuration.webAreaSettleInterval * 1_000_000_000))
                    if let element = snapshot?.webArea ?? snapshot?.focusedElement,
                       let result = AXWebAreaStrategy.pollFresh(from: element) {
                        return (result, .succeeded)
                    }
                    snapshot = await inspectWithWatchdog(trace: trace)
                }
            }
            return (nil, attempts > 0 ? .timedOut : .empty(.noSelection))

        case .officeScript:
            return await runOfficeScript(for: app, target: target, trace: trace)

        case .browserScript:
            return (nil, .skipped(.noTextEvidence))

        case .menuCopy, .keyboardCopy:
            let trigger: CopyTrigger
            switch strategy {
            case .menuCopy:
                let press = menuPress
                let timeout = configuration.axReadTimeout
                let maxConcurrent = configuration.axMaxConcurrentInspects
                trigger = {
                    Task.detached {
                        await Self.pressCopyMenuWithWatchdog(
                            app: target.focusedApp,
                            press: press,
                            timeout: timeout,
                            maxConcurrent: maxConcurrent
                        )
                    }
                }
            case .keyboardCopy:
                let copyKey = configuration.copyVirtualKey
                trigger = { KeyboardEventPoster.postKey(keyCode: copyKey, flags: .maskCommand) }
            default:
                return (nil, .empty(.noSelection))
            }
            let request = CopyRequest(trigger: trigger, evidence: evidence ?? CopyEvidence("unspecified", .weak))
            guard let captured = await copyCapture(request) else {
                return (nil, Task.isCancelled ? .cancelled : .empty(.noSelection))
            }
            let res = SelectionResult(
                text: captured.text,
                bounds: target.bounds,
                html: captured.html,
                rtf: captured.rtf,
                flavors: captured.flavors,
                sourceApp: nil,
                strategy: strategy,
                isEditable: false
            )
            return (res, .succeeded)
        }
    }

    // MARK: - Office Scripts

    public static func isMicrosoftOffice(_ bundleIdentifier: String?) -> Bool {
        AppMatching.isMicrosoftOffice(bundleIdentifier)
    }

    public static func officeScript(for bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case "com.microsoft.Word":
            return "tell application id \"com.microsoft.Word\" to if (count of documents) > 0 then return content of text object of selection"
        case "com.microsoft.Excel":
            return "tell application id \"com.microsoft.Excel\" to if (count of workbooks) > 0 then return string value of selection"
        case "com.microsoft.Powerpoint":
            // PowerPoint's app-level `selection` does not resolve to the document window's
            // selection, so `text range of selection` throws -1728. The working reference is
            // `selection of active window`; the type guard returns empty instead of throwing when
            // a shape or slide (rather than text) is selected.
            return """
            tell application id "com.microsoft.Powerpoint"
                if (count of presentations) = 0 then return ""
                try
                    if (selection type of selection of active window) is selection type text then
                        return content of text range of selection of active window
                    end if
                end try
                return ""
            end tell
            """
        default:
            return nil
        }
    }

    private func runOfficeScript(
        for app: AppIdentity,
        target: AXElementInspector.Target,
        trace: SelectionTrace? = nil
    ) async -> (result: SelectionResult?, outcome: StrategyOutcome) {
        guard let bundleID = app.bundleIdentifier else { return (nil, .empty(.noSelection)) }
        guard let script = Self.officeScript(for: bundleID) else {
            trace?.log(.warning, .cascade, "office script template missing", fields: ["bundleID": .token(bundleID)])
            return (nil, .failed(.scriptError))
        }
        do {
            let timeout = configuration.officeScriptTimeout
            let runner = scriptRunner
            let output = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await runner(script)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw CancellationError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "missing value" else { return (nil, .empty(.noSelection)) }
            return (SelectionResult(
                text: trimmed,
                bounds: target.bounds,
                strategy: .officeScript,
                isEditable: true
            ), .succeeded)
        } catch is CancellationError {
            trace?.log(.warning, .cascade, "office script timed out", fields: [
                "bundleID": .token(bundleID),
                "timeoutMicros": .micros(UInt32(configuration.officeScriptTimeout * 1_000_000))
            ])
            return (nil, .timedOut)
        } catch {
            trace?.log(.warning, .cascade, "office script failed", fields: ["bundleID": .token(bundleID)])
            return (nil, .failed(.scriptError))
        }
    }

    // MARK: - Watchdog AX Workers

    private func inspectWithWatchdog(trace: SelectionTrace? = nil) async -> AXElementInspector.Target? {
        guard await Self.inspectGate.tryAcquire(limit: configuration.axMaxConcurrentInspects) else {
            trace?.log(.warning, .ax, "inspect concurrency cap reached")
            return nil
        }
        let inspect = self.inspect
        let timeoutSeconds = self.configuration.axReadTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<AXElementInspector.Target?, Never>) in
            let resume = OnceResume<AXElementInspector.Target?>()
            let timeout = TaskBox()

            timeout.set(Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if resume.resume(continuation, with: nil) {
                    Task.detached { await Self.inspectGate.release() }
                    trace?.log(.warning, .ax, "ax inspect deadline exceeded", fields: [
                        "timeoutMicros": .micros(UInt32(timeoutSeconds * 1_000_000))
                    ])
                }
            })

            Self.axInspectQueue.async {
                let target = inspect(trace)
                if resume.resume(continuation, with: target) {
                    timeout.cancel()
                    Task.detached { await Self.inspectGate.release() }
                }
            }
        }
    }

    private static func pressCopyMenuWithWatchdog(
        app: AXUIElement?,
        press: @escaping MenuPress,
        timeout: TimeInterval,
        maxConcurrent: Int
    ) async {
        guard await inspectGate.tryAcquire(limit: maxConcurrent) else {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSettled = OSAllocatedUnfairLock(initialState: false)
            let watchdog = TaskBox()

            let finishOperation: @Sendable (Bool) -> Void = { didTimeout in
                let shouldRelinquish = isSettled.withLock { settled -> Bool in
                    guard !settled else { return false }
                    settled = true
                    return true
                }
                guard shouldRelinquish else { return }

                if didTimeout {
                    DiagnosticsHub.shared.log(.warning, .ax, "menu press deadline exceeded", fields: [
                        "timeoutMicros": .micros(UInt32(timeout * 1_000_000))
                    ])
                } else {
                    watchdog.cancel()
                }

                Task.detached {
                    await inspectGate.release()
                }
                continuation.resume()
            }

            watchdog.set(Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finishOperation(true)
            })

            nonisolated(unsafe) let element = app
            axInspectQueue.async {
                press(element)
                finishOperation(false)
            }
        }
    }

    // MARK: - Utilities

    public static func isEditableContext(_ target: AXElementInspector.Target) -> Bool {
        let editableRoles: Set<String> = [
            "AXTextField",
            "AXTextArea",
            "AXComboBox",
            "AXSearchField"
        ]
        if let role = target.role, editableRoles.contains(role) {
            return true
        }
        if target.selectedTextRange != nil {
            return true
        }
        return false
    }

    /// Text-control roles that justify a copy-based read on their own. Deliberately excludes
    /// `AXWebArea`: an Electron canvas (Figma) lives inside a web area, so counting it as text
    /// evidence would let a plain object drag through.
    static let textEvidenceRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox"
    ]

    /// Returns the matching text-selection signal when a copy strategy is justified, else `nil`.
    ///
    /// Copy and menu strategies post a real, system-wide side effect (a ⌘C or an Edit ▸ Copy
    /// press), so they must be justified by positive evidence that text is actually selected.
    /// Without this, an app classified as copy-based fires ⌘C on every qualifying gesture — e.g.
    /// dragging a Figma object mutates Figma's selection and undo state instead of reading text.
    ///
    /// Evidence is: an I-beam cursor (a text caret under the pointer), `AXSelectedText` with
    /// content, a resolved `AXStringForTextMarkerRange` with content, a *non-empty*
    /// `AXSelectedTextRange`, or the focused/ancestor element being a text control.
    /// `isTextBearing` is intentionally *not* used here: it returns true whenever
    /// `webArea != nil` or an ancestor is `AXWebArea`.
    ///
    /// Two AX signals are deliberately excluded because they are non-nil even without a text
    /// selection in Electron/web canvases (Figma on its canvas): a collapsed caret exposes an
    /// `AXSelectedTextRange` with length 0 (so the range must have positive length), and a web
    /// area exposes a non-nil `AXSelectedTextMarkerRange` regardless — so only a marker range that
    /// *resolves to text* counts.
    static func rangeLength(of target: AXElementInspector.Target) -> Int? {
        guard let range = target.selectedTextRange, CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        var cfRange = CFRange()
        if AXValueGetValue(range as! AXValue, .cfRange, &cfRange) {
            return cfRange.length
        }
        return nil
    }

    static func copyEvidence(
        _ strategy: SelectionStrategy,
        target: AXElementInspector.Target,
        cursor: CursorClass,
        bundleID: String? = nil,
        isFallbackFromAX: Bool = false
    ) -> CopyEvidence? {
        guard strategy == .keyboardCopy || strategy == .menuCopy else { return nil }

        // AX-positive signals are always strong.
        if let s = target.selectedText, !s.isEmpty { return .init("ax-selected-text", .strong) }
        if let m = target.selectedMarkerText, !m.isEmpty { return .init("ax-marker-text", .strong) }

        let rangeLength = Self.rangeLength(of: target)
        if let len = rangeLength, len > 0 { return .init("ax-selected-text-range", .strong) }

        let isTextControl = target.role.map { textEvidenceRoles.contains($0) } == true
            || !target.containedInRoles.isDisjoint(with: textEvidenceRoles)

        if cursor == .beam {
            // A control that lacks confirmed selection text/range must let the menu veto (TextEdit whitespace drag or empty text field).
            return isTextControl
                ? .init("beam-cursor+text-control", .weak)
                : .init("beam-cursor", .strong)
        }
        if isTextControl { return .init("ax-text-control", .weak) }

        if let bundleID, AppMatching.isBrowser(bundleID) {
            if isFallbackFromAX { return .init("ax-empty-browser-fallback", .weak) }
            if cursor == .unknown || cursor == .pointingHand { return .init("browser-cursor:\(cursor.rawValue)", .weak) }
        }
        return nil
    }

    private static func nonBlank(_ result: SelectionResult?) -> SelectionResult? {
        guard let result else { return nil }
        guard TextSanitizer.isSubstantial(result.text) else { return nil }
        return result
    }

    private static let rowSelectionRoles: Set<String> = [
        "AXTable", "AXOutline", "AXBrowser", "AXList", "AXRow", "AXCell", "AXColumn", "AXGrid"
    ]

    private static func isRowSelectionContext(_ target: AXElementInspector.Target) -> Bool {
        if isTextBearing(target) { return false }
        if let role = target.role, rowSelectionRoles.contains(role) { return true }
        return !target.containedInRoles.isDisjoint(with: rowSelectionRoles)
    }

    private static func isTextBearing(_ target: AXElementInspector.Target) -> Bool {
        if target.selectedTextRange != nil { return true }
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"]
        if let role = target.role, textRoles.contains(role) { return true }
        if !target.containedInRoles.isDisjoint(with: textRoles) { return true }
        return target.webArea != nil
    }
}

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

public struct SelectionRetrievalCoordinator: Sendable {
    public typealias TargetProvider = @Sendable () -> AXElementInspector.Target
    public typealias CopyTrigger = PasteboardCopyEngine.CopyTrigger
    public typealias CopyCapture = @Sendable (CopyTrigger) async -> SelectionResult?
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

    /// The strategies, Edit ▸ Copy press, and script runner are injectable so unit tests can exercise the gate
    /// and mode routing with fixture targets instead of the live accessibility tree.
    public init(
        configuration: SelectionConfiguration = .default,
        inspect: @escaping TargetProvider = { AXElementInspector.inspect() },
        copyCapture: CopyCapture? = nil,
        menuPress: @escaping MenuPress = Self.pressEditCopyMenu,
        scriptRunner: @escaping ScriptRunner = Self.defaultScriptRunner
    ) {
        self.configuration = configuration
        self.inspect = inspect
        self.copyCapture = copyCapture ?? { trigger in
            await PasteboardCopyEngine(configuration: configuration).capture(trigger: trigger)
        }
        self.menuPress = menuPress
        self.scriptRunner = scriptRunner
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
                } else if let stringValue = descriptor?.stringValue {
                    continuation.resume(returning: stringValue)
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
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
        requireCopyEvidence: Bool = true
    ) async -> (result: SelectionResult?, isEditable: Bool) {
        let target = await inspectWithWatchdog()
        guard let target else {
            OpenSelectionLogging.log("coordinator: AX inspect timed out for \(app.bundleIdentifier ?? "unknown"); no selection")
            return (nil, false)
        }

        let isEditable = Self.isEditableContext(target)

        // Gate 1: skip UI roles that can never hold a text selection.
        let isWeb = target.webArea != nil || target.role == "AXWebArea" || target.containedInRoles.contains("AXWebArea")
        if let role = target.role, policy.gate.skipRoles.contains(role) {
            if !(isWeb && role == "AXButton") {
                OpenSelectionLogging.log("coordinator: skipping \(app.bundleIdentifier ?? "unknown"); role \(role) is gated")
                return (nil, isEditable)
            }
        }

        // Gate 2: only read when the cursor class suggests a text context.
        if cursor != .unknown, !policy.gate.allowedCursors.contains(cursor) {
            OpenSelectionLogging.log("coordinator: skipping \(app.bundleIdentifier ?? "unknown"); cursor \(cursor.rawValue) not allowed")
            return (nil, isEditable)
        }

        // Whole-container select gesture (⌘A, ⌘L) landing on a row selection (Finder, Mail, table views)
        if isSelectAll, Self.isRowSelectionContext(target) {
            OpenSelectionLogging.log("coordinator: select-all on a row-selection element; skipping retrieval")
            return (nil, isEditable)
        }

        OpenSelectionLogging.log("coordinator: gate passed for \(app.bundleIdentifier ?? "unknown"); retrieving via \(policy.retrievalMode.rawValue)")

        let readResult = Self.nonBlank(await read(
            for: app,
            target: target,
            policy: policy,
            cursor: cursor,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence
        ))
        return (readResult, isEditable)
    }

    /// Convenience for NSRunningApplication.
    public func retrieveDetails(
        for app: NSRunningApplication?,
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true
    ) async -> (result: SelectionResult?, isEditable: Bool) {
        await retrieveDetails(
            for: AppIdentity(app),
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence
        )
    }

    /// Reads the current selection for `app` under `policy`.
    public func retrieve(
        for app: AppIdentity = AppIdentity(),
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true
    ) async -> SelectionResult? {
        await retrieveDetails(
            for: app,
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence
        ).result
    }

    /// Convenience for NSRunningApplication.
    public func retrieve(
        for app: NSRunningApplication?,
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true
    ) async -> SelectionResult? {
        await retrieve(
            for: AppIdentity(app),
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback,
            requireCopyEvidence: requireCopyEvidence
        )
    }

    // MARK: - Internal Cascade & Execution

    private func read(
        for app: AppIdentity,
        target: AXElementInspector.Target,
        policy: SelectionPolicy,
        cursor: CursorClass,
        allowCopyFallback: Bool = true,
        requireCopyEvidence: Bool = true
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
                OpenSelectionLogging.log("coordinator: overlay gate — skipping copy strategies for \(bundleID); trying AX-only")
            } else {
                strategies = nonCopy
            }
        }

        for (index, strategy) in strategies.enumerated() {
            if index > 0 {
                let previous = strategies[index - 1]
                OpenSelectionLogging.log("coordinator: \(previous.rawValue) produced no text for \(bundleID); falling back to \(strategy.rawValue)")
            }
            if requireCopyEvidence {
                if let evidence = Self.copyEvidence(strategy, target: target, cursor: cursor) {
                    OpenSelectionLogging.log("coordinator: \(strategy.rawValue) permitted for \(bundleID); text-selection evidence=\(evidence)")
                } else {
                    OpenSelectionLogging.log("coordinator: skipping \(strategy.rawValue) for \(bundleID); no text-selection evidence (cursor=\(cursor.rawValue))")
                    continue
                }
            }
            if let result = Self.nonBlank(await run(strategy, app: app, target: target)) {
                if index > 0 {
                    OpenSelectionLogging.log("coordinator: fallback \(strategy.rawValue) succeeded for \(bundleID)")
                } else {
                    OpenSelectionLogging.log("coordinator: primary \(strategy.rawValue) succeeded for \(bundleID)")
                }
                return await enrichRichContent(
                    result,
                    strategy: strategy,
                    app: app,
                    target: target,
                    allowCopyFallback: allowCopyFallback
                )
            }
        }
        OpenSelectionLogging.log("coordinator: all strategies exhausted for \(bundleID); no selection")
        return nil
    }

    private func enrichRichContent(
        _ result: SelectionResult,
        strategy: SelectionStrategy,
        app: AppIdentity,
        target: AXElementInspector.Target,
        allowCopyFallback: Bool = true
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
        OpenSelectionLogging.log("coordinator: web/electron/rich-document selection; enriching via pasteboard rich capture")
        // Keep the capture when it carries anything the AX read cannot express: HTML, RTF,
        // multi-line text, or app-private pasteboard flavors (e.g. `com.apple.notes.richtext`).
        // A single-line capture with only flavors must still replace the flavorless AX result.
        guard let captured = Self.nonBlank(await run(.keyboardCopy, app: app, target: target)),
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
        target: AXElementInspector.Target
    ) async -> SelectionResult? {
        switch strategy {
        case .axTextControl:
            return AXTextControlStrategy.read(from: target)

        case .axWebArea:
            var snapshot: AXElementInspector.Target? = target
            var attempts = 0
            while attempts < configuration.webAreaSettleMaxRetries {
                if let snapshot, let result = AXWebAreaStrategy.read(from: snapshot) {
                    return result
                }
                attempts += 1
                if attempts < configuration.webAreaSettleMaxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(configuration.webAreaSettleInterval * 1_000_000_000))
                    if let element = snapshot?.webArea ?? snapshot?.focusedElement,
                       let result = AXWebAreaStrategy.pollFresh(from: element) {
                        return result
                    }
                    snapshot = await inspectWithWatchdog()
                }
            }
            return nil

        case .officeScript:
            return await runOfficeScript(for: app, target: target)

        case .browserScript:
            return nil

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
                return nil
            }
            guard let captured = await copyCapture(trigger) else { return nil }
            return SelectionResult(
                text: captured.text,
                bounds: target.bounds,
                html: captured.html,
                rtf: captured.rtf,
                flavors: captured.flavors,
                sourceApp: nil,
                strategy: strategy,
                isEditable: false
            )
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

    private func runOfficeScript(for app: AppIdentity, target: AXElementInspector.Target) async -> SelectionResult? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        guard let script = Self.officeScript(for: bundleID) else {
            OpenSelectionLogging.log("coordinator: office app recognised but no script template for \(bundleID)")
            return nil
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
            guard !trimmed.isEmpty, trimmed != "missing value" else { return nil }
            return SelectionResult(
                text: trimmed,
                bounds: target.bounds,
                strategy: .officeScript,
                isEditable: true
            )
        } catch is CancellationError {
            OpenSelectionLogging.log("coordinator: office script timed out after \(configuration.officeScriptTimeout)s for \(bundleID)")
            return nil
        } catch {
            OpenSelectionLogging.log("coordinator: office script failed for \(bundleID): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Watchdog AX Workers

    private func inspectWithWatchdog() async -> AXElementInspector.Target? {
        guard await Self.inspectGate.tryAcquire(limit: configuration.axMaxConcurrentInspects) else {
            OpenSelectionLogging.log("coordinator: inspect concurrency cap reached; skipping read")
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
                    OpenSelectionLogging.log("coordinator: AX inspect exceeded \(timeoutSeconds)s deadline; returning nil")
                }
            })

            Self.axInspectQueue.async {
                let target = inspect()
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
                    OpenSelectionLogging.log("coordinator: Edit ▸ Copy press exceeded \(timeout)s deadline; releasing inspect gate")
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
    static func copyEvidence(
        _ strategy: SelectionStrategy,
        target: AXElementInspector.Target,
        cursor: CursorClass
    ) -> String? {
        guard strategy == .keyboardCopy || strategy == .menuCopy else { return "not-a-copy-strategy" }
        if cursor == .beam { return "beam-cursor" }
        if let selected = target.selectedText, !selected.isEmpty { return "ax-selected-text" }
        if let markerText = target.selectedMarkerText, !markerText.isEmpty { return "ax-marker-text" }
        if let range = target.selectedTextRange, CFGetTypeID(range) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &cfRange), cfRange.length > 0 {
                return "ax-selected-text-range(len=\(cfRange.length))"
            }
        }
        if let role = target.role, textEvidenceRoles.contains(role) { return "ax-role:\(role)" }
        if let role = target.containedInRoles.first(where: textEvidenceRoles.contains) { return "ax-ancestor-role:\(role)" }
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

// OpenSelectionInspector.swift
// OpenSelection
//
// Diagnostic inspector inspecting active macOS targets, testing accessibility trees,
// and preflighting retrieval strategies.
import AppKit
import ApplicationServices
import Foundation

/// Primary diagnostic entry point for analyzing selection retrieval conditions.
public enum OpenSelectionInspector {

    private static let allowlistedAttributes: Set<String> = [
        "AXRole", "AXSubrole", "AXRoleDescription",
        "AXTitle", "AXValue", "AXDescription", "AXHelp",
        "AXParent", "AXChildren", "AXSelectedChildren",
        "AXVisibleChildren", "AXWindow", "AXTopLevelUIElement",
        "AXPosition", "AXSize", "AXEnabled", "AXFocused",
        "AXSelectedText", "AXSelectedTextRange", "AXNumberOfCharacters",
        "AXVisibleCharacterRange", "AXInsertionPointLineNumber",
        "AXSelectedTextMarkerRange", "AXStartTextMarker", "AXEndTextMarker",
        "AXLinkUIElements", "AXLoaded", "AXLayoutCount",
        "AXMain", "AXMinimized", "AXCloseButton", "AXZoomButton",
        "AXMinimizeButton", "AXToolbarButton", "AXFullScreenButton",
        "AXURL", "AXDOMIdentifier", "AXWebArea"
    ]

    /// Performs diagnostic inspection of the target application.
    public static func diagnose(
        target: InspectionTarget = .frontmost,
        options: InspectionOptions = .init()
    ) async -> TargetDiagnostics {
        if case .focusedAfter(let delay) = target, delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        let deadline = Date().addingTimeInterval(options.deadlineSeconds)

        let targetApp = resolveRunningApplication(target: target)
        let pid = targetApp?.processIdentifier ?? 0
        let bundleID = targetApp?.bundleIdentifier
        let liveCursor = await CursorClassifier.current

        let systemInfo = SystemInfo(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture(),
            isAXTrusted: AXIsProcessTrusted(),
            hostBundleID: Bundle.main.bundleIdentifier
        )

        var targetArch = currentArchitecture()
        var isRosetta = false
        if let targetApp {
            #if arch(arm64)
            if targetApp.executableArchitecture == NSBundleExecutableArchitectureX86_64 {
                targetArch = .x86_64
                isRosetta = true
            } else if targetApp.executableArchitecture == NSBundleExecutableArchitectureARM64 {
                targetArch = .arm64
            }
            #elseif arch(x86_64)
            if targetApp.executableArchitecture == NSBundleExecutableArchitectureX86_64 {
                targetArch = .x86_64
            }
            #endif
        }

        let targetSnapshot = TargetSnapshot(
            pid: pid,
            bundleID: bundleID,
            architecture: targetArch,
            isRosettaTranslated: isRosetta,
            framework: AppMatching.isBrowser(bundleID)
                ? (bundleID == "com.apple.Safari" ? .webkit : .chromium)
                : (AppMatching.isMultiProcess(bundleID) ? .electron : (AppMatching.isMicrosoftOffice(bundleID) ? .office : (AppMatching.isTerminal(bundleID) ? .terminal : .native))),
            cursor: cursorKind(from: liveCursor),
            windowBounds: nil
        )

        guard let targetApp, pid > 0 else {
            return TargetDiagnostics(
                system: systemInfo,
                target: targetSnapshot,
                strategyPreflight: [
                    StrategyPreflight(strategy: .axTextControl, viable: false, reason: "Target application not running or inaccessible"),
                    StrategyPreflight(strategy: .axWebArea, viable: false, reason: "Target application not running or inaccessible"),
                    StrategyPreflight(strategy: .officeScript, viable: false, reason: "Target application not running or inaccessible"),
                    StrategyPreflight(strategy: .menuCopy, viable: false, reason: "Target application not running or inaccessible"),
                    StrategyPreflight(strategy: .keyboardCopy, viable: false, reason: "Target application not running or inaccessible")
                ]
            )
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Float(min(options.deadlineSeconds, 1.0)))

        let capabilities = probeAXCapabilities(appElement)
        let focusChain = probeFocusChain(appElement: appElement, maxDepth: options.depth, deadline: deadline)
        let subtree = probeSubtree(appElement: appElement, maxDepth: options.depth, budget: options.nodeBudget, deadline: deadline)
        let menuProbe = probeMenuCopy(appElement: appElement, deadline: deadline)

        let preflights = evaluatePreflights(
            bundleID: bundleID,
            focusChain: focusChain,
            menuProbe: menuProbe,
            cursor: liveCursor
        )

        var liveRun: CascadeReport? = nil
        if options.allowIntrusiveProbes {
            // Activate targetApp if not already frontmost to prevent capturing another app
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                if #available(macOS 14.0, *) {
                    _ = targetApp.activate()
                } else {
                    _ = targetApp.activate(options: [.activateIgnoringOtherApps])
                }
                for _ in 0..<10 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                let trace = SelectionTrace.create(trigger: .programmatic)
                let coordinator = SelectionRetrievalCoordinator()
                let (res, _) = await coordinator.retrieveDetails(
                    for: AppIdentity(targetApp),
                    cursor: liveCursor,
                    trace: trace
                )
                liveRun = res?.diagnostics ?? trace.buildReport(outcome: .none)
            }
        }

        return TargetDiagnostics(
            system: systemInfo,
            target: targetSnapshot,
            accessibility: capabilities,
            focusChain: focusChain,
            subtree: subtree,
            strategyPreflight: preflights,
            menuCopy: menuProbe,
            liveRun: liveRun
        )
    }

    // MARK: - Internal Probing

    private static func resolveRunningApplication(target: InspectionTarget) -> NSRunningApplication? {
        switch target {
        case .frontmost, .focusedAfter:
            return NSWorkspace.shared.frontmostApplication
        case .pid(let pid):
            return NSRunningApplication(processIdentifier: pid)
        case .bundleID(let bundleID):
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
    }

    private static func currentArchitecture() -> TargetArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }

    private static func cursorKind(from cursor: CursorClass) -> CursorKind {
        switch cursor {
        case .beam: return .iBeam
        case .arrow: return .arrow
        case .pointingHand: return .pointingHand
        default: return .other
        }
    }

    private static func probeAXCapabilities(_ appElement: AXUIElement) -> AXCapabilities {
        var isManualSettable: DarwinBoolean = false
        let manualSettable = AXUIElementIsAttributeSettable(appElement, "AXManualAccessibility" as CFString, &isManualSettable) == .success && isManualSettable.boolValue
        var manualVal: AnyObject?
        let manualEnabled = AXUIElementCopyAttributeValue(appElement, "AXManualAccessibility" as CFString, &manualVal) == .success && (manualVal as? Bool == true)

        var isEnhancedSettable: DarwinBoolean = false
        let enhancedSettable = AXUIElementIsAttributeSettable(appElement, "AXEnhancedUserInterface" as CFString, &isEnhancedSettable) == .success && isEnhancedSettable.boolValue
        var enhancedVal: AnyObject?
        let enhancedEnabled = AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &enhancedVal) == .success && (enhancedVal as? Bool == true)

        return AXCapabilities(
            isManualAccessibilitySettable: manualSettable,
            isManualAccessibilityEnabled: manualEnabled,
            isEnhancedUserInterfaceSettable: enhancedSettable,
            isEnhancedUserInterfaceEnabled: enhancedEnabled
        )
    }

    private static func probeFocusChain(
        appElement: AXUIElement,
        maxDepth: Int,
        deadline: Date
    ) -> [ElementSnapshot] {
        guard Date() < deadline else { return [] }

        var currentElementRef: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &currentElementRef)
        guard focusErr == .success, let currentElement = currentElementRef, CFGetTypeID(currentElement) == AXUIElementGetTypeID() else {
            return []
        }

        var chain: [ElementSnapshot] = []
        var nextElem: AXUIElement? = (currentElement as! AXUIElement)
        var depth = 0

        while let elem = nextElem, depth < maxDepth, Date() < deadline {
            let snapshot = snapshotElement(elem, deadline: deadline)
            chain.append(snapshot)
            depth += 1

            var parentRef: AnyObject?
            if AXUIElementCopyAttributeValue(elem, kAXParentAttribute as CFString, &parentRef) == .success,
               let p = parentRef, CFGetTypeID(p) == AXUIElementGetTypeID() {
                nextElem = (p as! AXUIElement)
            } else {
                nextElem = nil
            }
        }

        return chain
    }

    private static func probeSubtree(
        appElement: AXUIElement,
        maxDepth: Int,
        budget: Int,
        deadline: Date
    ) -> [ElementSnapshot] {
        guard budget > 0, maxDepth > 0, Date() < deadline else { return [] }

        var results: [ElementSnapshot] = []
        var queue: [(element: AXUIElement, depth: Int)] = []

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.02 else { return [] }
        AXUIElementSetMessagingTimeout(appElement, Float(min(0.2, remaining)))

        var childrenRef: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &childrenRef) == .success,
           let windows = childrenRef as? [AXUIElement], !windows.isEmpty {
            for win in windows.prefix(budget) {
                queue.append((win, 1))
            }
        } else if AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let kids = childrenRef as? [AXUIElement] {
            for kid in kids.prefix(budget) {
                queue.append((kid, 1))
            }
        }

        var head = 0
        while head < queue.count && results.count < budget && Date() < deadline {
            let (elem, depth) = queue[head]
            head += 1

            let snap = snapshotElement(elem, deadline: deadline)
            results.append(snap)

            if depth < maxDepth && results.count + (queue.count - head) < budget && Date() < deadline {
                let rem = deadline.timeIntervalSinceNow
                if rem > 0.02 {
                    AXUIElementSetMessagingTimeout(elem, Float(min(0.2, rem)))
                    var kidRef: AnyObject?
                    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &kidRef) == .success,
                       let kids = kidRef as? [AXUIElement] {
                        let allowed = budget - (results.count + (queue.count - head))
                        for kid in kids.prefix(max(0, allowed)) {
                            queue.append((kid, depth + 1))
                        }
                    }
                }
            }
        }

        return results
    }

    private static func snapshotElement(_ elem: AXUIElement, deadline: Date) -> ElementSnapshot {
        guard Date() < deadline else {
            return ElementSnapshot(
                selectedText: .error(.cannotComplete),
                selectedRange: .error(.cannotComplete),
                selectedRangeBounds: .notApplicable
            )
        }

        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0.01 {
            AXUIElementSetMessagingTimeout(elem, Float(min(0.2, remaining)))
        }

        var roleVal: AnyObject?
        _ = AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleVal)
        let role = roleVal as? String

        var subroleVal: AnyObject?
        _ = AXUIElementCopyAttributeValue(elem, kAXSubroleAttribute as CFString, &subroleVal)
        let subrole = subroleVal as? String

        var enabledVal: AnyObject?
        _ = AXUIElementCopyAttributeValue(elem, kAXEnabledAttribute as CFString, &enabledVal)
        let enabled = enabledVal as? Bool

        var focusedVal: AnyObject?
        _ = AXUIElementCopyAttributeValue(elem, kAXFocusedAttribute as CFString, &focusedVal)
        let focused = focusedVal as? Bool

        var attrNamesRef: CFArray?
        var sanitizedAttrs: [String] = []
        if Date() < deadline, AXUIElementCopyAttributeNames(elem, &attrNamesRef) == .success, let names = attrNamesRef as? [String] {
            var customCount = 0
            for name in names {
                if allowlistedAttributes.contains(name) {
                    sanitizedAttrs.append(name)
                } else {
                    customCount += 1
                }
            }
            if customCount > 0 {
                sanitizedAttrs.append("custom(\(customCount))")
            }
        }

        var paramNamesRef: CFArray?
        var sanitizedParams: [String] = []
        if Date() < deadline, AXUIElementCopyParameterizedAttributeNames(elem, &paramNamesRef) == .success, let pNames = paramNamesRef as? [String] {
            sanitizedParams = pNames
        }

        var actionsRef: CFArray?
        var actions: [String] = []
        if Date() < deadline, AXUIElementCopyActionNames(elem, &actionsRef) == .success, let aNames = actionsRef as? [String] {
            actions = aNames
        }

        // Selected Text Probe
        let textProbe: ProbeResult
        if Date() < deadline {
            var textVal: AnyObject?
            let textErr = AXUIElementCopyAttributeValue(elem, kAXSelectedTextAttribute as CFString, &textVal)
            if textErr == .success {
                let str = textVal as? String ?? ""
                textProbe = .presence(str.isEmpty ? .empty : .nonEmpty)
            } else {
                textProbe = .error(AXErrorCode(axError: textErr))
            }
        } else {
            textProbe = .error(.cannotComplete)
        }

        // Selected Range Probe
        let rangeProbe: ProbeResult
        if Date() < deadline {
            var rangeVal: AnyObject?
            let rangeErr = AXUIElementCopyAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, &rangeVal)
            if rangeErr == .success {
                if let r = rangeVal, CFGetTypeID(r) == AXValueGetTypeID() {
                    var cfRange = CFRange()
                    if AXValueGetValue(r as! AXValue, .cfRange, &cfRange) {
                        rangeProbe = .presence(cfRange.length > 0 ? .nonEmpty : .empty)
                    } else {
                        rangeProbe = .presence(.empty)
                    }
                } else {
                    rangeProbe = .presence(.empty)
                }
            } else {
                rangeProbe = .error(AXErrorCode(axError: rangeErr))
            }
        } else {
            rangeProbe = .error(.cannotComplete)
        }

        // Marker Range Support Probe
        let markerProbe: ProbeResult?
        if Date() < deadline {
            var markerVal: AnyObject?
            let markerErr = AXUIElementCopyAttributeValue(elem, "AXSelectedTextMarkerRange" as CFString, &markerVal)
            if markerErr == .success {
                markerProbe = .presence(markerVal != nil ? .nonEmpty : .empty)
            } else if markerErr == .attributeUnsupported {
                markerProbe = .notApplicable
            } else {
                markerProbe = .error(AXErrorCode(axError: markerErr))
            }
        } else {
            markerProbe = nil
        }

        var childrenCount: CFIndex = 0
        let countErr = (Date() < deadline) ? AXUIElementGetAttributeValueCount(elem, kAXChildrenAttribute as CFString, &childrenCount) : .cannotComplete

        return ElementSnapshot(
            role: role,
            subrole: subrole,
            enabled: enabled,
            focused: focused,
            supportedAttributes: sanitizedAttrs,
            supportedParameterized: sanitizedParams,
            actions: actions,
            selectedText: textProbe,
            selectedRange: rangeProbe,
            selectedRangeBounds: .notApplicable,
            markerRangeSupport: markerProbe,
            childrenCount: countErr == .success ? Int(childrenCount) : nil
        )
    }

    private static func probeMenuCopy(appElement: AXUIElement, deadline: Date) -> MenuCopyProbe? {
        let outcome = AXMenuNavigator.probeMenuItem(
            .copy,
            in: appElement,
            matchingShortcutOnly: false,
            timeout: 0.5,
            deadline: deadline
        )
        switch outcome {
        case .found(let element, let isEnabled):
            var cmdCharRef: AnyObject?
            _ = AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &cmdCharRef)
            let cmdChar = (cmdCharRef as? String)?.uppercased()

            var cmdModsRef: AnyObject?
            _ = AXUIElementCopyAttributeValue(element, kAXMenuItemCmdModifiersAttribute as CFString, &cmdModsRef)
            let cmdMods = (cmdModsRef as? NSNumber)?.uintValue

            let isCmdC = cmdChar == "C" && (cmdMods == nil || cmdMods == 0)

            var isEditMenu = false
            var walker: AXUIElement? = element
            var depth = 0
            while let current = walker, depth < 5 {
                var parentRef: AnyObject?
                if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                   let p = parentRef, CFGetTypeID(p) == AXUIElementGetTypeID() {
                    let parent = p as! AXUIElement
                    var titleRef: AnyObject?
                    _ = AXUIElementCopyAttributeValue(parent, kAXTitleAttribute as CFString, &titleRef)
                    if let title = titleRef as? String {
                        let lower = title.lowercased()
                        if lower == "edit" || lower == "编辑" || lower == "編輯" || lower == "編集" || lower == "édition" || lower == "edition" || lower == "bearbeiten" {
                            isEditMenu = true
                            break
                        }
                    }
                    walker = parent
                    depth += 1
                } else {
                    break
                }
            }

            return MenuCopyProbe(
                editMenuFound: isEditMenu,
                copyItemPresent: true,
                copyItemEnabled: isEnabled == true,
                shortcutMatchesCommandC: isCmdC
            )
        case .notFound:
            return MenuCopyProbe(
                editMenuFound: true,
                copyItemPresent: false,
                copyItemEnabled: false,
                shortcutMatchesCommandC: false
            )
        case .noMenuBar, .timedOut:
            return MenuCopyProbe(
                editMenuFound: false,
                copyItemPresent: false,
                copyItemEnabled: false,
                shortcutMatchesCommandC: false
            )
        }
    }

    private static func evaluatePreflights(
        bundleID: String?,
        focusChain: [ElementSnapshot],
        menuProbe: MenuCopyProbe?,
        cursor: CursorClass
    ) -> [StrategyPreflight] {
        var results: [StrategyPreflight] = []

        let focusedElem = focusChain.first
        let role = focusedElem?.role ?? "unknown"

        // 1. AX Text Control
        let textControlRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        if textControlRoles.contains(role) {
            results.append(StrategyPreflight(
                strategy: .axTextControl,
                viable: true,
                reason: "Focused element '\(role)' is a standard accessible text control."
            ))
        } else if case .presence(let p) = focusedElem?.selectedText, p == .nonEmpty {
            results.append(StrategyPreflight(
                strategy: .axTextControl,
                viable: true,
                reason: "Focused element exposes non-empty AXSelectedText."
            ))
        } else {
            results.append(StrategyPreflight(
                strategy: .axTextControl,
                viable: false,
                reason: "Focused element '\(role)' does not expose text control attributes or selection."
            ))
        }

        // 2. AX Web Area
        let hasWebArea = focusChain.contains { $0.role == "AXWebArea" }
        if hasWebArea {
            results.append(StrategyPreflight(
                strategy: .axWebArea,
                viable: true,
                reason: "Focus chain contains an AXWebArea ancestor."
            ))
        } else {
            results.append(StrategyPreflight(
                strategy: .axWebArea,
                viable: false,
                reason: "No AXWebArea ancestor found in focus chain."
            ))
        }

        // 3. Office Script
        if AppMatching.isMicrosoftOffice(bundleID) {
            results.append(StrategyPreflight(
                strategy: .officeScript,
                viable: true,
                reason: "Target application '\(bundleID ?? "")' matches supported Office AppleScript suite."
            ))
        } else {
            results.append(StrategyPreflight(
                strategy: .officeScript,
                viable: false,
                reason: "Target application is not a recognized Microsoft Office document host."
            ))
        }

        // 4. Menu Copy
        if let menu = menuProbe, menu.copyItemPresent, menu.copyItemEnabled {
            results.append(StrategyPreflight(
                strategy: .menuCopy,
                viable: true,
                reason: "Edit -> Copy menu item is present and enabled."
            ))
        } else if let menu = menuProbe, menu.copyItemPresent {
            results.append(StrategyPreflight(
                strategy: .menuCopy,
                viable: false,
                reason: "Edit -> Copy menu item is present but currently disabled."
            ))
        } else {
            results.append(StrategyPreflight(
                strategy: .menuCopy,
                viable: false,
                reason: "Edit -> Copy menu item was not located."
            ))
        }

        // 5. Keyboard Copy
        let isBrowser = AppMatching.isBrowser(bundleID)
        let hasTextEvidence = textControlRoles.contains(role)
            || (focusedElem?.selectedText == .presence(.nonEmpty))
            || (focusedElem?.selectedRange == .presence(.nonEmpty))
            || (cursor == .beam)
            || AppMatching.isCopyFallbackApp(bundleID)
            || (isBrowser && (cursor == .unknown || cursor == .pointingHand || cursor == .beam))
            || !AppMatching.isStrictlyNative(bundleID ?? "")

        if hasTextEvidence {
            results.append(StrategyPreflight(
                strategy: .keyboardCopy,
                viable: true,
                reason: "Target context satisfies the copy-evidence safety gate."
            ))
        } else {
            results.append(StrategyPreflight(
                strategy: .keyboardCopy,
                viable: false,
                reason: "No positive text evidence or cursor/browser waiver found in accessibility snapshot to justify ⌘C."
            ))
        }

        return results
    }
}

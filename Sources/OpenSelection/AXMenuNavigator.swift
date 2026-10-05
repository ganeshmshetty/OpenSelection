// AXMenuNavigator.swift
// OpenSelection
//
// Robust, localization-agnostic navigation of the frontmost application's menu bar through the raw
// Accessibility API. Menu items are matched by action identifier (`copy:`/`paste:`), by their
// Command-key equivalent (⌘C/⌘V), or by localized titles.
import ApplicationServices
import Foundation

public enum MenuProbeOutcome: @unchecked Sendable {
    case found(AXUIElement, isEnabled: Bool?)
    case notFound, noMenuBar, timedOut
}

public enum EnabledRead: Sendable, Equatable {
    case value(Bool), invalidElement, failed
}

public struct AXMenuNavigator {
    /// The system menu commands to locate and press.
    public enum MenuCommand: CaseIterable, Sendable {
        case copy
        case paste

        /// The AX action-selector identifier for this command (e.g. `copy:`).
        public var identifier: String {
            switch self {
            case .copy: return "copy:"
            case .paste: return "paste:"
            }
        }

        /// The expected Command-key equivalent character for this command.
        public var cmdChar: String {
            switch self {
            case .copy: return "C"
            case .paste: return "V"
            }
        }

        /// Localized menu titles for this command, lowercased for case-insensitive matching.
        public var titles: Set<String> {
            switch self {
            case .copy: return AXMenuNavigator.copyTitles
            case .paste: return AXMenuNavigator.pasteTitles
            }
        }
    }

    /// Traverses the application menu bar to locate the requested menu command.
    /// Traversal is deadline-bounded and prioritizes inspecting the Edit menu first.
    /// `matchingShortcutOnly` ignores titles/selectors when authorizing a synthetic shortcut.
    public static func findMenuItem(
        _ command: MenuCommand,
        in app: AXUIElement?,
        requireEnabled: Bool = false,
        matchingShortcutOnly: Bool = false,
        timeout: TimeInterval = 0.5,
        deadline: Date? = nil
    ) -> AXUIElement? {
        let budget = deadline.map(MenuDeadline.init(wall:))
        guard budget?.isExpired != true, let app else {
            return nil
        }

        AXUIElementSetMessagingTimeout(app, Float(timeout))

        guard let menuBar = queryElementAttribute(kAXMenuBarAttribute as CFString, of: app, timeout: timeout, budget: budget),
              let topMenus: [AXUIElement] = queryAttribute(kAXChildrenAttribute as CFString, of: menuBar, timeout: timeout, budget: budget) else {
            return nil
        }

        // Edit menu is standardly located at index 3 (4th item). Check it first before scanning others.
        let editMenuIndex = 3
        if topMenus.indices.contains(editMenuIndex),
           let hit = searchMenuSubtree(
               command: command,
               root: topMenus[editMenuIndex],
               requireEnabled: requireEnabled,
               matchingShortcutOnly: matchingShortcutOnly,
               timeout: timeout,
               budget: budget
           ) {
            return hit
        }

        for (index, menu) in topMenus.enumerated() where index != editMenuIndex {
            guard budget?.isExpired != true else { return nil }
            if let hit = searchMenuSubtree(
                command: command,
                root: menu,
                requireEnabled: requireEnabled,
                matchingShortcutOnly: matchingShortcutOnly,
                timeout: timeout,
                budget: budget
            ) {
                return hit
            }
        }

        return nil
    }

    /// Locates and triggers the requested menu command if found and enabled.
    @discardableResult
    public static func press(
        _ command: MenuCommand,
        in app: AXUIElement?,
        timeout: TimeInterval = 0.5,
        deadline: Date? = nil
    ) -> Bool {
        guard let item = findMenuItem(command, in: app, requireEnabled: true, timeout: timeout, deadline: deadline) else {
            return false
        }
        AXUIElementSetMessagingTimeout(item, Float(timeout))
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        return true
    }

    /// Whether the supplied title/cmd-char/modifiers describe the requested menu command.
    public static func matches(
        _ command: MenuCommand,
        title: String?,
        identifier: String?,
        cmdChar: String?,
        cmdModifiers: UInt?,
        matchingShortcutOnly: Bool = false
    ) -> Bool {
        if matchingShortcutOnly {
            // AX menu modifiers imply Command: 0 means Command alone.
            return cmdChar?.caseInsensitiveCompare(command.cmdChar) == .orderedSame && cmdModifiers == 0
        }
        if let identifier, identifier == command.identifier { return true }

        if let cmdChar, cmdChar.caseInsensitiveCompare(command.cmdChar) == .orderedSame,
           let modifiers = cmdModifiers {
            return modifiers == 0
        }

        guard let title else { return false }
        return command.titles.contains(title.localizedLowercase)
    }

    // MARK: - Tree walking

    private static let maxTraversalDepth = 8

    /// Monotonic traversal deadline, built once at each public entry point.
    ///
    /// Wall-clock `Date` deadlines drift under NTP steps and sleep/wake cycles: a backward
    /// adjustment mid-walk would extend a stalled worker past its watchdog (and hold its
    /// gate permit with it). Anchoring the remaining budget to a monotonic clock at entry —
    /// like the inspect budget — closes that. The public API keeps accepting wall-clock
    /// `Date`s; only the traversal internals run on the token.
    private struct MenuDeadline: Sendable {
        private let end: ContinuousClock.Instant

        init(wall: Date) {
            let interval = wall.timeIntervalSinceNow
            let wholeSeconds = Int64(floor(interval))
            let attoseconds = Int64((interval - Double(wholeSeconds)) * 1_000_000_000_000_000_000)
            self.end = ContinuousClock.now.advanced(
                by: Duration(secondsComponent: wholeSeconds, attosecondsComponent: attoseconds)
            )
        }

        var isExpired: Bool { ContinuousClock.now >= end }

        /// Per-call messaging timeout capped to the remaining budget, or `nil` when no
        /// further IPC may be issued (expired deadline).
        func timeout(capped timeout: TimeInterval) -> TimeInterval? {
            let remaining = end - ContinuousClock.now
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1_000_000_000_000_000_000
            guard seconds > 0 else { return nil }
            return min(timeout, max(0.02, seconds))
        }
    }

    /// Recursively traverses a menu hierarchy down to `maxTraversalDepth`, checking elements against `command`.
    private static func searchMenuSubtree(
        command: MenuCommand,
        root: AXUIElement,
        requireEnabled: Bool,
        matchingShortcutOnly: Bool,
        currentDepth: Int = 0,
        timeout: TimeInterval,
        budget: MenuDeadline?
    ) -> AXUIElement? {
        guard budget?.isExpired != true, currentDepth <= maxTraversalDepth else {
            return nil
        }

        if elementMatches(command: command, element: root, requireEnabled: requireEnabled, matchingShortcutOnly: matchingShortcutOnly, timeout: timeout, budget: budget) {
            return root
        }

        let childElements: [AXUIElement]? = queryAttribute(kAXChildrenAttribute as CFString, of: root, timeout: timeout, budget: budget)
        for child in childElements ?? [] {
            guard budget?.isExpired != true else { return nil }
            if let hit = searchMenuSubtree(
                command: command,
                root: child,
                requireEnabled: requireEnabled,
                matchingShortcutOnly: matchingShortcutOnly,
                currentDepth: currentDepth + 1,
                timeout: timeout,
                budget: budget
            ) {
                return hit
            }
        }

        return nil
    }

    /// Evaluates if an accessibility element matches the requested menu command and enablement criteria.
    private static func elementMatches(
        command: MenuCommand,
        element: AXUIElement,
        requireEnabled: Bool,
        matchingShortcutOnly: Bool,
        timeout: TimeInterval,
        budget: MenuDeadline?
    ) -> Bool {
        guard budget?.isExpired != true else { return false }

        let title: String? = queryAttribute(kAXTitleAttribute as CFString, of: element, timeout: timeout, budget: budget)
        let identifier: String? = queryAttribute(kAXIdentifierAttribute as CFString, of: element, timeout: timeout, budget: budget)
        let cmdChar: String? = queryAttribute(kAXMenuItemCmdCharAttribute as CFString, of: element, timeout: timeout, budget: budget)
        let rawModifiers: NSNumber? = queryAttribute(kAXMenuItemCmdModifiersAttribute as CFString, of: element, timeout: timeout, budget: budget)

        guard matches(
            command,
            title: title,
            identifier: identifier,
            cmdChar: cmdChar,
            cmdModifiers: rawModifiers?.uintValue,
            matchingShortcutOnly: matchingShortcutOnly
        ) else {
            return false
        }

        if requireEnabled {
            let isEnabled: Bool? = queryAttribute(kAXEnabledAttribute as CFString, of: element, timeout: timeout, budget: budget)
            guard isEnabled == true else { return false }
        }

        return true
    }

    // MARK: - AX attribute helpers

    /// Queries a typed accessibility attribute with per-call messaging timeout and aggregate deadline checking.
    private static func queryAttribute<T>(
        _ attribute: CFString,
        of element: AXUIElement,
        timeout: TimeInterval,
        budget: MenuDeadline?
    ) -> T? {
        queryRawAttribute(attribute, of: element, timeout: timeout, budget: budget) as? T
    }

    /// Queries an accessibility attribute returning an `AXUIElement` if present and valid.
    private static func queryElementAttribute(
        _ attribute: CFString,
        of element: AXUIElement,
        timeout: TimeInterval,
        budget: MenuDeadline?
    ) -> AXUIElement? {
        guard let raw = queryRawAttribute(attribute, of: element, timeout: timeout, budget: budget),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    /// Fetches an untyped CoreFoundation attribute value after verifying the aggregate deadline and setting the messaging timeout.
    ///
    /// When a budget is present the per-call messaging timeout is capped to the remaining
    /// budget: a menu-tree walk over a stalled app must abort near the deadline instead of
    /// blocking a full `timeout` on every one of its (potentially hundreds of) sequential
    /// IPC calls and parking its worker — and its concurrency-gate permit — far past the
    /// watchdog. On a responsive app the remaining budget always exceeds `timeout`, so this
    /// is a no-op there. `nil` budget means uncapped legacy behavior.
    private static func queryRawAttribute(
        _ attribute: CFString,
        of element: AXUIElement,
        timeout: TimeInterval,
        budget: MenuDeadline?
    ) -> CFTypeRef? {
        let effectiveTimeout: TimeInterval
        if let budget {
            guard let capped = budget.timeout(capped: timeout) else { return nil }
            effectiveTimeout = capped
        } else {
            effectiveTimeout = timeout
        }
        AXUIElementSetMessagingTimeout(element, Float(effectiveTimeout))
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else {
            return nil
        }
        return valueRef
    }

    // MARK: - Probing & Snapshotting

    nonisolated(unsafe) private static let snapshotAttributes: [CFString] = [
        kAXTitleAttribute as CFString,
        kAXIdentifierAttribute as CFString,
        kAXMenuItemCmdCharAttribute as CFString,
        kAXMenuItemCmdModifiersAttribute as CFString,
        kAXEnabledAttribute as CFString,
    ]

    private static func snapshot(
        of element: AXUIElement,
        timeout: TimeInterval,
        budget: MenuDeadline
    ) -> (title: String?, id: String?, cmdChar: String?, mods: UInt?, enabled: Bool?)? {
        guard let effectiveTimeout = budget.timeout(capped: timeout) else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(effectiveTimeout))
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            snapshotAttributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &out
        ) == .success,
        let v = out as? [Any],
        v.count == snapshotAttributes.count else { return nil }

        let enabled: Bool?
        if let b = v[4] as? Bool {
            enabled = b
        } else if let num = v[4] as? NSNumber {
            enabled = num.boolValue
        } else {
            enabled = nil
        }

        return (
            v[0] as? String,
            v[1] as? String,
            v[2] as? String,
            (v[3] as? NSNumber)?.uintValue,
            enabled
        )
    }

    public static func probeMenuItem(
        _ command: MenuCommand,
        in app: AXUIElement,
        matchingShortcutOnly: Bool,
        timeout: TimeInterval,
        deadline: Date
    ) -> MenuProbeOutcome {
        let budget = MenuDeadline(wall: deadline)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        guard let menuBar = queryElementAttribute(kAXMenuBarAttribute as CFString, of: app, timeout: timeout, budget: budget),
              let top: [AXUIElement] = queryAttribute(kAXChildrenAttribute as CFString, of: menuBar, timeout: timeout, budget: budget)
        else { return budget.isExpired ? .timedOut : .noMenuBar }

        let editIndex = 3
        let order = top.indices.filter { $0 == editIndex } + top.indices.filter { $0 != editIndex }
        for i in order {
            if budget.isExpired { return .timedOut }
            if let hit = probeSubtree(command, top[i], matchingShortcutOnly, 0, timeout, budget) {
                return .found(hit.0, isEnabled: hit.1)
            }
        }
        return budget.isExpired ? .timedOut : .notFound
    }

    private static func probeSubtree(
        _ command: MenuCommand,
        _ root: AXUIElement,
        _ shortcutOnly: Bool,
        _ depth: Int,
        _ timeout: TimeInterval,
        _ budget: MenuDeadline
    ) -> (AXUIElement, Bool?)? {
        guard !budget.isExpired, depth <= maxTraversalDepth else { return nil }
        if let s = snapshot(of: root, timeout: timeout, budget: budget),
           matches(command, title: s.title, identifier: s.id, cmdChar: s.cmdChar,
                   cmdModifiers: s.mods, matchingShortcutOnly: shortcutOnly) {
            return (root, s.enabled)
        }
        let kids: [AXUIElement]? = queryAttribute(kAXChildrenAttribute as CFString, of: root, timeout: timeout, budget: budget)
        for kid in kids ?? [] {
            if let hit = probeSubtree(command, kid, shortcutOnly, depth + 1, timeout, budget) { return hit }
        }
        return nil
    }

    /// Warm path: one IPC.
    public static func readEnabled(of element: AXUIElement, timeout: TimeInterval) -> EnabledRead {
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &ref) {
        case .success:
            if let b = ref as? Bool {
                return .value(b)
            } else if let num = ref as? NSNumber {
                return .value(num.boolValue)
            } else {
                return .failed
            }
        case .invalidUIElement:
            return .invalidElement
        default:
            return .failed
        }
    }

    // MARK: - Localized titles

    public static let copyTitles: Set<String> = [
        "copy",  // English
        "拷贝", "复制",  // Simplified Chinese
        "拷貝", "複製",  // Traditional Chinese
        "コピー",  // Japanese
        "복사",  // Korean
        "copier",  // French
        "copiar",  // Spanish, Portuguese
        "copia",  // Italian
        "kopieren",  // German
        "копировать",  // Russian
        "kopiëren",  // Dutch
        "kopiér",  // Danish
        "kopiera",  // Swedish
        "kopioi",  // Finnish
        "αντιγραφή",  // Greek
        "kopyala",  // Turkish
        "salin",  // Indonesian
        "sao chép",  // Vietnamese
        "คัดลอก",  // Thai
        "копіювати",  // Ukrainian
        "kopiuj",  // Polish
        "másolás",  // Hungarian
        "kopírovat",  // Czech
        "kopírovať",  // Slovak
        "kopiraj",  // Croatian, Serbian (Latin)
        "копирај",  // Serbian (Cyrillic)
        "копиране",  // Bulgarian
        "kopēt",  // Latvian
        "kopijuoti",  // Lithuanian
        "copiază",  // Romanian
        "העתק",  // Hebrew
        "نسخ",  // Arabic
        "کپی",  // Persian
    ]

    public static let pasteTitles: Set<String> = [
        "paste", "paste and match style",  // English
        "粘贴", "贴上",  // Simplified Chinese
        "貼上", "粘貼",  // Traditional Chinese
        "ペースト",  // Japanese
        "붙여넣기",  // Korean
        "coller", "coller et assortir le style",  // French
        "pegar", "pegar y combinar estilo",  // Spanish, Portuguese
        "incolla",  // Italian
        "einfügen", "einfügen und stil anpassen",  // German
        "вставить",  // Russian
        "plakken", "plakken en stijl aanpassen",  // Dutch
        "indsæt",  // Danish
        "klistra", "klistra in",  // Swedish
        "liitä",  // Finnish
        "επικόλληση",  // Greek
        "yapıştır",  // Turkish
        "tempel",  // Indonesian
        "dán",  // Vietnamese
        "วาง",  // Thai
        "вставити",  // Ukrainian
        "wklej",  // Polish
        "beillesztés",  // Hungarian
        "vložit",  // Czech
        "vložiť",  // Slovak
        "umetni",  // Croatian, Serbian (Latin)
        "уметни",  // Serbian (Cyrillic)
        "поставяне",  // Bulgarian
        "ielīmēt",  // Latvian
        "įklijuoti",  // Lithuanian
        "lipește",  // Romanian
        "colar", "colar e combinar estilo",  // Portuguese (BR)
        "lim inn",  // Norwegian
        "הדבק",  // Hebrew
        "لصق",  // Arabic
        "چسباندن",  // Persian
        "貼り付け",  // Japanese (alt)
    ]
}

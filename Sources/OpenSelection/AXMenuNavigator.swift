// AXMenuNavigator.swift
// OpenSelection
//
// Robust, localization-agnostic navigation of the frontmost application's menu bar through the raw
// Accessibility API. Menu items are matched by action identifier (`copy:`/`paste:`), by their
// Command-key equivalent (⌘C/⌘V), or by localized titles.
import ApplicationServices
import Foundation

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
    public static func findMenuItem(
        _ command: MenuCommand,
        in app: AXUIElement?,
        requireEnabled: Bool = false,
        timeout: TimeInterval = 0.5,
        deadline: Date? = nil
    ) -> AXUIElement? {
        guard !isDeadlineExpired(deadline), let app else {
            return nil
        }

        AXUIElementSetMessagingTimeout(app, Float(timeout))

        guard let menuBar = queryElementAttribute(kAXMenuBarAttribute as CFString, of: app, timeout: timeout, deadline: deadline),
              let topMenus: [AXUIElement] = queryAttribute(kAXChildrenAttribute as CFString, of: menuBar, timeout: timeout, deadline: deadline) else {
            return nil
        }

        // Edit menu is standardly located at index 3 (4th item). Check it first before scanning others.
        let editMenuIndex = 3
        if topMenus.indices.contains(editMenuIndex),
           let hit = searchMenuSubtree(
               command: command,
               root: topMenus[editMenuIndex],
               requireEnabled: requireEnabled,
               timeout: timeout,
               deadline: deadline
           ) {
            return hit
        }

        for (index, menu) in topMenus.enumerated() where index != editMenuIndex {
            guard !isDeadlineExpired(deadline) else { return nil }
            if let hit = searchMenuSubtree(
                command: command,
                root: menu,
                requireEnabled: requireEnabled,
                timeout: timeout,
                deadline: deadline
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
        cmdModifiers: UInt?
    ) -> Bool {
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

    @inline(__always)
    private static func isDeadlineExpired(_ deadline: Date?) -> Bool {
        guard let deadline else { return false }
        return Date() >= deadline
    }

    /// Recursively traverses a menu hierarchy down to `maxTraversalDepth`, checking elements against `command`.
    private static func searchMenuSubtree(
        command: MenuCommand,
        root: AXUIElement,
        requireEnabled: Bool,
        currentDepth: Int = 0,
        timeout: TimeInterval,
        deadline: Date?
    ) -> AXUIElement? {
        guard !isDeadlineExpired(deadline), currentDepth <= maxTraversalDepth else {
            return nil
        }

        if elementMatches(command: command, element: root, requireEnabled: requireEnabled, timeout: timeout, deadline: deadline) {
            return root
        }

        let childElements: [AXUIElement]? = queryAttribute(kAXChildrenAttribute as CFString, of: root, timeout: timeout, deadline: deadline)
        for child in childElements ?? [] {
            guard !isDeadlineExpired(deadline) else { return nil }
            if let hit = searchMenuSubtree(
                command: command,
                root: child,
                requireEnabled: requireEnabled,
                currentDepth: currentDepth + 1,
                timeout: timeout,
                deadline: deadline
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
        timeout: TimeInterval,
        deadline: Date?
    ) -> Bool {
        guard !isDeadlineExpired(deadline) else { return false }

        let title: String? = queryAttribute(kAXTitleAttribute as CFString, of: element, timeout: timeout, deadline: deadline)
        let identifier: String? = queryAttribute(kAXIdentifierAttribute as CFString, of: element, timeout: timeout, deadline: deadline)
        let cmdChar: String? = queryAttribute(kAXMenuItemCmdCharAttribute as CFString, of: element, timeout: timeout, deadline: deadline)
        let rawModifiers: NSNumber? = queryAttribute(kAXMenuItemCmdModifiersAttribute as CFString, of: element, timeout: timeout, deadline: deadline)

        guard matches(
            command,
            title: title,
            identifier: identifier,
            cmdChar: cmdChar,
            cmdModifiers: rawModifiers?.uintValue
        ) else {
            return false
        }

        if requireEnabled {
            let isEnabled: Bool? = queryAttribute(kAXEnabledAttribute as CFString, of: element, timeout: timeout, deadline: deadline)
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
        deadline: Date?
    ) -> T? {
        queryRawAttribute(attribute, of: element, timeout: timeout, deadline: deadline) as? T
    }

    /// Queries an accessibility attribute returning an `AXUIElement` if present and valid.
    private static func queryElementAttribute(
        _ attribute: CFString,
        of element: AXUIElement,
        timeout: TimeInterval,
        deadline: Date?
    ) -> AXUIElement? {
        guard let raw = queryRawAttribute(attribute, of: element, timeout: timeout, deadline: deadline),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    /// Fetches an untyped CoreFoundation attribute value after verifying the aggregate deadline and setting the messaging timeout.
    private static func queryRawAttribute(
        _ attribute: CFString,
        of element: AXUIElement,
        timeout: TimeInterval,
        deadline: Date?
    ) -> CFTypeRef? {
        guard !isDeadlineExpired(deadline) else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success else {
            return nil
        }
        return valueRef
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

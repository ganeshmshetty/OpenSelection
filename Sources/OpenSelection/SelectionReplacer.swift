// SelectionReplacer.swift
// OpenSelection
//
// Replaces selection in an active application using direct AX text attribute
// mutation when editable, or non-destructive synthetic ⌘V pasteboard delivery.
import AppKit
import ApplicationServices
import Foundation

public enum OpenSelectionError: Error, LocalizedError, Sendable, Equatable {
    case targetApplicationUnavailable
    case replacementFailed(String)

    public var errorDescription: String? {
        switch self {
        case .targetApplicationUnavailable:
            return "Target application is unavailable or not running."
        case .replacementFailed(let reason):
            return "Failed to replace selection: \(reason)"
        }
    }
}

@MainActor
public struct SelectionReplacer {
    public typealias FocusedElementProvider = @Sendable (NSRunningApplication) -> AXUIElement?
    public typealias DirectAXReplacer = @MainActor @Sendable (AXUIElement, String) -> Bool
    public typealias KeyPoster = @MainActor @Sendable (CGKeyCode, CGEventFlags) -> Void
    public typealias AppActivator = @MainActor @Sendable (NSRunningApplication) -> Void

    public let configuration: SelectionConfiguration
    public let pasteboard: NSPasteboard
    public let focusedElementProvider: FocusedElementProvider
    public let directAXReplacer: DirectAXReplacer
    public let keyPoster: KeyPoster
    public let appActivator: AppActivator

    public init(
        configuration: SelectionConfiguration = .default,
        pasteboard: NSPasteboard = .general,
        focusedElementProvider: @escaping FocusedElementProvider = SelectionReplacer.defaultFocusedElement,
        directAXReplacer: @escaping DirectAXReplacer = SelectionReplacer.defaultDirectAXReplacer,
        keyPoster: @escaping KeyPoster = { KeyboardEventPoster.postKey(keyCode: $0, flags: $1) },
        appActivator: @escaping AppActivator = { $0.activate() }
    ) {
        self.configuration = configuration
        self.pasteboard = pasteboard
        self.focusedElementProvider = focusedElementProvider
        self.directAXReplacer = directAXReplacer
        self.keyPoster = keyPoster
        self.appActivator = appActivator
    }

    public static let `default` = SelectionReplacer()

    /// Minimum pasteboard restore delay for rich document apps, whose paste is applied asynchronously.
    private static let richDocumentRestoreDelay: TimeInterval = 0.35

    /// Default direct AX replacement implementation.
    /// Checks if the focused element is editable and allows direct setting of kAXSelectedTextAttribute or kAXValueAttribute.
    public static let defaultDirectAXReplacer: DirectAXReplacer = { element, text in
        var isSettable: DarwinBoolean = false
        // First try kAXSelectedTextAttribute
        let status = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSettable)
        if status == .success && isSettable.boolValue {
            let setResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if setResult == .success {
                OpenSelectionLogging.log("SelectionReplacer: successfully set kAXSelectedTextAttribute directly")
                return true
            }
        }
        return false
    }

    /// Replaces the current selection in the target app with the given text.
    @MainActor
    public func replace(
        with text: String,
        html: String? = nil,
        rtf: String? = nil,
        flavors: [PasteboardFlavor] = [],
        in app: NSRunningApplication? = nil,
        matchStyle: Bool = false,
        restorePasteboard: Bool = true
    ) async throws {
        let targetApp = app ?? NSWorkspace.shared.frontmostApplication
        let bundleID = targetApp?.bundleIdentifier

        // 1. Try direct AX text control replacement if element is accessible and editable,
        // UNLESS the app is a rich document app (e.g. Apple Notes, TextEdit, Pages) or rich formats were supplied.
        let isRichDocApp = AppMatching.isRichDocumentApp(bundleID)
        let hasRichContent = (html.map { !$0.isEmpty } ?? false)
            || (rtf.map { !$0.isEmpty } ?? false)
            || !flavors.isEmpty

        if !isRichDocApp && !hasRichContent {
            if let targetApp, let focused = focusedElementProvider(targetApp) {
                if directAXReplacer(focused, text) {
                    return
                }
            }
        }

        // 2. Fall back to non-destructive pasteboard delivery:
        let snapshot = restorePasteboard ? PasteboardSnapshot.capture(pasteboard) : nil

        pasteboard.clearContents()
        if !flavors.isEmpty {
            // Write the captured representations verbatim. `setData` (rather than `writeObjects`)
            // mirrors clipboard managers and avoids rich items being pasted more than once; the
            // app-private flavors are what let rich content (e.g. Notes checklists) round-trip.
            for flavor in flavors {
                pasteboard.setData(flavor.data, forType: NSPasteboard.PasteboardType(flavor.type))
            }
            pasteboard.setData(Data(), forType: PasteboardSnapshot.transientType)
            pasteboard.setData(Data(), forType: PasteboardSnapshot.autoGeneratedType)
        } else {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if let html, !html.isEmpty {
                item.setString(html, forType: .html)
            }
            if let rtf, !rtf.isEmpty, let rtfData = RichTextCoding.data(from: rtf) {
                item.setData(rtfData, forType: .rtf)
            }
            item.setData(Data(), forType: PasteboardSnapshot.transientType)
            item.setData(Data(), forType: PasteboardSnapshot.autoGeneratedType)
            pasteboard.writeObjects([item])
        }
        let changeCountAfterWrite = pasteboard.changeCount

        if let targetApp {
            appActivator(targetApp)
        }

        // Synthesize paste keystroke:
        // When matchStyle is requested, use Option+Shift+Command+V (Paste and Match Style)
        let keyFlags: CGEventFlags = matchStyle ? [.maskCommand, .maskAlternate, .maskShift] : .maskCommand
        keyPoster(configuration.pasteVirtualKey, keyFlags)

        if restorePasteboard {
            // Document apps (like Apple Notes) sync asynchronously and benefit from a slightly longer delivery window
            let baseDelay = configuration.pasteboardDeliveryRestoreDelay
            let restoreDelay = isRichDocApp ? max(baseDelay, Self.richDocumentRestoreDelay) : baseDelay
            if restoreDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(restoreDelay * 1_000_000_000))
                if pasteboard.changeCount == changeCountAfterWrite {
                    snapshot?.restore(to: pasteboard, transientMarkers: true)
                    OpenSelectionLogging.log("SelectionReplacer: restored original pasteboard contents")
                } else {
                    OpenSelectionLogging.log("SelectionReplacer: pasteboard was mutated during delivery; skipping restore")
                }
            }
        }
    }

    /// Replaces the selection (convenience alias for replace).
    @MainActor
    public func replaceSelection(
        with text: String,
        html: String? = nil,
        rtf: String? = nil,
        flavors: [PasteboardFlavor] = [],
        in app: NSRunningApplication? = nil,
        matchStyle: Bool = false,
        restorePasteboard: Bool = true
    ) async throws {
        try await replace(
            with: text,
            html: html,
            rtf: rtf,
            flavors: flavors,
            in: app,
            matchStyle: matchStyle,
            restorePasteboard: restorePasteboard
        )
    }

    nonisolated public static let defaultFocusedElement: FocusedElementProvider = { app in
        focusedElement(for: app)
    }

    nonisolated private static func focusedElement(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElementValue: AnyObject?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue)
        guard status == .success, let focused = focusedElementValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }
}

// PasteboardCopyEngine.swift
// OpenSelection
//
// Standalone clipboard capture engine: archives pasteboard types, runs a copy
// trigger, polls for a changeCount advance with non-empty string content, then
// restores the original items tagged with transient markers.
import AppKit
import Foundation

@MainActor
public struct PasteboardCopyEngine {
    public typealias CopyTrigger = @MainActor () -> Void
    /// Answers whether it is safe to post a synthetic copy that will be delivered to the current key
    /// window. Defaults to the system overlay gate (see `CopyTriggerGate`).
    public typealias CopyAuthorization = @MainActor () -> Bool

    private let configuration: SelectionConfiguration
    private let isCopyAuthorized: CopyAuthorization

    public init(
        configuration: SelectionConfiguration = .default,
        isCopyAuthorized: @escaping CopyAuthorization = {
            !CopyTriggerGate.isForeignOverlayPresent(at: NSEvent.mouseLocation)
        }
    ) {
        self.configuration = configuration
        self.isCopyAuthorized = isCopyAuthorized
    }

    /// Runs `trigger` between archiving the pasteboard and polling for a change.
    public func capture(
        pasteboard: NSPasteboard = .general,
        timeout: TimeInterval? = nil,
        restoreDelay: TimeInterval? = nil,
        trigger: CopyTrigger
    ) async -> SelectionResult? {
        // Refuse before posting anything: a key window owned by another app means the synthetic ⌘C
        // would fire that overlay's shortcut and tear it down instead of reaching the target app.
        guard isCopyAuthorized() else {
            OpenSelectionLogging.log("copy engine: suppressed — a foreign overlay owns the key window")
            return nil
        }

        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let initialChangeCount = pasteboard.changeCount

        trigger()

        let resolvedTimeout = timeout ?? Self.pollingTimeout(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, configuration: configuration)
        let pollInterval: TimeInterval = 0.002
        let deadline = Date().addingTimeInterval(resolvedTimeout)
        var result: SelectionResult?

        while Date() < deadline && !Task.isCancelled {
            if pasteboard.changeCount != initialChangeCount {
                if let candidate = pasteboard.string(forType: .string),
                   Self.hasSelection(candidate) {
                    let html = pasteboard.string(forType: .html) ?? Self.htmlFromRTF(pasteboard)
                    let rtf = pasteboard.string(forType: .rtf)
                    result = SelectionResult(
                        text: candidate,
                        bounds: nil,
                        html: html,
                        rtf: rtf,
                        strategy: .keyboardCopy,
                        isEditable: false
                    )
                    break
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        guard let result else {
            if pasteboard.changeCount != initialChangeCount {
                OpenSelectionLogging.log("copy engine: no non-empty pasteboard text within deadline; restoring immediately")
                snapshot.restore(to: pasteboard, transientMarkers: true)
            }
            return nil
        }

        snapshot.restore(to: pasteboard, transientMarkers: true)
        return result
    }

    /// Per-app copy polling timeout. Browsers and Electron apps need more time for multi-process IPC clipboard operations to stabilize.
    public static func pollingTimeout(
        for bundleID: String?,
        configuration: SelectionConfiguration = .default
    ) -> TimeInterval {
        guard let bundleID else { return configuration.pasteboardCopyTimeout }
        if isMultiProcess(bundleID) {
            return configuration.safariPasteboardCopyTimeout
        }
        return configuration.pasteboardCopyTimeout
    }

    public static func isMultiProcess(_ bundleID: String) -> Bool {
        AppMatching.isMultiProcess(bundleID)
    }

    public static func isBrowser(_ bundleID: String) -> Bool {
        AppMatching.isBrowser(bundleID)
    }

    /// Returns `true` only when `text` is non-nil and contains visible, substantial characters.
    public static func hasSelection(_ text: String?) -> Bool {
        TextSanitizer.isSubstantial(text)
    }

    /// Converts a pasteboard's RTF data into HTML.
    private static func htmlFromRTF(_ pasteboard: NSPasteboard) -> String? {
        guard let rtfData = pasteboard.data(forType: .rtf),
              let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil),
              let htmlData = try? attributed.data(
                  from: NSRange(location: 0, length: attributed.length),
                  documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
              ) else { return nil }
        return String(data: htmlData, encoding: .utf8)
    }
}

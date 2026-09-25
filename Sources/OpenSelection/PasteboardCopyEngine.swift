// PasteboardCopyEngine.swift
// OpenSelection
//
// Standalone clipboard capture engine: archives pasteboard types, runs a copy
// trigger, polls for a changeCount advance with non-empty string content, then
// restores the original items tagged with transient markers.
import AppKit
import Foundation
import os

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

        // Watch for the user's own ⌘C/⌘X while the synthetic copy is in flight. Our posted events
        // carry `KeyboardEventPoster.syntheticEventTag`; anything untagged is the user, so the
        // clipboard they just filled must never be clobbered by the snapshot restore below.
        let userCopied = OSAllocatedUnfairLock(initialState: false)
        let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.modifierFlags.contains(.command),
                  event.keyCode == 0x08 || event.keyCode == 0x07,   // kVK_ANSI_C / kVK_ANSI_X
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                      != KeyboardEventPoster.syntheticEventTag
            else { return }
            userCopied.withLock { $0 = true }
        }
        defer { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

        trigger()

        let resolvedTimeout = timeout ?? Self.pollingTimeout(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, configuration: configuration)
        let pollInterval: TimeInterval = 0.001
        let deadline = Date().addingTimeInterval(resolvedTimeout)
        var result: SelectionResult?

        while Date() < deadline && !Task.isCancelled {
            // The user copied — bail before touching the pasteboard and leave their content intact.
            if userCopied.withLock({ $0 }) {
                OpenSelectionLogging.log("copy engine: user copied during grab — leaving clipboard untouched")
                return nil
            }

            if pasteboard.changeCount != initialChangeCount {
                if let candidate = pasteboard.string(forType: .string),
                   Self.hasSelection(candidate) {
                    // Extract raw pasteboard data synchronously and restore the original items IMMEDIATELY.
                    // This shrinks the clipboard exposure window down to sub-millisecond microseconds,
                    // preventing third-party clipboard managers (Maccy, Paste, etc.) from intercepting
                    // the synthetic copy before the previous clipboard content is restored.
                    let rawHTML = pasteboard.string(forType: .html)
                    let rawRTFData = pasteboard.data(forType: .rtf)
                    let rawRTFString = pasteboard.string(forType: .rtf)
                    let rawFlavors = Self.captureFlavors(from: pasteboard)
                    let postCopyCount = pasteboard.changeCount

                    // Grace window: a user's ⌘C landing a few ms after ours trips the flag or bumps
                    // the changeCount again. The restore is only safe once neither has happened.
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    guard !userCopied.withLock({ $0 }), pasteboard.changeCount == postCopyCount else {
                        OpenSelectionLogging.log("copy engine: external copy detected — leaving clipboard untouched")
                        return nil
                    }

                    snapshot.restore(to: pasteboard, transientMarkers: true)

                    // Post-process HTML/RTF in memory now that the pasteboard is safely restored
                    let html = rawHTML ?? rawRTFData.flatMap(Self.htmlFromRTFData)
                    let rtf = rawRTFData.flatMap(RichTextCoding.string(from:))
                        ?? rawRTFString

                    result = SelectionResult(
                        text: candidate,
                        bounds: nil,
                        html: html,
                        rtf: rtf,
                        flavors: rawFlavors,
                        strategy: .keyboardCopy,
                        isEditable: false
                    )
                    break
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        guard let result else {
            if pasteboard.changeCount != initialChangeCount, !userCopied.withLock({ $0 }) {
                OpenSelectionLogging.log("copy engine: no non-empty pasteboard text within deadline; restoring immediately")
                snapshot.restore(to: pasteboard, transientMarkers: true)
            }
            return nil
        }

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

    /// Captures every declared type on the pasteboard's first item as raw bytes, excluding the
    /// transient/auto-generated markers OpenSelection writes. Preserving the full item is what lets
    /// app-private representations (Notes checklists, etc.) survive a copy→paste round trip.
    static func captureFlavors(from pasteboard: NSPasteboard) -> [PasteboardFlavor] {
        guard let item = pasteboard.pasteboardItems?.first else { return [] }
        let ignored: Set<NSPasteboard.PasteboardType> = [
            PasteboardSnapshot.transientType,
            PasteboardSnapshot.autoGeneratedType,
            PasteboardSnapshot.concealedType,
            PasteboardSnapshot.modifiedType
        ]
        return item.types.compactMap { type in
            guard !ignored.contains(type),
                  let data = item.data(forType: type) else { return nil }
            return PasteboardFlavor(type: type.rawValue, data: data)
        }
    }

    /// Converts raw RTF bytes into HTML.
    private static func htmlFromRTFData(_ rtfData: Data) -> String? {
        guard let attributed = NSAttributedString(rtf: rtfData, documentAttributes: nil),
              let htmlData = try? attributed.data(
                  from: NSRange(location: 0, length: attributed.length),
                  documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
              ) else { return nil }
        return String(data: htmlData, encoding: .utf8)
    }

    /// Converts an HTML string into an RTF string (see `RichTextCoding` for the byte bridge).
    private static func rtfFromHTML(_ html: String) -> String? {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ),
              let rtfData = try? attributed.data(
                  from: NSRange(location: 0, length: attributed.length),
                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
              ) else { return nil }
        return RichTextCoding.string(from: rtfData)
    }
}

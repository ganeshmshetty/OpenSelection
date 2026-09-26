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
        // changeCount captured the instant our own synthetic copy was read. The user-copy bail-out
        // below needs it to tell "the user copied something" (their content is now on the pasteboard
        // — leave it alone) from "the user pressed ⌘C and it copied nothing" (the pasteboard still
        // holds OUR synthetic copy, so the snapshot must be restored or their clipboard is lost).
        var postCopyCount: Int?

        while Date() < deadline && !Task.isCancelled {
            // The user pressed ⌘C/⌘X while our copy was in flight. Bail either way, but only restore
            // when the pasteboard provably still holds our own copy: an untagged keydown does not
            // guarantee a clipboard write (no selection, or an app that ignores the shortcut), and
            // skipping the restore in that case would replace the user's clipboard with our
            // synthetic selection.
            if userCopied.withLock({ $0 }) {
                Self.restoreAfterUserCopyIfNeeded(
                    changeCount: pasteboard.changeCount,
                    postCopyCount: postCopyCount,
                    snapshot: snapshot,
                    pasteboard: pasteboard
                )
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
                    let observedCopyCount = pasteboard.changeCount
                    postCopyCount = observedCopyCount

                    // No suspension point may sit between reading the synthetic copy and restoring the
                    // snapshot. While the unmarked copy is on the pasteboard a polling clipboard manager
                    // (Maccy reads changeCount every 0.5s) can record it as a ghost history entry, and any
                    // grace window here scales that ghost rate directly: 30ms / 0.5s ≈ 6%. The user-copy
                    // guard is therefore evaluated synchronously — a real ⌘C/⌘X bumps the changeCount (and
                    // the monitor above flags the untagged event even when it races ours), so restoring
                    // the instant after the read keeps the exposure down to microseconds.
                    //
                    // An untagged ⌘C/⌘X that copied *nothing* leaves the changeCount untouched, so it
                    // falls through to the restore below: the pasteboard still holds our synthetic copy,
                    // and bailing out would leave it there in place of the user's clipboard. A user copy
                    // that really landed advanced the changeCount and takes the bail-out instead.
                    guard pasteboard.changeCount == observedCopyCount else {
                        OpenSelectionLogging.log("copy engine: external copy detected — leaving clipboard untouched")
                        return nil
                    }

                    snapshot.restore(to: pasteboard, transientMarkers: true)

                    // Post-process HTML/RTF in memory now that the pasteboard is safely restored
                    let html = rawHTML ?? rawRTFData.flatMap(Self.htmlFromRTFData)
                    let rtf = rawRTFData.flatMap(RichTextCoding.string(from:))
                        ?? rawRTFString
                        ?? rawHTML.flatMap(Self.rtfFromHTML)

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
            let changeCount = pasteboard.changeCount
            let userCopyLanded = userCopied.withLock({ $0 })
                && !Self.shouldRestoreAfterUserCopy(changeCount: changeCount, postCopyCount: postCopyCount)
            if changeCount != initialChangeCount, !userCopyLanded {
                OpenSelectionLogging.log("copy engine: no non-empty pasteboard text within deadline; restoring immediately")
                snapshot.restore(to: pasteboard, transientMarkers: true)
            }
            return nil
        }

        return result
    }

    /// Whether the snapshot must be restored after a user ⌘C/⌘X was observed mid-grab.
    ///
    /// An untagged copy keydown does not guarantee a clipboard write: with nothing selected, or in an
    /// app that ignores the shortcut, the pasteboard is untouched and still holds OUR synthetic copy.
    /// Bailing out without a restore in that case silently replaces the user's clipboard with our
    /// selection. So restore whenever nothing has landed since we read our own copy. When the user
    /// really did copy — the changeCount advanced past our read, or we never saw our copy land at
    /// all — their content is on the pasteboard and must be left alone.
    static func shouldRestoreAfterUserCopy(changeCount: Int, postCopyCount: Int?) -> Bool {
        guard let postCopyCount else { return false }
        return changeCount == postCopyCount
    }

    /// Applies the restore half of that decision to the pasteboard. Returns whether the snapshot was
    /// restored. Internal rather than private so the restore-vs-leave contract is testable directly,
    /// without racing a real untagged key event to set the flag.
    @discardableResult
    static func restoreAfterUserCopyIfNeeded(
        changeCount: Int,
        postCopyCount: Int?,
        snapshot: PasteboardSnapshot,
        pasteboard: NSPasteboard
    ) -> Bool {
        guard shouldRestoreAfterUserCopy(changeCount: changeCount, postCopyCount: postCopyCount) else {
            OpenSelectionLogging.log("copy engine: user copied during grab — leaving clipboard untouched")
            return false
        }
        snapshot.restore(to: pasteboard, transientMarkers: true)
        OpenSelectionLogging.log("copy engine: user copy wrote nothing to the pasteboard; restored the snapshot over our stale synthetic copy")
        return true
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

    /// Pasteboard types read eagerly when capturing a selection's flavors.
    ///
    /// Deliberately an allowlist, not "every declared type". A type backed by a data provider is
    /// fetched cross-process and synchronously, so reading it while the *unmarked* synthetic copy is
    /// still on the pasteboard holds that content exposed for as long as the provider takes —
    /// reopening exactly the ghost-entry window the read-then-restore ordering exists to close, and
    /// invisibly to the in-process ghost test (which can only sample at suspension points). Only
    /// types that are already materialized are read: the text/rich-text formats OpenClip acts on and
    /// the app-private representation it round-trips (Notes checklists). A promised type is left to
    /// the snapshot restore rather than blocking the capture.
    static let eagerFlavorTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .html, .rtf, .rtfd, .pdf,
        NSPasteboard.PasteboardType("public.tab-separated-text"),
        NSPasteboard.PasteboardType("com.apple.notes.richtext")
    ]

    /// Captures the eagerly-materialized types on the pasteboard's first item as raw bytes, excluding
    /// the transient/auto-generated markers OpenSelection writes. Preserving these is what lets
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
                  eagerFlavorTypes.contains(type),
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

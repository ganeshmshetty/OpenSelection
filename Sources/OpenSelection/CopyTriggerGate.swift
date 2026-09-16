// CopyTriggerGate.swift
// OpenSelection
//
// Guards synthetic copy / menu-press retrieval. A copy strategy posts a real ⌘C (or presses
// Edit ▸ Copy) that is delivered to the *current key window*. When another app owns that window
// while its app is not active — a screenshot/annotation tool's full-screen picker, a non-activating
// HUD — the synthetic event fires that overlay's own shortcut (e.g. macshot's "Copy Selection")
// and tears the capture down, instead of reaching the app OpenClip meant to read. Callers use this
// gate to refuse the copy before it is posted; reads that need no synthetic event are unaffected.
import AppKit
import CoreGraphics

/// One on-screen window reduced to what the copy guard needs. `frame` is in Cocoa screen
/// coordinates (bottom-left origin) so it can be tested against `NSEvent.mouseLocation`.
public struct OnScreenWindowInfo: Equatable, Sendable {
    public let ownerPID: pid_t
    public let layer: Int
    public let frame: CGRect

    public init(ownerPID: pid_t, layer: Int, frame: CGRect) {
        self.ownerPID = ownerPID
        self.layer = layer
        self.frame = frame
    }
}

public enum CopyTriggerGate {
    /// Pure decision over a front-to-back window list. Unknown inputs never suppress (fail open).
    public static func isForeignOverlay(
        windows: [OnScreenWindowInfo],
        at point: CGPoint,
        frontmostPID: pid_t?,
        selfPID: pid_t,
        displayBounds: CGRect? = nil
    ) -> Bool {
        guard let frontmostPID else { return false }
        guard let top = windows.first(where: { $0.layer >= 0 && $0.frame.contains(point) }) else { return false }
        if top.ownerPID == selfPID { return false }   // our own popup is not a foreign overlay
        if top.ownerPID != frontmostPID { return true }
        // A capture tool can *activate itself* while its picker is up (CleanShot X reports as
        // frontmost), so the owner mismatch never fires. Detect it structurally instead: the
        // frontmost app's own top window is an elevated, display-covering overlay, not a document.
        guard let displayBounds else { return false }
        let coversDisplay = top.frame.width >= displayBounds.width - 1 && top.frame.height >= displayBounds.height - 1
        return top.layer > 0 && coversDisplay
    }

    /// True when a foreign overlay sits at `point` right now. Inert under XCTest so unit tests never
    /// depend on the live window server; the pure `isForeignOverlay` is exercised directly instead.
    public static func isForeignOverlayPresent(at point: CGPoint) -> Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        let display = NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame
        return isForeignOverlay(
            windows: systemWindows(),
            at: point,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            displayBounds: display
        )
    }

    /// Reads the live on-screen window list, ordered front-to-back, converting `CGWindowList`'s
    /// top-left global bounds into Cocoa screen coordinates (the y-axis is flipped about the
    /// primary display's top edge).
    static func systemWindows() -> [OnScreenWindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
        return raw.compactMap { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber else { return nil }
            let cocoaFrame = CGRect(
                x: cgBounds.minX,
                y: primaryHeight - cgBounds.maxY,
                width: cgBounds.width,
                height: cgBounds.height
            )
            return OnScreenWindowInfo(ownerPID: ownerNumber.int32Value, layer: layerNumber.intValue, frame: cocoaFrame)
        }
    }
}

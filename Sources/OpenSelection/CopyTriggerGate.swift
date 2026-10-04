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
    /// The owning application's bundle identifier, or `nil` when no application owns the window
    /// (the window server). Distinguishes app overlays from system chrome that never receives input.
    public let ownerBundleID: String?
    public let layer: Int
    public let frame: CGRect
    /// The window's alpha (0 = fully transparent). System UI processes keep invisible helper
    /// windows on screen at elevated layers; an invisible window can neither be interacted with
    /// nor swallow a synthetic ⌘C, so it must never count as an overlay.
    public let alpha: Double

    public init(ownerPID: pid_t, ownerBundleID: String? = nil, layer: Int, frame: CGRect, alpha: Double = 1.0) {
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.layer = layer
        self.frame = frame
        self.alpha = alpha
    }
}

public enum CopyTriggerGate {
    /// Bundle identifiers of system chrome — always-present windows that sit above app windows and
    /// can cover a display, but never own an app's key window, so a synthetic ⌘C is never delivered
    /// to them. The Dock's full-screen window (layer 20) is the canonical case: on macOS 26 with the
    /// Dock visible it covers the display and was mistaken for a capture overlay, stripping every
    /// copy-based read.
    public static let systemChromeBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.wallpaper"
    ]

    /// Bundle identifiers of system UI *panels* (Control Center, Notification Center, etc.) that
    /// float above applications. Interacting with these must never deliver synthetic copies to
    /// background applications. Their display-covering backdrops are excluded by
    /// `isForeignOverlay`, which would otherwise suppress every copy on screen while one is up.
    public static let systemUIBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.Spotlight"
    ]

    /// Bundle identifiers of known screenshot and screen-recording tools whose selection pickers
    /// or crosshair overlays swallow ⌘C to copy images instead of text.
    public static let screenCaptureBundleIDs: Set<String> = [
        "com.cleanshot.app",
        "pl.maketheweb.cleanshotx",
        "cc.ffitch.shottr",
        "com.macshot.app",
        "com.Snipaste",
        "com.TechSmith.Snagit",
        "net.telestream.screenflow",
        "com.wulkano.kap",
        "com.x-art.Xnip",
        "com.monosnap.monosnap",
        "org.flameshot.flameshot",
        "com.skillbrains.lightshot",
        "com.apple.screencapture",
        "com.apple.screencaptureui"
    ]

    /// Whether `window` can own the key window that receives a synthetic ⌘C. Windows with no owning
    /// application (the window server), system chrome, and extreme layer windows (shields/hardware
    /// overlays) cannot, so they must never be treated as copy-swallowing overlays.
    static func canOwnKeyWindow(_ window: OnScreenWindowInfo) -> Bool {
        guard let bundleID = window.ownerBundleID else { return false }
        if systemChromeBundleIDs.contains(bundleID) { return false }
        // Extreme layers (>= 1000) are screen shields, cursor/event tracking overlays, or screen savers;
        // they can never own an app's key window for text selection.
        if window.layer >= 1000 { return false }
        return true
    }

    /// Pure decision over a front-to-back window list. Unknown inputs never suppress (fail open).
    ///
    /// Only two categories of windows can swallow the synthetic ⌘C:
    /// 1. A known screenshot/capture tool's full-screen picker (elevated, display-covering).
    /// 2. An elevated System UI *panel* (Control Center, Notification Center) — its display-covering
    ///    backdrop is a transparent click-catcher and does NOT suppress.
    ///
    /// Everything else — window managers, mouse utilities, dimmers, HUDs, notification badges,
    /// helper windows — is assumed to not intercept ⌘C and fails open. The earlier approach of
    /// suppressing for any elevated display-covering foreign window and allowlisting known-good
    /// utilities was a whack-a-mole: every non-allowlisted utility silently dropped selections.
    public static func isForeignOverlay(
        windows: [OnScreenWindowInfo],
        at point: CGPoint,
        frontmostPID: pid_t?,
        selfPID: pid_t,
        displayBounds: CGRect? = nil
    ) -> Bool {
        // Without a known frontmost app or display there is nothing to reason about: fail open.
        guard let frontmostPID, let displayBounds else { return false }
        // Only visible windows that can own the key window are candidates; system chrome and
        // invisible (alpha 0) helper windows are skipped.
        guard let top = windows.first(where: {
            $0.layer >= 0 && $0.alpha > 0 && $0.frame.contains(point) && Self.canOwnKeyWindow($0)
        }) else { return false }
        if top.ownerPID == selfPID { return false }   // our own popup is not a foreign overlay

        let coversDisplay = top.frame.width >= displayBounds.width - 1
            && top.frame.height >= displayBounds.height - 1

        if top.ownerPID == frontmostPID {
            // A capture tool can *activate itself* while its picker is up (CleanShot X reports as
            // frontmost). Only suppress if the frontmost app is an actual screen capture tool whose
            // picker is covering the display. Normal applications (Chrome, Ghostty, etc.) in fullscreen
            // (layer 500) belong to the active user session and are never foreign overlays.
            if let bundleID = top.ownerBundleID, screenCaptureBundleIDs.contains(bundleID) {
                return top.layer > 0 && coversDisplay
            }
            return false
        }

        if let bundleID = top.ownerBundleID, systemUIBundleIDs.contains(bundleID) && top.layer > 0 {
            // A System UI *panel* can swallow the copy even though it does not cover the display.
            // Its display-covering backdrop is a transparent click-catcher, not a panel: treating
            // it as an overlay suppressed every copy on screen for as long as it was up.
            return !coversDisplay
        }

        // Only known screenshot/capture tools suppress: their full-screen pickers intercept ⌘C to
        // copy an image. All other elevated windows (window managers, mouse utilities, dimmers, HUDs)
        // never own key window and never swallow a copy shortcut, so they fail open.
        guard let bundleID = top.ownerBundleID, screenCaptureBundleIDs.contains(bundleID) else {
            return false
        }
        return top.layer > 0 && coversDisplay
    }

    /// True when a foreign overlay sits at `point` right now. Inert under XCTest so unit tests never
    /// depend on the live window server; the pure `isForeignOverlay` is exercised directly instead.
    public static func isForeignOverlayPresent(at point: CGPoint) -> Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        let display = NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame
        let windows = systemWindows()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suppressed = isForeignOverlay(
            windows: windows,
            at: point,
            frontmostPID: frontmostPID,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            displayBounds: display
        )
        // Log the decision inputs only when we refuse, so a false positive is diagnosable from a
        // user's log dump instead of being an invisible "no selection".
        if suppressed {
            let top = windows.first { $0.layer >= 0 && $0.alpha > 0 && $0.frame.contains(point) }
            DiagnosticsHub.shared.log(.info, .gate, "copy gate suppressed by foreign overlay", fields: [
                "frontmostPID": .int(Int64(frontmostPID ?? -1)),
                "selfPID": .int(Int64(ProcessInfo.processInfo.processIdentifier)),
                "topPID": .int(Int64(top?.ownerPID ?? -1)),
                "topLayer": .int(Int64(top?.layer ?? -1))
            ])
        }
        return suppressed
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
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            let cocoaFrame = CGRect(
                x: cgBounds.minX,
                y: primaryHeight - cgBounds.maxY,
                width: cgBounds.width,
                height: cgBounds.height
            )
            let ownerPID = ownerNumber.int32Value
            let ownerBundleID = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
            return OnScreenWindowInfo(
                ownerPID: ownerPID,
                ownerBundleID: ownerBundleID,
                layer: layerNumber.intValue,
                frame: cocoaFrame,
                alpha: alpha
            )
        }
    }
}

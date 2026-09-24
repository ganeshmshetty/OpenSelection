import XCTest
import CoreGraphics
@testable import OpenSelection

final class CopyTriggerGateTests: XCTestCase {
    private let selfPID: pid_t = 100
    private let frontmost: pid_t = 200
    private let display = CGRect(x: 0, y: 0, width: 1470, height: 956)

    /// A foreign capture tool's full-screen picker (elevated, display-covering) owns the key window
    /// and would swallow the synthetic ⌘C, so the copy must be suppressed.
    func testForeignFullScreenElevatedOverlaySuppresses() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, ownerBundleID: "com.macshot.app", layer: 257, frame: display),
            OnScreenWindowInfo(ownerPID: frontmost, ownerBundleID: "com.apple.Safari", layer: 0, frame: display)
        ]
        XCTAssertTrue(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// Regression: a *normal* (layer 0) window owned by another process — an Electron helper window
    /// (VS Code), a background app, or a stale window-list entry — sits below the frontmost app's key
    /// window and can never receive the synthetic ⌘C. Treating it as an overlay suppressed every
    /// copy-based read whose mouse point happened to overlap it.
    func testForeignFullScreenNormalWindowDoesNotSuppress() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, layer: 0, frame: display),
            OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// Regression (NotchNook): a notch/HUD app's elevated panel covers only a strip of the screen and
    /// never owns the key window. It used to be mistaken for a capture overlay, dropping the selection
    /// whenever the cursor landed under the notch region.
    func testForeignPartialElevatedPanelDoesNotSuppress() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, layer: 25, frame: CGRect(x: 0, y: 707, width: 1470, height: 250)),
            OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 570, y: 734),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    func testFrontmostOwnsTopWindowAllows() {
        let windows = [
            OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// Our own popup sits above the frontmost app while visible; it must never count as foreign.
    func testOwnPopupIsNotForeign() {
        let windows = [
            OnScreenWindowInfo(ownerPID: selfPID, layer: 101, frame: display),
            OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// CleanShot X activates itself while its picker is up, so `ownerPID == frontmostPID`; the
    /// overlay is recognised structurally as an elevated, display-covering window.
    func testFrontmostFullScreenElevatedWindowIsOverlay() {
        let overlay = OnScreenWindowInfo(ownerPID: frontmost, ownerBundleID: "com.cleanshot.app", layer: 103, frame: display)
        XCTAssertTrue(CopyTriggerGate.isForeignOverlay(
            windows: [overlay], at: CGPoint(x: 700, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// Regression (#104): on macOS 26 with the Dock visible, the Dock owns a full-screen layer-20
    /// window that covers the display. It never owns an app's key window, so it must not be mistaken
    /// for a capture overlay — doing so stripped the copy fallback and killed every selection in
    /// apps that can only be read via copy.
    func testDockFullScreenChromeDoesNotSuppress() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, ownerBundleID: "com.apple.dock", layer: 20, frame: display),
            OnScreenWindowInfo(ownerPID: frontmost, ownerBundleID: "com.apple.Safari", layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// The window server owns the menu bar (and other chrome) with no owning application; a
    /// display-covering window server window is not an app overlay either.
    func testWindowServerChromeDoesNotSuppress() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 1, ownerBundleID: nil, layer: 24, frame: display),
            OnScreenWindowInfo(ownerPID: frontmost, ownerBundleID: "com.apple.Safari", layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// Regression: Control Center keeps an invisible (alpha 0) full-height helper window on screen
    /// at layer 22 covering the right of the display. It is not visible, not interactive, and can
    /// never swallow the synthetic ⌘C, so treating it as an overlay stripped every copy-based read
    /// whose point landed on the right half of the screen (e.g. text inputs in a browser).
    func testInvisibleControlCenterHelperDoesNotSuppress() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, ownerBundleID: "com.apple.controlcenter", layer: 22,
                               frame: CGRect(x: 990, y: -11, width: 656, height: 967), alpha: 0.0),
            OnScreenWindowInfo(ownerPID: frontmost, ownerBundleID: "com.apple.Safari", layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 1200, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// A System UI *panel* (Control Center's open panel, a notification banner) can swallow the
    /// copy even though it does not cover the display, so it still suppresses.
    func testVisibleSystemUIPanelSuppresses() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, ownerBundleID: "com.apple.controlcenter", layer: 25,
                               frame: CGRect(x: 1050, y: 500, width: 380, height: 440)),
            OnScreenWindowInfo(ownerPID: frontmost, ownerBundleID: "com.apple.Safari", layer: 0, frame: display)
        ]
        XCTAssertTrue(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 1200, y: 700),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// Regression: Notification Center's display-covering layer-21 backdrop is a transparent
    /// click-catcher, not a panel. Treating it as an overlay suppressed every copy on screen for as
    /// long as a notification was showing, so a selection far from the banner was dropped.
    func testSystemUIDisplayCoveringBackdropDoesNotSuppress() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, ownerBundleID: "com.apple.notificationcenterui", layer: 21, frame: display),
            OnScreenWindowInfo(ownerPID: frontmost, ownerBundleID: "com.apple.Safari", layer: 0, frame: display)
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 570, y: 57),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// A normal document window (layer 0) covering the display is not an overlay.
    func testFrontmostFullScreenNormalWindowIsNotOverlay() {
        let window = OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: display)
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [window], at: CGPoint(x: 700, y: 400),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    /// An elevated but small window (a menu or popover) is not an overlay.
    func testFrontmostSmallElevatedWindowIsNotOverlay() {
        let menu = OnScreenWindowInfo(ownerPID: frontmost, layer: 101, frame: CGRect(x: 400, y: 700, width: 280, height: 240))
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [menu], at: CGPoint(x: 500, y: 800),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display))
    }

    func testUnknownInputsFailOpen() {
        let window = OnScreenWindowInfo(ownerPID: 999, layer: 257, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [window], at: CGPoint(x: 500, y: 500),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display),
            "no window under the point must not suppress")
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [window], at: CGPoint(x: 50, y: 50),
            frontmostPID: nil, selfPID: selfPID, displayBounds: display),
            "unknown frontmost app must not suppress")
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [], at: CGPoint(x: 50, y: 50),
            frontmostPID: frontmost, selfPID: selfPID, displayBounds: display),
            "no windows must not suppress")
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [OnScreenWindowInfo(ownerPID: 999, layer: 257, frame: display)],
            at: CGPoint(x: 50, y: 50), frontmostPID: frontmost, selfPID: selfPID, displayBounds: nil),
            "unknown display must not suppress")
    }
}

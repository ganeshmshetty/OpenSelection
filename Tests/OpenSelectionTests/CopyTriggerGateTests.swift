import XCTest
import CoreGraphics
@testable import OpenSelection

final class CopyTriggerGateTests: XCTestCase {
    private let selfPID: pid_t = 100
    private let frontmost: pid_t = 200

    func testForeignOverlayOnTopSuppresses() {
        let windows = [
            OnScreenWindowInfo(ownerPID: 999, layer: 257, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        XCTAssertTrue(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400), frontmostPID: frontmost, selfPID: selfPID))
    }

    func testFrontmostOwnsTopWindowAllows() {
        let windows = [
            OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400), frontmostPID: frontmost, selfPID: selfPID))
    }

    /// Our own popup sits above the frontmost app while visible; it must never count as foreign.
    func testOwnPopupIsNotForeign() {
        let windows = [
            OnScreenWindowInfo(ownerPID: selfPID, layer: 101, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            OnScreenWindowInfo(ownerPID: frontmost, layer: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: windows, at: CGPoint(x: 500, y: 400), frontmostPID: frontmost, selfPID: selfPID))
    }

    func testUnknownInputsFailOpen() {
        let window = OnScreenWindowInfo(ownerPID: 999, layer: 257, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [window], at: CGPoint(x: 500, y: 500), frontmostPID: frontmost, selfPID: selfPID),
            "no window under the point must not suppress")
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [window], at: CGPoint(x: 50, y: 50), frontmostPID: nil, selfPID: selfPID),
            "unknown frontmost app must not suppress")
        XCTAssertFalse(CopyTriggerGate.isForeignOverlay(
            windows: [], at: CGPoint(x: 50, y: 50), frontmostPID: frontmost, selfPID: selfPID),
            "no windows must not suppress")
    }
}

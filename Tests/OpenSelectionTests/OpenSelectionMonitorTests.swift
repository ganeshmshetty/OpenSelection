// OpenSelectionMonitorTests.swift
// OpenSelectionTests
import XCTest
import AppKit
@testable import OpenSelection

@MainActor
final class OpenSelectionMonitorTests: XCTestCase {

    private final class ResultBox: @unchecked Sendable {
        var result: SelectionResult?
    }

    nonisolated private static func textTarget(
        role: String = "AXTextField",
        selectedText: String = "sample selection",
        bounds: CGRect? = nil
    ) -> AXElementInspector.Target {
        AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: role,
            subRole: nil,
            parentRoles: [],
            containedInRoles: [],
            webArea: nil,
            selectedText: selectedText,
            selectedTextMarkerRange: nil,
            value: nil,
            selectedTextRange: nil,
            bounds: bounds
        )
    }

    func testCommandATriggersSelectionRetrieval() {
        XCTAssertTrue(OpenSelectionMonitor.isSelectionTrigger(keyCode: 0x00, flags: [.command]))
        XCTAssertFalse(OpenSelectionMonitor.isSelectionTrigger(keyCode: 0x08, flags: [.command]))
        XCTAssertFalse(OpenSelectionMonitor.isSelectionTrigger(keyCode: 0x00, flags: []))
    }

    func testCommandLTriggersSelectionRetrieval() {
        XCTAssertTrue(OpenSelectionMonitor.isSelectionTrigger(keyCode: 0x25, flags: [.command]))
        XCTAssertTrue(OpenSelectionMonitor.isSelectAllKey(keyCode: 0x25, flags: [.command]))
        XCTAssertFalse(OpenSelectionMonitor.isSelectionTrigger(keyCode: 0x25, flags: []))
        XCTAssertFalse(OpenSelectionMonitor.isSelectionTrigger(keyCode: 0x25, flags: [.command, .shift]))
    }

    func testShiftArrowAndJumpKeysTriggerSelectionRetrieval() {
        // Arrow keys
        for keyCode: UInt16 in [0x7B, 0x7C, 0x7D, 0x7E] {
            XCTAssertTrue(OpenSelectionMonitor.isSelectionTrigger(keyCode: keyCode, flags: [.shift]))
            XCTAssertTrue(OpenSelectionMonitor.isSelectionTrigger(keyCode: keyCode, flags: [.shift, .command]))
            XCTAssertTrue(OpenSelectionMonitor.isSelectionTrigger(keyCode: keyCode, flags: [.shift, .option]))
            XCTAssertFalse(OpenSelectionMonitor.isSelectionTrigger(keyCode: keyCode, flags: [.shift, .control]))
        }
        // Home / End / PageUp / PageDown
        for keyCode: UInt16 in [0x73, 0x77, 0x74, 0x79] {
            XCTAssertTrue(OpenSelectionMonitor.isSelectionTrigger(keyCode: keyCode, flags: [.shift, .function]))
            XCTAssertFalse(OpenSelectionMonitor.isSelectionTrigger(keyCode: keyCode, flags: [.function]))
        }
    }

    func testSelectionClearingKeyClassification() {
        // Navigation keys without Shift clear selection
        XCTAssertTrue(OpenSelectionMonitor.isSelectionClearingKey(keyCode: 0x7B, flags: []))
        // Editing keys clear selection
        XCTAssertTrue(OpenSelectionMonitor.isSelectionClearingKey(keyCode: 0x35, flags: [])) // Escape
        XCTAssertTrue(OpenSelectionMonitor.isSelectionClearingKey(keyCode: 0x33, flags: [])) // Delete
        // Command combinations (shortcuts) do NOT clear selection
        XCTAssertFalse(OpenSelectionMonitor.isSelectionClearingKey(keyCode: 0x08, flags: [.command])) // ⌘C
    }

    func testHoldStationaryRequiresButtonPressedAndWithinDriftLimit() {
        let down = CGPoint(x: 100, y: 100)
        // Button not pressed
        XCTAssertFalse(OpenSelectionMonitor.holdStationary(downPoint: down, pointer: down, buttonPressed: false))
        // Button pressed, exactly at down point
        XCTAssertTrue(OpenSelectionMonitor.holdStationary(downPoint: down, pointer: down, buttonPressed: true))
        // Button pressed, 1 pt drift (1^2 + 1^2 = 2 <= 4)
        XCTAssertTrue(OpenSelectionMonitor.holdStationary(downPoint: down, pointer: CGPoint(x: 101, y: 101), buttonPressed: true))
        // Button pressed, 3 pt drift (3^2 = 9 > 4)
        XCTAssertFalse(OpenSelectionMonitor.holdStationary(downPoint: down, pointer: CGPoint(x: 103, y: 100), buttonPressed: true))
    }

    func testKeyboardAnchorCalculation() {
        let mouse = CGPoint(x: 500, y: 300)
        // Select-all always anchors at mouse position
        let selectAllAnchor = OpenSelectionMonitor.keyboardAnchor(
            bounds: CGRect(x: 10, y: 10, width: 1000, height: 1000),
            isSelectAll: true,
            mouseLocation: mouse
        )
        XCTAssertEqual(selectAllAnchor, mouse)

        // Missing bounds falls back to mouse position
        let missingBoundsAnchor = OpenSelectionMonitor.keyboardAnchor(
            bounds: nil,
            isSelectAll: false,
            mouseLocation: mouse
        )
        XCTAssertEqual(missingBoundsAnchor, mouse)
    }

    func testMouseDragOver5ptThresholdTriggersSelection() async {
        let monitor = OpenSelectionMonitor(excludedBundleIDs: [])
        let dummyApp = NSRunningApplication.current
        monitor.frontmostAppProvider = { dummyApp }

        let box = ResultBox()
        monitor.onSelection = { result in
            box.result = result
        }

        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textTarget(selectedText: "dragged text", bounds: CGRect(x: 100, y: 100, width: 200, height: 20)) }
        )
        monitor.coordinator = coordinator

        // Mouse down at (100, 100)
        monitor.handleMouseDown(at: CGPoint(x: 100, y: 100))
        // Mouse up at (108, 100) -> distance dx = 8 pt (> 5 pt threshold)
        monitor.handleMouseUp(app: dummyApp, cursor: CGPoint(x: 108, y: 100), clickCount: 1)

        if let debounce = monitor.debounceTask {
            _ = await debounce.value
        }

        XCTAssertNotNil(box.result)
        XCTAssertEqual(box.result?.text, "dragged text")
    }

    func testMouseDragUnder5ptThresholdDoesNotTriggerSelection() async {
        let monitor = OpenSelectionMonitor(excludedBundleIDs: [])
        let dummyApp = NSRunningApplication.current
        monitor.frontmostAppProvider = { dummyApp }

        let box = ResultBox()
        monitor.onSelection = { result in
            box.result = result
        }

        // Mouse down at (100, 100)
        monitor.handleMouseDown(at: CGPoint(x: 100, y: 100))
        // Mouse up at (102, 102) -> distance squared = 4 + 4 = 8 <= 25 (under 5 pt threshold)
        monitor.handleMouseUp(app: dummyApp, cursor: CGPoint(x: 102, y: 102), clickCount: 1)

        if let debounce = monitor.debounceTask {
            _ = await debounce.value
        }

        XCTAssertNil(box.result, "Sub-5pt drag without multi-click must not trigger selection")
    }

    func testMultiClickTriggersSelectionEvenWithZeroDragDistance() async {
        let monitor = OpenSelectionMonitor(excludedBundleIDs: [])
        let dummyApp = NSRunningApplication.current
        monitor.frontmostAppProvider = { dummyApp }

        let box = ResultBox()
        monitor.onSelection = { result in
            box.result = result
        }

        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textTarget(selectedText: "word clicked") }
        )
        monitor.coordinator = coordinator

        // Double-click at the exact same location
        monitor.handleMouseDown(at: CGPoint(x: 100, y: 100))
        monitor.handleMouseUp(app: dummyApp, cursor: CGPoint(x: 100, y: 100), clickCount: 2)

        if let debounce = monitor.debounceTask {
            _ = await debounce.value
        }

        XCTAssertNotNil(box.result)
        XCTAssertEqual(box.result?.text, "word clicked")
    }

    func testAppExclusionFiltersOutExcludedBundleID() async {
        guard let bundleID = NSRunningApplication.current.bundleIdentifier else { return }
        let monitor = OpenSelectionMonitor(excludedBundleIDs: [bundleID])
        let dummyApp = NSRunningApplication.current
        monitor.frontmostAppProvider = { dummyApp }

        let box = ResultBox()
        monitor.onSelection = { result in
            box.result = result
        }

        monitor.handleMouseDown(at: CGPoint(x: 100, y: 100))
        monitor.handleMouseUp(app: dummyApp, cursor: CGPoint(x: 110, y: 100), clickCount: 1)

        if let debounce = monitor.debounceTask {
            _ = await debounce.value
        }

        XCTAssertNil(box.result, "Excluded bundle ID should be ignored")
    }

    func testAsyncStreamYieldsSelections() async {
        let monitor = OpenSelectionMonitor(excludedBundleIDs: [])
        let dummyApp = NSRunningApplication.current
        monitor.frontmostAppProvider = { dummyApp }

        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textTarget(selectedText: "streamed text") }
        )
        monitor.coordinator = coordinator

        let streamTask = Task<SelectionResult?, Never> {
            for await item in monitor.selections {
                return item
            }
            return nil
        }

        monitor.handleMouseDown(at: CGPoint(x: 100, y: 100))
        monitor.handleMouseUp(app: dummyApp, cursor: CGPoint(x: 120, y: 100), clickCount: 1)

        if let debounce = monitor.debounceTask {
            _ = await debounce.value
        }

        let result = await streamTask.value
        XCTAssertEqual(result?.text, "streamed text")
    }

    func testCustomSelectionTriggerYieldsResult() async {
        final class MockTrigger: SelectionTrigger {
            var handler: (@MainActor (SelectionTriggerSignal) -> Void)?
            func start(onTrigger: @escaping @MainActor (SelectionTriggerSignal) -> Void) {
                self.handler = onTrigger
            }
            func stop() {
                self.handler = nil
            }
        }

        let trigger = MockTrigger()
        let monitor = OpenSelectionMonitor(excludedBundleIDs: [])
        monitor.addTrigger(trigger)
        let dummyApp = NSRunningApplication.current
        monitor.frontmostAppProvider = { dummyApp }

        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textTarget(selectedText: "triggered text") }
        )
        monitor.coordinator = coordinator

        final class Box: @unchecked Sendable {
            var result: SelectionResult?
        }
        let box = Box()
        monitor.onSelection = { box.result = $0 }

        monitor.start()
        trigger.handler?(SelectionTriggerSignal(app: dummyApp))

        if let debounce = monitor.debounceTask {
            _ = await debounce.value
        }

        XCTAssertEqual(box.result?.text, "triggered text")
        monitor.stop()
    }
}

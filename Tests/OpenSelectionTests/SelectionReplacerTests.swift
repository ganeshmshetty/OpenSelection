// SelectionReplacerTests.swift
// OpenSelectionTests
import XCTest
import AppKit
@testable import OpenSelection

final class SelectionReplacerTests: XCTestCase {
    private var uniquePasteboardName: NSPasteboard.Name!
    private var testPasteboard: NSPasteboard!

    private final class ReplacerTestBox: @unchecked Sendable {
        var keyPosted: Bool = false
        var postedKeyCode: CGKeyCode?
        var postedFlags: CGEventFlags?
        var activated: Bool = false
        var pasteboard: NSPasteboard?
    }

    override func setUp() {
        super.setUp()
        uniquePasteboardName = NSPasteboard.Name("com.openselection.test.replacer.\(UUID().uuidString)")
        testPasteboard = NSPasteboard(name: uniquePasteboardName)
        testPasteboard.clearContents()
    }

    override func tearDown() {
        testPasteboard.releaseGlobally()
        super.tearDown()
    }

    @MainActor
    func testDirectAXReplacementSucceedsWithoutPasteboardMutation() async throws {
        testPasteboard.setString("original", forType: .string)
        let box = ReplacerTestBox()

        let dummyApp = NSRunningApplication.current
        let replacer = SelectionReplacer(
            configuration: .default,
            pasteboard: testPasteboard,
            focusedElementProvider: { _ in AXUIElementCreateSystemWide() },
            directAXReplacer: { _, _ in true },
            keyPoster: { _, _ in box.keyPosted = true },
            appActivator: { _ in }
        )

        try await replacer.replace(with: "replacement", in: dummyApp)

        XCTAssertFalse(box.keyPosted, "Direct AX replacement should not synthesize keystrokes")
        XCTAssertEqual(testPasteboard.string(forType: .string), "original", "Pasteboard should remain untouched")
    }

    @MainActor
    func testPasteboardFallbackDeliversTransientAndRestores() async throws {
        testPasteboard.setString("original", forType: .string)
        let box = ReplacerTestBox()

        let dummyApp = NSRunningApplication.current
        let config = SelectionConfiguration(
            pasteboardDeliveryRestoreDelay: 0.05,
            pasteVirtualKey: 0x09
        )

        let replacer = SelectionReplacer(
            configuration: config,
            pasteboard: testPasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: { keyCode, flags in
                box.postedKeyCode = keyCode
                box.postedFlags = flags
            },
            appActivator: { _ in box.activated = true }
        )

        try await replacer.replace(with: "transient text", in: dummyApp, restorePasteboard: true)

        XCTAssertTrue(box.activated)
        XCTAssertEqual(box.postedKeyCode, 0x09)
        XCTAssertTrue(box.postedFlags?.contains(.maskCommand) ?? false)
        XCTAssertEqual(testPasteboard.string(forType: .string), "original", "Pasteboard should be restored to original")
    }

    @MainActor
    func testPasteboardFallbackWithoutRestorePreservesWrittenContent() async throws {
        testPasteboard.setString("original", forType: .string)

        let dummyApp = NSRunningApplication.current
        let config = SelectionConfiguration(
            pasteboardDeliveryRestoreDelay: 0.05,
            pasteVirtualKey: 0x09
        )

        let replacer = SelectionReplacer(
            configuration: config,
            pasteboard: testPasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in },
            appActivator: { _ in }
        )

        try await replacer.replace(with: "permanent text", in: dummyApp, restorePasteboard: false)

        XCTAssertEqual(testPasteboard.string(forType: .string), "permanent text")
    }

    @MainActor
    func testPasteboardRestorationSkippedIfClipboardMutatedDuringDelivery() async throws {
        testPasteboard.setString("original", forType: .string)

        let dummyApp = NSRunningApplication.current
        let config = SelectionConfiguration(
            pasteboardDeliveryRestoreDelay: 0.05,
            pasteVirtualKey: 0x09
        )

        let box = ReplacerTestBox()
        box.pasteboard = testPasteboard

        let replacer = SelectionReplacer(
            configuration: config,
            pasteboard: testPasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in
                // Simulate another app writing to pasteboard immediately after key post
                box.pasteboard?.clearContents()
                box.pasteboard?.setString("user copied this mid-flight", forType: .string)
            },
            appActivator: { _ in }
        )

        try await replacer.replace(with: "transient text", in: dummyApp, restorePasteboard: true)

        XCTAssertEqual(testPasteboard.string(forType: .string), "user copied this mid-flight")
    }

    @MainActor
    func testPasteboardDeliveryWorksWithoutTargetApplication() async throws {
        let replacer = SelectionReplacer(
            configuration: SelectionConfiguration(pasteboardDeliveryRestoreDelay: 0.01),
            pasteboard: testPasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in },
            appActivator: { _ in }
        )

        try await replacer.replace(with: "no app text", in: nil, restorePasteboard: false)
        XCTAssertEqual(testPasteboard.string(forType: .string), "no app text")
    }
}

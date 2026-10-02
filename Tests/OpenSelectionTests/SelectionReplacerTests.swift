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
            appActivator: { _ in },
            targetActiveChecker: { _ in true }
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
            appActivator: { _ in box.activated = true },
            targetActiveChecker: { _ in true }
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
            appActivator: { _ in },
            targetActiveChecker: { _ in true }
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
            appActivator: { _ in },
            targetActiveChecker: { _ in true }
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
            appActivator: { _ in },
            targetActiveChecker: { _ in true }
        )

        try await replacer.replace(with: "no app text", in: nil, restorePasteboard: false)
        XCTAssertEqual(testPasteboard.string(forType: .string), "no app text")
    }

    @MainActor
    func testRichReplacementWritesMultipleTypesAndMatchStyleFlags() async throws {
        let box = ReplacerTestBox()
        let replacer = SelectionReplacer(
            configuration: SelectionConfiguration(pasteboardDeliveryRestoreDelay: 0.01),
            pasteboard: testPasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: { code, flags in
                box.postedKeyCode = code
                box.postedFlags = flags
            },
            appActivator: { _ in },
            targetActiveChecker: { _ in true }
        )

        try await replacer.replace(
            with: "Plain Text",
            html: "<p>Plain Text</p>",
            rtf: "{\\rtf1 Plain Text}",
            in: nil,
            matchStyle: true,
            restorePasteboard: false
        )

        XCTAssertEqual(testPasteboard.string(forType: .string), "Plain Text")
        XCTAssertEqual(testPasteboard.string(forType: .html), "<p>Plain Text</p>")
        XCTAssertNotNil(testPasteboard.data(forType: .rtf))
        XCTAssertTrue(box.postedFlags?.contains(.maskAlternate) ?? false)
        XCTAssertTrue(box.postedFlags?.contains(.maskShift) ?? false)
        XCTAssertTrue(box.postedFlags?.contains(.maskCommand) ?? false)
    }

    @MainActor
    func testRichReplacementPreservesHighBitRTFBytes() async throws {
        let replacer = SelectionReplacer(
            configuration: SelectionConfiguration(pasteboardDeliveryRestoreDelay: 0.01),
            pasteboard: testPasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in },
            appActivator: { _ in },
            targetActiveChecker: { _ in true }
        )

        // ISO Latin-1 bytes that are not valid UTF-8: they must survive the String bridge intact.
        let rtf = "{\\rtf1 caf\u{00E9}}"

        try await replacer.replace(with: "Plain", rtf: rtf, in: nil, restorePasteboard: false)

        let written = try XCTUnwrap(testPasteboard.data(forType: .rtf))
        XCTAssertEqual(String(data: written, encoding: .isoLatin1), rtf)
    }

    @MainActor
    func testReplacementWritesFlavorsVerbatim() async throws {
        let replacer = SelectionReplacer(
            configuration: SelectionConfiguration(pasteboardDeliveryRestoreDelay: 0.01),
            pasteboard: testPasteboard,
            directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in },
            appActivator: { _ in },
            targetActiveChecker: { _ in true }
        )
        let proprietaryType = NSPasteboard.PasteboardType("com.apple.notes.richtext")
        let proprietaryData = Data([0x00, 0x01, 0xFE, 0xFF])
        let flavors = [
            PasteboardFlavor(type: "public.rtf", data: Data("{\\rtf1 x}".utf8)),
            PasteboardFlavor(type: proprietaryType.rawValue, data: proprietaryData)
        ]

        // Plain text is ignored when flavors are supplied: the captured representations are the source of truth.
        try await replacer.replace(with: "ignored", flavors: flavors, in: nil, restorePasteboard: false)

        XCTAssertEqual(testPasteboard.data(forType: proprietaryType), proprietaryData)
        XCTAssertEqual(testPasteboard.data(forType: .rtf), Data("{\\rtf1 x}".utf8))
    }

    @MainActor
    func testFormattedTextAndMetricsReconstructParagraphsFromHTML() {
        let singleLineText = "Paragraph 1 Paragraph 2"
        let html = "<p>Paragraph 1</p><p>Paragraph 2</p>"
        let result = SelectionResult(text: singleLineText, html: html)

        let formatted = result.formattedText
        XCTAssertTrue(formatted.contains("\n"), "Formatted text should restore newlines from HTML")

        let metrics = result.metrics
        XCTAssertGreaterThanOrEqual(metrics.paragraphs, 2, "Should recognize multiple paragraphs from HTML")
        XCTAssertEqual(metrics.words, 4)
    }

    @MainActor
    func testFormattedTextReconstructsParagraphsFromRTFWhenHTMLMissing() {
        let singleLineText = "Paragraph 1 Paragraph 2"
        let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 Paragraph 1\\par Paragraph 2}"
        let result = SelectionResult(text: singleLineText, rtf: rtf)

        let formatted = result.formattedText
        XCTAssertNotEqual(formatted, singleLineText, "Formatted text should be reconstructed from RTF")
        XCTAssertTrue(formatted.contains("\n"), "Formatted text should restore paragraph breaks from RTF")
        XCTAssertGreaterThanOrEqual(result.metrics.paragraphs, 2)
    }
    @MainActor
    func testRapidPastesConsumeTheirOwnPayloadsDuringDeliveryWindows() async throws {
        let board = testPasteboard!
        board.setString("original", forType: .string)
        let firstPosted = expectation(description: "first paste posted")
        let consumed = expectation(description: "both external pastes consumed")
        consumed.expectedFulfillmentCount = 2
        var payloads: [String] = []
        var posts = 0
        let replacer = SelectionReplacer(
            configuration: SelectionConfiguration(pasteboardDeliveryRestoreDelay: 0.06),
            pasteboard: board, focusedElementProvider: { _ in nil },
            directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in
                posts += 1
                if posts == 1 { firstPosted.fulfill() }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    payloads.append(board.string(forType: .string) ?? "missing")
                    consumed.fulfill()
                }
            }, appActivator: { _ in }, targetActiveChecker: { _ in true }
        )
        let first = Task { try await replacer.replace(with: "one", in: .current) }
        await fulfillment(of: [firstPosted], timeout: 1)
        let second = Task { try await replacer.replace(with: "two", in: .current) }
        try await first.value
        try await second.value
        await fulfillment(of: [consumed], timeout: 1)
        XCTAssertEqual(payloads, ["one", "two"])
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    @MainActor
    func testFailedActivationLeavesBaselineAndDoesNotPost() async {
        testPasteboard.setString("original", forType: .string)
        let baselineCount = testPasteboard.changeCount
        var posted = false
        let replacer = SelectionReplacer(pasteboard: testPasteboard,
            focusedElementProvider: { _ in nil }, directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in posted = true }, appActivator: { _ in },
            targetActiveChecker: { _ in false })
        do {
            try await replacer.replace(with: "payload", in: .current)
            XCTFail("Expected target failure")
        } catch { }
        XCTAssertFalse(posted)
        XCTAssertEqual(testPasteboard.changeCount, baselineCount)
        XCTAssertEqual(testPasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testCancelledCaptureDrainsPostedCopyBeforePaste() async throws {
        let board = testPasteboard!
        board.setString("original", forType: .string)
        let copyPosted = expectation(description: "copy posted")
        var pasted: String?
        let capture = Task { @MainActor in
            await PasteboardCopyEngine(isCopyAuthorized: { true }).capture(pasteboard: board, timeout: 0.15) {
                copyPosted.fulfill()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    board.clearContents(); board.setString("late copy", forType: .string)
                }
            }
        }
        await fulfillment(of: [copyPosted], timeout: 1)
        capture.cancel()
        let replacer = SelectionReplacer(
            configuration: SelectionConfiguration(pasteboardDeliveryRestoreDelay: 0.03),
            pasteboard: board, focusedElementProvider: { _ in nil },
            directAXReplacer: { _, _ in false },
            keyPoster: { _, _ in pasted = board.string(forType: .string) },
            appActivator: { _ in }, targetActiveChecker: { _ in true })
        try await replacer.replace(with: "paste payload", in: .current)
        let captured = await capture.value
        XCTAssertNil(captured)
        XCTAssertEqual(pasted, "paste payload")
        XCTAssertEqual(board.string(forType: .string), "original")
    }

}

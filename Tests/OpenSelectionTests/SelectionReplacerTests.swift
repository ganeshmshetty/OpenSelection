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
            appActivator: { _ in }
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
            appActivator: { _ in }
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
            appActivator: { _ in }
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
}

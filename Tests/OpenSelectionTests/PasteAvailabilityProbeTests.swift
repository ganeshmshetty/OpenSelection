// PasteAvailabilityProbeTests.swift
// OpenSelectionTests
import XCTest
import AppKit
@testable import OpenSelection

final class PasteAvailabilityProbeTests: XCTestCase {

    func testPasteMatchByNonEnglishTitle_WhenNoCommandEquivalent() {
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "Coller", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "Einfügen", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "Pegar", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "уметни", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "umetni", cmdChar: nil, cmdCharModifiers: nil))
    }

    func testPasteMatchByCJKTitle() {
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "粘贴", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: "붙여넣기", cmdChar: nil, cmdCharModifiers: nil))
    }

    func testPasteMatchByCommandEquivalent() {
        // Shift modifier should be rejected
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: "포함", cmdChar: "V", cmdCharModifiers: UInt(AXMenuItemModifiers.shift.rawValue)))
        // Plain Command+V matches
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: nil, cmdChar: "V", cmdCharModifiers: 0))
        XCTAssertTrue(PasteAvailabilityProbe.isPaste(title: nil, cmdChar: "v", cmdCharModifiers: 0))
    }

    func testNonPasteItemsAreRejected() {
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: "Copier", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: "Copy", cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: nil, cmdChar: nil, cmdCharModifiers: nil))
        XCTAssertFalse(PasteAvailabilityProbe.isPaste(title: "Cut", cmdChar: "X", cmdCharModifiers: UInt(AXMenuItemModifiers.control.rawValue)))
    }

    @MainActor
    func testCanPasteHonorsPolicyDenyPaste() async {
        let probe = PasteAvailabilityProbe(lookup: { _ in true })
        let policy = SelectionPolicy(denyPaste: true)
        let canPaste = await probe.canPaste(in: NSRunningApplication.current, policy: policy)
        XCTAssertEqual(canPaste, false)
    }

    @MainActor
    func testCanPasteReturnsLookupResult() async {
        let probe = PasteAvailabilityProbe(lookup: { _ in true })
        let canPaste = await probe.canPaste(in: NSRunningApplication.current, policy: .default)
        XCTAssertEqual(canPaste, true)
    }

    func testProbePasteRespectsDeadlineWatchdog() async {
        let probe = PasteAvailabilityProbe(
            lookupWithDeadline: { _, deadline in
                Thread.sleep(forTimeInterval: 0.1)
                return true
            },
            timeout: 0.02
        )
        let result = await probe.probePaste(pid: 12345)
        XCTAssertNil(result, "Exceeded deadline must yield nil")
    }
}

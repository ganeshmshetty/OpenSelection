import XCTest
import Foundation
import CoreGraphics
import ApplicationServices
@testable import OpenSelection

final class AXWebAreaStrategyTests: XCTestCase {

    private func target(
        webArea: AXUIElement? = nil,
        selectedText: String? = nil,
        selectedTextMarkerRange: AnyObject? = nil,
        bounds: CGRect? = nil
    ) -> AXElementInspector.Target {
        AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: webArea,
            role: "AXWebArea",
            subRole: nil,
            parentRoles: [],
            containedInRoles: [],
            webArea: webArea,
            selectedText: selectedText,
            selectedTextMarkerRange: selectedTextMarkerRange,
            value: nil,
            selectedTextRange: nil,
            bounds: bounds
        )
    }

    func testReadFallsBackToSelectedTextWhenMarkerRangeIsNotAnAXMarker() {
        let bounds = CGRect(x: 1, y: 2, width: 80, height: 20)
        let result = AXWebAreaStrategy.read(from: target(
            webArea: AXUIElementCreateSystemWide(),
            selectedText: "selected web text",
            selectedTextMarkerRange: "not-a-marker" as NSString,
            bounds: bounds
        ))

        XCTAssertEqual(result?.text, "selected web text")
        XCTAssertEqual(result?.bounds, bounds)
    }

    func testReadReturnsNilWhenMarkerRangeIsNotAnAXMarkerAndNoSelectedText() {
        let result = AXWebAreaStrategy.read(from: target(
            selectedText: nil,
            selectedTextMarkerRange: "not-a-marker" as NSString
        ))

        XCTAssertNil(result)
    }

    func testReadUsesSelectedTextWhenNoMarkerRange() {
        let result = AXWebAreaStrategy.read(from: target(
            selectedText: "plain fallback",
            selectedTextMarkerRange: nil
        ))

        XCTAssertEqual(result?.text, "plain fallback")
    }

    func testReadReturnsNilWhenTextIsEmpty() {
        let result = AXWebAreaStrategy.read(from: target(
            selectedText: "",
            selectedTextMarkerRange: nil
        ))

        XCTAssertNil(result)
    }
}

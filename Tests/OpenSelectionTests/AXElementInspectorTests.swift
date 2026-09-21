import XCTest
import ApplicationServices
import CoreGraphics
@testable import OpenSelection

final class AXElementInspectorTests: XCTestCase {
    func testTargetMemberwiseInitBuildsFullyPopulatedFixture() {
        let target = AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: "AXTextField",
            subRole: "AXSearchField",
            parentRoles: ["AXGroup", "AXWindow"],
            containedInRoles: ["AXWindow", "AXScrollArea"],
            webArea: nil,
            selectedText: "hello",
            selectedTextMarkerRange: nil,
            value: "hello",
            selectedTextRange: nil,
            bounds: CGRect(x: 1, y: 2, width: 30, height: 4)
        )

        XCTAssertEqual(target.role, "AXTextField")
        XCTAssertEqual(target.subRole, "AXSearchField")
        XCTAssertEqual(target.parentRoles, ["AXGroup", "AXWindow"])
        XCTAssertEqual(target.containedInRoles, ["AXWindow", "AXScrollArea"])
        XCTAssertEqual(target.selectedText, "hello")
        XCTAssertEqual(target.value, "hello")
        XCTAssertEqual(target.bounds, CGRect(x: 1, y: 2, width: 30, height: 4))
        XCTAssertNil(target.focusedApp)
        XCTAssertNil(target.focusedElement)
        XCTAssertNil(target.webArea)
        XCTAssertNil(target.selectedTextMarkerRange)
        XCTAssertNil(target.selectedTextRange)
    }

    func testTargetMemberwiseInitBuildsEmptyFixture() {
        let target = AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: nil,
            subRole: nil,
            parentRoles: [],
            containedInRoles: [],
            webArea: nil,
            selectedText: nil,
            selectedTextMarkerRange: nil,
            value: nil,
            selectedTextRange: nil,
            bounds: nil
        )

        XCTAssertNil(target.role)
        XCTAssertNil(target.subRole)
        XCTAssertTrue(target.parentRoles.isEmpty)
        XCTAssertTrue(target.containedInRoles.isEmpty)
        XCTAssertNil(target.selectedText)
        XCTAssertNil(target.value)
        XCTAssertNil(target.bounds)
    }

    func testAncestorWalkDepthIsBounded() {
        XCTAssertEqual(AXElementInspector.ancestorWalkDepth, 25)
    }

    func testWindowWebAreaSearchSkippedWhenFocusIsNativeTextControl() {
        // Apple Notes: focus is an AXTextArea outside any web area. Searching its window overran
        // the inspect deadline, so the popup never appeared.
        for role in ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"] {
            XCTAssertFalse(AXElementInspector.shouldSearchWindowForWebArea(focusedRole: role, webArea: nil), role)
        }
    }

    func testWindowWebAreaSearchRunsWhenFocusIsAtContainerLevel() {
        // Static page text selected in a browser leaves focus on the window/a group.
        XCTAssertTrue(AXElementInspector.shouldSearchWindowForWebArea(focusedRole: "AXWindow", webArea: nil))
        XCTAssertTrue(AXElementInspector.shouldSearchWindowForWebArea(focusedRole: "AXGroup", webArea: nil))
        XCTAssertTrue(AXElementInspector.shouldSearchWindowForWebArea(focusedRole: nil, webArea: nil))
    }

    func testWindowWebAreaSearchSkippedWhenWebAreaAlreadyResolved() {
        let webArea = AXUIElementCreateApplication(500)
        XCTAssertFalse(AXElementInspector.shouldSearchWindowForWebArea(focusedRole: "AXGroup", webArea: webArea))
    }

    func testFindFirstChildFindsNestedRole() {
        let child = AXUIElementCreateApplication(300)
        let parent = AXUIElementCreateApplication(400)

        let found = AXElementInspector.findFirstChild(
            role: "AXWebArea",
            in: parent,
            maxDepth: 3,
            read: { element, attribute in
                if CFEqual(element, parent), attribute == kAXChildrenAttribute {
                    return [child] as NSArray
                }
                if CFEqual(element, child), attribute == kAXRoleAttribute {
                    return "AXWebArea" as NSString
                }
                return nil
            }
        )
        XCTAssertNotNil(found)
        if let found {
            XCTAssertTrue(CFEqual(found, child))
        }
    }

    func testSelectedTextMarkerRangeFallsBackToWebAreaWhenFocusedElementExposesNoMarker() {
        let focusedEl = AXUIElementCreateApplication(100)
        let webAreaEl = AXUIElementCreateApplication(200)
        let dummyWebMarker = "webarea-marker-range" as NSString

        let fromWebArea = AXElementInspector.selectedTextMarkerRange(
            focusedElement: focusedEl,
            webArea: webAreaEl,
            read: { element, attribute in
                if CFEqual(element, webAreaEl), attribute == AXElementInspector.selectedTextMarkerRangeAttribute {
                    return dummyWebMarker
                }
                return nil
            }
        )
        XCTAssertNotNil(fromWebArea)
    }
}

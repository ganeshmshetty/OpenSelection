import XCTest
import ApplicationServices
@testable import OpenSelection

final class AXMenuNavigatorTests: XCTestCase {
    func testCopyMatchesExpectedIdentifiersAndShortcuts() {
        XCTAssertTrue(AXMenuNavigator.matches(.copy, title: "Copy", identifier: "copy:", cmdChar: "c", cmdModifiers: 0))
        XCTAssertTrue(AXMenuNavigator.matches(.copy, title: "Copy", identifier: nil, cmdChar: "c", cmdModifiers: 0))
        XCTAssertTrue(AXMenuNavigator.matches(.copy, title: "拷贝", identifier: nil, cmdChar: nil, cmdModifiers: nil))
        XCTAssertTrue(AXMenuNavigator.matches(.copy, title: "Copier", identifier: nil, cmdChar: nil, cmdModifiers: nil))
        XCTAssertTrue(AXMenuNavigator.matches(.copy, title: "Kopieren", identifier: nil, cmdChar: nil, cmdModifiers: nil))
        XCTAssertFalse(AXMenuNavigator.matches(.copy, title: "Paste", identifier: "paste:", cmdChar: "v", cmdModifiers: 0))
    }

    func testPasteMatchesExpectedIdentifiersAndShortcuts() {
        XCTAssertTrue(AXMenuNavigator.matches(.paste, title: "Paste", identifier: "paste:", cmdChar: "v", cmdModifiers: 0))
        XCTAssertTrue(AXMenuNavigator.matches(.paste, title: "Paste", identifier: nil, cmdChar: "v", cmdModifiers: 0))
        XCTAssertTrue(AXMenuNavigator.matches(.paste, title: "粘贴", identifier: nil, cmdChar: nil, cmdModifiers: nil))
        XCTAssertTrue(AXMenuNavigator.matches(.paste, title: "Coller", identifier: nil, cmdChar: nil, cmdModifiers: nil))
        XCTAssertTrue(AXMenuNavigator.matches(.paste, title: "Einfügen", identifier: nil, cmdChar: nil, cmdModifiers: nil))
        XCTAssertFalse(AXMenuNavigator.matches(.paste, title: "Copy", identifier: "copy:", cmdChar: "c", cmdModifiers: 0))
    }

    func testNilElementReturnsNil() {
        XCTAssertNil(AXMenuNavigator.findMenuItem(.copy, in: nil))
        XCTAssertFalse(AXMenuNavigator.press(.copy, in: nil))
    }
}

import XCTest
import AppKit
@testable import OpenSelection

final class OpenSelectionFacadeTests: XCTestCase {
    func testPluggableLoggerInvoked() async {
        final class LogAccumulator: @unchecked Sendable {
            var messages: [String] = []
            let lock = NSLock()
            func add(_ msg: String) {
                lock.lock()
                defer { lock.unlock() }
                messages.append(msg)
            }
        }

        let accumulator = LogAccumulator()
        OpenSelection.logger = { msg in
            accumulator.add(msg)
        }
        defer { OpenSelection.logger = nil }

        OpenSelectionLogging.log("Test log entry")
        XCTAssertEqual(accumulator.messages, ["Test log entry"])
    }

    func testSelectionConfigurationDefaults() {
        let config = SelectionConfiguration.default
        XCTAssertEqual(config.axReadTimeout, 0.5)
        XCTAssertEqual(config.pasteboardCopyTimeout, 0.25)
        XCTAssertEqual(config.safariPasteboardCopyTimeout, 0.4)
        XCTAssertEqual(config.webAreaSettleMaxRetries, 6)
        XCTAssertEqual(config.webAreaSettleInterval, 0.05)
        XCTAssertEqual(config.pasteboardRestoreDelay, 0.01)
        XCTAssertEqual(config.copyVirtualKey, 0x08)
    }

    func testSelectionResultInitAndProperties() {
        let result = SelectionResult(
            text: "test selection",
            bounds: CGRect(x: 10, y: 20, width: 100, height: 20),
            html: "<b>test</b>",
            rtf: "rtf_data",
            sourceApp: nil,
            strategy: .keyboardCopy,
            isEditable: true
        )

        XCTAssertEqual(result.text, "test selection")
        XCTAssertEqual(result.bounds, CGRect(x: 10, y: 20, width: 100, height: 20))
        XCTAssertEqual(result.html, "<b>test</b>")
        XCTAssertEqual(result.rtf, "rtf_data")
        XCTAssertEqual(result.strategy, .keyboardCopy)
        XCTAssertTrue(result.isEditable)
    }

    func testSelectionGatePolicyDefaults() {
        let policy = SelectionGatePolicy.default
        XCTAssertTrue(policy.skipRoles.contains("AXButton"))
        XCTAssertTrue(policy.skipRoles.contains("AXScrollBar"))
        XCTAssertTrue(policy.allowedCursors.contains(.beam))
        XCTAssertTrue(policy.allowedCursors.contains(.arrow))
    }

    func testTextSanitizer() {
        XCTAssertEqual(TextSanitizer.sanitize("  hello  \n"), "hello")
        XCTAssertEqual(TextSanitizer.sanitize("\u{200B}trimmed\u{FEFF}"), "trimmed")
        XCTAssertNil(TextSanitizer.sanitize("   \t  \n"))
        XCTAssertTrue(TextSanitizer.isSubstantial("a"))
        XCTAssertFalse(TextSanitizer.isSubstantial("   \u{200B} "))
    }
}

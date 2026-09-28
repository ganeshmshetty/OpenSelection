import XCTest
import AppKit
@testable import OpenSelection

@MainActor
final class AutomaticCopyCaptureTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("com.openselection.tests.automatic-copy.\(UUID().uuidString)"))
        board.setString("Original clipboard", forType: .string)
        return board
    }

    func testUnavailableCopyDoesNotTriggerOrTouchClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let result = await AutomaticCopyCapture.capture(
            trigger: { XCTFail("An unavailable Copy command must never be triggered") },
            pasteboard: board,
            frontmostPID: { 42 },
            copyAvailable: { _ in false },
            overlayPresent: { false }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testEnabledCopyCapturesAndRestoresClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let result = await AutomaticCopyCapture.capture(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            pasteboard: board,
            frontmostPID: { 42 },
            copyAvailable: { pid in
                XCTAssertEqual(pid, 42)
                return true
            },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testAppSwitchDuringProbeDoesNotCopyIntoNewApp() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        var pid: pid_t = 42
        let result = await AutomaticCopyCapture.capture(
            trigger: { XCTFail("The old gesture must not send Copy to the new app") },
            pasteboard: board,
            frontmostPID: { pid },
            copyAvailable: { _ in
                pid = 43
                return true
            },
            overlayPresent: { false }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testCancellationDuringProbeDoesNotTriggerCopy() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let task = Task { @MainActor in
            await AutomaticCopyCapture.capture(
                trigger: { XCTFail("A cancelled gesture must not trigger Copy") },
                pasteboard: board,
                frontmostPID: { 42 },
                copyAvailable: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                overlayPresent: { false }
            )
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    func testEnabledCopyStillRespectsForeignOverlayGate() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let result = await AutomaticCopyCapture.capture(
            trigger: { XCTFail("An overlay must not receive the copy shortcut") },
            pasteboard: board,
            frontmostPID: { 42 },
            copyAvailable: { _ in true },
            overlayPresent: { true }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
    }
}

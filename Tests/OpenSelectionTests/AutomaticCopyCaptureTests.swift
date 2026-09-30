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

    func testDisabledMenuWithWeakEvidenceDoesNotTriggerOrTouchClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        let request = CopyRequest(
            trigger: { XCTFail("A disabled Copy command with weak evidence must never be triggered") },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .disabled },
            overlayPresent: { false }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testStrongEvidenceProceedsEvenIfMenuIsDisabled() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-strong", .strong)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in
                XCTFail("Menu probe must NOT be consulted for strong evidence")
                return .disabled
            },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testEnabledMenuCapturesAndRestoresClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { pid in
                XCTAssertEqual(pid, 42)
                return .enabled
            },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testUnknownMenuStateProceedsWithWeakEvidence() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.timeout) },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testNoCopyItemMenuStateProceedsWithWeakEvidence() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.noCopyItem) },
            overlayPresent: { false }
        )
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testNoMenuBarMenuStateProceedsWithWeakEvidence() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.noMenuBar) },
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
        let request = CopyRequest(
            trigger: { XCTFail("The old gesture must not send Copy to the new app") },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { pid },
            menuState: { _ in
                pid = 43
                return .enabled
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
            let request = CopyRequest(
                trigger: { XCTFail("A cancelled gesture must not trigger Copy") },
                evidence: CopyEvidence("test-weak", .weak)
            )
            return await AutomaticCopyCapture.capture(
                request: request,
                pasteboard: board,
                frontmostPID: { 42 },
                menuState: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .enabled
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
        let request = CopyRequest(
            trigger: { XCTFail("An overlay must not receive the copy shortcut") },
            evidence: CopyEvidence("test-weak", .weak)
        )
        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .enabled },
            overlayPresent: { true }
        )
        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, changeCount)
    }
}

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

    func testStrongAXEvidenceBypassesStrictWeakMenuRequirement() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("ax-selected-text", .strong),
            requiresEnabledCopyMenu: true
        )

        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in
                XCTFail("Strong selected-text evidence must bypass the menu probe")
                return .unknown(.timeout)
            },
            overlayPresent: { false }
        )

        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(triggers, 1)
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

    func testStrictWeakEvidenceRequiresEnabledMenuBeforeTouchingClipboard() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let changeCount = board.changeCount
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                XCTFail("Unknown menu state must not trigger copy for automatic retrieval")
            },
            evidence: CopyEvidence("ax-text-control", .weak),
            requiresEnabledCopyMenu: true
        )

        let response = await AutomaticCopyCapture.captureResponse(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .unknown(.timeout) },
            overlayPresent: { false }
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.status, .copyBlocked)
        XCTAssertEqual(triggers, 0)
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testStrictWeakEvidenceStillRunsWhenMenuEnabled() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        var triggers = 0
        let request = CopyRequest(
            trigger: {
                triggers += 1
                board.clearContents()
                board.setString("Selected text", forType: .string)
            },
            evidence: CopyEvidence("ax-text-control", .weak),
            requiresEnabledCopyMenu: true
        )

        let result = await AutomaticCopyCapture.capture(
            request: request,
            pasteboard: board,
            frontmostPID: { 42 },
            menuState: { _ in .enabled },
            overlayPresent: { false }
        )

        XCTAssertEqual(result?.text, "Selected text")
        XCTAssertEqual(triggers, 1)
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    func testIssue159CoordinatorEmptyTextFieldWithUnknownMenuNeverCopies() async {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let originalChangeCount = board.changeCount
        let boardBox = PasteboardBox(board)
        let configuration = SelectionConfiguration(evidenceSettleMaxRetries: 0)
        let target = AXElementInspector.Target(role: "AXTextArea")
        let coordinator = SelectionRetrievalCoordinator(
            configuration: configuration,
            inspect: { target },
            detailedCopyCapture: { request in
                await AutomaticCopyCapture.captureResponse(
                    configuration: configuration,
                    request: request,
                    pasteboard: boardBox.pasteboard,
                    frontmostPID: { 42 },
                    menuState: { _ in .unknown(.timeout) },
                    overlayPresent: { false }
                )
            }
        )

        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.Outlook"),
            policy: SelectionPolicy(strategy: .keyboardCopy),
            cursor: .unknown,
            trigger: .doubleClick
        )

        XCTAssertNil(result)
        XCTAssertEqual(board.changeCount, originalChangeCount)
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

    func testCopyMenuProbeEnforcesDeadlineWhenWorkerBlocks() async {
        let probe = CopyMenuProbe()
        let start = Date()
        let result = await probe.run(hardLimit: 0.05, fallback: "fallback") {
            Thread.sleep(forTimeInterval: 0.5)
            return "finished"
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, "fallback")
        XCTAssertLessThan(elapsed, 0.25, "watchdog must enforce deadline even if worker blocks queue")
    }
    func testCopyMenuWorkerRetainsPermitAfterDeadline() async {
        let probe = CopyMenuProbe()
        probe.maxConcurrent = 1
        let unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() }
        let first = await probe.run(hardLimit: 0.03, fallback: false) {
            unblock.wait()
            return true
        }
        XCTAssertFalse(first)
        let capped = await probe.run(hardLimit: 0.03, fallback: false) {
            XCTFail("A timed-out worker must retain its permit")
            return true
        }
        XCTAssertFalse(capped)
        unblock.signal()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let recovered = await probe.run(hardLimit: 0.1, fallback: false) { true }
        XCTAssertTrue(recovered)
    }

}

private final class PasteboardBox: @unchecked Sendable {
    let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }
}

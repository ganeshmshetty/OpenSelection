import XCTest
import AppKit
import ApplicationServices
@testable import OpenSelection

final class SelectionReadResponseTests: XCTestCase {
    func testEmptyNativeReadIsDistinctFromCopyBlocked() async {
        let reader = SelectionRetrievalCoordinator(inspect: { _ in
            AXElementInspector.Target(role: "AXTextField", selectedText: "")
        })
        let native = await reader.retrieveResponse(allowCopyFallback: false)
        XCTAssertNil(native.result)
        XCTAssertEqual(native.status, .copyBlocked)
        let response = await reader.retrieveResponse(
            for: AppIdentity(bundleIdentifier: "com.apple.TextEdit"), allowCopyFallback: false)
        XCTAssertEqual(response.status, .noSelection)
    }

    func testDisabledPolicyIsExplainedWithoutInspecting() async {
        let reader = SelectionRetrievalCoordinator(inspect: { _ in
            XCTFail("Disabled read must not inspect"); return AXElementInspector.Target()
        })
        let response = await reader.retrieveResponse(policy: SelectionPolicy(disabled: true))
        XCTAssertEqual(response.status, .policyBlocked)
    }

    func testInspectionTimeoutHasStableReason() async {
        let reader = SelectionRetrievalCoordinator(
            configuration: SelectionConfiguration(axReadTimeout: 0.01),
            inspect: { _ in Thread.sleep(forTimeInterval: 0.08); return AXElementInspector.Target() })
        let response = await reader.retrieveResponse()
        XCTAssertNil(response.result)
        XCTAssertEqual(response.status, .timedOut)
    }

    func testCancellationBeforeReadIsExplained() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await SelectionRetrievalCoordinator().retrieveResponse()
        }
        let response = await task.value
        XCTAssertEqual(response.status, .cancelled)
    }

    func testCopyFailureSurvivesCompatibilityBoundary() async {
        let reader = SelectionRetrievalCoordinator(
            inspect: { _ in AXElementInspector.Target() },
            detailedCopyCapture: { _ in .init(status: .copyBlocked) })
        let response = await reader.retrieveResponse()
        XCTAssertEqual(response.status, .copyBlocked)
        XCTAssertNil(response.result)
    }

    func testChangedInspectedProcessIsExplained() async {
        let reader = SelectionRetrievalCoordinator(inspect: { _ in
            AXElementInspector.Target(focusedApp: AXUIElementCreateApplication(getpid()))
        })
        let response = await reader.retrieveResponse(for: AppIdentity(processIdentifier: getpid() + 1))
        XCTAssertEqual(response.status, .targetChanged)
    }

    func testReportContainsReasonWithoutSelectedText() async throws {
        let trace = SelectionTrace.create(trigger: .programmatic)
        let reader = SelectionRetrievalCoordinator(inspect: { _ in
            AXElementInspector.Target(role: "AXTextField", selectedText: "PRIVATE_CANARY")
        })
        let response = await reader.retrieveResponse(allowCopyFallback: false, trace: trace)
        XCTAssertEqual(response.status, .selection)
        let report = trace.buildReport(outcome: .none)
        XCTAssertEqual(report.readStatus, .selection)
        let data = try JSONEncoder().encode(report)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE_CANARY"))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "readStatus")
        old.removeValue(forKey: "metrics")
        old.removeValue(forKey: "clipboardRestored")
        let decoded = try JSONDecoder().decode(CascadeReport.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.readStatus)
    }

    @MainActor
    func testCaptureSummaryRecordsActualRestorationAndTiming() async {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let trace = SelectionTrace.create(trigger: .dragEnd)
        let response = await SelectionTrace.$current.withValue(trace) {
            await PasteboardCopyEngine(isCopyAuthorized: { true }).captureResponse(pasteboard: board) {
                board.clearContents()
                board.setString("selection", forType: .string)
            }
        }
        XCTAssertEqual(response.status, .selection)
        XCTAssertEqual(board.string(forType: .string), "original")
        let report = trace.buildReport(outcome: .selection(strategy: .keyboardCopy, presence: .nonEmpty))
        XCTAssertEqual(report.clipboardRestored, true)
        XCTAssertNotNil(report.metrics?["copyCaptureMicros"])
        let blockedTrace = SelectionTrace.create(trigger: .dragEnd)
        _ = await SelectionTrace.$current.withValue(blockedTrace) {
            await PasteboardCopyEngine(isCopyAuthorized: { false }).captureResponse(pasteboard: board) {}
        }
        XCTAssertNil(blockedTrace.buildReport(outcome: .none).clipboardRestored)
    }

    @MainActor
    func testCopyTimeoutAndAuthorizationDenialAreDistinct() async {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let blocked = await PasteboardCopyEngine(isCopyAuthorized: { false })
            .captureResponse(pasteboard: board, timeout: 0.01) { XCTFail("Must not post") }
        XCTAssertEqual(blocked.status, .copyBlocked)
        let timeout = await PasteboardCopyEngine(isCopyAuthorized: { true })
            .captureResponse(pasteboard: board, timeout: 0.01) {}
        XCTAssertEqual(timeout.status, .timedOut)
    }

    @MainActor
    func testUserCopyWhileCapturePendingPreservesUserClipboardAndReason() async {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var physicalCopy = false
        var engine = PasteboardCopyEngine(isCopyAuthorized: { true })
        engine.userCopyObserved = { physicalCopy }
        let response = await engine.captureResponse(pasteboard: board, timeout: 0.05) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000)
                physicalCopy = true
                board.clearContents()
                board.setString("user copy", forType: .string)
            }
        }
        XCTAssertEqual(response.status, .copyBlocked)
        XCTAssertNil(response.result)
        XCTAssertEqual(board.string(forType: .string), "user copy")
    }

    @MainActor
    func testSwitchDuringMenuReadDoesNotPostCopy() async {
        var pid: pid_t? = 123
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        let response = await AutomaticCopyCapture.captureResponse(
            request: CopyRequest(trigger: { XCTFail("Stale target must not receive copy") },
                                 evidence: CopyEvidence("test", .weak)),
            pasteboard: board, frontmostPID: { pid },
            menuState: { _ in pid = 456; return .enabled },
            overlayPresent: { false })
        XCTAssertEqual(response.status, .targetChanged)
    }
}

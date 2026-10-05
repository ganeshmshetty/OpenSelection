// DeadlineBoundingTests.swift
// OpenSelectionTests
//
// Regression tests for watchdog-deadline-bounded AX workers.
//
// Symptom: selection works windowed, works briefly in native fullscreen (green-button
// Space) for Chromium/Electron apps, then the popup never appears again until fullscreen
// is exited or the process restarts.
//
// Cause: AX inspect workers issued unbounded sequential IPC with no per-call messaging
// timeout and no deadline checks, so a stalled fullscreen renderer parked each worker
// far past the watchdog. The concurrency-gate permit is (deliberately — see the
// retain-permit tests) released only when the worker exits, so a few slow inspects
// saturated the static gates and every later retrieval failed `busy`: a self-inflicted
// permanent outage.
//
// Fix: the trace carries a per-attempt AX deadline (refreshed to a fresh watchdog-sized
// budget by every inspect attempt); `AXElementInspector` skips new IPC past it and caps
// per-call messaging timeouts to the remaining budget, and `AXMenuNavigator` caps its
// per-call timeouts the same way. Workers now exit near the deadline, permits recycle,
// and the gate degrades transiently instead of wedging.
import XCTest
import ApplicationServices
import Foundation
import os
@testable import OpenSelection

final class DeadlineBoundingTests: XCTestCase {

    /// Past the deadline no AX IPC may be issued at all: inspect returns an empty target
    /// immediately instead of walking the accessibility tree.
    func testExpiredDeadlineSkipsAXInspect() {
        let trace = SelectionTrace.create(trigger: .programmatic)
        trace.refreshDeadline(Date().addingTimeInterval(-1))
        let start = Date()
        let target = AXElementInspector.inspect(trace: trace)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "expired deadline must skip AX IPC")
        XCTAssertNil(target.focusedApp)
        XCTAssertNil(target.focusedElement)
        XCTAssertNil(target.role)
        XCTAssertNil(target.selectedText)
        XCTAssertNil(target.webArea)
    }

    /// A menu probe with an expired deadline reports `.timedOut` without touching AX.
    func testExpiredDeadlineTimesOutMenuProbe() {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let outcome = AXMenuNavigator.probeMenuItem(
            .copy,
            in: app,
            matchingShortcutOnly: true,
            timeout: 0.5,
            deadline: Date().addingTimeInterval(-1)
        )
        guard case .timedOut = outcome else {
            return XCTFail("expired deadline must time out without issuing AX, got \(outcome)")
        }
    }

    /// The trace budget API: absent until refreshed, full after refresh, exhausted when past.
    func testTraceBudgetStartsAbsentThenExpires() {
        let trace = SelectionTrace.create(trigger: .programmatic)
        XCTAssertNil(trace.remainingAXBudget)
        trace.refreshDeadline(Date().addingTimeInterval(5))
        guard let remaining = trace.remainingAXBudget else {
            return XCTFail("refreshed trace must carry a budget")
        }
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThanOrEqual(remaining, 5.0)
        trace.refreshDeadline(Date().addingTimeInterval(-1))
        XCTAssertEqual(trace.remainingAXBudget, 0)
    }

    /// A menu search with an expired deadline returns nil without touching AX.
    func testExpiredDeadlineSkipsMenuSearch() {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let found = AXMenuNavigator.findMenuItem(
            .copy,
            in: app,
            timeout: 0.5,
            deadline: Date().addingTimeInterval(-1)
        )
        XCTAssertNil(found, "expired deadline must skip the menu walk")
    }

    /// The coordinator seeds a fresh watchdog-sized AX budget on the trace for every
    /// inspect attempt, so workers (initial read and settle retries alike) are bounded.
    func testCoordinatorRefreshesInspectDeadlinePerAttempt() async {
        let seen = OSAllocatedUnfairLock<SelectionTrace?>(initialState: nil)
        var configuration = SelectionConfiguration()
        configuration.axReadTimeout = 5
        let coordinator = SelectionRetrievalCoordinator(
            configuration: configuration,
            inspect: { trace in
                seen.withLock { $0 = trace }
                return AXElementInspector.Target()
            }
        )
        _ = await coordinator.retrieveResponse(for: AppIdentity(bundleIdentifier: "com.test.app"))
        let trace = seen.withLock { $0 }
        let deadline = try? XCTUnwrap(trace?.deadline, "inspect attempt must carry an AX deadline")
        guard let deadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        XCTAssertGreaterThan(remaining, 4.0, "attempt budget must start near axReadTimeout")
        XCTAssertLessThanOrEqual(remaining, 5.0)
    }
}

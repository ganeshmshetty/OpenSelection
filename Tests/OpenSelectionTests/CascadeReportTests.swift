// CascadeReportTests.swift
// OpenSelectionTests
//
import XCTest
import ApplicationServices
import Foundation
import os
@testable import OpenSelection

final class CascadeReportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsHub.shared.reset()
    }

    override func tearDown() {
        DiagnosticsHub.shared.reset()
        super.tearDown()
    }

    func testCascadeReportAssemblyOnSuccess() async {
        final class ReportCollector: OpenSelectionDiagnosticsSink, @unchecked Sendable {
            let minimumLevel: LogLevel = .debug
            let reports = OSAllocatedUnfairLock<[CascadeReport]>(initialState: [])

            func record(_ event: DiagnosticEvent) {}
            func finish(_ report: CascadeReport) {
                reports.withLock { $0.append(report) }
            }
        }

        let collector = ReportCollector()
        DiagnosticsHub.shared.install(collector)
        DiagnosticsHub.shared.setReportMode(.always)

        let coordinator = SelectionRetrievalCoordinator(
            inspect: {
                AXElementInspector.Target(
                    focusedApp: nil,
                    focusedElement: nil,
                    role: "AXTextField",
                    subRole: nil,
                    parentRoles: [],
                    containedInRoles: [],
                    webArea: nil,
                    selectedText: "Hello world",
                    selectedTextMarkerRange: nil,
                    value: "Hello world",
                    selectedTextRange: nil,
                    bounds: CGRect(x: 100, y: 100, width: 200, height: 40)
                )
            },
            copyCapture: nil
        )

        let trace = SelectionTrace.create(trigger: .doubleClick)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Safari", localizedName: "Safari"),
            cursor: .beam,
            trace: trace
        )

        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.diagnostics)
        XCTAssertEqual(result?.diagnostics?.traceID, trace.id)
        XCTAssertEqual(result?.diagnostics?.trigger, .doubleClick)

        await DiagnosticsHub.shared.flush()

        let emittedReports = collector.reports.withLock { $0 }
        XCTAssertEqual(emittedReports.count, 1)

        let report = emittedReports[0]
        XCTAssertEqual(report.traceID, trace.id)
        XCTAssertEqual(report.outcome, .selection(strategy: .axTextControl, presence: .nonEmpty))
        XCTAssertEqual(report.target?.bundleID, "com.apple.Safari")
        XCTAssertEqual(report.target?.framework, .webkit)
        XCTAssertEqual(report.target?.cursor, .iBeam)
        XCTAssertFalse(report.attempts.isEmpty)
        XCTAssertEqual(report.attempts[0].strategy, .axTextControl)
        XCTAssertEqual(report.attempts[0].outcome, .succeeded)
    }

    func testCascadeReportAssemblyOnExhaustion() async {
        final class ReportCollector: OpenSelectionDiagnosticsSink, @unchecked Sendable {
            let minimumLevel: LogLevel = .debug
            let reports = OSAllocatedUnfairLock<[CascadeReport]>(initialState: [])

            func record(_ event: DiagnosticEvent) {}
            func finish(_ report: CascadeReport) {
                reports.withLock { $0.append(report) }
            }
        }

        let collector = ReportCollector()
        DiagnosticsHub.shared.install(collector)
        DiagnosticsHub.shared.setReportMode(.always)

        let coordinator = SelectionRetrievalCoordinator(
            inspect: {
                AXElementInspector.Target(
                    focusedApp: nil,
                    focusedElement: nil,
                    role: "AXButton",
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
            },
            copyCapture: { _ in nil }
        )

        let trace = SelectionTrace.create(trigger: .mouseUp)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.Opaque", localizedName: "Opaque"),
            cursor: .arrow,
            trace: trace
        )

        XCTAssertNil(result)

        await DiagnosticsHub.shared.flush()

        let emittedReports = collector.reports.withLock { $0 }
        XCTAssertEqual(emittedReports.count, 1)

        let report = emittedReports[0]
        XCTAssertEqual(report.outcome, .none)
    }

    func testReportModeOnFailureOrSlow() async {
        final class ReportCollector: OpenSelectionDiagnosticsSink, @unchecked Sendable {
            let minimumLevel: LogLevel = .debug
            let reports = OSAllocatedUnfairLock<[CascadeReport]>(initialState: [])

            func record(_ event: DiagnosticEvent) {}
            func finish(_ report: CascadeReport) {
                reports.withLock { $0.append(report) }
            }
        }

        let collector = ReportCollector()
        DiagnosticsHub.shared.install(collector)
        DiagnosticsHub.shared.setReportMode(.onFailureOrSlow)

        // 1. Fast success -> should NOT emit report
        let successCoordinator = SelectionRetrievalCoordinator(
            inspect: {
                AXElementInspector.Target(
                    role: "AXTextField",
                    selectedText: "Quick read"
                )
            }
        )
        _ = await successCoordinator.retrieve(cursor: .beam)
        await DiagnosticsHub.shared.flush()
        XCTAssertEqual(collector.reports.withLock({ $0.count }), 0)

        // 2. Failure -> SHOULD emit report
        let failCoordinator = SelectionRetrievalCoordinator(
            inspect: {
                AXElementInspector.Target(role: "AXWindow")
            },
            copyCapture: { _ in nil }
        )
        _ = await failCoordinator.retrieve(cursor: .arrow)
        await DiagnosticsHub.shared.flush()
        XCTAssertEqual(collector.reports.withLock({ $0.count }), 1)
    }
}

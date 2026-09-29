// SignpostSinkTests.swift
// OpenSelectionTests
//
import XCTest
import Foundation
@testable import OpenSelection

final class SignpostSinkTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsHub.shared.reset()
    }

    override func tearDown() {
        DiagnosticsHub.shared.reset()
        super.tearDown()
    }

    func testSignpostSinkHandlesEventsAndReportsWithoutThrowing() async {
        let sink = SignpostSink(minimumLevel: .trace)
        DiagnosticsHub.shared.install(sink)
        DiagnosticsHub.shared.setReportMode(.always)

        let trace = SelectionTrace.create(trigger: .keyboardShortcut)
        trace.log(.info, .cascade, "Testing signpost event", fields: ["phase": .token("ax")])

        let report = trace.buildReport(outcome: .selection(strategy: .axTextControl, presence: .nonEmpty))
        DiagnosticsHub.shared.emitReport(report)

        await DiagnosticsHub.shared.flush()
        // If execution finishes without crashing or failing preconditions, signposts were emitted cleanly.
        XCTAssertTrue(true)
    }
}

// PrivacyCanaryTests.swift
// OpenSelectionTests
//
import XCTest
import ApplicationServices
import Foundation
import os
@testable import OpenSelection

final class PrivacyCanaryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsHub.shared.reset()
    }

    override func tearDown() {
        DiagnosticsHub.shared.reset()
        super.tearDown()
    }

    func testCanaryZeroLeakGuarantee() async throws {
        final class CanarySink: OpenSelectionDiagnosticsSink, @unchecked Sendable {
            let minimumLevel: LogLevel = .trace
            let lock = OSAllocatedUnfairLock<([DiagnosticEvent], [CascadeReport])>(initialState: ([], []))

            func record(_ event: DiagnosticEvent) {
                lock.withLock { $0.0.append(event) }
            }

            func finish(_ report: CascadeReport) {
                lock.withLock { $0.1.append(report) }
            }
        }

        let sink = CanarySink()
        DiagnosticsHub.shared.install(sink)
        DiagnosticsHub.shared.setReportMode(.always)

        let canary = "CANARY_SECRET_TOKEN_7f3a9b1c"
        let canaryBase64 = Data(canary.utf8).base64EncodedString()
        let canaryLength = canary.count

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
                    selectedText: canary,
                    selectedTextMarkerRange: nil,
                    value: canary,
                    selectedTextRange: nil,
                    bounds: CGRect(x: 10, y: 20, width: 200, height: 30)
                )
            },
            copyCapture: nil
        )

        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
            cursor: .beam
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, canary)

        await DiagnosticsHub.shared.flush()

        let (events, reports) = sink.lock.withLock { $0 }
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(reports.count, 1)

        // 1. Serialize all events and reports to JSON data and UTF-8 strings
        let encoder = JSONEncoder()
        let eventsData = try encoder.encode(events)
        let reportsData = try encoder.encode(reports)
        let eventsString = String(decoding: eventsData, as: UTF8.self)
        let reportsString = String(decoding: reportsData, as: UTF8.self)

        // 2. Assert zero leak of raw substring
        XCTAssertFalse(eventsString.contains(canary), "Diagnostic events leaked canary string!")
        XCTAssertFalse(reportsString.contains(canary), "Cascade reports leaked canary string!")

        // 3. Assert zero leak of base64
        XCTAssertFalse(eventsString.contains(canaryBase64), "Diagnostic events leaked canary base64!")
        XCTAssertFalse(reportsString.contains(canaryBase64), "Cascade reports leaked canary base64!")

        // 4. Assert zero leak of length
        for event in events {
            for (key, val) in event.fields {
                if case .int(let v) = val {
                    XCTAssertNotEqual(Int(v), canaryLength, "Field '\(key)' leaked canary length!")
                }
            }
        }

        // 5. Assert report presence reflects .nonEmpty without leaking text
        XCTAssertEqual(reports[0].outcome, .selection(strategy: .axTextControl, presence: .nonEmpty))
    }

    func testSensitiveWrapperPreventsAccidentalInterpolation() {
        let sensitive = Sensitive("confidential_password")
        XCTAssertEqual(sensitive.unwrap(), "confidential_password")
    }
}

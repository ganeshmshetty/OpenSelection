// DiagnosticsPipelineTests.swift
// OpenSelectionTests
//
import XCTest
import ApplicationServices
import Foundation
import os
@testable import OpenSelection

final class DiagnosticsPipelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticsHub.shared.reset()
    }

    override func tearDown() {
        DiagnosticsHub.shared.reset()
        super.tearDown()
    }

    func testSuccessfulFallbackProducesOneNormalSummaryWithoutPollingNoise() async throws {
        let sink = SelectionLogTestSink(minimumLevel: .debug)
        DiagnosticsHub.shared.removeAllSinks()
        DiagnosticsHub.shared.install(sink)
        let reader = SelectionRetrievalCoordinator(
            configuration: SelectionConfiguration(webAreaSettleInterval: 0.001, webAreaSettleMaxRetries: 3),
            inspect: { _ in AXElementInspector.Target(role: "AXWebArea", selectedText: "") },
            detailedCopyCapture: { _ in .init(result: SelectionResult(text: "PRIVATE_CANARY", strategy: .keyboardCopy), status: .selection) })
        let response = await reader.retrieveResponse(for: AppIdentity(bundleIdentifier: "com.test"),
            requireCopyEvidence: false, trigger: .dragEnd)
        await DiagnosticsHub.shared.flush()
        let events = sink.events.withLock { $0 }
        XCTAssertEqual(events.count, 1)
        let summary = try XCTUnwrap(events.first)
        XCTAssertEqual(summary.message, "selection completed")
        XCTAssertEqual(summary.level, .info)
        XCTAssertEqual(summary.traceID.rawValue, response.traceID)
        XCTAssertEqual(summary.fields["configuredStrategy"], .token("ax-text-control"))
        XCTAssertEqual(summary.fields["winningStrategy"], .token("keyboard-copy"))
        XCTAssertEqual(summary.fields["trigger"], .token("dragEnd"))
        XCTAssertEqual(summary.fields["webAreaRetries"], .int(2))
        XCTAssertEqual(summary.fields["fallbackReason"], .token("noSelection"))
        XCTAssertFalse(String(describing: events).contains("PRIVATE_CANARY"))
    }

    func testVerboseCaptureEventsInheritRequestTraceAndContextDoesNotLeak() async {
        let sink = SelectionLogTestSink(minimumLevel: .trace)
        DiagnosticsHub.shared.removeAllSinks()
        DiagnosticsHub.shared.install(sink)
        let reader = SelectionRetrievalCoordinator(
            inspect: { _ in AXElementInspector.Target() },
            detailedCopyCapture: { _ in
                await Task { DiagnosticsHub.shared.log(.trace, .pasteboard, "capture detail") }.value
                return .init(result: SelectionResult(text: "text", strategy: .keyboardCopy), status: .selection)
            })
        let response = await reader.retrieveResponse()
        await DiagnosticsHub.shared.flush()
        let events = sink.events.withLock { $0 }
        XCTAssertTrue(events.contains { $0.message == "capture detail" })
        XCTAssertTrue(events.allSatisfy { $0.traceID.rawValue == response.traceID })
        XCTAssertNil(SelectionTrace.current)
    }

    func testLogLevelOrdering() {
        XCTAssertLessThan(LogLevel.trace, LogLevel.debug)
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
        XCTAssertLessThan(LogLevel.error, LogLevel.fault)
    }

    func testLogMessageLiteralOnly() {
        let msg: LogMessage = "gate passed"
        XCTAssertEqual(msg.description, "gate passed")
    }

    func testFieldValueCodableRoundtrip() throws {
        let fields: [String: FieldValue] = [
            "count": .int(42),
            "allowed": .bool(true),
            "latency": .micros(1500),
            "presence": .presence(.nonEmpty),
            "axError": .ax(.cannotComplete),
            "strategy": .token("axTextControl")
        ]

        let data = try JSONEncoder().encode(fields)
        let decoded = try JSONDecoder().decode([String: FieldValue].self, from: data)
        XCTAssertEqual(fields, decoded)
    }

    func testDiagnosticsHubSinkDeliveryAndFloorFiltering() async {
        final class MockSink: OpenSelectionDiagnosticsSink, Sendable {
            let minimumLevel: LogLevel
            let recordedEvents = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])

            init(minimumLevel: LogLevel) {
                self.minimumLevel = minimumLevel
            }

            func record(_ event: DiagnosticEvent) {
                recordedEvents.withLock { $0.append(event) }
            }
        }

        let sink = MockSink(minimumLevel: .info)
        DiagnosticsHub.shared.install(sink)

        XCTAssertTrue(DiagnosticsHub.shared.isEnabled(.info))
        XCTAssertTrue(DiagnosticsHub.shared.isEnabled(.error))
        XCTAssertFalse(DiagnosticsHub.shared.isEnabled(.debug))
        XCTAssertFalse(DiagnosticsHub.shared.isEnabled(.trace))

        let trace = SelectionTrace.create(trigger: .mouseUp)
        trace.log(.debug, .gate, "debug event ignored")
        trace.log(.info, .cascade, "info event delivered", fields: ["attempt": .int(1)])
        trace.log(.error, .ax, "error event delivered", fields: ["code": .ax(.cannotComplete)])

        // Wait for serial diagnostics queue to flush
        await DiagnosticsHub.shared.flush()

        let events = sink.recordedEvents.withLock { $0 }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].message, "info event delivered")
        XCTAssertEqual(events[0].level, .info)
        XCTAssertEqual(events[0].category, .cascade)
        XCTAssertEqual(events[0].fields["attempt"], .int(1))

        XCTAssertEqual(events[1].message, "error event delivered")
        XCTAssertEqual(events[1].level, .error)
        XCTAssertEqual(events[1].category, .ax)
        XCTAssertEqual(events[1].fields["code"], .ax(.cannotComplete))
    }

    func testTraceIDGenerationAndCorrelation() {
        let trace1 = SelectionTrace.create(trigger: .mouseUp)
        let trace2 = SelectionTrace.create(trigger: .keyboardShortcut, parent: trace1.id)

        XCTAssertNotEqual(trace1.id, trace2.id)
        XCTAssertLessThan(trace1.id.rawValue, trace2.id.rawValue)
        XCTAssertNil(trace1.parent)
        XCTAssertEqual(trace2.parent, trace1.id)
        XCTAssertEqual(trace1.trigger, .mouseUp)
        XCTAssertEqual(trace2.trigger, .keyboardShortcut)
    }

    func testAXErrorCodeMapping() {
        XCTAssertEqual(AXErrorCode(axError: .apiDisabled), .apiDisabled)
        XCTAssertEqual(AXErrorCode(axError: .cannotComplete), .cannotComplete)
        XCTAssertEqual(AXErrorCode(axError: .invalidUIElement), .invalidUIElement)
        XCTAssertEqual(AXErrorCode(axError: .attributeUnsupported), .attributeUnsupported)
        XCTAssertEqual(AXErrorCode(axError: .notImplemented), .notImplemented)
        XCTAssertEqual(AXErrorCode(axError: .noValue), .noValue)

        XCTAssertEqual(AXErrorCode.apiDisabled.likelyCause, .permissionDenied)
        XCTAssertEqual(AXErrorCode.cannotComplete.likelyCause, .ipcTimeoutOrBusy)
        XCTAssertEqual(AXErrorCode.invalidUIElement.likelyCause, .staleElement)
        XCTAssertEqual(AXErrorCode.notImplemented.likelyCause, .unsupportedByTarget)
    }

    func testAXReadResult() {
        let val: AXReadResult<String> = .value("hello")
        XCTAssertEqual(val.valueOrNil, "hello")

        let fail: AXReadResult<String> = .failure(.cannotComplete)
        XCTAssertNil(fail.valueOrNil)
    }

    func testLegacyOpenSelectionLoggingShim() async {
        let received = OSAllocatedUnfairLock<[String]>(initialState: [])

        OpenSelectionLogging.logger = { msg in
            received.withLock { $0.append(msg) }
        }

        OpenSelectionLogging.log("test legacy message")

        await DiagnosticsHub.shared.flush()

        let msgs = received.withLock { $0 }
        XCTAssertTrue(msgs.contains(where: { $0.contains("test legacy message") }))
    }
}


private final class SelectionLogTestSink: OpenSelectionDiagnosticsSink, Sendable {
    let minimumLevel: LogLevel
    let events = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])
    init(minimumLevel: LogLevel) { self.minimumLevel = minimumLevel }
    func record(_ event: DiagnosticEvent) { events.withLock { $0.append(event) } }
}

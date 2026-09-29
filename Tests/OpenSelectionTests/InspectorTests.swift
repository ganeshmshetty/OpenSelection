// InspectorTests.swift
// OpenSelectionTests
//
import XCTest
import ApplicationServices
import Foundation
@testable import OpenSelection

final class InspectorTests: XCTestCase {

    func testDiagnoseProducesValidDiagnosticsStructure() async {
        let options = InspectionOptions(
            depth: 5,
            nodeBudget: 50,
            deadlineSeconds: 2.0,
            allowIntrusiveProbes: false
        )

        let diagnostics = await OpenSelectionInspector.diagnose(target: .frontmost, options: options)

        XCTAssertEqual(diagnostics.schemaVersion, TargetDiagnostics.currentSchemaVersion)
        XCTAssertFalse(diagnostics.system.osVersion.isEmpty)
        XCTAssertEqual(diagnostics.strategyPreflight.count, 5)

        let strategies = Set(diagnostics.strategyPreflight.map(\.strategy))
        XCTAssertTrue(strategies.contains(.axTextControl))
        XCTAssertTrue(strategies.contains(.axWebArea))
        XCTAssertTrue(strategies.contains(.officeScript))
        XCTAssertTrue(strategies.contains(.menuCopy))
        XCTAssertTrue(strategies.contains(.keyboardCopy))
    }

    func testRenderJSONAndDecodeRoundtrip() throws {
        let systemInfo = SystemInfo(
            osVersion: "macOS 15.0",
            architecture: .arm64,
            isAXTrusted: true,
            hostBundleID: "com.test.host"
        )
        let targetSnapshot = TargetSnapshot(
            pid: 1234,
            bundleID: "com.apple.TextEdit",
            architecture: .arm64,
            isRosettaTranslated: false,
            framework: .native,
            cursor: .iBeam
        )
        let element = ElementSnapshot(
            role: "AXTextField",
            subrole: nil,
            enabled: true,
            focused: true,
            supportedAttributes: ["AXRole", "AXValue", "custom(2)"],
            actions: ["AXPress"],
            selectedText: .presence(.nonEmpty),
            selectedRange: .presence(.nonEmpty),
            childrenCount: 0
        )
        let preflights = [
            StrategyPreflight(strategy: .axTextControl, viable: true, reason: "Text control ready"),
            StrategyPreflight(strategy: .keyboardCopy, viable: true, reason: "Evidence satisfied")
        ]
        let menuProbe = MenuCopyProbe(
            editMenuFound: true,
            copyItemPresent: true,
            copyItemEnabled: true,
            shortcutMatchesCommandC: true
        )

        let diagnostics = TargetDiagnostics(
            system: systemInfo,
            target: targetSnapshot,
            accessibility: AXCapabilities(isManualAccessibilitySettable: false, isManualAccessibilityEnabled: false, isEnhancedUserInterfaceSettable: true, isEnhancedUserInterfaceEnabled: false),
            focusChain: [element],
            strategyPreflight: preflights,
            menuCopy: menuProbe,
            liveRun: nil
        )

        let jsonData = diagnostics.renderJSON(pretty: true)
        XCTAssertFalse(jsonData.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TargetDiagnostics.self, from: jsonData)

        XCTAssertEqual(decoded.schemaVersion, diagnostics.schemaVersion)
        XCTAssertEqual(decoded.system, diagnostics.system)
        XCTAssertEqual(decoded.target, diagnostics.target)
        XCTAssertEqual(decoded.focusChain, diagnostics.focusChain)
        XCTAssertEqual(decoded.strategyPreflight, diagnostics.strategyPreflight)
        XCTAssertEqual(decoded.menuCopy, diagnostics.menuCopy)
    }

    func testRenderTextContainsExpectedSectionHeaders() {
        let systemInfo = SystemInfo(
            osVersion: "macOS 15.0",
            architecture: .arm64,
            isAXTrusted: true,
            hostBundleID: "com.test.host"
        )
        let targetSnapshot = TargetSnapshot(
            pid: 4321,
            bundleID: "com.apple.Safari",
            architecture: .arm64,
            isRosettaTranslated: false,
            framework: .webkit,
            cursor: .iBeam
        )

        let diagnostics = TargetDiagnostics(
            system: systemInfo,
            target: targetSnapshot,
            focusChain: [ElementSnapshot(role: "AXWebArea", supportedAttributes: ["AXRole"])],
            strategyPreflight: [StrategyPreflight(strategy: .axWebArea, viable: true, reason: "WebArea present")]
        )

        let text = diagnostics.renderText()
        XCTAssertTrue(text.contains("=== OpenSelection Target Diagnostics ==="))
        XCTAssertTrue(text.contains("--- System ---"))
        XCTAssertTrue(text.contains("--- Target Application ---"))
        XCTAssertTrue(text.contains("--- Strategy Preflights ---"))
        XCTAssertTrue(text.contains("PID: 4321"))
        XCTAssertTrue(text.contains("Bundle ID: com.apple.Safari"))
        XCTAssertTrue(text.contains("ax-web-area"))
    }
}

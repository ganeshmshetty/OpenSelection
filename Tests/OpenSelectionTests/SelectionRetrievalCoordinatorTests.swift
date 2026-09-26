import XCTest
import ApplicationServices
import CoreGraphics
@testable import OpenSelection

private typealias AppPolicyContext = SelectionPolicy

final class SelectionRetrievalCoordinatorTests: XCTestCase {

    private static func textFieldTarget(
        selectedText: String? = nil,
        role: String = "AXTextField",
        bounds: CGRect? = nil
    ) -> AXElementInspector.Target {
        AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: role,
            subRole: nil,
            parentRoles: [],
            containedInRoles: [],
            webArea: nil,
            selectedText: selectedText,
            selectedTextMarkerRange: nil,
            value: nil,
            selectedTextRange: nil,
            bounds: bounds
        )
    }

    /// An app that exposes no usable AX role for its text (custom-drawn editors/terminals):
    /// everything the gate could key off is absent.
    private static func opaqueTarget(containedInRoles: Set<String> = []) -> AXElementInspector.Target {
        AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: nil,
            subRole: nil,
            parentRoles: [],
            containedInRoles: containedInRoles,
            webArea: nil,
            selectedText: nil,
            selectedTextMarkerRange: nil,
            value: nil,
            selectedTextRange: nil,
            bounds: nil
        )
    }

    private static func webAreaTarget(selectedText: String) -> AXElementInspector.Target {
        AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: "AXWebArea",
            subRole: nil,
            parentRoles: ["AXGroup"],
            containedInRoles: ["AXGroup"],
            webArea: nil,
            selectedText: selectedText,
            selectedTextMarkerRange: nil,
            value: nil,
            selectedTextRange: nil,
            bounds: nil
        )
    }

    /// A web-area-style target whose only AX selection signal is a non-nil (but opaque)
    /// `AXSelectedTextMarkerRange`, as Electron/web canvases report with nothing selected.
    private static func markerRangeTarget() -> AXElementInspector.Target {
        AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: "AXWebArea",
            subRole: nil,
            parentRoles: ["AXGroup"],
            containedInRoles: ["AXGroup"],
            webArea: nil,
            selectedText: "",
            selectedTextMarkerRange: NSObject(),
            value: nil,
            selectedTextRange: nil,
            bounds: nil
        )
    }

    /// A web-area-style target whose only selection signal is a marker range that resolved to text.
    private static func markerTextTarget(_ text: String) -> AXElementInspector.Target {
        AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: "AXWebArea",
            subRole: nil,
            parentRoles: [],
            containedInRoles: [],
            webArea: nil,
            selectedText: "",
            selectedTextMarkerRange: NSObject(),
            selectedMarkerText: text,
            value: nil,
            selectedTextRange: nil,
            bounds: nil
        )
    }

    /// A target whose only possible evidence is an `AXSelectedTextRange` of `length` code units.
    /// Length 0 models a collapsed caret (Figma on its canvas); positive length models a real
    /// text selection.
    private static func rangeTarget(length: Int) -> AXElementInspector.Target {
        var cfRange = CFRange(location: 0, length: length)
        let value = AXValueCreate(.cfRange, &cfRange)
        return AXElementInspector.Target(
            focusedApp: nil,
            focusedElement: nil,
            role: nil,
            subRole: nil,
            parentRoles: [],
            containedInRoles: [],
            webArea: nil,
            selectedText: nil,
            selectedTextMarkerRange: nil,
            value: nil,
            selectedTextRange: value,
            bounds: nil
        )
    }

    /// The shipping default leaves `enrichRichContent` off so a successful AX read never posts a
    /// synthetic copy. Tests that assert rich HTML/RTF/flavor capture must opt in explicitly.
    private static let richCaptureConfiguration = SelectionConfiguration(enrichRichContent: true)

    // MARK: - Gate

    func testGateSkipsButtonRole() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "button text", role: "AXButton") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl, gate: .default)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
    }

    func testGateAllowsButtonRoleInsideWebArea() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: {
                AXElementInspector.Target(
                    focusedApp: nil,
                    focusedElement: nil,
                    role: "AXButton",
                    subRole: nil,
                    parentRoles: ["AXWebArea"],
                    containedInRoles: ["AXWebArea"],
                    webArea: nil,
                    selectedText: "button text inside web",
                    selectedTextMarkerRange: nil,
                    value: nil,
                    selectedTextRange: nil,
                    bounds: nil
                )
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl, gate: .default)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "button text inside web")
    }

    func testUnknownCursorProceedsEvenWhenNotAllowed() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "proceed") }
        )
        let policy = AppPolicyContext(
            retrievalMode: .axTextControl,
            gate: SelectionGatePolicy(allowedCursors: [.beam])
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "proceed")
    }

    func testDisallowedCursorBlocksRetrieval() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "blocked") }
        )
        let policy = AppPolicyContext(
            retrievalMode: .axTextControl,
            gate: SelectionGatePolicy(allowedCursors: [.beam])
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .arrow
        )
        XCTAssertNil(result)
    }

    // MARK: - Modes

    func testAXTextControlReturnsTextFromFixtureTarget() async {
        let bounds = CGRect(x: 1, y: 2, width: 30, height: 4)
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "hello", bounds: bounds) }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "hello")
        XCTAssertEqual(result?.bounds, bounds)
    }

    func testAXWebAreaReturnsTextFromFixtureTarget() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.webAreaTarget(selectedText: "web text") }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "web text")
    }

    func testAXWebAreaSettleRetryReInspectsUntilTextSettles() async {
        final class InspectCallCount: @unchecked Sendable { var value = 0 }
        let calls = InspectCallCount()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: {
                calls.value += 1
                if calls.value <= 2 {
                    return Self.webAreaTarget(selectedText: "")
                }
                return Self.webAreaTarget(selectedText: "settled web text")
            },
            copyCapture: { _ in nil }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "settled web text")
        XCTAssertGreaterThan(calls.value, 2)
    }

    func testBrowserModeUsesWebAreaSelection() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.webAreaTarget(selectedText: "web selection") }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Safari"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "web selection")
    }

    func testBrowserModeNilFallsBackToKeyboardCopy() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in SelectionResult(text: "copy fallback") }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Safari"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "copy fallback")
    }

    private actor CopyCallTracker {
        var copyInvoked = false
        func recordCopy() { copyInvoked = true }
    }

    func testAllowCopyFallbackFalseSkipsCopyCapture() async {
        let tracker = CopyCallTracker()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in
                await tracker.recordCopy()
                return SelectionResult(text: "should not be called")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.openai.codex"),
            policy: policy,
            cursor: .unknown,
            allowCopyFallback: false
        )
        XCTAssertNil(result)
        let invoked = await tracker.copyInvoked
        XCTAssertFalse(invoked, "copyCapture must not be invoked when allowCopyFallback is false")
    }

    /// A copy-only app must not be left with an empty cascade when the overlay gate disallows the
    /// synthetic copy: it degrades to the (event-free) AX reads instead of returning nil, so the
    /// popup still appears. Regression: the Dock's always-on window tripped the gate and stripped
    /// the only strategy.
    func testKeyboardCopyOnlyAppDegradesToAXWhenCopyFallbackDisallowed() async {
        let tracker = CopyCallTracker()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "ax fallback text") },
            copyCapture: { _ in
                await tracker.recordCopy()
                return SelectionResult(text: "should not be called")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "abnerworks.Typora"),
            policy: policy,
            cursor: .unknown,
            allowCopyFallback: false
        )
        XCTAssertEqual(result?.text, "ax fallback text")
        let invoked = await tracker.copyInvoked
        XCTAssertFalse(invoked, "the AX-only degradation must not post a synthetic copy")
    }

    func testRetrieveDetailsIdentifiesEditableTextControl() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil, role: "AXTextField") },
            copyCapture: { _ in nil }
        )
        let outcome = await coordinator.retrieveDetails(
            for: AppIdentity(bundleIdentifier: "com.openai.codex"),
            policy: AppPolicyContext.default,
            cursor: CursorClass.unknown,
            allowCopyFallback: false
        )
        XCTAssertNil(outcome.result)
        XCTAssertTrue(outcome.isEditable, "AXTextField must be identified as editable context")
    }


    // MARK: - Copy modes

    func testMenuCopyProceedsWithoutConfirmedSelection() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in SelectionResult(text: "captured via menu copy") }
        )
        let policy = AppPolicyContext(retrievalMode: .menuCopy, gate: .default)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Terminal"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "captured via menu copy")
    }

    func testMenuCopyStartsAtMenuCopyEvenWhenAXTextAvailable() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "ax text") },
            copyCapture: { _ in SelectionResult(text: "captured via menu copy") }
        )
        let policy = AppPolicyContext(retrievalMode: .menuCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Terminal"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "captured via menu copy")
    }

    func testKeyboardCopyStartsAtKeyboardCopyEvenWhenAXTextAvailable() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "ax text") },
            copyCapture: { _ in SelectionResult(text: "captured keyboard copy") }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.sublimetext.3"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "captured keyboard copy")
    }

    /// OneNote's canvas exposes no AX text-selection evidence (no cursor class, no
    /// `AXSelectedText`/range, no text-control role), so the copy-evidence gate would skip the only
    /// strategy that can read it and retrieval would always return nil. The allowlist waives the
    /// gate so the copy fallback runs. Regression: mouse selections in OneNote produced no popup.
    func testCopyFallbackAppBypassesEvidenceGate() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget() },
            copyCapture: { _ in SelectionResult(text: "onenote selection") }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.onenote.mac"),
            policy: AppPolicyContext.default,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "onenote selection")
    }

    /// The evidence gate must still protect custom-drawn web canvases (e.g. Figma object drags)
    /// from a spurious ⌘C. Figma is Electron, so its inspect target sits inside an AXWebArea —
    /// that web-area surface is exactly what keeps the evidence requirement in force now that the
    /// waiver is structural (no-text-surface) rather than a bundle-ID allowlist.
    func testNonCopyFallbackAppStillRequiresEvidence() async {
        let tracker = CopyCallTracker()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget(containedInRoles: ["AXWebArea"]) },
            copyCapture: { _ in
                await tracker.recordCopy()
                return SelectionResult(text: "should not be called")
            }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: AppPolicyContext.default,
            cursor: .unknown
        )
        XCTAssertNil(result)
        let invoked = await tracker.copyInvoked
        XCTAssertFalse(invoked, "the evidence gate must still block the copy for web-canvas apps")
    }

    /// The structural waiver generalizes the OneNote allowlist: any app whose AX tree exposes no
    /// text surface at all (no selected text/range, no text-control role, no containing AXWebArea)
    /// gets one speculative copy attempt per gesture, because a synthetic copy is the only read
    /// that can ever succeed there. No bundle-ID entry required.
    func testOpaqueNativeAppWithoutTextSurfaceBypassesEvidenceGate() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget() },
            copyCapture: { _ in SelectionResult(text: "canvas selection") }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.example.someopaquecanvas"),
            policy: AppPolicyContext.default,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "canvas selection")
    }

    /// The structural waiver must not extend to item-selection surfaces: a drag across a Photos grid
    /// or Mail list selects items, not text, and an opaque grid is as evidence-free as a OneNote
    /// canvas. Posting a real ⌘C there copies image/file data and stalls the capture, so those
    /// targets keep the evidence requirement.
    func testItemSelectionSurfaceStillRequiresEvidence() async {
        let tracker = CopyCallTracker()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget(containedInRoles: ["AXList"]) },
            copyCapture: { _ in
                await tracker.recordCopy()
                return SelectionResult(text: "should not be called")
            }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.example.someopaquegrid"),
            policy: AppPolicyContext.default,
            cursor: .unknown
        )
        XCTAssertNil(result)
        let invoked = await tracker.copyInvoked
        XCTAssertFalse(invoked, "an item-selection surface must not get a speculative ⌘C")
    }

    /// Electron/Chromium apps are copy-classified but should read AX first (non-destructively)
    /// before posting ⌘C: accessibility usually sees the selection once it is active.
    func testElectronKeyboardCopyPrefersAXTextOverCopy() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "electron ax text") },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "captured keyboard copy")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.VSCode"),
            policy: policy,
            cursor: .unknown,
            allowCopyFallback: false
        )
        XCTAssertEqual(result?.text, "electron ax text")
        XCTAssertEqual(counter.calls, 0, "AX read must win over the synthetic copy")
    }

    func testKeyboardCopyHasNoFallbackBelowIt() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in
                counter.calls += 1
                return nil
            }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.VSCode"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 1)
    }

    func testMenuCopyHasNoFallbackToKeyboardCopy() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in
                counter.calls += 1
                return nil
            }
        )
        let policy = AppPolicyContext(retrievalMode: .menuCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.mitchellh.ghostty"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 1)
    }

    func testCopyCaptureNilReturnsNil() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in nil }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.VSCode"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
    }

    func testMenuCopyCaptureNilReturnsNil() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in nil }
        )
        let policy = AppPolicyContext(retrievalMode: .menuCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Terminal"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
    }

    // MARK: - Select-all (⌘A) gating for copy modes

    func testSelectAllMenuCopySkippedOnNonTextElement() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil, role: "AXOutline") },
            copyCapture: { _ in SelectionResult(text: "should not copy rows") }
        )
        let policy = AppPolicyContext(retrievalMode: .menuCopy, gate: .lenient)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.finder"),
            policy: policy,
            cursor: .unknown,
            isSelectAll: true
        )
        XCTAssertNil(result)
    }

    func testSelectAllMenuCopySkippedOnNonTextElementWithoutSelection() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "row text", role: "AXTable") },
            copyCapture: { _ in SelectionResult(text: "should not copy") }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.mail"),
            policy: policy,
            cursor: .unknown,
            isSelectAll: true
        )
        XCTAssertNil(result)
    }

    func testSelectAllMenuCopyProceedsOnTextElement() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil, role: "AXTextArea") },
            copyCapture: { _ in SelectionResult(text: "captured select-all text") }
        )
        let policy = AppPolicyContext(retrievalMode: .menuCopy, gate: .lenient)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Terminal"),
            policy: policy,
            cursor: .unknown,
            isSelectAll: true
        )
        XCTAssertEqual(result?.text, "captured select-all text")
    }

    func testSelectAllProceedsOnOpaqueRoleWithBeamCursor() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget() },
            copyCapture: { _ in SelectionResult(text: "captured select-all text") }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "dev.zed.Zed"),
            policy: policy,
            cursor: .beam,
            isSelectAll: true
        )
        XCTAssertEqual(result?.text, "captured select-all text")
    }

    // MARK: - Copy evidence gate

    func testCopySkippedOnCanvasDragWithoutTextEvidence() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget(containedInRoles: ["AXWebArea"]) },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "copied object")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: policy,
            cursor: .arrow
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 0, "A canvas drag must never post a synthetic ⌘C")
    }

    func testCopyProceedsWithBeamCursorTextEvidence() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget() },
            copyCapture: { _ in SelectionResult(text: "captured via keyboard copy") }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: policy,
            cursor: .beam
        )
        XCTAssertEqual(result?.text, "captured via keyboard copy")
    }

    func testCopySkippedForAXWebAreaAncestorWithoutSelection() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget(containedInRoles: ["AXWebArea", "AXGroup"]) },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "copied object")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: policy,
            cursor: .pointingHand
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 0, "AXWebArea ancestry alone is not text evidence")
    }

    /// Regression: a web text input is exposed as a text control, but the pointer can read as a
    /// hand (a link/button near the input) or unknown while the selection is made. The focused/
    /// ancestor text-control role is structural evidence, so it must permit the copy fallback
    /// regardless of the cursor class — gating it on the cursor left the input unreadable.
    func testCopyProceedsForTextControlRoleRegardlessOfCursor() async {
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        for cursor: CursorClass in [.pointingHand, .unknown, .arrow] {
            let coordinator = SelectionRetrievalCoordinator(
                inspect: { Self.opaqueTarget(containedInRoles: ["AXTextArea"]) },
                copyCapture: { _ in SelectionResult(text: "captured via keyboard copy") }
            )
            let result = await coordinator.retrieve(
                for: AppIdentity(bundleIdentifier: "com.google.Chrome"),
                policy: policy,
                cursor: cursor
            )
            XCTAssertEqual(result?.text, "captured via keyboard copy", "cursor=\(cursor.rawValue)")
        }
    }

    func testCopyEvidenceGateCanBeDisabledForExplicitTriggers() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget(containedInRoles: ["AXWebArea"]) },
            copyCapture: { _ in SelectionResult(text: "explicit hotkey capture") }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: policy,
            cursor: .arrow,
            requireCopyEvidence: false
        )
        XCTAssertEqual(result?.text, "explicit hotkey capture")
    }

    func testCollapsedCaretRangeIsNotTextEvidence() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.rangeTarget(length: 0) },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "should not copy")
            }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: AppPolicyContext(retrievalMode: .keyboardCopy),
            cursor: .arrow
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 0, "A zero-length caret range must not justify ⌘C")
    }

    func testNonEmptyRangeIsTextEvidence() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.rangeTarget(length: 5) },
            copyCapture: { _ in SelectionResult(text: "copied") }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: AppPolicyContext(retrievalMode: .keyboardCopy),
            cursor: .arrow
        )
        XCTAssertEqual(result?.text, "copied")
    }

    func testMarkerRangeAloneIsNotTextEvidence() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.markerRangeTarget() },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "should not copy")
            }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: AppPolicyContext(retrievalMode: .keyboardCopy),
            cursor: .arrow
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 0, "A marker range alone must not justify ⌘C")
    }

    /// Figma's canvas reports `cursor = .unknown` (a custom move cursor) alongside an empty marker
    /// range. `.unknown` must NOT count as copy evidence, or an object drag would post ⌘C again.
    func testUnknownCursorOnCanvasIsNotTextEvidence() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.markerRangeTarget() },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "should not copy")
            }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.figma.Desktop"),
            policy: AppPolicyContext(retrievalMode: .keyboardCopy),
            cursor: .unknown
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 0, ".unknown cursor must not justify ⌘C on a canvas")
    }

    func testMarkerTextIsTextEvidence() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.markerTextTarget("resolved web text") },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "copied")
            }
        )
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.hnc.Discord"),
            policy: AppPolicyContext(retrievalMode: .keyboardCopy),
            cursor: .arrow
        )
        // A marker range that resolves to text is sufficient to return the selection directly;
        // Electron/Chromium apps must not be sent a synthetic ⌘C when AX already has the text.
        XCTAssertEqual(result?.text, "resolved web text")
        XCTAssertEqual(counter.calls, 0, "resolved marker text must not trigger a synthetic copy")
    }

    func testSelectAllSkippedInsideRowContainer() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.opaqueTarget(containedInRoles: ["AXScrollArea", "AXOutline"]) },
            copyCapture: { _ in SelectionResult(text: "should not copy rows") }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.finder"),
            policy: policy,
            cursor: .unknown,
            isSelectAll: true
        )
        XCTAssertNil(result)
    }

    func testSelectAllProceedsInTextFieldInsideTable() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "cell text", role: "AXTextField") },
            copyCapture: { _ in SelectionResult(text: "cell text") }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Numbers"),
            policy: policy,
            cursor: .unknown,
            isSelectAll: true
        )
        XCTAssertEqual(result?.text, "cell text")
    }

    func testSelectAllDoesNotGateNonCopyModes() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "selected text") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown,
            isSelectAll: true
        )
        XCTAssertEqual(result?.text, "selected text")
    }

    // MARK: - Fallback cascade

    func testAXTextControlFallsBackToCopyWhenAXReadIsEmpty() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil, role: "AXTextArea") },
            copyCapture: { _ in SelectionResult(text: "copied fallback") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "copied fallback")
    }

    // MARK: - Blank-text filtering

    func testRetrieveRejectsWhitespaceOnlySelection() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "   \n  ") },
            copyCapture: { _ in nil }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
    }

    func testRetrieveRejectsWhitespaceOnlyCopyCapture() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil, role: "AXTextArea") },
            copyCapture: { _ in SelectionResult(text: "  ") }
        )
        let policy = AppPolicyContext(retrievalMode: .menuCopy, gate: .lenient)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Terminal"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
    }

    func testBlankAXTextFallsThroughToCopyFallback() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "   \t  ") },
            copyCapture: { _ in SelectionResult(text: "copied text") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "copied text")
    }

    func testStrictlyNativeAppDoesNotFallbackToKeyboardCopy() async throws {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "unexpected copy")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let nativeBundleID = try XCTUnwrap(AppMatching.nativeApps.first)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: nativeBundleID),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(result)
        XCTAssertEqual(counter.calls, 0)
    }

    func testNotesResolvesKeyboardCopyFallback() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in SelectionResult(text: "copied from notes") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Notes"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "copied from notes")
    }

    func testNativeAppWithEmbeddedWebAreaCascadesToWebArea() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.webAreaTarget(selectedText: "mail web body") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.mail"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "mail web body")
    }

    func testPreviewAppFallsBackToKeyboardCopy() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in SelectionResult(text: "copied from preview pdf") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Preview"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "copied from preview pdf")
    }

    // MARK: - Rich-content enrichment

    /// The default configuration disables enrichment: a successful AX read must not fire the
    /// synthetic ⌘C that captures HTML/RTF/flavors, even for a web area.
    func testDefaultConfigurationSkipsRichEnrichment() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.webAreaTarget(selectedText: "plain selection") },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "rich selection", html: "<b>rich</b> selection")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.google.Chrome"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "plain selection")
        XCTAssertNil(result?.html)
        XCTAssertEqual(counter.calls, 0, "the default configuration must not post a synthetic copy")
    }

    func testTextOnlyWebAreaWinEnrichesFromPasteboardCapture() async {
        let coordinator = SelectionRetrievalCoordinator(
            configuration: Self.richCaptureConfiguration,
            inspect: { Self.webAreaTarget(selectedText: "plain selection") },
            copyCapture: { _ in SelectionResult(text: "rich selection", html: "<b>rich</b> selection") }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.google.Chrome"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "rich selection")
        XCTAssertEqual(result?.html, "<b>rich</b> selection")
    }

    func testRichDocumentAppEnrichesFromPasteboardCapture() async {
        let coordinator = SelectionRetrievalCoordinator(
            configuration: Self.richCaptureConfiguration,
            inspect: { Self.textFieldTarget(selectedText: "flattened notes text") },
            copyCapture: { _ in
                SelectionResult(
                    text: "Paragraph 1\n\nParagraph 2",
                    rtf: "{\\rtf1\\ansi Paragraph 1\\par Paragraph 2}",
                    flavors: [PasteboardFlavor(type: "com.apple.notes.richtext", data: Data([0x00, 0x01]))]
                )
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Notes"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "Paragraph 1\n\nParagraph 2")
        XCTAssertNotNil(result?.rtf, "Rich document apps should retain RTF captured from the pasteboard")
        XCTAssertEqual(result?.flavors.first?.type, "com.apple.notes.richtext", "Captured flavors must survive enrichment")
    }

    func testNativeAppTextOnlyWinDoesNotFireCopyCapture() async throws {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "native text") },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "unexpected", html: "<b>unexpected</b>")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)
        // A strictly-native app that is *not* a rich document app (those now enrich from the pasteboard).
        let nativeBundleID = try XCTUnwrap(AppMatching.nativeApps.first { !AppMatching.isRichDocumentApp($0) })
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: nativeBundleID),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "native text")
        XCTAssertNil(result?.html)
        XCTAssertEqual(counter.calls, 0)
    }

    func testKeyboardCopySkipsEnrichmentCapture() async {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in
                counter.calls += 1
                return SelectionResult(text: "captured", html: "<b>captured</b>")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .keyboardCopy)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.google.Chrome"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "captured")
        XCTAssertEqual(result?.html, "<b>captured</b>")
        XCTAssertEqual(counter.calls, 1)
    }

    func testEnrichmentKeepsOriginalWhenCaptureYieldsNoRichContent() async {
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.webAreaTarget(selectedText: "plain selection") },
            copyCapture: { _ in SelectionResult(text: "plain capture") }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.google.Chrome"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "plain selection")
        XCTAssertNil(result?.html)
    }

    /// Regression: a web area that only exposes its selection after a settle retry must still be
    /// enriched. The copy-evidence check used the original inspect snapshot, which a later retry
    /// had replaced — so a real selection looked evidence-free and enrichment was skipped.
    func testSettledWebAreaRetryStillEnrichesRichContent() async {
        final class SnapshotSequence: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            private let first: AXElementInspector.Target
            private let settled: AXElementInspector.Target
            init(first: AXElementInspector.Target, settled: AXElementInspector.Target) {
                self.first = first
                self.settled = settled
            }
            func next() -> AXElementInspector.Target {
                lock.lock()
                defer { lock.unlock() }
                calls += 1
                return calls == 1 ? first : settled
            }
        }
        let sequence = SnapshotSequence(
            first: Self.markerRangeTarget(),
            settled: Self.webAreaTarget(selectedText: "settled web text")
        )
        let coordinator = SelectionRetrievalCoordinator(
            configuration: Self.richCaptureConfiguration,
            inspect: { sequence.next() },
            copyCapture: { _ in SelectionResult(text: "rich settled", html: "<b>rich settled</b>") }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.google.Chrome"),
            policy: policy,
            cursor: .arrow
        )
        XCTAssertEqual(result?.text, "rich settled")
        XCTAssertEqual(result?.html, "<b>rich settled</b>")
    }

    /// Regression: an app-private pasteboard flavor captured by a single-line copy must survive
    /// enrichment even when no HTML/RTF was written. Dropping it silently lost app-private data.
    func testFlavorOnlyPasteboardCaptureIsRetained() async {
        let coordinator = SelectionRetrievalCoordinator(
            configuration: Self.richCaptureConfiguration,
            inspect: { Self.webAreaTarget(selectedText: "plain web selection") },
            copyCapture: { _ in
                SelectionResult(
                    text: "plain web selection",
                    flavors: [PasteboardFlavor(type: "com.example.private", data: Data([0x01, 0x02]))]
                )
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axWebArea)
        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.google.Chrome"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertEqual(result?.text, "plain web selection")
        XCTAssertEqual(result?.flavors.first?.type, "com.example.private")
    }

    // MARK: - Inspect concurrency gate

    func testConcurrentRetrievesBothDeliver() async {
        let inspectStarted = expectation(description: "both inspects started")
        inspectStarted.expectedFulfillmentCount = 2
        inspectStarted.assertForOverFulfill = true
        let unblock = DispatchSemaphore(value: 0)

        let coordinator = SelectionRetrievalCoordinator(
            inspect: {
                inspectStarted.fulfill()
                unblock.wait()
                return Self.textFieldTarget(selectedText: "overlap text")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)

        async let firstResult = coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        async let secondResult = coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )

        await fulfillment(of: [inspectStarted], timeout: 2.0)
        unblock.signal()
        unblock.signal()

        let first = await firstResult
        let second = await secondResult
        XCTAssertEqual(first?.text, "overlap text", "first overlapping gesture must still deliver")
        XCTAssertEqual(second?.text, "overlap text", "second overlapping gesture must not be dropped")
    }

    func testInspectPermitFreesAtWatchdogDeadlineWhileWorkerStillHung() async {
        let zombieUnblock = DispatchSemaphore(value: 0)
        defer { zombieUnblock.signal() }
        let hungCoordinator = SelectionRetrievalCoordinator(
            inspect: {
                zombieUnblock.wait()
                return Self.textFieldTarget(selectedText: "zombie")
            }
        )
        let freshCoordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "fresh") }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)

        let hungResult = await hungCoordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(hungResult, "watchdog must return nil for the hung read")

        let freshStart = Date()
        let freshResult = await freshCoordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertLessThan(Date().timeIntervalSince(freshStart), hungCoordinator.configuration.axReadTimeout,
                          "new read must not wait behind the abandoned hung worker")
        XCTAssertEqual(freshResult?.text, "fresh",
                       "permit must be usable again right after the watchdog deadline")

        zombieUnblock.signal()
    }

    func testConcurrencyCapFailsFastWhenSaturated() async {
        let inspectStarted = expectation(description: "cap-filling inspects started")
        let maxConcurrent = SelectionConfiguration.default.axMaxConcurrentInspects
        inspectStarted.expectedFulfillmentCount = maxConcurrent
        inspectStarted.assertForOverFulfill = true
        let unblock = DispatchSemaphore(value: 0)

        let coordinator = SelectionRetrievalCoordinator(
            inspect: {
                inspectStarted.fulfill()
                unblock.wait()
                return Self.textFieldTarget(selectedText: "parked")
            }
        )
        let policy = AppPolicyContext(retrievalMode: .axTextControl)

        var parkedResults: [Task<SelectionResult?, Never>] = []
        for _ in 0..<maxConcurrent {
            parkedResults.append(Task {
                await coordinator.retrieve(
                    for: AppIdentity(bundleIdentifier: "com.test.app"),
                    policy: policy,
                    cursor: .unknown
                )
            })
        }
        await fulfillment(of: [inspectStarted], timeout: 2.0)

        let start = Date()
        let overflow = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: policy,
            cursor: .unknown
        )
        XCTAssertNil(overflow, "saturated gate must skip the extra read instead of piling up")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3,
                          "the overflow read must fail fast, not queue")

        unblock.signal()
        for _ in 0..<maxConcurrent { unblock.signal() }
        for task in parkedResults {
            let value = await task.value
            XCTAssertEqual(value?.text, "parked")
        }
    }

    func testMenuCopyPressPermitFreesAtWatchdogDeadlineWhileWorkerStillHung() async {
        let pressStarted = expectation(description: "hung menu press started")
        let zombieUnblock = DispatchSemaphore(value: 0)
        defer { zombieUnblock.signal() }

        let hungCoordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { trigger in
                await MainActor.run { trigger() }
                return nil
            },
            menuPress: { _ in
                pressStarted.fulfill()
                zombieUnblock.wait()
            }
        )
        let freshCoordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "fresh") }
        )
        let menuPolicy = AppPolicyContext(retrievalMode: .menuCopy)
        let inspectPolicy = AppPolicyContext(retrievalMode: .axTextControl)

        async let hungResult = hungCoordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.apple.Terminal"),
            policy: menuPolicy,
            cursor: .unknown
        )

        await fulfillment(of: [pressStarted], timeout: 2.0)
        _ = await hungResult

        try? await Task.sleep(nanoseconds: UInt64((hungCoordinator.configuration.axReadTimeout + 0.1) * 1_000_000_000))

        let freshStart = Date()
        let freshResult = await freshCoordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: inspectPolicy,
            cursor: .unknown
        )
        XCTAssertLessThan(Date().timeIntervalSince(freshStart), hungCoordinator.configuration.axReadTimeout,
                          "new read must not wait behind the abandoned hung menu press")
        XCTAssertEqual(freshResult?.text, "fresh",
                       "permit must be usable again right after the press watchdog deadline")
    }

    func testFourHungMenuCopyPressesDoNotPermanentlyLockOutInspect() async {
        let starts = PressStartSignal()
        let maxConcurrent = SelectionConfiguration.default.axMaxConcurrentInspects
        let zombieUnblock = DispatchSemaphore(value: 0)
        defer {
            for _ in 0..<maxConcurrent { zombieUnblock.signal() }
        }

        let hungCoordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { trigger in
                await MainActor.run { trigger() }
                return nil
            },
            menuPress: { _ in
                starts.signal()
                zombieUnblock.wait()
            }
        )
        let freshCoordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: "fresh") }
        )
        let menuPolicy = AppPolicyContext(retrievalMode: .menuCopy)
        let inspectPolicy = AppPolicyContext(retrievalMode: .axTextControl)

        var hungTasks: [Task<SelectionResult?, Never>] = []
        for index in 1...maxConcurrent {
            hungTasks.append(Task {
                await hungCoordinator.retrieve(
                    for: AppIdentity(bundleIdentifier: "com.apple.Terminal"),
                    policy: menuPolicy,
                    cursor: .unknown
                )
            })
            await starts.waitUntil(index)
        }

        let overflowStart = Date()
        let overflow = await freshCoordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: inspectPolicy,
            cursor: .unknown
        )
        XCTAssertNil(overflow, "saturated gate must skip inspect while four hung presses hold permits")
        XCTAssertLessThan(Date().timeIntervalSince(overflowStart), 0.3,
                          "the overflow read must fail fast, not queue")

        try? await Task.sleep(nanoseconds: UInt64((hungCoordinator.configuration.axReadTimeout + 0.1) * 1_000_000_000))

        let recoveredStart = Date()
        let recovered = await freshCoordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.test.app"),
            policy: inspectPolicy,
            cursor: .unknown
        )
        XCTAssertLessThan(Date().timeIntervalSince(recoveredStart), hungCoordinator.configuration.axReadTimeout,
                          "inspect must not stay locked out after press watchdogs fire")
        XCTAssertEqual(recovered?.text, "fresh")

        for task in hungTasks { _ = await task.value }
    }

    // MARK: - Microsoft Office & Copy Guarding (Issue #90)

    func testMicrosoftOfficeCascadesToOfficeScriptAndDoesNotCopy() async {
        final class CopyCounter: @unchecked Sendable { var count = 0 }
        let copyCounter = CopyCounter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in
                copyCounter.count += 1
                return SelectionResult(text: "clobbered copy")
            },
            scriptRunner: { script in
                XCTAssertTrue(script.contains("com.microsoft.Word"))
                return "text from word selection"
            }
        )

        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.Word"),
            policy: AppPolicyContext(retrievalMode: .axTextControl),
            cursor: .unknown
        )

        XCTAssertEqual(result?.text, "text from word selection")
        XCTAssertEqual(copyCounter.count, 0, "Office must be retrieved via AppleScript without firing copy")
    }

    func testMicrosoftOfficeWithMissingValueReturnsNilWithoutFallback() async {
        final class CopyCounter: @unchecked Sendable { var count = 0 }
        let copyCounter = CopyCounter()
        let coordinator = SelectionRetrievalCoordinator(
            inspect: { Self.textFieldTarget(selectedText: nil) },
            copyCapture: { _ in
                copyCounter.count += 1
                return SelectionResult(text: "clobbered copy")
            },
            scriptRunner: { _ in "missing value" }
        )

        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.Word"),
            policy: AppPolicyContext(retrievalMode: .axTextControl),
            cursor: .unknown
        )

        XCTAssertNil(result, "missing value indicates no active selection in Word")
        XCTAssertEqual(copyCounter.count, 0, "Must never fall back to keyboard copy in Office")
    }

    func testMicrosoftOfficeScriptTemplates() {
        XCTAssertTrue(SelectionRetrievalCoordinator.isMicrosoftOffice("com.microsoft.Word"))
        XCTAssertTrue(SelectionRetrievalCoordinator.isMicrosoftOffice("com.microsoft.Excel"))
        XCTAssertTrue(SelectionRetrievalCoordinator.isMicrosoftOffice("com.microsoft.Powerpoint"))
        XCTAssertFalse(SelectionRetrievalCoordinator.isMicrosoftOffice("com.apple.TextEdit"))

        let wordScript = SelectionRetrievalCoordinator.officeScript(for: "com.microsoft.Word")
        XCTAssertTrue(wordScript?.contains("com.microsoft.Word") == true)
        XCTAssertTrue(wordScript?.contains("content of text object of selection") == true)

        let excelScript = SelectionRetrievalCoordinator.officeScript(for: "com.microsoft.Excel")
        XCTAssertTrue(excelScript?.contains("com.microsoft.Excel") == true)
        XCTAssertTrue(excelScript?.contains("string value of selection") == true)

        let pptScript = SelectionRetrievalCoordinator.officeScript(for: "com.microsoft.Powerpoint")
        XCTAssertTrue(pptScript?.contains("com.microsoft.Powerpoint") == true)
        XCTAssertTrue(pptScript?.contains("content of text range of selection") == true)
    }

    /// Regression: a blank row inside a selected Excel range must survive as an empty line. The
    /// 2D AppleScript descriptor's inner rows are flattened to TSV, so dropping an all-empty row
    /// silently collapsed `A\n\nB` to `A\nB`.
    func testExtractStringPreservesBlankRowInExcelRange() {
        func row(_ cells: [String?]) -> NSAppleEventDescriptor {
            let list = NSAppleEventDescriptor.list()
            for (offset, cell) in cells.enumerated() {
                let descriptor = cell.map { NSAppleEventDescriptor(string: $0) } ?? NSAppleEventDescriptor.null()
                list.insert(descriptor, at: offset + 1)
            }
            return list
        }
        let range = NSAppleEventDescriptor.list()
        range.insert(row(["A"]), at: 1)
        range.insert(row([nil]), at: 2)
        range.insert(row(["B"]), at: 3)

        XCTAssertEqual(
            SelectionRetrievalCoordinator.extractString(from: range),
            "A\n\nB",
            "A blank row inside an Excel range must stay as a row separator"
        )
    }

    func testMicrosoftOfficeScriptTimeoutReturnsNil() async {
        var config = SelectionConfiguration.default
        config.officeScriptTimeout = 0.05
        let coordinator = SelectionRetrievalCoordinator(
            configuration: config,
            inspect: { Self.textFieldTarget(selectedText: nil) },
            scriptRunner: { _ in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return "late response"
            }
        )

        let result = await coordinator.retrieve(
            for: AppIdentity(bundleIdentifier: "com.microsoft.Word"),
            policy: SelectionPolicy(strategy: .axTextControl),
            cursor: .unknown
        )

        XCTAssertNil(result, "Office script exceeding timeout must return nil")
    }
}

private final class PressStartSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        lock.lock()
        count += 1
        let n = count
        let ready = waiters.filter { n >= $0.0 }
        waiters.removeAll { $0.0 <= n }
        lock.unlock()
        ready.forEach { $0.1.resume() }
    }

    func waitUntil(_ target: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if count >= target {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((target, continuation))
            lock.unlock()
        }
    }
}

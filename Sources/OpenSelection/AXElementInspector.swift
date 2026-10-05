// AXElementInspector.swift
// OpenSelection
//
// Fresh, one-shot resolution of the focused application and its focused UI element via the
// macOS accessibility API. Nothing is cached — every `inspect()` call resolves against the
// live accessibility tree.
import ApplicationServices
import CoreGraphics
import Foundation

public struct AXElementInspector {
    /// A snapshot of the focused application and UI element plus the AX attributes needed to
    /// gate and retrieve a text selection.
    ///
    /// `@unchecked Sendable` because it is an immutable snapshot of AX attribute values: the
    /// CF-type members are never mutated and are safe to hand from the blocking inspect worker to
    /// the consuming strategy.
    public struct Target: @unchecked Sendable {
        public let focusedApp: AXUIElement?
        public let focusedElement: AXUIElement?
        public let role: String?
        public let subRole: String?
        public let parentRoles: Set<String>
        public let containedInRoles: Set<String>
        public let webArea: AXUIElement?
        public let selectedText: String?
        public let selectedTextMarkerRange: AnyObject?
        /// The element `selectedTextMarkerRange` was read from. The parameterized
        /// `AXStringForTextMarkerRange` / `AXBoundsForTextMarkerRange` queries must be issued
        /// against this owner: Chromium can collapse the page's selection when a marker range is
        /// asked of a foreign element (e.g. the containing web area rather than the focused node).
        public let selectedTextMarkerRangeOwner: AXUIElement?
        /// `AXStringForTextMarkerRange` for `selectedTextMarkerRange`, resolved at inspect time.
        /// A non-nil range whose string is empty/absent is not a real text selection (Figma's
        /// canvas reports a marker range with no text); a non-empty string is strong, cursor-
        /// independent evidence of selected text in web/Electron content.
        public let selectedMarkerText: String?
        public let value: String?
        public let selectedTextRange: AnyObject?
        public let bounds: CGRect?

        public init(
            focusedApp: AXUIElement? = nil,
            focusedElement: AXUIElement? = nil,
            role: String? = nil,
            subRole: String? = nil,
            parentRoles: Set<String> = [],
            containedInRoles: Set<String> = [],
            webArea: AXUIElement? = nil,
            selectedText: String? = nil,
            selectedTextMarkerRange: AnyObject? = nil,
            selectedTextMarkerRangeOwner: AXUIElement? = nil,
            selectedMarkerText: String? = nil,
            value: String? = nil,
            selectedTextRange: AnyObject? = nil,
            bounds: CGRect? = nil
        ) {
            self.focusedApp = focusedApp
            self.focusedElement = focusedElement
            self.role = role
            self.subRole = subRole
            self.parentRoles = parentRoles
            self.containedInRoles = containedInRoles
            self.webArea = webArea
            self.selectedText = selectedText
            self.selectedTextMarkerRange = selectedTextMarkerRange
            self.selectedTextMarkerRangeOwner = selectedTextMarkerRangeOwner
            self.selectedMarkerText = selectedMarkerText
            self.value = value
            self.selectedTextRange = selectedTextRange
            self.bounds = bounds
        }
    }

    /// Maximum number of ancestor levels walked when collecting parent/container roles and
    /// hunting for a containing web area.
    public static let ancestorWalkDepth = 25

    /// Canonical AX role string for WebKit web content.
    public static let webAreaRole = "AXWebArea"

    /// Canonical AX attribute string for a web area's selected text marker range.
    public static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"

    /// Canonical AX attribute string resolving a marker range to its text.
    private static let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"

    /// Resolve the focused application FIRST, then its focused UI element — fresh every call.
    ///
    /// Resolution order matters for reliability: the focused application is read from the
    /// system-wide element, and the focused UI element is then read from THAT application
    /// element. Reading `kAXFocusedUIElementAttribute` directly off the system-wide element
    /// is the classic source of stale or missing selection reads.
    public static func inspect(ancestorDepth: Int = ancestorWalkDepth, trace: SelectionTrace? = nil) -> Target {
        trace?.log(.trace, .ax, "ax inspect started")
        // Past the caller's watchdog: any result here is discarded, so skip the IPC storm
        // entirely and free the worker (and its concurrency permit) immediately.
        guard Self.isLive(trace: trace) else { return Target() }
        let systemWide = AXUIElementCreateSystemWide()

        // 1. Focused application — from the system-wide element.
        //
        // Explicit global-timeout policy: this query deliberately uses the unbounded `read`,
        // never `boundedRead`. Per Apple's SDK, setting a messaging timeout on the system-wide
        // element changes the process-global AX default, which unrelated AX clients and
        // no-deadline diagnostic callers would then inherit without knowing. Every other query
        // below runs against per-call element proxies, so capping those is side-effect free.
        // Residual exposure is a single process-default-bounded call per inspect, after which
        // the walk aborts near the deadline as usual.
        let focusedApp = read(systemWide, kAXFocusedApplicationAttribute, trace: trace).flatMap { axElement($0) }

        // 2. Focused UI element — from the focused application element, never system-wide.
        let focusedElement = focusedApp.flatMap { axElement(boundedRead($0, kAXFocusedUIElementAttribute, trace: trace)) }

        var role: String?
        var subRole: String?
        var parentRoles: Set<String> = []
        var containedInRoles: Set<String> = []
        var webArea: AXUIElement?

        if let focusedElement {
            role = boundedRead(focusedElement, kAXRoleAttribute, trace: trace) as? String
            subRole = boundedRead(focusedElement, kAXSubroleAttribute, trace: trace) as? String

            if role == webAreaRole {
                webArea = focusedElement
            }

            // Walk ancestors (bounded) for parent/container roles and web-area detection.
            var current = focusedElement
            for _ in 0..<ancestorDepth {
                guard Self.isLive(trace: trace) else { break }
                guard let parent = axElement(boundedRead(current, kAXParentAttribute, trace: trace)) else { break }
                if CFEqual(parent, current) { break }
                if let parentRole = boundedRead(parent, kAXRoleAttribute, trace: trace) as? String {
                    parentRoles.insert(parentRole)
                    containedInRoles.insert(parentRole)
                }
                if webArea == nil, boundedRead(parent, kAXRoleAttribute, trace: trace) as? String == webAreaRole {
                    webArea = parent
                }
                current = parent
            }
        }

        // Fallback: If focusedElement was not inside an AXWebArea (e.g. user selected static text on a page
        // so focus remained at the window or outer container level), search the focused window for the active AXWebArea.
        if shouldSearchWindowForWebArea(focusedRole: role, webArea: webArea), let app = focusedApp,
           let window = boundedRead(app, kAXFocusedWindowAttribute, trace: trace).flatMap({ axElement($0) }) {
            // The budget-aware read below short-circuits to nil past the deadline, which ends
            // the depth-first search without further IPC instead of parking the worker.
            webArea = findFirstChild(role: webAreaRole, in: window, maxDepth: 6, read: {
                boundedRead($0, $1, trace: trace)
            })
        }

        // Text/value attributes and selection bounds, where supported.
        let selectedText = focusedElement.flatMap { boundedRead($0, kAXSelectedTextAttribute, trace: trace) as? String }
        // Resolve the selected marker range together with the element that owns it, so the
        // parameterized string query is never issued against a foreign element: Chromium reacts to
        // an `AXSelectedTextMarkerRange` asked of the wrong element, which can collapse the
        // page's selection. `AXStringForTextMarkerRange` is therefore always run on the same
        // element the range was read from.
        let marker: (owner: AXUIElement, range: AnyObject)?
        if let focusedElement, let range = boundedRead(focusedElement, selectedTextMarkerRangeAttribute, trace: trace) {
            marker = (focusedElement, range)
        } else if let webArea, let range = boundedRead(webArea, selectedTextMarkerRangeAttribute, trace: trace) {
            marker = (webArea, range)
        } else {
            marker = nil
        }
        let selectedTextMarkerRange = marker?.range
        let selectedTextMarkerRangeOwner = marker?.owner
        let selectedMarkerText = marker.flatMap { markerText(for: $0.owner, markerRange: $0.range, trace: trace) }
        let value = focusedElement.flatMap { boundedRead($0, kAXValueAttribute, trace: trace) as? String }
        let selectedTextRange = focusedElement.flatMap { boundedRead($0, kAXSelectedTextRangeAttribute, trace: trace) }
        let bounds = bounds(for: focusedElement, range: selectedTextRange, trace: trace)

        return Target(
            focusedApp: focusedApp,
            focusedElement: focusedElement,
            role: role,
            subRole: subRole,
            parentRoles: parentRoles,
            containedInRoles: containedInRoles,
            webArea: webArea,
            selectedText: selectedText,
            selectedTextMarkerRange: selectedTextMarkerRange,
            selectedTextMarkerRangeOwner: selectedTextMarkerRangeOwner,
            selectedMarkerText: selectedMarkerText,
            value: value,
            selectedTextRange: selectedTextRange,
            bounds: bounds
        )
    }

    /// Whether `inspect()` should run the window-wide web-area search.
    ///
    /// Only when focus sits at a window/container level. A focused native text control already
    /// exposes its own selection, and the search is expensive in apps with large AX trees: Apple
    /// Notes walks its folder sidebar and note list (~420 AX calls, 0.6–1.1 s), overrunning the
    /// inspect deadline so no selection is ever read.
    static func shouldSearchWindowForWebArea(focusedRole: String?, webArea: AXUIElement?) -> Bool {
        guard webArea == nil else { return false }
        guard let focusedRole else { return true }
        return !SelectionRetrievalCoordinator.textEvidenceRoles.contains(focusedRole)
    }

    /// Reads `AXSelectedTextMarkerRange` attribute from `focusedElement`, falling back to `webArea` if `focusedElement` is nil or yields no marker range.
    public static func selectedTextMarkerRange(
        focusedElement: AXUIElement?,
        webArea: AXUIElement?,
        read: (AXUIElement, String) -> CFTypeRef? = { read($0, $1) }
    ) -> AnyObject? {
        focusedElement.flatMap { read($0, selectedTextMarkerRangeAttribute) } ?? webArea.flatMap { read($0, selectedTextMarkerRangeAttribute) }
    }

    /// Resolves an `AXSelectedTextMarkerRange` to its text via `AXStringForTextMarkerRange`.
    ///
    /// Returns `nil` unless `markerRange` really is an `AXTextMarkerRange` on `element` and the
    /// parameterized query succeeds. A marker range with no text resolves to `nil`/empty — the
    /// distinction that keeps a web canvas (Figma) from looking like a text selection.
    public static func markerText(for element: AXUIElement?, markerRange: AnyObject?, trace: SelectionTrace? = nil) -> String? {
        guard let element, let markerRange, CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() else { return nil }
        guard prepareParameterized(element, trace: trace) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, stringForTextMarkerRangeAttribute as CFString, markerRange as! AXTextMarkerRange, &value
        ) == .success else { return nil }
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Bounded depth-first search for a descendant UI element matching `role`.
    public static func findFirstChild(
        role: String,
        in element: AXUIElement,
        maxDepth: Int,
        read: (AXUIElement, String) -> CFTypeRef? = { read($0, $1) }
    ) -> AXUIElement? {
        guard maxDepth >= 0 else { return nil }
        if (read(element, kAXRoleAttribute) as? String) == role {
            return element
        }
        guard maxDepth > 0 else { return nil }
        guard let childrenVal = read(element, kAXChildrenAttribute),
              CFGetTypeID(childrenVal) == CFArrayGetTypeID() else { return nil }
        guard let children = childrenVal as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findFirstChild(role: role, in: child, maxDepth: maxDepth - 1, read: read) {
                return found
            }
        }
        return nil
    }

    /// Reads a single AX attribute, returning an `AXReadResult` containing either the value
    /// or the unmasked `AXErrorCode`.
    public static func readResult(
        _ element: AXUIElement,
        _ attribute: String,
        trace: SelectionTrace? = nil
    ) -> AXReadResult<CFTypeRef> {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if err == .success, let value {
            return .value(value)
        }
        let code = AXErrorCode(axError: err)
        if let trace, code != .noValue, code != .attributeUnsupported {
            trace.log(.trace, .ax, "ax attribute read failed", fields: [
                "attribute": .token(attribute),
                "error": .ax(code)
            ])
        }
        return .failure(code)
    }

    /// Reads a single AX attribute, returning `nil` on any error or unsupported attribute.
    public static func read(_ element: AXUIElement, _ attribute: String, trace: SelectionTrace? = nil) -> CFTypeRef? {
        readResult(element, attribute, trace: trace).valueOrNil
    }

    /// Minimum per-call AX messaging timeout: avoids zero-timeout failures when the deadline
    /// is nearly exhausted while keeping any overrun negligible.
    private static let minPerCallTimeout: TimeInterval = 0.02

    /// Whether this inspect may still issue AX IPC. Past the trace deadline any result is
    /// discarded by the caller's watchdog, so workers must stop instead of parking on IPC.
    private static func isLive(trace: SelectionTrace?) -> Bool {
        guard let remaining = remainingBudget(trace: trace) else { return true }
        return remaining > 0
    }

    /// Remaining AX budget for this inspect (monotonic; see `remainingAXBudget`), or `nil`
    /// when no trace deadline constrains it.
    private static func remainingBudget(trace: SelectionTrace?) -> TimeInterval? {
        trace?.remainingAXBudget
    }

    /// Deadline-aware single-attribute read for `inspect`.
    ///
    /// Without a trace deadline this is exactly `read` (legacy behavior, and the path every
    /// diagnostic/test caller takes). With one, an expired deadline skips the IPC entirely,
    /// and a live one caps the per-call messaging timeout to the remaining budget so a
    /// stalled target app cannot park this worker — and its concurrency-gate permit — far
    /// past the watchdog. Calls that could only finish after the caller's watchdog already
    /// fired produce discarded results, so bounding them changes nothing the caller observes.
    private static func boundedRead(_ element: AXUIElement, _ attribute: String, trace: SelectionTrace?) -> CFTypeRef? {
        guard let remaining = remainingBudget(trace: trace) else {
            return read(element, attribute, trace: trace)
        }
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(max(minPerCallTimeout, remaining)))
        return read(element, attribute, trace: trace)
    }

    /// Deadline gate for parameterized AX queries (`AXStringForTextMarkerRange`,
    /// `AXBoundsForTextMarkerRange`). Sets the element's messaging timeout to the remaining
    /// budget. Returns `false` when no query may be issued (expired deadline).
    private static func prepareParameterized(_ element: AXUIElement, trace: SelectionTrace?) -> Bool {
        guard remainingBudget(trace: trace) != nil else { return true }
        guard let remaining = remainingBudget(trace: trace), remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(max(minPerCallTimeout, remaining)))
        return true
    }

    /// Returns the value as an `AXUIElement` only when it actually is one.
    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element: AXUIElement = value as! AXUIElement
        return element
    }

    /// The selection bounds for a text range via `kAXBoundsForRangeParameterizedAttribute`,
    /// or `nil` when the element or range does not support it.
    private static func bounds(for element: AXUIElement?, range: CFTypeRef?, trace: SelectionTrace? = nil) -> CGRect? {
        guard let element, let range else { return nil }
        guard prepareParameterized(element, trace: trace) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsRef
        ) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}

// AXWebAreaStrategy.swift
// OpenSelection
//
// Reads selected text and bounds for WebKit web areas from an
// AXElementInspector.Target snapshot or directly from an AXUIElement.
import ApplicationServices
import CoreGraphics
import Foundation

public enum AXWebAreaStrategy {
    /// Canonical AX attribute string for a web area's selected text marker range.
    public static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let stringForTextMarkerRangeAttribute = "AXStringForTextMarkerRange"
    private static let boundsForTextMarkerRangeAttribute = "AXBoundsForTextMarkerRange"

    /// Messaging timeout for the fresh reads below, matching the default AX watchdog.
    ///
    /// The elements handed in can carry near-zero messaging timeouts left behind by a
    /// deadline-capped inspect walk. Every query here must set its own timeout first:
    /// inheriting the leftover would turn responsive apps into spurious misses. On a
    /// responsive app this changes nothing (fast queries never approach it); on a stalled
    /// app it fails fast instead of parking on the process-default timeout.
    private static let freshReadTimeout: TimeInterval = 0.5

    /// kAXSelectedTextMarkerRange → AXStringForTextMarkerRange; bounds via
    /// AXBoundsForTextMarkerRange.
    public static func read(from target: AXElementInspector.Target) -> SelectionResult? {
        // Fast path: use already resolved marker text from the inspect snapshot
        if let markerText = target.selectedMarkerText, TextSanitizer.isSubstantial(markerText) {
            let bounds: CGRect?
            if let element = target.selectedTextMarkerRangeOwner ?? target.webArea ?? target.focusedElement,
               let markerRange = target.selectedTextMarkerRange,
               CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() {
                bounds = Self.bounds(for: element, markerRange: markerRange as! AXTextMarkerRange)
            } else {
                bounds = target.bounds
            }
            return SelectionResult(
                text: markerText,
                bounds: bounds,
                strategy: .axWebArea,
                isEditable: false
            )
        }

        // Marker-range path. The marker range must actually be an AXTextMarkerRange before
        // the live web area is asked to resolve it; under a fixture it is a plain object and
        // this strategy falls through to selectedText below.
        if let element = target.selectedTextMarkerRangeOwner ?? target.webArea ?? target.focusedElement,
           let markerRange = target.selectedTextMarkerRange,
           CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() {
            let range = markerRange as! AXTextMarkerRange
            if let text = string(for: element, markerRange: range), TextSanitizer.isSubstantial(text) {
                return SelectionResult(
                    text: text,
                    bounds: bounds(for: element, markerRange: range),
                    strategy: .axWebArea,
                    isEditable: false
                )
            }
        }

        guard let text = target.selectedText, TextSanitizer.isSubstantial(text) else { return nil }
        return SelectionResult(
            text: text,
            bounds: target.bounds,
            strategy: .axWebArea,
            isEditable: false
        )
    }

    /// Re-queries `element` directly for fresh selection text and bounds, avoiding
    /// full system-wide ancestor tree re-inspections during settle-retry polling.
    public static func pollFresh(from element: AXUIElement) -> SelectionResult? {
        AXUIElementSetMessagingTimeout(element, Float(freshReadTimeout))
        var markerValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, selectedTextMarkerRangeAttribute as CFString, &markerValue) == .success,
           let markerRange = markerValue,
           CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() {
            let range = markerRange as! AXTextMarkerRange
            if let text = string(for: element, markerRange: range), TextSanitizer.isSubstantial(text) {
                return SelectionResult(
                    text: text,
                    bounds: bounds(for: element, markerRange: range),
                    strategy: .axWebArea,
                    isEditable: false
                )
            }
        }

        var textValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textValue) == .success,
           let text = textValue as? String, TextSanitizer.isSubstantial(text) {
            return SelectionResult(
                text: text,
                bounds: nil,
                strategy: .axWebArea,
                isEditable: false
            )
        }

        return nil
    }

    private static func string(for element: AXUIElement, markerRange: AXTextMarkerRange) -> String? {
        AXUIElementSetMessagingTimeout(element, Float(freshReadTimeout))
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, stringForTextMarkerRangeAttribute as CFString, markerRange, &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func bounds(for element: AXUIElement, markerRange: AXTextMarkerRange) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, Float(freshReadTimeout))
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, boundsForTextMarkerRangeAttribute as CFString, markerRange, &value
        ) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}

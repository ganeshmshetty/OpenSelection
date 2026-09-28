import AppKit

/// Window-server geometry lets the monitor reject moves/resizes even when an old text
/// selection remains focused. No window titles or contents are read.
public struct SelectionGestureWindow: Sendable {
    public let id: CGWindowID
    public let frame: CGRect

    public init(id: CGWindowID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }

    @MainActor
    public static func at(_ point: CGPoint) -> SelectionGestureWindow? {
        guard NSClassFromString("XCTestCase") == nil,
              let screenTop = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let screenPoint = CGPoint(x: point.x, y: screenTop - point.y)
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ProcessInfo.processInfo.processIdentifier,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let frame = bounds(of: window), frame.contains(screenPoint) else { continue }
            return SelectionGestureWindow(id: id, frame: frame)
        }
        return nil
    }

    public static func currentFrame(for id: CGWindowID) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let window = windows.first else { return nil }
        return bounds(of: window)
    }

    private static func bounds(of window: [String: Any]) -> CGRect? {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}

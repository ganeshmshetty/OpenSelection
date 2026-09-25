// KeyboardEventPoster.swift
// OpenSelection
//
// Posts synthetic keyboard events to the system session event tap.
import CoreGraphics
import Foundation

public struct KeyboardEventPoster: Sendable {
    /// Stamped into `eventSourceUserData` on every synthetic key event so a global key monitor can
    /// tell OpenSelection's own ⌘C/⌘X apart from the user's. Arbitrary but stable; fits in Int64.
    public static let syntheticEventTag: Int64 = 0x4F53434C // "OSCL"

    public init() {}

    /// Posts a synthetic key down and key up event with the specified flags.
    public static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let resolvedFlags = CGEventFlags(rawValue: flags.rawValue | 0x000008)
        if let keydown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let keyup = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            keydown.flags = resolvedFlags
            keyup.flags = resolvedFlags
            keydown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            keyup.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            keydown.post(tap: .cgSessionEventTap)
            keyup.post(tap: .cgSessionEventTap)
        }
    }
}

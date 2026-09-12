// KeyboardEventPoster.swift
// OpenSelection
//
// Posts synthetic keyboard events to the system session event tap.
import CoreGraphics
import Foundation

public struct KeyboardEventPoster: Sendable {
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
            keydown.post(tap: .cgSessionEventTap)
            keyup.post(tap: .cgSessionEventTap)
        }
    }
}

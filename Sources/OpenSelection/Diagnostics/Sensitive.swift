// Sensitive.swift
// OpenSelection
//
// Compile-time privacy wrapper preventing accidental string interpolation
// or logging of user payload data.
import Foundation

/// A type-safe container for user data (selected text, clipboard data, HTML, RTF).
///
/// Deliberately omits `CustomStringConvertible`, `CustomDebugStringConvertible`,
/// and `Codable` to prevent accidental serialization into diagnostic logs or telemetry.
public struct Sensitive<T: Sendable>: Sendable {
    private let value: T

    public init(_ value: T) {
        self.value = value
    }

    /// Explicitly reveals the sensitive payload for intended domain processing.
    public func unwrap() -> T {
        value
    }
}

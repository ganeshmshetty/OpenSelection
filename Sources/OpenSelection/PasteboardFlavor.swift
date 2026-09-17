// PasteboardFlavor.swift
// OpenSelection
//
// A single raw pasteboard representation (UTI + bytes). Preserving every flavor lets a caller paste
// content back verbatim instead of rebuilding it from plain/RTF/HTML — the only way to round-trip
// app-private types such as Notes checklists, which have no RTF equivalent.
import Foundation

public struct PasteboardFlavor: Sendable, Equatable {
    /// The pasteboard type UTI (e.g. `public.rtf`, `com.apple.notes.richtext`).
    public let type: String

    /// The raw bytes declared for `type`.
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

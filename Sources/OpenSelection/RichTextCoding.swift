// RichTextCoding.swift
// OpenSelection
//
// Byte-faithful bridging for pasteboard RTF payloads.
import Foundation

/// Converts between pasteboard RTF `Data` and the `String` representation the selection API exposes.
///
/// RTF is a byte format: it can embed binary via `\bin`, and raw high-bit bytes appear under some
/// `\ansicpg` code pages. Bridging through UTF-8 alone (`String(data:encoding:.utf8)`) silently drops
/// any payload that is not valid UTF-8. These helpers decode UTF-8 when possible and fall back to
/// ISO Latin-1 (which maps every byte 0x00–0xFF to the same scalar), and encode back with Latin-1
/// when the string is representable so a capture→replace round trip preserves the original bytes.
enum RichTextCoding {
    static func string(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return String(data: data, encoding: .isoLatin1)
    }

    static func data(from string: String) -> Data? {
        if string.unicodeScalars.allSatisfy({ $0.value <= 0xFF }), let latin1 = string.data(using: .isoLatin1) {
            return latin1
        }
        return string.data(using: .utf8)
    }
}

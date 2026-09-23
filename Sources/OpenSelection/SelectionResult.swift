// SelectionResult.swift
// OpenSelection
//
// Represents the outcome of a selection retrieval operation, including text, bounds,
// rich formatting representations, source application, and the winning strategy.
import AppKit
import CoreGraphics
import Foundation

public struct SelectionResult: Sendable, Equatable {
    /// The retrieved selection text, trimmed of leading/trailing invisible artifacts.
    public let text: String

    /// The on-screen bounding rectangle of the selection in global display coordinates, if available.
    public let bounds: CGRect?

    /// The rich HTML representation written by web views or rich text editors, if available.
    public let html: String?

    /// The rich RTF representation written by rich text editors, if available.
    public let rtf: String?

    /// Every raw pasteboard representation captured for the selection, if it was read via copy.
    /// Carries app-private types (e.g. `com.apple.notes.richtext`) that RTF/HTML cannot express,
    /// so they can be written back verbatim on paste.
    public let flavors: [PasteboardFlavor]

    /// The frontmost application owning the selection at the time of retrieval.
    public let sourceApp: NSRunningApplication?

    /// The retrieval strategy that successfully extracted this selection.
    public let strategy: SelectionStrategy

    /// Whether the selection was made inside an editable text context (e.g. text field, text area).
    public let isEditable: Bool

    public init(
        text: String,
        bounds: CGRect? = nil,
        html: String? = nil,
        rtf: String? = nil,
        flavors: [PasteboardFlavor] = [],
        sourceApp: NSRunningApplication? = nil,
        strategy: SelectionStrategy = .axTextControl,
        isEditable: Bool = false
    ) {
        self.text = text
        self.bounds = bounds
        self.html = html
        self.rtf = rtf
        self.flavors = flavors
        self.sourceApp = sourceApp
        self.strategy = strategy
        self.isEditable = isEditable
    }

    /// Layout-accurate plain text.
    /// If the raw selection text was extracted from an accessibility tree that flattened
    /// block DOM elements into a single continuous line, but rich HTML is available,
    /// this reconstructs the intended layout breaks (\n for paragraph, list, and line breaks).
    ///
    /// - Note: Uses WebKit-backed HTML import and AppKit RTF import, which must run on the main actor.
    @MainActor
    public var formattedText: String {
        // If the plain text already has line breaks, use it directly.
        if text.contains("\n") || text.contains("\r") {
            return text
        }
        if let html, !html.isEmpty, Self.hasBlockTags(html), let extracted = Self.plainText(fromHTML: html), !extracted.isEmpty {
            return extracted
        }
        // Native rich editors (Notes, Pages, TextEdit, Mail) often expose RTF without HTML.
        if let rtf, !rtf.isEmpty, let extracted = Self.plainText(fromRTF: rtf), !extracted.isEmpty {
            return extracted
        }
        return text
    }

    /// Fast check for whether an HTML snippet contains structural block tags that would introduce line breaks.
    public static func hasBlockTags(_ html: String) -> Bool {
        html.range(of: "<(p|br|div|li|tr|h[1-6])[\\s/>]", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Converts rich HTML into clean plain text preserving paragraph breaks.
    ///
    /// - Note: WebKit-backed HTML import must run on the main actor.
    @MainActor
    public static func plainText(fromHTML html: String) -> String? {
        guard let data = html.data(using: .utf8) else { return nil }
        if let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            let extracted = attributed.string.trimmingCharacters(in: TextSanitizer.invisibleCharacterSet)
            return extracted.isEmpty ? nil : extracted
        }
        return nil
    }

    /// Converts rich RTF into clean plain text preserving paragraph breaks.
    ///
    /// - Note: AppKit RTF import must run on the main actor.
    @MainActor
    public static func plainText(fromRTF rtf: String) -> String? {
        guard let data = RichTextCoding.data(from: rtf),
              let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        let extracted = attributed.string.trimmingCharacters(in: TextSanitizer.invisibleCharacterSet)
        return extracted.isEmpty ? nil : extracted
    }

    /// Content metrics (lines, paragraphs, words, characters) for extensions and analytics.
    public struct ContentMetrics: Sendable, Equatable {
        public let characters: Int
        public let words: Int
        public let lines: Int
        public let paragraphs: Int

        public init(characters: Int, words: Int, lines: Int, paragraphs: Int) {
            self.characters = characters
            self.words = words
            self.lines = lines
            self.paragraphs = paragraphs
        }
    }

    /// Computed content metrics based on `formattedText`.
    ///
    /// - Note: Inherits `formattedText`'s main-actor isolation (WebKit-backed HTML import).
    @MainActor
    public var metrics: ContentMetrics {
        let content = formattedText
        guard !content.isEmpty else {
            return ContentMetrics(characters: 0, words: 0, lines: 0, paragraphs: 0)
        }
        let chars = content.count
        var lines = 0
        content.enumerateSubstrings(in: content.startIndex..<content.endIndex, options: [.byLines]) { substring, _, _, _ in
            if let s = substring, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines += 1
            }
        }
        var paragraphs = 0
        content.enumerateSubstrings(in: content.startIndex..<content.endIndex, options: [.byParagraphs]) { substring, _, _, _ in
            if let s = substring, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paragraphs += 1
            }
        }
        let words = content.split { $0.isWhitespace || $0.isNewline }.count
        return ContentMetrics(
            characters: chars,
            words: words,
            lines: max(lines, 1),
            paragraphs: max(paragraphs, 1)
        )
    }
}

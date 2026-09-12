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
        sourceApp: NSRunningApplication? = nil,
        strategy: SelectionStrategy = .axTextControl,
        isEditable: Bool = false
    ) {
        self.text = text
        self.bounds = bounds
        self.html = html
        self.rtf = rtf
        self.sourceApp = sourceApp
        self.strategy = strategy
        self.isEditable = isEditable
    }
}

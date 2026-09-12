// SelectionStrategy.swift
// OpenSelection
//
// Public enum defining the selection retrieval strategy mechanisms.
import Foundation

public enum SelectionStrategy: String, Codable, Sendable, CaseIterable {
    case axTextControl = "ax-text-control"
    case axWebArea = "ax-web-area"
    case menuCopy = "menu-copy"
    case keyboardCopy = "keyboard-copy"
    case officeScript = "office-script"
}

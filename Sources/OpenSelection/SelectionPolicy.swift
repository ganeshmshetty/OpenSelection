// SelectionPolicy.swift
// OpenSelection
//
// Application policy defining gate rules and preferred retrieval strategy.
import Foundation

public struct SelectionPolicy: Sendable, Equatable {
    public var strategy: SelectionStrategy?
    public var gate: SelectionGatePolicy
    public var disabled: Bool
    public var hotkeyOnly: Bool
    public var denyPaste: Bool

    public var retrievalMode: SelectionStrategy {
        strategy ?? .axTextControl
    }

    public init(
        strategy: SelectionStrategy? = nil,
        gate: SelectionGatePolicy = .default,
        disabled: Bool = false,
        hotkeyOnly: Bool = false,
        denyPaste: Bool = false
    ) {
        self.strategy = strategy
        self.gate = gate
        self.disabled = disabled
        self.hotkeyOnly = hotkeyOnly
        self.denyPaste = denyPaste
    }

    /// Convenience initializer compatible with application policy contexts.
    public init(
        disabled: Bool = false,
        hotkeyOnly: Bool = false,
        denyPaste: Bool = false,
        useMenuCopy: Bool = false,
        retrievalMode: SelectionStrategy = .axTextControl,
        gate: SelectionGatePolicy = .default
    ) {
        self.strategy = useMenuCopy ? .menuCopy : retrievalMode
        self.gate = gate
        self.disabled = disabled
        self.hotkeyOnly = hotkeyOnly
        self.denyPaste = denyPaste
    }

    public static let `default` = SelectionPolicy()
}

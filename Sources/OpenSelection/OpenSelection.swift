// OpenSelection.swift
// OpenSelection
//
// High-level public facade for selection retrieval across active macOS applications.
import AppKit
import Foundation
import os

public typealias OpenSelectionCursorClass = CursorClass
public typealias OpenSelectionAppIdentity = AppIdentity
public typealias OpenSelectionGatePolicy = SelectionGatePolicy
public typealias OpenSelectionResult = SelectionResult
public typealias OpenSelectionPolicy = SelectionPolicy
public typealias OpenSelectionStrategy = SelectionStrategy
public typealias OpenSelectionConfiguration = SelectionConfiguration
public typealias OpenSelectionCoordinator = SelectionRetrievalCoordinator
public typealias OpenSelectionReplacer = SelectionReplacer
public typealias OpenSelectionMonitorType = OpenSelectionMonitor
public typealias OpenSelectionPasteAvailabilityProbe = PasteAvailabilityProbe

public enum OpenSelection: Sendable {
    public typealias CursorClass = OpenSelectionCursorClass
    public typealias AppIdentity = OpenSelectionAppIdentity
    public typealias GatePolicy = OpenSelectionGatePolicy
    public typealias SelectionGatePolicy = OpenSelectionGatePolicy
    public typealias Result = OpenSelectionResult
    public typealias SelectionResult = OpenSelectionResult
    public typealias Policy = OpenSelectionPolicy
    public typealias SelectionPolicy = OpenSelectionPolicy
    public typealias Strategy = OpenSelectionStrategy
    public typealias SelectionStrategy = OpenSelectionStrategy
    public typealias Configuration = OpenSelectionConfiguration
    public typealias SelectionConfiguration = OpenSelectionConfiguration
    public typealias Coordinator = OpenSelectionCoordinator
    public typealias SelectionRetrievalCoordinator = OpenSelectionCoordinator
    public typealias Replacer = OpenSelectionReplacer
    public typealias SelectionReplacer = OpenSelectionReplacer
    public typealias Monitor = OpenSelectionMonitorType
    public typealias OpenSelectionMonitor = OpenSelectionMonitorType
    public typealias PasteProbe = OpenSelectionPasteAvailabilityProbe
    public typealias PasteAvailabilityProbe = OpenSelectionPasteAvailabilityProbe

    private static let configLock = OSAllocatedUnfairLock(initialState: SelectionConfiguration.default)

    /// Global default configuration.
    public static var configuration: SelectionConfiguration {
        get {
            configLock.withLock { $0 }
        }
        set {
            configLock.withLock { $0 = newValue }
        }
    }

    /// Pluggable logger closure. Set this to pipe OpenSelection logs to your app's logging subsystem.
    public static var logger: (@Sendable (String) -> Void)? {
        get { OpenSelectionLogging.logger }
        set { OpenSelectionLogging.logger = newValue }
    }

    /// Retrieves the currently selected text from the frontmost application.
    @MainActor
    public static func selectedText(
        configuration: SelectionConfiguration? = nil
    ) async -> String? {
        let config = configuration ?? Self.configuration
        return (await current(configuration: config))?.text
    }

    /// Retrieves the full selection result from the frontmost application.
    @MainActor
    public static func current(
        configuration: SelectionConfiguration? = nil
    ) async -> SelectionResult? {
        let config = configuration ?? Self.configuration
        let frontApp = NSWorkspace.shared.frontmostApplication
        let coordinator = SelectionRetrievalCoordinator(configuration: config)
        let cursor = CursorClassifier.current
        return await coordinator.retrieve(for: frontApp, cursor: cursor)
    }

    /// Retrieves the selection for a specified application identity and policy context.
    public static func retrieve(
        for app: AppIdentity = AppIdentity(),
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        configuration: SelectionConfiguration? = nil,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true
    ) async -> SelectionResult? {
        let config = configuration ?? Self.configuration
        let coordinator = SelectionRetrievalCoordinator(configuration: config)
        return await coordinator.retrieve(
            for: app,
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback
        )
    }

    /// Convenience overload for NSRunningApplication.
    public static func retrieve(
        for app: NSRunningApplication?,
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        configuration: SelectionConfiguration? = nil,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true
    ) async -> SelectionResult? {
        await retrieve(
            for: AppIdentity(app),
            policy: policy,
            cursor: cursor,
            configuration: configuration,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback
        )
    }

    /// Retrieves full selection details including editable context identification.
    public static func retrieveDetails(
        for app: AppIdentity = AppIdentity(),
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        configuration: SelectionConfiguration? = nil,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true
    ) async -> (result: SelectionResult?, isEditable: Bool) {
        let config = configuration ?? Self.configuration
        let coordinator = SelectionRetrievalCoordinator(configuration: config)
        return await coordinator.retrieveDetails(
            for: app,
            policy: policy,
            cursor: cursor,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback
        )
    }

    /// Convenience overload for NSRunningApplication.
    public static func retrieveDetails(
        for app: NSRunningApplication?,
        policy: SelectionPolicy = .default,
        cursor: CursorClass = .unknown,
        configuration: SelectionConfiguration? = nil,
        isSelectAll: Bool = false,
        allowCopyFallback: Bool = true
    ) async -> (result: SelectionResult?, isEditable: Bool) {
        await retrieveDetails(
            for: AppIdentity(app),
            policy: policy,
            cursor: cursor,
            configuration: configuration,
            isSelectAll: isSelectAll,
            allowCopyFallback: allowCopyFallback
        )
    }

    // MARK: - Write API

    /// Replaces the current selection in the specified application (or frontmost application) with text.
    @MainActor
    public static func replace(
        with text: String,
        in app: NSRunningApplication? = nil,
        restorePasteboard: Bool = true,
        pasteboard: NSPasteboard = .general,
        configuration: SelectionConfiguration? = nil
    ) async throws {
        let replacer = SelectionReplacer(
            configuration: configuration ?? Self.configuration,
            pasteboard: pasteboard
        )
        try await replacer.replace(with: text, in: app, restorePasteboard: restorePasteboard)
    }

    /// Replaces the current selection (convenience alias for replace).
    @MainActor
    public static func replaceSelection(
        with text: String,
        in app: NSRunningApplication? = nil,
        restorePasteboard: Bool = true
    ) async throws {
        try await replace(with: text, in: app, restorePasteboard: restorePasteboard)
    }

    // MARK: - Push Monitoring API

    /// Creates and returns an OpenSelectionMonitor for push-based selection observation.
    @MainActor
    public static func monitor(
        configuration: SelectionConfiguration? = nil,
        excludedBundleIDs: Set<String> = [],
        onSelection: (@Sendable (SelectionResult) -> Void)? = nil
    ) -> OpenSelectionMonitor {
        OpenSelectionMonitor(
            configuration: configuration ?? Self.configuration,
            excludedBundleIDs: excludedBundleIDs,
            onSelection: onSelection
        )
    }

    // MARK: - Paste Availability Probe

    /// Determines whether the target application can paste.
    @MainActor
    public static func canPaste(
        in app: NSRunningApplication?,
        policy: SelectionPolicy = .default
    ) async -> Bool? {
        let probe = PasteAvailabilityProbe(configuration: configuration)
        return await probe.canPaste(in: app, policy: policy)
    }
}

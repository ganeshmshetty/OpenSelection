// OpenSelectionMonitor.swift
// OpenSelection
//
// Push-based selection monitor detecting mouse drags, multi-clicks, keyboard
// selection gestures, and optional pluggable triggers across macOS applications.
import AppKit
import ApplicationServices
import Foundation

/// An abstract source of selection-change intent signals (e.g. event taps, AX notifications, custom shortcuts).
@MainActor
public protocol SelectionTrigger: AnyObject {
    func start(onTrigger: @escaping @MainActor (SelectionTriggerSignal) -> Void)
    func stop()
}

/// A signal emitted by a `SelectionTrigger` indicating that a selection event occurred.
public struct SelectionTriggerSignal: Sendable {
    public let app: NSRunningApplication?
    public let isSelectAll: Bool
    public let cursor: CGPoint?

    public init(app: NSRunningApplication? = nil, isSelectAll: Bool = false, cursor: CGPoint? = nil) {
        self.app = app
        self.isSelectAll = isSelectAll
        self.cursor = cursor
    }
}

@MainActor
public final class OpenSelectionMonitor {
    public let configuration: SelectionConfiguration
    public var excludedBundleIDs: Set<String>
    public var onSelection: (@Sendable (SelectionResult) -> Void)?

    private var customTriggers: [any SelectionTrigger] = []

    private var streamContinuation: AsyncStream<SelectionResult>.Continuation?
    public private(set) lazy var selections: AsyncStream<SelectionResult> = {
        AsyncStream<SelectionResult> { continuation in
            self.streamContinuation = continuation
        }
    }()

    private var monitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var keyDownMonitor: Any?

    internal var debounceTask: Task<Void, Never>?
    internal var mouseDownLocation: CGPoint?
    /// Whether the press that started the current gesture landed on system chrome. Gate on this
    /// (the press), not on where the pointer is released: a drag that begins in a window and
    /// overshoots onto the menu bar or Dock is still a selection, while one that begins on chrome is not.
    internal var mouseDownWasSystemChrome: Bool = false

    // Injectable seams for tests and headless verification
    public var frontmostAppProvider: @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    public var currentMouseLocation: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    public var currentCursorProvider: @MainActor () -> CursorClass = { CursorClassifier.current }
    public var primaryButtonPressed: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    public var now: @MainActor () -> Date = { Date() }
    public var isSuppressed: @MainActor () -> Bool = { false }
    public var isSuppressedForApp: @MainActor (String?) -> Bool = { _ in false }
    /// Whether `point` sits on on-screen system chrome (the menu bar or Dock). Injectable so the
    /// gesture logic can be exercised headlessly against a fixed geometry.
    public var isSystemChrome: @MainActor (CGPoint) -> Bool = { OpenSelectionMonitor.isSystemChromeLocation($0) }

    public var coordinator: SelectionRetrievalCoordinator

    // MARK: - Constants & Key Codes

    public static let selectAllKeyCode: UInt16 = 0x00       // kVK_ANSI_A
    public static let selectLocationKeyCode: UInt16 = 0x25  // kVK_ANSI_L
    public static let extendKeyCodes: Set<UInt16> = [
        0x7B, 0x7C, 0x7D, 0x7E,   // left / right / down / up
        0x73, 0x77,               // home / end
        0x74, 0x79                // page up / page down
    ]

    /// Squared drag threshold (>3pt movement)
    public static let dragThresholdSquared: CGFloat = 9.0
    public static let holdDragDisarmSquared: CGFloat = 25.0
    public static let holdFireDriftSquared: CGFloat = 4.0

    public init(
        configuration: SelectionConfiguration = .default,
        excludedBundleIDs: Set<String> = [],
        onSelection: (@Sendable (SelectionResult) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.excludedBundleIDs = excludedBundleIDs
        self.onSelection = onSelection
        self.coordinator = SelectionRetrievalCoordinator(configuration: configuration)
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
            streamContinuation?.finish()
        }
    }

    /// Registers a custom `SelectionTrigger` to provide selection signals to this monitor.
    public func addTrigger(_ trigger: any SelectionTrigger) {
        customTriggers.append(trigger)
    }

    public func start() {
        guard monitor == nil else { return }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                self?.handleMouseDown(at: point)
            }
        }

        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                self?.handleMouseDragged(at: point)
            }
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let cursor = NSEvent.mouseLocation
            let clickCount = event.clickCount
            MainActor.assumeIsolated {
                self?.handleMouseUp(app: app, cursor: cursor, clickCount: clickCount)
            }
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyDown(keyCode: event.keyCode, flags: event.modifierFlags)
            }
        }

        for trigger in customTriggers {
            trigger.start { [weak self] signal in
                self?.handleTriggerSignal(signal)
            }
        }
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        if let mouseDragMonitor {
            NSEvent.removeMonitor(mouseDragMonitor)
            self.mouseDragMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        for trigger in customTriggers {
            trigger.stop()
        }
    }

    /// Whether `point` is on macOS system chrome (the menu bar or Dock) that is actually shown.
    ///
    /// This must not simply test "outside `visibleFrame`". That rectangle permanently reserves the
    /// menu-bar strip even while the menu bar is hidden — auto-hidden, or a full-screen window that
    /// only reveals it at the very top edge — so treating the whole strip as chrome discarded every
    /// selection whose press or release landed near the top of the screen. A hidden menu bar is not
    /// chrome. The Dock's reserved strip has the same failure mode: a window can extend into it
    /// (a chat box at the very bottom of the screen), and the pointer there is over the window, not
    /// the Dock, whenever the Dock is not actually shown. Both strips are chrome only while the
    /// corresponding chrome is really on screen.
    public static func isSystemChromeLocation(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        guard !screen.visibleFrame.contains(point) else { return false }
        if point.y >= screen.visibleFrame.maxY {
            return NSMenu.menuBarVisible()
        }
        return isDockOnScreen()
    }

    /// Whether the Dock's bar is actually on screen right now. `visibleFrame` keeps reserving the
    /// Dock's strip even when the Dock is hidden or the pointer is over a window that extends into
    /// it; the Dock's own on-screen window is the ground truth. Its background layers are always
    /// present at negative levels, so only a non-negative level counts.
    static func isDockOnScreen() -> Bool {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return true   // unknown: fail safe (treat as chrome) so a Dock interaction is never read
        }
        return raw.contains { info in
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
        }
    }

    // MARK: - Event Handlers

    public func handleMouseDown(at point: CGPoint) {
        if isSystemChrome(point) {
            mouseDownLocation = nil
            mouseDownWasSystemChrome = true
            return
        }
        mouseDownWasSystemChrome = false
        mouseDownLocation = point
    }

    public func handleMouseDragged(at point: CGPoint) {
        // Track dragging state if needed
    }

    public func handleMouseUp(app: NSRunningApplication, cursor: CGPoint, clickCount: Int) {
        let wasSystemChrome = mouseDownWasSystemChrome
        mouseDownWasSystemChrome = false

        let downPoint = mouseDownLocation
        mouseDownLocation = nil

        debounceTask?.cancel()

        // Gate on where the press landed, not where the pointer came up: a drag that begins inside
        // a window and overshoots onto the menu bar or Dock (the usual way of selecting text that
        // sits against a screen edge) is still a legitimate selection. An interaction that *begins*
        // on chrome is not.
        guard !wasSystemChrome else { return }

        guard !isSuppressed() else { return }
        guard !isSuppressedForApp(app.bundleIdentifier) else { return }
        if let bundleID = app.bundleIdentifier, excludedBundleIDs.contains(bundleID) {
            return
        }

        // Measure drag distance for click filtering (>5pt movement or multi-click >= 2)
        var isDragOrMultiClick = clickCount >= 2
        if !isDragOrMultiClick, let downPoint {
            let dx = cursor.x - downPoint.x
            let dy = cursor.y - downPoint.y
            isDragOrMultiClick = (dx * dx + dy * dy) > Self.dragThresholdSquared
        }
        guard isDragOrMultiClick else { return }

        debounceTask = Task { @MainActor in
            guard !self.isSuppressed(), !self.isSuppressedForApp(app.bundleIdentifier) else { return }
            if let bundleID = app.bundleIdentifier, self.excludedBundleIDs.contains(bundleID) { return }

            let appIdentity = AppIdentity(app)
            let cursorClass = self.currentCursorProvider()
            let result = await self.coordinator.retrieve(
                for: appIdentity,
                policy: .default,
                cursor: cursorClass
            )
            guard !Task.isCancelled else { return }
            if let result, TextSanitizer.isSubstantial(result.text) {
                self.dispatch(result: result)
            }
        }
    }

    public func handleKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if Self.isSelectionTrigger(keyCode: keyCode, flags: flags) {
            let isSelectAll = Self.isSelectAllKey(keyCode: keyCode, flags: flags)
            handleSelectionTrigger(isSelectAll: isSelectAll)
        } else if Self.isSelectionClearingKey(keyCode: keyCode, flags: flags) {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    public func handleSelectionTrigger(isSelectAll: Bool) {
        debounceTask?.cancel()
        guard !isSuppressed() else { return }

        debounceTask = Task { @MainActor in
            // Small debounce interval for keyboard selections
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard !Task.isCancelled else { return }

            guard let app = self.frontmostAppProvider() else { return }
            guard !self.isSuppressed(), !self.isSuppressedForApp(app.bundleIdentifier) else { return }
            if let bundleID = app.bundleIdentifier, self.excludedBundleIDs.contains(bundleID) { return }

            let appIdentity = AppIdentity(app)
            let cursorClass = self.currentCursorProvider()
            let result = await self.coordinator.retrieve(
                for: appIdentity,
                policy: .default,
                cursor: cursorClass,
                isSelectAll: isSelectAll
            )
            guard !Task.isCancelled else { return }
            if let result, TextSanitizer.isSubstantial(result.text) {
                self.dispatch(result: result)
            }
        }
    }

    public func handleTriggerSignal(_ signal: SelectionTriggerSignal) {
        debounceTask?.cancel()
        guard !isSuppressed() else { return }

        debounceTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let targetApp = signal.app ?? self.frontmostAppProvider()
            guard let targetApp else { return }
            guard !self.isSuppressed(), !self.isSuppressedForApp(targetApp.bundleIdentifier) else { return }
            if let bundleID = targetApp.bundleIdentifier, self.excludedBundleIDs.contains(bundleID) { return }

            let appIdentity = AppIdentity(targetApp)
            let cursorClass = self.currentCursorProvider()
            let result = await self.coordinator.retrieve(
                for: appIdentity,
                policy: .default,
                cursor: cursorClass,
                isSelectAll: signal.isSelectAll
            )
            guard !Task.isCancelled else { return }
            if let result, TextSanitizer.isSubstantial(result.text) {
                self.dispatch(result: result)
            }
        }
    }

    private func dispatch(result: SelectionResult) {
        streamContinuation?.yield(result)
        onSelection?(result)
    }

    // MARK: - Static Gesture Classification & Anchoring

    public static func isSelectionTrigger(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let gestureFlags = normalizedGestureFlags(flags)
        if gestureFlags == .command {
            return keyCode == selectAllKeyCode || keyCode == selectLocationKeyCode
        }
        if gestureFlags.contains(.shift) && gestureFlags.isSubset(of: [.shift, .option, .command]) {
            return extendKeyCodes.contains(keyCode)
        }
        return false
    }

    public static func isSelectAllKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let gestureFlags = normalizedGestureFlags(flags)
        guard gestureFlags == .command else { return false }
        return keyCode == selectAllKeyCode || keyCode == selectLocationKeyCode
    }

    public static func isSelectionClearingKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if isSelectionTrigger(keyCode: keyCode, flags: flags) {
            return false
        }
        let gestureFlags = normalizedGestureFlags(flags)
        if gestureFlags.contains(.command) || gestureFlags.contains(.control) {
            return false
        }
        if extendKeyCodes.contains(keyCode) {
            return true
        }
        let editingKeyCodes: Set<UInt16> = [
            0x35, // Escape
            0x33, // Delete / Backspace
            0x75, // Forward Delete
            0x24, // Return
            0x4C, // Enter
            0x31, // Space
            0x30  // Tab
        ]
        if editingKeyCodes.contains(keyCode) {
            return true
        }
        return gestureFlags.isSubset(of: [.shift, .option])
    }

    public static func holdStationary(downPoint: CGPoint?, pointer: CGPoint, buttonPressed: Bool) -> Bool {
        guard buttonPressed else { return false }
        guard let downPoint else { return true }
        let dx = pointer.x - downPoint.x
        let dy = pointer.y - downPoint.y
        return dx * dx + dy * dy <= holdFireDriftSquared
    }

    public static func keyboardAnchor(bounds: CGRect?, isSelectAll: Bool, mouseLocation: CGPoint) -> CGPoint {
        if !isSelectAll, let bounds {
            let anchor = cocoaPoint(fromAXPoint: CGPoint(x: bounds.minX, y: bounds.minY))
            if NSScreen.screens.contains(where: { $0.frame.contains(anchor) }) {
                return anchor
            }
        }
        return mouseLocation
    }

    private static func cocoaPoint(fromAXPoint point: CGPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }

    private static func normalizedGestureFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad, .help])
    }
}

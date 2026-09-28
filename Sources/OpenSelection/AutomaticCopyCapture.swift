import AppKit
import ApplicationServices

/// Conservative copy authorization for passive monitoring. Explicit selection requests can
/// continue to use `PasteboardCopyEngine` directly when an app exposes no usable menu tree.
@MainActor
public enum AutomaticCopyCapture {
    private static let probeQueue = DispatchQueue(label: "com.openselection.copy-availability", qos: .userInitiated)
    private static var isProbing = false

    public static func capture(
        configuration: SelectionConfiguration = .default,
        trigger: SelectionRetrievalCoordinator.CopyTrigger
    ) async -> SelectionResult? {
        await capture(
            configuration: configuration,
            trigger: trigger,
            pasteboard: .general,
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            copyAvailable: { await hasEnabledCopyCommand(for: $0, timeout: min(0.15, configuration.axReadTimeout)) },
            overlayPresent: { CopyTriggerGate.isForeignOverlayPresent(at: NSEvent.mouseLocation) }
        )
    }

    static func capture(
        configuration: SelectionConfiguration = .default,
        trigger: SelectionRetrievalCoordinator.CopyTrigger,
        pasteboard: NSPasteboard,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        copyAvailable: @MainActor (pid_t) async -> Bool,
        overlayPresent: @escaping @MainActor () -> Bool
    ) async -> SelectionResult? {
        guard !Task.isCancelled, let pid = frontmostPID() else { return nil }
        guard await copyAvailable(pid) else {
            OpenSelectionLogging.log("automatic copy: skipped; no enabled Command-C menu item for pid=\(pid)")
            return nil
        }
        guard !Task.isCancelled, frontmostPID() == pid else { return nil }

        let engine = PasteboardCopyEngine(configuration: configuration, isCopyAuthorized: {
            !Task.isCancelled && frontmostPID() == pid && !overlayPresent()
        })
        return await engine.capture(pasteboard: pasteboard) {
            guard !Task.isCancelled, frontmostPID() == pid else { return }
            OpenSelectionLogging.log("automatic copy: posting copy trigger for pid=\(pid)")
            trigger()
        }
    }

    /// Keep AX messaging off the main actor, with a bounded walk and no queue of stale probes.
    private static func hasEnabledCopyCommand(for pid: pid_t, timeout: TimeInterval) async -> Bool {
        guard !isProbing, timeout > 0 else { return false }
        isProbing = true
        defer { isProbing = false }
        return await withCheckedContinuation { continuation in
            probeQueue.async {
                let deadline = Date().addingTimeInterval(timeout)
                let app = AXUIElementCreateApplication(pid)
                let item = AXMenuNavigator.findMenuItem(
                    .copy, in: app, requireEnabled: true, matchingShortcutOnly: true,
                    timeout: timeout, deadline: deadline
                )
                continuation.resume(returning: item != nil && Date() < deadline)
            }
        }
    }
}

import AppKit
import ApplicationServices
import Foundation

/// An explicit user Copy. The source app owns the resulting items and data providers;
/// unlike background selection capture, this operation never reads or restores them.
@MainActor
public struct NativeCopyOperation {
    public enum Failure: Error, LocalizedError, Sendable {
        case targetChanged, commandUnavailable, timedOut, copyBlocked

        public var errorDescription: String? {
            switch self {
            case .targetChanged: return "The source selection is no longer available."
            case .commandUnavailable: return "The application's Copy command is unavailable."
            case .timedOut: return "The application did not confirm Copy in time."
            case .copyBlocked: return "Finish the screen capture before copying."
            }
        }
    }

    public init() {}

    private struct MenuItem: @unchecked Sendable { let element: AXUIElement }

    /// Menu-based app policies retain their Copy command. Both discovery and AXPress
    /// run on the existing bounded menu workers, never on the main actor.
    public static func pressMenuCopy(
        processIdentifier: pid_t,
        timeout: TimeInterval,
        isAuthorized: @MainActor () -> Bool
    ) async throws {
        guard timeout > 0 else { throw Failure.commandUnavailable }
        let deadline = Date().addingTimeInterval(timeout)
        let monotonicDeadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let item: MenuItem? = await CopyMenuProbe.shared.run(hardLimit: timeout, fallback: nil) {
            let app = AXUIElementCreateApplication(processIdentifier)
            return AXMenuNavigator.findMenuItem(.copy, in: app, requireEnabled: true,
                                               timeout: timeout, deadline: deadline).map { MenuItem(element: $0) }
        }
        try Task.checkCancellation()
        guard isAuthorized() else { throw Failure.targetChanged }
        guard let item, ContinuousClock.now < monotonicDeadline else { throw Failure.commandUnavailable }
        let budget = ContinuousClock.now.duration(to: monotonicDeadline).components
        let remaining = max(0.001, Double(budget.seconds) + Double(budget.attoseconds) / 1e18)
        let pressed = await CopyMenuProbe.shared.run(hardLimit: remaining, fallback: false) {
            guard ContinuousClock.now < monotonicDeadline else { return false }
            AXUIElementSetMessagingTimeout(item.element, Float(remaining))
            return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
        }
        guard pressed else { throw Failure.commandUnavailable }
    }

    public func perform(
        pasteboard: NSPasteboard = .general,
        timeout: TimeInterval,
        isAuthorized: @MainActor () -> Bool,
        trigger: @MainActor () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard isAuthorized() else { throw Failure.targetChanged }
        let session = try await PasteboardCoordinator.shared.acquireSession(priority: .userAction, pasteboard: pasteboard)
        defer { session.commitPermanent() }
        try Task.checkCancellation()
        guard isAuthorized() else { throw Failure.targetChanged }
        let initialCount = pasteboard.changeCount
        PasteboardCoordinator.shared.markCopyPosted(for: session)
        let triggerFailure: (any Error)?
        do {
            try await trigger()
            triggerFailure = nil
        } catch {
            // AXPress may have reached the target before its IPC reply timed out.
            // Keep ownership while that possible command response drains, too.
            triggerFailure = error
        }

        // Once posted, keep ownership until the bounded response window closes even if
        // the caller cancels. Never restore over the app's copy or a user's newer write.
        let changed = await Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            while pasteboard.changeCount == initialCount, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(2))
            }
            return pasteboard.changeCount != initialCount
        }.value
        try Task.checkCancellation()
        if let triggerFailure { throw triggerFailure }
        guard isAuthorized() else { throw Failure.targetChanged }
        guard changed else { throw Failure.timedOut }
    }
}

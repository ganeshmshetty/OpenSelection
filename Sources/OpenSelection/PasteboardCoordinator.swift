// PasteboardCoordinator.swift
// OpenSelection
//
// Single owner for all temporary clipboard operations across background selection capture
// and action delivery. Coordinates ownership, enforces operation priority (user action >
// background capture), preserves baseline snapshots across overlapping operations, tracks
// external mutations, serializes delivery windows, and invalidates stale restorations.
import AppKit
import Foundation
import os

public enum PasteboardOperationPriority: Int, Comparable, Sendable {
    case backgroundCapture = 0
    case userAction = 1

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
public final class PasteboardSession: Sendable {
    public let id = UUID()
    public fileprivate(set) var didRestore = false
    public let priority: PasteboardOperationPriority
    public let pasteboard: NSPasteboard

    private let cancelledLock = OSAllocatedUnfairLock(initialState: false)
    public var isCancelled: Bool {
        cancelledLock.withLock { $0 }
    }

    private let copyPostedLock = OSAllocatedUnfairLock(initialState: false)
    public var isCopyPosted: Bool {
        copyPostedLock.withLock { $0 }
    }

    private let onRestore: @Sendable (PasteboardSession, Int?) -> Void
    private let onCommitPermanent: @Sendable (PasteboardSession) -> Void

    fileprivate init(
        priority: PasteboardOperationPriority,
        pasteboard: NSPasteboard,
        onRestore: @escaping @Sendable (PasteboardSession, Int?) -> Void,
        onCommitPermanent: @escaping @Sendable (PasteboardSession) -> Void
    ) {
        self.priority = priority
        self.pasteboard = pasteboard
        self.onRestore = onRestore
        self.onCommitPermanent = onCommitPermanent
    }

    fileprivate func markCancelled() {
        cancelledLock.withLock { $0 = true }
    }

    fileprivate func markCopyPosted() {
        copyPostedLock.withLock { $0 = true }
    }

    /// Restores the baseline snapshot to the pasteboard if this session is still the active owner.
    public func restoreImmediately(expectedChangeCount: Int? = nil) {
        guard !isCancelled else { return }
        onRestore(self, expectedChangeCount)
    }

    /// Commits the current pasteboard contents permanently (no restore).
    public func commitPermanent() {
        guard !isCancelled else { return }
        onCommitPermanent(self)
    }
}

@MainActor
public final class PasteboardCoordinator: Sendable {
    public static let shared = PasteboardCoordinator()

    private struct ActiveState {
        let session: PasteboardSession
        let baselineSnapshot: PasteboardSnapshot
        let initialChangeCount: Int
        var ownedChangeCount: Int?
        var pendingRestoreTask: Task<Void, Never>?
        // Includes preparation/activation as well as the external delivery window.
        var isExclusive = false
    }

    private var states: [NSPasteboard.Name: ActiveState] = [:]
    private var waiters: [NSPasteboard.Name: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var waitingUserActions: [NSPasteboard.Name: Int] = [:]

    public init() {}

    /// Acquires ownership before any suspension or write. Posted operations keep ownership
    /// until their bounded external delivery window finishes, even if their caller cancels.
    public func acquireSession(
        priority: PasteboardOperationPriority,
        pasteboard: NSPasteboard = .general
    ) async throws -> PasteboardSession {
        let name = pasteboard.name
        if priority == .userAction { waitingUserActions[name, default: 0] += 1 }
        defer {
            if priority == .userAction { waitingUserActions[name, default: 0] -= 1 }
        }
        while true {
            try Task.checkCancellation()
            if let session = beginSession(priority: priority, pasteboard: pasteboard) {
                states[name]?.isExclusive = true
                return session
            }
            await waitForRelease(on: name)
        }
    }

    public func yieldForInFlightOperations(on pasteboard: NSPasteboard = .general) async {
        while states[pasteboard.name]?.isExclusive == true, !Task.isCancelled {
            await waitForRelease(on: pasteboard.name)
        }
    }

    private func waitForRelease(on name: NSPasteboard.Name) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                waiters[name, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters[name]?.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func wakeWaiters(on name: NSPasteboard.Name) {
        let pending = waiters.removeValue(forKey: name) ?? [:]
        for continuation in pending.values { continuation.resume() }
    }

    /// Synchronous acquisition is useful for work that has not yet posted side effects.
    /// It never preempts a committed capture, paste, or an async acquisition's preparation.
    @discardableResult
    public func beginSession(
        priority: PasteboardOperationPriority,
        pasteboard: NSPasteboard = .general
    ) -> PasteboardSession? {
        let name = pasteboard.name
        if priority == .backgroundCapture, waitingUserActions[name, default: 0] > 0 { return nil }
        let baseline: PasteboardSnapshot
        if let existing = states[name] {
            guard !existing.isExclusive, priority >= existing.session.priority else { return nil }
            let expected = existing.ownedChangeCount ?? existing.initialChangeCount
            baseline = pasteboard.changeCount == expected
                ? existing.baselineSnapshot : PasteboardSnapshot.capture(pasteboard)
            existing.session.markCancelled()
            existing.pendingRestoreTask?.cancel()
        } else {
            baseline = PasteboardSnapshot.capture(pasteboard)
        }
        let session = PasteboardSession(
            priority: priority,
            pasteboard: pasteboard,
            onRestore: { [weak self] session, expected in
                MainActor.assumeIsolated { self?.handleRestore(for: session, expectedChangeCount: expected) }
            },
            onCommitPermanent: { [weak self] session in
                MainActor.assumeIsolated { self?.finish(session) }
            }
        )
        states[name] = ActiveState(session: session, baselineSnapshot: baseline,
                                   initialChangeCount: pasteboard.changeCount)
        return session
    }

    public func recordOwnedWrite(changeCount: Int, for session: PasteboardSession) {
        guard isSessionActive(for: session) else { return }
        states[session.pasteboard.name]?.ownedChangeCount = changeCount
    }

    public func markDirty(for session: PasteboardSession, changeCount: Int? = nil) {
        recordOwnedWrite(changeCount: changeCount ?? session.pasteboard.changeCount, for: session)
    }

    public func markCopyPosted(for session: PasteboardSession, task: Task<Void, Never>? = nil) {
        guard isSessionActive(for: session) else { return }
        session.markCopyPosted()
        states[session.pasteboard.name]?.isExclusive = true
    }

    public func markCaptureFinished(for session: PasteboardSession) {
        // Restoration/commit releases ownership; do not unlock before that happens.
    }

    public func markDelivering(for session: PasteboardSession, task: Task<Void, Never>? = nil) {
        guard isSessionActive(for: session) else { return }
        states[session.pasteboard.name]?.isExclusive = true
    }

    public func markDeliveryFinished(for session: PasteboardSession) {
        // The caller restores or commits synchronously after its delivery window.
    }

    public func scheduleRestore(for session: PasteboardSession, delay: TimeInterval,
                                expectedChangeCount: Int? = nil) {
        guard isSessionActive(for: session) else { return }
        states[session.pasteboard.name]?.pendingRestoreTask?.cancel()
        if delay <= 0 { handleRestore(for: session, expectedChangeCount: expectedChangeCount); return }
        states[session.pasteboard.name]?.pendingRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleRestore(for: session, expectedChangeCount: expectedChangeCount)
        }
    }

    /// Call only for unposted operations. Permanent clipboard writes must acquire a user
    /// session first so they cannot overtake a copy/paste event already in flight.
    public func cancelAndClear(pasteboard: NSPasteboard = .general) {
        guard let state = states[pasteboard.name], !state.isExclusive else { return }
        state.session.markCancelled()
        state.pendingRestoreTask?.cancel()
        states[pasteboard.name] = nil
        wakeWaiters(on: pasteboard.name)
    }

    public func isSessionActive(for session: PasteboardSession) -> Bool {
        states[session.pasteboard.name]?.session.id == session.id && !session.isCancelled
    }

    private func handleRestore(for session: PasteboardSession, expectedChangeCount: Int?) {
        guard let state = states[session.pasteboard.name], isSessionActive(for: session) else { return }
        let expected = expectedChangeCount ?? state.ownedChangeCount ?? state.initialChangeCount
        if state.ownedChangeCount != nil, session.pasteboard.changeCount == expected {
            state.baselineSnapshot.restore(to: session.pasteboard, transientMarkers: true)
            session.didRestore = true
        }
        finish(session)
    }

    private func finish(_ session: PasteboardSession) {
        guard isSessionActive(for: session) else { return }
        states[session.pasteboard.name]?.pendingRestoreTask?.cancel()
        states[session.pasteboard.name] = nil
        wakeWaiters(on: session.pasteboard.name)
    }
}

// OnceResume.swift
// OpenSelection
//
// Thread-safe once-resume guard and cancellable task box used by watchdog patterns.
import Foundation
import os

/// Guarantees a `CheckedContinuation` is resumed exactly once when two or more racing producers
/// (a worker and a deadline watchdog) may both try to settle it.
final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    @discardableResult
    func resume(_ continuation: CheckedContinuation<T, Never>, with value: T) -> Bool {
        let shouldResume = lock.withLock { resumed -> Bool in
            guard !resumed else { return false }
            resumed = true
            return true
        }
        if shouldResume {
            continuation.resume(returning: value)
        }
        return shouldResume
    }
}

/// A thread-safe reference container for a `Task` to allow cross-isolation task cancellation.
final class TaskBox: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (task: Optional<Task<Void, Never>>.none, cancelled: false))

    func set(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { s -> Bool in
            s.task = task
            return s.cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let taskToCancel = state.withLock { s -> Task<Void, Never>? in
            guard !s.cancelled else { return nil }
            s.cancelled = true
            return s.task
        }
        taskToCancel?.cancel()
    }
}

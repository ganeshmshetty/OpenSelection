// PasteAvailabilityProbe.swift
// OpenSelection
//
// Determines whether an application can paste by inspecting the Edit ▸ Paste
// menu item through Accessibility or consulting policy overrides.
import AppKit
import ApplicationServices
import Foundation

public struct PasteAvailabilityProbe: Sendable {
    public typealias Lookup = @Sendable (_ pid: pid_t, _ deadline: Date?) -> Bool?

    private let lookup: Lookup
    public let timeout: TimeInterval
    public let maxConcurrent: Int

    public init(
        configuration: SelectionConfiguration = .default
    ) {
        let timeoutVal = configuration.axReadTimeout
        self.lookup = { pid, deadline in
            PasteAvailabilityProbe.editPasteEnabled(pid: pid, deadline: deadline, timeout: timeoutVal)
        }
        self.timeout = configuration.pasteProbeTimeout
        self.maxConcurrent = configuration.pasteProbeMaxConcurrent
    }

    public init(
        lookup: @escaping @Sendable (pid_t) -> Bool?,
        timeout: TimeInterval = 0.2,
        maxConcurrent: Int = 4
    ) {
        self.lookup = { pid, _ in lookup(pid) }
        self.timeout = timeout
        self.maxConcurrent = maxConcurrent
    }

    public init(
        lookupWithDeadline lookup: @escaping Lookup,
        timeout: TimeInterval = 0.2,
        maxConcurrent: Int = 4
    ) {
        self.lookup = lookup
        self.timeout = timeout
        self.maxConcurrent = maxConcurrent
    }

    public static let `default` = PasteAvailabilityProbe()

    /// Determines whether the target application can paste, consulting policy overrides first.
    @MainActor
    public func canPaste(in app: NSRunningApplication?, policy: SelectionPolicy = .default) async -> Bool? {
        if policy.denyPaste {
            return false
        }
        guard let app, !app.isTerminated else { return nil }
        return await probePaste(pid: app.processIdentifier)
    }

    private static let axProbeQueue = DispatchQueue(label: "com.openselection.ax-probe", qos: .userInitiated, attributes: .concurrent)

    private actor ProbeConcurrencyGate {
        private var inFlight = 0

        func tryAcquire(limit: Int) -> Bool {
            guard inFlight < limit else { return false }
            inFlight += 1
            return true
        }

        func release() {
            inFlight -= 1
        }
    }
    private static let probeGate = ProbeConcurrencyGate()

    public nonisolated func probePaste(pid: pid_t) async -> Bool? {
        guard await Self.probeGate.tryAcquire(limit: maxConcurrent) else {
            OpenSelectionLogging.log("PasteAvailabilityProbe: concurrency cap reached for pid \(pid); reporting unknown")
            return nil
        }
        let lookup = self.lookup
        let timeoutSeconds = self.timeout
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let resume = OnceResume<Bool?>()
            let watchdog = TaskBox()

            watchdog.set(Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if resume.resume(continuation, with: nil) {
                    Task.detached { await Self.probeGate.release() }
                    OpenSelectionLogging.log("PasteAvailabilityProbe: lookup for pid \(pid) exceeded \(timeoutSeconds)s deadline; reporting unknown")
                }
            })

            Self.axProbeQueue.async {
                let enabled = lookup(pid, deadline)
                if resume.resume(continuation, with: enabled) {
                    watchdog.cancel()
                    Task.detached { await Self.probeGate.release() }
                }
            }
        }
    }

    private nonisolated static func editPasteEnabled(pid: pid_t, deadline: Date? = nil, timeout: TimeInterval = 0.5) -> Bool? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let pasteItem = AXMenuNavigator.findMenuItem(.paste, in: appElement, requireEnabled: false, deadline: deadline) else {
            return nil
        }
        return enabledState(of: pasteItem, timeout: timeout)
    }

    public nonisolated static func isPaste(title: String?, cmdChar: String?, cmdCharModifiers: UInt?) -> Bool {
        AXMenuNavigator.matches(.paste, title: title, identifier: nil, cmdChar: cmdChar, cmdModifiers: cmdCharModifiers)
    }

    private nonisolated static func enabledState(of element: AXUIElement, timeout: TimeInterval) -> Bool? {
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        var enabledRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
              let value = enabledRef as? Bool else { return nil }
        return value
    }
}

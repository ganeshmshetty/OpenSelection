import AppKit
import ApplicationServices

public enum CopyMenuState: Sendable, Equatable {
    case enabled, disabled
    case unknown(Reason)
    public enum Reason: String, Sendable { case timeout, noMenuBar, noCopyItem, unreadable }
}

private struct AXBox: @unchecked Sendable { let element: AXUIElement }

private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

/// Per-PID probe: coalesces concurrent callers, caches the Copy element, and never conflates
/// "couldn't tell" with "disabled".
@MainActor
final class CopyMenuProbe {
    static let shared = CopyMenuProbe()
    private var cached: [pid_t: AXBox] = [:]
    private var inFlight: [pid_t: Task<CopyMenuState, Never>] = [:]
    private let queue = DispatchQueue(label: "com.openselection.copy-menu-probe",
                                      qos: .userInitiated, attributes: .concurrent)

    func forget(_ pid: pid_t) { cached[pid] = nil }   // call on app termination

    /// Polls briefly so a flag that lags the selection (renderer IPC) can settle.
    func settledState(for pid: pid_t, timeout: TimeInterval, settle: TimeInterval = 0.25) async -> CopyMenuState {
        let end = Date().addingTimeInterval(settle)
        var s = await state(for: pid, timeout: timeout)
        while s == .disabled, Date() < end, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 40_000_000)
            s = await state(for: pid, timeout: timeout)
        }
        return s
    }

    func state(for pid: pid_t, timeout: TimeInterval) async -> CopyMenuState {
        if let running = inFlight[pid] { return await running.value }
        let task = Task { [self] in
            defer { inFlight[pid] = nil }
            return await resolve(pid, timeout)
        }
        inFlight[pid] = task
        return await task.value
    }

    private func resolve(_ pid: pid_t, _ timeout: TimeInterval) async -> CopyMenuState {
        if let box = cached[pid] {
            let read = await run(hardLimit: timeout * 2, fallback: EnabledRead.failed) {
                AXMenuNavigator.readEnabled(of: box.element, timeout: timeout)
            }
            switch read {
            case .value(true): return .enabled
            case .value(false): return .disabled
            case .failed: return .unknown(.timeout)
            case .invalidElement: cached[pid] = nil   // menu rebuilt; rediscover
            }
        }
        let budget = max(timeout * 4, 0.5)          // cold walk happens once per PID
        let deadline = Date().addingTimeInterval(budget)
        let outcome = await run(hardLimit: budget + 0.1, fallback: MenuProbeOutcome.timedOut) {
            AXMenuNavigator.probeMenuItem(.copy, in: AXUIElementCreateApplication(pid),
                                          matchingShortcutOnly: true, timeout: timeout, deadline: deadline)
        }
        switch outcome {
        case .found(let el, let enabled):
            cached[pid] = AXBox(element: el)
            switch enabled {
            case true?: return .enabled
            case false?: return .disabled
            case nil: return .unknown(.unreadable)
            }
        case .notFound: return .unknown(.noCopyItem)
        case .noMenuBar: return .unknown(.noMenuBar)
        case .timedOut: return .unknown(.timeout)
        }
    }

    private func run<T: Sendable>(hardLimit: TimeInterval, fallback: T,
                                  _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            let gate = OneShot(c)
            queue.async { gate.resume(work()) }
            queue.asyncAfter(deadline: .now() + hardLimit) { gate.resume(fallback) }
        }
    }
}

@MainActor
public enum AutomaticCopyCapture {
    public static func capture(
        configuration: SelectionConfiguration = .default,
        request: CopyRequest
    ) async -> SelectionResult? {
        await capture(
            configuration: configuration,
            request: request,
            pasteboard: .general,
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            menuState: { await CopyMenuProbe.shared.settledState(for: $0, timeout: min(0.15, configuration.axReadTimeout)) },
            overlayPresent: { CopyTriggerGate.isForeignOverlayPresent(at: NSEvent.mouseLocation) }
        )
    }

    /// Convenience overload if called with just a trigger (e.g. legacy/explicit callers)
    public static func capture(
        configuration: SelectionConfiguration = .default,
        trigger: @escaping SelectionRetrievalCoordinator.CopyTrigger
    ) async -> SelectionResult? {
        await capture(
            configuration: configuration,
            request: CopyRequest(trigger: trigger, evidence: CopyEvidence("legacy-trigger", .strong))
        )
    }

    static func capture(
        configuration: SelectionConfiguration = .default,
        request: CopyRequest,
        pasteboard: NSPasteboard,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        menuState: @MainActor (pid_t) async -> CopyMenuState,
        overlayPresent: @escaping @MainActor () -> Bool
    ) async -> SelectionResult? {
        guard !Task.isCancelled, let pid = frontmostPID() else { return nil }

        if request.evidence.strength == .weak {
            let state = await menuState(pid)
            DiagnosticsHub.shared.log(.debug, .pasteboard, "automatic copy evaluating menu", fields: [
                "pid": .int(Int64(pid)),
                "menuState": .token("\(state)"),
                "evidence": .token(request.evidence.reason)
            ])
            if state == .disabled {   // only a completed, settled read may veto
                DiagnosticsHub.shared.log(.debug, .pasteboard, "automatic copy skipped, copy disabled and weak evidence", fields: [
                    "pid": .int(Int64(pid))
                ])
                return nil
            }
        } else {
            DiagnosticsHub.shared.log(.debug, .pasteboard, "automatic copy proceeding with strong evidence", fields: [
                "pid": .int(Int64(pid)),
                "evidence": .token(request.evidence.reason)
            ])
        }
        guard !Task.isCancelled, frontmostPID() == pid else { return nil }

        let engine = PasteboardCopyEngine(configuration: configuration, isCopyAuthorized: {
            !Task.isCancelled && frontmostPID() == pid && !overlayPresent()
        })
        return await engine.capture(pasteboard: pasteboard) {
            guard !Task.isCancelled, frontmostPID() == pid else { return }
            request.trigger()
        }
    }
}

import AppKit
import ApplicationServices
import os

public enum CopyMenuState: Sendable, Equatable {
    case enabled, disabled
    case unknown(Reason)
    public enum Reason: String, Sendable { case timeout, noMenuBar, noCopyItem, unreadable }
}

private struct AXBox: @unchecked Sendable { let element: AXUIElement }

/// Per-PID probe: coalesces concurrent callers, caches the Copy element, and never conflates
/// "couldn't tell" with "disabled".
@MainActor
final class CopyMenuProbe {
    static let shared = CopyMenuProbe()
    private var cached: [pid_t: AXBox] = [:]
    private var inFlight: [pid_t: Task<CopyMenuState, Never>] = [:]
    private let queue = DispatchQueue(label: "com.openselection.copy-menu-probe",
                                      qos: .userInitiated,
                                      attributes: .concurrent)
    nonisolated(unsafe) private var terminationObserver: (any NSObjectProtocol)?

    init() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                if let pid {
                    self?.forget(pid)
                }
            }
        }
    }

    deinit {
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

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
        let budget = timeout
        let deadline = Date().addingTimeInterval(budget)
        let outcome = await run(hardLimit: budget + 0.05, fallback: MenuProbeOutcome.timedOut) {
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

    private actor ConcurrencyGate {
        private var inFlight = 0
        func tryAcquire(limit: Int) -> Bool {
            guard inFlight < limit else { return false }
            inFlight += 1
            return true
        }
        func release() { inFlight -= 1 }
    }
    private let gate = ConcurrencyGate()
    var maxConcurrent: Int = 4

    func run<T: Sendable>(hardLimit: TimeInterval, fallback: T,
                          _ work: @escaping @Sendable () -> T) async -> T {
        guard await gate.tryAcquire(limit: maxConcurrent) else {
            return fallback
        }
        return await withCheckedContinuation { c in
            let resume = OnceResume<T>()
            let watchdog = TaskBox()
            watchdog.set(Task {
                try? await Task.sleep(nanoseconds: UInt64(hardLimit * 1_000_000_000))
                resume.resume(c, with: fallback)
            })
            queue.async {
                let result = work()
                Task {
                    await self.gate.release()
                    if resume.resume(c, with: result) { watchdog.cancel() }
                }
            }
        }
    }
}

@MainActor
public enum AutomaticCopyCapture {
    public static func capture(configuration: SelectionConfiguration = .default,
                               request: CopyRequest) async -> SelectionResult? {
        await captureResponse(configuration: configuration, request: request).result
    }

    public static func captureResponse(configuration: SelectionConfiguration = .default,
                                       request: CopyRequest) async -> SelectionReadResponse {
        await captureResponse(
            configuration: configuration, request: request, pasteboard: .general,
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            menuState: { await CopyMenuProbe.shared.settledState(for: $0, timeout: min(0.15, configuration.axReadTimeout)) },
            overlayPresent: { CopyTriggerGate.isForeignOverlayPresent(at: NSEvent.mouseLocation) })
    }

    /// Convenience overload if called with just a trigger (e.g. legacy/explicit callers)
    public static func capture(
        configuration: SelectionConfiguration = .default,
        trigger: @escaping SelectionRetrievalCoordinator.CopyTrigger
    ) async -> SelectionResult? {
        await capture(
            configuration: configuration,
            request: CopyRequest(trigger: trigger, evidence: CopyEvidence("legacy-trigger", .weak))
        )
    }

    /// Convenience overload if called with CopyRequest passed as trigger argument
    public static func capture(
        configuration: SelectionConfiguration = .default,
        trigger: CopyRequest
    ) async -> SelectionResult? {
        await capture(
            configuration: configuration,
            request: trigger
        )
    }

    static func capture(
        configuration: SelectionConfiguration = .default, request: CopyRequest,
        pasteboard: NSPasteboard, frontmostPID: @escaping @MainActor () -> pid_t?,
        menuState: @MainActor (pid_t) async -> CopyMenuState,
        overlayPresent: @escaping @MainActor () -> Bool
    ) async -> SelectionResult? {
        await captureResponse(configuration: configuration, request: request, pasteboard: pasteboard,
            frontmostPID: frontmostPID, menuState: menuState, overlayPresent: overlayPresent).result
    }

    static func captureResponse(
        configuration: SelectionConfiguration = .default,
        request: CopyRequest,
        pasteboard: NSPasteboard,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        menuState: @MainActor (pid_t) async -> CopyMenuState,
        overlayPresent: @escaping @MainActor () -> Bool
    ) async -> SelectionReadResponse {
        if Task.isCancelled { return SelectionReadResponse(status: .cancelled) }
        guard let pid = frontmostPID() else { return SelectionReadResponse(status: .targetChanged) }

        if request.evidence.strength == .weak {
            let phaseStart = SelectionTrace.current?.elapsedMicros ?? 0
            let state = await menuState(pid)
            if let trace = SelectionTrace.current { trace.addMetric("copyMenuMicros", trace.elapsedMicros - phaseStart) }
            DiagnosticsHub.shared.log(.trace, .pasteboard, "automatic copy evaluating menu", fields: [
                "pid": .int(Int64(pid)),
                "menuState": .token("\(state)"),
                "evidence": .token(request.evidence.reason)
            ])
            guard state != .disabled else {
                DiagnosticsHub.shared.log(.trace, .pasteboard, "automatic copy skipped, copy disabled under weak evidence", fields: [
                    "pid": .int(Int64(pid)),
                    "menuState": .token("\(state)")
                ])
                return SelectionReadResponse(status: .copyBlocked)
            }
            if case .unknown(let reason) = state {
                // "Couldn't tell" is not "disabled" (the CopyMenuProbe contract itself never
                // conflates the two): a terminal omits the AppKit Edit ▸ Copy item entirely, so
                // `noCopyItem` is its steady state, and a cold menu walk times out without
                // meaning. Refusing here turns every inconclusive probe into a permanent
                // retrieval failure. The pasteboard engine snapshots and restores around the
                // trigger, so proceeding on an unknown verdict cannot clobber the clipboard —
                // only a positive `.disabled` refuses.
                DiagnosticsHub.shared.log(.trace, .pasteboard, "copy menu state unknown, proceeding under weak evidence", fields: [
                    "pid": .int(Int64(pid)),
                    "reason": .token(reason.rawValue)
                ])
            }
        } else {
            DiagnosticsHub.shared.log(.trace, .pasteboard, "automatic copy proceeding with strong evidence", fields: [
                "pid": .int(Int64(pid)),
                "evidence": .token(request.evidence.reason)
            ])
        }
        if Task.isCancelled { return SelectionReadResponse(status: .cancelled) }
        guard frontmostPID() == pid else { return SelectionReadResponse(status: .targetChanged) }

        let engine = PasteboardCopyEngine(configuration: configuration, authorizationFailure: {
            if Task.isCancelled { return .cancelled }
            if frontmostPID() != pid { return .targetChanged }
            return overlayPresent() ? .copyBlocked : nil
        }, isCopyAuthorized: {
            !Task.isCancelled && frontmostPID() == pid && !overlayPresent()
        })
        return await engine.captureResponse(pasteboard: pasteboard) {
            guard !Task.isCancelled, frontmostPID() == pid else { return }
            request.trigger()
        }
    }
}

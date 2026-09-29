# AGENTS.md

OpenSelection is a standalone, high-performance Swift 6 selection retrieval engine for macOS (macOS 14+). It extracts selected text, screen bounds, rich representations (HTML, RTF), and editable state from any active macOS application using a multi-tiered, deadline-bounded cascade.

## Build & Test

OpenSelection is a pure Swift Package with **zero third-party dependencies**. It builds and tests entirely with standard Swift toolchain commands.

```bash
swift build                                         # compile Debug target
swift test                                          # full test suite (0 skips, ~5s)
swift test --filter AutomaticCopyCaptureTests       # run single test suite
swift test --filter testTerminalAndMultiProcessApp  # run single test method
```

All code must compile under Swift 6 language mode with complete concurrency checking (`SWIFT_STRICT_CONCURRENCY: complete`) and zero warnings.

---

## Cardinal Architectural Invariants

### 1. Avoid Hardcoding Bundle IDs Until Strictly Impossible

**Prefer structural heuristics, accessibility hierarchy, window server properties, and capability checks over bundle ID allowlists or denylists.**

Every hardcoded bundle ID introduces technical debt: it misses app forks, updates, and alternatives, turning maintenance into an endless game of whack-a-mole. Only introduce or check a bundle ID when an application has an idiosyncratic architecture that is *mathematically impossible* to detect generically.

Before adding a bundle ID check, exhaust these structural alternatives:
1. **AX Roles & Hierarchy**:
   - Check `isTextBearing` (`AXTextField`, `AXTextArea`, `AXWebArea`, ancestor roles).
   - Check `isEditableContext` (`selectedTextRange != nil`, settable attributes via `AXUIElementIsAttributeSettable`).
   - Check `rowSelectionRoles` (`AXTable`, `AXOutline`, `AXRow`, `AXCell`) to prevent copying list selections as text.
   - Check structural absence of text surfaces: the OneNote copy waiver is structural — if an app exposes *zero* AX text surfaces and *no* `AXWebArea`, it is allowed to use copy fallback without requiring an allowlist entry.
2. **Cursor Geometry & Silhouettes**:
   - Do not assume an app uses standard cursor names. Use `CursorClassifier.current` / `CursorClassifier.classify(_:)`, which analyzes pixel alpha silhouettes (`.beam`, `.arrow`, `.pointingHand`) from `NSCursor.currentSystem` across all apps.
3. **Window Server Geometry**:
   - `SelectionGestureWindow` uses `CGWindowListCopyWindowInfo` to detect window moves, resizes, and drags based on screen frames (`currentFrame != originalFrame`), independent of app bundle identity.
4. **Overlay Failure Modes**:
   - `CopyTriggerGate` fails **open** for unknown overlays (window managers, HUDs, utilities) rather than maintaining an allowlist of "good" apps. It only suppresses for known capture overlays whose full-screen pickers literally hijack ⌘C.
5. **Legitimate Exceptions (Where Bundle IDs Are Allowed)**:
   - Microsoft Office (`com.microsoft.Word`, `Excel`, `Powerpoint`): Required because Office exposes custom AppleScript Object Models (`content of text object of selection`) that prevent clipboard pollution.
   - Terminal Emulators (`AppMatching.terminalGroup`): Required because terminal emulators manage keybindings in-process and omit standard AppKit `Edit ▸ Copy` menu items.
   - Multi-process browsers (`AppMatching.browserPatterns`, `electronGroup`): Required for IPC copy timeout deadlines (`0.65s`) and bypassing expensive AX menu tree walks that stall Chrome/Electron renderer processes.

---

### 2. Zero Third-Party Dependencies

OpenSelection must remain completely self-contained. It relies exclusively on Apple system frameworks:
- `AppKit` (events, pasteboards, running apps, cursor state)
- `ApplicationServices` / `HIServices` (Accessibility APIs, `AXUIElement`, `AXTextMarkerRange`)
- `CoreGraphics` (event posting, window server geometry)
- `os.log` & `os.lock` (`Logger`, `OSAllocatedUnfairLock`)
- `Foundation`

Do not add SPM packages or external libraries.

---

### 3. Concurrency, Watchdogs & Deadlock Prevention

Accessibility messaging on macOS is inherently synchronous and IPC-bound. An unresponsive target app or beachballing process **will hang any thread that queries it**.

1. **Never block the main actor on AX calls**:
   - All blocking AX queries (`AXElementInspector.inspect`, menu traversals, attribute reads) must execute off the main actor on dedicated concurrent queues (`axInspectQueue`, `probeQueue`).
2. **Every AX operation must be watchdog-bounded**:
   - Wrap continuations with `OnceResume<T>` and a racing `TaskBox` watchdog sleeping for the configured deadline (`axReadTimeout: 0.5s`, probe timeout: `0.25s`).
   - If the target app stalls, the watchdog resumes `nil` and logs a timeout without hanging the caller.
3. **Concurrency Permit Gating**:
   - Use actor-backed gates (`InspectConcurrencyGate`, `ProbeGate`) to cap concurrent in-flight AX queries (default: 4).
   - This prevents rapid gestures or pointer hover events from starving the GCD cooperative thread pool.

---

### 4. Two-Layer Gesture & Copy Protection Model

Synthetic keystrokes (`⌘C`, `⌘V`) and `Edit ▸ Copy` menu presses post real system-wide side effects that can beep or mutate state. OpenSelection prevents false triggers via a two-layer defense:

```
[ Mouse / Keyboard Gesture ]
             │
             ▼
  ┌─────────────────────────────────────────────────────────┐
  │ Layer 1: Window Geometry Guard (SelectionGestureWindow) │
  │   - Snapshot window frame at mouseDown                  │
  │   - Compare frame at mouseUp (current != original)      │
  │   - Drop window drags/moves/resizes BEFORE retrieval    │
  └─────────────────────────────────────────────────────────┘
             │
             │ Window stationary
             ▼
  ┌─────────────────────────────────────────────────────────┐
  │ Layer 2: Evidence & Menu Pre-Gate (AutomaticCopyCapture)│
  │   - Check foreign overlay (CopyTriggerGate)             │
  │   - Require text evidence for copy strategies           │
  │   - For native text controls: require enabled ⌘C menu   │
  │   - Terminals & Browsers bypass menu walk               │
  └─────────────────────────────────────────────────────────┘
             │
             ▼
[ Execute Strategy Cascade ]
```

- **Layer 1 (Geometry Guard)**: Protects against TextEdit/Notes title bar dragging (Issue #123) and window management moves. If the window moved or resized, retrieval is dropped before touching the clipboard.
- **Layer 2 (Evidence & Menu Gate)**: Protects against Figma canvas object duplication (Issue #121) and empty text control alert beeps. Canvas tools must provide `copyEvidence` (caret cursor, non-empty range, or text-bearing role) before any copy is fired.
- **Terminal & Browser Bypass**: Terminals and multi-process browsers handle shortcuts internally or suffer IPC latency. They bypass the AX menu bar walk and use direct pasteboard capture with geometry guards.

---

### 5. Clipboard Integrity & Manager Transparency

Synthetic copies must be completely invisible to the user and third-party clipboard managers (Raycast, Alfred, Maccy, Paste):

1. **Snapshot Archiving**:
   - `PasteboardSnapshot.capture(_:)` deep-copies all pasteboard types before any copy trigger is fired.
   - Handles lazy/promised types by recording empty `Data()` placeholders to preserve declared type sets.
2. **Transient Markers**:
   - When restoring original clipboard items, always tag them with:
     - `org.nspasteboard.TransientType`
     - `org.nspasteboard.AutoGeneratedType`
     - `org.nspasteboard.ConcealedType`
     - `x.nspasteboard.ModifiedType`
3. **Microsecond Exposure Window**:
   - Once a synthetic copy arrives on the pasteboard, read its string/HTML/RTF content synchronously and restore the original snapshot immediately.
   - Do not introduce asynchronous delays or suspension points between reading the synthetic copy and restoring the snapshot.
4. **Collision Protection**:
   - Synthetic events carry `KeyboardEventPoster.syntheticEventTag`.
   - If the user physically presses `⌘C` or `⌘X` while a synthetic copy is in flight, the monitor detects the untagged event and preserves the user's new copy instead of restoring old content.

---

### 6. Strategy Cascade Order

When `SelectionRetrievalCoordinator.retrieve` is called, strategies are evaluated in this strict order:

| Strategy | Mechanism | Target Applications |
| :--- | :--- | :--- |
| **`AXTextControlStrategy`** | Direct zero-copy AX read (`kAXSelectedTextAttribute` / `kAXValueAttribute` UTF-16 slice) | Native Cocoa apps (TextEdit, Notes, Pages, AppKit forms) |
| **`AXWebAreaStrategy`** | `AXSelectedTextMarkerRange` with settle retries and fresh element polling | WebKit web areas, Safari, Mail web views |
| **`officeScript`** | AppleScript Object Model execution with deadline task group | Microsoft Word, Excel, PowerPoint |
| **`menuCopy`** | Accessibility press of `Edit ▸ Copy` | Apps with disabled keystroke taps |
| **`keyboardCopy`** | Synthetic ⌘C dispatch with pasteboard snapshot & transient restoration | Terminal emulators, Chromium, Electron (VS Code, Slack) |

#### Rich Content Enrichment
If an AX strategy (`.axTextControl` or `.axWebArea`) returns substantial plain text in a browser, multi-process app, or rich document app (e.g. Apple Notes, Pages), the coordinator triggers a background copy capture to enrich the result with `public.html`, `public.rtf`, and private rich flavors without altering the plain text selection.

---

### 7. Logging & Privacy Standards

OpenSelection uses `OpenSelectionLogging` (`os.Logger(subsystem: "com.openselection", category: "retrieval")`), pluggable via `OpenSelectionLogging.logger`:

- **NEVER log selected text, clipboard contents, or document fragments.**
- Only log PIDs, bundle IDs, strategy names, geometry coordinates, and timeout events.
- All log interpolations of target data must respect privacy constraints.

---

### 8. Testing Invariants & Test Doubles

1. **Headless Execution**:
   - Tests must run cleanly in CI and headless environments with zero UI prompts and zero test skips (`swift test` must report 0 failures, 0 skips).
2. **Mock Applications**:
   - Any subclass of `NSRunningApplication` (e.g. `MockTestApp`) **must override and return a valid positive `processIdentifier`** (e.g. `99999`).
   - If `processIdentifier` returns `0` or `nil`, `AutomaticCopyCapture` and `PasteboardCopyEngine` will fall back to `NSWorkspace.shared.frontmostApplication`, creating flaky host-environment leaks.
3. **Injectable Seams**:
   - All platform dependencies (mouse location, cursor class, window geometry, frontmost application, pasteboard, script runner) are injectable via closures on `OpenSelectionMonitor`, `SelectionRetrievalCoordinator`, and `SelectionReplacer`. Always inject test doubles in unit tests.

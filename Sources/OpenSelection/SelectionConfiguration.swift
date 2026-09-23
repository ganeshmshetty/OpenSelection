// SelectionConfiguration.swift
// OpenSelection
//
// Configurable timeouts, retry budgets, and parameters for selection retrieval.
import CoreGraphics
import Foundation

public struct SelectionConfiguration: Sendable, Equatable {
    /// Maximum time in seconds for one AX inspect or menu press operation before timing out.
    public var axReadTimeout: TimeInterval

    /// Maximum number of AX inspects and menu presses that can run concurrently.
    public var axMaxConcurrentInspects: Int

    /// Timeout (seconds) for detecting a pasteboard advance after a synthetic copy trigger.
    public var pasteboardCopyTimeout: TimeInterval

    /// Longer copy-poll deadline for Safari and WebKit browsers.
    public var safariPasteboardCopyTimeout: TimeInterval

    /// Interval (seconds) between settle-retry polls for dynamic web area selections.
    public var webAreaSettleInterval: TimeInterval

    /// Maximum number of retry polls for web area selections before giving up.
    public var webAreaSettleMaxRetries: Int

    /// Delay (seconds) before restoring the archived pasteboard on successful capture.
    public var pasteboardRestoreDelay: TimeInterval

    /// Virtual key code for the copy shortcut (0x08 is 'c' on macOS US keyboard layout).
    public var copyVirtualKey: CGKeyCode

    /// Maximum ancestor depth walked when inspecting UI elements and locating container roles.
    public var ancestorWalkDepth: Int

    /// Maximum execution time (seconds) for AppleScript selection retrieval (e.g. Office apps).
    public var officeScriptTimeout: TimeInterval

    /// Delay (seconds) before restoring the archived pasteboard on non-destructive paste replacement.
    public var pasteboardDeliveryRestoreDelay: TimeInterval

    /// Virtual key code for the paste shortcut (0x09 is 'v' on macOS US keyboard layout).
    public var pasteVirtualKey: CGKeyCode

    /// Timeout (seconds) for detecting if Paste is enabled via Accessibility menu traversal.
    public var pasteProbeTimeout: TimeInterval

    /// Maximum concurrent paste probes allowed.
    public var pasteProbeMaxConcurrent: Int

    /// Whether web / Electron / rich-document selections are enriched by posting a synthetic copy
    /// to capture HTML, RTF, and app-private pasteboard flavors. Disabling it removes that
    /// keystroke (and the clipboard churn, and any site anti-copy handler it trips) at the cost of
    /// rich content.
    public var enrichRichContent: Bool

    /// Default excluded bundle IDs (e.g. password managers, security utilities).
    public static let defaultExcludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.1password.1password7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess"
    ]

    public init(
        axReadTimeout: TimeInterval = 0.5,
        axMaxConcurrentInspects: Int = 4,
        pasteboardCopyTimeout: TimeInterval = 0.25,
        safariPasteboardCopyTimeout: TimeInterval = 0.4,
        webAreaSettleInterval: TimeInterval = 0.05,
        webAreaSettleMaxRetries: Int = 6,
        pasteboardRestoreDelay: TimeInterval = 0.01,
        copyVirtualKey: CGKeyCode = 0x08,
        ancestorWalkDepth: Int = 25,
        officeScriptTimeout: TimeInterval = 0.25,
        pasteboardDeliveryRestoreDelay: TimeInterval = 0.25,
        pasteVirtualKey: CGKeyCode = 0x09,
        pasteProbeTimeout: TimeInterval = 0.2,
        pasteProbeMaxConcurrent: Int = 4,
        enrichRichContent: Bool = false
    ) {
        self.axReadTimeout = axReadTimeout
        self.axMaxConcurrentInspects = axMaxConcurrentInspects
        self.pasteboardCopyTimeout = pasteboardCopyTimeout
        self.safariPasteboardCopyTimeout = safariPasteboardCopyTimeout
        self.webAreaSettleInterval = webAreaSettleInterval
        self.webAreaSettleMaxRetries = webAreaSettleMaxRetries
        self.pasteboardRestoreDelay = pasteboardRestoreDelay
        self.copyVirtualKey = copyVirtualKey
        self.ancestorWalkDepth = ancestorWalkDepth
        self.officeScriptTimeout = officeScriptTimeout
        self.pasteboardDeliveryRestoreDelay = pasteboardDeliveryRestoreDelay
        self.pasteVirtualKey = pasteVirtualKey
        self.pasteProbeTimeout = pasteProbeTimeout
        self.pasteProbeMaxConcurrent = pasteProbeMaxConcurrent
        self.enrichRichContent = enrichRichContent
    }

    public static let `default`: SelectionConfiguration = {
        var config = SelectionConfiguration()
        // Diagnostic override: set OPENCLIP_ENABLE_RICH_CAPTURE=1 to enable the
        // synthetic copy that captures HTML/RTF/flavors for web selections.
        if ProcessInfo.processInfo.environment["OPENCLIP_ENABLE_RICH_CAPTURE"] == "1" {
            config.enrichRichContent = true
        }
        if ProcessInfo.processInfo.environment["OPENCLIP_DISABLE_RICH_CAPTURE"] == "1" {
            config.enrichRichContent = false
        }
        return config
    }()
}

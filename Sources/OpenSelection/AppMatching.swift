// AppMatching.swift
// OpenSelection
//
// Catalog of bundle identifier patterns and categorization rules for browsers,
// office applications, and native apps.
import Foundation

public enum AppMatching: Sendable {
    /// Wildcard-aware bundle-id match: exact equality, or a trailing-`.*` / `*` prefix rule
    public static func matches(pattern: String, bundleID: String) -> Bool {
        if pattern == "*" { return true }
        if pattern == bundleID { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast(1))
            return bundleID.hasPrefix(prefix)
        }
        return false
    }

    public static func matchesAny(_ patterns: [String], bundleID: String) -> Bool {
        patterns.contains { matches(pattern: $0, bundleID: bundleID) }
    }

    public static let safariGroup: [String] = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.kagi.kagimacOS"
    ]

    public static let chromiumGroup: [String] = [
        "com.google.Chrome.*",
        "org.chromium.*",
        "com.brave.Browser.*",
        "com.microsoft.edgemac.*",
        "com.pushplaylabs.sidekick",
        "com.vivaldi.Vivaldi.*",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaNext",
        "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaGX",
        "com.sigmaos.sigmaos.macos",
        "com.quark.desktop",
        "net.imput.helium",
        "ai.perplexity.comet",
        "com.openai.atlas",
        "org.ecosia.browser"
    ]

    public static let firefoxGroup: [String] = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "net.waterfox.waterfox",
        "org.mozilla.librewolf",
        "app.zen-browser.zen"
    ]

    public static let arcGroup: [String] = [
        "company.thebrowser.*"
    ]

    public static let electronGroup: [String] = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.visualstudio.code.oss",
        "com.cursor.*",
        "com.exafunction.windsurf",
        "com.codeium.windsurf",
        "cn.trae.app",
        "com.byteplus.trae",
        "md.obsidian",
        "notion.id",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord*",
        "com.linear*",
        "com.figma.Desktop",
        "com.postmanlabs.mac",
        "com.github.GitHubClient",
        "org.whispersystems.signal-desktop",
        "com.mattermost.Mattermost",
        "com.todesktop.*",
        "net.whatsapp.WhatsApp*",
        "com.spotify.client",
        "com.microsoft.teams*",
        "com.insomnia.app",
        "com.tencent.xinWeChat*",
        "com.tencent.WeChat*"
    ]

    public static let browserPatterns: [String] = safariGroup + chromiumGroup + firefoxGroup + arcGroup

    public static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return matchesAny(browserPatterns, bundleID: bundleID)
    }

    public static func isMultiProcess(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return isBrowser(bundleID) || matchesAny(electronGroup, bundleID: bundleID)
    }

    public static let microsoftOfficeGroup: [String] = [
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint"
    ]

    public static func isMicrosoftOffice(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return microsoftOfficeGroup.contains(bundleID)
    }

    /// Apps whose AX tree never exposes a text selection, so the only way to read them is to post a
    /// synthetic copy. The copy-evidence gate is waived for these: with no cursor class, no
    /// `AXSelectedText`/range, and no text-control role in the snapshot, the gate would skip the
    /// copy strategy and retrieval would always return nil. Verified against Microsoft OneNote
    /// (`com.microsoft.onenote.mac`), whose canvas exposes no `AXSelectedText` for a mouse selection
    /// while ⌘C copies it correctly. Keep this list tight — every entry fires a real ⌘C on drag.
    public static let copyFallbackApps: Set<String> = [
        "com.microsoft.onenote.mac"
    ]

    public static func isCopyFallbackApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return copyFallbackApps.contains(bundleID)
    }

    public static let nativeApps: [String] = [
        "com.apple.TextEdit",
        "com.apple.mail",
        "com.apple.finder",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.MobileSMS",
        "com.apple.reminders",
        "com.apple.Preview",
        "com.apple.calculator",
        "com.apple.systempreferences",
        "com.apple.SystemSettings"
    ]

    public static let strictlyNativeApps: Set<String> = Set(nativeApps)

    public static func isStrictlyNative(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return strictlyNativeApps.contains(bundleID)
    }

    public static let richDocumentApps: Set<String> = [
        "com.apple.Notes",
        "com.apple.TextEdit",
        "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers",
        "com.apple.iWork.Keynote",
        "com.apple.mail"
    ]

    public static func isRichDocumentApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return richDocumentApps.contains(bundleID)
    }
}

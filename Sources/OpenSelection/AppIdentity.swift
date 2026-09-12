// AppIdentity.swift
// OpenSelection
//
// Represents external application identity (bundle identifier and localized name).
import AppKit
import Foundation

public struct AppIdentity: Sendable, Equatable, Hashable {
    public let bundleIdentifier: String?
    public let localizedName: String?

    public init(bundleIdentifier: String? = nil, localizedName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }

    public init(_ app: NSRunningApplication?) {
        self.bundleIdentifier = app?.bundleIdentifier
        self.localizedName = app?.localizedName
    }
}

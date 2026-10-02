import Foundation

/// Stable, content-free outcome codes for selection retrieval and its callers.
public enum SelectionReadStatus: String, Sendable, Codable, Equatable {
    case selection, noSelection, targetChanged, timedOut, copyBlocked, cancelled
    case clipboardFallback, policyBlocked, busy, failed, tooLarge
}

/// The result and the reason it is present or absent travel together.
public struct SelectionReadResponse: Sendable {
    public let result: SelectionResult?
    public let isEditable: Bool
    public let traceID: UInt64?
    public let status: SelectionReadStatus

    public init(result: SelectionResult? = nil, isEditable: Bool = false, status: SelectionReadStatus, traceID: UInt64? = nil) {
        self.traceID = traceID
        self.result = result
        self.isEditable = isEditable
        self.status = status
    }
}

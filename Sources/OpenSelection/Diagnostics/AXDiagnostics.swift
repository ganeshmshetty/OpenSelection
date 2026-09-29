// AXDiagnostics.swift
// OpenSelection
//
// Accessibility error categorization and unmasking for diagnostics.
import ApplicationServices
import Foundation

/// Structured categorization of accessibility subsystem errors.
public enum AXErrorCode: String, Sendable, Codable, Equatable, CaseIterable {
    case apiDisabled
    case invalidUIElement
    case cannotComplete
    case attributeUnsupported
    case actionUnsupported
    case notImplemented
    case noValue
    case parameterizedAttributeUnsupported
    case notificationUnsupported
    case illegalArgument
    case other

    public init(axError: AXError) {
        switch axError {
        case .apiDisabled:
            self = .apiDisabled
        case .invalidUIElement:
            self = .invalidUIElement
        case .cannotComplete:
            self = .cannotComplete
        case .attributeUnsupported:
            self = .attributeUnsupported
        case .actionUnsupported:
            self = .actionUnsupported
        case .notImplemented:
            self = .notImplemented
        case .noValue:
            self = .noValue
        case .parameterizedAttributeUnsupported:
            self = .parameterizedAttributeUnsupported
        case .notificationUnsupported:
            self = .notificationUnsupported
        case .illegalArgument:
            self = .illegalArgument
        default:
            self = .other
        }
    }

    public enum LikelyCause: String, Sendable, Codable, Equatable {
        case permissionDenied
        case ipcTimeoutOrBusy
        case unsupportedByTarget
        case staleElement
        case unknown
    }

    public var likelyCause: LikelyCause {
        switch self {
        case .apiDisabled:
            return .permissionDenied
        case .cannotComplete:
            return .ipcTimeoutOrBusy
        case .invalidUIElement:
            return .staleElement
        case .attributeUnsupported, .notImplemented, .parameterizedAttributeUnsupported, .actionUnsupported:
            return .unsupportedByTarget
        default:
            return .unknown
        }
    }
}

/// Result of an accessibility operation preserving underlying error codes.
public enum AXReadResult<T>: @unchecked Sendable {
    case value(T)
    case failure(AXErrorCode)

    public var valueOrNil: T? {
        switch self {
        case .value(let val):
            return val
        case .failure:
            return nil
        }
    }
}

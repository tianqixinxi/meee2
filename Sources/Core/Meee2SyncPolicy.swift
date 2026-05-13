import Foundation

public enum Meee2SyncPolicy: String, Codable, CaseIterable {
    case `private`
    case metadata
    case summary
    case recentContext
    case fullTranscript
    case artifactsOnly

    public init(rawValueOrAlias value: String?) {
        switch value {
        case Self.metadata.rawValue, "metadataOnly":
            self = .metadata
        case Self.summary.rawValue:
            self = .summary
        case Self.recentContext.rawValue, "recent_context":
            self = .recentContext
        case Self.fullTranscript.rawValue, "full_transcript":
            self = .fullTranscript
        case Self.artifactsOnly.rawValue, "artifacts_only":
            self = .artifactsOnly
        default:
            self = .private
        }
    }

    public var uploadsSession: Bool {
        self != .private
    }

    public var uploadsSummary: Bool {
        switch self {
        case .summary, .recentContext, .fullTranscript:
            return true
        case .private, .metadata, .artifactsOnly:
            return false
        }
    }

    public var uploadsRecentContext: Bool {
        switch self {
        case .recentContext, .fullTranscript:
            return true
        case .private, .metadata, .summary, .artifactsOnly:
            return false
        }
    }
}

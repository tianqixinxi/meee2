import Foundation

enum CanvasOrchestrationKind: String, Codable, Equatable, CaseIterable {
    case workflowGraphV1 = "workflow-graph-v1"
    case monitorObserverV1 = "monitor-observer-v1"
    case pokerRulesV1 = "poker-rules-v1"
}

struct CanvasOrchestrationStateSlot: Codable, Equatable {
    var nodeId: String
    var reference: String
}

struct CanvasOrchestrationActionBinding: Codable, Equatable {
    var id: String
    var capability: String
    var targetSlot: String?
    var targetRoleSlot: String?
    var payloadSchema: BoardJSONValue?
}

struct CanvasOrchestrationBindings: Codable, Equatable {
    var roleSlots: [String: String]
    var stateSlots: [String: CanvasOrchestrationStateSlot]
    var actions: [CanvasOrchestrationActionBinding]

    static let empty = CanvasOrchestrationBindings(roleSlots: [:], stateSlots: [:], actions: [])
}

struct CanvasOrchestrationProfile: Codable, Equatable {
    var version: Int
    var kind: CanvasOrchestrationKind
    var policy: [String: BoardJSONValue]
    var bindings: CanvasOrchestrationBindings

    static let defaultVersion = 1

    static func `default`(kind: CanvasOrchestrationKind) -> CanvasOrchestrationProfile {
        CanvasOrchestrationProfile(
            version: defaultVersion,
            kind: kind,
            policy: [:],
            bindings: .empty
        )
    }
}

struct CanvasOrchestrationProfileStatus: Codable, Equatable {
    enum State: String, Codable, Equatable {
        case valid
        case missingMigrated = "missing-migrated"
        case invalidUsingLastValid = "invalid-using-last-valid"
    }

    var state: State
    var path: String
    var error: String?
    var updatedAt: Date?
}

public struct TemplateIntakePolicy: Codable, Equatable {
    public var version: Int
    public var matchPhrases: [String]
    public var adaptationTargets: [String]
    public var initialStateRefs: [String]
    public var outputRefs: [String]

    public static let defaultVersion = 1

    public init(
        version: Int,
        matchPhrases: [String],
        adaptationTargets: [String],
        initialStateRefs: [String],
        outputRefs: [String]
    ) {
        self.version = version
        self.matchPhrases = matchPhrases
        self.adaptationTargets = adaptationTargets
        self.initialStateRefs = initialStateRefs
        self.outputRefs = outputRefs
    }
}

import Foundation

enum CanvasRenderLayoutKind: String, Codable, Equatable, CaseIterable {
    case spatial
    case graph
    case collection
}

enum CanvasRenderRendererId: String, Codable, Equatable, CaseIterable {
    case card
    case document
    case avatar
    case container
    case asset
    case label
    case list
    case kanban
    case matrix
    case grid
    case directedEdge = "directed-edge"
    case groupBoundary = "group-boundary"
}

enum CanvasRenderActionId: String, Codable, Equatable, CaseIterable {
    case openInspector
    case openSession
    case showVersions
    case runSceneAction
    case revealProfile
}

enum CanvasObjectEntityKind: String, Codable, Equatable, CaseIterable {
    case node
    case artifact
    case session
    case dataSource
    case subCanvas
    case integrationEntity
}

enum CanvasRenderOnlyKind: String, Codable, Equatable, CaseIterable {
    case background
    case region
    case container
    case label
    case asset
}

enum CanvasRelationKind: String, Codable, Equatable, CaseIterable {
    case dependency
    case dataflow
    case membership
    case projection
    case spatialLink = "spatial-link"
    case grouping
}

struct CanvasObjectEntityRef: Codable, Equatable {
    var kind: CanvasObjectEntityKind
    var id: String
    var nodeId: String?
    var reference: String?
}

struct CanvasRenderOnlyObject: Codable, Equatable {
    var kind: CanvasRenderOnlyKind
    var id: String
}

struct CanvasObjectRule: Codable, Equatable {
    var id: String
    var entityKind: CanvasObjectEntityKind?
    var renderOnlyKind: CanvasRenderOnlyKind?
    var renderer: CanvasRenderRendererId
}

struct CanvasRendererRule: Codable, Equatable {
    var id: String
    var renderer: CanvasRenderRendererId
    var entityKind: CanvasObjectEntityKind?
    var renderOnlyKind: CanvasRenderOnlyKind?
    var variant: String?
    var density: String?
}

struct CanvasRelationRule: Codable, Equatable {
    var id: String
    var kind: CanvasRelationKind
    var renderer: CanvasRenderRendererId
    var visible: Bool
}

struct CanvasRenderActionRule: Codable, Equatable {
    var id: String
    var action: CanvasRenderActionId
    var label: String?
    var targetObjectId: String?
    var sceneActionId: String?
}

struct CanvasRenderLogic: Codable, Equatable {
    var layout: CanvasRenderLayoutKind
    var objectRules: [CanvasObjectRule]
    var relationRules: [CanvasRelationRule]
    var rendererRules: [CanvasRendererRule]
    var actions: [CanvasRenderActionRule]

    static let workflowDefault = CanvasRenderLogic(
        layout: .graph,
        objectRules: [
            CanvasObjectRule(id: "nodes", entityKind: .node, renderOnlyKind: nil, renderer: .card),
            CanvasObjectRule(id: "artifacts", entityKind: .artifact, renderOnlyKind: nil, renderer: .document),
            CanvasObjectRule(id: "sessions", entityKind: .session, renderOnlyKind: nil, renderer: .avatar),
            CanvasObjectRule(id: "data-sources", entityKind: .dataSource, renderOnlyKind: nil, renderer: .list),
            CanvasObjectRule(id: "sub-canvases", entityKind: .subCanvas, renderOnlyKind: nil, renderer: .container)
        ],
        relationRules: [
            CanvasRelationRule(id: "dependencies", kind: .dependency, renderer: .directedEdge, visible: true),
            CanvasRelationRule(id: "dataflow", kind: .dataflow, renderer: .directedEdge, visible: true),
            CanvasRelationRule(id: "membership", kind: .membership, renderer: .groupBoundary, visible: true)
        ],
        rendererRules: [
            CanvasRendererRule(id: "node-card", renderer: .card, entityKind: .node, renderOnlyKind: nil, variant: nil, density: nil),
            CanvasRendererRule(id: "artifact-document", renderer: .document, entityKind: .artifact, renderOnlyKind: nil, variant: nil, density: nil)
        ],
        actions: [
            CanvasRenderActionRule(id: "open-inspector", action: .openInspector, label: nil, targetObjectId: nil, sceneActionId: nil),
            CanvasRenderActionRule(id: "open-session", action: .openSession, label: nil, targetObjectId: nil, sceneActionId: nil),
            CanvasRenderActionRule(id: "show-versions", action: .showVersions, label: nil, targetObjectId: nil, sceneActionId: nil),
            CanvasRenderActionRule(id: "reveal-profile", action: .revealProfile, label: "Reveal Render Profile in Finder", targetObjectId: nil, sceneActionId: nil)
        ]
    )
}

struct CanvasRenderObjectValues: Codable, Equatable {
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var zIndex: Int?
    var hidden: Bool?
    var collapsed: Bool?
    var pinned: Bool?
    var rendererVariant: String?
    var density: String?
    var icon: String?
    var designToken: String?

    func merging(_ patch: CanvasRenderObjectValues) -> CanvasRenderObjectValues {
        CanvasRenderObjectValues(
            x: patch.x ?? x,
            y: patch.y ?? y,
            width: patch.width ?? width,
            height: patch.height ?? height,
            zIndex: patch.zIndex ?? zIndex,
            hidden: patch.hidden ?? hidden,
            collapsed: patch.collapsed ?? collapsed,
            pinned: patch.pinned ?? pinned,
            rendererVariant: patch.rendererVariant ?? rendererVariant,
            density: patch.density ?? density,
            icon: patch.icon ?? icon,
            designToken: patch.designToken ?? designToken
        )
    }
}

struct CanvasRenderRelationValues: Codable, Equatable {
    var visible: Bool?
    var label: String?
    var routeStyle: String?

    func merging(_ patch: CanvasRenderRelationValues) -> CanvasRenderRelationValues {
        CanvasRenderRelationValues(
            visible: patch.visible ?? visible,
            label: patch.label ?? label,
            routeStyle: patch.routeStyle ?? routeStyle
        )
    }
}

struct CanvasRenderValues: Codable, Equatable {
    var objects: [String: CanvasRenderObjectValues]
    var relations: [String: CanvasRenderRelationValues]
    var renderOnlyObjects: [CanvasObject]

    static let empty = CanvasRenderValues(objects: [:], relations: [:], renderOnlyObjects: [])
}

struct CanvasRenderProfile: Codable, Equatable {
    var version: Int
    var logic: CanvasRenderLogic
    var values: CanvasRenderValues

    static let defaultVersion = 1

    static func `default`(layout: CanvasRenderLayoutKind = .graph) -> CanvasRenderProfile {
        var logic = CanvasRenderLogic.workflowDefault
        logic.layout = layout
        return CanvasRenderProfile(version: defaultVersion, logic: logic, values: .empty)
    }
}

struct CanvasRenderProfileStatus: Codable, Equatable {
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

struct CanvasObject: Codable, Equatable {
    var id: String
    var label: String
    var entityRef: CanvasObjectEntityRef?
    var renderOnly: CanvasRenderOnlyObject?
    var renderer: CanvasRenderRendererId
    var values: CanvasRenderObjectValues?
    var metadata: BoardJSONValue?
}

struct CanvasRelationEndpoint: Codable, Equatable {
    var objectId: String
}

struct CanvasRelation: Codable, Equatable {
    var id: String
    var kind: CanvasRelationKind
    var source: CanvasRelationEndpoint
    var target: CanvasRelationEndpoint
    var renderer: CanvasRenderRendererId
    var values: CanvasRenderRelationValues?
    var metadata: BoardJSONValue?
}

struct CanvasRenderResolver {
    static func resolve(
        record: PlannerStore.CanvasRecord,
        profile: CanvasRenderProfile
    ) -> (objects: [CanvasObject], relations: [CanvasRelation]) {
        var objects: [CanvasObject] = []
        var seenObjectIds = Set<String>()

        func append(_ object: CanvasObject) {
            guard !seenObjectIds.contains(object.id) else { return }
            seenObjectIds.insert(object.id)
            objects.append(object)
        }

        for node in record.nodes {
            append(object(for: node, values: profile.values.objects["node:\(node.id)"]))
            if let sessionId = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty {
                append(CanvasObject(
                    id: "session:\(sessionId)",
                    label: sessionId,
                    entityRef: CanvasObjectEntityRef(kind: .session, id: sessionId, nodeId: node.id, reference: nil),
                    renderOnly: nil,
                    renderer: .avatar,
                    values: profile.values.objects["session:\(sessionId)"],
                    metadata: nil
                ))
            }
            if let subCanvasId = node.subCanvasId?.trimmingCharacters(in: .whitespacesAndNewlines), !subCanvasId.isEmpty {
                append(CanvasObject(
                    id: "subCanvas:\(subCanvasId)",
                    label: node.title,
                    entityRef: CanvasObjectEntityRef(kind: .subCanvas, id: subCanvasId, nodeId: node.id, reference: nil),
                    renderOnly: nil,
                    renderer: .container,
                    values: profile.values.objects["subCanvas:\(subCanvasId)"],
                    metadata: nil
                ))
            }
        }

        for artifact in record.artifacts {
            let objectId = "artifact:\(artifact.id)"
            append(CanvasObject(
                id: objectId,
                label: artifact.title,
                entityRef: CanvasObjectEntityRef(kind: .artifact, id: artifact.id, nodeId: artifact.nodeId, reference: artifact.reference),
                renderOnly: nil,
                renderer: .document,
                values: profile.values.objects[objectId],
                metadata: nil
            ))
        }

        for source in record.canvas.dataSources {
            let objectId = "dataSource:\(source.id)"
            append(CanvasObject(
                id: objectId,
                label: source.semantics.label,
                entityRef: CanvasObjectEntityRef(kind: .dataSource, id: source.id, nodeId: nil, reference: nil),
                renderOnly: nil,
                renderer: .list,
                values: profile.values.objects[objectId],
                metadata: nil
            ))
        }

        for object in profile.values.renderOnlyObjects {
            append(object)
        }

        var relations: [CanvasRelation] = []
        for edge in record.canvas.edges {
            let sourceId = edge.sourceRef.dataSourceId?.isEmpty == false
                ? "dataSource:\(edge.sourceRef.dataSourceId ?? "")"
                : "node:\(edge.sourceRef.nodeId)"
            let targetId = edge.targetRef.dataSourceId?.isEmpty == false
                ? "dataSource:\(edge.targetRef.dataSourceId ?? "")"
                : "node:\(edge.targetRef.nodeId)"
            guard seenObjectIds.contains(sourceId), seenObjectIds.contains(targetId) else { continue }
            let relationKind = relationKind(for: edge)
            let relationId = "edge:\(edge.id)"
            relations.append(CanvasRelation(
                id: relationId,
                kind: relationKind,
                source: CanvasRelationEndpoint(objectId: sourceId),
                target: CanvasRelationEndpoint(objectId: targetId),
                renderer: .directedEdge,
                values: profile.values.relations[relationId],
                metadata: nil
            ))
        }

        var seenRelationIds = Set(relations.map(\.id))
        for artifact in record.artifacts {
            let sourceId = "node:\(artifact.nodeId)"
            let targetId = "artifact:\(artifact.id)"
            guard seenObjectIds.contains(sourceId), seenObjectIds.contains(targetId) else { continue }
            let relationId = "dataflow:\(artifact.nodeId):artifact:\(artifact.id)"
            guard !seenRelationIds.contains(relationId) else { continue }
            seenRelationIds.insert(relationId)
            relations.append(CanvasRelation(
                id: relationId,
                kind: .dataflow,
                source: CanvasRelationEndpoint(objectId: sourceId),
                target: CanvasRelationEndpoint(objectId: targetId),
                renderer: .directedEdge,
                values: profile.values.relations[relationId],
                metadata: nil
            ))
        }

        for node in record.nodes {
            for upstreamId in node.dependsOnNodeIds ?? [] {
                let sourceId = "node:\(upstreamId)"
                let targetId = "node:\(node.id)"
                guard seenObjectIds.contains(sourceId), seenObjectIds.contains(targetId) else { continue }
                let relationId = "dependency:\(upstreamId):\(node.id)"
                guard !seenRelationIds.contains(relationId) else { continue }
                seenRelationIds.insert(relationId)
                relations.append(CanvasRelation(
                    id: relationId,
                    kind: .dependency,
                    source: CanvasRelationEndpoint(objectId: sourceId),
                    target: CanvasRelationEndpoint(objectId: targetId),
                    renderer: .directedEdge,
                    values: profile.values.relations[relationId],
                    metadata: nil
                ))
            }
        }

        for node in record.nodes {
            if let sessionId = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !sessionId.isEmpty {
                let relationId = "membership:node:\(node.id):session:\(sessionId)"
                relations.append(CanvasRelation(
                    id: relationId,
                    kind: .membership,
                    source: CanvasRelationEndpoint(objectId: "node:\(node.id)"),
                    target: CanvasRelationEndpoint(objectId: "session:\(sessionId)"),
                    renderer: .groupBoundary,
                    values: profile.values.relations[relationId],
                    metadata: nil
                ))
            }
            if let subCanvasId = node.subCanvasId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !subCanvasId.isEmpty {
                let relationId = "projection:node:\(node.id):subCanvas:\(subCanvasId)"
                relations.append(CanvasRelation(
                    id: relationId,
                    kind: .projection,
                    source: CanvasRelationEndpoint(objectId: "node:\(node.id)"),
                    target: CanvasRelationEndpoint(objectId: "subCanvas:\(subCanvasId)"),
                    renderer: .groupBoundary,
                    values: profile.values.relations[relationId],
                    metadata: nil
                ))
            }
        }

        return (objects, relations)
    }

    private static func object(for node: PlanningNode, values: CanvasRenderObjectValues?) -> CanvasObject {
        var mergedValues = values
        if mergedValues == nil, let layout = node.layout {
            mergedValues = CanvasRenderObjectValues(
                x: layout.x,
                y: layout.y,
                width: layout.width,
                height: layout.height,
                zIndex: nil,
                hidden: nil,
                collapsed: nil,
                pinned: nil,
                rendererVariant: nil,
                density: nil,
                icon: nil,
                designToken: nil
            )
        }
        let renderer = renderer(for: node)
        return CanvasObject(
            id: "node:\(node.id)",
            label: node.title,
            entityRef: CanvasObjectEntityRef(kind: .node, id: node.id, nodeId: node.id, reference: nil),
            renderOnly: nil,
            renderer: renderer,
            values: mergedValues,
            metadata: nil
        )
    }

    private static func renderer(for node: PlanningNode) -> CanvasRenderRendererId {
        switch node.widget?.kind {
        case .kanban: return .kanban
        case .inbox: return .list
        case .matrix: return .matrix
        case .artifactPreview: return .document
        case .badge: return .card
        case .html: return .document
        case nil: break
        }
        return .card
    }

    private static func relationKind(for edge: Edge) -> CanvasRelationKind {
        switch edge.edgeMode.mode {
        case "dependency": return .dependency
        case "membership": return .membership
        case "projection": return .projection
        case "spatial-link": return .spatialLink
        case "grouping": return .grouping
        default: return .dataflow
        }
    }
}

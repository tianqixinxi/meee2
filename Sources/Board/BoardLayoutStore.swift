import Foundation
import Meee2CommKit

public enum BoardJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([BoardJSONValue])
    case object([String: BoardJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BoardJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BoardJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    static func fromAny(_ raw: Any) -> BoardJSONValue? {
        if raw is NSNull { return .null }
        if let value = raw as? Bool { return .bool(value) }
        if let value = raw as? NSNumber { return .number(value.doubleValue) }
        if let value = raw as? String { return .string(value) }
        if let values = raw as? [Any] {
            return .array(values.compactMap(fromAny))
        }
        if let values = raw as? [String: Any] {
            var out: [String: BoardJSONValue] = [:]
            for (key, value) in values {
                if let converted = fromAny(value) {
                    out[key] = converted
                }
            }
            return .object(out)
        }
        return nil
    }
}

/// BoardLayoutStore —— 多 canvas 的本地持久化状态。
///
/// 文件：`~/.meee2/board-canvases.json`（单文件，原子覆写）。旧的
/// `board-layout.json` 不再读写；产品未 release，这里按 breaking reset 处理。
///
/// 模型：Canvas 和 Session 是 N2N。每个 canvas 拥有自己的 viewport、
/// user elements、channel layout、session positions，以及 session membership。
/// 删除当前 canvas 中的 session 只删除 membership，不归档 session。
public final class BoardLayoutStore {
    public static let shared = BoardLayoutStore()

    public enum CanvasScope: String, Codable, Equatable {
        case personal
        case team
    }

    public enum CanvasKind: String, Codable, Equatable {
        case board     // ReactFlow dep-graph (default workflow editor)
        case monitor   // Workspace monitor (aggregated session / canvas health)
        case template  // Template gallery entry, not a working canvas
        // Note (2026-05-28): kanban/inbox/matrix were briefly modeled as canvas
        // kinds and reverted. Correct model is node-level `widget` (see widget
        // schema added in this same wave). DO NOT add view modes here.
    }

    public struct Point: Codable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double?
        public let height: Double?
        public init(x: Double, y: Double, width: Double? = nil, height: Double? = nil) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Viewport: Codable, Equatable {
        public let scrollX: Double
        public let scrollY: Double
        public let zoom: Double

        public init(scrollX: Double, scrollY: Double, zoom: Double) {
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.zoom = zoom
        }
    }

    public struct Layout: Codable, Equatable {
        public var sessions: [String: Point]
        public var channels: [String: Point]
        public var viewport: Viewport?
        public var userElements: [BoardJSONValue]
        public var dismissedSids: [String]
        public var unreadSids: [String]
        public var updatedAt: Date

        public init(
            sessions: [String: Point],
            channels: [String: Point],
            viewport: Viewport? = nil,
            userElements: [BoardJSONValue] = [],
            dismissedSids: [String] = [],
            unreadSids: [String] = [],
            updatedAt: Date
        ) {
            self.sessions = sessions
            self.channels = channels
            self.viewport = viewport
            self.userElements = userElements
            self.dismissedSids = dismissedSids
            self.unreadSids = unreadSids
            self.updatedAt = updatedAt
        }

        public static let empty = Layout(sessions: [:], channels: [:], updatedAt: Date(timeIntervalSince1970: 0))

        private enum CodingKeys: String, CodingKey {
            case sessions
            case channels
            case viewport
            case userElements
            case dismissedSids
            case unreadSids
            case updatedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try container.decodeIfPresent([String: Point].self, forKey: .sessions) ?? [:]
            channels = try container.decodeIfPresent([String: Point].self, forKey: .channels) ?? [:]
            viewport = try container.decodeIfPresent(Viewport.self, forKey: .viewport)
            userElements = try container.decodeIfPresent([BoardJSONValue].self, forKey: .userElements) ?? []
            dismissedSids = try container.decodeIfPresent([String].self, forKey: .dismissedSids) ?? []
            unreadSids = try container.decodeIfPresent([String].self, forKey: .unreadSids) ?? []
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        }
    }

    public struct Canvas: Codable, Equatable {
        public var id: String
        public var name: String
        public var scope: CanvasScope
        public var kind: CanvasKind?
        public var ownerUserId: String?
        public var teamId: String?
        public var isDefault: Bool
        public var workspaceFolderName: String?
        public var createdBy: String?
        public var remoteId: String?
        public var remoteVersion: Int?
        public var lastSyncedAt: Date?
        public var dirtySince: Date?
        public var syncStatus: String?
        public var lastRemoteUpdatedAt: Date?
        public var conflictRemoteVersion: Int?
        public var conflictRemoteState: BoardJSONValue?
        public var conflictRemoteDeleted: Bool?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String,
            name: String,
            scope: CanvasScope,
            kind: CanvasKind? = .board,
            ownerUserId: String?,
            teamId: String?,
            isDefault: Bool,
            workspaceFolderName: String? = nil,
            createdBy: String?,
            remoteId: String? = nil,
            remoteVersion: Int? = nil,
            lastSyncedAt: Date? = nil,
            dirtySince: Date? = nil,
            syncStatus: String? = nil,
            lastRemoteUpdatedAt: Date? = nil,
            conflictRemoteVersion: Int? = nil,
            conflictRemoteState: BoardJSONValue? = nil,
            conflictRemoteDeleted: Bool? = nil,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.name = name
            self.scope = scope
            self.kind = kind
            self.ownerUserId = ownerUserId
            self.teamId = teamId
            self.isDefault = isDefault
            self.workspaceFolderName = workspaceFolderName
            self.createdBy = createdBy
            self.remoteId = remoteId
            self.remoteVersion = remoteVersion
            self.lastSyncedAt = lastSyncedAt
            self.dirtySince = dirtySince
            self.syncStatus = syncStatus
            self.lastRemoteUpdatedAt = lastRemoteUpdatedAt
            self.conflictRemoteVersion = conflictRemoteVersion
            self.conflictRemoteState = conflictRemoteState
            self.conflictRemoteDeleted = conflictRemoteDeleted
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct DeletedCanvas: Codable, Equatable {
        public var id: String
        public var remoteId: String
        public var teamId: String
        public var baseVersion: Int
        public var deletedAt: Date
    }

    public struct SpawnIntent: Codable, Equatable {
        public var id: String
        public var canvasId: String
        public var cwd: String
        public var command: String
        public var provider: String?
        public var purpose: String?
        public var initialPrompt: String?
        public var layoutHint: Point?
        public var createdAt: Date

        public init(
            id: String = UUID().uuidString.lowercased(),
            canvasId: String,
            cwd: String,
            command: String,
            provider: String? = nil,
            purpose: String? = nil,
            initialPrompt: String? = nil,
            layoutHint: Point? = nil,
            createdAt: Date
        ) {
            self.id = id
            self.canvasId = canvasId
            self.cwd = cwd
            self.command = command
            self.provider = provider
            self.purpose = purpose
            self.initialPrompt = initialPrompt
            self.layoutHint = layoutHint
            self.createdAt = createdAt
        }

        enum CodingKeys: String, CodingKey {
            case id, canvasId, cwd, command, provider, purpose, initialPrompt, layoutHint, createdAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
            self.canvasId = try c.decode(String.self, forKey: .canvasId)
            self.cwd = try c.decode(String.self, forKey: .cwd)
            self.command = try c.decode(String.self, forKey: .command)
            self.provider = try c.decodeIfPresent(String.self, forKey: .provider)
            self.purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
            self.initialPrompt = try c.decodeIfPresent(String.self, forKey: .initialPrompt)
            self.layoutHint = try c.decodeIfPresent(Point.self, forKey: .layoutHint)
            self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        }
    }

    public struct SpawnCandidate {
        public let sessionId: String
        public let cwd: String
        public let provider: String?
        public let startedAt: Date?

        public init(sessionId: String, cwd: String, provider: String?, startedAt: Date?) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.provider = provider
            self.startedAt = startedAt
        }
    }

    public struct MatchedSpawnIntent {
        public let sessionId: String
        public let intent: SpawnIntent
    }

    public struct CanvasSession: Codable, Equatable {
        public var canvasId: String
        public var sessionId: String
        public var visible: Bool
        public var addedBy: String?
        public var addedAt: Date
        public var updatedAt: Date
    }

    public struct Snapshot: Codable, Equatable {
        public var activeCanvasId: String
        public var canvases: [Canvas]
        public var memberships: [CanvasSession]
    }

    public struct TeamCanvasSyncItem: Encodable {
        public let id: String
        public let remoteId: String
        public let teamId: String
        public let name: String
        public let baseVersion: Int
        public let force: Bool
        public let deleted: Bool
        public let layout: Layout
        public let memberships: [CanvasSession]
    }

    public struct RemoteTeamCanvas {
        public let id: String
        public let name: String
        public let teamId: String
        public let version: Int
        public let state: [String: Any]
        public let updatedAt: Date?
        public let deletedAt: Date?

        public init(id: String, name: String, teamId: String, version: Int, state: [String: Any], updatedAt: Date?, deletedAt: Date? = nil) {
            self.id = id
            self.name = name
            self.teamId = teamId
            self.version = version
            self.state = state
            self.updatedAt = updatedAt
            self.deletedAt = deletedAt
        }
    }

    private struct StoreData: Codable, Equatable {
        var activeCanvasId: String?
        var canvases: [Canvas]
        var layouts: [String: Layout]
        var memberships: [String: [String: CanvasSession]]
        var spawnIntents: [SpawnIntent]?
        var sessionHomeCanvasIds: [String: String]?
        var deletedTeamCanvases: [DeletedCanvas]?

        static let empty = StoreData(
            activeCanvasId: nil,
            canvases: [],
            layouts: [:],
            memberships: [:],
            spawnIntents: nil,
            sessionHomeCanvasIds: nil,
            deletedTeamCanvases: nil
        )
    }

    private let fileManager = FileManager.default
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.meee2.BoardLayoutStore", qos: .utility)
    private var cached: StoreData?

    private init() {
        let dir = MEEE2Env.home
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            MWarn("[BoardLayoutStore] failed to create dir \(dir.path): \(error)")
        }
        self.fileURL = MEEE2Env.boardCanvasesURL
    }

    // MARK: - Public API

    /// 读取当前 active canvas 的 layout；保留给旧调用点。
    public func load() -> Layout {
        load(canvasId: nil)
    }

    public func load(canvasId requestedCanvasId: String?) -> Layout {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let canvasId = resolveCanvasIdLocked(store, requestedCanvasId)
            cached = store
            return store.layouts[canvasId] ?? .empty
        }
    }

    /// Bulk variant of `load(canvasId:)` that returns all layouts in a single
    /// `queue.sync` call. Use when building a payload that needs the layout
    /// for every canvas (e.g. `canvasEnvelope`), to avoid N round-trips
    /// through `ensureDefaultCanvasesLocked` (each ~120ms with a large store).
    public func loadAllLayouts() -> [String: Layout] {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            cached = store
            return store.layouts
        }
    }

    /// 清空内存缓存。仅在 Settings → Privacy 的"删除本地数据"流程里调用——
    /// 磁盘上的 `board-canvases.json` 已被 SystemStorageAPI 抹掉，这里把
    /// in-process 缓存 drop 掉，让下一次 `load()` 走 disk 路径（disk 也没了，
    /// 会自动 fall back 到 `StoreData.empty` → 重建默认 canvas）。
    ///
    /// 注意：不直接持久化空 store，避免在删盘失败的边界情况下回写一份新文件。
    public func clearInMemoryCache() {
        queue.sync {
            cached = nil
        }
        SessionEventBus.shared.publish(.boardLayoutChanged)
    }

    /// 整体替换 active canvas 的 layout；保留给旧调用点。
    @discardableResult
    public func save(_ layout: Layout) throws -> Layout {
        try save(layout, canvasId: nil)
    }

    @discardableResult
    public func save(_ layout: Layout, canvasId requestedCanvasId: String?) throws -> Layout {
        let stamped = Layout(
            sessions: layout.sessions,
            channels: layout.channels,
            viewport: layout.viewport,
            userElements: layout.userElements,
            dismissedSids: layout.dismissedSids,
            unreadSids: layout.unreadSids,
            updatedAt: Date()
        )
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let canvasId = resolveCanvasIdLocked(store, requestedCanvasId)
            markTeamCanvasDirtyLocked(&store, canvasId: canvasId)
            store.layouts[canvasId] = stamped
            ensureMembershipsLocked(&store, canvasId: canvasId, sessionIds: Array(stamped.sessions.keys))
            try writeToDiskLocked(store)
            cached = store
        }
        SessionEventBus.shared.publish(.boardLayoutChanged)
        return stamped
    }

    /// 合并更新：传入的 sessions / channels 覆盖同名 key，其他 key 保留。
    /// 目前不公开暴露到 API，仅作为未来 partial-update 扩展点保留。
    @discardableResult
    public func merge(sessions: [String: Point]?, channels: [String: Point]?) throws -> Layout {
        try merge(canvasId: nil, sessions: sessions, channels: channels)
    }

    @discardableResult
    public func merge(canvasId requestedCanvasId: String?, sessions: [String: Point]?, channels: [String: Point]?) throws -> Layout {
        let merged: Layout = try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let canvasId = resolveCanvasIdLocked(store, requestedCanvasId)
            let current = store.layouts[canvasId] ?? .empty
            var nextSessions = current.sessions
            var nextChannels = current.channels
            if let s = sessions {
                for (k, v) in s { nextSessions[k] = v }
            }
            if let c = channels {
                for (k, v) in c { nextChannels[k] = v }
            }
            let next = Layout(
                sessions: nextSessions,
                channels: nextChannels,
                viewport: current.viewport,
                userElements: current.userElements,
                dismissedSids: current.dismissedSids,
                unreadSids: current.unreadSids,
                updatedAt: Date()
            )
            markTeamCanvasDirtyLocked(&store, canvasId: canvasId)
            store.layouts[canvasId] = next
            ensureMembershipsLocked(&store, canvasId: canvasId, sessionIds: Array(nextSessions.keys))
            try writeToDiskLocked(store)
            cached = store
            return next
        }
        SessionEventBus.shared.publish(.boardLayoutChanged)
        return merged
    }

    @discardableResult
    public func ensureDefaults(sessionIds: [String]) -> Snapshot {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            let before = store
            ensureDefaultCanvasesLocked(&store, sessionIds: sessionIds)
            if store != before {
                do {
                    try writeToDiskLocked(store)
                } catch {
                    MWarn("[BoardLayoutStore] failed to persist default canvases: \(error)")
                }
            }
            cached = store
            return snapshotLocked(store)
        }
    }

    public func snapshot() -> Snapshot {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            cached = store
            return snapshotLocked(store)
        }
    }

    public func workspacePath(canvasId: String) throws -> String {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            guard store.canvases.contains(where: { $0.id == canvasId }),
                  visibleCanvasesLocked(store).contains(where: { $0.id == canvasId }) else {
                throw storeError("canvas not found: \(canvasId)")
            }
            let foldersBefore = store.canvases.map { $0.workspaceFolderName }
            ensureWorkspaceFolderNamesLocked(&store)
            let foldersAfter = store.canvases.map { $0.workspaceFolderName }
            let folder = store.canvases.first(where: { $0.id == canvasId })?.workspaceFolderName
                ?? workspaceFolderName(forName: "canvas", id: canvasId, existing: Set<String>())
            // Only persist if ensureWorkspaceFolderNamesLocked actually mutated
            // a folder name. Otherwise we re-write the full 1.9 MB JSON on a
            // read-style call — a hot loop (e.g. canvasEnvelope) used to fan
            // this out and rack up 23+ writes per HTTP response.
            if foldersBefore != foldersAfter {
                try writeToDiskLocked(store)
            }
            cached = store
            return workspaceRootURL().appendingPathComponent(folder, isDirectory: true).path
        }
    }

    /// Bulk variant of `workspacePath(canvasId:)` for use by code that needs
    /// the path for every canvas (e.g. `canvasEnvelope`). One `queue.sync`,
    /// one (conditional) disk write, instead of N.
    public func loadAllWorkspacePaths() -> [String: String] {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let foldersBefore = store.canvases.map { $0.workspaceFolderName }
            ensureWorkspaceFolderNamesLocked(&store)
            let foldersAfter = store.canvases.map { $0.workspaceFolderName }
            if foldersBefore != foldersAfter {
                try? writeToDiskLocked(store)
            }
            cached = store
            let root = workspaceRootURL()
            var out: [String: String] = [:]
            out.reserveCapacity(store.canvases.count)
            for canvas in store.canvases {
                let folder = canvas.workspaceFolderName
                    ?? workspaceFolderName(forName: "canvas", id: canvas.id, existing: Set<String>())
                out[canvas.id] = root.appendingPathComponent(folder, isDirectory: true).path
            }
            return out
        }
    }

    @discardableResult
    public func recordSpawnIntent(canvasId: String, cwd: String, command: String) throws -> SpawnIntent {
        try recordSpawnIntent(
            canvasId: canvasId,
            cwd: cwd,
            command: command,
            provider: nil,
            purpose: nil,
            initialPrompt: nil,
            layoutHint: nil
        )
    }

    @discardableResult
    public func recordSpawnIntent(
        canvasId: String,
        cwd: String,
        command: String,
        provider: String?,
        purpose: String?,
        initialPrompt: String?,
        layoutHint: Point?
    ) throws -> SpawnIntent {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            guard store.canvases.contains(where: { $0.id == canvasId }),
                  visibleCanvasesLocked(store).contains(where: { $0.id == canvasId }) else {
                throw storeError("canvas not found: \(canvasId)")
            }
            let normalizedCwd = (cwd as NSString).standardizingPath
            let cutoff = Date().addingTimeInterval(-10 * 60)
            var intents = (store.spawnIntents ?? []).filter { $0.createdAt >= cutoff }
            let intent = SpawnIntent(
                canvasId: canvasId,
                cwd: normalizedCwd,
                command: command,
                provider: provider,
                purpose: purpose,
                initialPrompt: initialPrompt,
                layoutHint: layoutHint,
                createdAt: Date()
            )
            intents.append(intent)
            store.spawnIntents = intents
            try writeToDiskLocked(store)
            cached = store
            return intent
        }
    }

    public func applySpawnIntents(sessionCwds: [String: String]) {
        let candidates = sessionCwds.map {
            SpawnCandidate(sessionId: $0.key, cwd: $0.value, provider: nil, startedAt: nil)
        }
        _ = applySpawnIntents(candidates: candidates)
    }

    @discardableResult
    public func applySpawnIntents(candidates rawCandidates: [SpawnCandidate]) -> [MatchedSpawnIntent] {
        queue.sync {
            var matched: [MatchedSpawnIntent] = []
            let candidates = rawCandidates.sorted {
                switch ($0.startedAt, $1.startedAt) {
                case let (lhs?, rhs?):
                    if lhs != rhs { return lhs < rhs }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return $0.sessionId < $1.sessionId
            }
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let cutoff = Date().addingTimeInterval(-10 * 60)
            let intents = (store.spawnIntents ?? [])
                .filter { $0.createdAt >= cutoff }
                .sorted { $0.createdAt < $1.createdAt }
            var changed = intents.count != (store.spawnIntents ?? []).count
            guard !intents.isEmpty else {
                if changed {
                    store.spawnIntents = intents
                    try? writeToDiskLocked(store)
                    cached = store
                }
                return []
            }

            var homeCanvasIds = store.sessionHomeCanvasIds ?? [:]
            var consumedSessionIds = Set<String>()
            for intent in intents {
                let intentCwd = (intent.cwd as NSString).standardizingPath
                guard !intentCwd.isEmpty,
                      store.canvases.contains(where: { $0.id == intent.canvasId }) else {
                    continue
                }
                guard let candidate = candidates.first(where: { candidate in
                    if consumedSessionIds.contains(candidate.sessionId) { return false }
                    if homeCanvasIds[candidate.sessionId] != nil { return false }
                    let cwd = (candidate.cwd as NSString).standardizingPath
                    if cwd != intentCwd { return false }
                    if let provider = intent.provider?.lowercased(),
                       let candidateProvider = candidate.provider?.lowercased(),
                       !candidateProvider.contains(provider) {
                        return false
                    }
                    if let startedAt = candidate.startedAt,
                       startedAt < intent.createdAt.addingTimeInterval(-2) {
                        return false
                    }
                    return true
                }) else {
                    continue
                }

                consumedSessionIds.insert(candidate.sessionId)
                ensureMembershipsLocked(&store, canvasId: intent.canvasId, sessionIds: [candidate.sessionId])
                homeCanvasIds[candidate.sessionId] = intent.canvasId
                if let layoutHint = intent.layoutHint {
                    var layout = store.layouts[intent.canvasId] ?? .empty
                    layout.sessions[candidate.sessionId] = layoutHint
                    layout.dismissedSids.removeAll { $0 == candidate.sessionId }
                    layout.updatedAt = Date()
                    store.layouts[intent.canvasId] = layout
                }
                for canvas in store.canvases where canvas.isDefault && canvas.id != intent.canvasId {
                    store.memberships[canvas.id]?[candidate.sessionId] = nil
                    if var layout = store.layouts[canvas.id] {
                        layout.sessions.removeValue(forKey: candidate.sessionId)
                        layout.dismissedSids.removeAll { $0 == candidate.sessionId }
                        layout.updatedAt = Date()
                        store.layouts[canvas.id] = layout
                    }
                }
                matched.append(MatchedSpawnIntent(sessionId: candidate.sessionId, intent: intent))
                CoordinationStore.shared.bindCoordinator(spawnIntentId: intent.id, sessionId: candidate.sessionId)
                changed = true
            }

            if changed {
                let matchedIntentIds = Set(matched.map { $0.intent.id })
                store.spawnIntents = intents.filter { !matchedIntentIds.contains($0.id) }
                store.sessionHomeCanvasIds = homeCanvasIds
                do {
                    try writeToDiskLocked(store)
                } catch {
                    MWarn("[BoardLayoutStore] failed to persist spawn intents: \(error)")
                }
                cached = store
                SessionEventBus.shared.publish(.boardLayoutChanged)
            }
            return matched
        }
    }

    private func applySpawnIntentsLegacy(sessionCwds: [String: String]) {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let cutoff = Date().addingTimeInterval(-10 * 60)
            var intents = (store.spawnIntents ?? []).filter { $0.createdAt >= cutoff }
            var changed = intents.count != (store.spawnIntents ?? []).count
            guard !intents.isEmpty else {
                if changed {
                    store.spawnIntents = intents
                    try? writeToDiskLocked(store)
                    cached = store
                }
                return
            }

            var homeCanvasIds = store.sessionHomeCanvasIds ?? [:]
            for (sessionId, rawCwd) in sessionCwds {
                let cwd = (rawCwd as NSString).standardizingPath
                guard !cwd.isEmpty,
                      let idx = intents.firstIndex(where: { $0.cwd == cwd }),
                      store.canvases.contains(where: { $0.id == intents[idx].canvasId }) else {
                    continue
                }
                let intent = intents.remove(at: idx)
                ensureMembershipsLocked(&store, canvasId: intent.canvasId, sessionIds: [sessionId])
                homeCanvasIds[sessionId] = intent.canvasId
                for canvas in store.canvases where canvas.isDefault && canvas.id != intent.canvasId {
                    store.memberships[canvas.id]?[sessionId] = nil
                    if var layout = store.layouts[canvas.id] {
                        layout.sessions.removeValue(forKey: sessionId)
                        layout.dismissedSids.removeAll { $0 == sessionId }
                        layout.updatedAt = Date()
                        store.layouts[canvas.id] = layout
                    }
                }
                changed = true
            }

            if changed {
                store.spawnIntents = intents
                store.sessionHomeCanvasIds = homeCanvasIds
                do {
                    try writeToDiskLocked(store)
                } catch {
                    MWarn("[BoardLayoutStore] failed to persist spawn intents: \(error)")
                }
                cached = store
                SessionEventBus.shared.publish(.boardLayoutChanged)
            }
        }
    }

    @discardableResult
    public func createCanvas(name rawName: String, scope: CanvasScope, kind: CanvasKind = .board) throws -> Snapshot {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw storeError("canvas name is required")
        }
        return try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let context = currentContext()
            if scope == .team && context.teamId.isEmpty {
                throw storeError("team canvas requires meee2 Online connection")
            }
            let now = Date()
            let id = UUID().uuidString.lowercased()
            let canvas = Canvas(
                id: id,
                name: name,
                scope: scope,
                kind: kind,
                ownerUserId: scope == .personal ? context.userId : nil,
                teamId: scope == .team ? context.teamId : nil,
                isDefault: false,
                workspaceFolderName: nil,
                createdBy: context.userId,
                remoteId: scope == .team ? id : nil,
                remoteVersion: scope == .team ? 0 : nil,
                dirtySince: scope == .team ? now : nil,
                syncStatus: scope == .team ? "pending" : nil,
                createdAt: now,
                updatedAt: now
            )
            store.canvases.append(canvas)
            store.layouts[canvas.id] = .empty
            store.memberships[canvas.id] = [:]
            store.activeCanvasId = canvas.id
            try writeToDiskLocked(store)
            cached = store
            if scope == .team {
                Meee2OnlinePusher.shared.refreshActivation()
            }
            SessionEventBus.shared.publish(.boardLayoutChanged)
            return snapshotLocked(store)
        }
    }

    @discardableResult
    public func updateCanvas(id: String, name rawName: String?, active: Bool?) throws -> Snapshot {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            guard let idx = store.canvases.firstIndex(where: { $0.id == id }) else {
                throw storeError("canvas not found: \(id)")
            }
            guard visibleCanvasesLocked(store).contains(where: { $0.id == id }) else {
                throw storeError("canvas not accessible: \(id)")
            }
            if let rawName {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw storeError("canvas name is required") }
                store.canvases[idx].name = name
                store.canvases[idx].updatedAt = Date()
                markTeamCanvasDirtyLocked(&store, canvasId: id)
            }
            if active == true {
                store.activeCanvasId = id
            }
            try writeToDiskLocked(store)
            cached = store
            if store.canvases.first(where: { $0.id == id })?.scope == .team {
                Meee2OnlinePusher.shared.refreshActivation()
            }
            SessionEventBus.shared.publish(.boardLayoutChanged)
            return snapshotLocked(store)
        }
    }

    @discardableResult
    public func deleteCanvas(id: String) throws -> Snapshot {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            guard let canvas = store.canvases.first(where: { $0.id == id }) else {
                throw storeError("canvas not found: \(id)")
            }
            guard visibleCanvasesLocked(store).contains(where: { $0.id == id }) else {
                throw storeError("canvas not accessible: \(id)")
            }
            guard !canvas.isDefault else {
                throw storeError("default canvas cannot be deleted")
            }
            if canvas.scope == .team, let remoteId = canvas.remoteId, let teamId = canvas.teamId {
                var deleted = store.deletedTeamCanvases ?? []
                deleted.removeAll { $0.remoteId == remoteId }
                deleted.append(DeletedCanvas(
                    id: canvas.id,
                    remoteId: remoteId,
                    teamId: teamId,
                    baseVersion: canvas.remoteVersion ?? 0,
                    deletedAt: Date()
                ))
                store.deletedTeamCanvases = deleted
            }
            store.canvases.removeAll { $0.id == id }
            store.layouts.removeValue(forKey: id)
            store.memberships.removeValue(forKey: id)
            store.spawnIntents = (store.spawnIntents ?? []).filter { $0.canvasId != id }
            store.sessionHomeCanvasIds = (store.sessionHomeCanvasIds ?? [:]).filter { $0.value != id }
            if store.activeCanvasId == id {
                store.activeCanvasId = defaultCanvasIdLocked(store, scope: .personal) ?? store.canvases.first?.id
            }
            try writeToDiskLocked(store)
            cached = store
            SessionEventBus.shared.publish(.boardLayoutChanged)
            return snapshotLocked(store)
        }
    }

    @discardableResult
    public func addSession(_ sessionId: String, to canvasId: String) throws -> Snapshot {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            guard store.canvases.contains(where: { $0.id == canvasId }),
                  visibleCanvasesLocked(store).contains(where: { $0.id == canvasId }) else {
                throw storeError("canvas not found: \(canvasId)")
            }
            try validateTeamCanvasSessionLocked(store, canvasId: canvasId, sessionId: sessionId)
            ensureMembershipsLocked(&store, canvasId: canvasId, sessionIds: [sessionId])
            markTeamCanvasDirtyLocked(&store, canvasId: canvasId)
            var layout = store.layouts[canvasId] ?? .empty
            layout.dismissedSids.removeAll { $0 == sessionId }
            store.layouts[canvasId] = layout
            try writeToDiskLocked(store)
            cached = store
            SessionEventBus.shared.publish(.boardLayoutChanged)
            return snapshotLocked(store)
        }
    }

    @discardableResult
    public func removeSession(_ sessionId: String, from canvasId: String) throws -> Snapshot {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            guard store.canvases.contains(where: { $0.id == canvasId }),
                  visibleCanvasesLocked(store).contains(where: { $0.id == canvasId }) else {
                throw storeError("canvas not found: \(canvasId)")
            }
            store.memberships[canvasId]?[sessionId] = nil
            markTeamCanvasDirtyLocked(&store, canvasId: canvasId)
            var homeCanvasIds = store.sessionHomeCanvasIds ?? [:]
            homeCanvasIds[sessionId] = homeCanvasIds[sessionId] ?? canvasId
            store.sessionHomeCanvasIds = homeCanvasIds
            var layout = store.layouts[canvasId] ?? .empty
            layout.sessions.removeValue(forKey: sessionId)
            layout.dismissedSids.removeAll { $0 == sessionId }
            store.layouts[canvasId] = layout
            try writeToDiskLocked(store)
            cached = store
            SessionEventBus.shared.publish(.boardLayoutChanged)
            return snapshotLocked(store)
        }
    }

    public func dirtyTeamCanvasPayloads() -> [[String: Any]] {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let context = currentContext()
            guard !context.teamId.isEmpty else { return [] }
            var storeChanged = false
            let now = Date()

            for idx in store.canvases.indices {
                let canvas = store.canvases[idx]
                guard canvas.scope == .team,
                      canvas.teamId == context.teamId else {
                    continue
                }
                let memberships = store.memberships[canvas.id] ?? [:]
                let invalidSessionIds = memberships.compactMap { sessionId, membership -> String? in
                    guard membership.visible else { return nil }
                    return canSessionJoinTeamCanvas(canvasTeamId: context.teamId, sessionId: sessionId) ? nil : sessionId
                }
                guard !invalidSessionIds.isEmpty else { continue }

                var nextMemberships = memberships
                for sessionId in invalidSessionIds {
                    nextMemberships.removeValue(forKey: sessionId)
                }
                store.memberships[canvas.id] = nextMemberships
                if var layout = store.layouts[canvas.id] {
                    for sessionId in invalidSessionIds {
                        layout.sessions.removeValue(forKey: sessionId)
                        layout.dismissedSids.removeAll { $0 == sessionId }
                        layout.unreadSids.removeAll { $0 == sessionId }
                    }
                    store.layouts[canvas.id] = layout
                }
                store.canvases[idx].dirtySince = store.canvases[idx].dirtySince ?? now
                if store.canvases[idx].syncStatus != "conflict" {
                    store.canvases[idx].syncStatus = "pending"
                }
                store.canvases[idx].updatedAt = now
                storeChanged = true
            }

            if storeChanged {
                do {
                    try writeToDiskLocked(store)
                    cached = store
                } catch {
                    MWarn("[BoardLayoutStore] failed to prune unsynced team canvas sessions: \(error)")
                }
            }

            var out: [[String: Any]] = []

            for canvas in store.canvases where canvas.scope == .team && canvas.teamId == context.teamId {
                guard canvas.dirtySince != nil else { continue }
                let force = canvas.syncStatus == "force-pending"
                if canvas.syncStatus == "conflict" && !force { continue }
                let memberships = Array((store.memberships[canvas.id] ?? [:]).values)
                    .filter(\.visible)
                    .sorted { $0.sessionId < $1.sessionId }
                let layout = store.layouts[canvas.id] ?? .empty
                out.append([
                    "id": canvas.remoteId ?? canvas.id,
                    "localId": canvas.id,
                    "name": canvas.name,
                    "baseVersion": canvas.remoteVersion ?? 0,
                    "force": force,
                    "deleted": false,
                    "sessionKeys": memberships.map(\.sessionId),
                    "state": [
                        "kind": (canvas.kind ?? .board).rawValue,
                        "ownerUserId": canvas.ownerUserId ?? canvas.createdBy ?? "",
                        "layout": jsonObject(layout) ?? [:],
                        "memberships": jsonObject(memberships) ?? []
                    ]
                ])
            }

            for tombstone in store.deletedTeamCanvases ?? [] where tombstone.teamId == context.teamId {
                out.append([
                    "id": tombstone.remoteId,
                    "localId": tombstone.id,
                    "name": "",
                    "baseVersion": tombstone.baseVersion,
                    "force": false,
                    "deleted": true,
                    "sessionKeys": [],
                    "state": [:]
                ])
            }
            return out
        }
    }

    public func markTeamCanvasSyncResults(_ results: [[String: Any]]) {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            var changed = false
            for result in results {
                let status = (result["status"] as? String) ?? ""
                let remoteId = (result["remote_id"] as? String)
                    ?? (result["remoteId"] as? String)
                    ?? (result["id"] as? String)
                    ?? ""
                guard !remoteId.isEmpty else { continue }
                if status == "deleted" {
                    let before = store.deletedTeamCanvases?.count ?? 0
                    store.deletedTeamCanvases = (store.deletedTeamCanvases ?? []).filter { $0.remoteId != remoteId }
                    changed = changed || before != (store.deletedTeamCanvases?.count ?? 0)
                    continue
                }
                guard let idx = store.canvases.firstIndex(where: { ($0.remoteId ?? $0.id) == remoteId }) else {
                    continue
                }
                if status == "ok" {
                    let now = Date()
                    store.canvases[idx].remoteId = remoteId
                    store.canvases[idx].remoteVersion = intValue(result["version"]) ?? store.canvases[idx].remoteVersion
                    store.canvases[idx].dirtySince = nil
                    store.canvases[idx].syncStatus = "synced"
                    store.canvases[idx].lastSyncedAt = now
                    store.canvases[idx].lastRemoteUpdatedAt = dateValue(result["updated_at"]) ?? now
                    store.canvases[idx].conflictRemoteVersion = nil
                    store.canvases[idx].conflictRemoteState = nil
                    store.canvases[idx].conflictRemoteDeleted = nil
                    changed = true
                } else if status == "conflict" {
                    store.canvases[idx].syncStatus = "conflict"
                    store.canvases[idx].conflictRemoteVersion = intValue(result["version"])
                    if let state = result["state"], let value = BoardJSONValue.fromAny(state) {
                        store.canvases[idx].conflictRemoteState = value
                    }
                    store.canvases[idx].conflictRemoteDeleted = false
                    changed = true
                }
            }
            if changed {
                do {
                    try writeToDiskLocked(store)
                    cached = store
                } catch {
                    MWarn("[BoardLayoutStore] failed to persist sync results: \(error)")
                }
                SessionEventBus.shared.publish(.boardLayoutChanged)
            }
        }
    }

    public func applyRemoteTeamCanvases(_ remoteCanvases: [RemoteTeamCanvas]) {
        queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            let context = currentContext()
            guard !context.teamId.isEmpty else { return }
            var changed = false
            let now = Date()

            for remote in remoteCanvases where remote.teamId == context.teamId {
                if let idx = store.canvases.firstIndex(where: { ($0.remoteId ?? $0.id) == remote.id }) {
                    let local = store.canvases[idx]
                    let localVersion = local.remoteVersion ?? 0
                    if remote.deletedAt != nil {
                        if local.dirtySince != nil && remote.version > localVersion {
                            store.canvases[idx].syncStatus = "conflict"
                            store.canvases[idx].conflictRemoteVersion = remote.version
                            store.canvases[idx].conflictRemoteState = BoardJSONValue.fromAny(remote.state)
                            store.canvases[idx].conflictRemoteDeleted = true
                            store.canvases[idx].lastRemoteUpdatedAt = remote.updatedAt
                            changed = true
                        } else if local.dirtySince == nil && remote.version > localVersion {
                            removeCanvasLocked(&store, canvasId: local.id)
                            changed = true
                        }
                        continue
                    }
                    if local.dirtySince != nil && remote.version > localVersion {
                        store.canvases[idx].syncStatus = "conflict"
                        store.canvases[idx].conflictRemoteVersion = remote.version
                        store.canvases[idx].conflictRemoteState = BoardJSONValue.fromAny(remote.state)
                        store.canvases[idx].conflictRemoteDeleted = false
                        store.canvases[idx].lastRemoteUpdatedAt = remote.updatedAt
                        changed = true
                    } else if local.dirtySince == nil && remote.version > localVersion {
                        applyRemoteStateLocked(&store, canvasId: local.id, remote: remote, now: now)
                        changed = true
                    }
                } else if remote.deletedAt == nil, let state = BoardJSONValue.fromAny(remote.state) {
                    let canvas = Canvas(
                        id: remote.id,
                        name: remote.name,
                        scope: .team,
                        kind: parsedCanvasKind(from: remote.state) ?? .board,
                        ownerUserId: remote.state["ownerUserId"] as? String,
                        teamId: remote.teamId,
                        isDefault: false,
                        workspaceFolderName: nil,
                        createdBy: nil,
                        remoteId: remote.id,
                        remoteVersion: remote.version,
                        lastSyncedAt: now,
                        dirtySince: nil,
                        syncStatus: "synced",
                        lastRemoteUpdatedAt: remote.updatedAt,
                        createdAt: remote.updatedAt ?? now,
                        updatedAt: remote.updatedAt ?? now
                    )
                    store.canvases.append(canvas)
                    applyRemoteStateValueLocked(&store, canvasId: remote.id, state: state, remote: remote, now: now)
                    changed = true
                }
            }

            if changed {
                do {
                    try writeToDiskLocked(store)
                    cached = store
                } catch {
                    MWarn("[BoardLayoutStore] failed to persist remote canvases: \(error)")
                }
                SessionEventBus.shared.publish(.boardLayoutChanged)
            }
        }
    }

    public func resolveTeamCanvasConflict(canvasId: String, useRemote: Bool) throws -> Snapshot {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            ensureDefaultCanvasesLocked(&store, sessionIds: [])
            guard let idx = store.canvases.firstIndex(where: { $0.id == canvasId }) else {
                throw storeError("canvas not found: \(canvasId)")
            }
            guard store.canvases[idx].syncStatus == "conflict" else {
                throw storeError("canvas is not in conflict: \(canvasId)")
            }
            if useRemote {
                if store.canvases[idx].conflictRemoteDeleted == true {
                    removeCanvasLocked(&store, canvasId: canvasId)
                    try writeToDiskLocked(store)
                    cached = store
                    SessionEventBus.shared.publish(.boardLayoutChanged)
                    return snapshotLocked(store)
                }
                guard let state = store.canvases[idx].conflictRemoteState else {
                    throw storeError("remote conflict state is missing")
                }
                let remote = RemoteTeamCanvas(
                    id: store.canvases[idx].remoteId ?? store.canvases[idx].id,
                    name: store.canvases[idx].name,
                    teamId: store.canvases[idx].teamId ?? "",
                    version: store.canvases[idx].conflictRemoteVersion ?? store.canvases[idx].remoteVersion ?? 0,
                    state: anyObject(state) as? [String: Any] ?? [:],
                    updatedAt: store.canvases[idx].lastRemoteUpdatedAt
                )
                applyRemoteStateValueLocked(&store, canvasId: canvasId, state: state, remote: remote, now: Date())
            } else {
                store.canvases[idx].syncStatus = "force-pending"
                store.canvases[idx].dirtySince = store.canvases[idx].dirtySince ?? Date()
                store.canvases[idx].conflictRemoteState = nil
                store.canvases[idx].conflictRemoteVersion = nil
                store.canvases[idx].conflictRemoteDeleted = nil
            }
            try writeToDiskLocked(store)
            cached = store
            SessionEventBus.shared.publish(.boardLayoutChanged)
            return snapshotLocked(store)
        }
    }

    // MARK: - Disk I/O（must be called inside `queue`）

    private func loadFromDiskLocked() -> StoreData {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(StoreData.self, from: data)
        } catch {
            MWarn("[BoardLayoutStore] failed to decode \(fileURL.path): \(error); starting empty")
            return .empty
        }
    }

    private func writeToDiskLocked(_ store: StoreData) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        // 原子写：先写 .tmp.<pid>，再用 replaceItemAt（背后是 POSIX rename(2)，
        // 同一文件系统下原子；旧版本是 remove + move，崩在中间会只剩 .tmp.<pid>，
        // 而正式文件不存在）。
        let pid = ProcessInfo.processInfo.processIdentifier
        let tmp = fileURL.appendingPathExtension("tmp.\(pid)")
        try? fileManager.removeItem(at: tmp)
        try data.write(to: tmp, options: [.atomic])
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            // 文件还不存在：replaceItemAt 在原 URL 不存在时会抛错；走 moveItem。
            try fileManager.moveItem(at: tmp, to: fileURL)
        }
    }

    private func snapshotLocked(_ store: StoreData) -> Snapshot {
        let active = resolveCanvasIdLocked(store, store.activeCanvasId)
        let visibleCanvases = visibleCanvasesLocked(store)
        let visibleCanvasIds = Set(visibleCanvases.map { $0.id })
        let memberships = store.memberships
            .filter { visibleCanvasIds.contains($0.key) }
            .values
            .flatMap { $0.values }
        return Snapshot(activeCanvasId: active, canvases: visibleCanvases, memberships: memberships)
    }

    private func resolveCanvasIdLocked(_ store: StoreData, _ requested: String?) -> String {
        let visible = visibleCanvasesLocked(store)
        if let requested, visible.contains(where: { $0.id == requested }) {
            return requested
        }
        if let active = store.activeCanvasId, visible.contains(where: { $0.id == active }) {
            return active
        }
        return visible.first(where: { $0.scope == .personal && $0.isDefault })?.id
            ?? visible.first?.id
            ?? "personal-default"
    }

    private func visibleCanvasesLocked(_ store: StoreData) -> [Canvas] {
        let context = currentContext()
        return store.canvases.filter { canvas in
            switch canvas.scope {
            case .personal:
                return true
            case .team:
                return !context.teamId.isEmpty && canvas.teamId == context.teamId
            }
        }
    }

    private func ensureWorkspaceFolderNamesLocked(_ store: inout StoreData) {
        var existing = Set(store.canvases.compactMap { $0.workspaceFolderName }.filter { !$0.isEmpty })
        for idx in store.canvases.indices {
            if let folder = store.canvases[idx].workspaceFolderName, !folder.isEmpty {
                continue
            }
            let folder = workspaceFolderName(forName: store.canvases[idx].name, id: store.canvases[idx].id, existing: existing)
            store.canvases[idx].workspaceFolderName = folder
            existing.insert(folder)
        }
    }

    private func workspaceFolderName(forName name: String, id: String, existing: Set<String>) -> String {
        let slug = slugify(name).isEmpty ? "canvas" : slugify(name)
        let shortId = String(id.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let suffix = shortId.isEmpty ? "local" : shortId
        let base = "\(slug)-\(suffix)"
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    private func slugify(_ raw: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in raw.lowercased().unicodeScalars {
            let isAlphaNum = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
            if isAlphaNum {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func workspaceRootURL() -> URL {
        MEEE2Env.home
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("global", isDirectory: true)
    }

    private func defaultCanvasIdLocked(_ store: StoreData, scope: CanvasScope) -> String? {
        store.canvases.first(where: { $0.scope == scope && $0.isDefault })?.id
    }

    private func ensureDefaultCanvasesLocked(_ store: inout StoreData, sessionIds: [String]) {
        let context = currentContext()
        let now = Date()
        let personalId = "personal-default"
        let removedTeamDefaultIds = store.canvases
            .filter { $0.scope == .team && $0.isDefault }
            .map(\.id)
        if !removedTeamDefaultIds.isEmpty {
            let removed = Set(removedTeamDefaultIds)
            store.canvases.removeAll { removed.contains($0.id) }
            for canvasId in removed {
                store.layouts.removeValue(forKey: canvasId)
                store.memberships.removeValue(forKey: canvasId)
            }
            if removed.contains(store.activeCanvasId ?? "") {
                store.activeCanvasId = personalId
            }
            if var homeCanvasIds = store.sessionHomeCanvasIds {
                let sessionIdsToClear = homeCanvasIds.compactMap { sessionId, canvasId in
                    removed.contains(canvasId) ? sessionId : nil
                }
                for sessionId in sessionIdsToClear {
                    homeCanvasIds.removeValue(forKey: sessionId)
                }
                store.sessionHomeCanvasIds = homeCanvasIds
            }
        }
        if !store.canvases.contains(where: { $0.id == personalId }) {
            store.canvases.append(Canvas(
                id: personalId,
                name: "Monitor",
                scope: .personal,
                kind: .monitor,
                ownerUserId: context.userId,
                teamId: nil,
                isDefault: true,
                workspaceFolderName: nil,
                createdBy: context.userId,
                createdAt: now,
                updatedAt: now
            ))
            store.layouts[personalId] = store.layouts[personalId] ?? .empty
            store.memberships[personalId] = store.memberships[personalId] ?? [:]
        } else if let index = store.canvases.firstIndex(where: { $0.id == personalId }),
                  store.canvases[index].isDefault,
                  store.canvases[index].kind != .monitor || store.canvases[index].name == "Default canvas" {
            store.canvases[index].kind = .monitor
            if store.canvases[index].name == "Default canvas" {
                store.canvases[index].name = "Monitor"
            }
            store.canvases[index].updatedAt = now
        }
        ensureWorkspaceFolderNamesLocked(&store)
        let defaultSessionIds = sessionIds.filter { (store.sessionHomeCanvasIds ?? [:])[$0] == nil }
        ensureMembershipsLocked(&store, canvasId: personalId, sessionIds: defaultSessionIds)

        let visible = visibleCanvasesLocked(store)
        if store.activeCanvasId == nil
            || !visible.contains(where: { $0.id == (store.activeCanvasId ?? "") }) {
            store.activeCanvasId = personalId
        }
    }

    private func ensureMembershipsLocked(_ store: inout StoreData, canvasId: String, sessionIds: [String]) {
        guard !sessionIds.isEmpty else {
            store.memberships[canvasId] = store.memberships[canvasId] ?? [:]
            return
        }
        var bySession = store.memberships[canvasId] ?? [:]
        let now = Date()
        let actor = currentContext().userId
        for sessionId in sessionIds {
            if var existing = bySession[sessionId] {
                if !existing.visible {
                    existing.visible = true
                    existing.updatedAt = now
                    bySession[sessionId] = existing
                }
            } else {
                bySession[sessionId] = CanvasSession(
                    canvasId: canvasId,
                    sessionId: sessionId,
                    visible: true,
                    addedBy: actor,
                    addedAt: now,
                    updatedAt: now
                )
            }
        }
        store.memberships[canvasId] = bySession
    }

    private func validateTeamCanvasSessionLocked(_ store: StoreData, canvasId: String, sessionId: String) throws {
        guard let canvas = store.canvases.first(where: { $0.id == canvasId }),
              canvas.scope == .team else {
            return
        }
        guard let teamId = canvas.teamId, canSessionJoinTeamCanvas(canvasTeamId: teamId, sessionId: sessionId) else {
            throw storeError("sync this session to the team before adding it to a team canvas")
        }
    }

    private func canSessionJoinTeamCanvas(canvasTeamId: String, sessionId: String) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "meee2Connected"), !canvasTeamId.isEmpty else {
            return false
        }

        let aliases = Meee2OnlinePusher.sessionIdAliases(sessionId)
        let disabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds")
        if !aliases.isDisjoint(with: disabled) {
            return false
        }

        let enabledByDefault = defaults.bool(forKey: "meee2Online")
        let explicitlyEnabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds")
        guard enabledByDefault || !aliases.isDisjoint(with: explicitlyEnabled) else {
            return false
        }

        let sessionTeamIds = Meee2OnlinePusher.sessionIdMap(forKey: "meee2SessionTeamIds")
        let targetTeamId = aliases.compactMap { sessionTeamIds[$0] }.first { !$0.isEmpty }
            ?? defaults.string(forKey: "meee2TeamId")
            ?? ""
        guard targetTeamId == canvasTeamId else {
            return false
        }

        return isCurrentlySyncableSession(sessionId)
    }

    private func isCurrentlySyncableSession(_ sessionId: String) -> Bool {
        let aliases = Meee2OnlinePusher.sessionIdAliases(sessionId)
        if SessionStore.shared.listActive().contains(where: { session in
            !aliases.isDisjoint(with: Meee2OnlinePusher.sessionIdAliases(session.sessionId))
        }) {
            return true
        }
        return PluginManager.shared.sessions.contains { session in
            guard !session.status.isHistorical else { return false }
            return !aliases.isDisjoint(with: Meee2OnlinePusher.sessionIdAliases(session.id))
        }
    }

    private func removeCanvasLocked(_ store: inout StoreData, canvasId: String) {
        store.canvases.removeAll { $0.id == canvasId }
        store.layouts.removeValue(forKey: canvasId)
        store.memberships.removeValue(forKey: canvasId)
        store.spawnIntents = (store.spawnIntents ?? []).filter { $0.canvasId != canvasId }
        store.sessionHomeCanvasIds = (store.sessionHomeCanvasIds ?? [:]).filter { $0.value != canvasId }
        if store.activeCanvasId == canvasId {
            store.activeCanvasId = defaultCanvasIdLocked(store, scope: .personal) ?? store.canvases.first?.id
        }
    }

    private func markTeamCanvasDirtyLocked(_ store: inout StoreData, canvasId: String) {
        guard let idx = store.canvases.firstIndex(where: { $0.id == canvasId }),
              store.canvases[idx].scope == .team else {
            return
        }
        let now = Date()
        store.canvases[idx].dirtySince = store.canvases[idx].dirtySince ?? now
        if store.canvases[idx].syncStatus != "conflict" {
            store.canvases[idx].syncStatus = "pending"
        }
        store.canvases[idx].updatedAt = now
        if store.canvases[idx].remoteId == nil {
            store.canvases[idx].remoteId = store.canvases[idx].id
            store.canvases[idx].remoteVersion = store.canvases[idx].remoteVersion ?? 0
        }
    }

    private func applyRemoteStateLocked(_ store: inout StoreData, canvasId: String, remote: RemoteTeamCanvas, now: Date) {
        guard let state = BoardJSONValue.fromAny(remote.state) else { return }
        applyRemoteStateValueLocked(&store, canvasId: canvasId, state: state, remote: remote, now: now)
    }

    private func applyRemoteStateValueLocked(
        _ store: inout StoreData,
        canvasId: String,
        state: BoardJSONValue,
        remote: RemoteTeamCanvas,
        now: Date
    ) {
        if let idx = store.canvases.firstIndex(where: { $0.id == canvasId }) {
            store.canvases[idx].name = remote.name
            store.canvases[idx].remoteId = remote.id
            store.canvases[idx].remoteVersion = remote.version
            store.canvases[idx].dirtySince = nil
            store.canvases[idx].syncStatus = "synced"
            store.canvases[idx].lastSyncedAt = now
            store.canvases[idx].lastRemoteUpdatedAt = remote.updatedAt
            store.canvases[idx].conflictRemoteState = nil
            store.canvases[idx].conflictRemoteVersion = nil
            store.canvases[idx].conflictRemoteDeleted = nil
            store.canvases[idx].updatedAt = remote.updatedAt ?? now
        }
        guard let object = anyObject(state) as? [String: Any] else { return }
        if let parsedKind = parsedCanvasKind(from: object),
           let idx = store.canvases.firstIndex(where: { $0.id == canvasId }) {
            store.canvases[idx].kind = parsedKind
        }
        if let ownerUserId = object["ownerUserId"] as? String,
           let idx = store.canvases.firstIndex(where: { $0.id == canvasId }) {
            store.canvases[idx].ownerUserId = ownerUserId.isEmpty ? nil : ownerUserId
        }
        if let rawLayout = object["layout"],
           let layout = decodeJSON(Layout.self, from: rawLayout) {
            store.layouts[canvasId] = layout
        } else {
            store.layouts[canvasId] = store.layouts[canvasId] ?? .empty
        }
        if let rawMemberships = object["memberships"],
           let memberships = decodeJSON([CanvasSession].self, from: rawMemberships) {
            store.memberships[canvasId] = Dictionary(uniqueKeysWithValues: memberships.map { ($0.sessionId, $0) })
        } else {
            store.memberships[canvasId] = store.memberships[canvasId] ?? [:]
        }
    }

    private func parsedCanvasKind(from object: [String: Any]) -> CanvasKind? {
        guard let rawKind = object["kind"] as? String else { return .board }
        return CanvasKind(rawValue: rawKind)
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from raw: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func anyObject(_ value: BoardJSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .number(let number):
            return number
        case .string(let string):
            return string
        case .array(let values):
            return values.map(anyObject)
        case .object(let values):
            return values.mapValues(anyObject)
        }
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private func dateValue(_ raw: Any?) -> Date? {
        guard let value = raw as? String else { return nil }
        return BoardDTOBuilder.iso8601.date(from: value)
    }

    private func currentContext() -> (userId: String, teamId: String) {
        let defaults = UserDefaults.standard
        let connected = defaults.bool(forKey: "meee2Connected")
        let userId = connected
            ? (defaults.string(forKey: "meee2UserId")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        let teamId = connected
            ? (defaults.string(forKey: "meee2TeamId")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        return (userId.isEmpty ? "local-user" : userId, teamId)
    }

    private func storeError(_ message: String) -> NSError {
        NSError(domain: "BoardLayoutStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

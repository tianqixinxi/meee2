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

    public struct Point: Codable, Equatable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
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
        public var ownerUserId: String?
        public var teamId: String?
        public var isDefault: Bool
        public var workspaceFolderName: String?
        public var createdBy: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String,
            name: String,
            scope: CanvasScope,
            ownerUserId: String?,
            teamId: String?,
            isDefault: Bool,
            workspaceFolderName: String? = nil,
            createdBy: String?,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.name = name
            self.scope = scope
            self.ownerUserId = ownerUserId
            self.teamId = teamId
            self.isDefault = isDefault
            self.workspaceFolderName = workspaceFolderName
            self.createdBy = createdBy
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct SpawnIntent: Codable, Equatable {
        public var canvasId: String
        public var cwd: String
        public var command: String
        public var createdAt: Date
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

    private struct StoreData: Codable, Equatable {
        var activeCanvasId: String?
        var canvases: [Canvas]
        var layouts: [String: Layout]
        var memberships: [String: [String: CanvasSession]]
        var spawnIntents: [SpawnIntent]?
        var sessionHomeCanvasIds: [String: String]?

        static let empty = StoreData(
            activeCanvasId: nil,
            canvases: [],
            layouts: [:],
            memberships: [:],
            spawnIntents: nil,
            sessionHomeCanvasIds: nil
        )
    }

    private let fileManager = FileManager.default
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.meee2.BoardLayoutStore", qos: .utility)
    private var cached: StoreData?

    private init() {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            MWarn("[BoardLayoutStore] failed to create dir \(dir.path): \(error)")
        }
        self.fileURL = dir.appendingPathComponent("board-canvases.json")
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
            ensureDefaultCanvasesLocked(&store, sessionIds: sessionIds)
            do {
                try writeToDiskLocked(store)
            } catch {
                MWarn("[BoardLayoutStore] failed to persist default canvases: \(error)")
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
            ensureWorkspaceFolderNamesLocked(&store)
            let folder = store.canvases.first(where: { $0.id == canvasId })?.workspaceFolderName
                ?? workspaceFolderName(forName: "canvas", id: canvasId, existing: Set<String>())
            try writeToDiskLocked(store)
            cached = store
            return workspaceRootURL().appendingPathComponent(folder, isDirectory: true).path
        }
    }

    public func recordSpawnIntent(canvasId: String, cwd: String, command: String) throws {
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
            intents.append(SpawnIntent(canvasId: canvasId, cwd: normalizedCwd, command: command, createdAt: Date()))
            store.spawnIntents = intents
            try writeToDiskLocked(store)
            cached = store
        }
    }

    public func applySpawnIntents(sessionCwds: [String: String]) {
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
    public func createCanvas(name rawName: String, scope: CanvasScope) throws -> Snapshot {
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
            let canvas = Canvas(
                id: UUID().uuidString.lowercased(),
                name: name,
                scope: scope,
                ownerUserId: scope == .personal ? context.userId : nil,
                teamId: scope == .team ? context.teamId : nil,
                isDefault: false,
                workspaceFolderName: nil,
                createdBy: context.userId,
                createdAt: now,
                updatedAt: now
            )
            store.canvases.append(canvas)
            store.layouts[canvas.id] = .empty
            store.memberships[canvas.id] = [:]
            store.activeCanvasId = canvas.id
            try writeToDiskLocked(store)
            cached = store
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
            }
            if active == true {
                store.activeCanvasId = id
            }
            try writeToDiskLocked(store)
            cached = store
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
            ensureMembershipsLocked(&store, canvasId: canvasId, sessionIds: [sessionId])
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
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2", isDirectory: true)
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
                name: "Default canvas",
                scope: .personal,
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
                existing.visible = true
                existing.updatedAt = now
                bySession[sessionId] = existing
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

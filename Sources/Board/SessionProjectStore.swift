import Foundation
import Meee2CommKit

public enum SessionProjectProvider: String, Codable {
    case claude
    case codex

    static func normalize(_ raw: String?) -> SessionProjectProvider {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.contains("codex") ? .codex : .claude
    }
}

public struct SessionProjectRecord: Codable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var preferredProvider: SessionProjectProvider
    public var explicit: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: String,
        name: String,
        path: String,
        preferredProvider: SessionProjectProvider,
        explicit: Bool,
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.preferredProvider = preferredProvider
        self.explicit = explicit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }
}

public final class SessionProjectStore {
    public static let shared = SessionProjectStore()

    private struct StoreData: Codable, Equatable {
        var projects: [SessionProjectRecord]

        static let empty = StoreData(projects: [])
    }

    private let queue = DispatchQueue(label: "com.meee2.SessionProjectStore", qos: .utility)
    private let fileURL: URL
    private var cached: StoreData?

    private init() {
        let dir = StorageRoots.processDefault.baseDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("session-projects.json")
    }

    init(fileURL: URL) {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.fileURL = fileURL
    }

    public func list() -> [SessionProjectRecord] {
        queue.sync {
            let store = cached ?? loadFromDiskLocked()
            cached = store
            return store.projects.sorted(by: Self.compareProjects)
        }
    }

    @discardableResult
    public func upsert(path rawPath: String, name rawName: String? = nil, preferredProvider rawProvider: String? = nil) throws -> SessionProjectRecord {
        let path = Self.normalizePath(rawPath)
        guard !path.isEmpty else {
            throw NSError(domain: "SessionProjectStore", code: 400, userInfo: [NSLocalizedDescriptionKey: "project path is required"])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "SessionProjectStore", code: 400, userInfo: [NSLocalizedDescriptionKey: "project path does not exist: \(path)"])
        }
        return try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            let now = Date()
            let name = normalizedName(rawName, fallbackPath: path)
            let provider = SessionProjectProvider.normalize(rawProvider)
            if let index = store.projects.firstIndex(where: { $0.path == path || $0.id == Self.id(forPath: path) }) {
                store.projects[index].name = name
                store.projects[index].path = path
                store.projects[index].preferredProvider = provider
                store.projects[index].explicit = true
                store.projects[index].updatedAt = now
                try writeToDiskLocked(store)
                cached = store
                return store.projects[index]
            }
            let record = SessionProjectRecord(
                id: Self.id(forPath: path),
                name: name,
                path: path,
                preferredProvider: provider,
                explicit: true,
                createdAt: now,
                updatedAt: now,
                lastUsedAt: nil
            )
            store.projects.append(record)
            try writeToDiskLocked(store)
            cached = store
            return record
        }
    }

    @discardableResult
    public func markUsed(projectId: String, path rawPath: String? = nil, provider rawProvider: String? = nil) throws -> SessionProjectRecord {
        let fallbackPath = rawPath.map(Self.normalizePath)
        return try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            let now = Date()
            let provider = SessionProjectProvider.normalize(rawProvider)
            if let index = store.projects.firstIndex(where: { $0.id == projectId || ($0.path == fallbackPath && fallbackPath?.isEmpty == false) }) {
                store.projects[index].preferredProvider = provider
                store.projects[index].lastUsedAt = now
                store.projects[index].updatedAt = now
                try writeToDiskLocked(store)
                cached = store
                return store.projects[index]
            }
            throw NSError(domain: "SessionProjectStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "project not found: \(projectId)"])
        }
    }

    @discardableResult
    public func rename(projectId: String, name rawName: String) throws -> SessionProjectRecord {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NSError(domain: "SessionProjectStore", code: 400, userInfo: [NSLocalizedDescriptionKey: "project name is required"])
        }
        return try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            guard let index = store.projects.firstIndex(where: { $0.id == projectId }) else {
                throw NSError(domain: "SessionProjectStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "project not found: \(projectId)"])
            }
            store.projects[index].name = name
            store.projects[index].updatedAt = Date()
            try writeToDiskLocked(store)
            cached = store
            return store.projects[index]
        }
    }

    public func forget(projectId: String) throws {
        try queue.sync {
            var store = cached ?? loadFromDiskLocked()
            let before = store.projects.count
            store.projects.removeAll { $0.id == projectId }
            guard store.projects.count != before else {
                throw NSError(domain: "SessionProjectStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "project not found: \(projectId)"])
            }
            try writeToDiskLocked(store)
            cached = store
        }
    }

    public static func normalizePath(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("~") {
            value = NSHomeDirectory() + String(value.dropFirst(1))
        }
        return (value as NSString).standardizingPath
    }

    public static func id(forPath path: String) -> String {
        "project-\(String(WyHash.hash(normalizePath(path)), radix: 16))"
    }

    public static func defaultName(forPath path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? path : last
    }

    private static func compareProjects(_ lhs: SessionProjectRecord, _ rhs: SessionProjectRecord) -> Bool {
        let lhsUsed = lhs.lastUsedAt ?? lhs.updatedAt
        let rhsUsed = rhs.lastUsedAt ?? rhs.updatedAt
        if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
        if lhs.explicit != rhs.explicit { return lhs.explicit && !rhs.explicit }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func normalizedName(_ raw: String?, fallbackPath: String) -> String {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? Self.defaultName(forPath: fallbackPath) : name
    }

    private func loadFromDiskLocked() -> StoreData {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(StoreData.self, from: data)) ?? .empty
    }

    private func writeToDiskLocked(_ store: StoreData) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try data.write(to: fileURL, options: .atomic)
    }
}

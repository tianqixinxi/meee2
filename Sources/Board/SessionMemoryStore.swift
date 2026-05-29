import Foundation

public struct SessionMemoryRecord: Codable {
    public var id: String
    public var scope: String
    public var subjectId: String
    public var kind: String
    public var content: String
    public var source: String
    public var evidenceRef: String?
    public var createdAt: Date
    public var updatedAt: Date
}

public final class SessionMemoryStore {
    public static let shared = SessionMemoryStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var records: [SessionMemoryRecord] = []

    private init() {
        let base = MEEE2Env.home.appendingPathComponent("memory", isDirectory: true)
        self.fileURL = base.appendingPathComponent("records.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    public func list(scope: String, subjectId: String) -> [SessionMemoryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
            .filter { $0.scope == scope && $0.subjectId == subjectId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func create(
        scope: String,
        subjectId: String,
        kind: String,
        content: String,
        source: String,
        evidenceRef: String?
    ) -> SessionMemoryRecord {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let record = SessionMemoryRecord(
            id: UUID().uuidString,
            scope: scope,
            subjectId: subjectId,
            kind: kind,
            content: content,
            source: source,
            evidenceRef: evidenceRef,
            createdAt: now,
            updatedAt: now
        )
        records.append(record)
        saveLocked()
        return record
    }

    public func update(id: String, content: String, kind: String?) -> SessionMemoryRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        records[index].content = content
        if let kind, !kind.isEmpty {
            records[index].kind = kind
        }
        records[index].updatedAt = Date()
        saveLocked()
        return records[index]
    }

    public func delete(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let oldCount = records.count
        records.removeAll { $0.id == id }
        guard records.count != oldCount else { return false }
        saveLocked()
        return true
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([SessionMemoryRecord].self, from: data) {
            records = decoded
        }
    }

    private func saveLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

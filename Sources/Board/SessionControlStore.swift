import Foundation
import Meee2CommKit

public enum SessionControlState: String, Codable {
    case active
    case hidden
    case archived
}

public struct SessionControlRecord: Codable {
    public var sessionId: String
    public var state: SessionControlState
    public var updatedAt: Date
}

public final class SessionControlStore {
    public static let shared = SessionControlStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var records: [String: SessionControlRecord] = [:]

    private init() {
        let base = StorageRoots.processDefault.baseDirectory
        self.fileURL = base.appendingPathComponent("session-controls.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    public func state(for sessionIds: [String]) -> SessionControlState {
        lock.lock()
        defer { lock.unlock() }
        for sessionId in sessionIds where !sessionId.isEmpty {
            if let record = records[sessionId] {
                return record.state
            }
        }
        return .active
    }

    @discardableResult
    public func setState(sessionId: String, state: SessionControlState) -> SessionControlRecord {
        lock.lock()
        defer { lock.unlock() }
        let record = SessionControlRecord(sessionId: sessionId, state: state, updatedAt: Date())
        if state == .active {
            records.removeValue(forKey: sessionId)
        } else {
            records[sessionId] = record
        }
        saveLocked()
        return record
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: SessionControlRecord].self, from: data) {
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

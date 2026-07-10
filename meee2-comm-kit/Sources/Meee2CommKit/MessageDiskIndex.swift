import Foundation
import SQLite3

struct MessageDiskIndexRecord {
    let id: String
    let channel: String
    let createdAt: Date
    let fileModifiedAt: Date
    let fileSizeBytes: Int64
    let status: MessageStatus
}

/// Durable metadata index for message envelopes. Payload JSON remains the
/// source of truth; this database removes 100k individual file reads from the
/// warm-start path and is reconciled against those files in the background.
final class MessageDiskIndex {
    static let fileName = ".index.sqlite3"

    private let lock = NSLock()
    private var database: OpaquePointer?

    init(fileURL: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw IndexError.openFailed
        }
        database = handle
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("""
        CREATE TABLE IF NOT EXISTS message_index (
          id TEXT PRIMARY KEY NOT NULL,
          channel TEXT NOT NULL,
          created_at REAL NOT NULL,
          modified_at REAL NOT NULL,
          size_bytes INTEGER NOT NULL,
          status TEXT NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_message_channel ON message_index(channel, created_at)")
        try execute("CREATE INDEX IF NOT EXISTS idx_message_status ON message_index(status, created_at)")
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func loadAll() throws -> [MessageDiskIndexRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw IndexError.closed }
        let sql = "SELECT id, channel, created_at, modified_at, size_bytes, status FROM message_index"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw currentError() }
        defer { sqlite3_finalize(statement) }

        var records: [MessageDiskIndexRecord] = []
        if let count = try? rowCountLocked() { records.reserveCapacity(count) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let channelText = sqlite3_column_text(statement, 1),
                  let statusText = sqlite3_column_text(statement, 5),
                  let status = MessageStatus(rawValue: String(cString: statusText)) else {
                continue
            }
            records.append(MessageDiskIndexRecord(
                id: String(cString: idText),
                channel: String(cString: channelText),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                fileModifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                fileSizeBytes: sqlite3_column_int64(statement, 4),
                status: status
            ))
        }
        return records
    }

    func queryIDs(channel: String?, statuses: Set<MessageStatus>?) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw IndexError.closed }
        var clauses: [String] = []
        var values: [String] = []
        if let channel {
            clauses.append("channel = ?")
            values.append(channel)
        }
        if let statuses, !statuses.isEmpty {
            let ordered = statuses.map(\.rawValue).sorted()
            clauses.append("status IN (\(Array(repeating: "?", count: ordered.count).joined(separator: ",")))")
            values.append(contentsOf: ordered)
        }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT id FROM message_index\(predicate) ORDER BY created_at, modified_at, id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            bind(value, to: Int32(offset + 1), statement: statement)
        }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: text))
            }
        }
        return ids
    }

    private func rowCountLocked() throws -> Int {
        guard let database else { throw IndexError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM message_index", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw currentError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func upsert(_ record: MessageDiskIndexRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try upsertLocked(record)
    }

    func remove(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw IndexError.closed }
        try executeLocked("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM message_index WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw currentError() }
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(id, to: 1, statement: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
            }
            try executeLocked("COMMIT")
        } catch {
            try? executeLocked("ROLLBACK")
            throw error
        }
    }

    func replaceAll(with records: [MessageDiskIndexRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeLocked("BEGIN IMMEDIATE")
        do {
            try executeLocked("DELETE FROM message_index")
            let statement = try prepareUpsertLocked()
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bindAndStepUpsertLocked(record, statement: statement)
            }
            try executeLocked("COMMIT")
        } catch {
            try? executeLocked("ROLLBACK")
            throw error
        }
    }

    private func upsertLocked(_ record: MessageDiskIndexRecord) throws {
        let statement = try prepareUpsertLocked()
        defer { sqlite3_finalize(statement) }
        try bindAndStepUpsertLocked(record, statement: statement)
    }

    private func prepareUpsertLocked() throws -> OpaquePointer {
        guard let database else { throw IndexError.closed }
        let sql = """
        INSERT INTO message_index(id, channel, created_at, modified_at, size_bytes, status)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          channel=excluded.channel,
          created_at=excluded.created_at,
          modified_at=excluded.modified_at,
          size_bytes=excluded.size_bytes,
          status=excluded.status
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw currentError() }
        return statement
    }

    private func bindAndStepUpsertLocked(
        _ record: MessageDiskIndexRecord,
        statement: OpaquePointer
    ) throws {
        bind(record.id, to: 1, statement: statement)
        bind(record.channel, to: 2, statement: statement)
        sqlite3_bind_double(statement, 3, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, record.fileModifiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 5, record.fileSizeBytes)
        bind(record.status.rawValue, to: 6, statement: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    private func bind(_ value: String, to index: Int32, statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeLocked(sql)
    }

    private func executeLocked(_ sql: String) throws {
        guard let database else { throw IndexError.closed }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw currentError()
        }
    }

    private func currentError() -> Error {
        guard let database, let message = sqlite3_errmsg(database) else { return IndexError.closed }
        return IndexError.sqlite(String(cString: message))
    }

    enum IndexError: Error {
        case openFailed
        case closed
        case sqlite(String)
    }
}

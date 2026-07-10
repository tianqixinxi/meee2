import Darwin
import Foundation

/// Fault-injection seams used to prove that a failed write never exposes
/// partially encoded session JSON.
enum SessionRepositoryWriteStage: Equatable {
    case temporaryFileSynced
    case beforeRename
    case afterRename
}

/// The only session-record disk writer in a process. The actor serializes
/// Hook, Board, monitor and CLI-backed mutations; `flock` extends the same
/// boundary to offline CLI processes.
public actor SessionRepository {
    private let fileManager: FileManager
    private let sessionsDirectory: URL
    private let quarantineDirectory: URL
    private let lockURL: URL
    private let faultInjector: ((SessionRepositoryWriteStage) throws -> Void)?

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.init(baseDirectory: baseDirectory, fileManager: fileManager, faultInjector: nil)
    }

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        faultInjector: ((SessionRepositoryWriteStage) throws -> Void)?
    ) {
        self.fileManager = fileManager
        let base = baseDirectory.standardizedFileURL
        sessionsDirectory = base.appendingPathComponent("sessions", isDirectory: true)
        quarantineDirectory = sessionsDirectory.appendingPathComponent("quarantine", isDirectory: true)
        lockURL = sessionsDirectory.appendingPathComponent(".repository.lock")
        self.faultInjector = faultInjector
        try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    public func loadAll() -> [SessionData] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(load)
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Saves only when the caller's revision matches the latest disk revision.
    /// A nil result means the caller was stale, the schema is unsupported, or
    /// durable replacement failed. The future-schema file is never modified.
    public func save(_ session: SessionData) -> SessionData? {
        do {
            return try withExclusiveLock {
                try saveLocked(session)
            }
        } catch {
            MLog("[SessionRepository] Failed to save \(session.sessionId.prefix(8)): \(error)", level: .error)
            return nil
        }
    }

    /// CAS-protected deletion prevents an offline process from deleting a
    /// record that changed after its snapshot was loaded.
    public func delete(sessionId: String, expectedRevision: UInt64) -> Bool {
        do {
            return try withExclusiveLock {
                let path = sessionPath(sessionId)
                guard fileManager.fileExists(atPath: path.path) else { return true }
                let data = try Data(contentsOf: path)
                guard !isFutureSchema(data) else { return false }
                let diskRevision = storedRevision(in: data)
                guard diskRevision == expectedRevision else {
                    MLog(
                        "[SessionRepository] Refused stale delete \(sessionId.prefix(8)) "
                            + "expected r\(expectedRevision), found r\(diskRevision)",
                        level: .warning
                    )
                    return false
                }
                try fileManager.removeItem(at: path)
                try syncDirectory(sessionsDirectory)
                return true
            }
        } catch {
            MLog("[SessionRepository] Failed to delete \(sessionId.prefix(8)): \(error)", level: .error)
            return false
        }
    }

    // MARK: - Load / migration

    private func load(_ path: URL) -> SessionData? {
        do {
            return try withExclusiveLock {
                let data = try Data(contentsOf: path)
                if let storedVersion = storedSchemaVersion(in: data),
                   storedVersion > SessionData.currentSchemaVersion {
                    MLog(
                        "[SessionRepository] Left future-schema session read-only "
                            + "\(path.lastPathComponent) (v\(storedVersion) > v\(SessionData.currentSchemaVersion))",
                        level: .warning
                    )
                    return nil
                }

                var session: SessionData
                do {
                    session = try JSONDecoder().decode(SessionData.self, from: data)
                } catch {
                    try quarantineLocked(path, reason: "decode-failed")
                    MLog(
                        "[SessionRepository] Quarantined unreadable session \(path.lastPathComponent): \(error)",
                        level: .warning
                    )
                    return nil
                }

                if session.schemaVersion < SessionData.currentSchemaVersion {
                    let from = session.schemaVersion
                    session = SessionDataMigrations.apply(to: session, from: from)
                    guard let persisted = try saveLocked(session) else { return nil }
                    session = persisted
                    MLog(
                        "[SessionRepository] Migrated \(session.sessionId.prefix(8)) "
                            + "schema v\(from) → v\(SessionData.currentSchemaVersion)"
                    )
                }
                return session
            }
        } catch {
            MLog("[SessionRepository] Failed to load \(path.lastPathComponent): \(error)", level: .warning)
            return nil
        }
    }

    // MARK: - Durable CAS writes

    private func saveLocked(_ session: SessionData) throws -> SessionData? {
        guard session.schemaVersion <= SessionData.currentSchemaVersion else {
            MLog(
                "[SessionRepository] Refused to write future-schema in-memory record "
                    + "\(session.sessionId.prefix(8)) v\(session.schemaVersion)",
                level: .warning
            )
            return nil
        }

        let path = sessionPath(session.sessionId)
        var diskRevision: UInt64 = 0
        if fileManager.fileExists(atPath: path.path) {
            let existing = try Data(contentsOf: path)
            if isFutureSchema(existing) {
                MLog(
                    "[SessionRepository] Refused to overwrite future-schema session "
                        + session.sessionId.prefix(8),
                    level: .warning
                )
                return nil
            }
            diskRevision = storedRevision(in: existing)
        }

        guard session.revision == diskRevision else {
            MLog(
                "[SessionRepository] Refused stale save \(session.sessionId.prefix(8)) "
                    + "expected r\(session.revision), found r\(diskRevision)",
                level: .warning
            )
            return nil
        }

        var persisted = session
        persisted.schemaVersion = SessionData.currentSchemaVersion
        persisted.revision = diskRevision &+ 1
        let data = try JSONEncoder().encode(persisted)
        try atomicReplace(data, at: path)
        return persisted
    }

    private func atomicReplace(_ data: Data, at path: URL) throws {
        let temporary = path.deletingLastPathComponent().appendingPathComponent(
            ".\(path.lastPathComponent).tmp.\(getpid()).\(UUID().uuidString)"
        )
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("open temporary session file") }

        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary { try? fileManager.removeItem(at: temporary) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                guard count > 0 else { throw posixError("write temporary session file") }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync temporary session file") }
        try faultInjector?(.temporaryFileSynced)
        try faultInjector?(.beforeRename)

        guard Darwin.rename(temporary.path, path.path) == 0 else { throw posixError("rename session file") }
        shouldRemoveTemporary = false
        try faultInjector?(.afterRename)
        try syncDirectory(path.deletingLastPathComponent())
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError("open session directory") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync session directory") }
    }

    // MARK: - Cross-process lock

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("open session repository lock") }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw posixError("lock session repository")
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    // MARK: - Helpers

    private func sessionPath(_ sessionId: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(sessionId).json")
    }

    private func isFutureSchema(_ data: Data) -> Bool {
        guard let version = storedSchemaVersion(in: data) else { return false }
        return version > SessionData.currentSchemaVersion
    }

    private func storedSchemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["schema_version"] as? NSNumber)?.intValue
    }

    private func storedRevision(in data: Data) -> UInt64 {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["revision"] as? NSNumber else {
            return 0
        }
        return number.uint64Value
    }

    private func quarantineLocked(_ path: URL, reason: String) throws {
        try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        let stem = path.deletingPathExtension().lastPathComponent
        let destination = quarantineDirectory.appendingPathComponent(
            "\(stem).\(reason).\(UUID().uuidString).json"
        )
        try fileManager.moveItem(at: path, to: destination)
        try syncDirectory(sessionsDirectory)
    }

    private func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

/// Synchronous adapters preserve the existing Hook/CLI contracts while disk
/// access itself stays isolated by `SessionRepository`.
final class SessionRepositoryWaitBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func take() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value!
    }
}

func waitForSessionRepository<Value>(_ operation: @escaping () async -> Value) -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SessionRepositoryWaitBox<Value>()
    Task.detached {
        box.store(await operation())
        semaphore.signal()
    }
    semaphore.wait()
    return box.take()
}

import XCTest
@testable import meee2Kit
@testable import Meee2CommKit

final class StorageReliabilityTests: XCTestCase {
    private let fileManager = FileManager.default

    func testSharedRuntimeStoresUseTemporaryRootUnderXCTest() {
        let liveRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".meee2", isDirectory: true)
            .standardizedFileURL
        let paths = CommKitStoragePaths.processDefault
        let roots = StorageRoots.processDefault

        XCTAssertNotEqual(paths.baseDirectory, liveRoot)
        XCTAssertEqual(roots.communication.baseDirectory, paths.baseDirectory)
        XCTAssertEqual(roots.baseDirectory, paths.baseDirectory)
        XCTAssertEqual(ChannelRegistry.shared.storagePaths.baseDirectory, paths.baseDirectory)
        XCTAssertEqual(MessageRouter.shared.storagePaths.baseDirectory, paths.baseDirectory)
        XCTAssertEqual(SessionStore.shared.baseDirectory, paths.baseDirectory)
        XCTAssertTrue(LogManager.shared.logFileURL.path.hasPrefix(roots.logsDirectory.path))
        XCTAssertTrue(paths.baseDirectory.path.hasPrefix(fileManager.temporaryDirectory.standardizedFileURL.path))
    }

    func testMessageRouterIndexesTerminalHistoryAndLoadsItLazily() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(
            storage: paths,
            channelRegistry: registry,
            terminalCacheLimit: 1
        )

        _ = try registry.create(name: "isolated", mode: .auto)
        _ = try registry.join(channel: "isolated", alias: "a", sessionId: "sid-a")
        _ = try registry.join(channel: "isolated", alias: "b", sessionId: "sid-b")
        let first = try router.send(channel: "isolated", fromAlias: "a", toAlias: "b", content: "first")
        let second = try router.send(channel: "isolated", fromAlias: "a", toAlias: "b", content: "second")

        XCTAssertTrue(fileManager.fileExists(atPath: paths.channelsDirectory.appendingPathComponent("isolated.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: paths.messagesDirectory
            .appendingPathComponent("isolated", isDirectory: true)
            .appendingPathComponent("\(first.id).json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("audit.log").path))
        XCTAssertEqual(router.cachedMessageCount, 1)

        let restarted = MessageRouter(
            storage: paths,
            channelRegistry: registry,
            terminalCacheLimit: 1
        )
        XCTAssertEqual(restarted.indexedMessageCount, 2)
        XCTAssertEqual(restarted.cachedMessageCount, 0)
        XCTAssertEqual(restarted.get(first.id)?.content, "first")
        XCTAssertEqual(restarted.cachedMessageCount, 1)
        XCTAssertEqual(restarted.get(second.id)?.content, "second")
        XCTAssertEqual(restarted.cachedMessageCount, 1)
        XCTAssertEqual(restarted.listMessages(channel: "isolated").map(\.content), ["first", "second"])

        _ = restarted.installRetentionPolicyIfNeeded(MessageRetentionPolicy(
            activatedAt: Date(timeIntervalSince1970: 0),
            terminalMaxAge: .greatestFiniteMagnitude
        ))
        XCTAssertEqual(restarted.pruneTerminalMessages(olderThan: .distantFuture), 2)
        XCTAssertEqual(restarted.indexedMessageCount, 0)
    }

    func testMessageRouterWarmStartsOneHundredThousandIndexedRecordsUnderHalfSecond() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        try fileManager.createDirectory(at: paths.messagesDirectory, withIntermediateDirectories: true)
        let index = try MessageDiskIndex(
            fileURL: paths.messagesDirectory.appendingPathComponent(MessageDiskIndex.fileName)
        )
        let epoch = Date(timeIntervalSince1970: 2_000_000_000)
        let records = (0..<100_000).map { offset in
            MessageDiskIndexRecord(
                id: "m-benchmark-\(offset)",
                channel: "benchmark-\(offset % 20)",
                createdAt: epoch.addingTimeInterval(TimeInterval(offset)),
                fileModifiedAt: epoch.addingTimeInterval(TimeInterval(offset)),
                fileSizeBytes: 768,
                status: .delivered
            )
        }
        try index.replaceAll(with: records)

        let registry = ChannelRegistry(storage: paths)
        let started = CFAbsoluteTimeGetCurrent()
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(router.indexedMessageCount, 100_000)
        XCTAssertEqual(router.cachedMessageCount, 0)
        XCTAssertLessThan(elapsed, 0.5, "100k warm index took \(elapsed)s")
    }

    func testCommKitClearHooksDropMemoryWithoutDeletingFiles() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)

        _ = try registry.create(name: "clear-hooks", mode: .intercept)
        _ = try registry.join(channel: "clear-hooks", alias: "a", sessionId: "sid-a")
        _ = try registry.join(channel: "clear-hooks", alias: "b", sessionId: "sid-b")
        let message = try router.send(
            channel: "clear-hooks",
            fromAlias: "a",
            toAlias: "b",
            content: "pending"
        )
        let messageFile = paths.messagesDirectory
            .appendingPathComponent("clear-hooks", isDirectory: true)
            .appendingPathComponent("\(message.id).json")

        registry.clearAllInMemory()
        router.clearAllInMemory()

        XCTAssertTrue(registry.list().isEmpty)
        XCTAssertEqual(router.indexedMessageCount, 0)
        XCTAssertNil(router.get(message.id))
        XCTAssertTrue(fileManager.fileExists(atPath: messageFile.path))
    }

    func testSessionStoreAtomicallyReplacesExistingRecord() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let store = SessionStore(baseDirectory: root)
        let sessionId = "atomic-session"
        store.create(SessionData(sessionId: sessionId, project: "/tmp/project", status: .idle))

        store.update(sessionId) { session in
            session.status = .tooling
            session.currentTool = "Bash"
        }

        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let file = sessionsDir.appendingPathComponent("\(sessionId).json")
        let persisted = try JSONDecoder().decode(SessionData.self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.status, .tooling)
        XCTAssertEqual(persisted.currentTool, "Bash")
        let leftovers = try fileManager.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".tmp.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSessionStoreLeavesFutureSchemaReadOnlyAndQuarantinesUnreadableRecords() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let futureURL = sessionsDir.appendingPathComponent("future.json")
        let valid = SessionData(sessionId: "future", project: "/tmp", status: .idle)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        object["schema_version"] = SessionData.currentSchemaVersion + 10
        let futureData = try JSONSerialization.data(withJSONObject: object)
        try futureData.write(to: futureURL, options: .atomic)

        let corruptURL = sessionsDir.appendingPathComponent("corrupt.json")
        try Data("{ definitely not json".utf8).write(to: corruptURL, options: .atomic)

        let store = SessionStore(baseDirectory: root)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: futureURL.path))
        XCTAssertEqual(try Data(contentsOf: futureURL), futureData)
        XCTAssertFalse(fileManager.fileExists(atPath: corruptURL.path))

        let quarantine = sessionsDir.appendingPathComponent("quarantine", isDirectory: true)
        let names = try fileManager.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names.contains { $0.contains("corrupt.decode-failed") })
    }

    func testSessionRepositoryRejectsStaleCrossProcessWrite() async throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let first = SessionRepository(baseDirectory: root)
        let second = SessionRepository(baseDirectory: root)

        var original = SessionData(sessionId: "cas", project: "/tmp", status: .idle)
        let firstSave = await first.save(original)
        original = try XCTUnwrap(firstSave)
        let secondSnapshot = await second.loadAll()
        let stale = try XCTUnwrap(secondSnapshot.first)

        original.status = .tooling
        let secondSave = await first.save(original)
        let newest = try XCTUnwrap(secondSave)
        XCTAssertEqual(newest.revision, 2)

        var conflicting = stale
        conflicting.status = .dead
        let rejected = await second.save(conflicting)
        XCTAssertNil(rejected)
        let persistedSnapshot = await second.loadAll()
        let persisted = try XCTUnwrap(persistedSnapshot.first)
        XCTAssertEqual(persisted.status, .tooling)
        XCTAssertEqual(persisted.revision, 2)
    }

    func testSessionRepositoryFaultInjectionAlwaysLeavesWholeJSON() async throws {
        for stage in [
            SessionRepositoryWriteStage.temporaryFileSynced,
            .beforeRename,
            .afterRename,
        ] {
            let root = try temporaryRoot()
            defer { try? fileManager.removeItem(at: root) }
            let baseline = SessionRepository(baseDirectory: root)
            var session = SessionData(sessionId: "fault", project: "/tmp", status: .idle)
            let baselineSave = await baseline.save(session)
            session = try XCTUnwrap(baselineSave)

            let failing = SessionRepository(baseDirectory: root) { reached in
                if reached == stage {
                    throw NSError(domain: "SessionRepositoryFault", code: 1)
                }
            }
            let failingSnapshot = await failing.loadAll()
            var changed = try XCTUnwrap(failingSnapshot.first)
            changed.status = .tooling
            let failedSave = await failing.save(changed)
            XCTAssertNil(failedSave)

            let file = root.appendingPathComponent("sessions/fault.json")
            let decoded = try JSONDecoder().decode(SessionData.self, from: Data(contentsOf: file))
            XCTAssertTrue(decoded.status == .idle || decoded.status == .tooling)
            XCTAssertTrue(decoded.revision == session.revision || decoded.revision == session.revision + 1)
            let leftovers = try fileManager.contentsOfDirectory(
                at: root.appendingPathComponent("sessions"),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.contains(".tmp.") }
            XCTAssertTrue(leftovers.isEmpty)
        }
    }

    func testLogManagerRotatesOversizedLogOnStartup() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let logURL = root.appendingPathComponent("meee2.log")
        let oldBody = String(repeating: "old-log-line\n", count: 64)
        try oldBody.write(to: logURL, atomically: true, encoding: .utf8)

        let manager = LogManager(logFileURL: logURL, maxBytes: 256, maxRotatedFiles: 2)
        manager.log("fresh-line", level: .info)
        manager.flush()

        let archive = URL(fileURLWithPath: "\(logURL.path).1")
        XCTAssertEqual(try String(contentsOf: archive, encoding: .utf8), oldBody)
        let current = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(current.contains("Application Started"))
        XCTAssertTrue(current.contains("fresh-line"))
    }

    func testLogManagerProductionDefaultsAreTenMegabytesAndFiveArchives() {
        XCTAssertEqual(LogManager.defaultMaxBytes, 10 * 1_024 * 1_024)
        XCTAssertEqual(LogManager.defaultMaxRotatedFiles, 5)
    }

    func testLogManagerFactoryResetRemovesBaseAndAllNumberedArchives() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let logURL = root.appendingPathComponent("meee2.log")
        let manager = LogManager(logFileURL: logURL, maxBytes: 512, maxRotatedFiles: 2)
        manager.flush()
        try Data("archive-one".utf8).write(to: URL(fileURLWithPath: "\(logURL.path).1"))
        try Data("stale-old-archive".utf8).write(to: URL(fileURLWithPath: "\(logURL.path).9"))

        manager.resetForFactoryReset()

        XCTAssertTrue(fileManager.fileExists(atPath: logURL.path))
        XCTAssertEqual((try? Data(contentsOf: logURL).count), 0)
        XCTAssertFalse(fileManager.fileExists(atPath: "\(logURL.path).1"))
        XCTAssertFalse(fileManager.fileExists(atPath: "\(logURL.path).9"))
        manager.log("after-reset", level: .info)
        manager.flush()
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("after-reset"))
    }

    func testRetentionProtectsPreActivationHistoryAndNeverDeletesPending() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let activation = now.addingTimeInterval(-45 * day)

        let legacy = retentionMessage(
            id: "m-legacy1",
            channel: "history",
            createdAt: now.addingTimeInterval(-60 * day),
            status: .delivered
        )
        let boundary = retentionMessage(
            id: "m-boundary",
            channel: "history",
            createdAt: activation,
            status: .dropped
        )
        let postActivation = retentionMessage(
            id: "m-postact1",
            channel: "history",
            createdAt: now.addingTimeInterval(-40 * day),
            status: .delivered
        )
        let telemetry = retentionMessage(
            id: "m-telemetr",
            channel: "__telemetry-runtime",
            createdAt: now.addingTimeInterval(-10 * day),
            status: .delivered
        )
        let pending = retentionMessage(
            id: "m-pending1",
            channel: "history",
            createdAt: now.addingTimeInterval(-40 * day),
            status: .pending
        )
        for message in [legacy, boundary, postActivation, telemetry, pending] {
            try writeRetentionMessage(message, paths: paths)
        }

        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        let policy = MessageRetentionPolicy(
            activatedAt: activation,
            maxRecordCount: 100,
            maxTotalBytes: 10 * 1_024 * 1_024
        )
        XCTAssertEqual(router.installRetentionPolicyIfNeeded(policy), policy)

        let preview = router.retentionPreview(now: now)
        XCTAssertEqual(preview.automaticCount, 2)
        XCTAssertEqual(preview.protectedHistoryCount, 2)

        let automatic = router.applyRetention(now: now)
        XCTAssertEqual(automatic.removedCount, 2)
        XCTAssertGreaterThan(automatic.reclaimedBytes, 0)
        XCTAssertNotNil(router.get(legacy.id))
        XCTAssertNotNil(router.get(boundary.id))
        XCTAssertNotNil(router.get(pending.id))
        XCTAssertNil(router.get(postActivation.id))
        XCTAssertNil(router.get(telemetry.id))

        let confirmed = try router.backupAndCleanLegacyHistory(
            now: now,
            backupsDirectory: root.appendingPathComponent("backups", isDirectory: true),
            expectedCount: preview.protectedHistoryCount,
            expectedBytes: preview.protectedHistoryBytes
        )
        XCTAssertEqual(confirmed.removedCount, 2)
        XCTAssertNil(router.get(legacy.id))
        XCTAssertNil(router.get(boundary.id))
        XCTAssertNotNil(router.get(pending.id), "pending must never be deleted")

        let restarted = MessageRouter(storage: paths, channelRegistry: registry)
        let laterCandidate = MessageRetentionPolicy.production(activatedAt: now)
        XCTAssertEqual(restarted.installRetentionPolicyIfNeeded(laterCandidate), policy)
    }

    func testRetentionCountCapDeletesOldestPostActivationTerminalRecords() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let activation = now.addingTimeInterval(-2 * day)
        for index in 0..<5 {
            let message = retentionMessage(
                id: "m-cap000\(index)",
                channel: "cap",
                createdAt: activation.addingTimeInterval(TimeInterval(index + 1)),
                status: index.isMultiple(of: 2) ? .delivered : .dropped
            )
            try writeRetentionMessage(message, paths: paths)
        }

        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        let policy = MessageRetentionPolicy(
            activatedAt: activation,
            maxRecordCount: 3,
            maxTotalBytes: .max
        )
        _ = router.installRetentionPolicyIfNeeded(policy)

        let preview = router.retentionPreview(now: now)
        XCTAssertEqual(preview.automaticCount, 2)
        XCTAssertEqual(preview.protectedHistoryCount, 0)
        let result = router.applyRetention(now: now)
        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(router.indexedMessageCount, 3)
        XCTAssertNil(router.get("m-cap0000"))
        XCTAssertNil(router.get("m-cap0001"))
        XCTAssertNotNil(router.get("m-cap0002"))

        let production = MessageRetentionPolicy.production(activatedAt: now)
        XCTAssertEqual(production.maxRecordCount, 100_000)
        XCTAssertEqual(production.maxTotalBytes, 250 * 1_024 * 1_024)
    }

    func testRetentionByteCapCountsOnlyTerminalRecords() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let activation = now.addingTimeInterval(-60)
        for index in 0..<3 {
            try writeRetentionMessage(
                retentionMessage(
                    id: "m-bytes0\(index)",
                    channel: "bytes",
                    createdAt: activation.addingTimeInterval(TimeInterval(index + 1)),
                    status: .delivered
                ),
                paths: paths
            )
        }
        let pending = retentionMessage(
            id: "m-bytepnd",
            channel: "bytes",
            createdAt: activation.addingTimeInterval(10),
            status: .held
        )
        try writeRetentionMessage(pending, paths: paths)

        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        _ = router.installRetentionPolicyIfNeeded(MessageRetentionPolicy(
            activatedAt: activation,
            maxRecordCount: 100,
            maxTotalBytes: 1
        ))

        let preview = router.retentionPreview(now: now)
        XCTAssertEqual(preview.automaticCount, 3)
        XCTAssertGreaterThan(preview.automaticBytes, 1)
        let result = router.applyRetention(now: now)
        XCTAssertEqual(result.removedCount, 3)
        XCTAssertEqual(result.reclaimedBytes, preview.automaticBytes)
        XCTAssertNotNil(router.get(pending.id), "held must not count toward the byte cap")
        XCTAssertEqual(router.indexedMessageCount, 1)
    }

    func testCorruptRetentionPolicyFailsSafeToNewActivationBoundary() throws {
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try Data("not-json".utf8).write(
            to: paths.messageRetentionPolicyFile,
            options: .atomic
        )
        let legacy = retentionMessage(
            id: "m-corrupt1",
            channel: "history",
            createdAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
            status: .delivered
        )
        try writeRetentionMessage(legacy, paths: paths)

        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        let preview = router.retentionPreview(now: now)

        XCTAssertEqual(preview.policy.activatedAt, now)
        XCTAssertEqual(preview.automaticCount, 0)
        XCTAssertEqual(preview.protectedHistoryCount, 1)
        XCTAssertNotNil(router.get(legacy.id))
    }

    private func temporaryRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("meee2-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func retentionMessage(
        id: String,
        channel: String,
        createdAt: Date,
        status: MessageStatus
    ) -> A2AMessage {
        A2AMessage(
            id: id,
            channel: channel,
            fromAlias: "source",
            fromSessionId: "sid-source",
            toAlias: "target",
            content: "retention fixture \(id)",
            createdAt: createdAt,
            status: status,
            deliveredAt: status == .delivered ? createdAt : nil,
            deliveredTo: status == .delivered ? ["target"] : []
        )
    }

    private func writeRetentionMessage(
        _ message: A2AMessage,
        paths: CommKitStoragePaths
    ) throws {
        let directory = paths.messagesDirectory
            .appendingPathComponent(message.channel, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        try data.write(
            to: directory.appendingPathComponent("\(message.id).json"),
            options: .atomic
        )
    }
}

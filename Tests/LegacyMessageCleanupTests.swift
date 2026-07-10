import XCTest
@testable import meee2Kit
import Meee2CommKit

final class LegacyMessageCleanupTests: XCTestCase {
    private let fileManager = FileManager.default
    private let day: TimeInterval = 24 * 60 * 60

    func testCleanupRequiresAValidPurposeBoundOneTimeToken() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let source = fixture.messageURL(id: "m-legacy-a", channel: "history")

        XCTAssertThrowsError(try fixture.api.cleanUp(
            token: "not-issued",
            purpose: .legacyMessageRetention
        )) { error in
            XCTAssertEqual(error as? LegacyMessageCleanupAPI.APIError, .tokenInvalid)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.backups.path))

        let token = try fixture.api.issueConfirmToken()
        let result = try fixture.api.cleanUp(token: token.token, purpose: token.purpose)
        XCTAssertTrue(result.ok)
        XCTAssertThrowsError(try fixture.api.cleanUp(token: token.token, purpose: token.purpose)) { error in
            XCTAssertEqual(error as? LegacyMessageCleanupAPI.APIError, .tokenInvalid)
        }
    }

    func testGenericPruneCannotBypassLegacyBackupConfirmation() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let source = fixture.messageURL(id: "m-legacy-a", channel: "history")

        XCTAssertEqual(fixture.router.pruneTerminalMessages(olderThan: .distantFuture), 0)
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
        XCTAssertNotNil(fixture.router.get("m-legacy-a"))
    }

    func testConfirmedCleanupBacksUpExactCandidatesBeforeRemovingAndProtectsPendingHeld() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let legacyA = message(id: "m-legacy-a", createdAt: now.addingTimeInterval(-60 * day), status: .delivered)
        let legacyB = message(id: "m-legacy-b", createdAt: now.addingTimeInterval(-50 * day), status: .dropped)
        let pending = message(id: "m-pending-a", createdAt: now.addingTimeInterval(-70 * day), status: .pending)
        let held = message(id: "m-held-aaa", createdAt: now.addingTimeInterval(-70 * day), status: .held)
        for item in [legacyA, legacyB, pending, held] {
            try write(item, paths: paths)
        }
        let originalData = try Dictionary(uniqueKeysWithValues: [legacyA, legacyB].map {
            ($0.id, try Data(contentsOf: messageURL(paths: paths, message: $0)))
        })

        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        _ = router.installRetentionPolicyIfNeeded(MessageRetentionPolicy(
            activatedAt: now.addingTimeInterval(-30 * day),
            terminalMaxAge: 10 * day,
            telemetryMaxAge: 7 * day,
            maxRecordCount: 100,
            maxTotalBytes: 10 * 1_024 * 1_024
        ))
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let api = LegacyMessageCleanupAPI(
            router: router,
            backupsDirectory: backups,
            now: { now },
            makeToken: { "cleanup-token" }
        )

        let token = try api.issueConfirmToken()
        XCTAssertEqual(token.messageCount, 2)
        XCTAssertGreaterThan(token.messageBytes, 0)
        let result = try api.cleanUp(token: token.token, purpose: token.purpose)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.reclaimedBytes, token.messageBytes)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: result.backupPath, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let archivedFiles = try regularJSONFiles(at: URL(fileURLWithPath: result.backupPath))
        XCTAssertEqual(archivedFiles.count, 2, "archive must contain exactly the confirmed candidates")
        let archivedByID = try Dictionary(uniqueKeysWithValues: archivedFiles.map { url -> (String, Data) in
            let data = try Data(contentsOf: url)
            let decoded = try decode(data)
            return (decoded.id, data)
        })
        XCTAssertEqual(Set(archivedByID.keys), Set([legacyA.id, legacyB.id]))
        XCTAssertEqual(archivedByID[legacyA.id], originalData[legacyA.id])
        XCTAssertEqual(archivedByID[legacyB.id], originalData[legacyB.id])

        XCTAssertFalse(fileManager.fileExists(atPath: messageURL(paths: paths, message: legacyA).path))
        XCTAssertFalse(fileManager.fileExists(atPath: messageURL(paths: paths, message: legacyB).path))
        XCTAssertTrue(fileManager.fileExists(atPath: messageURL(paths: paths, message: pending).path))
        XCTAssertTrue(fileManager.fileExists(atPath: messageURL(paths: paths, message: held).path))
        XCTAssertNotNil(router.get(pending.id), "pending messages must never be cleanup candidates")
        XCTAssertNotNil(router.get(held.id), "held messages must never be cleanup candidates")
    }

    func testBackupFailureLeavesEveryOriginalCandidateUntouched() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        // A regular file where a backup directory must be forces staging to
        // fail before any source deletion can begin.
        try Data("not-a-directory".utf8).write(to: fixture.backups)
        let original = fixture.messageURL(id: "m-legacy-a", channel: "history")
        let before = try Data(contentsOf: original)
        let token = try fixture.api.issueConfirmToken()

        XCTAssertThrowsError(try fixture.api.cleanUp(token: token.token, purpose: token.purpose)) { error in
            guard case .backupFailed = error as? LegacyMessageCleanupAPI.APIError else {
                return XCTFail("expected backupFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertNotNil(fixture.router.get("m-legacy-a"))
    }

    func testTokenScopeChangeIsRejectedWithoutCreatingBackupOrDeletingHistory() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let token = try fixture.api.issueConfirmToken()
        let competingCleanup = try fixture.router.backupAndCleanLegacyHistory(
            now: fixture.now,
            backupsDirectory: fixture.root.appendingPathComponent("competing-backup", isDirectory: true),
            expectedCount: token.messageCount,
            expectedBytes: token.messageBytes
        )
        XCTAssertEqual(competingCleanup.removedCount, 1)

        XCTAssertThrowsError(try fixture.api.cleanUp(token: token.token, purpose: token.purpose)) { error in
            XCTAssertEqual(error as? LegacyMessageCleanupAPI.APIError, .noCandidates)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.backups.path))
    }

    func testExpiredTokenCannotRemoveOrBackUpAnyMessage() throws {
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let root = try temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let paths = CommKitStoragePaths(baseDirectory: root)
        let legacy = message(
            id: "m-expired-a",
            createdAt: clock.addingTimeInterval(-60 * day),
            status: .delivered
        )
        try write(legacy, paths: paths)
        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        _ = router.installRetentionPolicyIfNeeded(MessageRetentionPolicy(
            activatedAt: clock.addingTimeInterval(-30 * day),
            terminalMaxAge: 10 * day
        ))
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let api = LegacyMessageCleanupAPI(
            router: router,
            backupsDirectory: backups,
            now: { clock },
            makeToken: { "expiring-token" },
            tokenTTL: 120
        )
        let confirmation = try api.issueConfirmToken()
        clock = clock.addingTimeInterval(121)

        XCTAssertThrowsError(try api.cleanUp(
            token: confirmation.token,
            purpose: confirmation.purpose
        )) { error in
            XCTAssertEqual(error as? LegacyMessageCleanupAPI.APIError, .tokenExpired)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: messageURL(paths: paths, message: legacy).path))
        XCTAssertFalse(fileManager.fileExists(atPath: backups.path))
    }

    func testCandidateChangedToPendingAfterPreviewIsNeverRemoved() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let confirmation = try fixture.api.issueConfirmToken()
        let source = fixture.messageURL(id: "m-legacy-a", channel: "history")
        var changed = try decode(Data(contentsOf: source))
        changed.status = .pending
        try write(changed, paths: fixture.paths)

        XCTAssertThrowsError(try fixture.api.cleanUp(
            token: confirmation.token,
            purpose: confirmation.purpose
        )) { error in
            guard let apiError = error as? LegacyMessageCleanupAPI.APIError else {
                return XCTFail("unexpected error: \(error)")
            }
            switch apiError {
            case .previewChanged, .backupFailed:
                break
            default:
                XCTFail("unexpected cleanup error: \(apiError)")
            }
        }
        XCTAssertEqual(try decode(Data(contentsOf: source)).status, .pending)
    }

    private struct Fixture {
        let root: URL
        let paths: CommKitStoragePaths
        let backups: URL
        let router: MessageRouter
        let api: LegacyMessageCleanupAPI
        let now: Date

        func messageURL(id: String, channel: String) -> URL {
            paths.messagesDirectory
                .appendingPathComponent(channel, isDirectory: true)
                .appendingPathComponent("\(id).json", isDirectory: false)
        }
    }

    private func makeFixture() throws -> Fixture {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let root = try temporaryRoot()
        let paths = CommKitStoragePaths(baseDirectory: root)
        let legacy = message(
            id: "m-legacy-a",
            createdAt: now.addingTimeInterval(-60 * day),
            status: .delivered
        )
        try write(legacy, paths: paths)
        let registry = ChannelRegistry(storage: paths)
        let router = MessageRouter(storage: paths, channelRegistry: registry)
        _ = router.installRetentionPolicyIfNeeded(MessageRetentionPolicy(
            activatedAt: now.addingTimeInterval(-30 * day),
            terminalMaxAge: 10 * day,
            maxRecordCount: 100,
            maxTotalBytes: 10 * 1_024 * 1_024
        ))
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        return Fixture(
            root: root,
            paths: paths,
            backups: backups,
            router: router,
            api: LegacyMessageCleanupAPI(
                router: router,
                backupsDirectory: backups,
                now: { now },
                makeToken: { "fixture-token" }
            ),
            now: now
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("meee2-legacy-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func message(id: String, createdAt: Date, status: MessageStatus) -> A2AMessage {
        A2AMessage(
            id: id,
            channel: "history",
            fromAlias: "source",
            fromSessionId: "sid-source",
            toAlias: "target",
            content: "legacy cleanup fixture \(id)",
            createdAt: createdAt,
            status: status,
            deliveredAt: status == .delivered ? createdAt : nil,
            deliveredTo: status == .delivered ? ["target"] : []
        )
    }

    private func write(_ message: A2AMessage, paths: CommKitStoragePaths) throws {
        let url = messageURL(paths: paths, message: message)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(message).write(to: url, options: .atomic)
    }

    private func messageURL(paths: CommKitStoragePaths, message: A2AMessage) -> URL {
        paths.messagesDirectory
            .appendingPathComponent(message.channel, isDirectory: true)
            .appendingPathComponent("\(message.id).json", isDirectory: false)
    }

    private func regularJSONFiles(at root: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.pathExtension == "json",
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return url
        }
    }

    private func decode(_ data: Data) throws -> A2AMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(A2AMessage.self, from: data)
    }
}

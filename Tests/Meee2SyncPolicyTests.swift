import XCTest
@testable import meee2Kit

final class Meee2SyncPolicyTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "meee2SessionSyncPolicies")
        super.tearDown()
    }

    func testPolicyAliases() {
        XCTAssertEqual(Meee2SyncPolicy(rawValueOrAlias: "metadataOnly"), .metadata)
        XCTAssertEqual(Meee2SyncPolicy(rawValueOrAlias: "recent_context"), .recentContext)
        XCTAssertEqual(Meee2SyncPolicy(rawValueOrAlias: "full_transcript"), .fullTranscript)
        XCTAssertEqual(Meee2SyncPolicy(rawValueOrAlias: "artifacts_only"), .artifactsOnly)
        XCTAssertEqual(Meee2SyncPolicy(rawValueOrAlias: "unknown"), .private)
    }

    func testUploadBoundaries() {
        XCTAssertFalse(Meee2SyncPolicy.private.uploadsSession)
        XCTAssertTrue(Meee2SyncPolicy.metadata.uploadsSession)
        XCTAssertFalse(Meee2SyncPolicy.metadata.uploadsSummary)
        XCTAssertTrue(Meee2SyncPolicy.summary.uploadsSummary)
        XCTAssertFalse(Meee2SyncPolicy.summary.uploadsRecentContext)
        XCTAssertTrue(Meee2SyncPolicy.recentContext.uploadsRecentContext)
        XCTAssertTrue(Meee2SyncPolicy.fullTranscript.uploadsRecentContext)
        XCTAssertFalse(Meee2SyncPolicy.artifactsOnly.uploadsSummary)
    }

    func testSessionPolicyStorageUsesAliases() {
        Meee2OnlinePusher.storeSessionSyncPolicy(
            sessionId: "com.meee2.plugin.codex-abc123",
            policy: .summary
        )

        let policies = Meee2OnlinePusher.sessionSyncPolicyMap()
        XCTAssertEqual(policies["com.meee2.plugin.codex-abc123"], .summary)
        XCTAssertEqual(policies["abc123"], .summary)
    }
}

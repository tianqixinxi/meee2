import Foundation
import Meee2CommKit

/// Explicit, one-time-token contract for removing message history created
/// before retention was activated. It is intentionally separate from the
/// broader local-data deletion token so neither token can authorize the other
/// operation.
final class LegacyMessageCleanupAPI {
    static let shared = LegacyMessageCleanupAPI()

    enum Purpose: String, Codable {
        case legacyMessageRetention
    }

    struct ConfirmToken: Encodable {
        let token: String
        let purpose: Purpose
        let messageCount: Int
        let messageBytes: Int64
        let issuedAt: String
        let expiresAt: String
    }

    struct CleanupResult: Encodable, Equatable {
        let ok: Bool
        let backupPath: String
        let removedCount: Int
        let reclaimedBytes: Int64
        let failedCount: Int
    }

    enum APIError: LocalizedError, Equatable {
        case noCandidates
        case tokenInvalid
        case tokenExpired
        case previewChanged
        case backupFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCandidates:
                return "there are no legacy message files to clean up"
            case .tokenInvalid:
                return "legacy cleanup confirmation token is invalid, used, or belongs to another operation"
            case .tokenExpired:
                return "legacy cleanup confirmation token expired; review the preview again"
            case .previewChanged:
                return "legacy message cleanup preview changed; review the updated count and size"
            case .backupFailed(let detail):
                return "legacy message backup failed; no original files were removed: \(detail)"
            }
        }
    }

    private struct IssuedToken {
        let token: String
        let purpose: Purpose
        let expectedCount: Int
        let expectedBytes: Int64
        let expiresAt: Date
    }

    private let router: MessageRouter
    private let backupsDirectory: URL
    private let now: () -> Date
    private let makeToken: () -> String
    private let tokenTTL: TimeInterval
    private let tokenLock = NSLock()
    private var issuedTokens: [IssuedToken] = []

    init(
        router: MessageRouter = .shared,
        backupsDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        makeToken: @escaping () -> String = { UUID().uuidString },
        tokenTTL: TimeInterval = 120
    ) {
        self.router = router
        self.backupsDirectory = backupsDirectory
            ?? router.storagePaths.baseDirectory.appendingPathComponent("backups", isDirectory: true)
        self.now = now
        self.makeToken = makeToken
        self.tokenTTL = tokenTTL
    }

    /// Issue a scope-bound token from the same preview shown in the confirm
    /// modal. Cleanup rejects the token if the candidate count or byte total
    /// changes before confirmation.
    func issueConfirmToken() throws -> ConfirmToken {
        let issuedAt = now()
        let preview = router.retentionPreview(now: issuedAt)
        guard preview.protectedHistoryCount > 0,
              preview.protectedHistoryBytes > 0 else {
            throw APIError.noCandidates
        }

        let token = makeToken()
        let expiresAt = issuedAt.addingTimeInterval(tokenTTL)
        let entry = IssuedToken(
            token: token,
            purpose: .legacyMessageRetention,
            expectedCount: preview.protectedHistoryCount,
            expectedBytes: preview.protectedHistoryBytes,
            expiresAt: expiresAt
        )

        tokenLock.lock()
        issuedTokens.removeAll { $0.expiresAt < issuedAt }
        if issuedTokens.count >= 16 {
            issuedTokens.removeFirst(issuedTokens.count - 15)
        }
        issuedTokens.append(entry)
        tokenLock.unlock()

        let formatter = ISO8601DateFormatter()
        return ConfirmToken(
            token: token,
            purpose: entry.purpose,
            messageCount: entry.expectedCount,
            messageBytes: entry.expectedBytes,
            issuedAt: formatter.string(from: issuedAt),
            expiresAt: formatter.string(from: expiresAt)
        )
    }

    func cleanUp(token: String, purpose: Purpose) throws -> CleanupResult {
        let entry = try consumeToken(token, purpose: purpose)
        do {
            let result = try router.backupAndCleanLegacyHistory(
                now: now(),
                backupsDirectory: backupsDirectory,
                expectedCount: entry.expectedCount,
                expectedBytes: entry.expectedBytes
            )
            return CleanupResult(
                ok: result.failedCount == 0,
                backupPath: result.backupPath,
                removedCount: result.removedCount,
                reclaimedBytes: result.reclaimedBytes,
                failedCount: result.failedCount
            )
        } catch LegacyMessageCleanupError.noCandidates {
            throw APIError.noCandidates
        } catch LegacyMessageCleanupError.previewChanged {
            throw APIError.previewChanged
        } catch LegacyMessageCleanupError.archiveFailed(let detail) {
            throw APIError.backupFailed(detail)
        } catch {
            throw APIError.backupFailed(error.localizedDescription)
        }
    }

    private func consumeToken(_ token: String, purpose: Purpose) throws -> IssuedToken {
        let currentTime = now()
        tokenLock.lock()
        defer { tokenLock.unlock() }

        guard let index = issuedTokens.firstIndex(where: { $0.token == token }) else {
            throw APIError.tokenInvalid
        }
        let entry = issuedTokens.remove(at: index)
        guard entry.expiresAt >= currentTime else {
            throw APIError.tokenExpired
        }
        guard entry.purpose == purpose else {
            throw APIError.tokenInvalid
        }
        return entry
    }
}

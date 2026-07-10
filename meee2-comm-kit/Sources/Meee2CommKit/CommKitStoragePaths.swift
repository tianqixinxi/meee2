import Foundation

/// Filesystem roots used by the communication runtime.
///
/// Production keeps the existing `~/.meee2` and Claude Teams locations. Test
/// processes are redirected to a per-process temporary root so touching
/// `ChannelRegistry.shared` or `MessageRouter.shared` can never mutate a
/// developer's real channels, messages, or inboxes.
public struct CommKitStoragePaths {
    public let baseDirectory: URL
    public let channelsDirectory: URL
    public let messagesDirectory: URL
    public let messageRetentionPolicyFile: URL
    public let inboxDirectory: URL
    public let legacyInboxDirectory: URL

    public init(
        baseDirectory: URL,
        inboxDirectory: URL? = nil,
        legacyInboxDirectory: URL? = nil
    ) {
        let base = baseDirectory.standardizedFileURL
        self.baseDirectory = base
        channelsDirectory = base.appendingPathComponent("channels", isDirectory: true)
        messagesDirectory = base.appendingPathComponent("messages", isDirectory: true)
        messageRetentionPolicyFile = base.appendingPathComponent(
            "message-retention-policy.json",
            isDirectory: false
        )
        self.inboxDirectory = (inboxDirectory
            ?? base.appendingPathComponent("claude-inboxes", isDirectory: true))
            .standardizedFileURL
        self.legacyInboxDirectory = (legacyInboxDirectory
            ?? base.appendingPathComponent("inbox", isDirectory: true))
            .standardizedFileURL
    }

    /// Stable for the lifetime of the process so every CommKit singleton uses
    /// the same root. `MEEE2_COMM_KIT_STORAGE_ROOT` is also useful for isolated
    /// integration tests launched outside XCTest.
    public static let processDefault = StorageRoots.processDefault.communication
}

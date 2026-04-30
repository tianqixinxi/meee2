import XCTest
@testable import meee2Kit

final class HookSocketServerDesktopDrainTests: XCTestCase {

    private func writeTranscript(entrypoint: String?) -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("hsd-\(UUID().uuidString).jsonl")
        let line: String = {
            if let ep = entrypoint {
                return #"{"type":"user","entrypoint":"\#(ep)","sessionId":"x","message":{}}"#
            }
            return #"{"type":"user","sessionId":"x","message":{}}"#
        }()
        try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func uniqueChannel() -> String {
        "drain-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    private func uuidSid() -> String { UUID().uuidString.lowercased() }

    private func registerSession(_ sid: String, transcriptPath: String) {
        SessionStore.shared.upsert(SessionData(
            sessionId: sid,
            project: "test-desktop-drain",
            transcriptPath: transcriptPath
        ))
    }

    private func sendMessage(channel: String, target: String, content: String) throws {
        let senderSid = "sender-" + UUID().uuidString.lowercased()
        _ = try ChannelRegistry.shared.create(name: channel, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: channel, alias: "sender", sessionId: senderSid)
        _ = try ChannelRegistry.shared.join(channel: channel, alias: "target", sessionId: target)
        _ = try MessageRouter.shared.send(
            channel: channel, fromAlias: "sender", toAlias: "target", content: content
        )
    }

    override func setUp() {
        super.setUp()
        ClaudeEntrypointReader._resetCache()
    }

    func testDesktopSessionWithMessageReturnsBlockDecision() throws {
        let sid = uuidSid()
        let channel = uniqueChannel()
        registerSession(sid, transcriptPath: writeTranscript(entrypoint: "claude-desktop"))
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: sid)
            try? ChannelRegistry.shared.delete(channel)
        }

        try sendMessage(channel: channel, target: sid, content: "ship the fix")

        let response = HookSocketServer.shared.drainResponseForDesktopStop(sessionId: sid)
        XCTAssertEqual(response?.decision, "block")
        let reason = response?.reason ?? ""
        XCTAssertTrue(reason.contains("ship the fix"), "reason missing content: \(reason)")
        XCTAssertTrue(reason.contains("[meee2 a2a]"), "reason missing label: \(reason)")
        XCTAssertTrue(MessageRouter.shared.peekInbox(sessionId: sid).isEmpty,
                      "inbox should be drained after a successful inline drain")
    }

    func testCLISessionReturnsNilAndPreservesInbox() throws {
        let sid = uuidSid()
        let channel = uniqueChannel()
        registerSession(sid, transcriptPath: writeTranscript(entrypoint: "cli"))
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: sid)
            try? ChannelRegistry.shared.delete(channel)
        }

        try sendMessage(channel: channel, target: sid, content: "ping")

        let response = HookSocketServer.shared.drainResponseForDesktopStop(sessionId: sid)
        XCTAssertNil(response, "CLI session must not receive inline drain — uses Ghostty path")
        XCTAssertEqual(MessageRouter.shared.peekInbox(sessionId: sid).count, 1,
                       "inbox must NOT be drained for CLI sessions")
    }

    func testDesktopSessionWithEmptyInboxReturnsNil() throws {
        let sid = uuidSid()
        registerSession(sid, transcriptPath: writeTranscript(entrypoint: "claude-desktop"))
        defer { _ = MessageRouter.shared.drainInbox(sessionId: sid) }

        let response = HookSocketServer.shared.drainResponseForDesktopStop(sessionId: sid)
        XCTAssertNil(response, "Empty inbox must return nil — don't block Stop with empty reason")
    }

    func testUnknownEntrypointReturnsNil() throws {
        let sid = uuidSid()
        let channel = uniqueChannel()
        registerSession(sid, transcriptPath: writeTranscript(entrypoint: nil))
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: sid)
            try? ChannelRegistry.shared.delete(channel)
        }

        try sendMessage(channel: channel, target: sid, content: "noop")

        let response = HookSocketServer.shared.drainResponseForDesktopStop(sessionId: sid)
        XCTAssertNil(response, "Unknown entrypoint must not trigger inline drain")
        XCTAssertEqual(MessageRouter.shared.peekInbox(sessionId: sid).count, 1)
    }
}

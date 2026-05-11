import XCTest
@testable import meee2Kit
import Meee2CommKit

/// Unit tests for the assistant's tool dispatcher. We exercise the pure
/// gating + validation paths (filter, unknown tool, missing args) — the
/// state-touching tools (`get_session_list`, `get_session_info`) hit
/// `PluginManager.shared` and `SessionStore.shared`, which are global
/// singletons; we only verify they don't crash when those are empty and
/// trust integration smoke tests for the data shape.
final class AssistantToolsTests: XCTestCase {

    // MARK: - Catalog shape

    func testCatalogContainsAllExpectedTools() {
        let names = AssistantTools.allNames
        XCTAssertEqual(names, [
            "get_canvas_context",
            "get_session_list",
            "get_session_info",
            "get_session_transcript",
            "list_channels",
            "get_channel_messages",
            "propose_canvas_patch",
            "create_session"
        ])
    }

    func testCatalogToolDefsHaveSchemas() {
        for tool in AssistantTools.all {
            // Every tool must declare an object schema with a `properties` map.
            // LLMs reject tools whose schema is malformed or missing.
            XCTAssertEqual(
                tool.inputSchema["type"] as? String, "object",
                "tool '\(tool.name)' missing top-level type=object")
            XCTAssertNotNil(
                tool.inputSchema["properties"] as? [String: Any],
                "tool '\(tool.name)' missing properties map")
            XCTAssertFalse(tool.description.isEmpty,
                           "tool '\(tool.name)' missing description")
        }
    }

    // MARK: - Filter

    func testFilterReturnsAllWhenEnabledIsNil() {
        let filtered = AssistantTools.filter(nil)
        XCTAssertEqual(filtered.count, AssistantTools.all.count)
    }

    func testFilterRespectsEnabledSet() {
        let only = AssistantTools.filter(["get_session_list"])
        XCTAssertEqual(only.map(\.name), ["get_session_list"])
    }

    func testFilterEmptySetReturnsNoTools() {
        let none = AssistantTools.filter([])
        XCTAssertEqual(none.count, 0)
    }

    // MARK: - Dispatch gating

    func testDispatchUnknownToolFailsCleanly() {
        let r = AssistantTools.dispatch(name: "ghost_tool", args: [:], enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected failure for unknown tool, got \(r)")
        }
        XCTAssertTrue(msg.contains("unknown tool"))
    }

    func testDispatchHonorsEnabledFilter() {
        // create_session is a real tool, but if it's not in `enabled` the
        // dispatcher must refuse it before any side effects (no spawn).
        let r = AssistantTools.dispatch(
            name: "create_session",
            args: ["cwd": "/tmp"],
            enabled: ["get_session_list"])
        guard case .failure(let msg) = r else {
            return XCTFail("expected disabled tool to fail, got \(r)")
        }
        XCTAssertTrue(msg.contains("disabled"))
    }

    func testDispatchAllowsToolWhenEnabledNil() {
        // nil enabled = all tools available → unknown still fails, real tool
        // proceeds to its handler.
        let r = AssistantTools.dispatch(
            name: "create_session",
            args: [:],  // missing cwd → handler-level failure
            enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected handler-level failure for missing cwd")
        }
        XCTAssertTrue(msg.contains("cwd"),
                      "expected error to mention 'cwd', got: \(msg)")
    }

    // MARK: - create_session validation

    func testCreateSessionRejectsMissingCwd() {
        let r = AssistantTools.dispatch(name: "create_session", args: [:], enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected failure for missing cwd, got \(r)")
        }
        XCTAssertTrue(msg.contains("cwd"))
    }

    func testCreateSessionRejectsEmptyCwd() {
        let r = AssistantTools.dispatch(name: "create_session", args: ["cwd": ""], enabled: nil)
        guard case .failure = r else {
            return XCTFail("expected failure for empty cwd, got \(r)")
        }
    }

    func testCreateSessionRejectsNonexistentCwdWithoutCreateIfMissing() {
        // Pick a path that definitely doesn't exist.
        let bogus = "/tmp/meee2-tests-nonexistent-\(UUID().uuidString)"
        let r = AssistantTools.dispatch(
            name: "create_session",
            args: ["cwd": bogus],
            enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected failure for nonexistent cwd, got \(r)")
        }
        XCTAssertTrue(msg.contains("does not exist"))
        XCTAssertTrue(msg.contains("createIfMissing"),
                      "error message should hint at the createIfMissing escape hatch")
    }

    // MARK: - get_session_list / get_session_info smoke

    func testGetSessionListRunsAgainstEmptyStateWithoutCrashing() {
        // PluginManager.shared in test context has no live sessions; just
        // ensure the call returns success with whatever shape the runtime
        // happens to have, no crash on empty.
        let r = AssistantTools.dispatch(name: "get_session_list", args: [:], enabled: nil)
        guard case .success(let payload) = r else {
            return XCTFail("get_session_list should always succeed, got \(r)")
        }
        let dict = payload as? [String: Any]
        XCTAssertNotNil(dict?["sessions"] as? [Any])
        XCTAssertNotNil(dict?["total"] as? Int)
    }

    func testGetSessionInfoRejectsMissingSessionId() {
        let r = AssistantTools.dispatch(name: "get_session_info", args: [:], enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected missing-sessionId failure, got \(r)")
        }
        XCTAssertTrue(msg.contains("sessionId"))
    }

    func testGetSessionInfoRejectsUnknownSessionId() {
        let r = AssistantTools.dispatch(
            name: "get_session_info",
            args: ["sessionId": "definitely-not-a-real-sid-\(UUID().uuidString)"],
            enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected unknown-sid failure, got \(r)")
        }
        XCTAssertTrue(msg.contains("not found"))
    }

    // MARK: - get_session_transcript

    func testGetSessionTranscriptRejectsMissingSessionId() {
        let r = AssistantTools.dispatch(name: "get_session_transcript", args: [:], enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected missing-sessionId failure, got \(r)")
        }
        XCTAssertTrue(msg.contains("sessionId"))
    }

    func testGetSessionTranscriptRejectsUnknownSession() {
        let r = AssistantTools.dispatch(
            name: "get_session_transcript",
            args: ["sessionId": "ghost-\(UUID().uuidString)"],
            enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected unknown-sid failure")
        }
        XCTAssertTrue(msg.contains("not found"))
    }

    func testGetSessionTranscriptHonorsEnabledFilter() {
        let r = AssistantTools.dispatch(
            name: "get_session_transcript",
            args: ["sessionId": "anything"],
            enabled: ["get_session_list"])
        guard case .failure(let msg) = r else {
            return XCTFail("expected disabled failure")
        }
        XCTAssertTrue(msg.contains("disabled"))
    }

    // MARK: - list_channels

    func testListChannelsReturnsCreatedChannel() throws {
        // Real ChannelRegistry singleton — create a unique channel, dispatch
        // the tool, then clean up. Other channels may exist from other tests
        // or local state, so we only assert ours is present.
        let name = "asst-tool-list-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try ChannelRegistry.shared.create(name: name, description: "tool test", mode: .auto)
        defer { try? ChannelRegistry.shared.delete(name) }

        let r = AssistantTools.dispatch(name: "list_channels", args: [:], enabled: nil)
        guard case .success(let payload) = r else {
            return XCTFail("expected success, got \(r)")
        }
        let dict = payload as? [String: Any]
        let channels = dict?["channels"] as? [[String: Any]] ?? []
        let names = channels.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains(name), "expected new channel in list, got \(names)")

        // Schema check on our own channel: all expected keys present.
        let ours = channels.first { $0["name"] as? String == name }
        XCTAssertNotNil(ours?["mode"])
        XCTAssertNotNil(ours?["memberCount"] as? Int)
        XCTAssertNotNil(ours?["pendingCount"] as? Int)
    }

    // MARK: - get_channel_messages

    func testGetChannelMessagesRejectsMissingId() {
        let r = AssistantTools.dispatch(name: "get_channel_messages", args: [:], enabled: nil)
        guard case .failure(let msg) = r else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("channelId"))
    }

    func testGetChannelMessagesRejectsUnknownChannel() {
        let r = AssistantTools.dispatch(
            name: "get_channel_messages",
            args: ["channelId": "no-such-channel-\(UUID().uuidString.prefix(8).lowercased())"],
            enabled: nil)
        guard case .failure(let msg) = r else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("not found"))
    }

    func testGetChannelMessagesReturnsMessagesWithLimitAndSinceTs() throws {
        let name = "asst-tool-msgs-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try ChannelRegistry.shared.create(name: name, description: "msg test", mode: .auto)
        defer { try? ChannelRegistry.shared.delete(name) }
        // Two members so broadcast/direct sends are valid.
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: "sid-a-\(UUID().uuidString)")
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: "sid-b-\(UUID().uuidString)")

        // Send three messages in sequence.
        let m1 = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "first")
        let m2 = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "second")
        let m3 = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "third")
        XCTAssertNotNil(m1.id)
        XCTAssertNotNil(m2.id)
        XCTAssertNotNil(m3.id)

        // Default returns up to 30 — should see all 3 (newest last per spec).
        let r = AssistantTools.dispatch(
            name: "get_channel_messages",
            args: ["channelId": name],
            enabled: nil)
        guard case .success(let payload) = r else { return XCTFail("expected success") }
        let dict = payload as? [String: Any]
        let msgs = dict?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs.last?["content"] as? String, "third")
        XCTAssertEqual(msgs.first?["fromAlias"] as? String, "a")

        // Limit clamps the count.
        let r2 = AssistantTools.dispatch(
            name: "get_channel_messages",
            args: ["channelId": name, "limit": 2],
            enabled: nil)
        guard case .success(let p2) = r2 else { return XCTFail("expected success") }
        let msgs2 = (p2 as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(msgs2.count, 2)

        // sinceTs filters out anything <= the timestamp. Use a point strictly
        // between m2 and m3 (msgs are sent in rapid succession so we can't
        // rely on second-precision rounding of m2.createdAt).
        let cutoff = Date(timeInterval: 0.0001, since: m2.createdAt)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let r3 = AssistantTools.dispatch(
            name: "get_channel_messages",
            args: ["channelId": name, "sinceTs": iso.string(from: cutoff)],
            enabled: nil)
        guard case .success(let p3) = r3 else { return XCTFail("expected success") }
        let msgs3 = (p3 as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        // Allow either m3 alone, or m3+m2 if the system clock granularity
        // collapsed them — assert m3 is present and m1 isn't.
        let contents = msgs3.compactMap { $0["content"] as? String }
        XCTAssertTrue(contents.contains("third"), "expected 'third' in \(contents)")
        XCTAssertFalse(contents.contains("first"), "expected 'first' filtered out, got \(contents)")
    }

    func testGetChannelMessagesTruncatesContentPreview() throws {
        let name = "asst-tool-trunc-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try ChannelRegistry.shared.create(name: name, description: "trunc test", mode: .auto)
        defer { try? ChannelRegistry.shared.delete(name) }
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: "sid-a-\(UUID().uuidString)")
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: "sid-b-\(UUID().uuidString)")

        let huge = String(repeating: "x", count: 5_000)
        _ = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: huge)

        let r = AssistantTools.dispatch(
            name: "get_channel_messages",
            args: ["channelId": name],
            enabled: nil)
        guard case .success(let payload) = r else { return XCTFail("expected success") }
        let msgs = ((payload as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
        XCTAssertEqual(msgs.count, 1)
        let content = msgs[0]["content"] as? String ?? ""
        XCTAssertLessThan(content.utf8.count, huge.utf8.count)
        XCTAssertEqual(msgs[0]["contentTruncated"] as? Bool, true)
    }
}

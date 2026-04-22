import XCTest
import Darwin
@testable import meee2Kit

final class A2ATests: XCTestCase {

    // MARK: - Helpers

    /// 生成无碰撞的频道名（符合校验：小写字母数字+`-`+`_`，<=64）
    private func uniqueChannelName(_ prefix: String = "test") -> String {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        return "\(prefix)-\(suffix)"
    }

    /// 生成一个伪 session UUID
    private func fakeSessionId(_ tag: String) -> String {
        return "sid-\(tag)-\(UUID().uuidString.lowercased())"
    }

    // MARK: - Envelope & rendering

    func testMessageIdFormat() {
        let id = A2AMessage.newId()
        let range = id.range(of: #"^m-[a-f0-9]{8}$"#, options: .regularExpression)
        XCTAssertNotNil(range, "expected ID to match m-<8 hex>, got \(id)")
    }

    func testRenderForInbox() {
        let msg = A2AMessage(
            channel: "review",
            fromAlias: "planner",
            fromSessionId: "sid-xyz",
            toAlias: "coder",
            content: "hello"
        )
        XCTAssertEqual(msg.renderForInbox(), "[a2a from planner via review] hello")
    }

    func testMessageRoundTripCodable() throws {
        let original = A2AMessage(
            id: "m-deadbeef",
            channel: "review",
            fromAlias: "planner",
            fromSessionId: "sid-planner",
            toAlias: "coder",
            content: "ship it",
            replyTo: "m-cafef00d",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .delivered,
            deliveredAt: Date(timeIntervalSince1970: 1_700_000_005),
            deliveredTo: ["coder", "reviewer"],
            injectedByHuman: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(A2AMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.channel, original.channel)
        XCTAssertEqual(decoded.fromAlias, original.fromAlias)
        XCTAssertEqual(decoded.fromSessionId, original.fromSessionId)
        XCTAssertEqual(decoded.toAlias, original.toAlias)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.replyTo, original.replyTo)
        XCTAssertEqual(decoded.status, .delivered)
        XCTAssertEqual(decoded.deliveredTo, ["coder", "reviewer"])
        XCTAssertTrue(decoded.injectedByHuman)
    }

    // MARK: - ChannelRegistry

    func testCreateListGet() throws {
        let name = uniqueChannelName("create")
        defer { try? ChannelRegistry.shared.delete(name) }

        let created = try ChannelRegistry.shared.create(name: name, description: "desc", mode: .auto)
        XCTAssertEqual(created.name, name)
        XCTAssertEqual(created.mode, .auto)

        let fetched = ChannelRegistry.shared.get(name)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.description, "desc")

        XCTAssertTrue(ChannelRegistry.shared.list().contains(where: { $0.name == name }))
    }

    func testCreateDuplicateThrows() throws {
        let name = uniqueChannelName("dup")
        defer { try? ChannelRegistry.shared.delete(name) }

        _ = try ChannelRegistry.shared.create(name: name)
        XCTAssertThrowsError(try ChannelRegistry.shared.create(name: name)) { error in
            guard case ChannelRegistryError.alreadyExists = error else {
                return XCTFail("expected .alreadyExists, got \(error)")
            }
        }
    }

    func testJoinAndLeave() throws {
        let name = uniqueChannelName("join")
        defer { try? ChannelRegistry.shared.delete(name) }

        _ = try ChannelRegistry.shared.create(name: name)
        let aliceSid = fakeSessionId("alice")
        let bobSid = fakeSessionId("bob")

        _ = try ChannelRegistry.shared.join(channel: name, alias: "alice", sessionId: aliceSid)
        let afterBob = try ChannelRegistry.shared.join(channel: name, alias: "bob", sessionId: bobSid)
        XCTAssertEqual(afterBob.members.count, 2)
        XCTAssertEqual(afterBob.memberByAlias("alice")?.sessionId, aliceSid)
        XCTAssertEqual(afterBob.memberBySessionId(bobSid)?.alias, "bob")

        let afterLeave = try ChannelRegistry.shared.leave(channel: name, alias: "alice")
        XCTAssertEqual(afterLeave.members.count, 1)
        XCTAssertEqual(afterLeave.members.first?.alias, "bob")
    }

    func testJoinDuplicateAliasThrows() throws {
        let name = uniqueChannelName("alias")
        defer { try? ChannelRegistry.shared.delete(name) }

        _ = try ChannelRegistry.shared.create(name: name)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "dup", sessionId: fakeSessionId("s1"))
        XCTAssertThrowsError(
            try ChannelRegistry.shared.join(channel: name, alias: "dup", sessionId: fakeSessionId("s2"))
        ) { error in
            guard case ChannelRegistryError.aliasTaken = error else {
                return XCTFail("expected .aliasTaken, got \(error)")
            }
        }
    }

    func testInvalidNameThrows() {
        let invalids = ["", "Has Space", "UPPER", String(repeating: "a", count: 65)]
        for bad in invalids {
            XCTAssertThrowsError(try ChannelRegistry.shared.create(name: bad), "expected invalid: \(bad)") { error in
                guard case ChannelRegistryError.invalidName = error else {
                    return XCTFail("expected .invalidName for '\(bad)', got \(error)")
                }
            }
        }
        // 合法名应通过校验（不抛错）
        for good in ["review", "coder-1", "team_alpha"] {
            XCTAssertNoThrow(try ChannelRegistry.validateName(good), "expected valid: \(good)")
        }
    }

    // MARK: - MessageRouter (auto mode)

    func testSendAutoDeliversToInbox() throws {
        let name = uniqueChannelName("auto")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        let sent = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "ping")
        XCTAssertEqual(sent.status, .delivered)

        let inbox = MessageRouter.shared.drainInbox(sessionId: bSid)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertTrue(inbox[0].renderForInbox().contains("ping"))
        XCTAssertEqual(inbox[0].status, .delivered)
    }

    func testSendStarFanoutExcludesSender() throws {
        let name = uniqueChannelName("fan")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        let cSid = fakeSessionId("c")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            _ = MessageRouter.shared.drainInbox(sessionId: cSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "c", sessionId: cSid)

        let sent = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "*", content: "all")
        XCTAssertEqual(sent.status, .delivered)
        XCTAssertEqual(Set(sent.deliveredTo), Set(["b", "c"]))

        XCTAssertEqual(MessageRouter.shared.drainInbox(sessionId: bSid).count, 1)
        XCTAssertEqual(MessageRouter.shared.drainInbox(sessionId: cSid).count, 1)
        XCTAssertEqual(MessageRouter.shared.drainInbox(sessionId: aSid).count, 0)
    }

    // MARK: - MessageRouter (intercept mode)

    func testInterceptModeHoldsUntilDeliver() throws {
        let name = uniqueChannelName("inter")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .intercept)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        let sent = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "wait")
        XCTAssertEqual(sent.status, .pending)
        XCTAssertTrue(MessageRouter.shared.drainInbox(sessionId: bSid).isEmpty)

        let delivered = try MessageRouter.shared.deliver(sent.id)
        XCTAssertEqual(delivered.status, .delivered)

        let inbox = MessageRouter.shared.drainInbox(sessionId: bSid)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertEqual(inbox[0].id, sent.id)
    }

    // MARK: - MessageRouter (paused mode)

    /// Wave 1 行为：`.paused` 频道下，send() 不会自动投递（保持 pending）；
    /// `deliverPending(id)`（非 force）抛出 `.channelPaused`，
    /// 但 `deliver(id)`（force=true）可以强制投递。核心不变量：消息不会在 paused 频道中自动流动。
    func testPausedModeBlocksDelivery() throws {
        let name = uniqueChannelName("paused")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .paused)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        let sent = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "halt")
        XCTAssertEqual(sent.status, .pending, "paused channel must not auto-deliver")
        XCTAssertTrue(MessageRouter.shared.drainInbox(sessionId: bSid).isEmpty)

        // 非 force 的 deliverPending 必须抛 .channelPaused
        XCTAssertThrowsError(try MessageRouter.shared.deliverPending(sent.id)) { error in
            guard case MessageRouterError.channelPaused = error else {
                return XCTFail("expected .channelPaused, got \(error)")
            }
        }

        // 显式 deliver(id) 使用 force=true，可以穿透
        let forced = try MessageRouter.shared.deliver(sent.id)
        XCTAssertEqual(forced.status, .delivered)
        XCTAssertEqual(MessageRouter.shared.drainInbox(sessionId: bSid).count, 1)
    }

    // MARK: - Human-in-loop mutations

    func testEditAndDrop() throws {
        let name = uniqueChannelName("edit")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .intercept)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        let sent = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "original")

        let edited = try MessageRouter.shared.edit(sent.id, newContent: "x")
        XCTAssertEqual(edited.content, "x")
        XCTAssertEqual(edited.status, .pending)
        XCTAssertEqual(MessageRouter.shared.get(sent.id)?.content, "x")

        let dropped = try MessageRouter.shared.drop(sent.id)
        XCTAssertEqual(dropped.status, .dropped)
        XCTAssertTrue(MessageRouter.shared.drainInbox(sessionId: bSid).isEmpty)

        XCTAssertThrowsError(try MessageRouter.shared.deliver(sent.id)) { error in
            guard case MessageRouterError.alreadyTerminal = error else {
                return XCTFail("expected .alreadyTerminal, got \(error)")
            }
        }
    }

    // MARK: - Drain semantics

    func testDrainIsDestructive() throws {
        let name = uniqueChannelName("drain")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        _ = try MessageRouter.shared.send(channel: name, fromAlias: "a", toAlias: "b", content: "once")

        XCTAssertEqual(MessageRouter.shared.peekInbox(sessionId: bSid).count, 1)
        XCTAssertEqual(MessageRouter.shared.drainInbox(sessionId: bSid).count, 1)
        XCTAssertEqual(MessageRouter.shared.drainInbox(sessionId: bSid).count, 0)
    }

    // MARK: - A2AIdentity (Wave 4)

    func testAliasInChannelResolvesMember() throws {
        let name = uniqueChannelName("id-member")
        let sid = fakeSessionId("me")
        defer {
            unsetenv("CLAUDE_SESSION_ID")
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "planner", sessionId: sid)

        setenv("CLAUDE_SESSION_ID", sid, 1)
        XCTAssertEqual(A2AIdentity.currentSessionId(), sid)
        XCTAssertEqual(A2AIdentity.aliasInChannel(name), "planner")
    }

    func testAliasInChannelReturnsNilForNonMember() throws {
        let name = uniqueChannelName("id-nonmember")
        let sid = fakeSessionId("ghost")
        defer {
            unsetenv("CLAUDE_SESSION_ID")
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        // Intentionally do NOT join this session

        setenv("CLAUDE_SESSION_ID", sid, 1)
        XCTAssertNil(A2AIdentity.aliasInChannel(name))
    }

    func testSoleChannelWithOneMembership() throws {
        let nameA = uniqueChannelName("id-sole-a")
        let nameB = uniqueChannelName("id-sole-b")
        let sid = fakeSessionId("solo")
        defer {
            unsetenv("CLAUDE_SESSION_ID")
            try? ChannelRegistry.shared.delete(nameA)
            try? ChannelRegistry.shared.delete(nameB)
        }

        _ = try ChannelRegistry.shared.create(name: nameA, mode: .auto)
        _ = try ChannelRegistry.shared.create(name: nameB, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: nameA, alias: "only", sessionId: sid)

        setenv("CLAUDE_SESSION_ID", sid, 1)
        XCTAssertEqual(A2AIdentity.soleChannel(), nameA)

        // Add a second membership: now soleChannel must return nil
        _ = try ChannelRegistry.shared.join(channel: nameB, alias: "also", sessionId: sid)
        XCTAssertNil(A2AIdentity.soleChannel())
    }

    func testCurrentSessionIdFromEnv() {
        let sid = fakeSessionId("env")
        defer { unsetenv("CLAUDE_SESSION_ID") }

        setenv("CLAUDE_SESSION_ID", sid, 1)
        XCTAssertEqual(A2AIdentity.currentSessionId(), sid)

        // After unsetting, we don't over-constrain: either nil or a cwd-derived sid.
        unsetenv("CLAUDE_SESSION_ID")
        _ = A2AIdentity.currentSessionId()  // just exercise the path
    }

    // MARK: - AuditLogger

    func testAuditLogsCreated() throws {
        let name = uniqueChannelName("audit-create")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        // intercept 模式：只 create，不触发 delivered，查询结果更干净
        _ = try ChannelRegistry.shared.create(name: name, mode: .intercept)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        let sent = try MessageRouter.shared.send(
            channel: name, fromAlias: "a", toAlias: "b", content: "hi",
            injectedByHuman: false
        )

        let events = AuditLogger.shared.query(msgId: sent.id)
        XCTAssertEqual(events.count, 1, "expected exactly one audit event")
        XCTAssertEqual(events.first?.event, .created)
        XCTAssertEqual(events.first?.actor, "agent:a")
        XCTAssertEqual(events.first?.channel, name)
    }

    func testAuditLogsInjected() throws {
        let name = uniqueChannelName("audit-inject")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .intercept)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        let sent = try MessageRouter.shared.send(
            channel: name, fromAlias: "a", toAlias: "b", content: "human-sent",
            injectedByHuman: true
        )

        let events = AuditLogger.shared.query(msgId: sent.id)
        XCTAssertEqual(events.count, 1, "injected should emit exactly one event, not two")
        XCTAssertEqual(events.first?.event, .injected)
        XCTAssertEqual(events.first?.actor, "human")

        // No .created for this msg
        let createdOnly = events.filter { $0.event == .created }
        XCTAssertTrue(createdOnly.isEmpty, "injected must not also emit .created")
    }

    func testAuditLogsFullLifecycle() throws {
        let name = uniqueChannelName("audit-life")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            try? ChannelRegistry.shared.delete(name)
        }

        // intercept: send -> pending, enables edit/hold/deliver sequence
        _ = try ChannelRegistry.shared.create(name: name, mode: .intercept)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)

        let sent = try MessageRouter.shared.send(
            channel: name, fromAlias: "a", toAlias: "b", content: "v1"
        )
        _ = try MessageRouter.shared.edit(sent.id, newContent: "v1-updated-longer")
        _ = try MessageRouter.shared.hold(sent.id)
        _ = try MessageRouter.shared.deliver(sent.id)

        // query returns newest-first (file order is stable tiebreaker for equal timestamps)
        let events = AuditLogger.shared.query(msgId: sent.id)
        XCTAssertEqual(events.count, 4, "expected 4 lifecycle events, got \(events.count): \(events.map { $0.event })")
        let chronological = Array(events.reversed())
        let types = chronological.map { $0.event }
        XCTAssertEqual(types, [.created, .edited, .held, .delivered],
                       "expected created -> edited -> held -> delivered, got \(types)")
    }

    func testAuditFanoutSingleRecord() throws {
        let name = uniqueChannelName("audit-fan")
        let aSid = fakeSessionId("a")
        let bSid = fakeSessionId("b")
        let cSid = fakeSessionId("c")
        defer {
            _ = MessageRouter.shared.drainInbox(sessionId: aSid)
            _ = MessageRouter.shared.drainInbox(sessionId: bSid)
            _ = MessageRouter.shared.drainInbox(sessionId: cSid)
            try? ChannelRegistry.shared.delete(name)
        }

        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "a", sessionId: aSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "b", sessionId: bSid)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "c", sessionId: cSid)

        let sent = try MessageRouter.shared.send(
            channel: name, fromAlias: "a", toAlias: "*", content: "all"
        )

        let deliveredEvents = AuditLogger.shared.query(msgId: sent.id).filter { $0.event == .delivered }
        XCTAssertEqual(deliveredEvents.count, 1, "fan-out must be ONE delivered event, not N")
        XCTAssertEqual(deliveredEvents.first?.toAlias, "*")
        let details = deliveredEvents.first?.details ?? ""
        XCTAssertTrue(details.contains("fanout="), "expected details to contain 'fanout=', got: \(details)")
        XCTAssertTrue(details.contains("b"))
        XCTAssertTrue(details.contains("c"))
    }
}

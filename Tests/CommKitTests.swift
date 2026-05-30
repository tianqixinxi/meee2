import XCTest
@testable import meee2Kit
import Meee2CommKit

/// 测试 meee2-comm-kit 抽出后新增的两个抽象:
///   1. InboxPushDelegate 注册/分发/weak 清理
///   2. IdentityResolver 注入
///
/// 跟 A2ATests 一样用 MessageRouter.shared 单例,通过唯一 channel 名 + drain
/// 隔离副作用。
final class CommKitTests: XCTestCase {

    // MARK: - Helpers

    private func uniqueChannelName(_ prefix: String = "ckit") -> String {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        return "\(prefix)-\(suffix)"
    }

    private func fakeSessionId(_ tag: String) -> String {
        return "sid-\(tag)-\(UUID().uuidString.lowercased())"
    }

    /// 删除某 channel 在 ~/.meee2/messages/<name>/ 下的消息封装目录。
    /// ChannelRegistry.delete() 只删 channel 文件,不动 MessageRouter 的
    /// 消息存储 —— 这是 production 行为(channel 删了消息历史保留供审计),
    /// 但测试不需要,这里手动清。
    private func purgeChannelMessages(_ name: String) {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2")
            .appendingPathComponent("messages")
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Spy delegate:把每次 handleInboxPush 收到的 (sid, msgId) 记录下来。
    private final class SpyDelegate: InboxPushDelegate {
        var calls: [(sessionId: String, messageId: String)] = []
        let lock = NSLock()
        func handleInboxPush(sessionId: String, message: A2AMessage) {
            lock.lock(); defer { lock.unlock() }
            calls.append((sessionId, message.id))
        }
    }

    /// 二元 channel 的初始化模板。channel 在测试结束后通过
    /// `addTeardownBlock` 自动删除,避免 ~/.meee2/channels/ 残留。
    private func makePairChannel(
        aliasA: String = "alpha",
        aliasB: String = "beta"
    ) throws -> (channel: String, sidA: String, sidB: String) {
        let name = uniqueChannelName()
        let sidA = fakeSessionId("a")
        let sidB = fakeSessionId("b")
        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: name, alias: aliasA, sessionId: sidA)
        _ = try ChannelRegistry.shared.join(channel: name, alias: aliasB, sessionId: sidB)
        addTeardownBlock { [name, sidA, sidB, weak self] in
            _ = MessageRouter.shared.drainInbox(sessionId: sidA)
            _ = MessageRouter.shared.drainInbox(sessionId: sidB)
            try? ChannelRegistry.shared.delete(name)
            self?.purgeChannelMessages(name)
        }
        // 清干净 inbox(orientation 推送默认 noop,但保险起见)
        _ = MessageRouter.shared.drainInbox(sessionId: sidA)
        _ = MessageRouter.shared.drainInbox(sessionId: sidB)
        return (name, sidA, sidB)
    }

    // MARK: - InboxPushDelegate

    /// 注册一个 delegate -> send 消息 -> delegate 收到对应 (sid, msgId)。
    func testPushDelegate_calledOnDelivery() throws {
        let pair = try makePairChannel()
        let spy = SpyDelegate()
        MessageRouter.shared.registerPushDelegate(spy)
        defer { MessageRouter.shared.unregisterPushDelegate(spy) }

        let sent = try MessageRouter.shared.send(
            channel: pair.channel, fromAlias: "alpha", toAlias: "beta", content: "ping"
        )

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.sessionId, pair.sidB)
        XCTAssertEqual(spy.calls.first?.messageId, sent.id)
    }

    /// 注册两个 delegate,每个 send 都会通知两次。
    func testPushDelegate_multipleDelegatesAllCalled() throws {
        let pair = try makePairChannel()
        let s1 = SpyDelegate()
        let s2 = SpyDelegate()
        MessageRouter.shared.registerPushDelegate(s1)
        MessageRouter.shared.registerPushDelegate(s2)
        defer {
            MessageRouter.shared.unregisterPushDelegate(s1)
            MessageRouter.shared.unregisterPushDelegate(s2)
        }

        _ = try MessageRouter.shared.send(
            channel: pair.channel, fromAlias: "alpha", toAlias: "beta", content: "hi"
        )

        XCTAssertEqual(s1.calls.count, 1)
        XCTAssertEqual(s2.calls.count, 1)
        XCTAssertEqual(s1.calls.first?.sessionId, pair.sidB)
        XCTAssertEqual(s2.calls.first?.sessionId, pair.sidB)
    }

    /// 同一个 delegate 重复 register 不会被叠加 —— 实现里有 `removeAll{ === self }`。
    /// 一次 send 对它只触发一次 callback。
    func testPushDelegate_doubleRegister_dedupes() throws {
        let pair = try makePairChannel()
        let spy = SpyDelegate()
        MessageRouter.shared.registerPushDelegate(spy)
        MessageRouter.shared.registerPushDelegate(spy)  // 重复 register
        defer { MessageRouter.shared.unregisterPushDelegate(spy) }

        XCTAssertEqual(MessageRouter.shared.pushDelegateCount, 1, "重复 register 应该 dedupe")

        _ = try MessageRouter.shared.send(
            channel: pair.channel, fromAlias: "alpha", toAlias: "beta", content: "x"
        )
        XCTAssertEqual(spy.calls.count, 1)
    }

    /// 显式 unregister 后,后续 send 不再触发。
    func testPushDelegate_unregister_stopsDispatch() throws {
        let pair = try makePairChannel()
        let spy = SpyDelegate()
        MessageRouter.shared.registerPushDelegate(spy)
        MessageRouter.shared.unregisterPushDelegate(spy)

        _ = try MessageRouter.shared.send(
            channel: pair.channel, fromAlias: "alpha", toAlias: "beta", content: "after-unregister"
        )

        XCTAssertEqual(spy.calls.count, 0)
    }

    /// 强引用释放后,WeakInboxPushDelegate 自动清理 —— pushDelegateCount 反映真实存活数。
    func testPushDelegate_weakRef_autoCleanup() throws {
        var spy: SpyDelegate? = SpyDelegate()
        MessageRouter.shared.registerPushDelegate(spy!)
        XCTAssertEqual(MessageRouter.shared.pushDelegateCount, 1)

        spy = nil  // 释放唯一强引用
        XCTAssertEqual(MessageRouter.shared.pushDelegateCount, 0, "weak 引用应在 dealloc 后被自动清理")
    }

    /// 广播(toAlias = "*")应给每个非发送方成员都触发一次 push。
    func testPushDelegate_broadcastFanout() throws {
        let name = uniqueChannelName()
        let sidA = fakeSessionId("a")
        let sidB = fakeSessionId("b")
        let sidC = fakeSessionId("c")
        _ = try ChannelRegistry.shared.create(name: name, mode: .auto)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "alpha", sessionId: sidA)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "beta", sessionId: sidB)
        _ = try ChannelRegistry.shared.join(channel: name, alias: "gamma", sessionId: sidC)
        addTeardownBlock { [name, sidA, sidB, sidC, weak self] in
            for sid in [sidA, sidB, sidC] {
                _ = MessageRouter.shared.drainInbox(sessionId: sid)
            }
            try? ChannelRegistry.shared.delete(name)
            self?.purgeChannelMessages(name)
        }
        for sid in [sidA, sidB, sidC] {
            _ = MessageRouter.shared.drainInbox(sessionId: sid)
        }

        let spy = SpyDelegate()
        MessageRouter.shared.registerPushDelegate(spy)
        defer { MessageRouter.shared.unregisterPushDelegate(spy) }

        _ = try MessageRouter.shared.send(
            channel: name, fromAlias: "alpha", toAlias: "*", content: "everybody"
        )

        XCTAssertEqual(spy.calls.count, 2, "广播给 2 个非发送方成员,触发 2 次 push")
        let recipientSids = Set(spy.calls.map { $0.sessionId })
        XCTAssertEqual(recipientSids, Set([sidB, sidC]))
    }

    /// Paused 频道的消息不应触发 push(消息保留 .pending,delegate 不该收到通知)。
    func testPushDelegate_pausedChannel_noPush() throws {
        let pair = try makePairChannel()
        let spy = SpyDelegate()
        MessageRouter.shared.registerPushDelegate(spy)
        defer { MessageRouter.shared.unregisterPushDelegate(spy) }

        _ = try ChannelRegistry.shared.setMode(pair.channel, mode: .paused)
        _ = try MessageRouter.shared.send(
            channel: pair.channel, fromAlias: "alpha", toAlias: "beta", content: "held"
        )

        XCTAssertEqual(spy.calls.count, 0, "paused 频道里的消息不应触发 push")
    }

    // MARK: - IdentityResolver

    /// 一个简单的 stub IdentityResolver。
    private final class StubResolver: IdentityResolver {
        let byCwd: [String: [String]]

        init(byCwd: [String: [String]] = [:]) {
            self.byCwd = byCwd
        }

        func sessionsForCwd(_ cwd: String) -> [String] { byCwd[cwd] ?? [] }
    }

    /// 注入一个 stub resolver,A2AIdentity.currentSessionId() 在 cwd 路径上能命中。
    /// 注意:测试只覆盖 cwd 解析逻辑,不去动 ProcessInfo 环境变量(env 路径已有
    /// `testCurrentSessionIdFromEnv` 测过)。
    func testIdentityResolver_cwdMatch_returnsSessionId() {
        // 备份现状 —— 别污染其它测试
        let prior = A2AIdentity.resolver
        defer { A2AIdentity.resolver = prior }

        let cwd = FileManager.default.currentDirectoryPath
        let expected = "sid-resolver-\(UUID().uuidString.prefix(6))"
        let stub = StubResolver(byCwd: [cwd: [expected]])
        A2AIdentity.resolver = stub

        // 必须先把环境变量清空,否则 env 优先于 cwd
        let envBackup = ProcessInfo.processInfo.environment
        unsetenv("CLAUDE_SESSION_ID")
        unsetenv("CODEX_THREAD_ID")
        unsetenv("CODEX_SESSION_ID")
        defer {
            for (k, v) in envBackup { setenv(k, v, 1) }
        }

        XCTAssertEqual(A2AIdentity.currentSessionId(), expected)
        XCTAssertEqual(A2AIdentity.resolve().sessionId, expected)
        XCTAssertEqual(A2AIdentity.resolve().source, .cwdMatch)
    }

    /// 没注入 resolver -> cwd 路径返回 nil(env 也清空)。
    func testIdentityResolver_notInstalled_cwdReturnsNil() {
        let prior = A2AIdentity.resolver
        defer { A2AIdentity.resolver = prior }
        A2AIdentity.resolver = nil

        let envBackup = ProcessInfo.processInfo.environment
        unsetenv("CLAUDE_SESSION_ID")
        unsetenv("CODEX_THREAD_ID")
        unsetenv("CODEX_SESSION_ID")
        defer {
            for (k, v) in envBackup { setenv(k, v, 1) }
        }

        XCTAssertNil(A2AIdentity.currentSessionId())
        XCTAssertEqual(A2AIdentity.resolve().source, .unresolved)
    }

    /// resolver 返回多个 match -> ambiguous,fallback 到 nil。
    func testIdentityResolver_ambiguous_returnsNil() {
        let prior = A2AIdentity.resolver
        defer { A2AIdentity.resolver = prior }

        let cwd = FileManager.default.currentDirectoryPath
        let stub = StubResolver(byCwd: [cwd: ["sid-one", "sid-two"]])
        A2AIdentity.resolver = stub

        let envBackup = ProcessInfo.processInfo.environment
        unsetenv("CLAUDE_SESSION_ID")
        unsetenv("CODEX_THREAD_ID")
        unsetenv("CODEX_SESSION_ID")
        defer {
            for (k, v) in envBackup { setenv(k, v, 1) }
        }

        XCTAssertNil(A2AIdentity.currentSessionId(), "多个匹配应当 fallback 到 nil")
    }

    /// SessionStoreIdentityResolver(主仓侧实现)能透过 SessionStore 反查。
    /// 不写入真实 SessionStore(会污染 ~/.meee2);只验证类型链通顺,以及空
    /// 输入返回空列表。
    func testSessionStoreIdentityResolver_emptyForUnknownCwd() {
        let resolver = SessionStoreIdentityResolver()
        let result = resolver.sessionsForCwd("/nonexistent/path/\(UUID().uuidString)")
        XCTAssertEqual(result, [])
    }
}

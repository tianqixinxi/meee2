import XCTest
import Combine
@testable import meee2Kit
import Meee2CommKit
import Meee2PluginKit

/// 覆盖 CR fix-cr-2 (P2 by chatgpt-codex-connector):
/// "Clear live stores when deleting local data" —— 删本地数据后必须同步清掉
/// SessionStore.shared.sessions 和 BoardLayoutStore 的内存缓存,否则 UI
/// 会继续展示已被删除的 session,并把脏数据回写到 ~/.meee2.
///
/// 这里直接测两个新加的 in-memory clear hook (`SessionStore.clearAllInMemory`
/// + `BoardLayoutStore.clearInMemoryCache`),不去真删 `~/.meee2` —— 跑测试
/// 的人不能丢掉自己的本地数据。`deleteLocalData` 的"删盘 → 清内存 → 广播"
/// 端到端流程由手测覆盖 (Settings → Privacy → Delete)。
final class SystemStorageAPITests: XCTestCase {
    func testClearAllInMemoryWipesSessionsAndEmitsRemovedEvents() {
        let store = SessionStore.shared

        // 备份现有 sessions —— SessionStore.shared 是 process-wide singleton,
        // 不能因为这个测试擦掉别的测试在内存里铺好的 fixture。
        let backup = store.sessions
        defer {
            store.sessions = backup
        }

        let sidA = "delete-local-test-a-\(UUID().uuidString)"
        let sidB = "delete-local-test-b-\(UUID().uuidString)"

        store.sessions = [
            makeSession(id: sidA),
            makeSession(id: sidB)
        ]
        XCTAssertEqual(store.sessions.count, 2, "precondition: store has two sessions in memory")

        // 订阅 SessionEventBus,验证 clearAllInMemory 会为每条 session 发
        // .sessionRemoved 事件,触发 BoardServer 等下游 debounce 刷新。
        let exp = expectation(description: "sessionRemoved fired twice")
        exp.expectedFulfillmentCount = 2
        var removedIds: [String] = []
        let removedQueue = DispatchQueue(label: "test.removed.collect")
        let cancellable = SessionEventBus.shared.publisher.sink { event in
            if case .sessionRemoved(let sid) = event {
                removedQueue.sync { removedIds.append(sid) }
                exp.fulfill()
            }
        }
        defer { cancellable.cancel() }

        store.clearAllInMemory()

        XCTAssertTrue(store.sessions.isEmpty, "clearAllInMemory should empty sessions array")
        wait(for: [exp], timeout: 2.0)
        let captured = removedQueue.sync { removedIds }
        XCTAssertTrue(captured.contains(sidA))
        XCTAssertTrue(captured.contains(sidB))
    }

    func testBoardLayoutStoreClearInMemoryCacheEmitsLayoutChanged() {
        // BoardLayoutStore.shared 的 cached field 是 private —— 我们只能
        // 从外部观测它的可见副作用:调用 clearInMemoryCache 后必须广播
        // .boardLayoutChanged,让 BoardServer 推 state.changed 到 React。
        let exp = expectation(description: "boardLayoutChanged emitted")
        let cancellable = SessionEventBus.shared.publisher.sink { event in
            if case .boardLayoutChanged = event {
                exp.fulfill()
            }
        }
        defer { cancellable.cancel() }

        BoardLayoutStore.shared.clearInMemoryCache()

        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - helpers

    private func makeSession(id: String) -> SessionData {
        SessionData(
            sessionId: id,
            project: "delete-local-test",
            cwd: "/tmp/delete-local-test",
            pid: nil,
            ghosttyTerminalId: nil,
            iTermSessionId: nil,
            appleTerminalSessionId: nil,
            transcriptPath: nil,
            startedAt: Date(),
            lastActivity: Date(),
            status: .idle,
            currentTool: nil,
            description: nil,
            tasks: [],
            currentTask: nil,
            terminalInfo: nil,
            usageStats: nil,
            lastMessage: nil
        )
    }
}

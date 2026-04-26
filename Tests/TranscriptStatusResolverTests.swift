import XCTest
@testable import meee2Kit
import Meee2PluginKit

/// TranscriptStatusResolver 的规则矩阵测试。
///
/// 覆盖的是 `decideFromTail(last:, hookStatus:, now:)` —— 纯函数，不做文件 I/O
/// 也不碰 AppleScript/进程检查。三个 case ("user" / "assistant" / "system") 内的
/// 每条优先级分支各至少一条测试 + 边界值。
///
/// 顺带测 `findLastRelevantEntry(tail:)` 对 transcript tail 字符串的解析：
/// 跳过 isMeta / bash-input 标记，识别 "[Request interrupted by user]" marker。
final class TranscriptStatusResolverTests: XCTestCase {

    // 基准时间（用这个做所有老化年龄的锚点）
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        type: String,
        interrupt: Bool = false,
        ageSeconds: TimeInterval? = 0
    ) -> LastEntry {
        let ts = ageSeconds.map { now.addingTimeInterval(-$0) }
        return LastEntry(type: type, isInterrupt: interrupt, timestamp: ts)
    }

    // MARK: - case "user"

    /// priority 1: [Request interrupted by user] marker 立即降级 idle
    func testUser_interrupt_downgradesToIdleImmediately() {
        let (status, reason) = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "user", interrupt: true, ageSeconds: 2),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(status, .idle)
        XCTAssertTrue(reason.contains("interrupt"), "reason='\(reason)'")
    }

    /// priority 2: age > 180s (abandoned) 无论 hookStatus 都降 idle
    func testUser_tooOld_abandoned() {
        for hook in [SessionStatus.thinking, .tooling, .active, .idle] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "user", ageSeconds: 200),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .idle, "hook=\(hook) 应该降级 idle")
            XCTAssertTrue(reason.contains("user-too-old"), "reason='\(reason)'")
        }
    }

    /// priority 3: hook=thinking + age > 45s = ESC-before-first-token，降 idle
    func testUser_staleThinking_escBeforeFirstToken() {
        let (status, reason) = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "user", ageSeconds: 60),  // >45s, <180s
            hookStatus: .thinking,
            now: now
        )
        XCTAssertEqual(status, .idle)
        XCTAssertTrue(reason.contains("user-stale-pre-assistant"), "reason='\(reason)'")
    }

    /// priority 3 边界：age = 45s 时不触发（严格 >）；== 45.1s 触发
    func testUser_staleThinking_boundary() {
        // 刚好 45s —— 不触发（条件是严格 >）
        let borderline = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "user", ageSeconds: 45),
            hookStatus: .thinking,
            now: now
        )
        XCTAssertEqual(borderline.status, .thinking, "45s 边界不应触发降级")

        // 45.5s → 触发
        let over = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "user", ageSeconds: 45.5),
            hookStatus: .thinking,
            now: now
        )
        XCTAssertEqual(over.status, .idle, "45.5s 应触发降级")
    }

    /// priority 3 仅在 hook=.thinking 时生效；.tooling 不走这条兜底
    func testUser_staleThinking_onlyAppliesToThinking() {
        // hook=tooling + user tail 60s 老 → 应该保留 tooling (走 priority 4)
        let (status, reason) = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "user", ageSeconds: 60),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(status, .tooling)
        XCTAssertTrue(reason.contains("hook-specific(tooling)"), "reason='\(reason)'")
    }

    /// priority 4: isSpecific(hookStatus) → 保留 hook
    func testUser_recent_preservesSpecificHookStatus() {
        for hook in [SessionStatus.thinking, .tooling, .permissionRequired, .compacting] {
            let (status, _) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "user", ageSeconds: 5),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, hook, "recent user + hook=\(hook) 应该保留 hook")
        }
    }

    /// priority 5 (fallback): 非 specific hook + recent user → .active
    func testUser_recent_fallsToActiveForGenericHook() {
        for hook in [SessionStatus.idle, .completed, .waitingForUser, .active] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "user", ageSeconds: 5),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .active, "hook=\(hook) 应该 fallback active")
            XCTAssertTrue(reason.contains("user-recent"), "reason='\(reason)'")
        }
    }

    /// user tail 无时间戳：走 priority 4/5（timestamp 缺失的 age 判断跳过）
    func testUser_noTimestamp_treatedAsRecent() {
        let (status, _) = TranscriptStatusResolver.decideFromTail(
            last: LastEntry(type: "user", isInterrupt: false, timestamp: nil),
            hookStatus: .thinking,
            now: now
        )
        XCTAssertEqual(status, .thinking, "无 timestamp 应当不走 stale 兜底")
    }

    // MARK: - case "assistant"

    /// priority 1: hook ∈ {idle, completed, waitingForUser} + assistant tail → .active (mid-turn override)
    func testAssistant_midTurn_overridesRestingHook() {
        for hook in [SessionStatus.idle, .completed, .waitingForUser] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "assistant", ageSeconds: 3),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .active, "hook=\(hook) + assistant tail 应升到 active")
            XCTAssertTrue(reason.contains("mid-turn"), "reason='\(reason)'")
        }
    }

    /// priority 2: hook 是工作态 → 保留 hookStatus（只要 tail 还新鲜）
    func testAssistant_workingHook_passesThrough() {
        for hook in [SessionStatus.thinking, .tooling, .compacting, .permissionRequired] {
            let (status, _) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "assistant", ageSeconds: 3),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, hook, "hook=\(hook) 应保留")
        }
    }

    /// ESC-mid-stream 兜底：tail 是 assistant 超过 60s 且 hook 是工作态 → .idle
    /// 正常 streaming 每秒追写，60s+ 没动 = Claude 被打断了
    func testAssistant_staleMidStream_escDuringStreaming() {
        for hook in [SessionStatus.thinking, .tooling, .active, .compacting] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "assistant", ageSeconds: 80),  // >60s
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .idle, "hook=\(hook) + assistant tail 80s 应降 idle")
            XCTAssertTrue(reason.contains("assistant-tail-stale"), "reason='\(reason)'")
        }
    }

    /// assistant stale 60s 边界
    func testAssistant_staleMidStream_boundary() {
        let borderline = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "assistant", ageSeconds: 60),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(borderline.status, .tooling, "60s 边界不应触发")

        let over = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "assistant", ageSeconds: 61),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(over.status, .idle, "61s 应触发")
    }

    /// assistant stale 规则只对工作态 hook 生效；permissionRequired 不降级
    /// （permission 是"等用户"的合法长期状态，不是被 ESC 卡住）
    func testAssistant_staleMidStream_skipsPermission() {
        let (status, _) = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "assistant", ageSeconds: 120),
            hookStatus: .permissionRequired,
            now: now
        )
        XCTAssertEqual(status, .permissionRequired, "permission 不应被 stale 兜底误伤")
    }

    // MARK: - case "system"

    /// priority 1: system tail 老于 90s + 工作态 hookStatus → .idle (ESC-during-tool 兜底)
    func testSystem_stale_escDuringTool() {
        for hook in [SessionStatus.thinking, .tooling, .active, .compacting] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "system", ageSeconds: 120),  // >90s
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .idle, "hook=\(hook) + system tail >90s 应降 idle")
            XCTAssertTrue(reason.contains("system-tail-stale"), "reason='\(reason)'")
        }
    }

    /// priority 1 边界：90s 不触发，91s 触发
    func testSystem_stale_boundary() {
        let borderline = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "system", ageSeconds: 90),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(borderline.status, .tooling, "90s 不应触发")

        let over = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "system", ageSeconds: 91),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(over.status, .idle, "91s 应触发")
    }

    /// priority 2: hook=.active + system tail（即使 <90s）→ .idle
    func testSystem_activeHook_forcesIdle() {
        let (status, reason) = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "system", ageSeconds: 10),  // 不触发 stale
            hookStatus: .active,
            now: now
        )
        XCTAssertEqual(status, .idle)
        XCTAssertTrue(reason.contains("force-idle"), "reason='\(reason)'")
    }

    /// priority 3: 休息态 hook + system tail recent → 保留 hookStatus
    func testSystem_restingHook_passesThrough() {
        for hook in [SessionStatus.idle, .completed, .waitingForUser] {
            let (status, _) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "system", ageSeconds: 10),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, hook, "hook=\(hook) 应保留")
        }
    }

    // MARK: - case default (unknown type)

    func testUnknownType_preservesHookStatus() {
        let (status, reason) = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "bizarre-future-type", ageSeconds: 10),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(status, .tooling)
        XCTAssertTrue(reason.contains("unknown-type"), "reason='\(reason)'")
    }

    // MARK: - findLastRelevantEntry（tail 解析）

    /// 基础：单条 user entry
    func testFindLast_singleUser() {
        let tail = #"""
        {"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-04-24T10:00:00Z"}
        """#
        let entry = findLastRelevantEntry(tail: tail)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.type, "user")
        XCTAssertFalse(entry?.isInterrupt ?? true)
    }

    /// 识别 `[Request interrupted by user]` marker
    func testFindLast_recognizesInterruptMarker() {
        let tail = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-04-24T10:00:00Z"}
        """#
        let entry = findLastRelevantEntry(tail: tail)
        XCTAssertEqual(entry?.type, "user")
        XCTAssertTrue(entry?.isInterrupt ?? false)
    }

    /// 跳过 isMeta=true 的 user entry（本地 !bash 命令）。
    /// 注意：findLastRelevantEntry 会丢掉 tail 的第一行防 4KB 切断，所以 fixture
    /// 必须 ≥ 3 行才能让"第 2 条"和"第 3 条"都进入 relevant 扫描。
    func testFindLast_skipsMetaUsers() {
        let tail = """
        {"type":"filler-will-be-dropped"}
        {"type":"user","message":{"role":"user","content":"real prompt"},"timestamp":"2026-04-24T10:00:00Z"}
        {"type":"user","message":{"role":"user","content":"!ls"},"isMeta":true,"timestamp":"2026-04-24T10:01:00Z"}
        """
        let entry = findLastRelevantEntry(tail: tail)
        // 最新 entry 是 isMeta，应跳到前一条 real prompt
        XCTAssertEqual(entry?.type, "user")
        XCTAssertFalse(entry?.isInterrupt ?? true)
    }

    /// 跳过 <bash-input> / <bash-stdout> 包装的 user entry
    func testFindLast_skipsBashMarkerUsers() {
        let tail = """
        {"type":"filler-will-be-dropped"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]},"timestamp":"2026-04-24T09:59:00Z"}
        {"type":"user","message":{"role":"user","content":"<bash-input>ls</bash-input>"},"timestamp":"2026-04-24T10:00:00Z"}
        """
        let entry = findLastRelevantEntry(tail: tail)
        // bash-input wrapped user entry 应被跳过 → 返回 assistant
        XCTAssertEqual(entry?.type, "assistant")
    }

    /// 完全没有 user/assistant/system 条目时返回 nil
    func testFindLast_noRelevantEntry() {
        let tail = #"""
        {"type":"file-history-snapshot"}
        {"type":"permission-mode"}
        """#
        let entry = findLastRelevantEntry(tail: tail)
        XCTAssertNil(entry)
    }

    /// tail 首行可能被 4KB 切断：findLastRelevantEntry 应主动跳过第一行
    func testFindLast_skipsPotentiallyTruncatedFirstLine() {
        let tail = """
        ld":"2026-04-24T09:58:00Z"}
        {"type":"user","message":{"role":"user","content":"real"},"timestamp":"2026-04-24T10:00:00Z"}
        """
        let entry = findLastRelevantEntry(tail: tail)
        XCTAssertEqual(entry?.type, "user")
    }
}

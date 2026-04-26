import XCTest
@testable import Meee2Core
@testable import ClaudeCLIAdapter
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

    /// priority 2: age > 180s + hook 是 resting（idle / waitingForUser /
    /// completed）→ 降 idle（user-too-old）。这是"用户打字后走了没等"场景。
    func testUser_tooOld_abandoned_whenHookResting() {
        for hook in [SessionStatus.idle, .waitingForUser, .completed] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "user", ageSeconds: 200),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .idle, "hook=\(hook) 应该降级 idle")
            XCTAssertTrue(reason.contains("user-too-old"), "reason='\(reason)'")
        }
    }

    /// priority 2 守卫：age > 180s 但 hook 报 working（thinking / tooling /
    /// active / compacting）→ trust hook，**不**误降 idle。
    /// 真实场景：Claude 跑长工具链 / extended thinking，user 在尾巴 N 分钟前，
    /// 但 PreToolUse 还在喷——这是真活，必须保留 working state。
    func testUser_tooOld_butHookWorking_trustsHook() {
        for hook in [SessionStatus.thinking, .tooling, .active, .compacting] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "user", ageSeconds: 246),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, hook, "hook=\(hook) working 时应 trust hook，不降 idle, got reason='\(reason)'")
            XCTAssertTrue(reason.contains("hook-working"), "reason='\(reason)'")
        }
    }

    /// 历史 stale-thinking 规则（hook=thinking + age>45s → idle）已删除。
    /// 现在只要在 abandoned 阈值（180s）以内 + hook=thinking，永远报 thinking——
    /// 防止 Opus extended thinking / 长 context 等 60-180s 才 first token 的
    /// 场景被错翻 idle 显示成"等用户输入"。
    func testUser_thinking_stayThinkingUntilAbandoned() {
        // 60s, 120s, 170s 都应该返回 thinking，不再降级 idle
        for age in [60.0, 120.0, 170.0] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "user", ageSeconds: age),
                hookStatus: .thinking,
                now: now
            )
            XCTAssertEqual(status, .thinking, "age=\(age)s + hook=thinking 应保留 thinking, got reason='\(reason)'")
        }
    }

    /// hook=tooling + user tail 60s 老 → 保留 tooling (priority 3 / hook-specific)
    func testUser_recent_tooling() {
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

    /// priority 1: hook ∈ {idle, completed, waitingForUser} + FRESH assistant tail → .active (mid-turn override)
    func testAssistant_midTurn_overridesRestingHook() {
        for hook in [SessionStatus.idle, .completed, .waitingForUser] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "assistant", ageSeconds: 3),
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .active, "hook=\(hook) + fresh assistant tail 应升到 active")
            XCTAssertTrue(reason.contains("mid-turn"), "reason='\(reason)'")
        }
    }

    /// 回归：stale assistant tail（远超 mid-turn freshness 窗）+ resting hook
    /// 必须保留 hookStatus，不能误升 active。
    /// 旧 bug：1.3 hours 前的 assistant tail + hook=waitingForUser 被错升 active
    /// → UI 上显示 "live" 绿条，用户以为 session 还在跑。
    func testAssistant_staleMidTurn_doesNotOverrideRestingHook() {
        for hook in [SessionStatus.idle, .completed, .waitingForUser] {
            let (status, _) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "assistant", ageSeconds: 60),  // >30s freshness window
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, hook, "stale assistant tail 不应升级 hook=\(hook) → active")
        }
    }

    /// mid-turn freshness 窗的 30s 边界
    func testAssistant_midTurn_freshnessBoundary() {
        // 29s 内仍算 fresh → 升 active
        let fresh = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "assistant", ageSeconds: 29),
            hookStatus: .waitingForUser,
            now: now
        )
        XCTAssertEqual(fresh.status, .active, "29s 仍在 freshness 窗内")

        // 31s 已过窗 → 保留 hook
        let stale = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "assistant", ageSeconds: 31),
            hookStatus: .waitingForUser,
            now: now
        )
        XCTAssertEqual(stale.status, .waitingForUser, "31s 已过 freshness 窗")
    }

    /// 无 timestamp 的 assistant tail 保守视为 fresh（不知道多老就当还活着）
    func testAssistant_midTurn_noTimestampFallsBackToFresh() {
        let (status, _) = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "assistant", ageSeconds: nil),
            hookStatus: .waitingForUser,
            now: now
        )
        XCTAssertEqual(status, .active, "无 ts 应保守视为 fresh，仍触发 mid-turn")
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

    /// priority 1: system tail 老于 600s + 工作态 hookStatus → .idle
    /// 阈值从 90s 提到 600s—— 90s 误降太多合法长 Bash / extended thinking。
    /// 真挂的 session 一般 10 分钟没人耐心等了。
    func testSystem_stale_escDuringTool() {
        for hook in [SessionStatus.thinking, .tooling, .active, .compacting] {
            let (status, reason) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "system", ageSeconds: 700),  // >600s
                hookStatus: hook,
                now: now
            )
            XCTAssertEqual(status, .idle, "hook=\(hook) + system tail >600s 应降 idle")
            XCTAssertTrue(reason.contains("system-tail-stale"), "reason='\(reason)'")
        }
    }

    /// priority 1 边界：600s 不触发，601s 触发
    func testSystem_stale_boundary() {
        let borderline = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "system", ageSeconds: 600),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(borderline.status, .tooling, "600s 不应触发")

        let over = TranscriptStatusResolver.decideFromTail(
            last: entry(type: "system", ageSeconds: 601),
            hookStatus: .tooling,
            now: now
        )
        XCTAssertEqual(over.status, .idle, "601s 应触发")
    }

    /// 回归：90-600s 之间的 system tail + hook=tooling 必须保留 tooling
    /// （之前 90s 阈值时 100s 也降级，长 Bash 命令被误判 idle）。
    func testSystem_longRunningTool_notDowngraded() {
        for age in [100.0, 200.0, 400.0, 599.0] {
            let (status, _) = TranscriptStatusResolver.decideFromTail(
                last: entry(type: "system", ageSeconds: age),
                hookStatus: .tooling,
                now: now
            )
            XCTAssertEqual(status, .tooling, "age=\(age)s + hook=tooling 不应降级")
        }
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

import XCTest
@testable import meee2Kit

/// 同一 cliSessionId 在 Claude Desktop 端能并存多个 `local_<uuid>.json`
/// wrapper：
///   - "primary" 名为 local_<cliSessionId>.json —— resume 入口创建，title=null
///     但 timestamp 最新
///   - "named"   名为 local_<random>.json     —— Desktop UI 命名后产物，
///     有人类可读 title，timestamp 较旧
///   - 老 wrapper 可能是 archived（用户在 Desktop UI 标过）
///
/// 历史现场：
///   1. 2026-05-04: archived 旧 wrapper 抢 index 槽 → /api/state 把整条
///      cliSessionId 当 archived 过滤掉 → 当前 dev session 在 webui 里消失。
///   2. 第一版修复（pick 一个 wrapper，preferUnarchived + lastActivity）
///      让无 title 的 primary 抢赢 → webui 上人类 title 全丢。
///
/// 现在 mergeMetadata 是字段级合并，不再"挑一个"——这一组 case 锁住合并行为。
final class ClaudeDesktopMetadataReaderTests: XCTestCase {

    private func makeMeta(
        cliSid: String = "9d0f0185-9886-47cd-919f-a567c45b130f",
        wrapper: String,
        title: String = "(untitled)",
        isArchived: Bool = false,
        lastActivity: Date? = nil
    ) -> ClaudeDesktopMetadata {
        ClaudeDesktopMetadata(
            cliSessionId: cliSid,
            title: title,
            model: nil,
            cwd: "/Users/test/meee2",
            isArchived: isArchived,
            desktopSessionId: "local_\(wrapper)",
            lastActivityAt: lastActivity,
            transcriptPath: nil
        )
    }

    /// 单条直接返回。
    func testSingleWrapper_PassThrough() {
        let only = makeMeta(wrapper: "only", title: "Hello", isArchived: false)
        let merged = ClaudeDesktopMetadataReader.mergeMetadata([only])
        XCTAssertEqual(merged?.title, "Hello")
        XCTAssertEqual(merged?.isArchived, false)
    }

    /// 空输入返回 nil（调用方上游 group-by 不应该传空，但保险）。
    func testEmpty_ReturnsNil() {
        XCTAssertNil(ClaudeDesktopMetadataReader.mergeMetadata([]))
    }

    /// 现场原型：primary wrapper 没 title 但更新；named wrapper 有 title 但
    /// 更早。合并后 title 必须从 named 那条带过来，不掉到 "(untitled)"。
    func testNullTitlePrimaryAndNamedWrapper_MergedTitleWins() {
        let primary = makeMeta(
            wrapper: "9d0f0185",
            title: "(untitled)",
            isArchived: false,
            lastActivity: Date(timeIntervalSince1970: 2_000_000)
        )
        let named = makeMeta(
            wrapper: "a8df88ee",
            title: "Move session card input to canvas area",
            isArchived: false,
            lastActivity: Date(timeIntervalSince1970: 1_000_000)
        )
        let merged = ClaudeDesktopMetadataReader.mergeMetadata([primary, named])
        XCTAssertEqual(merged?.title, "Move session card input to canvas area")
        XCTAssertEqual(merged?.isArchived, false)
        // lastActivityAt 取 max
        XCTAssertEqual(merged?.lastActivityAt, Date(timeIntervalSince1970: 2_000_000))
    }

    /// 任一 unarchived → 整条 cliSessionId 视为 active（这是 visibility 修复
    /// 的核心保证：archived 的旧 wrapper 不能拉黑还活着的 CLI session）。
    func testAnyUnarchivedWrapper_KeepsSessionActive() {
        let archived  = makeMeta(wrapper: "old",  isArchived: true)
        let active    = makeMeta(wrapper: "live", isArchived: false)
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.mergeMetadata([archived, active])?.isArchived,
            false
        )
        // 顺序无关
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.mergeMetadata([active, archived])?.isArchived,
            false
        )
    }

    /// 全部 archived → 才视为 archived。
    func testAllArchived_MergedIsArchived() {
        let a = makeMeta(wrapper: "a", isArchived: true)
        let b = makeMeta(wrapper: "b", isArchived: true)
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.mergeMetadata([a, b])?.isArchived,
            true
        )
    }

    /// 多个 wrapper 都有 title → 取最新活跃的那条的 title。
    func testMultipleTitledWrappers_PrefersMostRecent() {
        let older = makeMeta(
            wrapper: "older",
            title: "Old title",
            lastActivity: Date(timeIntervalSince1970: 1_000_000)
        )
        let newer = makeMeta(
            wrapper: "newer",
            title: "New title",
            lastActivity: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.mergeMetadata([older, newer])?.title,
            "New title"
        )
    }

    /// 三方组合：archived+无 title 的 primary（最新）+ unarchived+有 title 的
    /// named（中间）+ archived+老 title 的废弃 wrapper。合并后：
    ///   - isArchived = false（有 unarchived 的 named）
    ///   - title      = "(named's title)"（"(untitled)" 跳过，archived 那条
    ///     虽然 title 非空，但优先取最新非"(untitled)"，所以走 named 而不是
    ///     最旧的废弃 wrapper）
    func testThreeWrapperRealisticMix() {
        let primary  = makeMeta(
            wrapper: "primary",
            title: "(untitled)",
            isArchived: false,
            lastActivity: Date(timeIntervalSince1970: 3_000_000)
        )
        let named    = makeMeta(
            wrapper: "named",
            title: "Real conversation title",
            isArchived: false,
            lastActivity: Date(timeIntervalSince1970: 2_000_000)
        )
        let scrap    = makeMeta(
            wrapper: "scrap",
            title: "Old discarded title",
            isArchived: true,
            lastActivity: Date(timeIntervalSince1970: 1_000_000)
        )
        let merged = ClaudeDesktopMetadataReader.mergeMetadata([primary, named, scrap])
        XCTAssertEqual(merged?.isArchived, false)
        XCTAssertEqual(merged?.title, "Real conversation title")
        XCTAssertEqual(merged?.lastActivityAt, Date(timeIntervalSince1970: 3_000_000))
    }

    /// 都没 title → 合并出 "(untitled)"，不是 nil 不是空串。
    func testAllWrappersUntitled_FallsBackToPlaceholder() {
        let a = makeMeta(wrapper: "a", title: "(untitled)")
        let b = makeMeta(wrapper: "b", title: "")
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.mergeMetadata([a, b])?.title,
            "(untitled)"
        )
    }
}

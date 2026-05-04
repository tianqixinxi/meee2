import XCTest
@testable import meee2Kit

/// 同一 cliSessionId 在 Claude Desktop 端能并存多个 `local_<uuid>.json`
/// wrapper —— 当用户在 Desktop UI archive 一个旧 wrapper 时，活着的 CLI
/// session 仍然在另一个 unarchived wrapper 里跑。
///
/// 现场（2026-05-04）：reader.refresh() 用 last-write-wins 装 index，archived
/// 旧 wrapper 抢到槽位 → BoardAPI.getState 把整条 cliSessionId 误判 archived
/// 过滤掉 → 当前 dev session 在 webui 里凭空消失。
///
/// 修复：preferredMetadata 永远偏好 unarchived；都 unarchived/archived 时按
/// lastActivityAt 取新者。这一组 case 锁住选择行为。
final class ClaudeDesktopMetadataReaderTests: XCTestCase {

    private func makeMeta(
        cliSid: String = "9d0f0185-9886-47cd-919f-a567c45b130f",
        wrapper: String,
        isArchived: Bool,
        lastActivity: Date? = nil
    ) -> ClaudeDesktopMetadata {
        ClaudeDesktopMetadata(
            cliSessionId: cliSid,
            title: "(untitled)",
            model: nil,
            cwd: "/Users/qc/projects/meee1_code/meee2",
            isArchived: isArchived,
            desktopSessionId: "local_\(wrapper)",
            lastActivityAt: lastActivity,
            transcriptPath: nil
        )
    }

    /// 现场原型：unarchived 是当前活的 CLI session，archived 是旧 wrapper。
    /// 必须保留 unarchived。
    func testUnarchivedAlwaysWinsOverArchived_ArchivedFirst() {
        let archived = makeMeta(wrapper: "a8df88ee", isArchived: true)
        let active   = makeMeta(wrapper: "9d0f0185", isArchived: false)
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(archived, active).desktopSessionId,
            "local_9d0f0185"
        )
    }

    /// 反方向同样必须赢 —— 顺序无关。
    func testUnarchivedAlwaysWinsOverArchived_UnarchivedFirst() {
        let active   = makeMeta(wrapper: "9d0f0185", isArchived: false)
        let archived = makeMeta(wrapper: "a8df88ee", isArchived: true)
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(active, archived).desktopSessionId,
            "local_9d0f0185"
        )
    }

    /// 两条都 unarchived → 取 lastActivityAt 更新的。
    func testBothUnarchived_PrefersMostRecentActivity() {
        let older = makeMeta(
            wrapper: "older",
            isArchived: false,
            lastActivity: Date(timeIntervalSince1970: 1_000_000)
        )
        let newer = makeMeta(
            wrapper: "newer",
            isArchived: false,
            lastActivity: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(older, newer).desktopSessionId,
            "local_newer"
        )
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(newer, older).desktopSessionId,
            "local_newer"
        )
    }

    /// 两条都 archived（病态但要确定行为）—— 取最新的，不要乱选。
    func testBothArchived_PrefersMostRecentActivity() {
        let older = makeMeta(
            wrapper: "older",
            isArchived: true,
            lastActivity: Date(timeIntervalSince1970: 1_000_000)
        )
        let newer = makeMeta(
            wrapper: "newer",
            isArchived: true,
            lastActivity: Date(timeIntervalSince1970: 2_000_000)
        )
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(older, newer).desktopSessionId,
            "local_newer"
        )
    }

    /// lastActivity 缺失边界：a 有时间、b 没时间 → 选 a。
    func testFallbackWhenOneSideMissingTimestamp() {
        let withTime    = makeMeta(wrapper: "with",    isArchived: false, lastActivity: Date())
        let withoutTime = makeMeta(wrapper: "without", isArchived: false, lastActivity: nil)
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(withTime, withoutTime).desktopSessionId,
            "local_with"
        )
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(withoutTime, withTime).desktopSessionId,
            "local_with"
        )
    }

    /// 两条都缺 lastActivity → 稳定保留 a。避免反复 churn index。
    func testBothMissingTimestamp_StablyKeepsFirst() {
        let a = makeMeta(wrapper: "first",  isArchived: false, lastActivity: nil)
        let b = makeMeta(wrapper: "second", isArchived: false, lastActivity: nil)
        XCTAssertEqual(
            ClaudeDesktopMetadataReader.preferredMetadata(a, b).desktopSessionId,
            "local_first"
        )
    }
}

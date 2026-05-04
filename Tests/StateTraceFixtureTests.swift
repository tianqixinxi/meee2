import XCTest
@testable import meee2Kit
import Meee2PluginKit

/// 遍历 `Tests/Fixtures/StateTraces/*.json`，每条 fixture 都 replay 一遍：
///   1. 把 captured `transcript_tail` 写到临时文件
///   2. 把 fixture 里的 SessionData 的 `transcript_path` 重写到这个临时文件
///   3. 调 `TranscriptStatusResolver.resolve(for: sd)` 得到 actual
///   4. assert actual == fixture 抓取时记录的 `expected_resolved_status`
///
/// fixture 是用 `meee2 test capture <sid> --name foo --desc "..."` 产出的，
/// 一条对应一个真实修过的 stuck-session bug 现场。回归库越长越厚，每次 resolver
/// 改动都会被这堆历史现场扫一遍。
///
/// 没有 fixture 时这个 test class 的 `testAllFixtures` 直接 PASS（空目录视为 OK，
/// 不强迫每个开发者本地都生成 fixture）。如果想强制要求有 fixture，把 guard 那条
/// 注释打开即可。
final class StateTraceFixtureTests: XCTestCase {

    func testAllFixtures() throws {
        let dir = Self.fixturesDir
        guard FileManager.default.fileExists(atPath: dir.path) else {
            // 目录不存在 = 还没人 capture 过；不算失败
            return
        }
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            XCTFail("无法读取 fixtures 目录 \(dir.path): \(error)")
            return
        }
        let files = entries.filter { $0.hasSuffix(".json") }.sorted()
        // 强制要求至少 1 条的话，把下面这条注释改成 XCTAssertFalse(files.isEmpty, ...)
        guard !files.isEmpty else { return }

        for f in files {
            let url = dir.appendingPathComponent(f)
            try replay(fixtureAt: url)
        }
    }

    private func replay(fixtureAt url: URL) throws {
        let data = try Data(contentsOf: url)
        let fx = try JSONDecoder().decode(TraceFixture.self, from: data)

        // resolver 用 `Date.now` 算 entry 年龄。capture 时 assistant 可能是 3s 前
        // （fresh），但跑测试时 fixture 可能已经过去 N 天 —— 同一份 tail 再喂进
        // resolver 就会被 ESC-mid-stream / abandoned-user 等老化规则降级 idle，
        // 跟当时 expected 不一致。
        // 解决：fixture 里 `captured_at` 是 capture 时刻；test 跑时算 delta，
        // 把 tail 里每个 `"timestamp":"<ISO8601>"` 平移 delta，让 resolver 看到
        // 的"年龄"跟 capture 时同。
        let shiftedTail = TraceFixture.shiftTimestamps(
            in: fx.transcriptTail,
            capturedAt: fx.capturedAt,
            now: Date()
        )

        // 写 tail 到临时文件，让 resolver 像生产环境那样走 readTail()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meee2-fixture-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try shiftedTail.data(using: .utf8)?.write(to: tmp)

        var sd = fx.sessionData
        sd.transcriptPath = tmp.path
        // sanitize 已经把这些清空了，二次防御
        sd.pid = nil
        sd.ghosttyTerminalId = nil
        sd.terminalInfo = nil

        // 清缓存 —— resolver 内部 1s TTL，否则前一条 fixture 的结果会污染本条
        TranscriptStatusResolver.invalidate(sessionId: sd.sessionId)

        let descSuffix = (fx.description ?? "").isEmpty ? "" : "  \(fx.description!)"

        // ── status assertion
        let actualStatus = TranscriptStatusResolver.resolve(for: sd)
        let expectedStatus = SessionStatus.from(rawString: fx.expectedResolvedStatus)
        XCTAssertEqual(
            actualStatus, expectedStatus,
            "fixture '\(fx.name)' (\(url.lastPathComponent)): status expected \(expectedStatus.rawValue), got \(actualStatus.rawValue).\(descSuffix)"
        )

        // ── tool override assertion（仅当 fixture 里有 expected_current_tool_override）
        if let expectedTool = fx.expectedCurrentToolOverride {
            let actualToolRaw = TranscriptStatusResolver.resolveCurrentTool(
                transcriptPath: tmp.path,
                currentTool: fx.inputCurrentTool
            )
            let actualTool = ToolOverride.from(resolverReturn: actualToolRaw)
            XCTAssertEqual(
                actualTool, expectedTool,
                "fixture '\(fx.name)' (\(url.lastPathComponent)): tool override expected \(expectedTool), got \(actualTool).\(descSuffix)"
            )
        }
    }

    // MARK: - 路径推导
    //
    // 测试进程的 cwd 在 swift test 下不稳定，用 #filePath 拿到当前测试文件
    // 物理路径，向上回到仓库根（Tests 上一级）再拼 Tests/Fixtures/StateTraces。

    private static let fixturesDir: URL = {
        let testFile = URL(fileURLWithPath: #filePath)
        // #filePath = .../meee2/Tests/StateTraceFixtureTests.swift
        let testsDir = testFile.deletingLastPathComponent()        // Tests/
        return testsDir.appendingPathComponent("Fixtures/StateTraces", isDirectory: true)
    }()
}

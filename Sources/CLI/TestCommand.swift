import Foundation
import Meee2PluginKit

/// `meee2 test ...` —— log-driven 回归 fixture 工具。
///
/// 流程：
///   1. 真实修过一个 stuck-session 类 bug（resolver 把 status 算错）
///   2. 趁着复现现场 / 修完之后状态对的时候跑 `meee2 test capture <sid> --name foo`
///      抓一份 SessionData + transcript tail + log 片段 + 当前 resolver 结果
///   3. 写入 `Tests/Fixtures/StateTraces/foo.json`
///   4. `swift test` 时 `StateTraceFixtureTests` 遍历该目录，replay 每条 fixture，
///      assert resolver 输出 == 捕获时的"权威 status"
///
/// 这套等于把每个修过的现场冻结成一条回归用例，库会越长越厚而成本几乎为 0。
public struct TestCommand {
    public static func run(args: [String]) {
        guard let sub = args.first else {
            printUsage()
            return
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "capture":
            runCapture(args: rest)
        case "list":
            runList()
        case "replay":
            runReplay(args: rest)
        case "--help", "-h", "help":
            printUsage()
        default:
            print("Unknown subcommand: test \(sub)")
            printUsage()
        }
    }

    // MARK: - capture

    private static func runCapture(args: [String]) {
        var sidArg: String?
        var name: String?
        var description: String?
        var lines = 200
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--name":
                i += 1; if i < args.count { name = args[i] }
            case "--desc", "--description":
                i += 1; if i < args.count { description = args[i] }
            case "--lines":
                i += 1; if i < args.count, let n = Int(args[i]) { lines = n }
            default:
                if sidArg == nil { sidArg = a }
            }
            i += 1
        }
        guard let sidArg else {
            print("usage: meee2 test capture <sid> [--name NAME] [--desc \"...\"] [--lines N]")
            return
        }

        guard let session = resolveSession(prefix: sidArg) else {
            print("error: no live session matching '\(sidArg)' in SessionStore")
            return
        }

        // ── 抓 transcript tail（tail bytes，不全文件）。再 cap 到 16KB，
        //    resolver 实际只读最后 4KB，留 4× 余量足够 + 避免大段无关内容入库。
        let transcriptTailRaw: String = {
            guard let path = session.transcriptPath,
                  FileManager.default.fileExists(atPath: path) else { return "" }
            return tailLines(path: path, lines: lines) ?? ""
        }()
        let transcriptTail = redactHome(capTail(transcriptTailRaw, maxBytes: 16 * 1024))

        // ── 计算 transcript 文件 mtime 距 capture 时刻的年龄（秒）。
        // resolver 的 "transcript-mtime-stale" 兜底依赖这个数 —— replay 时
        // tmp 文件的 mtime 会被设回 (now - age)，让 fixture 在任何机器、
        // 任何时刻 replay 都能再现 capture 时的"文件多久没动"语义。
        let transcriptFileAgeAtCapture: Double? = {
            guard let path = session.transcriptPath,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else {
                return nil
            }
            return Date().timeIntervalSince(mtime)
        }()

        // ── 抓 state-trace 日志里跟该 sid 有关的 [StateTrace] 行。
        // 路径优先级跟 scripts/dev-restart.sh 对齐：
        //   1. MEEE2_LOG_DIR/state-trace.log
        //   2. MEEE2_HOME/logs/state-trace.log
        //   3. /tmp/meee2.log（老默认，向后兼容）
        let sid8 = String(session.sessionId.prefix(8))
        let stateTraceLogPath = Self.resolveStateTraceLogPath()
        let logExcerpts = grepLog(path: stateTraceLogPath, needle: sid8, max: 100).map(redactHome)

        // ── 跑一次 resolver 当作"权威"答案。注意：这是当前现场的解析结果，
        //    所以 fixture 命名 / 描述里务必写清楚"我认为这个时刻的 status 应当是 X"，
        //    避免抓到错的状态作为 expected。
        TranscriptStatusResolver.invalidate(sessionId: session.sessionId)
        let resolved = TranscriptStatusResolver.resolve(for: session)

        // ── 同样跑一次 resolveCurrentTool 抓"权威" tool 覆盖结果。
        let toolOverrideRaw = TranscriptStatusResolver.resolveCurrentTool(
            transcriptPath: session.transcriptPath,
            currentTool: session.currentTool
        )
        let toolOverride = ToolOverride.from(resolverReturn: toolOverrideRaw)

        // ── 净化 SessionData：把依赖 OS 状态的字段去掉，让 fixture 可在任何机器上 replay
        let sanitized = sanitize(session, transcriptPathPlaceholder: "<<embedded-tail>>")

        let fixtureName = name ?? "\(sid8)-\(resolved.rawValue)-\(timestampSuffix())"
        let fixture = TraceFixture(
            name: fixtureName,
            description: description,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            sessionData: sanitized,
            transcriptTail: transcriptTail,
            transcriptFileAgeAtCaptureSeconds: transcriptFileAgeAtCapture,
            logExcerpts: logExcerpts,
            expectedResolvedStatus: resolved.rawValue,
            inputCurrentTool: session.currentTool,
            expectedCurrentToolOverride: toolOverride
        )

        do {
            let outURL = try writeFixture(fixture)
            print("captured fixture: \(outURL.path)")
            print("  sid:           \(session.sessionId)")
            print("  hook:          \(session.status.rawValue)")
            print("  resolved:      \(resolved.rawValue)  ← expected_resolved_status")
            print("  current_tool:  \(session.currentTool ?? "<nil>")  → \(describeOverride(toolOverride))  ← expected_current_tool_override")
            print("  tail:          \(transcriptTail.count) bytes")
            print("  log:           \(logExcerpts.count) lines")
            if description == nil {
                print("  TIP: 用 --desc 写明这个 fixture 在测什么 case，方便回归时读懂")
            }
        } catch {
            print("error: failed to write fixture: \(error.localizedDescription)")
        }
    }

    private static func describeOverride(_ o: ToolOverride) -> String {
        switch o {
        case .noChange: return "no_change (resolver 不发表意见)"
        case .clear:    return "clear (清掉 currentTool)"
        case .set(let s): return "set(\"\(s)\")"
        }
    }

    // MARK: - list

    private static func runList() {
        let dir = fixturesDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            print("(no fixtures at \(dir.path))")
            return
        }
        let files = entries.filter { $0.hasSuffix(".json") }.sorted()
        if files.isEmpty {
            print("(no fixtures at \(dir.path))")
            return
        }
        let decoder = JSONDecoder()
        print("\(files.count) fixture(s) at \(dir.path):")
        for f in files {
            let url = dir.appendingPathComponent(f)
            guard let data = try? Data(contentsOf: url),
                  let fx = try? decoder.decode(TraceFixture.self, from: data) else {
                print("  - \(f) [parse error]")
                continue
            }
            let desc = fx.description ?? ""
            print("  - \(fx.name): expected=\(fx.expectedResolvedStatus)\(desc.isEmpty ? "" : "  \(desc)")")
        }
    }

    // MARK: - replay

    private static func runReplay(args: [String]) {
        guard let name = args.first else {
            print("usage: meee2 test replay <name>")
            return
        }
        let url = fixturesDir().appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let fx = try? JSONDecoder().decode(TraceFixture.self, from: data) else {
            print("error: cannot read fixture '\(name)' at \(url.path)")
            return
        }
        // 写 tail 到临时文件，让 resolver 像生产那样去 readTail。
        // 平移 timestamp 让 entry "年龄"跟 capture 时一致（防 fixture 过期）。
        let shiftedTail = TraceFixture.shiftTimestamps(
            in: fx.transcriptTail,
            capturedAt: fx.capturedAt,
            now: Date()
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meee2-replay-\(fx.name).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? shiftedTail.data(using: .utf8)?.write(to: tmp)
        // 把 mtime 设回 capture 时的 staleness，让 resolver 的
        // "transcript-mtime-stale" 兜底规则能复现 capture 时的判定
        fx.applyTranscriptFileMtime(at: tmp.path)

        var sd = fx.sessionData
        sd.transcriptPath = tmp.path
        TranscriptStatusResolver.invalidate(sessionId: sd.sessionId)
        let actualStatus = TranscriptStatusResolver.resolve(for: sd)
        let expectedStatus = SessionStatus.from(rawString: fx.expectedResolvedStatus)

        print("fixture: \(fx.name)")
        print("  status   expected: \(expectedStatus.rawValue)")
        print("  status   actual:   \(actualStatus.rawValue)  \(actualStatus == expectedStatus ? "✓" : "✗")")

        // Tool override：fixture 里有 expected 才 assert
        var toolPass = true
        if let expectedTool = fx.expectedCurrentToolOverride {
            let actualToolRaw = TranscriptStatusResolver.resolveCurrentTool(
                transcriptPath: tmp.path,
                currentTool: fx.inputCurrentTool
            )
            let actualTool = ToolOverride.from(resolverReturn: actualToolRaw)
            toolPass = (actualTool == expectedTool)
            print("  tool     expected: \(describeOverride(expectedTool))")
            print("  tool     actual:   \(describeOverride(actualTool))  \(toolPass ? "✓" : "✗")")
        }

        let pass = (actualStatus == expectedStatus) && toolPass
        print("  result:  \(pass ? "PASS" : "FAIL")")
        if !pass, let desc = fx.description {
            print("  context: \(desc)")
        }
    }

    // MARK: - helpers

    /// SessionStore 用的 sid 解析：full match → suffix match → prefix match
    private static func resolveSession(prefix: String) -> SessionData? {
        let all = SessionStore.shared.listAll()
        if let exact = all.first(where: { $0.sessionId == prefix }) {
            return exact
        }
        if let byPrefix = all.first(where: { $0.sessionId.hasPrefix(prefix) }) {
            return byPrefix
        }
        if let bySuffix = all.first(where: { $0.sessionId.hasSuffix(prefix) }) {
            return bySuffix
        }
        return nil
    }

    /// 净化：移除 / 占位掉依赖本机 OS 状态的字段，让 fixture 在任意机器跑得动。
    /// pid / ghosttyTerminalId / terminalInfo 都置空（resolver 这几个字段为空时会跳过对应 step），
    /// transcriptPath 改写成占位符（test runner 会临时重写到本地 tmp 文件）。
    /// 任何字符串字段里出现的 `$HOME`（如 `/Users/qc`）也替换成 `~`，符合
    /// 仓库 "no hardcoded user paths" 约定，避免 validate.sh / swiftlint 报警。
    private static func sanitize(_ data: SessionData, transcriptPathPlaceholder: String) -> SessionData {
        var s = data
        s.pid = nil
        s.ghosttyTerminalId = nil
        s.iTermSessionId = nil
        s.appleTerminalSessionId = nil
        s.terminalInfo = nil
        s.transcriptPath = transcriptPathPlaceholder
        s.cwd = s.cwd.map(redactHome)
        s.project = redactHome(s.project)
        s.lastMessage = s.lastMessage.map(redactHome)
        s.description = s.description.map(redactHome)
        s.currentTask = s.currentTask.map(redactHome)
        return s
    }

    /// 把 `/Users/<user>` / `/var/folders/...` 这种本机绝对路径替换成 `~` /
    /// `/var/folders/<TMP>`，避免 fixture 里漏出 username 或 macOS 临时路径。
    private static func redactHome(_ s: String) -> String {
        let home = NSHomeDirectory()
        var out = s.replacingOccurrences(of: home, with: "~")
        // /var/folders/.../T/ 这种 macOS NSTemporaryDirectory 路径里 user uuid
        // 也不该公开（虽然不直接暴露 username，仍然是会话指纹）
        let tmp = NSTemporaryDirectory()
        if !tmp.isEmpty, tmp != "/tmp/" {
            out = out.replacingOccurrences(of: tmp, with: "/tmp/")
        }
        return out
    }

    /// 把 transcript tail cap 在 maxBytes 字节左右（按 UTF-8 字节算），从尾部
    /// 截取。resolver 实际 readTail(4096)；多留 4× 给"边界 case"分析空间足够。
    /// 避免一条 fixture 存一整段 60+ KB 的项目内容（业务讨论、代码、commit msg）。
    private static func capTail(_ s: String, maxBytes: Int) -> String {
        let bytes = Array(s.utf8)
        guard bytes.count > maxBytes else { return s }
        // 从尾巴回溯 maxBytes，再裁到下一个 \n 边界，保证截后是合法 UTF-8 + 完整行
        let suffix = bytes.suffix(maxBytes)
        if let str = String(bytes: suffix, encoding: .utf8) {
            // 砍掉首行可能不完整的部分
            if let newlineIdx = str.firstIndex(of: "\n") {
                return String(str[str.index(after: newlineIdx)...])
            }
            return str
        }
        // utf8 边界 unhappy 时 fallback 拿 char-suffix
        return String(s.suffix(maxBytes))
    }

    /// 读文件最后 N 行（按 newline 切）。读 tail 64KB 然后取末尾 N 行。
    private static func tailLines(path: String, lines: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? h.close() }
        let size: UInt64 = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 64 * 1024
        let from: UInt64 = size > chunk ? size - chunk : 0
        try? h.seek(toOffset: from)
        guard let raw = try? h.readToEnd(),
              let s = String(data: raw, encoding: .utf8) else { return nil }
        let allLines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = allLines.suffix(lines)
        return tail.joined(separator: "\n")
    }

    /// 解析当前进程的 state-trace 日志位置。
    /// 跟 `scripts/dev-restart.sh` 里的 stdout/stderr 落盘规则对齐：
    /// 1. `MEEE2_LOG_DIR/state-trace.log`
    /// 2. `MEEE2_HOME/logs/state-trace.log`
    /// 3. `/tmp/meee2.log`（旧默认，向后兼容）
    static func resolveStateTraceLogPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["MEEE2_LOG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return MEEE2Env.expandTilde(raw) + "/state-trace.log"
        }
        if let raw = env["MEEE2_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return MEEE2Env.expandTilde(raw) + "/logs/state-trace.log"
        }
        return "/tmp/meee2.log"
    }

    /// 简单 grep：读整个 log 文件，按 needle substring 过滤，返回最后 max 条。
    /// log 文件大时只看 tail 1MB 避免炸内存。
    private static func grepLog(path: String, needle: String, max: Int) -> [String] {
        guard FileManager.default.fileExists(atPath: path),
              let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return [] }
        defer { try? h.close() }
        let size: UInt64 = (try? h.seekToEnd()) ?? 0
        let cap: UInt64 = 1024 * 1024
        let from: UInt64 = size > cap ? size - cap : 0
        try? h.seek(toOffset: from)
        guard let raw = try? h.readToEnd(),
              let s = String(data: raw, encoding: .utf8) else { return [] }
        let matched = s.split(separator: "\n").filter { $0.contains(needle) }.map { String($0) }
        return Array(matched.suffix(max))
    }

    private static func fixturesDir() -> URL {
        // Tests/Fixtures/StateTraces/ 相对仓库根。CLI 跑的时候 cwd 不稳定，
        // 所以走 PROJECT_ROOT 推断：从可执行文件路径回溯到包含 Package.swift 的目录。
        let env = ProcessInfo.processInfo.environment
        if let custom = env["MEEE2_FIXTURES_DIR"] {
            return URL(fileURLWithPath: custom)
        }
        if let root = projectRoot() {
            return root.appendingPathComponent("Tests/Fixtures/StateTraces", isDirectory: true)
        }
        // 兜底：cwd
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/StateTraces", isDirectory: true)
    }

    private static func projectRoot() -> URL? {
        // 从可执行文件路径（.build/.../debug/meee2）逐级上溯找 Package.swift
        let bundlePath = Bundle.main.bundleURL.deletingLastPathComponent()
        var cur = bundlePath
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: cur.appendingPathComponent("Package.swift").path) {
                return cur
            }
            cur = cur.deletingLastPathComponent()
            if cur.path == "/" { break }
        }
        // 兜底：试 cwd
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd
        }
        return nil
    }

    private static func writeFixture(_ fx: TraceFixture) throws -> URL {
        let dir = fixturesDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(fx.name).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(fx)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func timestampSuffix() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func printUsage() {
        print("""
        meee2 test - state-trace 回归 fixture 工具

        Usage:
          meee2 test capture <sid>  [--name NAME] [--desc "..."] [--lines N]
              抓当前 session 的 SessionData + transcript tail + 相关 log 行 +
              当前 resolver 结果，写到 Tests/Fixtures/StateTraces/<NAME>.json
          meee2 test list
              列出所有已捕获 fixture
          meee2 test replay <name>
              单独跑一条 fixture 看 PASS / FAIL
          meee2 test help
              显示这条
        """)
    }
}

// MARK: - Fixture model（CLI / Tests 两边都用）

/// resolveCurrentTool 的 String?? 三态在 JSON 里的 stable 表示。
/// 用 `kind` 区分而不是 sentinel value，避免 "string vs null vs missing field"
/// 在不同 JSON 工具下解释不一致。
public enum ToolOverride: Codable, Equatable {
    /// resolveCurrentTool 返回 nil —— "我没意见，保留现有 currentTool"
    case noChange
    /// resolveCurrentTool 返回 .some(nil) —— "清空 currentTool"
    case clear
    /// resolveCurrentTool 返回 .some(s) —— "覆盖 currentTool 为 s"（如 "thinking"）
    case set(String)

    enum CodingKeys: String, CodingKey { case kind, value }
    enum Kind: String, Codable { case no_change, clear, set }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noChange: try c.encode(Kind.no_change, forKey: .kind)
        case .clear:    try c.encode(Kind.clear, forKey: .kind)
        case .set(let v):
            try c.encode(Kind.set, forKey: .kind)
            try c.encode(v, forKey: .value)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .no_change: self = .noChange
        case .clear:     self = .clear
        case .set:       self = .set(try c.decode(String.self, forKey: .value))
        }
    }

    /// 把 resolveCurrentTool 的返回值（String??）规范成三态 enum。
    public static func from(resolverReturn ret: String??) -> ToolOverride {
        switch ret {
        case .none:                  return .noChange       // nil
        case .some(.none):           return .clear          // .some(nil)
        case .some(.some(let s)):    return .set(s)
        }
    }
}

/// 一条 state-trace 回归 fixture。
/// 字段命名走 snake_case 以便 git diff 友好阅读。
public struct TraceFixture: Codable {
    public let name: String
    public let description: String?
    public let capturedAt: String?
    /// SessionData JSON（已被 sanitize：pid / ghosttyTerminalId / iTermSessionId /
    /// appleTerminalSessionId / terminalInfo 都已置空，transcriptPath 是占位符）
    public let sessionData: SessionData
    /// 抓 fixture 时 transcript JSONL 的最后若干行
    public let transcriptTail: String
    /// capture 时刻距 transcript 文件 mtime 的秒数。replay 时 harness 会把
    /// 临时文件的 mtime 设回 (now - 此值)，复现"文件多久没动"语义。resolver
    /// 的 "transcript-mtime-stale" 兜底规则依赖此字段。老 fixture 没这字段
    /// → nil → replay 时不动 mtime（保持文件刚写完的 fresh mtime）。
    public let transcriptFileAgeAtCaptureSeconds: Double?
    /// state-trace log（默认 `/tmp/meee2.log`；若 `MEEE2_HOME` / `MEEE2_LOG_DIR`
    /// 被指定则跟随）里跟此 sid 相关的 [StateTrace] 等日志片段，纯供人读
    public let logExcerpts: [String]?
    /// 抓 fixture 时跑 `TranscriptStatusResolver.resolve(for:)` 得到的结果。
    /// test runner replay 时拿这个当 expected 比对。
    public let expectedResolvedStatus: String
    /// capture 时 SessionData.currentTool 的值。replay `resolveCurrentTool`
    /// 时作为 currentTool 入参。老 fixture 缺这个字段 → nil。
    public let inputCurrentTool: String?
    /// capture 时 `resolveCurrentTool(...)` 的输出三态。replay 时拿来断言。
    /// 老 fixture 没这个字段 → nil（test runner 跳过 tool 断言）。
    public let expectedCurrentToolOverride: ToolOverride?

    enum CodingKeys: String, CodingKey {
        case name, description
        case capturedAt = "captured_at"
        case sessionData = "session_data"
        case transcriptTail = "transcript_tail"
        case transcriptFileAgeAtCaptureSeconds = "transcript_file_age_at_capture_seconds"
        case logExcerpts = "log_excerpts"
        case expectedResolvedStatus = "expected_resolved_status"
        case inputCurrentTool = "input_current_tool"
        case expectedCurrentToolOverride = "expected_current_tool_override"
    }

    public init(
        name: String,
        description: String?,
        capturedAt: String?,
        sessionData: SessionData,
        transcriptTail: String,
        transcriptFileAgeAtCaptureSeconds: Double?,
        logExcerpts: [String]?,
        expectedResolvedStatus: String,
        inputCurrentTool: String?,
        expectedCurrentToolOverride: ToolOverride?
    ) {
        self.name = name
        self.description = description
        self.capturedAt = capturedAt
        self.sessionData = sessionData
        self.transcriptTail = transcriptTail
        self.transcriptFileAgeAtCaptureSeconds = transcriptFileAgeAtCaptureSeconds
        self.logExcerpts = logExcerpts
        self.expectedResolvedStatus = expectedResolvedStatus
        self.inputCurrentTool = inputCurrentTool
        self.expectedCurrentToolOverride = expectedCurrentToolOverride
    }

    /// replay harness 共用：把临时 transcript 文件的 mtime 设回 capture 时
    /// 看到的 staleness（如果 fixture 里有这个字段）。CLI 的 runReplay 和
    /// XCTest 的 StateTraceFixtureTests.replay 都调它，避免两边写两遍逻辑。
    public func applyTranscriptFileMtime(at path: String, now: Date = Date()) {
        guard let age = transcriptFileAgeAtCaptureSeconds, age > 0 else { return }
        let mtime = now.addingTimeInterval(-age)
        try? FileManager.default.setAttributes(
            [.modificationDate: mtime],
            ofItemAtPath: path
        )
    }

    /// 把 tail 里每条 `"timestamp":"<ISO8601>"` 平移 (`now - capturedAt`) 秒。
    /// 让 resolver 看到的相对年龄跟 capture 时一样 —— fixture 不会随时间过期。
    /// 没有 capturedAt（老 fixture）就原样返回。
    public static func shiftTimestamps(in tail: String, capturedAt: String?, now: Date) -> String {
        guard let captured = capturedAt,
              let captured = ISO8601DateFormatter.parseFlexible(captured) else {
            return tail
        }
        let delta = now.timeIntervalSince(captured)
        if abs(delta) < 1 { return tail }
        // 匹配 `"timestamp":"YYYY-MM-DDTHH:MM:SS(.sss)?Z"` 格式（带或不带毫秒）
        let pattern = #""timestamp":"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return tail }
        let ns = tail as NSString
        let matches = regex.matches(in: tail, range: NSRange(location: 0, length: ns.length))
        // 倒序替换避免 NSRange 错位
        var out = tail
        let outNS = NSMutableString(string: out)
        for m in matches.reversed() {
            let tsRange = m.range(at: 1)
            let tsStr = (out as NSString).substring(with: tsRange)
            guard let parsed = ISO8601DateFormatter.parseFlexible(tsStr) else { continue }
            let shifted = parsed.addingTimeInterval(delta)
            let formatted = ISO8601DateFormatter.shared.string(from: shifted)
            outNS.replaceCharacters(in: tsRange, with: formatted)
        }
        out = outNS as String
        return out
    }
}

// 共享的 ISO8601 解析 / 格式化（带 / 不带毫秒都接），跟 resolver 内部
// 用的 formatter 行为对齐。
extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseFlexible(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: s)
    }
}

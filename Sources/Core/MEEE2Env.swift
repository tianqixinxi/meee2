import Foundation

/// 单一 env + path 求值入口。
///
/// 设计原则：
/// - 所有可被外部 env 覆盖的路径 / 端口 / socket / log 目录都从这里出。
/// - env 全 unset 时，行为与硬编码版本完全一致（零回归）。
/// - 静态属性 lazy：进程启动后第一次访问求值并缓存（`ProcessInfo` 读完不再变）。
/// - 这是地基模块：只读 env、只算路径，不做 IO（除 `ensureHome()` 这一显式 mkdir）。
///
/// 命名约定：
/// - `MEEE2_HOME`     — 数据 root（默认 `~/.meee2`）
/// - `MEEE2_PORT`     — BoardServer HTTP/WS 端口（默认 9876）
/// - `MEEE2_SOCK`     — Hook socket 路径（默认 `/tmp/meee2.sock`）
/// - `MEEE2_HEADLESS` — `1` / `true` 时跳过 AppKit GUI surfaces
/// - `MEEE2_LOG_DIR`  — 日志目录（默认 `~/Library/Logs`，若指定 `MEEE2_HOME` 则 `HOME/logs`）
/// - `MEEE2_CLAUDE_CONFIG` — Claude desktop 配置位置（默认 `~/.claude.json`）
public enum MEEE2Env {

    // MARK: - Raw env access

    /// 读 env，空串视作未设。
    private static func env(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 把以 `~` 开头的路径展成绝对路径。
    ///
    /// 注意：这里展开的是**用户 HOME**（`NSHomeDirectory()`），与 `MEEE2_HOME` 无关。
    /// `MEEE2_HOME` 只影响 meee2 自己的数据 root；用户在配置里写 `~/foo` 仍指向真实 home。
    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = NSHomeDirectory()
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        // 形如 ~user/... 的展开交给标准 API；fallback 直接返回原值。
        return (path as NSString).expandingTildeInPath
    }

    // MARK: - Home / data root

    /// 数据 root。默认 `~/.meee2`；可被 `MEEE2_HOME` 覆盖。
    public static let home: URL = {
        if let raw = env("MEEE2_HOME") {
            return URL(fileURLWithPath: expandTilde(raw), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".meee2", isDirectory: true)
    }()

    /// `home/sessions` —— `SessionStore` 持久化目录。
    public static var sessionsDir: URL {
        home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// `home/planner` —— planner runtime 状态。
    public static var plannerDir: URL {
        home.appendingPathComponent("planner", isDirectory: true)
    }

    /// `home/plugins` —— 动态插件 dylib 安装根。
    public static var pluginsDir: URL {
        home.appendingPathComponent("plugins", isDirectory: true)
    }

    /// `home/runtimes` —— planner agent runtime 暂存。
    public static var agentRuntimeStaging: URL {
        home.appendingPathComponent("runtimes", isDirectory: true)
    }

    /// `home/mcp` —— MCP 二进制 / 注册表安装目录。
    public static var mcpInstallDir: URL {
        home.appendingPathComponent("mcp", isDirectory: true)
    }

    /// `home/settings.json` —— 用户偏好。
    public static var settingsURL: URL {
        home.appendingPathComponent("settings.json", isDirectory: false)
    }

    /// `home/board-canvases.json` —— Board 画布存档。
    public static var boardCanvasesURL: URL {
        home.appendingPathComponent("board-canvases.json", isDirectory: false)
    }

    /// `home/session-terminals.json` —— session ↔ terminal 绑定。
    public static var sessionTerminalsURL: URL {
        home.appendingPathComponent("session-terminals.json", isDirectory: false)
    }

    // MARK: - External configs

    /// Claude desktop 配置位置。默认 `~/.claude.json`，可被 `MEEE2_CLAUDE_CONFIG` 覆盖。
    public static let claudeConfigURL: URL = {
        if let raw = env("MEEE2_CLAUDE_CONFIG") {
            return URL(fileURLWithPath: expandTilde(raw), isDirectory: false)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude.json", isDirectory: false)
    }()

    /// Codex 配置位置。固定 `~/.codex/config`（除非将来引入 `MEEE2_CODEX_CONFIG`）。
    public static var codexConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }

    // MARK: - Logging

    /// 日志目录。
    /// 优先级：`MEEE2_LOG_DIR` > （若设了 `MEEE2_HOME`）`home/logs` > `~/Library/Logs`。
    public static let logDir: URL = {
        if let raw = env("MEEE2_LOG_DIR") {
            return URL(fileURLWithPath: expandTilde(raw), isDirectory: true)
        }
        if env("MEEE2_HOME") != nil {
            return home.appendingPathComponent("logs", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }()

    /// `logDir/meee2.log` —— `LogManager` 主日志。
    public static var logFileURL: URL {
        logDir.appendingPathComponent("meee2.log", isDirectory: false)
    }

    // MARK: - Networking / IPC

    /// Hook socket 路径。默认 `/tmp/meee2.sock`，可被 `MEEE2_SOCK` 覆盖。
    public static let socketPath: String = {
        if let raw = env("MEEE2_SOCK") {
            return expandTilde(raw)
        }
        return "/tmp/meee2.sock"
    }()

    /// BoardServer 监听端口。
    /// 兼容旧名 `MEEE2_BOARD_PORT`；新名 `MEEE2_PORT` 优先。
    /// 解析失败 / 越界时 fallback 到默认 9876。
    public static let boardPort: UInt16 = {
        let candidate = env("MEEE2_PORT") ?? env("MEEE2_BOARD_PORT")
        if let raw = candidate, let parsed = UInt16(raw), parsed > 0 {
            return parsed
        }
        return 9876
    }()

    // MARK: - Headless

    /// `MEEE2_HEADLESS=1` / `=true` 时跳过 AppKit GUI surfaces。
    public static let isHeadless: Bool = {
        guard let raw = env("MEEE2_HEADLESS")?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }()

    // MARK: - Bootstrap

    /// 启动时 `mkdir -p` 所有 meee2 自管目录。
    ///
    /// 调用方：`AppDelegate.applicationDidFinishLaunching`（或等价启动 hook）。
    /// 老路径（`~/.meee2`、`~/Library/Logs`）本来就存在或会被各模块自己创建，
    /// 这里只是把"必有目录"集中起来，让 isolated 实例（`MEEE2_HOME=/tmp/x`）一把建齐。
    public static func ensureHome() throws {
        let fm = FileManager.default
        let dirs: [URL] = [
            home,
            sessionsDir,
            plannerDir,
            pluginsDir,
            agentRuntimeStaging,
            mcpInstallDir,
            logDir
        ]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

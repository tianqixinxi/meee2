import Foundation
import Meee2PluginKit
import Darwin

// MARK: - Color Scheme

/// TUI 颜色定义 (ANSI)
public enum TUIColor {
    public static let reset = "\u{1B}[0m"
    public static let bold = "\u{1B}[1m"
    public static let dim = "\u{1B}[2m"
    public static let reverse = "\u{1B}[7m"

    public static let green = "\u{1B}[32m"
    public static let yellow = "\u{1B}[33m"
    public static let red = "\u{1B}[31m"
    public static let cyan = "\u{1B}[36m"
    public static let magenta = "\u{1B}[35m"
    public static let white = "\u{1B}[37m"
    public static let black = "\u{1B}[30m"

    // 背景色
    public static let bgCyan = "\u{1B}[46m"
    public static let bgBlack = "\u{1B}[40m"

    /// 状态颜色映射
    public static func forStatus(_ status: String) -> String {
        switch status {
        case "active", "running": return green
        case "idle": return yellow
        case "waiting", "waitingForUser", "permissionRequired": return red
        case "dead", "failed": return red
        case "completed": return dim
        default: return white
        }
    }
}

// MARK: - Column Definition

/// 列定义
struct Column {
    let key: String
    let header: String
    let weight: Int  // 相对宽度权重

    /// 从 session 提取显示文本和颜色
    let extract: (SessionData, SessionExtras) -> (text: String, colorKey: String?)
}

/// Session 附加信息
struct SessionExtras {
    var unread: UnreadNotification?
    var messages: [(role: String, text: String)]
    var usage: UsageStats?
}

// MARK: - Column Registry

/// 列注册表 (类似 csm columns.py)
enum ColumnRegistry {
    static let registry: [String: Column] = [
        "badge": Column(key: "badge", header: "", weight: 1) { _, extras in
            (extras.unread != nil ? " ●" : "", "badge")
        },

        "id": Column(key: "id", header: "ID", weight: 4) { session, _ in
            (String(session.sessionId.prefix(8)), nil)
        },

        "project": Column(key: "project", header: "PROJECT", weight: 6) { session, _ in
            (session.project, nil)
        },

        "description": Column(key: "description", header: "NOTE", weight: 6) { session, _ in
            (session.description ?? "-", nil)
        },

        "status": Column(key: "status", header: "STATUS", weight: 5) { session, _ in
            let status = session.status
            let tool = session.currentTool ?? ""
            if (status == "active" || status == "running") && !tool.isEmpty {
                return ("⚡\(tool)", status)
            }
            // 使用精细状态
            let ds = session.detailedStatus
            return ("\(ds.icon) \(ds.displayName)", status)
        },

        "progress": Column(key: "progress", header: "PROGRESS", weight: 4) { session, _ in
            guard !session.tasks.isEmpty else { return ("-", nil) }
            let done = session.tasks.filter { $0.status == .done || $0.status == .completed }.count
            return ("\(done)/\(session.tasks.count)", nil)
        },

        "last_msg": Column(key: "last_msg", header: "LAST MSG", weight: 14) { _, extras in
            guard let last = extras.messages.last else { return ("", nil) }
            let prefix: String
            switch last.role {
            case "user": prefix = ">"
            case "assistant": prefix = "◀"
            case "tool": prefix = "⚡"
            default: prefix = "·"
            }
            return ("\(prefix) \(oneline(last.text))", nil)
        },

        "updated": Column(key: "updated", header: "UPDATED", weight: 4) { session, _ in
            (relativeTime(session.lastActivity), "dim")
        },

        "cost": Column(key: "cost", header: "COST", weight: 3) { _, extras in
            (formatCost(extras.usage?.costUSD ?? 0), nil)
        },

        "tokens_in": Column(key: "tokens_in", header: "IN", weight: 3) { _, extras in
            (formatTokens(extras.usage?.inputTokens ?? 0), "dim")
        },

        "tokens_out": Column(key: "tokens_out", header: "OUT", weight: 3) { _, extras in
            (formatTokens(extras.usage?.outputTokens ?? 0), nil)
        },

        "turns": Column(key: "turns", header: "TURNS", weight: 2) { _, extras in
            (String(extras.usage?.turns ?? 0), "dim")
        },

        "model": Column(key: "model", header: "MODEL", weight: 5) { _, extras in
            (shortModel(extras.usage?.model ?? ""), "dim")
        },

        "started": Column(key: "started", header: "STARTED", weight: 4) { session, _ in
            (relativeTime(session.startedAt), "dim")
        }
    ]

    /// 默认列
    static let defaultColumns = ["badge", "id", "project", "status", "cost", "last_msg", "updated"]

    /// 获取列配置
    static func getColumns() -> [Column] {
        defaultColumns.compactMap { registry[$0] }
    }
}

// MARK: - Formatting Helpers

/// 相对时间 (e.g., "5m ago")
func relativeTime(_ date: Date) -> String {
    let diff = Date().timeIntervalSince(date)
    if diff < 0 { return "just now" }
    else if diff < 60 { return "just now" }
    else if diff < 3600 { return "\(Int(diff / 60))m ago" }
    else if diff < 86400 { return "\(Int(diff / 3600))h ago" }
    else { return "\(Int(diff / 86400))d ago" }
}

/// 单行文本
func oneline(_ text: String) -> String {
    text.split(separator: "\n").joined(separator: " ")
        .split(separator: " ").joined(separator: " ")
}

/// 格式化成本
func formatCost(_ usd: Double) -> String {
    if usd < 0.01 { return "$0" }
    else if usd < 1 { return String(format: "$%.2f", usd) }
    else if usd < 10 { return String(format: "$%.1f", usd) }
    else { return String(format: "$%.0f", usd) }
}

/// 格式化 token 数量
func formatTokens(_ n: Int) -> String {
    if n < 1000 { return String(n) }
    else if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
    else { return String(format: "%.1fM", Double(n) / 1_000_000) }
}

/// 短模型名
func shortModel(_ model: String) -> String {
    guard !model.isEmpty else { return "-" }
    let m = model.replacingOccurrences(of: "claude-", with: "")
    // 移除日期后缀
    let parts = m.split(separator: "-")
    let clean = parts.filter { !($0.count == 8 && $0.allSatisfy { $0.isNumber }) }
    return clean.joined(separator: "-")
}

/// 截断字符串
func truncate(_ text: String, maxLen: Int) -> String {
    if text.count <= maxLen { return text }
    return String(text.prefix(maxLen - 2)) + ".."
}

/// Pad 字符串
func pad(_ text: String, to width: Int) -> String {
    if text.count >= width { return String(text.prefix(width)) }
    return text + String(repeating: " ", count: width - text.count)
}

// MARK: - Dashboard View

/// TUI Dashboard
public struct DashboardView {
    private var sessions: [SessionData]
    private var selectedIndex: Int = 0
    private var showHelp: Bool = false
    private var running: Bool = true
    private var originalTermios: termios?

    // 列配置
    private let columns = ColumnRegistry.getColumns()

    // 消息缓存
    private var messageCache: [String: [(role: String, text: String)]] = [:]
    private var usageCache: [String: UsageStats] = [:]
    private var unreadCache: [String: UnreadNotification?] = [:]

    // 初始化
    public init() {
        sessions = SessionStore.shared.sessions
        refreshCaches()
    }

    // MARK: - 数据刷新

    private mutating func refreshSessions() {
        sessions = SessionStore.shared.sessions
        refreshCaches()
    }

    private mutating func refreshCaches() {
        for session in sessions {
            let sid = session.sessionId

            // 加载消息
            if let path = session.transcriptPath {
                messageCache[sid] = TranscriptParser.loadMessages(transcriptPath: path, count: 5)
            }

            // 加载使用统计
            usageCache[sid] = session.usageStats

            // 加载未读通知
            unreadCache[sid] = SessionStore.shared.getUnread(sid)
        }
    }

    // MARK: - 渲染

    public func render() -> String {
        var output = ""

        // 清屏
        output += "\u{1B}[2J\u{1B}[H"

        // 获取终端宽度
        let termWidth = getTerminalWidth()
        let colWidths = calculateColumnWidths(totalWidth: termWidth)

        // ── 标题栏 ─────────────────────────────────────────
        output += TUIColor.bold + TUIColor.reverse + " MEEE2 Dashboard " + TUIColor.reset
        let helpText = showHelp
            ? "  [q]uit [r]efresh [h]ide help"
            : "  ↑↓ select  ⏎ switch  s send  n note  h help  q quit"
        output += TUIColor.dim + helpText + TUIColor.reset + "\n"

        if sessions.isEmpty {
            output += "\n"
            output += TUIColor.dim + "  No active sessions.\n"
            output += TUIColor.dim + "  Start Claude Code to see sessions here.\n"
            output += "\n"
            output += TUIColor.dim + "  Press q to quit.\n"
            return output
        }

        // ── 表格头部 ─────────────────────────────────────────
        output += TUIColor.dim + "─" + TUIColor.reset
        for (i, col) in columns.enumerated() {
            let w = colWidths[i]
            output += TUIColor.dim + pad(col.header, to: w) + (i < columns.count - 1 ? " " : "") + TUIColor.reset
        }
        output += "\n"

        // ── Session 行 ─────────────────────────────────────────
        for (idx, session) in sessions.enumerated() {
            let isSelected = idx == selectedIndex
            let sid = session.sessionId

            // 构建 extras
            let extras = SessionExtras(
                unread: unreadCache[sid] ?? nil,
                messages: messageCache[sid] ?? [],
                usage: usageCache[sid]
            )

            // 行前缀
            if isSelected {
                output += TUIColor.bgCyan + TUIColor.black + "▸" + TUIColor.reset + " "
            } else {
                output += "  "
            }

            // 渲染每列
            for (i, col) in columns.enumerated() {
                let w = colWidths[i]
                var (text, colorKey) = col.extract(session, extras)

                // Badge 列特殊处理
                if col.key == "badge" {
                    if extras.unread != nil {
                        text = " ●"
                    } else if isSelected {
                        text = " "
                    }
                }

                // 截断
                text = truncate(text, maxLen: w)

                // 颜色
                let color: String
                if isSelected {
                    if col.key == "badge" && extras.unread != nil {
                        color = TUIColor.red + TUIColor.bold
                    } else if col.key == "id" {
                        color = TUIColor.bold
                    } else if col.key == "status" {
                        color = TUIColor.forStatus(session.status)
                    } else {
                        color = ""
                    }
                    // 选中背景
                    output += TUIColor.bgCyan + TUIColor.black
                } else {
                    if col.key == "badge" && extras.unread != nil {
                        color = TUIColor.red + TUIColor.bold
                    } else if col.key == "status" {
                        color = TUIColor.forStatus(session.status)
                    } else if colorKey == "dim" {
                        color = TUIColor.dim
                    } else {
                        color = ""
                    }
                }

                output += color + pad(text, to: w) + TUIColor.reset
                if i < columns.count - 1 { output += " " }
            }
            output += "\n"
        }

        // ── 详细消息区 ─────────────────────────────────────────
        output += "\n"

        if selectedIndex < sessions.count {
            let session = sessions[selectedIndex]
            let sid = session.sessionId
            let msgs = messageCache[sid] ?? []

            // 显示 session ID 和项目
            let shortId = String(sid.prefix(8))
            let proj = URL(fileURLWithPath: session.project).lastPathComponent
            output += TUIColor.cyan + TUIColor.dim + "─── \(shortId) · \(proj) " + TUIColor.reset + "\n"

            // 显示消息
            for msg in msgs {
                let prefix: String
                let prefixColor: String
                switch msg.role {
                case "user":
                    prefix = " > "
                    prefixColor = TUIColor.cyan + TUIColor.bold
                case "assistant":
                    prefix = " ◀ "
                    prefixColor = TUIColor.yellow + TUIColor.bold
                case "tool":
                    prefix = " ⚡ "
                    prefixColor = TUIColor.magenta + TUIColor.dim
                default:
                    prefix = " · "
                    prefixColor = TUIColor.dim
                }

                let lines = msg.text.split(separator: "\n")
                for (i, line) in lines.enumerated() {
                    if i == 0 {
                        output += prefixColor + prefix + TUIColor.reset
                    } else {
                        output += "   "
                    }
                    output += truncate(oneline(String(line)), maxLen: termWidth - 4) + "\n"
                }
            }
        }

        // ── 帮助面板 ─────────────────────────────────────────
        if showHelp {
            output += "\n"
            output += TUIColor.cyan + "─── Help ───" + TUIColor.reset + "\n"
            output += "  ↑/k    Move up\n"
            output += "  ↓/j    Move down\n"
            output += "  Enter  Switch to terminal\n"
            output += "  s      Send message\n"
            output += "  n      Add note\n"
            output += "  r      Refresh\n"
            output += "  h      Toggle help\n"
            output += "  q      Quit\n"
        }

        return output
    }

    // MARK: - 列宽计算

    private func calculateColumnWidths(totalWidth: Int) -> [Int] {
        let gaps = columns.count - 1  // 列间距
        let available = max(columns.count, totalWidth - gaps - 2)  // 减去行前缀
        let totalWeight = columns.reduce(0) { $0 + $1.weight }

        var widths: [Int] = []
        var used = 0

        for i in 0..<columns.count {
            if i == columns.count - 1 {
                widths.append(max(1, available - used))
            } else {
                let w = max(4, available * columns[i].weight / totalWeight)
                widths.append(w)
                used += w
            }
        }

        return widths
    }

    private func getTerminalWidth() -> Int {
        var w = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &w)
        return Int(w.ws_col) > 0 ? Int(w.ws_col) : 80
    }

    // MARK: - 输入处理

    public mutating func handleInput(_ key: String) -> Bool {
        switch key {
        case "q", "Q":
            running = false
            return false

        case "k":
            selectedIndex = max(0, selectedIndex - 1)

        case "j":
            selectedIndex = min(max(0, sessions.count - 1), selectedIndex + 1)

        case "r", "R":
            refreshSessions()
            selectedIndex = min(selectedIndex, max(0, sessions.count - 1))

        case "h", "H":
            showHelp.toggle()

        case "\n", "\r":
            if selectedIndex < sessions.count {
                print("\u{1B}[2J\u{1B}[H")
                print("Switching to terminal for session \(sessions[selectedIndex].sessionId.prefix(8))...")
                // 这里可以调用跳转逻辑
            }

        default:
            break
        }

        return running
    }

    // MARK: - 运行循环

    public mutating func run() {
        // 检查是否是真正的终端
        guard isatty(STDIN_FILENO) == 1 else {
            print("Error: TUI requires an interactive terminal")
            print("Run: meee2 list  (for non-interactive output)")
            return
        }

        // 保存原始终端设置
        var original = termios()
        let tcResult = tcgetattr(STDIN_FILENO, &original)
        if tcResult == 0 {
            originalTermios = original

            // 设置 raw 模式
            var raw = original
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }

        // 确保退出时恢复终端设置
        defer {
            if var orig = originalTermios {
                tcsetattr(STDIN_FILENO, TCSANOW, &orig)
            }
            // 显示光标
            print("\u{1B}[?25h", terminator: "")
        }

        // 隐藏光标
        print("\u{1B}[?25l", terminator: "")
        fflush(stdout)

        // 主循环
        while running {
            // 渲染
            print(render(), terminator: "")
            fflush(stdout)

            // 读取单个字符
            var ch: UInt8 = 0
            let n = read(STDIN_FILENO, &ch, 1)
            if n > 0 {
                // 处理转义序列（方向键）
                if ch == 27 { // ESC
                    var seq: [UInt8] = [0, 0]
                    let n1 = read(STDIN_FILENO, &seq[0], 1)
                    let n2 = read(STDIN_FILENO, &seq[1], 1)
                    if n1 > 0 && n2 > 0 && seq[0] == 91 {
                        if seq[1] == 65 && !sessions.isEmpty { // Up
                            selectedIndex = max(0, selectedIndex - 1)
                        } else if seq[1] == 66 && !sessions.isEmpty { // Down
                            selectedIndex = min(sessions.count - 1, selectedIndex + 1)
                        }
                        continue
                    }
                }

                let key = String(UnicodeScalar(ch))
                if !handleInput(key) {
                    break
                }
            }
        }

        // 清屏退出
        print("\u{1B}[2J\u{1B}[H")
        print("Goodbye!")
    }
}
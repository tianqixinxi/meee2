import Foundation
import Meee2PluginKit
import Darwin

// MARK: - Session Extras

/// Additional session data for display
struct SessionExtras {
    var messages: [(role: String, text: String)]
    var usage: UsageStats?
}

// MARK: - Dashboard View (ANSI-based with curses-like API)

/// TUI Dashboard using ANSI escape codes (matches csm visual style)
public struct DashboardView {
    // MARK: - State

    private var sessions: [SessionData] = []
    private var selectedIndex: Int = 0
    private var running: Bool = true
    private var lastRefresh: Date = Date.distantPast
    private var messageCache: [String: [(role: String, text: String)]] = [:]
    private var usageCache: [String: UsageStats] = [:]

    // Refresh interval (seconds)
    private let refreshInterval: TimeInterval = 2.0

    // Column configuration
    private let columns = defaultColumns

    // MARK: - Initialization

    public init() {
        refreshData()
    }

    // MARK: - Data Management

    private mutating func refreshData() {
        // 从磁盘重新加载，同步 GUI 进程的更新
        SessionStore.shared.reloadFromDisk()
        // 只显示活跃 sessions，并验证进程存活
        var activeSessions = SessionStore.shared.listActive()
        activeSessions = activeSessions.filter { session in
            // 验证进程是否存活
            guard let pid = session.pid else { return false }
            let isAlive = checkProcessAlive(pid: pid)
            if !isAlive {
                // 进程已结束，清理缓存
                SessionStore.shared.delete(session.sessionId)
            }
            return isAlive
        }
        sessions = activeSessions
        lastRefresh = Date()
        refreshCaches()
    }

    /// 检查进程是否存活
    private func checkProcessAlive(pid: Int) -> Bool {
        let result = kill(pid_t(pid), 0)
        return result == 0
    }

    private mutating func refreshCaches() {
        for session in sessions {
            let sid = session.sessionId

            // Load messages from transcript
            if let path = session.transcriptPath {
                messageCache[sid] = TranscriptParser.loadMessages(transcriptPath: path, count: 5)
            }

            // Load usage stats
            usageCache[sid] = session.usageStats
        }
    }

    // MARK: - Main Run Loop

    public mutating func run() {
        // Check if running in interactive terminal
        guard isatty(STDIN_FILENO) == 1 else {
            print("Error: TUI requires an interactive terminal")
            print("Run: meee2 list  (for non-interactive output)")
            return
        }

        // Initialize terminal
        let term = initscr()
        defer {
            endwin()
            print("Goodbye!")
        }

        // Configure terminal
        _ = curs_set(0)  // Hide cursor
        initCursesColors()

        // Main event loop
        while running {
            // Update terminal size (handle resize)
            term.updateSize()

            // Auto-refresh data every refreshInterval seconds
            if Date().timeIntervalSince(lastRefresh) >= refreshInterval {
                refreshData()
                // Keep selected index in bounds
                selectedIndex = min(selectedIndex, max(0, sessions.count - 1))
            }

            // Draw screen
            draw()

            // Handle input (100ms timeout built into raw mode)
            let ch = getch()

            if ch == -1 {
                // Timeout - continue loop
                continue
            }

            handleInput(ch)
        }
    }

    // MARK: - Drawing

    private func draw() {
        erase()

        let h = Int(LINES)
        let w = Int(COLS)
        let widths = calcColumnWidths(totalWidth: w - 2, columns: columns)  // -2 for side borders

        var row = 0

        // ── Header Bar ─────────────────────────────────────────
        drawHeader(row: row, width: w)
        row += 1

        if sessions.isEmpty {
            drawEmptyState(row: row + 1, width: w)
            refresh()
            return
        }

        // ── Table Top Border ───────────────────────────────────
        drawHorizontalLine(row: row, widths: widths, kind: "top")
        row += 1

        // ── Table Header ───────────────────────────────────────
        drawTableHeader(row: row, widths: widths, columns: columns)
        row += 1

        // ── Session Rows ───────────────────────────────────────
        let maxRows = min(sessions.count, h - row - 5)  // Leave space for detail and status

        for idx in 0..<maxRows {
            let session = sessions[idx]
            let isSelected = idx == selectedIndex

            drawSessionRow(
                row: row,
                widths: widths,
                session: session,
                isSelected: isSelected
            )
            row += 1
        }

        // ── Table Bottom Border ────────────────────────────────
        if row < h - 3 {
            drawHorizontalLine(row: row, widths: widths, kind: "bot")
            row += 1
        }

        // ── Detail Section ─────────────────────────────────────
        if row < h - 2 {
            row += 1  // Blank line
            drawDetailSection(row: row, height: h - row - 1, width: w)
        }

        refresh()
    }

    private func drawHeader(row: Int, width: Int) {
        move(CursesInt(row), 0)
        // No background color, just bold title
        let headerText = ANSIColor.bold + " MEEE2 Dashboard " + ANSIColor.reset
        addstr(headerText)

        let helpText = ANSIColor.dim + "  ↑↓ select  ⏎ switch  r refresh  q quit" + ANSIColor.reset
        addstr(helpText.truncate(maxWidth: width - 17))
    }

    private func drawEmptyState(row: Int, width: Int) {
        move(CursesInt(row), 2)
        addstr(ANSIColor.dim + "No active sessions." + ANSIColor.reset)
        move(CursesInt(row + 1), 2)
        addstr(ANSIColor.dim + "Start Claude Code to see sessions here." + ANSIColor.reset)
        move(CursesInt(row + 2), 2)
        addstr(ANSIColor.dim + "Press q to quit." + ANSIColor.reset)
    }

    private func drawSessionRow(row: Int, widths: [Int], session: SessionData, isSelected: Bool) {
        // Use the same drawing logic as Table.drawTableRow for consistency
        let sid = session.sessionId
        let extras = SessionExtras(
            messages: messageCache[sid] ?? [],
            usage: usageCache[sid]
        )

        var cells: [String] = []
        for (i, col) in columns.enumerated() {
            let w = widths[i]
            let (text, _) = extractCellData(
                column: col.key,
                session: session,
                extras: extras,
                isSelected: isSelected,
                maxWidth: w
            )
            // Use display-width-aware padding for emoji/CJK alignment
            cells.append(padToDisplayWidth(text, width: w))
        }

        // Use the standard table row drawing
        drawTableRow(row: row, widths: widths, cells: cells, attrs: nil, isSelected: isSelected)
    }

    private func extractCellData(column key: String, session: SessionData, extras: SessionExtras, isSelected: Bool, maxWidth: Int = 0) -> (text: String, attr: Chtype) {
        var text: String
        let attr: Chtype = A_NORMAL

        switch key {
        case "badge":
            text = isSelected ? "▸" : " "

        case "id":
            text = shortId(session.sessionId)

        case "project":
            text = shortPath(session.project)

        case "status":
            // 获取有效状态（当 detailedStatus 为 idle 但 status 为 running 时使用 active）
            let effectiveStatus: DetailedStatus
            if session.detailedStatus != .idle {
                effectiveStatus = session.detailedStatus
            } else {
                effectiveStatus = DetailedStatus.from(sessionStatus: SessionStatus(rawValue: session.status) ?? .running)
            }
            let icon = effectiveStatus.terminalIcon
            let name = effectiveStatus.displayName
            if let tool = session.currentTool, !tool.isEmpty {
                text = "*\(tool)"  // Use * instead of lightning emoji
            } else {
                text = "\(icon) \(name)"
            }

        case "cost":
            text = formatCost(extras.usage?.costUSD ?? 0)

        case "last_msg":
            if let last = extras.messages.last {
                let prefix: String
                switch last.role {
                case "user": prefix = ">"  // ASCII
                case "assistant": prefix = "<"  // ASCII instead of ◀
                case "tool": prefix = "*"  // ASCII instead of ⚡
                default: prefix = "."  // ASCII instead of ·
                }
                let msg = "\(prefix) \(oneline(last.text))"
                // 根据列宽度截断，考虑 emoji 显示宽度
                text = truncateForDisplay(msg, maxWidth: maxWidth)
            } else {
                text = ""
            }

        case "updated":
            text = formatRelativeTime(session.lastActivity)

        default:
            text = ""
        }

        return (text, attr)
    }

    private func drawDetailSection(row: Int, height: Int, width: Int) {
        guard selectedIndex < sessions.count else { return }

        let session = sessions[selectedIndex]
        let sid = session.sessionId
        let msgs = messageCache[sid] ?? []

        // Section header
        move(CursesInt(row), 0)
        let headerText = "--- \(shortId(sid)) · \(shortPath(session.project)) "
        let remaining = max(0, width - calcDisplayWidth(headerText))
        let header = ANSIColor.cyan + ANSIColor.dim + headerText + String(repeating: BoxChars.horizontal, count: remaining) + ANSIColor.reset
        addstr(header.truncate(maxWidth: width))

        // Messages
        var currentRow = row + 1
        for msg in msgs {
            if currentRow >= row + height { break }

            let prefix: String
            let prefixColor: String
            switch msg.role {
            case "user":
                prefix = " > "
                prefixColor = ANSIColor.cyan + ANSIColor.bold
            case "assistant":
                prefix = " < "
                prefixColor = ANSIColor.yellow + ANSIColor.bold
            case "tool":
                prefix = " * "
                prefixColor = ANSIColor.magenta + ANSIColor.dim
            default:
                prefix = " . "
                prefixColor = ANSIColor.dim
            }

            move(CursesInt(currentRow), 0)
            addstr(prefixColor + prefix + ANSIColor.reset)

            let text = oneline(msg.text).truncate(maxWidth: width - 4)
            addstr(text)

            currentRow += 1
        }
    }

    // MARK: - Input Handling

    private mutating func handleInput(_ ch: CursesInt) {
        switch ch {
        case Int32(Character("q").asciiValue!), Int32(Character("Q").asciiValue!):
            running = false

        case KEY_UP, Int32(Character("k").asciiValue!):
            selectedIndex = max(0, selectedIndex - 1)

        case KEY_DOWN, Int32(Character("j").asciiValue!):
            selectedIndex = min(max(0, sessions.count - 1), selectedIndex + 1)

        case Int32(Character("r").asciiValue!), Int32(Character("R").asciiValue!):
            refreshData()
            selectedIndex = min(selectedIndex, max(0, sessions.count - 1))

        case Int32(Character("\n").asciiValue!), Int32(Character("\r").asciiValue!), KEY_ENTER:
            if selectedIndex < sessions.count {
                switchToSession(sessions[selectedIndex])
            }

        case Int32(Character("s").asciiValue!), Int32(Character("S").asciiValue!):
            // TODO: Send message to session
            break

        default:
            break
        }
    }

    private mutating func switchToSession(_ session: SessionData) {
        // 暂时退出 alternate screen (恢复原终端)
        endwin()

        // Create AISession with full terminal info (same as GUI)
        var aiSession = AISession(
            id: session.sessionId,
            pid: session.pid ?? 0,
            cwd: session.project,
            startedAt: session.startedAt,
            status: SessionStatus(rawValue: session.status) ?? .running
        )

        // Copy all terminal info from SessionData (same as GUI path)
        if let info = session.terminalInfo {
            aiSession.tty = info.tty
            aiSession.termProgram = info.termProgram
            aiSession.termBundleId = info.termBundleId
            aiSession.cmuxSocketPath = info.cmuxSocketPath
            aiSession.cmuxSurfaceId = info.cmuxSurfaceId
        }

        // Activate using TerminalManager (same as GUI)
        TerminalManager.smartActivateTerminal(forSession: aiSession)

        // 等待 cmux 完成窗口切换
        usleep(300_000) // 300ms

        // 显示返回提示（已在正常终端，endwin 恢复了原始终端）
        print("")
        print("\u{1b}[1;36m→ 已跳转到 session 终端\u{1b}[0m")
        print("\u{1b}[2m按 Enter 返回 TUI (或 Ctrl+C 退出)\u{1b}[0m")
        print("")

        // 等待用户按键返回
        // 在正常终端模式下，read 会阻塞直到有输入
        var buf: UInt8 = 0
        _ = read(STDIN_FILENO, &buf, 1)

        // 重新进入 TUI
        _ = initscr()
        _ = curs_set(0)
    }
}

// MARK: - String Extensions

extension String {
    /// Truncate string to fit within given display width
    public func truncate(maxWidth: Int) -> String {
        if self.count <= maxWidth { return self }
        if maxWidth <= 2 { return String(self.prefix(maxWidth)) }
        return String(self.prefix(maxWidth - 2)) + ".."
    }
}

/// Truncate string considering display width (emoji = 2 chars, CJK = 2 chars)
private func truncateForDisplay(_ text: String, maxWidth: Int) -> String {
    if maxWidth <= 0 { return "" }

    var displayWidth = 0
    var result = ""

    for char in text {
        let charWidth: Int
        if char.isEmoji || char.isCJK {
            charWidth = 2
        } else {
            charWidth = 1
        }

        if displayWidth + charWidth > maxWidth - 2 {
            // Not enough space, add ".."
            if result.isEmpty {
                return ".."
            }
            return result + ".."
        }

        result.append(char)
        displayWidth += charWidth
    }

    return result
}

private extension Character {
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.properties.isEmoji
    }

    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) || // CJK Unified Ideographs
               (0x3000...0x303F).contains(scalar.value) || // CJK Symbols and Punctuation
               (0xFF00...0xFFEF).contains(scalar.value)    // Halfwidth and Fullwidth Forms
    }
}
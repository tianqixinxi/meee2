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
        sessions = SessionStore.shared.sessions
        lastRefresh = Date()
        refreshCaches()
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
        curs_set(0)  // Hide cursor
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

        // ── Table Header Border ────────────────────────────────
        drawHorizontalLine(row: row, widths: widths, kind: "mid")
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
                isSelected: isSelected
            )
            cells.append(String(text.prefix(w)).padding(toLength: w, withPad: " ", startingAt: 0))
        }

        // Use the standard table row drawing
        drawTableRow(row: row, widths: widths, cells: cells, attrs: nil, isSelected: isSelected)
    }

    private func extractCellData(column key: String, session: SessionData, extras: SessionExtras, isSelected: Bool) -> (text: String, attr: Chtype) {
        var text: String
        var attr: Chtype = A_NORMAL

        switch key {
        case "badge":
            text = isSelected ? "▸" : " "

        case "id":
            text = shortId(session.sessionId)

        case "project":
            text = shortPath(session.project)

        case "status":
            let status = session.detailedStatus
            let icon = status.terminalIcon
            let name = status.displayName
            if let tool = session.currentTool, !tool.isEmpty {
                text = "⚡\(tool)"
            } else {
                text = "\(icon)\(name)"
            }

        case "cost":
            text = formatCost(extras.usage?.costUSD ?? 0)

        case "last_msg":
            if let last = extras.messages.last {
                let prefix: String
                switch last.role {
                case "user": prefix = ">"
                case "assistant": prefix = "◀"
                case "tool": prefix = "⚡"
                default: prefix = "·"
                }
                text = "\(prefix) \(oneline(last.text))"
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
        let headerText = "─── \(shortId(sid)) · \(shortPath(session.project)) "
        let remaining = max(0, width - headerText.count)
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
                prefix = " ◀ "
                prefixColor = ANSIColor.yellow + ANSIColor.bold
            case "tool":
                prefix = " ⚡ "
                prefixColor = ANSIColor.magenta + ANSIColor.dim
            default:
                prefix = " · "
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

        // Create AISession with terminal info
        var aiSession = AISession(
            id: session.sessionId,
            pid: session.pid ?? 0,
            cwd: session.project,
            startedAt: session.startedAt,
            status: SessionStatus(rawValue: session.status) ?? .running
        )

        // Add terminal info
        if let info = session.terminalInfo {
            aiSession.tty = info.tty
            aiSession.termProgram = info.termProgram
            aiSession.termBundleId = info.termBundleId
            aiSession.cmuxSocketPath = info.cmuxSocketPath
            aiSession.cmuxSurfaceId = info.cmuxSurfaceId
        }

        // Activate using TerminalManager
        TerminalManager.smartActivateTerminal(forSession: aiSession)

        // 等待用户回到 TUI 窗口
        // 提示用户按任意键返回
        print("\n\x1b[1;36m→ 已跳转到 session 终端\x1b[0m")
        print("\x1b[2m按 Enter 返回 TUI...\x1b[0m")

        // 等待用户按键
        _ = read(STDIN_FILENO, UnsafeMutablePointer<UInt8>.allocate(capacity: 1), 1)

        // 重新进入 TUI
        let term = initscr()
        curs_set(0)
        // term 已在 run() 的 defer 中管理，这里不需要再次 defer
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
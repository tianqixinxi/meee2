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
    // MARK: - View Mode

    /// 当前展示的视图标签页
    private enum ViewMode: Equatable {
        case sessions
        case channels
        /// 钻入某个频道的消息列表
        case channelDetail(channelName: String)
    }

    /// 需要确认的危险操作
    private enum ConfirmAction {
        case deleteChannel(name: String)
    }

    // MARK: - State

    private var sessions: [SessionData] = []
    private var selectedIndex: Int = 0
    private var running: Bool = true
    private var lastRefresh: Date = Date.distantPast
    private var messageCache: [String: [(role: String, text: String)]] = [:]
    private var usageCache: [String: UsageStats] = [:]

    // Channels-tab caches
    private var viewMode: ViewMode = .sessions
    private var channels: [Channel] = []
    private var channelPendingCounts: [String: Int] = [:]
    private var channelSelectedIndex: Int = 0

    // Channel detail caches
    private var detailMessages: [A2AMessage] = []
    private var messageSelectedIndex: Int = 0

    // Transient confirmation prompt
    private var pendingConfirm: ConfirmAction? = nil

    // Transient status message (shown for 3s in the help line area)
    private var statusMessage: String? = nil
    private var statusMessageSetAt: Date = .distantPast

    // Refresh interval (seconds)
    // TODO(wave13): subscribe to SessionEventBus for immediate redraws. Today's
    // DashboardView is a struct with mutating methods, so wiring an AnyCancellable
    // in requires boxing state into a reference type. 2s poll is OK for MVP TUI.
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
        refreshChannelData()
        // 当前在 channel detail 视图时也刷新消息
        if case .channelDetail(let name) = viewMode {
            refreshDetailMessages(channel: name)
        }
    }

    /// 刷新 channels 标签页所需的数据（频道列表 + 每个频道的 pending 消息数）
    private mutating func refreshChannelData() {
        let all = ChannelRegistry.shared.list()
        channels = all
        var counts: [String: Int] = [:]
        for ch in all {
            let n = MessageRouter.shared
                .listMessages(channel: ch.name, statuses: [.pending, .held])
                .count
            counts[ch.name] = n
        }
        channelPendingCounts = counts
        // Clamp selection
        if channels.isEmpty {
            channelSelectedIndex = 0
        } else {
            channelSelectedIndex = min(channelSelectedIndex, channels.count - 1)
        }
    }

    /// 刷新 channel detail 视图的消息列表（newest-first）
    private mutating func refreshDetailMessages(channel: String) {
        let all = MessageRouter.shared.listMessages(channel: channel, statuses: nil)
        // Newest first
        detailMessages = all.sorted { $0.createdAt > $1.createdAt }
        if detailMessages.isEmpty {
            messageSelectedIndex = 0
        } else {
            messageSelectedIndex = min(messageSelectedIndex, detailMessages.count - 1)
        }
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

    /// 设置一条短暂状态消息（自动在 3s 后消失）
    private mutating func setStatus(_ msg: String) {
        statusMessage = msg
        statusMessageSetAt = Date()
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

        switch viewMode {
        case .channels:
            drawChannelsView(startRow: row, width: w, height: h)
            drawBottomLine(height: h, width: w)
            refresh()
            return
        case .channelDetail(let name):
            // 如果频道已被外部删除，自动返回 channels
            if ChannelRegistry.shared.get(name) == nil {
                // Can't mutate self from draw(); defer via status message; handleInput will notice on next tick.
                // For now just show an empty-ish view; the mutating refresh happens via refreshData.
            }
            drawChannelDetailView(channelName: name, startRow: row, width: w, height: h)
            drawBottomLine(height: h, width: w)
            refresh()
            return
        case .sessions:
            break
        }

        if sessions.isEmpty {
            drawEmptyState(row: row + 1, width: w)
            drawBottomLine(height: h, width: w)
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

        // ── Bottom Status/Help Line ────────────────────────────
        drawBottomLine(height: h, width: w)

        refresh()
    }

    private func drawHeader(row: Int, width: Int) {
        move(CursesInt(row), 0)
        // No background color, just bold title
        let headerText = ANSIColor.bold + " MEEE2 Dashboard " + ANSIColor.reset
        addstr(headerText)

        // Tab indicator: active tab bold+reverse, inactive dim
        let sessionsTab: String
        let channelsTab: String
        var extraSegment: String = ""

        switch viewMode {
        case .sessions:
            sessionsTab = ANSIColor.bold + ANSIColor.reverse + " sessions (s) " + ANSIColor.reset
            channelsTab = ANSIColor.dim + " channels (c) " + ANSIColor.reset
        case .channels:
            sessionsTab = ANSIColor.dim + " sessions (s) " + ANSIColor.reset
            channelsTab = ANSIColor.bold + ANSIColor.reverse + " channels (c) " + ANSIColor.reset
        case .channelDetail(let name):
            sessionsTab = ANSIColor.dim + " sessions (s) " + ANSIColor.reset
            channelsTab = ANSIColor.dim + " channels (c) " + ANSIColor.reset
            let badge: String
            if let ch = ChannelRegistry.shared.get(name) {
                badge = channelModeBadge(ch.mode)
            } else {
                badge = ANSIColor.dim + "GONE" + ANSIColor.reset
            }
            extraSegment = "  " + ANSIColor.bold + "channel: " + name + ANSIColor.reset + "  " + badge
        }
        addstr(sessionsTab + " " + channelsTab + extraSegment)
    }

    /// 底部最后一行：显示 help hint 或者临时状态消息或者确认 prompt。
    private func drawBottomLine(height: Int, width: Int) {
        let bottomRow = max(0, height - 1)
        move(CursesInt(bottomRow), 0)

        // Confirm prompt takes priority.
        if let confirm = pendingConfirm {
            let prompt: String
            switch confirm {
            case .deleteChannel(let name):
                prompt = " Delete channel '\(name)'? [y/N] "
            }
            // Red background, bold
            let styled = ANSIColor.reverse + ANSIColor.bold + ANSIColor.red + prompt + ANSIColor.reset
            addstr(styled.truncate(maxWidth: width))
            return
        }

        // Recent status message takes next priority.
        if let sm = statusMessage, Date().timeIntervalSince(statusMessageSetAt) < 3.0 {
            let color: String
            if sm.hasPrefix("Error:") {
                color = ANSIColor.red + ANSIColor.bold
            } else {
                color = ANSIColor.green + ANSIColor.bold
            }
            let text = color + " " + sm + " " + ANSIColor.reset
            addstr(text.truncate(maxWidth: width))
            return
        }

        // Default: per-mode help hints.
        let hint: String
        switch viewMode {
        case .sessions:
            hint = "  ↑↓ select  ⏎ detail  r refresh  q quit"
        case .channels:
            hint = "  ↑↓ select  ⏎ open  m mode  D delete  r refresh  q quit"
        case .channelDetail:
            hint = "  ↑↓ select  d deliver  h hold  x drop  b back  r refresh  q quit"
        }
        addstr((ANSIColor.dim + hint + ANSIColor.reset).truncate(maxWidth: width))
    }

    private func drawEmptyState(row: Int, width: Int) {
        move(CursesInt(row), 2)
        addstr(ANSIColor.dim + "No active sessions." + ANSIColor.reset)
        move(CursesInt(row + 1), 2)
        addstr(ANSIColor.dim + "Start Claude Code to see sessions here." + ANSIColor.reset)
        move(CursesInt(row + 2), 2)
        addstr(ANSIColor.dim + "Press q to quit." + ANSIColor.reset)
    }

    // MARK: - Channels View

    /// Render the channels tab as a vertical listing with selection cursor.
    private func drawChannelsView(startRow: Int, width: Int, height: Int) {
        if channels.isEmpty {
            // Centered empty-state message
            let msg = "No channels. Create one with `meee2 channel create <name>`."
            let contentRow = startRow + max(1, (height - startRow) / 2)
            let col = max(0, (width - msg.count) / 2)
            move(CursesInt(contentRow), CursesInt(col))
            addstr(ANSIColor.dim + msg + ANSIColor.reset)
            return
        }

        var row = startRow + 1  // blank line after header
        // Reserve the last row for help/status line.
        let maxRow = height - 1

        for (idx, ch) in channels.enumerated() {
            // Bail out if we've run out of vertical room
            if row >= maxRow { break }

            let isSelected = idx == channelSelectedIndex
            let badgePrefix = isSelected
                ? ANSIColor.cyan + ANSIColor.bold + "▸ " + ANSIColor.reset
                : "  "

            // Line 1: <badge> <name>  <MODE-badge>  members=N  pending=K
            let name: String
            if isSelected {
                name = ANSIColor.bold + ANSIColor.cyan + ch.name + ANSIColor.reset
            } else {
                name = ANSIColor.bold + ch.name + ANSIColor.reset
            }
            let badge = channelModeBadge(ch.mode)
            let memberCount = ANSIColor.dim + "members=\(ch.members.count)" + ANSIColor.reset
            let pending = channelPendingCounts[ch.name] ?? 0
            let pendingStr: String
            if pending > 0 {
                pendingStr = ANSIColor.yellow + "pending=\(pending)" + ANSIColor.reset
            } else {
                pendingStr = ANSIColor.dim + "pending=0" + ANSIColor.reset
            }
            move(CursesInt(row), 0)
            addstr("\(badgePrefix)\(name)  \(badge)  \(memberCount)  \(pendingStr)")
            row += 1
            if row >= maxRow { break }

            // Line 2: member list "  alias (sid abc12345..) / alias2 (sid def...)"
            move(CursesInt(row), 4)
            if ch.members.isEmpty {
                addstr(ANSIColor.dim + "(no members)" + ANSIColor.reset)
            } else {
                let parts = ch.members.map { m -> String in
                    let sid = shortId(m.sessionId)
                    return "\(ANSIColor.cyan)\(m.alias)\(ANSIColor.reset) \(ANSIColor.dim)(sid \(sid)..)\(ANSIColor.reset)"
                }
                addstr(parts.joined(separator: " / "))
            }
            row += 1

            // Line 3 (optional): description
            if let d = ch.description, !d.isEmpty, row < maxRow {
                move(CursesInt(row), 4)
                // Dim + italic (ANSI italic = \x1b[3m)
                addstr(ANSIColor.dim + "\u{1B}[3m" + d + ANSIColor.reset)
                row += 1
            }

            // Blank line separator
            if row < maxRow {
                row += 1
            }
        }
    }

    // MARK: - Channel Detail View

    /// Render the channel-detail (messages) view.
    private func drawChannelDetailView(channelName: String, startRow: Int, width: Int, height: Int) {
        // Reserve last row for help line.
        let helpRow = height - 1
        // Reserve bottom detail section: header line + up to 6 content lines + separator
        let detailBlockHeight = 8
        let listEndRow = max(startRow + 2, helpRow - detailBlockHeight - 1)

        if detailMessages.isEmpty {
            let msg = "No messages on channel '\(channelName)'."
            let contentRow = startRow + max(1, (listEndRow - startRow) / 2)
            let col = max(0, (width - msg.count) / 2)
            move(CursesInt(contentRow), CursesInt(col))
            addstr(ANSIColor.dim + msg + ANSIColor.reset)
            return
        }

        var row = startRow + 1  // blank line after header

        // TODO: viewport scrolling for long message lists. For MVP we truncate
        // to the first N (newest) messages that fit on screen.
        let visibleCount = max(1, listEndRow - row)
        let count = min(detailMessages.count, visibleCount)

        for idx in 0..<count {
            if row >= listEndRow { break }
            let msg = detailMessages[idx]
            let isSelected = idx == messageSelectedIndex

            let badgePrefix = isSelected
                ? ANSIColor.cyan + ANSIColor.bold + "▸ " + ANSIColor.reset
                : "  "

            let mid = shortId(msg.id)
            let fromTo = "\(msg.fromAlias) → \(msg.toAlias)"
            let statusStr = statusLabel(msg.status)
            let age = formatRelativeTime(msg.createdAt)

            var line = "\(badgePrefix)"
            line += ANSIColor.dim + mid + ANSIColor.reset + "  "
            line += ANSIColor.cyan + fromTo + ANSIColor.reset + "  "
            line += statusStr + "  "
            line += ANSIColor.dim + age + ANSIColor.reset

            // Fanout detail for broadcast messages
            if msg.toAlias == "*" {
                let tail: String
                if msg.status == .delivered && !msg.deliveredTo.isEmpty {
                    tail = "  " + ANSIColor.dim + "(fanout=[" + msg.deliveredTo.joined(separator: ",") + "])" + ANSIColor.reset
                } else {
                    tail = "  " + ANSIColor.dim + "(fanout pending)" + ANSIColor.reset
                }
                line += tail
            }

            move(CursesInt(row), 0)
            addstr(line)
            row += 1
        }

        // ── Detail panel: full content of selected message ─────
        let detailStartRow = max(row + 1, helpRow - detailBlockHeight)
        if detailStartRow < helpRow - 1 && messageSelectedIndex < detailMessages.count {
            let selected = detailMessages[messageSelectedIndex]
            let divider = "--- selected message "
            let remaining = max(0, width - calcDisplayWidth(divider))
            let headerLine = ANSIColor.cyan + ANSIColor.dim + divider
                + String(repeating: BoxChars.horizontal, count: remaining) + ANSIColor.reset
            move(CursesInt(detailStartRow), 0)
            addstr(headerLine.truncate(maxWidth: width))

            // Word-wrap content lines; max 6 lines, ellipsize after
            let content = selected.content
            let wrapped = wrapContent(content, width: max(10, width - 2))
            let maxLines = 6
            var linesToShow = Array(wrapped.prefix(maxLines))
            if wrapped.count > maxLines {
                // Append ellipsis to last shown line
                if var last = linesToShow.last {
                    let maxLen = max(1, (width - 2) - 3)
                    if last.count > maxLen { last = String(last.prefix(maxLen)) }
                    linesToShow[linesToShow.count - 1] = last + "..."
                }
            }

            var contentRow = detailStartRow + 1
            for line in linesToShow {
                if contentRow >= helpRow - 1 { break }
                move(CursesInt(contentRow), 1)
                addstr(line)
                contentRow += 1
            }

            // Separator
            if contentRow < helpRow - 1 {
                move(CursesInt(contentRow), 0)
                addstr(ANSIColor.dim + String(repeating: BoxChars.horizontal, count: width) + ANSIColor.reset)
            }
        }
    }

    /// Colored status label for a message.
    private func statusLabel(_ status: MessageStatus) -> String {
        switch status {
        case .pending:
            return ANSIColor.yellow + ANSIColor.bold + "PENDING" + ANSIColor.reset
        case .held:
            return ANSIColor.magenta + ANSIColor.bold + "HELD" + ANSIColor.reset
        case .delivered:
            return ANSIColor.green + ANSIColor.dim + "DELIVERED" + ANSIColor.reset
        case .dropped:
            return ANSIColor.red + ANSIColor.dim + "DROPPED" + ANSIColor.reset
        }
    }

    /// Simple word wrap. Splits on whitespace, falls back to hard break if a single token is longer than width.
    private func wrapContent(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var out: [String] = []
        // Preserve explicit newlines in the source
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                out.append("")
                continue
            }
            var current = ""
            for word in line.split(separator: " ") {
                let w = String(word)
                if w.count > width {
                    // Flush current, then hard-split the word.
                    if !current.isEmpty { out.append(current); current = "" }
                    var remaining = w
                    while remaining.count > width {
                        out.append(String(remaining.prefix(width)))
                        remaining = String(remaining.dropFirst(width))
                    }
                    current = remaining
                    continue
                }
                if current.isEmpty {
                    current = w
                } else if current.count + 1 + w.count <= width {
                    current += " " + w
                } else {
                    out.append(current)
                    current = w
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    /// Colored badge for channel mode
    private func channelModeBadge(_ mode: ChannelMode) -> String {
        switch mode {
        case .auto:
            return ANSIColor.green + ANSIColor.bold + "AUTO" + ANSIColor.reset
        case .intercept:
            return ANSIColor.yellow + ANSIColor.bold + "INTERCEPT" + ANSIColor.reset
        case .paused:
            return ANSIColor.red + ANSIColor.bold + "PAUSED" + ANSIColor.reset
        }
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
        // If a confirmation is pending, it eats the next key.
        if let confirm = pendingConfirm {
            handleConfirmKey(ch, confirm: confirm)
            return
        }

        switch viewMode {
        case .sessions:
            handleSessionsInput(ch)
        case .channels:
            handleChannelsInput(ch)
        case .channelDetail(let name):
            handleDetailInput(ch, channelName: name)
        }
    }

    private mutating func handleConfirmKey(_ ch: CursesInt, confirm: ConfirmAction) {
        let yKey = Int32(Character("y").asciiValue!)
        let YKey = Int32(Character("Y").asciiValue!)
        defer { pendingConfirm = nil }
        if ch == yKey || ch == YKey {
            switch confirm {
            case .deleteChannel(let name):
                do {
                    try ChannelRegistry.shared.delete(name)
                    setStatus("OK: deleted channel '\(name)'")
                    refreshChannelData()
                    if channels.isEmpty {
                        channelSelectedIndex = 0
                    } else {
                        channelSelectedIndex = min(channelSelectedIndex, channels.count - 1)
                    }
                } catch {
                    setStatus("Error: \(error)")
                }
            }
        }
        // Any other key: just clears confirm (via defer).
    }

    private mutating func handleSessionsInput(_ ch: CursesInt) {
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
            viewMode = .sessions

        case Int32(Character("c").asciiValue!), Int32(Character("C").asciiValue!):
            viewMode = .channels
            refreshChannelData()

        default:
            break
        }
    }

    private mutating func handleChannelsInput(_ ch: CursesInt) {
        let hasChannels = !channels.isEmpty

        switch ch {
        case Int32(Character("q").asciiValue!), Int32(Character("Q").asciiValue!):
            running = false

        case Int32(Character("s").asciiValue!), Int32(Character("S").asciiValue!):
            viewMode = .sessions

        case Int32(Character("c").asciiValue!):
            // no-op (already on channels tab)
            break

        case Int32(Character("C").asciiValue!):
            // no-op (shift-C reserved; treat as no-op to avoid accidents)
            break

        default:
            guard hasChannels else {
                // Skip all other keys when no channels exist.
                return
            }

            switch ch {
            case KEY_UP, Int32(Character("k").asciiValue!):
                channelSelectedIndex = max(0, channelSelectedIndex - 1)

            case KEY_DOWN, Int32(Character("j").asciiValue!):
                channelSelectedIndex = min(channels.count - 1, channelSelectedIndex + 1)

            case Int32(Character("\n").asciiValue!), Int32(Character("\r").asciiValue!), KEY_ENTER:
                let name = channels[channelSelectedIndex].name
                viewMode = .channelDetail(channelName: name)
                messageSelectedIndex = 0
                refreshDetailMessages(channel: name)

            case Int32(Character("m").asciiValue!):
                // Cycle mode: auto -> intercept -> paused -> auto
                let ch0 = channels[channelSelectedIndex]
                let next: ChannelMode
                switch ch0.mode {
                case .auto: next = .intercept
                case .intercept: next = .paused
                case .paused: next = .auto
                }
                do {
                    _ = try ChannelRegistry.shared.setMode(ch0.name, mode: next)
                    setStatus("OK: \(ch0.name) mode -> \(next.rawValue)")
                    refreshChannelData()
                } catch {
                    setStatus("Error: \(error)")
                }

            case Int32(Character("D").asciiValue!):
                pendingConfirm = .deleteChannel(name: channels[channelSelectedIndex].name)

            case Int32(Character("r").asciiValue!), Int32(Character("R").asciiValue!):
                refreshChannelData()
                setStatus("OK: refreshed")

            default:
                break
            }
        }
    }

    private mutating func handleDetailInput(_ ch: CursesInt, channelName: String) {
        // If the channel vanished externally, auto-return.
        if ChannelRegistry.shared.get(channelName) == nil {
            viewMode = .channels
            refreshChannelData()
            setStatus("Error: channel '\(channelName)' was deleted")
            return
        }

        let hasMessages = !detailMessages.isEmpty

        switch ch {
        case Int32(Character("q").asciiValue!), Int32(Character("Q").asciiValue!):
            running = false

        case 27, Int32(Character("b").asciiValue!), Int32(Character("B").asciiValue!):
            // ESC or b — back to channels
            viewMode = .channels
            refreshChannelData()

        case Int32(Character("s").asciiValue!), Int32(Character("S").asciiValue!):
            viewMode = .sessions

        case Int32(Character("c").asciiValue!), Int32(Character("C").asciiValue!):
            viewMode = .channels
            refreshChannelData()

        case Int32(Character("r").asciiValue!), Int32(Character("R").asciiValue!):
            refreshDetailMessages(channel: channelName)
            setStatus("OK: refreshed")

        case KEY_UP, Int32(Character("k").asciiValue!):
            guard hasMessages else { return }
            messageSelectedIndex = max(0, messageSelectedIndex - 1)

        case KEY_DOWN, Int32(Character("j").asciiValue!):
            guard hasMessages else { return }
            messageSelectedIndex = min(detailMessages.count - 1, messageSelectedIndex + 1)

        case Int32(Character("d").asciiValue!):
            guard hasMessages, messageSelectedIndex < detailMessages.count else { return }
            let msg = detailMessages[messageSelectedIndex]
            if msg.status == .delivered || msg.status == .dropped {
                setStatus("Error: already terminal")
                return
            }
            do {
                _ = try MessageRouter.shared.deliver(msg.id)
                setStatus("OK: delivered \(shortId(msg.id))")
                refreshDetailMessages(channel: channelName)
            } catch {
                setStatus("Error: \(error)")
            }

        case Int32(Character("h").asciiValue!):
            guard hasMessages, messageSelectedIndex < detailMessages.count else { return }
            let msg = detailMessages[messageSelectedIndex]
            if msg.status != .pending {
                setStatus("Error: only pending can be held")
                return
            }
            do {
                _ = try MessageRouter.shared.hold(msg.id)
                setStatus("OK: held \(shortId(msg.id))")
                refreshDetailMessages(channel: channelName)
            } catch {
                setStatus("Error: \(error)")
            }

        case Int32(Character("x").asciiValue!), Int32(Character("X").asciiValue!):
            guard hasMessages, messageSelectedIndex < detailMessages.count else { return }
            let msg = detailMessages[messageSelectedIndex]
            if msg.status == .delivered || msg.status == .dropped {
                setStatus("Error: already terminal")
                return
            }
            do {
                _ = try MessageRouter.shared.drop(msg.id)
                setStatus("OK: dropped \(shortId(msg.id))")
                refreshDetailMessages(channel: channelName)
            } catch {
                setStatus("Error: \(error)")
            }

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

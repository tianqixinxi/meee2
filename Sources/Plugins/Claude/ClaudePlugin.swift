import Foundation
import SwiftUI
import PeerPluginKit

/// Claude Code 插件
/// 从 CSM 的 ~/.csm/sessions/ 读取会话数据（CSM hooks 维护）
/// 补充 transcript 解析获取 usage stats 和状态推断
class ClaudePlugin: AIPlugin {
    // MARK: - 身份

    override var pluginId: String { "com.peerisland.claude" }
    override var displayName: String { "Claude Code" }
    override var icon: String { "brain.head.profile" }
    override var themeColor: Color { .orange }
    override var version: String { "1.0.0" }

    // MARK: - 内部组件

    private let sessionScanner = ClaudeSessionScanner()
    private let transcriptReader = ClaudeTranscriptReader()
    private let configManager = ClaudeConfigManager()

    // MARK: - 生命周期

    override func initialize() -> Bool {
        configManager.ensureHooksConfigured()
        return true
    }

    override func start() -> Bool {
        sessionScanner.onSessionsChanged = { [weak self] _ in
            self?.notifySessionsUpdated()
        }
        sessionScanner.start()

        NSLog("[ClaudePlugin] Started (reading from CSM data)")
        return true
    }

    override func stop() {
        sessionScanner.stop()
        NSLog("[ClaudePlugin] Stopped")
    }

    override func cleanup() { stop() }

    // MARK: - 会话发现

    override func getSessions() -> [Session] {
        sessionScanner.currentSessions.map { csm in
            // 注册 transcript 路径
            if let tp = csm.transcriptPath {
                transcriptReader.setTranscriptPath(for: csm.sessionId, path: tp)
            }

            let status = resolveStatus(csm)

            var session = Session(
                id: "\(pluginId):\(csm.sessionId)",
                pluginId: pluginId,
                title: csm.projectName,
                status: status,
                startedAt: csm.startedAtDate,
                lastUpdated: csm.lastActivityDate,
                subtitle: csm.description ?? csm.currentTask,
                pid: csm.pid,
                cwd: csm.project,
                toolName: csm.currentTool,
                terminalInfo: csm.terminalInfo
            )

            // 如果没有 terminal_info 但有 ghostty_terminal_id，构建 Ghostty 终端信息
            if session.terminalInfo == nil, let ghosttyId = csm.ghosttyTerminalId {
                session.terminalInfo = TerminalInfo(
                    termProgram: "ghostty",
                    termBundleId: "com.mitchellh.ghostty",
                    customData: ["ghostty_terminal_id": ghosttyId]
                )
            }
            // 补充 ghostty_terminal_id 到已有 terminal_info
            if let ghosttyId = csm.ghosttyTerminalId, session.terminalInfo?.customData == nil {
                session.terminalInfo?.customData = ["ghostty_terminal_id": ghosttyId]
            }

            // Usage stats (从 transcript 聚合)
            session.usage = transcriptReader.getUsageStats(for: csm.sessionId)

            // Progress
            if let progress = csm.progress, progress != "0/0" {
                let parts = progress.split(separator: "/")
                if parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total > 0 {
                    session.progress = done * 100 / total
                }
            }

            return session
        }
    }

    override func refresh() {
        sessionScanner.refresh()
    }

    // MARK: - 状态映射

    override func mapStatus(_ nativeStatus: String) -> SessionStatus {
        // 从 CSM detailed_status 映射
        switch nativeStatus {
        case "idle": return .idle
        case "thinking": return .thinking
        case "tooling": return .tooling
        case "active": return .active
        case "waitingForUser": return .waitingForUser
        case "permissionRequired": return .permissionRequired
        case "compacting": return .compacting
        case "completed": return .completed
        case "dead": return .dead
        default: return .idle
        }
    }

    // MARK: - 终端跳转

    override func activateTerminal(for session: Session) {
        TerminalManager.smartActivateTerminal(forSession: session)
    }

    // MARK: - 内部逻辑

    /// 状态解析：优先用 CSM 的 detailed_status，回退到 transcript 推断
    private func resolveStatus(_ csm: CSMSessionData) -> SessionStatus {
        // Step 1: 进程存活检查
        if let pid = csm.pid, kill(pid_t(pid), 0) != 0 {
            return .dead
        }

        // Step 2: 优先使用 CSM 的 detailed_status（CSM hooks 已经计算好）
        if let ds = csm.detailedStatus {
            return mapStatus(ds)
        }

        // Step 3: 从 CSM 粗粒度 status + current_tool 推断
        let status = csm.status
        let tool = csm.currentTool

        switch status {
        case "active":
            if tool == "thinking" { return .thinking }
            if tool != nil { return .tooling }
            return .active
        case "waiting":
            return .permissionRequired
        case "idle":
            // 检查 transcript 是否有更新状态
            if let tp = csm.transcriptPath {
                transcriptReader.setTranscriptPath(for: csm.sessionId, path: tp)
                let override = transcriptReader.inferStatus(for: csm.sessionId, hookStatus: .idle)
                if let overrideStatus = override.status {
                    return overrideStatus
                }
            }
            return .idle
        case "dead": return .dead
        case "completed": return .completed
        default: return .idle
        }
    }

    private func notifySessionsUpdated() {
        let sessions = getSessions()
        onSessionsUpdated?(sessions)
    }
}

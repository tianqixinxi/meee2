import Foundation
import Meee2PluginKit

// MARK: - Session Palette Entry

/// 扁平化的 session 条目，供 Palette 搜索和展示
public struct SessionPaletteEntry: Identifiable, Equatable {
    public let id: String
    public let sessionId: String
    public let title: String
    public let project: String
    public let cwd: String
    public let pluginId: String
    public let pluginDisplayName: String
    public let status: String
    public let statusRaw: SessionStatus
    public let model: String
    public let startedAt: Date
    public let lastActivity: Date
    public let currentTool: String?
    public let pendingPermissionTool: String?
    public let lastMessage: String?
    public let isTerminalJumpable: Bool
    public let terminalKind: String
    public let surfaceId: String?

    public static func == (lhs: SessionPaletteEntry, rhs: SessionPaletteEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search Engine

/// Session Palette 搜索引擎 —— 对内存中 session 做全文匹配 + 过滤
/// 设计目标：冷启动 < 200ms（纯内存操作，无 I/O）
public final class SessionPaletteSearchEngine {

    // MARK: - Filters

    public enum StatusFilter: String, CaseIterable {
        case all
        case active
        case thinking
        case tooling
        case idle
        case waitingForUser
        case permissionRequired
        case completed
        case dead
    }

    // MARK: - Search State

    public var query: String = ""
    public var statusFilter: StatusFilter = .all
    public var pluginFilter: String?
    public var sortBy: SortBy = .lastActivity

    public enum SortBy: String {
        case lastActivity
        case startedAt
        case project
    }

    // MARK: - Search

    /// 执行搜索，返回匹配的 entries
    public func search(
        sessions: [PluginSession],
        storeSessions: [SessionData],
        internalSurfaces: [InternalTerminalSurfaceSnapshot] = []
    ) -> [SessionPaletteEntry] {
        var results: [SessionPaletteEntry] = []
        let queryLower = query.lowercased()
        let internalSessionIds = Set(
            internalSurfaces
                .filter { $0.status != "exited" && $0.status != "failed" }
                .map(\.sessionId)
        )

        for s in sessions where !s.status.isHistorical {
            let realSid: String = {
                let prefix = "\(s.pluginId)-"
                return s.id.hasPrefix(prefix) ? String(s.id.dropFirst(prefix.count)) : s.id
            }()
            if internalSessionIds.contains(realSid) {
                continue
            }

            // Status filter
            if statusFilter != .all {
                let statusName = statusName(for: s.status)
                if statusName != statusFilter.rawValue {
                    continue
                }
            }

            // Plugin filter
            if let pf = pluginFilter, s.pluginId != pf {
                continue
            }

            let storeSession = storeSessions.first { $0.sessionId == realSid }
            let cwd = storeSession?.cwd ?? s.cwd ?? s.title
            let project = cwd.split(separator: "/").last.map(String.init) ?? cwd
            let currentTool = storeSession?.currentTool
            let pendingPermission = storeSession?.pendingPermissionTool
            let lastMessage = storeSession?.lastMessage
            let model = s.usageStats?.model ?? ""
            let pluginDisplayName = PluginManager.shared.getPluginInfo(for: s.pluginId)?.displayName ?? s.pluginId

            // Text query filter —— 在所有可见字段上做子串匹配
            if !queryLower.isEmpty {
                let searchable = [
                    s.title, s.pluginId, pluginDisplayName,
                    project, cwd, statusName(for: s.status),
                    model, currentTool ?? "", pendingPermission ?? "",
                    lastMessage ?? ""
                ].joined(separator: " ").lowercased()
                if !searchable.contains(queryLower) {
                    continue
                }
            }

            let statusName = statusName(for: s.status)

            // Terminal jumpable if we have a terminal info
            let isTerminalJumpable = s.terminalInfo?.tty != nil
                || s.terminalInfo?.termProgram != nil
                || storeSession?.ghosttyTerminalId != nil
                || storeSession?.iTermSessionId != nil
                || storeSession?.appleTerminalSessionId != nil

            results.append(SessionPaletteEntry(
                id: s.id,
                sessionId: realSid,
                title: s.title,
                project: project,
                cwd: cwd,
                pluginId: s.pluginId,
                pluginDisplayName: pluginDisplayName,
                status: statusName,
                statusRaw: s.status,
                model: model,
                startedAt: s.startedAt,
                lastActivity: s.lastUpdated ?? s.startedAt,
                currentTool: currentTool,
                pendingPermissionTool: pendingPermission,
                lastMessage: lastMessage,
                isTerminalJumpable: isTerminalJumpable,
                terminalKind: "external",
                surfaceId: nil
            ))
        }

        for surface in internalSurfaces where surface.status != "exited" && surface.status != "failed" {
            let storeSession = storeSessions.first { $0.sessionId == surface.sessionId }
            let status = storeSession?.status ?? .active
            let pluginId = surface.provider.lowercased() == "codex"
                ? "com.meee2.plugin.codex"
                : "com.meee2.plugin.claude"
            let pluginDisplayName = PluginManager.shared.getPluginInfo(for: pluginId)?.displayName
                ?? surface.provider.capitalized
            let cwd = storeSession?.cwd ?? surface.cwd
            let project = cwd.split(separator: "/").last.map(String.init) ?? cwd
            let statusText = surface.status == "running" ? statusName(for: status) : surface.status

            if statusFilter != .all, statusName(for: status) != statusFilter.rawValue {
                continue
            }
            if let pf = pluginFilter, pluginId != pf {
                continue
            }
            if !queryLower.isEmpty {
                let searchable = [
                    surface.title, surface.sessionId, surface.surfaceId,
                    pluginId, pluginDisplayName, project, cwd, statusText,
                    storeSession?.currentTool ?? "", storeSession?.lastMessage ?? ""
                ].joined(separator: " ").lowercased()
                if !searchable.contains(queryLower) {
                    continue
                }
            }

            results.append(SessionPaletteEntry(
                id: surface.sessionId,
                sessionId: surface.sessionId,
                title: surface.title,
                project: project,
                cwd: cwd,
                pluginId: pluginId,
                pluginDisplayName: pluginDisplayName,
                status: statusText,
                statusRaw: status,
                model: storeSession?.usageStats?.model ?? "",
                startedAt: surface.createdAt,
                lastActivity: surface.updatedAt,
                currentTool: storeSession?.currentTool ?? "terminal",
                pendingPermissionTool: storeSession?.pendingPermissionTool,
                lastMessage: storeSession?.lastMessage,
                isTerminalJumpable: false,
                terminalKind: "internal",
                surfaceId: surface.surfaceId
            ))
        }

        // Sort
        switch sortBy {
        case .lastActivity:
            results.sort { $0.lastActivity > $1.lastActivity }
        case .startedAt:
            results.sort { $0.startedAt > $1.startedAt }
        case .project:
            results.sort { $0.project < $1.project }
        }

        return results
    }

    /// 获取所有已知 plugin 的列表（用于 filter chip）
    public func distinctPlugins(
        sessions: [PluginSession],
        internalSurfaces: [InternalTerminalSurfaceSnapshot] = []
    ) -> [(id: String, displayName: String, count: Int)] {
        var counts: [String: (displayName: String, count: Int)] = [:]
        for s in sessions where !s.status.isHistorical {
            if let existing = counts[s.pluginId] {
                counts[s.pluginId] = (existing.displayName, existing.count + 1)
            } else {
                counts[s.pluginId] = (PluginManager.shared.getPluginInfo(for: s.pluginId)?.displayName ?? s.pluginId, 1)
            }
        }
        for surface in internalSurfaces where surface.status != "exited" && surface.status != "failed" {
            let pluginId = surface.provider.lowercased() == "codex"
                ? "com.meee2.plugin.codex"
                : "com.meee2.plugin.claude"
            let displayName = PluginManager.shared.getPluginInfo(for: pluginId)?.displayName
                ?? surface.provider.capitalized
            if let existing = counts[pluginId] {
                counts[pluginId] = (existing.displayName, existing.count + 1)
            } else {
                counts[pluginId] = (displayName, 1)
            }
        }
        return counts.sorted { $0.value.count > $1.value.count }
            .map { (id: $0.key, displayName: $0.value.displayName, count: $0.value.count) }
    }

    private func statusName(for status: SessionStatus) -> String {
        switch status {
        case .active: return "active"
        case .thinking: return "thinking"
        case .tooling: return "tooling"
        case .idle: return "idle"
        case .waitingForUser: return "waitingForUser"
        case .permissionRequired: return "permissionRequired"
        case .completed: return "completed"
        case .compacting: return "compacting"
        case .dead: return "dead"
        }
    }
}

import Foundation
import SwiftUI
import AppKit
import Meee2PluginKit

// MARK: - DTO 类型：API 响应用的扁平化结构，供 Wave 10b React 前端消费

/// 单条 transcript 预览条目 DTO —— 供卡片上渲染最近消息
struct TranscriptEntryDTO: Encodable {
    let role: String       // "user" | "assistant" | "tool" | other
    let text: String       // 后端已按 ~200 字截断
}

/// Session 摘要 DTO —— 面向前端的最小必需信息
struct SessionDTO: Encodable {
    let id: String
    let title: String
    let project: String
    let pluginId: String
    let pluginDisplayName: String
    let pluginColor: String  // hex like "#FF9500"
    let status: String
    let inboxPending: Int
    /// 最近 transcript 消息；最多 5 条，oldest → newest；transcript 不可用时为 []
    let recentMessages: [TranscriptEntryDTO]
    /// 当前工具名，如 "Bash" / "Edit"；空闲时为 null
    let currentTool: String?
    /// 累计使用费用（USD），未知时为 null
    let costUSD: Double?

    // MARK: - 扩展字段（custom card 模板可引用）

    /// Session 启动时间 ISO8601；缺失时为 null
    let startedAt: String?
    /// 最后活动时间 ISO8601；缺失时为 null
    let lastActivity: String?
    /// 完整 usage 明细；SessionData.usageStats 为 nil 时为 null
    let usageStats: UsageStatsDTO?
    /// 任务列表；无任务时为 []
    let tasks: [TaskDTO]
    /// 当前任务名；无时为 null
    let currentTask: String?
    /// 待审批工具名；无待审批时为 null
    let pendingPermissionTool: String?
    /// 待审批权限描述；无待审批时为 null
    let pendingPermissionMessage: String?
    /// Ghostty 终端 ID（诊断用）；未捕获时为 null
    let ghosttyTerminalId: String?
    /// 终端 TTY 路径（诊断用）；未知时为 null
    let tty: String?
    /// 终端程序名（诊断用）；未知时为 null
    let termProgram: String?
}

/// Usage 明细 DTO —— 供模板引用 token/turns/cost 等指标
struct UsageStatsDTO: Encodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreateTokens: Int
    let cacheReadTokens: Int
    let turns: Int
    /// 模型名；未知时为 ""
    let model: String
    let costUSD: Double
}

/// 任务条目 DTO
struct TaskDTO: Encodable {
    let id: String
    let name: String
    /// SessionTask.status.rawValue —— "pending" | "in_progress" | "done" | "completed"
    let status: String
}

/// 频道成员 DTO
struct MemberDTO: Encodable {
    let alias: String
    let sessionId: String
}

/// 频道 DTO
struct ChannelDTO: Encodable {
    let name: String
    let mode: String  // "auto" / "intercept" / "paused"
    let members: [MemberDTO]
    let pendingCount: Int
    let description: String?
    let createdAt: String  // ISO8601
}

/// 消息 DTO
struct MessageDTO: Encodable {
    let id: String
    let channel: String
    let fromAlias: String
    let toAlias: String
    let content: String
    let replyTo: String?
    let status: String
    let createdAt: String
    let deliveredAt: String?
    let deliveredTo: [String]
    let injectedByHuman: Bool
}

/// 全局状态 DTO —— `GET /api/state` 的 payload
struct StateDTO: Encodable {
    let sessions: [SessionDTO]
    let channels: [ChannelDTO]
}

/// 错误 DTO —— 所有 4xx/5xx 响应的 body
struct ErrorDTO: Encodable {
    struct Inner: Encodable {
        let code: String
        let message: String
    }
    let error: Inner

    init(code: String, message: String) {
        self.error = .init(code: code, message: message)
    }
}

// MARK: - 单条响应包装

struct ChannelEnvelope: Encodable { let channel: ChannelDTO }
struct MessageEnvelope: Encodable { let message: MessageDTO }
struct MessagesEnvelope: Encodable { let messages: [MessageDTO] }
struct OkEnvelope: Encodable { let ok: Bool }

struct CardTemplateEnvelope: Encodable { let template: CardTemplateStore.Entry }
struct CardTemplatesEnvelope: Encodable { let templates: [CardTemplateStore.Entry] }

// MARK: - 转换工具

enum BoardDTOBuilder {
    /// 缓存 ISO8601 formatter（带毫秒精度）
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso(_ date: Date) -> String { iso8601.string(from: date) }
    static func iso(_ date: Date?) -> String? {
        guard let d = date else { return nil }
        return iso8601.string(from: d)
    }

    /// 按 channel 统计 pending + held 计数
    static func pendingCount(for channelName: String) -> Int {
        MessageRouter.shared
            .listMessages(channel: channelName, statuses: [.pending, .held])
            .count
    }

    static func channelDTO(_ channel: Channel) -> ChannelDTO {
        ChannelDTO(
            name: channel.name,
            mode: channel.mode.rawValue,
            members: channel.members.map { MemberDTO(alias: $0.alias, sessionId: $0.sessionId) },
            pendingCount: pendingCount(for: channel.name),
            description: channel.description,
            createdAt: iso(channel.createdAt)
        )
    }

    static func messageDTO(_ msg: A2AMessage) -> MessageDTO {
        MessageDTO(
            id: msg.id,
            channel: msg.channel,
            fromAlias: msg.fromAlias,
            toAlias: msg.toAlias,
            content: msg.content,
            replyTo: msg.replyTo,
            status: msg.status.rawValue,
            createdAt: iso(msg.createdAt),
            deliveredAt: iso(msg.deliveredAt),
            deliveredTo: msg.deliveredTo,
            injectedByHuman: msg.injectedByHuman
        )
    }

    /// 把 PluginSession 转成 SessionDTO；pluginInfo 可能为 nil（插件未加载）
    static func sessionDTO(_ session: PluginSession) -> SessionDTO {
        let info = PluginManager.shared.getPluginInfo(for: session.pluginId)
        let displayName = info?.displayName ?? session.pluginId
        let colorHex = info.map { hexString(from: $0.themeColor) } ?? "#808080"

        // inbox pending —— 把该 session 作为接收方的 pending/held 消息数量
        // 遍历所有频道里的消息，过滤出目标是当前 session 的（通过 alias/sessionId 映射）
        let pending = pendingInboxCount(for: session.id)

        // 丰富字段：transcript / currentTool / cost —— 都从底层 SessionStore 拿
        let sessionData = SessionStore.shared.get(session.id)
        let transcriptEntries: [TranscriptEntryDTO]
        if let path = sessionData?.transcriptPath {
            let msgs = TranscriptParser.loadMessages(transcriptPath: path, count: 5)
            transcriptEntries = msgs.map {
                TranscriptEntryDTO(role: $0.role, text: String($0.text.prefix(1000)))
            }
        } else {
            transcriptEntries = []
        }

        // csm-style live status: combine process liveness + transcript tail
        // with the hook status. 优先用 detailedStatus（hook 驱动的精细状态，比
        // raw status "running" 更准——"running" 只表示会话生命周期活着，不是
        // "Claude 正在干活"）。
        let hookStatus: String = {
            if let ds = sessionData?.detailedStatus {
                return ds.rawValue
            }
            return sessionData?.status ?? session.status.rawValue
        }()
        let resolvedStatus = TranscriptStatusResolver.resolve(
            transcriptPath: sessionData?.transcriptPath,
            hookStatus: hookStatus,
            pid: sessionData?.pid,
            ghosttyTerminalId: sessionData?.ghosttyTerminalId
        )

        // Tool name: let the resolver override to "thinking" / clear when
        // appropriate; otherwise keep whatever the plugin set.
        let currentTool: String?
        if let toolOverride = TranscriptStatusResolver.resolveCurrentTool(
            transcriptPath: sessionData?.transcriptPath,
            currentTool: sessionData?.currentTool
        ) {
            currentTool = toolOverride  // may be nil (clear) or a new name
        } else {
            currentTool = sessionData?.currentTool
        }

        let costUSD = sessionData?.usageStats?.costUSD

        // 扩展字段：模板可引用的完整 session 信息
        let usageStatsDTO: UsageStatsDTO? = sessionData?.usageStats.map { u in
            UsageStatsDTO(
                inputTokens: u.inputTokens,
                outputTokens: u.outputTokens,
                cacheCreateTokens: u.cacheCreateTokens,
                cacheReadTokens: u.cacheReadTokens,
                turns: u.turns,
                model: u.model,
                costUSD: u.costUSD
            )
        }

        // Tasks: SessionData 优先；其次 PluginSession；都无则为 []
        let rawTasks: [SessionTask] = sessionData?.tasks ?? session.tasks ?? []
        let tasksDTO: [TaskDTO] = rawTasks.map { t in
            TaskDTO(id: t.id, name: t.name, status: t.status.rawValue)
        }

        let startedAtISO: String? = sessionData.map { iso($0.startedAt) } ?? iso(session.startedAt)
        let lastActivityISO: String? = sessionData.map { iso($0.lastActivity) } ?? iso(session.lastUpdated)

        let terminalInfo = sessionData?.terminalInfo ?? session.terminalInfo
        let tty = terminalInfo?.tty
        let termProgram = terminalInfo?.termProgram

        return SessionDTO(
            id: session.id,
            title: session.title,
            project: session.cwd ?? session.title,
            pluginId: session.pluginId,
            pluginDisplayName: displayName,
            pluginColor: colorHex,
            status: resolvedStatus.rawValue,
            inboxPending: pending,
            recentMessages: transcriptEntries,
            currentTool: currentTool,
            costUSD: costUSD,
            startedAt: startedAtISO,
            lastActivity: lastActivityISO,
            usageStats: usageStatsDTO,
            tasks: tasksDTO,
            currentTask: sessionData?.currentTask ?? session.subtitle,
            pendingPermissionTool: sessionData?.pendingPermissionTool,
            pendingPermissionMessage: sessionData?.pendingPermissionMessage,
            ghosttyTerminalId: sessionData?.ghosttyTerminalId,
            tty: tty,
            termProgram: termProgram
        )
    }

    /// 计算一个 sessionId 的待投递消息数（对其名下所有 alias 的 pending/held 合计）
    private static func pendingInboxCount(for sessionId: String) -> Int {
        let channels = ChannelRegistry.shared.list()
        // 构造 channel -> [alias] 映射（该 session 在各频道里的所有 alias）
        var matches: [(channel: String, alias: String)] = []
        for ch in channels {
            for m in ch.members where m.sessionId == sessionId {
                matches.append((ch.name, m.alias))
            }
        }
        guard !matches.isEmpty else { return 0 }

        var count = 0
        for (channelName, alias) in matches {
            let msgs = MessageRouter.shared.listMessages(
                channel: channelName,
                statuses: [.pending, .held]
            )
            // 面向该 alias 的消息：要么是 "*"（广播，排除自己作为发送方），要么是点名
            for m in msgs {
                if m.fromAlias == alias { continue }
                if m.toAlias == alias || m.toAlias == "*" {
                    count += 1
                }
            }
        }
        return count
    }

    /// 把 SwiftUI Color 转成 "#RRGGBB" hex 字符串
    /// nil 或解析失败时返回 "#808080"
    static func hexString(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB)
        guard let c = nsColor else { return "#808080" }
        let r = Int((c.redComponent * 255.0).rounded().clamped(0, 255))
        let g = Int((c.greenComponent * 255.0).rounded().clamped(0, 255))
        let b = Int((c.blueComponent * 255.0).rounded().clamped(0, 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double {
        return Swift.min(Swift.max(self, lo), hi)
    }
}

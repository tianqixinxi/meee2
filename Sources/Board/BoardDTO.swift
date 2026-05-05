import Foundation
import SwiftUI
import AppKit
import Meee2PluginKit
import Meee2CommKit

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

    /// 当前后台在跑的 Claude Code 子 agent / task（Agent run_in_background / Monitor / Bash run_in_background）。
    /// 主 agent status 和这个字段是正交维度：主可以是 idle 而后台同时有 N 条在跑。
    let backgroundAgents: [BackgroundAgentDTO]

    /// Claude Code 最新的 "away summary" / `/recap` 内容；无则为 null
    let latestRecap: RecapDTO?

    /// session 来源客户端：cli (`claude` CLI) / desktop (Claude.app embedded
    /// runtime) / nil (未知 / 非 Claude plugin session)。CLI 和 desktop 共用
    /// 同一个 ClaudePlugin，但 desktop 的 metadata 写在
    /// `~/Library/Application Support/Claude/claude-code-sessions/` 下，
    /// 这个字段供前端区分卡片图标 / 跳转目标。
    let clientKind: String?

    /// 前端展示分组。nil/default 表示主列表；"older" 表示仍可打开但默认折叠、
    /// 不自动铺到画布上的历史 session。
    let displayGroup: String?
}

/// Recap DTO
struct RecapDTO: Encodable {
    let content: String
    let timestamp: String?   // ISO8601
}

/// 后台子 agent / task DTO
struct BackgroundAgentDTO: Encodable {
    let id: String              // Claude 返回的 agentId / taskId
    let kind: String            // "agent" | "monitor" | "bash"
    let description: String?
    let startedAt: String?      // ISO8601
}

/// Usage 明细 DTO —— 供模板引用 token / turns 等指标。
/// 历史上还暴露过 `costUSD`，但 Claude CLI 按 token 粗估的 USD 数字经常不准
/// （不同模型单价、cache read/write 计价、local OAuth 免费额度都不在里面），
/// 展示只会误导。数据模型里直接不带它，UI 展示上下行 token 即可。
struct UsageStatsDTO: Encodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreateTokens: Int
    let cacheReadTokens: Int
    let turns: Int
    /// 模型名；未知时为 ""
    let model: String
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
struct MessageEnvelope: Encodable {
    let message: MessageDTO
    /// 投递语义提示。none = 默认（CLI / 已立刻 push 走 Ghostty 等）；
    /// `queued_until_next_turn` = Desktop session 没 terminal 可以 typeIn，
    /// 消息已写入 inbox，等下一个 Stop hook 触发 drainResponseForDesktopStop
    /// 转成 block-decision reason 才被 Claude.app 看到。session 当前空闲时
    /// 这个等待可能比较久。WebUI 据此显示 toast 提示用户。
    var delivery: String?
}
struct MessagesEnvelope: Encodable { let messages: [MessageDTO] }
struct OkEnvelope: Encodable { let ok: Bool }

struct CardTemplateEnvelope: Encodable { let template: CardTemplateStore.Entry? }
struct CardTemplatesEnvelope: Encodable { let templates: [CardTemplateStore.Entry] }

/// 响应 `GET /api/board/layout`。
struct BoardLayoutEnvelope: Encodable { let layout: BoardLayoutStore.Layout }

// MARK: - 转换工具

enum BoardDTOBuilder {
    /// 缓存 ISO8601 formatter（带毫秒精度）
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private struct TranscriptPreviewCacheKey: Hashable {
        let parser: String
        let path: String
    }

    private struct TranscriptPreviewCacheEntry {
        let fileSize: UInt64
        let modifiedAt: TimeInterval
        let cachedAt: Date
        let entries: [TranscriptEntryDTO]
    }

    private static let transcriptPreviewCacheLock = NSLock()
    private static var transcriptPreviewCache: [TranscriptPreviewCacheKey: TranscriptPreviewCacheEntry] = [:]
    private static let transcriptPreviewCacheMaxEntries = 256
    private static let transcriptPreviewCacheFreshSeconds: TimeInterval = 1.0

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
        // 包括两种来源：
        //  1. A2A channel 消息（遍历该 session 参与的频道里 pending/held 消息）
        //  2. Operator 直接 inject 的消息（写进 ~/.meee2/inbox/<sid>.jsonl，
        //     由 HookSocketServer 在 Stop hook 时 drain）
        let realSessionId = session.id.hasPrefix("\(session.pluginId)-")
            ? String(session.id.dropFirst("\(session.pluginId)-".count))
            : session.id
        let channelPending = pendingInboxCount(for: session.id)
            + (realSessionId == session.id ? 0 : pendingInboxCount(for: realSessionId))
        let directPending = MessageRouter.shared.peekInbox(sessionId: session.id).count
            + (realSessionId == session.id ? 0 : MessageRouter.shared.peekInbox(sessionId: realSessionId).count)
        let pending = channelPending + directPending

        // 丰富字段：transcript / currentTool / cost —— 都从底层 SessionStore 拿
        let sessionData = SessionStore.shared.get(session.id) ?? SessionStore.shared.get(realSessionId)
        let transcriptPath = sessionData?.transcriptPath ?? session.transcriptPath
        let transcriptEntries: [TranscriptEntryDTO]
        if let path = sessionData?.transcriptPath {
            transcriptEntries = transcriptPreviewFromClaude(path: path)
        } else if let path = transcriptPath {
            transcriptEntries = transcriptPreviewFromFullReader(path: path)
        } else {
            transcriptEntries = []
        }

        // Island / TUI / Board 三端同源：用统一 resolver。
        // 有 SessionData 时直接 resolve(for:)，否则退化到 PluginSession.status。
        let resolvedStatus: SessionStatus = {
            if let data = sessionData {
                return TranscriptStatusResolver.resolve(for: data)
            }
            return session.status
        }()
        if UserDefaults.standard.bool(forKey: "stateTraceLoggingEnabled") {
            NSLog("[StateTrace][boardDTO] sid=\(session.id.prefix(8)) hook=\(sessionData?.status.rawValue ?? session.status.rawValue) → api.status=\(resolvedStatus.rawValue) (for Web)")
        }

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

        // 扩展字段：模板可引用的完整 session 信息
        let usageStatsDTO: UsageStatsDTO? = sessionData?.usageStats.map { u in
            UsageStatsDTO(
                inputTokens: u.inputTokens,
                outputTokens: u.outputTokens,
                cacheCreateTokens: u.cacheCreateTokens,
                cacheReadTokens: u.cacheReadTokens,
                turns: u.turns,
                model: u.model
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
        let hydrateHeavyTranscriptFields = shouldHydrateHeavyTranscriptFields(
            transcriptPath: sessionData?.transcriptPath,
            status: resolvedStatus
        )

        // 后台 agent / task：扫 transcript tail 找 Agent run_in_background /
        // Monitor / Bash run_in_background 的 tool_result 启动锚点，减掉已经
        // 出现在 <task-notification>...<status>completed</status></> 里的。
        let bgAgents: [BackgroundAgentDTO] = hydrateHeavyTranscriptFields
            ? BackgroundAgentResolver
                .resolve(transcriptPath: sessionData?.transcriptPath)
                .map {
                    BackgroundAgentDTO(
                        id: $0.id,
                        kind: $0.kind,
                        description: $0.description,
                        startedAt: $0.startedAt.map { iso($0) } ?? nil
                    )
                }
            : []

        // Recap：Claude CLI 的 away summary / `/recap` 在 transcript 里以
        // `system subtype=away_summary` 落盘，扫 tail 拿最新一条。
        let recapDTO: RecapDTO? = hydrateHeavyTranscriptFields
            ? RecapResolver
                .resolve(transcriptPath: sessionData?.transcriptPath)
                .map {
                    RecapDTO(
                        content: $0.content,
                        timestamp: $0.timestamp.map { iso($0) } ?? nil
                    )
                }
            : nil

        // ─── Claude Desktop 集成 ───
        // 查一下 ClaudeDesktopMetadataReader：命中即说明这是 Claude.app 起的
        // session（claude-code-sessions 下面那种），用 metadata 装饰 title / model。
        let desktopMeta = ClaudeDesktopMetadataReader.shared.lookup(cliSessionId: realSessionId)
        // metadata reader 30s 才扫一次，新建 desktop session 在第一个扫描周期内
        // 会被错判成 CLI。entrypoint 写在 transcript 顶部，hook 一进来就能读。
        // clientKind 决策：
        //   - desktopMeta 命中 → "desktop"
        //   - 否则按 entrypoint 推断："claude-desktop" → "desktop"，sdk-* → 透传
        //   - 都没有 → "cli"
        let entrypoint = ClaudeEntrypointReader.read(
            transcriptPath: sessionData?.transcriptPath ?? session.transcriptPath
        )
        let clientKind: String = {
            if desktopMeta != nil { return "desktop" }
            switch entrypoint {
            case ClaudeEntrypointReader.knownDesktop: return "desktop"
            case ClaudeEntrypointReader.knownSDKPy:   return "sdk-py"
            case ClaudeEntrypointReader.knownSDKTs:   return "sdk-ts"
            default: return "cli"
            }
        }()
        let displayGroup: String? = {
            // 跨插件统一：idle ≥ 1h 且不在阻塞等用户响应 → 折叠到 Sidebar 的
            // Older 区。Codex (poll) / Claude (hook) 都走同一条规则。
            //   - 时间源：与 Sidebar 日期分桶用的 lastActivity 同源（sessionData
            //     优先，缺失回退 PluginSession.lastUpdated），保证「折叠/分桶」
            //     共识。
            //   - 状态豁免：`.permissionRequired` 是真正阻塞的弹框，挂超过
            //     1h 也不该折叠，否则用户找不回操作入口。
            //     `.waitingForUser` 语义就是 idle，不豁免。
            guard resolvedStatus != .permissionRequired else { return nil }
            let lastActivity = sessionData?.lastActivity ?? session.lastUpdated
            guard let last = lastActivity,
                  Date().timeIntervalSince(last) >= 3600 else {
                return nil
            }
            return "older"
        }()

        // title 优先用 desktop 的 user-friendly 标题（"AI Product Twitter
        // Marketing Strategy" 这种），fallback 到 PluginSession.title（cwd basename）
        let displayTitle = desktopMeta?.title ?? session.title

        // model 优先用 desktop metadata（"claude-opus-4-7[1m]"），fallback 到
        // transcript 推断（usageStats.model 可能是 "claude-opus-4-6"）
        let usageStatsDTOFinal: UsageStatsDTO? = {
            guard var u = usageStatsDTO else { return nil }
            if let m = desktopMeta?.model, !m.isEmpty {
                u = UsageStatsDTO(
                    inputTokens: u.inputTokens,
                    outputTokens: u.outputTokens,
                    cacheCreateTokens: u.cacheCreateTokens,
                    cacheReadTokens: u.cacheReadTokens,
                    turns: u.turns,
                    model: m
                )
            }
            return u
        }()

        return SessionDTO(
            id: session.id,
            title: displayTitle,
            project: session.cwd ?? session.title,
            pluginId: session.pluginId,
            pluginDisplayName: displayName,
            pluginColor: colorHex,
            status: resolvedStatus.rawValue,
            inboxPending: pending,
            recentMessages: transcriptEntries,
            currentTool: currentTool,
            startedAt: startedAtISO,
            lastActivity: lastActivityISO,
            usageStats: usageStatsDTOFinal,
            tasks: tasksDTO,
            currentTask: sessionData?.currentTask ?? session.subtitle,
            pendingPermissionTool: sessionData?.pendingPermissionTool,
            pendingPermissionMessage: sessionData?.pendingPermissionMessage,
            ghosttyTerminalId: sessionData?.ghosttyTerminalId,
            tty: tty,
            termProgram: termProgram,
            backgroundAgents: bgAgents,
            latestRecap: recapDTO,
            clientKind: clientKind,
            displayGroup: displayGroup
        )
    }

    /// 合成 Claude Desktop session DTO —— 当 PluginManager 不知道这个 session
    /// 时（desktop 子进程已经退了，没 PID 文件，hook 不会再来），直接从 metadata
    /// 文件 + 历史 transcript 还原一份给 Web UI。
    /// transcript 路径推导：~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl
    /// （Claude CLI 用的同一规则：path → '-Users-qc-projects-foo' 这种 dash-flat 编码）。
    static func syntheticDesktopSessionDTO(metadata m: ClaudeDesktopMetadata) -> SessionDTO {
        let info = PluginManager.shared.getPluginInfo(for: "com.meee2.plugin.claude")
        let displayName = info?.displayName ?? "Claude Code"
        let colorHex = info.map { hexString(from: $0.themeColor) } ?? "#FF9230"

        // transcript path 已经由 ClaudeDesktopMetadataReader 解析好
        // （~/.claude/projects/<encoded-host-cwd>/<sid>.jsonl）。文件不存在时为 nil → recent 空。
        let recent: [TranscriptEntryDTO] = m.transcriptPath.map(transcriptPreviewFromFullReader) ?? []

        // 状态：desktop 子进程不长跑，metadata-only 默认 idle。Web UI 卡片
        // 用 lastActivity 时间显示 "X 分钟前"。
        let status: SessionStatus = .idle

        let usageDTO: UsageStatsDTO? = m.model.map { model in
            UsageStatsDTO(
                inputTokens: 0, outputTokens: 0,
                cacheCreateTokens: 0, cacheReadTokens: 0,
                turns: 0, model: model
            )
        }

        return SessionDTO(
            id: m.cliSessionId,
            title: m.title,
            project: m.cwd ?? m.title,
            pluginId: "com.meee2.plugin.claude",
            pluginDisplayName: displayName,
            pluginColor: colorHex,
            status: status.rawValue,
            inboxPending: 0,
            recentMessages: recent,
            currentTool: nil,
            startedAt: nil,
            lastActivity: m.lastActivityAt.map { iso($0) } ?? nil,
            usageStats: usageDTO,
            tasks: [],
            currentTask: nil,
            pendingPermissionTool: nil,
            pendingPermissionMessage: nil,
            ghosttyTerminalId: nil,
            tty: nil,
            termProgram: nil,
            backgroundAgents: [],
            latestRecap: nil,
            clientKind: "desktop",
            displayGroup: nil
        )
    }

    private static func transcriptPreviewFromClaude(path: String) -> [TranscriptEntryDTO] {
        cachedTranscriptPreview(path: path, parser: "claude") {
            let msgs = TranscriptParser.loadMessages(transcriptPath: path, count: 5)
            return msgs.map {
                TranscriptEntryDTO(role: $0.role, text: String($0.text.prefix(1000)))
            }
        }
    }

    private static func transcriptPreviewFromFullReader(path: String) -> [TranscriptEntryDTO] {
        cachedTranscriptPreview(path: path, parser: "full-reader") {
            FullTranscriptReader.readTail(
                transcriptPath: path,
                limit: 5,
                maxBytes: 512 * 1024
            ).compactMap { entry in
                let parts = entry.blocks.compactMap { block -> String? in
                    switch block.type {
                    case "text", "thinking":
                        return block.text
                    case "tool_use":
                        return block.toolName.map { "tool: \($0)" }
                    case "tool_result":
                        return block.toolResultText
                    default:
                        return nil
                    }
                }
                let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptEntryDTO(role: entry.type, text: String(text.prefix(1000)))
            }
        }
    }

    private static func cachedTranscriptPreview(
        path: String,
        parser: String,
        load: () -> [TranscriptEntryDTO]
    ) -> [TranscriptEntryDTO] {
        let key = TranscriptPreviewCacheKey(parser: parser, path: path)
        let now = Date()

        transcriptPreviewCacheLock.lock()
        if let cached = transcriptPreviewCache[key],
           now.timeIntervalSince(cached.cachedAt) < transcriptPreviewCacheFreshSeconds {
            let entries = cached.entries
            transcriptPreviewCacheLock.unlock()
            return entries
        }
        transcriptPreviewCacheLock.unlock()

        guard let fingerprint = transcriptPreviewFingerprint(path: path) else {
            return load()
        }

        transcriptPreviewCacheLock.lock()
        if let cached = transcriptPreviewCache[key] {
            if now.timeIntervalSince(cached.cachedAt) < transcriptPreviewCacheFreshSeconds ||
                (cached.fileSize == fingerprint.fileSize && cached.modifiedAt == fingerprint.modifiedAt) {
                let entries = cached.entries
                transcriptPreviewCacheLock.unlock()
                return entries
            }
        }

        let entries = load()
        transcriptPreviewCache[key] = TranscriptPreviewCacheEntry(
            fileSize: fingerprint.fileSize,
            modifiedAt: fingerprint.modifiedAt,
            cachedAt: now,
            entries: entries
        )
        if transcriptPreviewCache.count > transcriptPreviewCacheMaxEntries,
           let oldest = transcriptPreviewCache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
            transcriptPreviewCache.removeValue(forKey: oldest)
        }
        transcriptPreviewCacheLock.unlock()
        return entries
    }

    private static func transcriptPreviewFingerprint(path: String) -> (fileSize: UInt64, modifiedAt: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value
        let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        guard let fileSize = fileSize, let modifiedAt = modifiedAt else {
            return nil
        }
        return (fileSize, modifiedAt)
    }

    private static func shouldHydrateHeavyTranscriptFields(
        transcriptPath: String?,
        status: SessionStatus
    ) -> Bool {
        guard transcriptPath != nil else { return false }
        return status.isWorking || status.needsUserAction
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

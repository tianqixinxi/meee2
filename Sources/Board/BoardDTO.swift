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
    /// "internal" means meee2 owns the PTY/surface; "external" means the
    /// session still lives in Ghostty/iTerm/Terminal/cmux.
    let terminalKind: String
    let surfaceId: String?
    let surfaceStatus: String?
    let canOpenExternal: Bool
    let terminalBackend: String
    let nativeWorkspaceAvailable: Bool
    let openTarget: String
    /// "active" | "hidden" | "archived" — local operator visibility state.
    let controlState: String

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

    /// meee2 Online connected-mode sync state. Local Board remains the source
    /// of truth; these fields only describe which team receives cloud sync.
    let syncEnabled: Bool
    let syncTeamId: String?
    let syncTeamName: String?

    // 注：旧版本曾下发 `displayGroup: "older"` 字段（idle ≥ 1h）。这是 webui
    // 呈现规则，已挪到前端从 lastActivity 派生（see board-app/types.ts
    // isOlderSession）—— DTO 不再扛这个职责。
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
    /// 可选 display name —— UI 渲染时优先用这个，nil 时退回 `name`。
    let displayName: String?
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

struct MemberDigestDTO: Encodable {
    let sessionId: String
    let summary: String
    let currentTask: String
    let status: String
    let blockers: [String]
    let lastDecision: String
    let lastTranscriptCursor: String
    let lastActivity: String?
}

struct CoordinationEventDTO: Encodable {
    let id: String
    let groupId: String
    let kind: String
    let reason: String
    let sessionIds: [String]
    let contextPreview: String
    let createdAt: String
}

struct CoordinationGroupDTO: Encodable {
    let id: String
    let canvasId: String
    let coordinatorSessionId: String?
    let pendingSpawnIntentId: String?
    let memberSessionIds: [String]
    let mode: String
    let goal: String
    let paused: Bool
    let memberDigests: [String: MemberDigestDTO]
    let events: [CoordinationEventDTO]
    let lastWakeAt: String?
    let lastRoutedAction: String?
    let createdAt: String
    let updatedAt: String
}

/// 全局状态 DTO —— `GET /api/state` 的 payload
struct StateDTO: Encodable {
    let sessions: [SessionDTO]
    let channels: [ChannelDTO]
    let coordinationGroups: [CoordinationGroupDTO]
}

/// Settings/User tab mirrored user profile for the board sidebar footer.
struct SyncTeamDTO: Encodable {
    let id: String
    let name: String
    let role: String?
    let isDefault: Bool
}

struct UserProfileDTO: Encodable {
    let connected: Bool
    let userId: String
    let displayName: String
    let userName: String
    let userEmail: String
    let userAvatarUrl: String
    let initials: String
    let dashboardUrl: String
    let connectUrl: String
    let defaultSyncEnabled: Bool
    let defaultSyncTeamId: String
    let defaultSyncTeamName: String
    let teams: [SyncTeamDTO]
    let sessionSync: [UserProfileSessionSyncDTO]
}

struct UserProfileSessionSyncDTO: Encodable {
    let sessionId: String
    let title: String
    let pluginDisplayName: String
    let project: String
    let enabled: Bool
}

struct AppSettingsScreenDTO: Encodable {
    let id: String
    let name: String
    let hasNotch: Bool
}

struct AppSettingsDTO: Encodable {
    let theme: String
    let locale: String
    let devMode: Bool
    let showIsland: Bool
    let selectedScreenId: String
    let availableScreens: [AppSettingsScreenDTO]
    let autoExpandEnabled: Bool
    let autoCloseInterval: Double
    let showSessionInCompact: Bool
    let carouselInterval: Double
}

/// One identity in the team member directory — the authoritative source the
/// planner graph keys avatar / displayName lookups by `userId`.
struct TeamMemberDTO: Encodable {
    let userId: String
    let displayName: String
    let avatarUrl: String?
    /// Team-level role from meee2 Online membership (`owner` / `admin` /
    /// `member`). `nil` when the member was discovered only locally (e.g. a
    /// planner-node doer) and no membership role is known.
    let role: String?
}

/// `GET /api/team/members` body.
struct TeamMembersEnvelope: Encodable {
    let members: [TeamMemberDTO]
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
struct CoordinationGroupEnvelope: Encodable { let group: CoordinationGroupDTO }
struct CoordinationGroupsEnvelope: Encodable { let groups: [CoordinationGroupDTO] }
struct PlannerCanvasStateEnvelope: Encodable {
    let canvas: PlanningCanvas
    let nodes: [PlanningNode]
    let states: [NodeStateSnapshot]
    let proposals: [PlanProposal]
    let access: PlannerAccess
    let activities: [PlannerActivity]
    let events: [PlannerEvent]
    let artifacts: [PlannerArtifact]
    let edges: [PlannerGraphEdge]
}
struct PlannerGraphStateEnvelope: Encodable {
    let canvas: PlanningCanvas
    let nodes: [PlanningNode]
    let states: [NodeStateSnapshot]
    let proposals: [PlanProposal]
    let access: PlannerAccess
    let activities: [PlannerActivity]
    let events: [PlannerEvent]
    let artifacts: [PlannerArtifact]
    let edges: [PlannerGraphEdge]
}
struct PlannerProposalEnvelope: Encodable {
    let proposal: PlanProposal?
}
struct PlannerApplyPreviewEnvelope: Encodable {
    let proposal: PlanProposal
    let nodes: [PlanningNode]
    let states: [NodeStateSnapshot]
    let edges: [PlannerGraphEdge]
    let artifacts: [PlannerArtifact]
}
struct PlannerMonitorEnvelope: Encodable {
    let generatedAt: Date
    let items: [PlannerMonitorItem]
}
struct PlannerActivityEnvelope: Encodable {
    let activity: PlannerActivity
}
/// 响应 `PATCH /api/planner/canvases/:id/visibility`。
struct PlannerCanvasVisibilityEnvelope: Encodable {
    let canvas: PlanningCanvas
}
/// 响应单个 run 的端点(start / get / abort)。
struct WorkflowRunEnvelope: Encodable {
    let run: WorkflowRun
}
/// 响应 `GET /api/planner/canvases/:id/runs` —— run 历史。
struct WorkflowRunsEnvelope: Encodable {
    let runs: [WorkflowRun]
}

struct CardTemplateEnvelope: Encodable { let template: CardTemplateStore.Entry? }
struct CardTemplatesEnvelope: Encodable { let templates: [CardTemplateStore.Entry] }

/// 响应 `GET /api/board/layout`。
struct BoardLayoutEnvelope: Encodable { let layout: BoardLayoutStore.Layout }

struct CanvasInfoDTO: Encodable {
    let id: String
    let name: String
    let scope: String
    let kind: String
    let isDefault: Bool
    let workspacePath: String
    let teamId: String?
    let ownerUserId: String?
    let remoteId: String?
    let remoteVersion: Int?
    let syncStatus: String?
    let dirtySince: String?
    let lastSyncedAt: String?
    let lastRemoteUpdatedAt: String?
}

struct CanvasSessionMembershipDTO: Encodable {
    let canvasId: String
    let sessionId: String
    let visible: Bool
    let layout: BoardLayoutStore.Point?
}

struct CanvasListEnvelope: Encodable {
    let canvases: [CanvasInfoDTO]
    let activeCanvasId: String
    let defaultCanvasIds: [String]
    let memberships: [CanvasSessionMembershipDTO]
}

// MARK: - 转换工具

enum BoardDTOBuilder {
    private struct Meee2TeamRecord: Codable {
        let id: String
        let name: String
        let role: String?
    }

    private struct SyncInfo {
        let enabled: Bool
        let teamId: String?
        let teamName: String?
    }

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

    private struct CountCacheEntry {
        let cachedAt: Date
        let value: Int
    }

    private struct EntrypointCacheEntry {
        let fileSize: UInt64
        let modifiedAt: TimeInterval
        let cachedAt: Date
        let value: String?
    }

    private struct FingerprintCacheEntry {
        let fileSize: UInt64
        let modifiedAt: TimeInterval
        let cachedAt: Date
    }

    private static let transcriptPreviewCacheLock = NSLock()
    private static var transcriptPreviewCache: [TranscriptPreviewCacheKey: TranscriptPreviewCacheEntry] = [:]
    private static let transcriptPreviewCacheMaxEntries = 256
    private static let transcriptPreviewCacheFreshSeconds: TimeInterval = 1.0
    private static let countCacheLock = NSLock()
    private static var countCache: [String: CountCacheEntry] = [:]
    private static let countCacheFreshSeconds: TimeInterval = 1.0
    private static let entrypointCacheLock = NSLock()
    private static var entrypointCache: [String: EntrypointCacheEntry] = [:]
    private static let fingerprintCacheLock = NSLock()
    private static var fingerprintCache: [String: FingerprintCacheEntry] = [:]
    private static let fingerprintCacheFreshSeconds: TimeInterval = 1.0
    private static let perfLoggingEnabled = ProcessInfo.processInfo.environment["MEEE2_PERF_LOG"] == "1"

    static func iso(_ date: Date) -> String { iso8601.string(from: date) }
    static func iso(_ date: Date?) -> String? {
        guard let d = date else { return nil }
        return iso8601.string(from: d)
    }

    static func coordinationGroupDTO(_ group: CoordinationGroup) -> CoordinationGroupDTO {
        CoordinationGroupDTO(
            id: group.id,
            canvasId: group.canvasId,
            coordinatorSessionId: group.coordinatorSessionId,
            pendingSpawnIntentId: group.pendingSpawnIntentId,
            memberSessionIds: group.memberSessionIds,
            mode: group.mode,
            goal: group.goal,
            paused: group.paused,
            memberDigests: group.memberDigests.mapValues { digest in
                MemberDigestDTO(
                    sessionId: digest.sessionId,
                    summary: digest.summary,
                    currentTask: digest.currentTask,
                    status: digest.status,
                    blockers: digest.blockers,
                    lastDecision: digest.lastDecision,
                    lastTranscriptCursor: digest.lastTranscriptCursor,
                    lastActivity: iso(digest.lastActivity)
                )
            },
            events: group.events.map { event in
                CoordinationEventDTO(
                    id: event.id,
                    groupId: event.groupId,
                    kind: event.kind,
                    reason: event.reason,
                    sessionIds: event.sessionIds,
                    contextPreview: event.contextPreview,
                    createdAt: iso(event.createdAt)
                )
            },
            lastWakeAt: iso(group.lastWakeAt),
            lastRoutedAction: group.lastRoutedAction,
            createdAt: iso(group.createdAt),
            updatedAt: iso(group.updatedAt)
        )
    }

    static func meee2OnlineTeams() -> [SyncTeamDTO] {
        let defaults = UserDefaults.standard
        let defaultTeamId = defaults.string(forKey: "meee2TeamId") ?? ""
        let defaultTeamName = defaults.string(forKey: "meee2TeamName") ?? ""
        let stored: [Meee2TeamRecord] = {
            guard let data = defaults.data(forKey: "meee2Teams"),
                  let decoded = try? JSONDecoder().decode([Meee2TeamRecord].self, from: data),
                  !decoded.isEmpty else {
                return []
            }
            return decoded
        }()

        if let team = stored.first {
            return [
                SyncTeamDTO(
                    id: team.id,
                    name: team.name,
                    role: team.role,
                    isDefault: true
                )
            ]
        }

        guard !defaultTeamId.isEmpty else { return [] }
        return [
            SyncTeamDTO(
                id: defaultTeamId,
                name: defaultTeamName.isEmpty ? "Default team" : defaultTeamName,
                role: nil,
                isDefault: true
            )
        ]
    }

    static func meee2DefaultSyncTeamName() -> String {
        let defaults = UserDefaults.standard
        let defaultTeamId = defaults.string(forKey: "meee2TeamId") ?? ""
        guard !defaultTeamId.isEmpty else { return "" }
        return meee2OnlineTeams().first(where: { $0.id == defaultTeamId })?.name
            ?? defaults.string(forKey: "meee2TeamName")
            ?? ""
    }

    private static func syncInfo(forSessionId sessionId: String) -> SyncInfo {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "meee2Connected") else {
            return SyncInfo(enabled: false, teamId: nil, teamName: nil)
        }

        let aliases = Meee2OnlinePusher.sessionIdAliases(sessionId)
        let disabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds")
        if !aliases.isDisjoint(with: disabled) {
            return SyncInfo(enabled: false, teamId: nil, teamName: nil)
        }

        let enabledByDefault = defaults.bool(forKey: "meee2Online")
        let explicitlyEnabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds")
        guard enabledByDefault || !aliases.isDisjoint(with: explicitlyEnabled) else {
            return SyncInfo(enabled: false, teamId: nil, teamName: nil)
        }

        let teams = meee2OnlineTeams()
        let teamId = teams.first?.id ?? defaults.string(forKey: "meee2TeamId") ?? ""
        guard !teamId.isEmpty else {
            return SyncInfo(enabled: false, teamId: nil, teamName: nil)
        }
        let teamName = teams.first(where: { $0.id == teamId })?.name
            ?? defaults.string(forKey: "meee2TeamName")
            ?? "Default team"
        return SyncInfo(enabled: true, teamId: teamId, teamName: teamName)
    }

    /// 按 channel 统计 pending + held 计数
    static func pendingCount(for channelName: String) -> Int {
        cachedCount(key: "channel:\(channelName)") {
            MessageRouter.shared
                .listMessages(channel: channelName, statuses: [.pending, .held])
                .count
        }
    }

    /// issue #25 诊断：缓存上一次 emit 时各 channel 的 memberCount。
    /// 当一个之前有成员的 channel 这次 emit 出 0 时，写一条 MWarn —— 用来抓
    /// "DTO 层在 leave 半途读到空成员快照然后推给前端导致 board flash" 的现场。
    private static var lastEmittedMemberCount: [String: Int] = [:]
    private static let lastEmittedMemberCountLock = NSLock()

    static func channelDTO(_ channel: Channel) -> ChannelDTO {
        let dto = ChannelDTO(
            name: channel.name,
            displayName: channel.displayName,
            mode: channel.mode.rawValue,
            members: channel.members.map { MemberDTO(alias: $0.alias, sessionId: $0.sessionId) },
            pendingCount: pendingCount(for: channel.name),
            description: channel.description,
            createdAt: iso(channel.createdAt)
        )
        let count = channel.members.count
        lastEmittedMemberCountLock.lock()
        let previous = lastEmittedMemberCount[channel.name]
        lastEmittedMemberCount[channel.name] = count
        lastEmittedMemberCountLock.unlock()
        if count == 0, let prev = previous, prev > 0 {
            MWarn("[StateTrace][channelDTO] channel='\(channel.name)' memberCount=0 (was \(prev) last emission)")
        }
        return dto
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
        let started = Date()
        defer {
            perfLog("sessionDTO", started: started, extra: "sid=\(session.id.prefix(8)),plugin=\(session.pluginId)")
        }
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
        let directPending = directInboxCount(for: session.id)
            + (realSessionId == session.id ? 0 : directInboxCount(for: realSessionId))
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
        let entrypoint = cachedEntrypoint(
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
        // 注：之前在这里算 displayGroup="older"（idle ≥ 1h），现在该判定挪到
        // 前端（board-app/types.ts isOlderSession）—— DTO 只下发原始 lastActivity，
        // 由 webui 决定要不要折叠/不自动建卡。

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

        let sync = syncInfo(forSessionId: session.id)
        let controlState = SessionControlStore.shared.state(for: [session.id, realSessionId])

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
            terminalKind: "external",
            surfaceId: nil,
            surfaceStatus: nil,
            canOpenExternal: true,
            terminalBackend: TerminalSessionBackendKind.external.rawValue,
            nativeWorkspaceAvailable: false,
            openTarget: "external",
            controlState: controlState.rawValue,
            backgroundAgents: bgAgents,
            latestRecap: recapDTO,
            clientKind: clientKind,
            syncEnabled: sync.enabled,
            syncTeamId: sync.teamId,
            syncTeamName: sync.teamName
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

        let sync = syncInfo(forSessionId: m.cliSessionId)
        let controlState = SessionControlStore.shared.state(for: [m.cliSessionId])

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
            terminalKind: "external",
            surfaceId: nil,
            surfaceStatus: nil,
            canOpenExternal: true,
            terminalBackend: TerminalSessionBackendKind.external.rawValue,
            nativeWorkspaceAvailable: false,
            openTarget: "external",
            controlState: controlState.rawValue,
            backgroundAgents: [],
            latestRecap: nil,
            clientKind: "desktop",
            syncEnabled: sync.enabled,
            syncTeamId: sync.teamId,
            syncTeamName: sync.teamName
        )
    }

    static func internalSessionDTO(_ surface: InternalTerminalSurfaceSnapshot) -> SessionDTO {
        let isCodex = surface.provider == "codex"
        let pluginId = isCodex ? "com.meee2.plugin.codex" : "com.meee2.plugin.claude"
        let info = PluginManager.shared.getPluginInfo(for: pluginId)
        let displayName = info?.displayName ?? (isCodex ? "Codex" : "Claude Code")
        let colorHex = info.map { hexString(from: $0.themeColor) } ?? (isCodex ? "#3B82F6" : "#FF9230")
        let sessionData = SessionStore.shared.get(surface.sessionId)
        let lifecycleStatus: SessionStatus = {
            switch surface.status {
            case "starting", "running":
                return sessionData?.status == .dead ? .dead : .active
            case "exited", "failed":
                return .dead
            default:
                return sessionData?.status ?? .idle
            }
        }()
        let sync = syncInfo(forSessionId: surface.sessionId)
        let providerResumeId = SessionTerminalStore.shared.get(sessionId: surface.sessionId)?
            .providerResumeSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let controlIds = [surface.sessionId, surface.surfaceId, providerResumeId]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let controlState = SessionControlStore.shared.state(for: controlIds)
        let backend = TerminalSessionBackendMetadata.kind(forSessionId: surface.sessionId) ?? .legacyInternal
        return SessionDTO(
            id: surface.sessionId,
            title: surface.title,
            project: surface.cwd,
            pluginId: pluginId,
            pluginDisplayName: displayName,
            pluginColor: colorHex,
            status: lifecycleStatus.rawValue,
            inboxPending: directInboxCount(for: surface.sessionId),
            recentMessages: [],
            currentTool: surface.status == "running" ? "terminal" : nil,
            startedAt: iso8601.string(from: surface.createdAt),
            lastActivity: iso8601.string(from: surface.updatedAt),
            usageStats: nil,
            tasks: [],
            currentTask: surface.nodeId.map { "Node \($0)" },
            pendingPermissionTool: sessionData?.pendingPermissionTool,
            pendingPermissionMessage: sessionData?.pendingPermissionMessage,
            ghosttyTerminalId: nil,
            tty: nil,
            termProgram: "meee2-internal",
            terminalKind: "internal",
            surfaceId: surface.surfaceId,
            surfaceStatus: surface.status,
            canOpenExternal: false,
            terminalBackend: backend.rawValue,
            nativeWorkspaceAvailable: true,
            openTarget: "native-workspace",
            controlState: controlState.rawValue,
            backgroundAgents: [],
            latestRecap: nil,
            clientKind: "cli",
            syncEnabled: sync.enabled,
            syncTeamId: sync.teamId,
            syncTeamName: sync.teamName
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
        let now = Date()
        fingerprintCacheLock.lock()
        if let cached = fingerprintCache[path],
           now.timeIntervalSince(cached.cachedAt) < fingerprintCacheFreshSeconds {
            fingerprintCacheLock.unlock()
            return (cached.fileSize, cached.modifiedAt)
        }
        fingerprintCacheLock.unlock()

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let fileSize = (attrs[.size] as? NSNumber)?.uint64Value
        let modifiedAt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        guard let fileSize = fileSize, let modifiedAt = modifiedAt else {
            return nil
        }

        fingerprintCacheLock.lock()
        fingerprintCache[path] = FingerprintCacheEntry(
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            cachedAt: now
        )
        if fingerprintCache.count > 512 {
            fingerprintCache.removeAll(keepingCapacity: true)
        }
        fingerprintCacheLock.unlock()
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
        cachedCount(key: "inbox:\(sessionId)") {
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
    }

    private static func directInboxCount(for sessionId: String) -> Int {
        cachedCount(key: "direct-inbox:\(sessionId)") {
            MessageRouter.shared.peekInbox(sessionId: sessionId).count
        }
    }

    private static func cachedCount(key: String, load: () -> Int) -> Int {
        let now = Date()
        countCacheLock.lock()
        if let cached = countCache[key],
           now.timeIntervalSince(cached.cachedAt) < countCacheFreshSeconds {
            let value = cached.value
            countCacheLock.unlock()
            return value
        }
        countCacheLock.unlock()

        let value = load()

        countCacheLock.lock()
        countCache[key] = CountCacheEntry(cachedAt: now, value: value)
        if countCache.count > 512 {
            countCache.removeAll(keepingCapacity: true)
        }
        countCacheLock.unlock()
        return value
    }

    private static func cachedEntrypoint(transcriptPath: String?) -> String? {
        guard let path = transcriptPath else { return nil }
        guard let fingerprint = transcriptPreviewFingerprint(path: path) else {
            return ClaudeEntrypointReader.read(transcriptPath: path)
        }

        let now = Date()
        entrypointCacheLock.lock()
        if let cached = entrypointCache[path],
           cached.fileSize == fingerprint.fileSize,
           cached.modifiedAt == fingerprint.modifiedAt {
            let value = cached.value
            entrypointCacheLock.unlock()
            return value
        }
        entrypointCacheLock.unlock()

        let value = ClaudeEntrypointReader.read(transcriptPath: path)
        entrypointCacheLock.lock()
        entrypointCache[path] = EntrypointCacheEntry(
            fileSize: fingerprint.fileSize,
            modifiedAt: fingerprint.modifiedAt,
            cachedAt: now,
            value: value
        )
        if entrypointCache.count > 256,
           let oldest = entrypointCache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
            entrypointCache.removeValue(forKey: oldest)
        }
        entrypointCacheLock.unlock()
        return value
    }

    private static func perfLog(_ name: String, started: Date, extra: String = "") {
        guard perfLoggingEnabled else { return }
        let ms = Date().timeIntervalSince(started) * 1_000
        let suffix = extra.isEmpty ? "" : " \(extra)"
        MLog(String(format: "[Perf][BoardDTO] %@ %.1fms%@", name, ms, suffix))
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

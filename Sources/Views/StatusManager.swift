import Foundation
import Combine
import SwiftUI
import Meee2PluginKit
import Meee2CommKit

/// 状态管理器 - 聚合所有插件的数据
/// 作为 UI 的数据源
public class StatusManager: ObservableObject {
    /// Island attention 重算的最小间隔(throttle 窗口)。高频 hook 风暴下,
    /// 重算被合并成「每个窗口最多一次」,避免主线程被全量 session 关联计算吃满。
    private static let islandAttentionRecomputeInterval: DispatchQueue.SchedulerTimeType.Stride = .seconds(1)
    /// Dynamic Island 只需要近实时的 monitor attention,不应该每秒执行完整
    /// workspaceMonitor(canvasState + event sort)。Board 页面/API 仍然实时计算。
    private static let islandMonitorCacheTTL: TimeInterval = 10

    // MARK: - Published Properties

    /// 所有 sessions (来自所有插件，包括 Claude)
    @Published public var sessions: [PluginSession] = []

    /// 是否有需要用户介入的 session
    @Published public var hasUrgentSession: Bool = false

    /// 系统状态
    @Published public var systemStatus: SystemStatus = .idle

    /// 最新的事件消息
    @Published public var latestMessage: String?

    /// Dynamic Island 的高维 attention 聚合状态。
    @Published var islandAttentionState: IslandAttentionState = .empty()
    private var islandMonitorItemsCache: (generatedAt: Date, items: [PlannerMonitorItem])?

    /// 刘海尺寸 (由 AppDelegate 设置)
    @Published public var notchSize: CGSize = CGSize(width: 150, height: 32)

    // MARK: - Computed Properties

    /// 当前紧急 session 列表 (urgentEvent != nil)
    public var urgentSessions: [PluginSession] {
        sessions.filter { $0.urgentEvent != nil }
    }

    /// 当前第一个紧急 session
    public var currentUrgentSession: PluginSession? {
        urgentSessions.first
    }

    /// 当前紧急消息
    public var currentUrgentMessage: String? {
        currentUrgentSession?.urgentEvent?.message
    }

    // MARK: - Private Properties

    let pluginManager: PluginManager
    private var cancellables = Set<AnyCancellable>()

    /// Island attention 重算的统一去抖入口 —— 所有触发源(sessions 变更 /
    /// SessionEventBus 事件)都 send 到这里,由 throttle 合并高频风暴。
    private let islandRecomputeSubject = PassthroughSubject<Void, Never>()

    // MARK: - System Status

    public enum SystemStatus {
        case idle          // 无活跃 session
        case running       // 有 session 运行中
        case needsAttention  // 需要用户介入
        case error         // 有错误发生
    }

    // MARK: - Initialization

    public init() {
        pluginManager = PluginManager.shared
        setupBindings()
    }

    deinit {
        pluginManager.stopAll()
    }

    // MARK: - Public Methods

    /// 启动监控
    public func start() {
        // 注册 ClaudePlugin (内置插件)
        let claudePlugin = ClaudePlugin()
        pluginManager.register(claudePlugin)

        // 启动所有 plugins
        pluginManager.startAll()

        NSLog("[StatusManager] Started with ClaudePlugin registered")
    }

    /// 停止监控
    public func stop() {
        pluginManager.stopAll()
        NSLog("[StatusManager] Stopped")
    }

    // MARK: - Session Operations

    /// 激活 session 对应的终端
    public func activateTerminal(for session: PluginSession) {
        pluginManager.activateTerminal(for: session)
    }

    /// 清除 session 的 urgentEvent 状态
    public func clearUrgentEvent(session: PluginSession) {
        pluginManager.clearUrgentEvent(sessionId: session.id, pluginId: session.pluginId)
    }

    /// 响应权限请求
    public func respondToPermission(for session: PluginSession, decision: PermissionDecision) {
        session.urgentEvent?.respond?(decision)
    }

    /// 关闭指定紧急 session
    public func dismissUrgent(sessionId: String) {
        // 通过响应 .deny 来关闭权限请求
        if let session = sessions.first(where: { $0.id == sessionId }),
           let event = session.urgentEvent {
            event.respond?(.deny(reason: "Dismissed by user"))
        }
    }

    func openBoard(for item: IslandAttentionItem) {
        NotificationCenter.default.post(
            name: NSNotification.Name("meee2.openPlannerItem"),
            object: nil,
            userInfo: [
                "canvasId": item.canvasId ?? "",
                "nodeId": item.nodeId ?? "",
                "deliveryId": item.deliveryId ?? "",
                "proposalId": item.proposalId ?? ""
            ]
        )
    }

    func rejectProposal(for item: IslandAttentionItem) {
        guard let canvasId = item.canvasId, let proposalId = item.proposalId else { return }
        do {
            _ = try PlannerBoardBridge.rejectProposal(
                proposalId: proposalId,
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            BoardServer.shared.broadcastStateChanged()
            islandMonitorItemsCache = nil
            refreshIslandAttentionState()
        } catch {
            MWarn("[StatusManager] failed to reject proposal from Island: \(error.localizedDescription)")
        }
    }

    // MARK: - Plugin Info

    /// 获取 plugin 信息
    public func getPluginInfo(for pluginId: String) -> (displayName: String, icon: String, themeColor: Color)? {
        pluginManager.getPluginInfo(for: pluginId)
    }

    // MARK: - Private Methods

    private func setupBindings() {
        // Island attention 重算(currentBoardSessions → 对全量 session 做 surface→CLI
        // 关联)是主线程上的重计算。并发会话多时,$sessions 与 SessionEventBus 会被
        // 每个 hook 高频触发;若每个事件都即时重算,会吃满主线程(实测单核 ~93%)。
        // 统一走一个 throttle 入口,把风暴合并成「每 islandAttentionRecomputeInterval
        // 最多重算一次」。用 throttle(latest:) 而非 debounce —— debounce 在持续不断的
        // 事件流下会一直推迟、整个忙碌期都不刷新;throttle 保证每个窗口至少落地一次最新态。
        islandRecomputeSubject
            .throttle(for: Self.islandAttentionRecomputeInterval, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                guard let self = self else { return }
                self.refreshIslandAttentionState()
                self.updateSystemStatus()
            }
            .store(in: &cancellables)

        // 订阅 PluginManager.sessions —— 只做便宜的即时更新(驱动 UI 列表/badge),
        // 昂贵的 island 重算交给上面的 throttle 入口,不在每个 hook 上同步全量重算。
        pluginManager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self = self else { return }
                self.sessions = sessions
                    .filter(Self.isManagedIslandSession)
                    .filter { !$0.status.isHistorical || $0.urgentEvent != nil }
                // 通知 AppDelegate 更新状态栏图标
                NotificationCenter.default.post(name: NSNotification.Name("SessionsDidChange"), object: nil)
                self.islandRecomputeSubject.send()
            }
            .store(in: &cancellables)

        // 检测 urgent 状态
        pluginManager.$sessions
            .map {
                $0.contains {
                    Self.isManagedIslandSession($0) && !$0.status.isHistorical && $0.urgentEvent != nil
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasUrgentSession)

        SessionEventBus.shared.publisher
            .filter(Self.shouldRefreshIslandAttention)
            .sink { [weak self] _ in
                self?.islandRecomputeSubject.send()
            }
            .store(in: &cancellables)
    }

    private static func shouldRefreshIslandAttention(for event: SessionEvent) -> Bool {
        switch event {
        case .boardLayoutChanged, .sessionAdded, .sessionRemoved, .sessionMetadataChanged:
            return true
        case .transcriptAppended, .channelMutated, .messageMutated, .cardTemplateChanged, .plannerCanvasChanged:
            return false
        }
    }

    private static func isManagedIslandSession(_ session: PluginSession) -> Bool {
        let realId = session.id.hasPrefix("\(session.pluginId)-")
            ? String(session.id.dropFirst("\(session.pluginId)-".count))
            : session.id
        if TerminalSessionBackendRegistry.shared.isManagedSession(session.id)
            || TerminalSessionBackendRegistry.shared.isManagedSession(realId) {
            return true
        }
        let termProgram = (
            SessionStore.shared.get(session.id)?.terminalInfo?.termProgram
                ?? SessionStore.shared.get(realId)?.terminalInfo?.termProgram
                ?? session.terminalInfo?.termProgram
                ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return termProgram == "meee2-internal" || termProgram == "meee2-ghostty-surface"
    }

    private func updateSystemStatus() {
        if islandAttentionState.hasAttention {
            systemStatus = .needsAttention
            return
        }

        if sessions.isEmpty {
            systemStatus = .idle
            return
        }

        if hasUrgentSession || sessions.contains(where: { $0.status.needsUserAction }) {
            systemStatus = .needsAttention
            return
        }

        systemStatus = .running
    }

    private func refreshIslandAttentionState(sessions sourceSessions: [PluginSession]? = nil) {
        let visibleSessions = sourceSessions ?? sessions
        islandAttentionState = IslandAttentionBuilder.build(sessions: visibleSessions) {
            try cachedIslandMonitorItems()
        }
    }

    private func cachedIslandMonitorItems() throws -> [PlannerMonitorItem] {
        if let cached = islandMonitorItemsCache,
           Date().timeIntervalSince(cached.generatedAt) < Self.islandMonitorCacheTTL {
            return cached.items
        }
        let monitor = try PlannerBoardBridge.workspaceMonitor(
            snapshot: BoardLayoutStore.shared.snapshot(),
            actorUserId: PlannerPermission.currentActorId(),
            sessions: BoardSessionSnapshotProvider.currentBoardSessions()
        )
        islandMonitorItemsCache = (Date(), monitor.items)
        return monitor.items
    }
}

// MARK: - 时间格式化

extension StatusManager {
    /// 格式化运行时间
    public func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.0fs", duration)
        } else if duration < 3600 {
            let minutes = Int(duration / 60)
            return "\(minutes)m"
        } else {
            let hours = Int(duration / 3600)
            let remainingSeconds = duration - TimeInterval(hours * 3600)
            let minutes = Int(remainingSeconds / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}

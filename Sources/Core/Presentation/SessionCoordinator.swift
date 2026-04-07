import Foundation
import Combine
import SwiftUI
import PeerPluginKit

/// 紧急事件信息
public struct UrgentEventInfo: Identifiable {
    public let id: String   // session id
    public let session: Session
    public let event: UrgentEvent
    public let message: String
}

/// 系统状态
public enum SystemStatus {
    case idle
    case running
    case needsAttention
    case error
}

/// 会话协调器
/// 替代原有的 StatusManager，聚合所有插件的会话并为 UI 提供统一数据源
public class SessionCoordinator: ObservableObject {
    // MARK: - Published (UI 消费)

    /// 所有会话（统一列表）
    @Published public var sessions: [Session] = []

    /// 紧急事件列表
    @Published public var urgentEvents: [UrgentEventInfo] = []

    /// 是否有紧急事件
    @Published public var hasUrgentSession: Bool = false

    /// 最新消息
    @Published public var latestMessage: String?

    /// 系统状态
    @Published public var systemStatus: SystemStatus = .idle

    /// 刘海尺寸
    @Published public var notchSize: CGSize = CGSize(width: 150, height: 32)

    // MARK: - Computed

    /// 当前第一个紧急事件
    public var currentUrgentEvent: UrgentEventInfo? {
        urgentEvents.first
    }

    /// 当前紧急会话
    public var currentUrgentSession: Session? {
        urgentEvents.first?.session
    }

    /// 当前紧急消息
    public var currentUrgentMessage: String? {
        urgentEvents.first?.message
    }

    // MARK: - IslandView 兼容属性

    /// 紧急会话列表 (从 urgentEvents 派生)
    public var urgentSessions: [Session] {
        urgentEvents.map(\.session)
    }

    /// 紧急消息字典 (sessionId → message)
    public var urgentMessages: [String: String] {
        Dictionary(urgentEvents.map { ($0.id, $0.message) }, uniquingKeysWith: { _, last in last })
    }

    /// 查找紧急事件类型
    public func urgentEventType(for sessionId: String) -> String? {
        urgentEvents.first { $0.id == sessionId }?.event.eventType
    }

    /// 插件是否正在加载
    public var isLoading: Bool {
        registry.isLoading
    }

    // MARK: - Internal

    let registry: PluginRegistry
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    public init(registry: PluginRegistry = .shared) {
        self.registry = registry
        setupBindings()
    }

    // MARK: - 生命周期

    public func start() {
        registry.registerBuiltin()
        registry.loadExternalPlugins()
        registry.startAll()
        NSLog("[SessionCoordinator] Started")
    }

    public func stop() {
        registry.stopAll()
    }

    // MARK: - 终端跳转

    public func activateTerminal(for session: Session) {
        registry.activateTerminal(for: session)
    }

    // MARK: - 紧急事件管理

    /// 关闭指定会话的紧急事件
    public func dismissUrgent(sessionId: String) {
        urgentEvents.removeAll { $0.id == sessionId }
        hasUrgentSession = !urgentEvents.isEmpty
        if !hasUrgentSession {
            updateSystemStatus()
        }
        NSLog("[SessionCoordinator] Dismissed urgent: \(sessionId), remaining: \(urgentEvents.count)")
    }

    /// 关闭当前（第一个）紧急事件
    public func dismissCurrentUrgent() {
        guard !urgentEvents.isEmpty else { return }
        let dismissed = urgentEvents.removeFirst()
        hasUrgentSession = !urgentEvents.isEmpty
        if !hasUrgentSession {
            updateSystemStatus()
        }
        NSLog("[SessionCoordinator] Dismissed current urgent: \(dismissed.id)")
    }

    /// 清除所有紧急事件
    public func clearUrgentSessions() {
        urgentEvents.removeAll()
        hasUrgentSession = false
        updateSystemStatus()
    }

    // MARK: - 权限确认

    /// 确认权限请求 (跳转终端 + 关闭紧急面板)
    public func confirmPermission(for session: Session) {
        activateTerminal(for: session)
        dismissUrgent(sessionId: session.id)
    }

    // MARK: - 插件查询

    /// 获取插件信息
    public func getPluginInfo(for pluginId: String) -> (displayName: String, icon: String, themeColor: Color)? {
        registry.getPluginInfo(for: pluginId)
    }

    // MARK: - 时间格式化

    public func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.0fs", duration)
        } else if duration < 3600 {
            return "\(Int(duration / 60))m"
        } else {
            let hours = Int(duration / 3600)
            let minutes = Int((duration - TimeInterval(hours * 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }

    // MARK: - 内部

    private func setupBindings() {
        // 订阅 registry 的会话变化
        registry.$allSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.sessions = sessions
                self?.updateSystemStatus()
            }
            .store(in: &cancellables)

        // 订阅紧急事件通知
        NotificationCenter.default.publisher(for: .aiPluginUrgentEvent)
            .compactMap { $0.userInfo }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                guard let session = info["session"] as? Session,
                      let event = info["event"] as? UrgentEvent else { return }
                self?.handleUrgentEvent(session: session, event: event)
            }
            .store(in: &cancellables)
    }

    private func handleUrgentEvent(session: Session, event: UrgentEvent) {
        let info = UrgentEventInfo(
            id: session.id,
            session: session,
            event: event,
            message: event.message
        )

        // 如果已存在，更新；否则添加
        if let idx = urgentEvents.firstIndex(where: { $0.id == session.id }) {
            urgentEvents[idx] = info
        } else {
            urgentEvents.append(info)
        }

        hasUrgentSession = true
        systemStatus = .needsAttention
        latestMessage = event.message

        NSLog("[SessionCoordinator] Urgent event: \(session.id) - \(event.message)")
    }

    private func updateSystemStatus() {
        if sessions.isEmpty && urgentEvents.isEmpty {
            systemStatus = .idle
            return
        }

        if sessions.contains(where: { $0.status == .failed }) {
            systemStatus = .error
            return
        }

        if !urgentEvents.isEmpty || sessions.contains(where: { $0.status.needsUserAction }) {
            systemStatus = .needsAttention
            return
        }

        systemStatus = .running
    }
}

import Combine
import Foundation

/// 统一的 Session/Channel/Message 事件总线
///
/// 所有可见的状态变更都应在此流中 emit 一个 `SessionEvent`，消费端（BoardServer 等）
/// 通过 `.debounce` 自行聚合，避免各自 polling。
public enum SessionEvent: Sendable {
    /// 新 session 第一次出现在 SessionStore 中
    case sessionAdded(sessionId: String)
    /// Session 从 SessionStore 中移除
    case sessionRemoved(sessionId: String)
    /// Session 元数据变更（status、currentTool、terminalInfo、usage 等）
    case sessionMetadataChanged(sessionId: String)
    /// 新 transcript 内容到达（Stop/PostToolUse/SessionEnd 或带 lastAssistantMessage）
    case transcriptAppended(sessionId: String)
    /// 频道创建/删除/加入/离开/改模式/通用 update
    case channelMutated(name: String)
    /// 消息创建/hold/drop/edit/deliver
    case messageMutated(id: String, channel: String)
    /// Custom card 模板文件保存或删除（template id 为文件名不含扩展名）
    case cardTemplateChanged(id: String)
    /// 看板坐标（session 卡片位置 + channel hub 位置）整体写入成功
    case boardLayoutChanged
}

/// 事件总线单例。`publish` 线程安全（PassthroughSubject.send 可从任意线程调用），
/// 投递顺序为 best-effort；订阅者负责自己的线程路由与去抖。
public final class SessionEventBus: @unchecked Sendable {
    public static let shared = SessionEventBus()
    private init() {}

    private let subject = PassthroughSubject<SessionEvent, Never>()

    /// 供订阅者使用的类型擦除 Publisher
    public var publisher: AnyPublisher<SessionEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Fire-and-forget 发布事件
    public func publish(_ event: SessionEvent) {
        subject.send(event)
    }
}

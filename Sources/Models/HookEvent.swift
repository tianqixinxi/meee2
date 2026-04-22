import Foundation
import Meee2PluginKit

/// 用于解码任意 JSON 值的包装类型
public struct AnyCodable: Decodable, @unchecked Sendable {
    private let _value: Any?

    public var value: Any? {
        return _value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            _value = string
        } else if let int = try? container.decode(Int.self) {
            _value = int
        } else if let double = try? container.decode(Double.self) {
            _value = double
        } else if let bool = try? container.decode(Bool.self) {
            _value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            _value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            _value = dict.mapValues { $0.value }
        } else {
            _value = nil
        }
    }

    var description: String {
        if let v = _value {
            return String(describing: v)
        }
        return "null"
    }
}

/// Claude CLI Hook 事件类型
/// 参考 settings.json 中配置的 hooks
public enum HookEventType: String, Codable, Sendable {
    case notification = "Notification"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case preToolUse = "PreToolUse"
    case preCompact = "PreCompact"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case userPromptSubmit = "UserPromptSubmit"

    /// 转换为音效事件
    public var soundEvent: SoundEvent? {
        switch self {
        case .sessionStart:
            return .sessionStart
        case .permissionRequest:
            return .permissionRequest
        case .notification:
            return .notification
        case .stop:
            return .stop
        case .sessionEnd:
            return .sessionEnd
        case .preToolUse:
            return .preToolUse
        case .postToolUse:
            return .postToolUse
        case .userPromptSubmit:
            return .userPromptSubmit
        case .preCompact, .subagentStart, .subagentStop:
            return nil
        }
    }
}

/// Hook 事件数据结构
/// 从 Claude CLI hooks stdin 读取的 JSON 数据
public struct HookEvent: Decodable, Sendable {
    /// 事件类型
    public let event: HookEventType?

    /// 触发此事件的 session ID
    public let sessionId: String?

    /// 工作目录
    public let cwd: String?

    /// 通知消息内容
    public let notification: String?

    /// 最后的 assistant 消息 (Stop 事件)
    public let lastAssistantMessage: String?

    /// 工具使用 ID (用于 PermissionRequest 关联)
    public var toolUseId: String?

    /// 工具使用信息 (PostToolUse)
    public let toolName: String?

    /// 工具输入 (原始 JSON 对象)
    private let rawToolInput: AnyCodable?

    /// 工具输入字符串 (用于显示)
    public var toolInput: String? {
        if let raw = rawToolInput {
            return raw.description
        }
        return nil
    }

    /// 工具输入字典 (用于解析结构化数据)
    public var toolInputDict: [String: Any]? {
        if let raw = rawToolInput, let dict = raw.value as? [String: Any] {
            return dict
        }
        return nil
    }

    /// 工具输出 (原始 JSON 对象)
    private let rawToolOutput: AnyCodable?
    public var toolOutput: String? {
        if let raw = rawToolOutput {
            return raw.description
        }
        return nil
    }

    /// 工具输出字典 (用于解析结构化数据)
    public var toolOutputDict: [String: Any]? {
        if let raw = rawToolOutput, let dict = raw.value as? [String: Any] {
            return dict
        }
        return nil
    }

    /// 权限请求详情
    public let permission: String?
    public let resource: String?

    /// 权限状态 (waiting_for_approval, etc.)
    public let status: String?

    /// 终端 tty 设备 (如 /dev/ttys016)
    public let tty: String?

    /// 终端程序名 (ghostty, iTerm2, Terminal, cmux, etc.)
    public let termProgram: String?

    /// 终端 Bundle ID
    public let termBundleId: String?

    /// cmux socket 路径 (用于 cmux 精确定位)
    public let cmuxSocketPath: String?

    /// cmux surface ID (用于 cmux tab 定位)
    public let cmuxSurfaceId: String?

    /// Ghostty 原生 terminal ID（来自 AppleScript `id of terminal`），用于
    /// `tell application "Ghostty" to focus (terminal id "X")` 精确跳转。
    /// 只在 SessionStart/UserPromptSubmit 这类用户刚触发的事件里由 bridge 捕获。
    public let ghosttyTerminalId: String?

    /// 时间戳
    public let timestamp: Date?

    /// 原始 JSON 数据 (用于调试)
    public var rawData: String?

    // MARK: - 计算属性

    /// 根据事件类型和状态推断 session 状态
    public var inferredStatus: SessionStatus {
        // 优先根据 status 字段判断
        if let status = status {
            switch status {
            case "waiting_for_approval":
                return .permissionRequest
            case "waiting_for_input":
                return .completed
            case "running_tool", "processing", "starting":
                return .running
            case "compacting":
                return .compacting
            default:
                break
            }
        }

        // 回退到根据 event 类型判断
        switch event {
        case .notification:
            // 通知事件通常表示任务完成或有消息
            if let msg = notification, msg.contains("completed") || msg.contains("finished") {
                return .completed
            }
            return .running

        case .permissionRequest:
            return .permissionRequest

        case .postToolUse:
            // 正在使用工具
            return .tooling

        case .preToolUse:
            // 准备使用工具，正在思考
            return .thinking

        case .preCompact:
            return .compacting

        case .sessionStart:
            return .running

        case .sessionEnd, .stop:
            return .completed

        case .subagentStart:
            return .running

        case .subagentStop:
            return .running

        case .userPromptSubmit:
            return .thinking

        case .none:
            return .running
        }
    }

    /// 是否需要用户介入
    public var needsUserAction: Bool {
        switch event {
        case .permissionRequest:
            return true
        case .notification:
            // 所有通知都需要用户确认
            return true
        case .stop, .sessionEnd:
            // 任务完成时需要用户查看结果
            return true
        default:
            return false
        }
    }

    /// 是否应该显示 Urgent Panel
    /// 只有有实际内容的事件才显示，过滤掉无意义的 "Task completed" 等
    public var shouldShowUrgentPanel: Bool {
        switch event {
        case .permissionRequest:
            return true
        case .notification:
            // 过滤无意义的 notification
            if let notification = notification {
                let emptyNotifications = ["Task completed", "任务完成", "Done", "Finished"]
                return !emptyNotifications.contains(notification)
            }
            return false
        case .stop, .sessionEnd:
            // Stop/SessionEnd 事件：有 lastAssistantMessage 时显示
            if let message = lastAssistantMessage, !message.isEmpty {
                return true
            }
            return false
        default:
            // 其他事件：如果 status 是 waiting_for_input，也需要显示
            if status == "waiting_for_input" {
                return true
            }
            return false
        }
    }

    /// 是否需要响应 (PermissionRequest 且状态为 waiting_for_approval)
    public var expectsResponse: Bool {
        event == .permissionRequest && status == "waiting_for_approval"
    }

    /// 生成简短的状态描述
    public var statusDescription: String? {
        switch event {
        case .notification:
            return notification

        case .permissionRequest:
            return "需要确认: \(permission ?? "未知权限")"

        case .postToolUse:
            if let tool = toolName {
                return "使用工具: \(tool)"
            }
            return "执行中..."

        case .preToolUse:
            if let tool = toolName {
                return "准备使用: \(tool)"
            }
            return "准备执行..."

        case .preCompact:
            return "压缩上下文..."

        case .sessionStart:
            return "Session 开始"

        case .sessionEnd:
            return "Session 结束"

        case .stop:
            // 显示完整的任务摘要
            return lastAssistantMessage ?? "任务完成"

        case .subagentStart:
            return "子任务开始"

        case .subagentStop:
            return "子任务结束"

        case .userPromptSubmit:
            return "收到用户输入"

        case .none:
            return nil
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case event
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case notification
        case lastAssistantMessage = "last_assistant_message"
        case toolName = "tool_name"
        case rawToolInput = "tool_input"
        case rawToolOutput = "tool_response"
        case toolUseId = "tool_use_id"
        case permissionMode = "permission_mode"
        case permission
        case resource
        case status
        case tty
        case termProgram
        case termBundleId
        case cmuxSocketPath
        case cmuxSurfaceId
        case ghosttyTerminalId
        case timestamp
    }

    // MARK: - Initializers

    /// 普通初始化方法
    public init(
        event: HookEventType? = nil,
        sessionId: String? = nil,
        cwd: String? = nil,
        notification: String? = nil,
        lastAssistantMessage: String? = nil,
        toolUseId: String? = nil,
        toolName: String? = nil,
        rawToolInput: AnyCodable? = nil,
        rawToolOutput: AnyCodable? = nil,
        permission: String? = nil,
        resource: String? = nil,
        status: String? = nil,
        tty: String? = nil,
        termProgram: String? = nil,
        termBundleId: String? = nil,
        cmuxSocketPath: String? = nil,
        cmuxSurfaceId: String? = nil,
        ghosttyTerminalId: String? = nil,
        timestamp: Date? = nil,
        rawData: String? = nil
    ) {
        self.event = event
        self.sessionId = sessionId
        self.cwd = cwd
        self.notification = notification
        self.lastAssistantMessage = lastAssistantMessage
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.rawToolInput = rawToolInput
        self.rawToolOutput = rawToolOutput
        self.permission = permission
        self.resource = resource
        self.status = status
        self.tty = tty
        self.termProgram = termProgram
        self.termBundleId = termBundleId
        self.cmuxSocketPath = cmuxSocketPath
        self.cmuxSurfaceId = cmuxSurfaceId
        self.ghosttyTerminalId = ghosttyTerminalId
        self.timestamp = timestamp
        self.rawData = rawData
    }

    /// Codable 初始化方法
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 优先从 hook_event_name 解码事件类型
        if let eventType = try container.decodeIfPresent(HookEventType.self, forKey: .hookEventName) {
            event = eventType
        } else {
            // 回退到 event 字段，但处理空字符串
            if let eventString = try container.decodeIfPresent(String.self, forKey: .event),
               !eventString.isEmpty {
                event = HookEventType(rawValue: eventString)
            } else {
                event = nil
            }
        }

        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        notification = try container.decodeIfPresent(String.self, forKey: .notification)
        lastAssistantMessage = try container.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        rawToolInput = try container.decodeIfPresent(AnyCodable.self, forKey: .rawToolInput)
        rawToolOutput = try container.decodeIfPresent(AnyCodable.self, forKey: .rawToolOutput)
        permission = try container.decodeIfPresent(String.self, forKey: .permission)
        resource = try container.decodeIfPresent(String.self, forKey: .resource)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        termProgram = try container.decodeIfPresent(String.self, forKey: .termProgram)
        termBundleId = try container.decodeIfPresent(String.self, forKey: .termBundleId)
        cmuxSocketPath = try container.decodeIfPresent(String.self, forKey: .cmuxSocketPath)
        cmuxSurfaceId = try container.decodeIfPresent(String.self, forKey: .cmuxSurfaceId)
        ghosttyTerminalId = try container.decodeIfPresent(String.self, forKey: .ghosttyTerminalId)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
    }
}

// MARK: - 解析助手

public extension HookEvent {
    /// 从 JSON 字符串解析 HookEvent
    static func parse(from jsonString: String) -> HookEvent? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        var event: HookEvent?
        do {
            event = try JSONDecoder().decode(HookEvent.self, from: data)
        } catch {
            // JSON 解析失败，尝试创建基本事件
            print("HookEvent parse error: \(error)")
        }

        if var event = event {
            event.rawData = jsonString
            return event
        }

        return nil
    }

    /// 从 stdin 数据创建默认事件
    static func fromStdin(data: String, session: ClaudeSession) -> HookEvent {
        var event = HookEvent.parse(from: data) ?? HookEvent(
            event: nil,
            sessionId: session.id,
            cwd: session.cwd,
            notification: nil,
            lastAssistantMessage: nil,
            toolUseId: nil,
            toolName: nil,
            rawToolInput: nil,
            rawToolOutput: nil,
            permission: nil,
            resource: nil,
            status: nil,
            tty: nil,
            termProgram: nil,
            termBundleId: nil,
            cmuxSocketPath: nil,
            cmuxSurfaceId: nil,
            ghosttyTerminalId: nil,
            timestamp: Date()
        )
        event.rawData = data
        return event
    }
}
import Foundation
import SwiftUI

/// 动画类型枚举
public enum StatusAnimation {
    case none           // 无动画
    case pulse          // 脉冲呼吸
    case rotate         // 旋转
    case bounce         // 弹跳
}

/// 精细状态枚举 - 用于更详细的会话状态展示
/// 移植自 csm 的 detailed_status 字段
public enum DetailedStatus: String, Codable, CaseIterable {
    case idle              // 空闲
    case thinking          // 思考中
    case tooling           // 工具调用中
    case active            // 活跃
    case waitingForUser    // 等待用户
    case permissionRequired // 需要权限
    case compacting        // 压缩中
    case completed         // 已完成
    case dead              // 已终止

    /// 状态图标（SF Symbol 名称，用于 GUI）
    public var icon: String {
        switch self {
        case .idle: return "ellipsis.circle"
        case .thinking: return "brain.head.profile"
        case .tooling: return "wrench.and.screwdriver.fill"
        case .active: return "play.circle.fill"
        case .waitingForUser: return "hand.raised.fill"
        case .permissionRequired: return "lock.shield.fill"
        case .compacting: return "rectangle.compress.vertical"
        case .completed: return "checkmark.circle.fill"
        case .dead: return "xmark.circle.fill"
        }
    }

    /// 终端图标（文本图标，用于 CLI/TUI）
    public var terminalIcon: String {
        switch self {
        case .idle: return "○"
        case .thinking: return "🧠"
        case .tooling: return "🔧"
        case .active: return "▶"
        case .waitingForUser: return "✋"
        case .permissionRequired: return "🔒"
        case .compacting: return "📦"
        case .completed: return "✅"
        case .dead: return "❌"
        }
    }

    /// SF Symbol 名称（与 icon 相同，用于 SwiftUI Image）
    public var sfSymbolName: String { icon }

    /// 状态颜色（简化为4种核心颜色）
    public var color: Color {
        switch self {
        case .waitingForUser, .permissionRequired:
            return .orange  // 需要用户介入（最重要）
        case .thinking, .tooling, .active, .compacting:
            return .blue    // 正在运行中
        case .idle, .completed:
            return .gray    // 空闲/完成
        case .dead:
            return .red     // 异常终止
        }
    }

    /// 是否显示右侧状态图标（只在需要用户介入时显示）
    public var showsRightIcon: Bool {
        switch self {
        case .waitingForUser, .permissionRequired:
            return true
        default:
            return false
        }
    }

    /// 右侧状态图标（只用于需要介入的情况）
    public var rightIcon: String? {
        switch self {
        case .waitingForUser, .permissionRequired:
            return "hand.raised.fill"
        default:
            return nil
        }
    }

    /// 状态显示名称
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .tooling: return "Tooling"
        case .active: return "Active"
        case .waitingForUser: return "Waiting"
        case .permissionRequired: return "Permission"
        case .compacting: return "Compacting"
        case .completed: return "Completed"
        case .dead: return "Dead"
        }
    }

    /// 动画类型
    public var animation: StatusAnimation {
        switch self {
        case .thinking: return .pulse
        case .tooling: return .pulse
        case .active: return .pulse
        case .compacting: return .pulse
        case .waitingForUser: return .bounce
        case .permissionRequired: return .bounce
        default: return .none
        }
    }

    /// 是否需要呼吸动效（兼容旧代码）
    public var needsBreathing: Bool {
        animation != .none
    }

    /// 是否需要用户介入
    public var needsUserAction: Bool {
        switch self {
        case .waitingForUser, .permissionRequired:
            return true
        default:
            return false
        }
    }

    /// 从 csm 的 detailed_status 字符串解析
    public static func from(csmString: String) -> DetailedStatus {
        // csm 使用 camelCase: idle, thinking, tooling, active, waitingForUser, permissionRequired, compacting, completed, dead
        return DetailedStatus(rawValue: csmString) ?? .idle
    }

    /// 从 SessionStatus 转换
    public static func from(sessionStatus: SessionStatus) -> DetailedStatus {
        switch sessionStatus {
        case .idle: return .idle
        case .thinking: return .thinking
        case .tooling: return .tooling
        case .running: return .active
        case .waitingInput: return .waitingForUser
        case .permissionRequest: return .permissionRequired
        case .completed: return .completed
        case .failed: return .dead
        case .compacting: return .compacting
        }
    }

    /// 转换为 csm 格式字符串
    public var csmString: String {
        return rawValue
    }
}
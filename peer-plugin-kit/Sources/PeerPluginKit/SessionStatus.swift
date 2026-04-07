import SwiftUI

/// 统一的会话运行状态
/// 每个 AI 插件将自己的原生状态映射到此枚举
public enum SessionStatus: String, Codable, CaseIterable {
    case idle               // 空闲，无活动
    case active             // 通用"工作中"（插件无法区分 thinking/tooling 时使用）
    case thinking           // 正在思考（等待 AI 响应）
    case tooling            // 正在使用工具
    case waitingForUser     // 等待用户输入 (AskUserQuestion)
    case permissionRequired // 需要权限确认
    case compacting         // 正在压缩上下文
    case completed          // 任务完成
    case failed             // 任务失败
    case dead               // 进程消失（异常退出）

    /// 状态对应的 SF Symbol 图标名称
    public var icon: String {
        switch self {
        case .idle:
            return "circle"
        case .active:
            return "bolt.fill"
        case .thinking:
            return "brain.head.profile"
        case .tooling:
            return "wrench.and.screwdriver"
        case .waitingForUser, .permissionRequired:
            return "hand.raised.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .dead:
            return "exclamationmark.triangle.fill"
        case .compacting:
            return "rectangle.compress.vertical"
        }
    }

    /// 状态对应的颜色
    public var color: Color {
        switch self {
        case .idle:
            return .gray
        case .active:
            return .blue
        case .thinking:
            return .purple
        case .tooling:
            return .cyan
        case .waitingForUser, .permissionRequired:
            return .orange
        case .completed:
            return .green
        case .failed, .dead:
            return .red
        case .compacting:
            return .purple
        }
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

    /// 是否正在工作中
    public var isWorking: Bool {
        switch self {
        case .active, .thinking, .tooling, .compacting:
            return true
        default:
            return false
        }
    }

    /// 状态的简短描述
    public var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .active:
            return "Active"
        case .thinking:
            return "Thinking..."
        case .tooling:
            return "Tooling..."
        case .waitingForUser:
            return "Waiting for input"
        case .permissionRequired:
            return "Permission required"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .dead:
            return "Dead"
        case .compacting:
            return "Compacting..."
        }
    }
}

// MARK: - 向后兼容（旧 case 名称）

public extension SessionStatus {
    /// 兼容旧代码中的 .running
    static var running: SessionStatus { .active }
    /// 兼容旧代码中的 .waitingInput
    static var waitingInput: SessionStatus { .waitingForUser }
    /// 兼容旧代码中的 .permissionRequest
    static var permissionRequest: SessionStatus { .permissionRequired }
}

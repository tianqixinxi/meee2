import SwiftUI

/// Claude Session 的运行状态
public enum SessionStatus: String, Codable {
    case idle           // 空闲，无活动
    case thinking      // 正在思考（等待AI响应）
    case tooling       // 正在使用工具
    case running       // 正在执行任务
    case waitingInput   // 等待用户输入 (AskUserQuestion)
    case permissionRequest  // 需要权限确认
    case completed      // 任务完成
    case failed         // 任务失败
    case compacting     // 正在压缩上下文

    /// 状态对应的 SF Symbol 图标名称（与 DetailedStatus 保持一致）
    public var icon: String {
        DetailedStatus.from(sessionStatus: self).icon
    }

    /// 状态对应的颜色（与 DetailedStatus 保持一致）
    public var color: Color {
        DetailedStatus.from(sessionStatus: self).color
    }

    /// 动画类型（与 DetailedStatus 保持一致）
    public var animation: StatusAnimation {
        DetailedStatus.from(sessionStatus: self).animation
    }

    /// 是否需要呼吸动效（与 DetailedStatus 保持一致）
    public var needsBreathing: Bool {
        DetailedStatus.from(sessionStatus: self).needsBreathing
    }

    /// 是否需要用户介入
    public var needsUserAction: Bool {
        switch self {
        case .waitingInput, .permissionRequest:
            return true
        default:
            return false
        }
    }

    /// 状态的简短描述（用于折叠状态显示）
    public var shortDescription: String {
        switch self {
        case .idle:
            return "Idle"
        case .thinking:
            return "..."
        case .tooling:
            return "Tool"
        case .running:
            return "Run"
        case .waitingInput:
            return "Ask"
        case .permissionRequest:
            return "Perm"
        case .completed:
            return "Done"
        case .failed:
            return "Err"
        case .compacting:
            return "Ctx"
        }
    }

    /// 状态的详细描述
    public var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .thinking:
            return "Thinking..."
        case .tooling:
            return "Tooling..."
        case .running:
            return "Running"
        case .waitingInput:
            return "Waiting for input"
        case .permissionRequest:
            return "Permission required"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .compacting:
            return "Compacting..."
        }
    }
}
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

    /// 状态对应的 SF Symbol 图标名称
    public var icon: String {
        switch self {
        case .idle:
            return "circle"
        case .thinking:
            return "brain.head.profile"
        case .tooling:
            return "wrench.and.screwdriver"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .waitingInput, .permissionRequest:
            return "hand.raised.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .compacting:
            return "rectangle.compress.vertical"
        }
    }

    /// 状态对应的颜色
    public var color: Color {
        switch self {
        case .idle:
            return .gray
        case .thinking:
            return .purple
        case .tooling:
            return .cyan
        case .running:
            return .blue
        case .waitingInput, .permissionRequest:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .compacting:
            return .purple
        }
    }

    /// 是否需要用户介入
    public var needsUserAction: Bool {
        switch self {
        case .thinking, .tooling:
            return false
        case .waitingInput, .permissionRequest:
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
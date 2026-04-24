import Foundation
import SwiftUI

/// 动画类型枚举
public enum StatusAnimation {
    case none           // 无动画
    case pulse          // 脉冲呼吸
    case rotate         // 旋转
    case bounce         // 弹跳
}

/// Session 统一状态枚举 —— UI / 磁盘 / 解析器共用
public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case thinking
    case tooling
    case active
    case waitingForUser
    case permissionRequired
    case compacting
    case completed
    case dead

    /// SF Symbol 图标（GUI 用）。waitingForUser 复用 idle 图标，因为语义就是 idle。
    public var icon: String {
        switch self {
        case .idle, .waitingForUser: return "ellipsis.circle"
        case .thinking: return "brain.head.profile"
        case .tooling: return "wrench.and.screwdriver.fill"
        case .active: return "play.circle.fill"
        case .permissionRequired: return "lock.shield.fill"
        case .compacting: return "rectangle.compress.vertical"
        case .completed: return "checkmark.circle.fill"
        case .dead: return "xmark.circle.fill"
        }
    }

    /// 终端图标（CLI/TUI 用）
    public var terminalIcon: String {
        switch self {
        case .idle, .waitingForUser: return "○"
        case .thinking: return "🧠"
        case .tooling: return "🔧"
        case .active: return "▶"
        case .permissionRequired: return "🔒"
        case .compacting: return "📦"
        case .completed: return "✅"
        case .dead: return "❌"
        }
    }

    public var sfSymbolName: String { icon }

    /// 颜色
    /// 注意：`.waitingForUser` 语义是"Claude 回完一轮、等你回话"——属于 idle 区段，
    /// 不是需要你点确认那种 urgent。只有 `.permissionRequired` 才是真 block。
    public var color: Color {
        switch self {
        case .permissionRequired:
            return .orange
        case .thinking, .tooling, .active, .compacting:
            return .blue
        case .idle, .completed, .waitingForUser:
            return .gray
        case .dead:
            return .red
        }
    }

    public var showsRightIcon: Bool {
        self == .permissionRequired
    }

    public var rightIcon: String? {
        self == .permissionRequired ? "hand.raised.fill" : nil
    }

    public var displayName: String {
        switch self {
        case .idle, .waitingForUser: return "Idle"
        case .thinking: return "Thinking"
        case .tooling: return "Tooling"
        case .active: return "Active"
        case .permissionRequired: return "Permission"
        case .compacting: return "Compacting"
        case .completed: return "Completed"
        case .dead: return "Dead"
        }
    }

    public var shortDescription: String {
        switch self {
        case .idle, .waitingForUser: return "Idle"
        case .thinking: return "..."
        case .tooling: return "Tool"
        case .active: return "Run"
        case .permissionRequired: return "Perm"
        case .compacting: return "Ctx"
        case .completed: return "Done"
        case .dead: return "Dead"
        }
    }

    public var description: String {
        switch self {
        case .idle, .waitingForUser: return "Idle"
        case .thinking: return "Thinking..."
        case .tooling: return "Tooling..."
        case .active: return "Running"
        case .permissionRequired: return "Permission required"
        case .compacting: return "Compacting..."
        case .completed: return "Completed"
        case .dead: return "Dead"
        }
    }

    public var animation: StatusAnimation {
        switch self {
        case .thinking, .tooling, .active, .compacting: return .pulse
        case .permissionRequired: return .bounce
        default: return .none
        }
    }

    public var needsBreathing: Bool {
        animation != .none
    }

    /// 是否真的需要用户点击处理。只有 permissionRequired（权限弹窗阻塞运行）
    /// 算 urgent；waitingForUser 语义是 idle。
    public var needsUserAction: Bool {
        self == .permissionRequired
    }

    /// 从任意字符串反序列化（处理旧 case 名）
    public static func from(rawString: String) -> SessionStatus {
        if let v = SessionStatus(rawValue: rawString) { return v }
        return legacyMap[rawString.lowercased()] ?? .idle
    }

    /// 旧字符串 → 新 case 的迁移表
    private static let legacyMap: [String: SessionStatus] = [
        // 旧 SessionStatus 名称
        "running": .active,
        "waitinginput": .waitingForUser,
        "waiting_input": .waitingForUser,
        "permissionrequest": .permissionRequired,
        "permission_request": .permissionRequired,
        "failed": .dead,
        // 旧 LiveStatus 名称
        "waiting": .permissionRequired,
        "unknown": .idle,
        // snake_case 变体
        "waiting_for_user": .waitingForUser,
        "permission_required": .permissionRequired
    ]
}

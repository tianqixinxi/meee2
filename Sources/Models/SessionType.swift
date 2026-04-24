import SwiftUI

/// Session 类型 - 用于 Claude CLI sessions
public enum SessionType: String, Codable, CaseIterable {
    case claude
    case cursor
    case copilot
    case aime
    case other

    /// 类型对应的图标
    public var icon: String {
        switch self {
        case .claude:
            return "brain.head.profile"
        case .cursor:
            return "cursorarrow"
        case .copilot:
            return "brain"
        case .aime:
            return "pawprint.fill"
        case .other:
            return "questionmark.circle"
        }
    }

    /// 类型显示名称
    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .cursor:
            return "Cursor"
        case .copilot:
            return "Copilot"
        case .aime:
            return "Aime"
        case .other:
            return "Other"
        }
    }

    /// 类型主题色
    var themeColor: Color {
        switch self {
        case .claude:
            return .orange
        case .cursor:
            return .blue
        case .copilot:
            return .purple
        case .aime:
            return .green
        case .other:
            return .gray
        }
    }
}

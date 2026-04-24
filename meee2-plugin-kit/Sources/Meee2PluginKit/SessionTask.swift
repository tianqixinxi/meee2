import Foundation

/// 会话任务 - 用于追踪 TaskCreate/TaskUpdate 创建的任务
/// 移植自 csm 的 Task 数据类
public struct SessionTask: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public var status: TaskStatus

    public init(id: String, name: String, status: TaskStatus = .pending) {
        self.id = id
        self.name = name
        self.status = status
    }

    /// 任务状态
    public enum TaskStatus: String, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done
        case completed

        public var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .inProgress: return "In Progress"
            case .done: return "Done"
            case .completed: return "Completed"
            }
        }

        /// 从 csm 格式解析
        public static func from(csmString: String) -> TaskStatus {
            return TaskStatus(rawValue: csmString) ?? .pending
        }
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: SessionTask, rhs: SessionTask) -> Bool {
        lhs.id == rhs.id
    }
}

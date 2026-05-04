import Foundation
import Meee2CommKit

/// 主仓侧的 IdentityResolver 实现:走 SessionStore.shared.listAll(),
/// 用 cwd 精确匹配 session 的 project 字段。AppDelegate 启动时把
/// 它注入到 `A2AIdentity.resolver`,让 comm-kit 不必直接依赖 SessionStore。
public final class SessionStoreIdentityResolver: IdentityResolver {
    public init() {}

    public func sessionsForCwd(_ cwd: String) -> [String] {
        SessionStore.shared.listAll()
            .filter { $0.project == cwd }
            .map { $0.sessionId }
    }
}

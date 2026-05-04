import Foundation

/// 把"通过 cwd 反查 sessionId"的能力从 comm-kit 解耦出去。
/// 主仓在启动时注入一个走 `SessionStore` 的实现;comm-kit 自身不依赖
/// SessionStore。在 unit test 里可注入 stub,或者干脆留 nil
/// (此时 `A2AIdentity.currentSessionId()` 在 cwd 路径上返回 nil)。
public protocol IdentityResolver: AnyObject, Sendable {
    /// 返回 `project == cwd` 的所有 session id;通常 0 或 1 个。
    func sessionsForCwd(_ cwd: String) -> [String]
}

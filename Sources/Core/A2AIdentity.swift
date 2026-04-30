import Foundation

/// A2AIdentity - 当前会话身份解析工具
///
/// 让一个运行在 Claude CLI Bash tool 里的 agent 不必手动传 `--from` / `--channel`
/// 就能使用 `meee2 msg send`。解析链：
///   1. `$CLAUDE_SESSION_ID` 环境变量（Claude CLI 在每次工具调用时注入）
///   2. `$CODEX_THREAD_ID` 环境变量（Codex Desktop / CLI 注入）
///   3. 进程 cwd 精确匹配 SessionStore 中某个会话的 `project`
///
/// 本文件属于 service code：不直接 `print`，异常走日志。
public struct A2AIdentity {
    private static let claudePluginPrefix = "com.meee2.plugin.claude-"
    private static let codexPluginPrefix = "com.meee2.plugin.codex-"

    /// 当前会话的完整 UUID（若可解析）
    ///
    /// 顺序：
    ///   1. `$CLAUDE_SESSION_ID` 环境变量
    ///   2. `$CODEX_THREAD_ID` 环境变量
    ///   3. `FileManager.default.currentDirectoryPath` 与某个 session 的 `project`
    ///      做精确字符串相等比较；恰好命中一个 → 返回；零或多个 → nil
    public static func currentSessionId() -> String? {
        if let sid = currentSessionIdFromEnvironment() {
            return sid
        }
        let cwd = FileManager.default.currentDirectoryPath
        let matches = SessionStore.shared.listAll().filter { $0.project == cwd }
        if matches.count == 1 {
            return matches[0].sessionId
        }
        if matches.count > 1 {
            MDebug("[A2AIdentity] cwd '\(cwd)' matched \(matches.count) sessions - ambiguous")
        }
        return nil
    }

    /// 当前会话可能使用的 session id。Claude 主要用原始 sid；Codex 在
    /// Board/Plugin 层使用 `com.meee2.plugin.codex-<threadId>`，但环境变量
    /// 暴露的是裸 threadId，所以这里同时返回 canonical + raw aliases。
    public static func currentSessionIdCandidates() -> [String] {
        if let sid = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"],
           !sid.isEmpty {
            return unique([sid, "\(claudePluginPrefix)\(sid)"])
        }
        if let tid = codexThreadIdFromEnvironment() {
            return unique(["\(codexPluginPrefix)\(tid)", tid])
        }
        if let sid = currentSessionId() {
            return [sid]
        }
        return []
    }

    /// 当前会话参与的所有 (channel, alias) 组合，按频道名升序
    public static func currentMemberships() -> [(channel: String, alias: String)] {
        let sessionIds = currentSessionIdCandidates()
        guard !sessionIds.isEmpty else { return [] }
        var out: [(channel: String, alias: String)] = []
        var seen = Set<String>()
        for ch in ChannelRegistry.shared.list() {
            for sid in sessionIds {
                if let m = ch.memberBySessionId(sid) {
                    let key = "\(ch.name)\u{0}\(m.alias)"
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    out.append((channel: ch.name, alias: m.alias))
                }
            }
        }
        return out.sorted { $0.channel < $1.channel }
    }

    /// 根据当前会话在指定频道中的成员身份，解析 sender alias
    ///
    /// 若当前会话无法识别，或不是该频道成员，则返回 nil
    public static func aliasInChannel(_ channelName: String) -> String? {
        let sessionIds = currentSessionIdCandidates()
        guard !sessionIds.isEmpty else { return nil }
        guard let ch = ChannelRegistry.shared.get(channelName) else { return nil }
        for sid in sessionIds {
            if let alias = ch.memberBySessionId(sid)?.alias {
                return alias
            }
        }
        return nil
    }

    /// 当前会话仅参与一个频道时返回其名称，否则 nil
    public static func soleChannel() -> String? {
        let ms = currentMemberships()
        return ms.count == 1 ? ms[0].channel : nil
    }

    /// 内省：描述当前 session 解析来源（供 `meee2 whoami` 使用）
    public enum Source {
        case envVar
        case codexEnv
        case cwdMatch
        case unresolved
    }

    /// 返回 (sessionId, source)，用于诊断；不副作用调用任何 CLI
    public static func resolve() -> (sessionId: String?, source: Source) {
        if let sid = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"],
           !sid.isEmpty {
            return (sid, .envVar)
        }
        if let tid = codexThreadIdFromEnvironment() {
            return ("\(codexPluginPrefix)\(tid)", .codexEnv)
        }
        let cwd = FileManager.default.currentDirectoryPath
        let matches = SessionStore.shared.listAll().filter { $0.project == cwd }
        if matches.count == 1 {
            return (matches[0].sessionId, .cwdMatch)
        }
        return (nil, .unresolved)
    }

    private static func currentSessionIdFromEnvironment() -> String? {
        if let sid = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"],
           !sid.isEmpty {
            return sid
        }
        if let tid = codexThreadIdFromEnvironment() {
            return "\(codexPluginPrefix)\(tid)"
        }
        return nil
    }

    private static func codexThreadIdFromEnvironment() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let tid = env["CODEX_THREAD_ID"], !tid.isEmpty {
            return tid
        }
        if let tid = env["CODEX_SESSION_ID"], !tid.isEmpty {
            return tid
        }
        return nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where !value.isEmpty && !seen.contains(value) {
            seen.insert(value)
            out.append(value)
        }
        return out
    }
}

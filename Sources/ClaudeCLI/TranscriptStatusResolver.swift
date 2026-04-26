import Foundation
import Meee2PluginKit

// MARK: - Terminal reachability cache

/// Per-terminal reachability cache with a short TTL. Avoids spawning an
/// AppleScript subprocess on every 1s board poll.
///
/// We cache both alive=true and alive=false. Transient AppleScript failures
/// are treated as alive (see `terminalAlive`).
private struct TerminalCacheEntry {
    let checkedAt: Date
    let alive: Bool
}

private let _terminalCacheLock = NSLock()
private var _terminalCache: [String: TerminalCacheEntry] = [:]
private let _terminalCacheTTL: TimeInterval = 10.0

// Hard budget: if osascript ever takes longer than this, we give up and
// treat the terminal as reachable. Better to miss a dead-session mark than
// to stall the /api/state response.
private let _terminalProbeTimeout: TimeInterval = 0.5

/// Check if a Ghostty terminal id is still reachable. Cached for 10s per id.
/// On timeout or AppleScript failure returns `true` (don't mark dead on
/// transient failure).
private func terminalAlive(_ terminalId: String) -> Bool {
    let now = Date()

    _terminalCacheLock.lock()
    if let cached = _terminalCache[terminalId],
       now.timeIntervalSince(cached.checkedAt) < _terminalCacheTTL {
        _terminalCacheLock.unlock()
        return cached.alive
    }
    _terminalCacheLock.unlock()

    let alive = probeGhosttyTerminal(terminalId)

    _terminalCacheLock.lock()
    _terminalCache[terminalId] = TerminalCacheEntry(checkedAt: now, alive: alive)
    _terminalCacheLock.unlock()

    return alive
}

/// Synchronously probe Ghostty for a terminal id. Returns false only if the
/// AppleScript explicitly reports the terminal doesn't exist. Any other
/// condition (timeout, script failure, Ghostty not running) returns true so
/// we don't mark the session dead on a transient glitch.
private func probeGhosttyTerminal(_ terminalId: String) -> Bool {
    let escaped = terminalId.replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "Ghostty"
        try
            set t to terminal id "\(escaped)"
            return "ok"
        on error
            return ""
        end try
    end tell
    """

    let process = Process()
    process.launchPath = "/usr/bin/osascript"
    process.arguments = ["-e", script]

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        MWarn("[TranscriptStatusResolver] failed to launch osascript: \(error)")
        return true
    }

    // Poll for completion with a hard deadline.
    let deadline = Date().addingTimeInterval(_terminalProbeTimeout)
    while process.isRunning {
        if Date() >= deadline {
            process.terminate()
            MWarn("[TranscriptStatusResolver] osascript probe timed out for terminal=\(terminalId.prefix(8)); assuming alive")
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }

    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return output == "ok"
}

// MARK: - Resolved-status cache

/// Short-TTL cache for resolved SessionStatus keyed by sessionId. Lets the
/// Island / TUI re-read at UI frame rates without thrashing the transcript
/// file I/O. Invalidated on every hook event (ClaudePlugin calls invalidate).
private struct ResolvedCacheEntry {
    let at: Date
    let status: SessionStatus
}

private let _resolvedCacheLock = NSLock()
private var _resolvedCache: [String: ResolvedCacheEntry] = [:]
private let _resolvedCacheTTL: TimeInterval = 1.0

// MARK: - Resolver

public enum TranscriptStatusResolver {
    /// Resolve the "true" live status by combining process liveness and the
    /// tail of the transcript JSONL. Falls back to `hookStatus` when
    /// transcript is absent. Returns the unified SessionStatus.
    public static func resolve(
        sessionId: String? = nil,
        transcriptPath: String?,
        hookStatus: SessionStatus,
        pid: Int?,
        ghosttyTerminalId: String?
    ) -> SessionStatus {
        // Short-TTL cache: if called multiple times within 1s for the same
        // session, return the cached value. Invalidated by ClaudePlugin on
        // each hook event.
        if let sid = sessionId {
            _resolvedCacheLock.lock()
            if let cached = _resolvedCache[sid],
               Date().timeIntervalSince(cached.at) < _resolvedCacheTTL {
                _resolvedCacheLock.unlock()
                NSLog("[StateTrace][resolver] sid=\(sid.prefix(8)) hook=\(hookStatus.rawValue) → \(cached.status.rawValue) (CACHED)")
                return cached.status
            }
            _resolvedCacheLock.unlock()
        }

        let out = resolveUncached(
            transcriptPath: transcriptPath,
            hookStatus: hookStatus,
            pid: pid,
            ghosttyTerminalId: ghosttyTerminalId
        )

        if let sid = sessionId {
            _resolvedCacheLock.lock()
            _resolvedCache[sid] = ResolvedCacheEntry(at: Date(), status: out)
            _resolvedCacheLock.unlock()
        }

        return out
    }

    /// Invalidate the resolved-status cache for a session (call on hook event).
    public static func invalidate(sessionId: String) {
        _resolvedCacheLock.lock()
        _resolvedCache.removeValue(forKey: sessionId)
        _resolvedCacheLock.unlock()
        NSLog("[StateTrace][resolver] sid=\(sessionId.prefix(8)) cache INVALIDATED")
    }

    /// 对 SessionData 做一次解析 —— Island / TUI / Board 三端的唯一入口。
    /// `data.status` 是 hook 事件直接写入的权威状态；resolver 基于 transcript
    /// 尾部 + 进程存活 + 终端可达性做二次校准，输出展示用的 status。
    public static func resolve(for data: SessionData) -> SessionStatus {
        return resolve(
            sessionId: data.sessionId,
            transcriptPath: data.transcriptPath,
            hookStatus: data.status,
            pid: data.pid,
            ghosttyTerminalId: data.ghosttyTerminalId
        )
    }

    private static func resolveUncached(
        transcriptPath: String?,
        hookStatus: SessionStatus,
        pid: Int?,
        ghosttyTerminalId: String?
    ) -> SessionStatus {
        let sidTag = (transcriptPath as NSString?)?.lastPathComponent.prefix(8) ?? "?"

        // Step 0: process liveness
        if let pid = pid, !SessionStore.processAlive(pid) {
            NSLog("[StateTrace][resolver] sid=\(sidTag) hook=\(hookStatus.rawValue) → DEAD (pid \(pid) gone)")
            return .dead
        }

        // Step 0.5: Ghostty reachability (cached)
        if let gtid = ghosttyTerminalId, !gtid.isEmpty {
            if !terminalAlive(gtid) {
                NSLog("[StateTrace][resolver] sid=\(sidTag) hook=\(hookStatus.rawValue) → DEAD (ghostty \(gtid.prefix(8)) gone)")
                return .dead
            }
        }

        // Step 1: read tail & find last user/assistant/system entry.
        guard let tail = readTail(path: transcriptPath, bytes: 4096) else {
            NSLog("[StateTrace][resolver] sid=\(sidTag) hook=\(hookStatus.rawValue) → \(hookStatus.rawValue) (no transcript)")
            return hookStatus
        }

        guard let last = findLastRelevantEntry(tail: tail) else {
            NSLog("[StateTrace][resolver] sid=\(sidTag) hook=\(hookStatus.rawValue) → \(hookStatus.rawValue) (no relevant entry)")
            return hookStatus
        }

        let tsStr = last.timestamp.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        let age: String = last.timestamp.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "?"

        // Step 2: apply rule matrix. Extracted to decideFromTail so tests
        // can hit the decision logic without transcript files or osascript.
        let (out, reason) = decideFromTail(last: last, hookStatus: hookStatus, now: Date())

        NSLog("[StateTrace][resolver] sid=\(sidTag) hook=\(hookStatus.rawValue) last={type=\(last.type) age=\(age) ts=\(tsStr)} → \(out.rawValue) (\(reason))")
        return out
    }

    /// 纯函数：根据 tail entry + hookStatus + 当前时间，算出展示用 status。
    /// 不做文件 I/O、不调 AppleScript、不查进程——所有外部依赖都已经在
    /// `resolveUncached` 里解析好之后才调这里。方便单元测试遍历规则矩阵。
    ///
    /// 规则优先级（详见 docs/ARCHITECTURE.md §6）：
    ///   case user:
    ///     1. isInterrupt          → .idle    (user-interrupt)
    ///     2. age > 180s + hook ∉ working → .idle (user-too-old)
    ///                               working hook trumps age — agent 还在跑就别误降
    ///     3. isSpecific(hook)     → hookStatus
    ///     4. fallback             → .active
    ///   case assistant:
    ///     1. fresh (<30s) + hook ∈ {idle,completed,waitingForUser} → .active (mid-turn)
    ///     2. fallback             → hookStatus
    ///   case system:
    ///     1. age > 90s + working hook → .idle (system-tail-stale)
    ///     2. hook == .active       → .idle (force-idle)
    ///     3. fallback              → hookStatus
    static func decideFromTail(
        last: LastEntry,
        hookStatus: SessionStatus,
        now: Date
    ) -> (status: SessionStatus, reason: String) {
        switch last.type {
        case "user":
            if last.isInterrupt {
                return (.idle, "user-interrupt")
            }
            if let ts = last.timestamp, now.timeIntervalSince(ts) > _abandonedUserEntryThreshold {
                // 关键守卫：hook 明确报"还在干活"（thinking / tooling / active /
                // compacting），就 trust hook，**不**因为 transcript 尾部 user 久了
                // 就降级。场景：用户打了一句话之后 Claude 长时间走工具链 / extended
                // thinking，transcript 尾巴一直是那条原 user prompt（4-30 分钟），
                // 但 PreToolUse 钩子在持续喷——这是真活，不能误判 abandoned。
                // "user-too-old"原本是兜"用户打字后走人没等回复"，那种情况下 hook
                // 早归 idle / waitingForUser 了，不会满足下面这条 guard。
                let workingHooks: Set<SessionStatus> = [.thinking, .tooling, .active, .compacting]
                if workingHooks.contains(hookStatus) {
                    return (hookStatus, "user-too-old-but-hook-working(\(hookStatus.rawValue))")
                }
                return (.idle, "user-too-old(>\(Int(_abandonedUserEntryThreshold))s)")
            }
            // (历史规则：hook=thinking + age>45s → idle，理由 ESC-pre-first-token)
            // 已删除——当 user 实际等 60-180s 才出 first token 时（Opus extended
            // thinking / 长 context），UI 会错翻 idle 看起来"在等用户输入"。
            // ESC-pre-first-token 用 abandoned-session 的 180s 阈值兜底。
            if isSpecific(hookStatus) {
                return (hookStatus, "user-recent+hook-specific(\(hookStatus.rawValue))")
            }
            return (.active, "user-recent")

        case "assistant":
            // 只有 fresh assistant tail（< _midTurnFreshnessWindow）才算"刚 stream
            // 完还没等到 Stop hook"的 mid-turn。Claude 流式输出时 transcript 每秒
            // 追写，turn 结束后 1-2s 内 Stop hook 必到——所以这个窗口很小。
            //
            // 旧 bug：没 age 守卫，1.3 hours 前的 assistant tail + hook=waitingForUser
            // 也被强升 active，UI 上"已经停留在等用户介入"的会话错显示成"live"
            // （比如 Claude 弹了 permission 后用户离开几小时没点）。
            let assistantIsFresh: Bool = {
                guard let ts = last.timestamp else { return true } // 无 ts 保守视为 fresh
                return now.timeIntervalSince(ts) < _midTurnFreshnessWindow
            }()
            if assistantIsFresh,
               hookStatus == .idle || hookStatus == .completed || hookStatus == .waitingForUser {
                return (.active, "assistant+hook=\(hookStatus.rawValue) → mid-turn")
            }
            // ESC-mid-stream 兜底：Claude 开始 stream 了（assistant entry 已写
            // 入）但没用工具就被用户 ESC，后续 Stop / 新 assistant 写入都没
            // 来。正常 streaming 时 transcript 每秒都有写入，tail 停在同一条
            // assistant 超过阈值 = 这一轮已断。降级 idle。
            if let ts = last.timestamp,
               now.timeIntervalSince(ts) > _staleAssistantTailThreshold,
               hookStatus == .thinking || hookStatus == .tooling || hookStatus == .active || hookStatus == .compacting {
                return (.idle, "assistant-tail-stale(>\(Int(_staleAssistantTailThreshold))s+hook=\(hookStatus.rawValue))")
            }
            return (hookStatus, "assistant+hook=\(hookStatus.rawValue)")

        case "system":
            if let ts = last.timestamp,
               now.timeIntervalSince(ts) > _staleSystemTailThreshold,
               hookStatus == .thinking || hookStatus == .tooling || hookStatus == .active || hookStatus == .compacting {
                return (.idle, "system-tail-stale(>\(Int(_staleSystemTailThreshold))s+hook=\(hookStatus.rawValue))")
            }
            if hookStatus == .active {
                return (.idle, "system+hook=active → force-idle")
            }
            return (hookStatus, "system+hook=\(hookStatus.rawValue)")

        default:
            return (hookStatus, "unknown-type(\(last.type))")
        }
    }

    /// States that carry more specific info than what the transcript tail can
    /// tell us. We keep these rather than overriding to `.active`.
    /// `.waitingForUser` 不在这里——它的语义本来就是 idle。
    private static func isSpecific(_ s: SessionStatus) -> Bool {
        switch s {
        case .thinking, .tooling, .permissionRequired, .compacting:
            return true
        default:
            return false
        }
    }

    /// Returns:
    ///   nil        → no change; caller should keep existing currentTool.
    ///   .some(nil) → clear the current tool (set to nil).
    ///   .some(s)   → override current tool to `s` (e.g. "thinking").
    public static func resolveCurrentTool(
        transcriptPath: String?,
        currentTool: String?
    ) -> String?? {
        guard let tail = readTail(path: transcriptPath, bytes: 4096) else {
            return nil
        }
        guard let last = findLastRelevantEntry(tail: tail) else {
            return nil
        }

        switch last.type {
        case "user":
            if last.isInterrupt {
                return .some(nil)  // clear
            }
            // 同 abandoned-session 规则：太旧就当 idle，清 tool
            if let ts = last.timestamp,
               Date().timeIntervalSince(ts) > _abandonedUserEntryThreshold {
                return .some(nil)
            }
            return .some("thinking")
        case "system":
            // If stop hook ran and we're forcing idle, clear the tool too.
            return .some(nil)
        default:
            return nil
        }
    }
}

// MARK: - Transcript tail parsing

// The subset of fields we need from the tail of the transcript.
// 提到模块级可见是为了单元测试能构造 fixture 直接喂给 decideFromTail。
// 生产代码仍然只由 TranscriptStatusResolver 内部使用。
struct LastEntry {
    let type: String        // "user" | "assistant" | "system"
    let isInterrupt: Bool
    let timestamp: Date?    // entry's own timestamp (ISO8601) if parseable
}

/// 如果最后一条 user 消息比这个旧，就认为"会话被放弃"，降级为 idle。
/// csm 没做这步，但它有 abandoned-session 误报的同样问题；对我们场景这是必要的
/// 防误报。Claude 真正处理一条用户消息极少超过这个阈值。
private let _abandonedUserEntryThreshold: TimeInterval = 180.0  // 3 min

// 针对 hookStatus=tooling/thinking + tail 是 system 条目的"ESC-during-tool"
// 场景阈值。正常 Claude 在工作态下 transcript 每几秒就有新 user/assistant
// 写入；tail 停在 system 条目（stop_hook_summary 之类）说明那一轮已经写完
// 收尾，剩下的沉默大概率是用户 ESC 把 tool 打断，后续 PostToolUse/Stop 没
// 到位。90s 是个安全阈值 —— 单次正常工具调用绝大多数 < 30s 完成。
// 之前是 90s，但 90s 内发生的"system 尾巴静默 + hook 仍报 tooling"绝大多数
// 是长 Bash / Read 大文件 / extended thinking 这种合法工作，不是 crash。
// 90s 误降会让用户看着真在跑的 session 显示 idle。提到 600s（10 分钟）——
// 真挂的 session 一般 10 分钟也不会有人耐心等了。
// 长期方案：plumb SessionData.lastActivity（最近一次 hook 时间）进 resolver，
// 用 "lastActivity 也很久没更新" 而不是只看 transcript 尾巴年龄做判断。
private let _staleSystemTailThreshold: TimeInterval = 600.0

/// 针对 hookStatus=working + tail 是 assistant 条目的"ESC-mid-stream"场景。
/// Claude 在 stream 文字时 transcript 每秒都在追写；tail 停在同一条 assistant
/// 超过 60s + hook 还是工作态 = 用户 ESC 把 streaming 打断，后续 Stop 没来。
/// 60s 比 system 的 90s 紧，因为 assistant 活跃 streaming 的节奏远高于
/// tool 执行（后者可以合法跑几分钟）。
private let _staleAssistantTailThreshold: TimeInterval = 60.0

/// "Mid-turn"（hook 是 idle/waitingForUser/completed 但 tail 是 assistant）的
/// freshness 窗。assistant entry 距 now 在这个窗内才认为"还没等到 Stop hook"
/// 的真 mid-turn；超过这个窗 hookStatus 是真相，不再升级 active。
/// 30s 比 stream-stale 60s 紧——Claude 写完最后一个 token 到 Stop hook 触发
/// 的延迟极少超过几秒，30s 给足缓冲又不至于把"真已 idle 的会话"误标 live。
private let _midTurnFreshnessWindow: TimeInterval = 30.0

/// Read the last `bytes` bytes of a file as UTF-8 (replacement on invalid
/// bytes). Returns nil if the path is missing or unreadable.
private func readTail(path: String?, bytes: Int) -> String? {
    guard let path = path, FileManager.default.fileExists(atPath: path) else {
        return nil
    }
    let url = URL(fileURLWithPath: path)
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    do {
        let fileSize = try handle.seekToEnd()
        let tailSize = min(fileSize, UInt64(bytes))
        try handle.seek(toOffset: fileSize - tailSize)
        let data = handle.readDataToEndOfFile()
        return String(bytes: data, encoding: .utf8)
    } catch {
        return nil
    }
}

/// Walk the tail from bottom → top, return the first entry we consider
/// "relevant" (i.e. not a local !bash command / isMeta user entry).
func findLastRelevantEntry(tail: String) -> LastEntry? {
    // Drop the (potentially truncated) first line — it may be mid-JSON.
    let rawLines = tail.split(separator: "\n", omittingEmptySubsequences: true)
    // If there's more than one line and we're likely mid-line at the top,
    // skip the first one to avoid parsing a fragment.
    let lines: [Substring]
    if rawLines.count > 1 {
        lines = Array(rawLines.dropFirst())
    } else {
        lines = Array(rawLines)
    }

    for line in lines.reversed() {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        guard let type = json["type"] as? String,
              ["user", "assistant", "system"].contains(type) else {
            continue
        }

        let ts = parseEntryTimestamp(json)

        if type == "user" {
            // Skip isMeta user entries (local !bash commands) and entries
            // whose text markers reveal they're local-command echoes.
            if let meta = json["isMeta"] as? Bool, meta {
                continue
            }
            let text = extractUserText(json)
            if text.contains("<bash-input>") ||
               text.contains("<bash-stdout>") ||
               text.contains("<local-command-caveat>") {
                continue
            }

            let isInterrupt = text.hasPrefix("[Request interrupted by user")
            return LastEntry(type: type, isInterrupt: isInterrupt, timestamp: ts)
        }

        // assistant / system
        return LastEntry(type: type, isInterrupt: false, timestamp: ts)
    }

    return nil
}

private let _iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let _iso8601Plain: ISO8601DateFormatter = ISO8601DateFormatter()

private func parseEntryTimestamp(_ json: [String: Any]) -> Date? {
    guard let raw = json["timestamp"] as? String else { return nil }
    return _iso8601WithFractional.date(from: raw) ?? _iso8601Plain.date(from: raw)
}

/// Pull the textual content out of a user entry. Handles both string and
/// array-of-blocks payloads. Returns empty string if nothing textual found.
private func extractUserText(_ entry: [String: Any]) -> String {
    guard let msg = entry["message"] as? [String: Any] else {
        if let str = entry["message"] as? String { return str }
        return ""
    }
    let content = msg["content"]
    if let s = content as? String { return s }
    if let arr = content as? [[String: Any]] {
        var parts: [String] = []
        for block in arr {
            if let t = block["text"] as? String, !t.isEmpty {
                parts.append(t)
            }
        }
        return parts.joined(separator: " ")
    }
    return ""
}

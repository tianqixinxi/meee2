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

        // Step 2: apply csm-style rules. Keep hook-driven status when it
        // already carries more information than transcript-based heuristics
        // (thinking / tooling / waitingForUser / permissionRequired /
        // compacting). Only override in the specific cases below.
        let out: SessionStatus
        let reason: String
        switch last.type {
        case "user":
            if last.isInterrupt {
                out = .idle; reason = "user-interrupt"
            } else if let ts = last.timestamp,
                      Date().timeIntervalSince(ts) > _abandonedUserEntryThreshold {
                out = .idle; reason = "user-too-old(>\(Int(_abandonedUserEntryThreshold))s)"
            } else if hookStatus == .thinking,
                      let ts = last.timestamp,
                      Date().timeIntervalSince(ts) > _staleThinkingThreshold {
                // ESC-before-first-token 场景：用户发完 prompt 就按 ESC，
                // Claude 还没开始 stream → 不写 interrupt marker，也不会再
                // 触发新 hook，hookStatus 就卡在 thinking 了。
                // "尾巴是普通 user prompt + hook 说 thinking + 超过 45s 还没
                //  有任何 assistant entry" 这组合，在真 thinking 里极罕见
                // （opus 极端复杂提示也基本 < 30s 出第一个 token），更可能是
                // 用户 ESC 了。降级为 idle 以释放 LIVE 徽章。
                out = .idle
                reason = "user-stale-pre-assistant(>\(Int(_staleThinkingThreshold))s+hook=thinking)"
            } else {
                // Keep the more-specific hook status if any (thinking/tooling
                // etc). Fall back to .active when the hook is generic idle /
                // active / completed.
                if isSpecific(hookStatus) {
                    out = hookStatus; reason = "user-recent+hook-specific(\(hookStatus.rawValue))"
                } else {
                    out = .active; reason = "user-recent"
                }
            }
        case "assistant":
            // waitingForUser 在语义上等同 idle（Claude 回完一轮等你回），
            // transcript 尾巴是 assistant 时应当跟 idle 一样被识别为 mid-turn。
            if hookStatus == .idle || hookStatus == .completed || hookStatus == .waitingForUser {
                out = .active; reason = "assistant+hook=\(hookStatus.rawValue) → mid-turn"
            } else {
                out = hookStatus; reason = "assistant+hook=\(hookStatus.rawValue)"
            }
        case "system":
            if hookStatus == .active {
                out = .idle; reason = "system+hook=active → force-idle"
            } else {
                out = hookStatus; reason = "system+hook=\(hookStatus.rawValue)"
            }
        default:
            out = hookStatus; reason = "unknown-type(\(last.type))"
        }

        NSLog("[StateTrace][resolver] sid=\(sidTag) hook=\(hookStatus.rawValue) last={type=\(last.type) age=\(age) ts=\(tsStr)} → \(out.rawValue) (\(reason))")
        return out
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
            // 同 status resolver 的 stale-thinking 兜底：卡住时清 thinking 标签
            if let ts = last.timestamp,
               Date().timeIntervalSince(ts) > _staleThinkingThreshold {
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

/// The subset of fields we need from the tail of the transcript.
private struct LastEntry {
    let type: String        // "user" | "assistant" | "system"
    let isInterrupt: Bool
    let timestamp: Date?    // entry's own timestamp (ISO8601) if parseable
}

/// 如果最后一条 user 消息比这个旧，就认为"会话被放弃"，降级为 idle。
/// csm 没做这步，但它有 abandoned-session 误报的同样问题；对我们场景这是必要的
/// 防误报。Claude 真正处理一条用户消息极少超过这个阈值。
private let _abandonedUserEntryThreshold: TimeInterval = 180.0  // 3 min

/// 针对 hookStatus=thinking + tail 还是 user prompt 的"卡住"场景的阈值。
/// 正常 thinking 阶段出第一个 token 的延迟绝大多数在 10 秒内，极端长 prompt
/// 也很少超过 30 秒。超过这个阈值仍没有 assistant entry 出现，大概率是用户
/// 在 first-token 前按了 ESC（这种情况 Claude 不写 interrupt marker、也不
/// 触发新 hook）。
private let _staleThinkingThreshold: TimeInterval = 45.0

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
private func findLastRelevantEntry(tail: String) -> LastEntry? {
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

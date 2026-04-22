import Foundation

// MARK: - LiveStatus

/// The canonical "live" status surfaced to the board UI, derived from a
/// combination of hook events, process liveness, and the transcript tail.
/// Distinct from `SessionData.status` (hook-only) — this is the resolved
/// value, used only on the Board/web path.
public enum LiveStatus: String, Sendable {
    case active       // Claude is working (post-user-msg, mid-turn, tool in flight)
    case idle         // waiting for user input
    case waiting      // permission request or similar user-intervention
    case completed    // stop ran, no follow-up
    case dead         // process gone or terminal closed
    case unknown
}

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

// MARK: - Resolver

public enum TranscriptStatusResolver {
    /// Resolve the "true" live status by combining process liveness and the
    /// tail of the transcript JSONL. Falls back to `hookStatus` when
    /// transcript is absent.
    public static func resolve(
        transcriptPath: String?,
        hookStatus: String,
        pid: Int?,
        ghosttyTerminalId: String?
    ) -> LiveStatus {
        let sidTag = (transcriptPath as NSString?)?.lastPathComponent.prefix(8) ?? "?"

        // Step 0: process liveness
        if let pid = pid, !SessionStore.processAlive(pid) {
            NSLog("[Resolver] sid=\(sidTag) hookStatus=\(hookStatus) → DEAD (pid \(pid) gone)")
            return .dead
        }

        // Step 0.5: Ghostty reachability (cached)
        if let gtid = ghosttyTerminalId, !gtid.isEmpty {
            if !terminalAlive(gtid) {
                NSLog("[Resolver] sid=\(sidTag) hookStatus=\(hookStatus) → DEAD (ghostty \(gtid.prefix(8)) gone)")
                return .dead
            }
        }

        // Step 1: read tail & find last user/assistant/system entry.
        let fallback = mapHookStatus(hookStatus)
        guard let tail = readTail(path: transcriptPath, bytes: 4096) else {
            NSLog("[Resolver] sid=\(sidTag) hookStatus=\(hookStatus) → \(fallback) (no transcript)")
            return fallback
        }

        guard let last = findLastRelevantEntry(tail: tail) else {
            NSLog("[Resolver] sid=\(sidTag) hookStatus=\(hookStatus) → \(fallback) (no relevant entry)")
            return fallback
        }

        let tsStr = last.timestamp.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        let age: String = last.timestamp.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "?"

        // Step 2: apply csm-style rules
        let out: LiveStatus
        let reason: String
        switch last.type {
        case "user":
            if last.isInterrupt {
                out = .idle; reason = "user-interrupt"
            } else if let ts = last.timestamp,
                      Date().timeIntervalSince(ts) > _abandonedUserEntryThreshold {
                out = .idle; reason = "user-too-old(>\(Int(_abandonedUserEntryThreshold))s)"
            } else {
                out = .active; reason = "user-recent"
            }
        case "assistant":
            let h = hookStatus.lowercased()
            if h == "idle" || h == "completed" {
                out = .active; reason = "assistant+hook=idle/completed → mid-turn"
            } else if h == "active" || h == "running" {
                out = .active; reason = "assistant+hook=active/running"
            } else {
                out = fallback; reason = "assistant+fallback(\(hookStatus))"
            }
        case "system":
            let h = hookStatus.lowercased()
            if h == "active" || h == "running" {
                out = .idle; reason = "system+hook=active → force-idle"
            } else {
                out = fallback; reason = "system+fallback(\(hookStatus))"
            }
        default:
            out = fallback; reason = "unknown-type(\(last.type))"
        }

        NSLog("[Resolver] sid=\(sidTag) hookStatus=\(hookStatus) last={type=\(last.type) age=\(age) ts=\(tsStr)} → \(out) (\(reason))")
        return out
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

    // MARK: - Hook-status fallback mapping

    /// Map a raw hook-status string to a LiveStatus. Used when we can't read
    /// the transcript.
    public static func mapHookStatus(_ raw: String) -> LiveStatus {
        switch raw.lowercased() {
        case "running", "active", "thinking", "tooling", "compacting":
            return .active
        // `waitingForUser` / `waitingForInput` 这一类是 "Claude 回完一轮、等你输入"，
        // 语义就是 idle —— 不要当成"需要你点确认的 permission"的 waiting。
        // waiting 只留给真正 user-intervention-required 的 permission 状态。
        case "idle", "waitingforuser", "waiting_for_user":
            return .idle
        case "completed":
            return .completed
        case "permissionrequest", "permission_request",
             "permissionrequired", "permission_required",
             "waitinginput", "waiting_input", "waiting":
            return .waiting
        case "failed", "dead":
            return .dead
        default:
            return .unknown
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
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
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

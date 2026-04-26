import Foundation

/// Deterministic tty → Ghostty terminal id lookup.
///
/// Ghostty PR #11922 (merged 2026-04-20, in tip nightly) added a `tty` property
/// to its AppleScript `terminal` class. Given a tty path like `/dev/ttys003`,
/// we can ask Ghostty which terminal owns it — no focus heuristics, no race.
///
/// Old Ghostty (≤ 1.3.1 stable) doesn't expose `tty`; the AppleScript snippet
/// silently returns empty, callers fall back to the legacy "focused terminal"
/// path in `Bridge/claude-hook-bridge.sh`.
public enum GhosttyTerminalRegistry {
    /// One-shot AppleScript probe: list every Ghostty terminal as
    /// `<id>|<tty>` per line. Empty / nil if Ghostty isn't running OR doesn't
    /// expose `tty` (i.e., on stable < 1.4).
    public static func snapshot() -> [(id: String, tty: String)] {
        let source = """
        tell application "Ghostty"
            set acc to ""
            try
                repeat with t in terminals
                    try
                        set acc to acc & (id of t) & "|" & (tty of t as string) & linefeed
                    end try
                end repeat
            end try
            return acc
        end tell
        """

        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            MWarn("[GhosttyRegistry] osascript launch failed: \(error)")
            return []
        }

        // 2s budget — listing all terminals shouldn't take long but cap so we
        // don't hang meee2 startup if Ghostty hangs / is mid-restart.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                MWarn("[GhosttyRegistry] osascript snapshot timed out")
                return []
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        var result: [(String, String)] = []
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "|", maxSplits: 1)
            if parts.count == 2 {
                let id = String(parts[0])
                let tty = String(parts[1])
                if !id.isEmpty && !tty.isEmpty {
                    result.append((id, tty))
                }
            }
        }
        return result
    }

    /// Walk SessionStore: for every session that knows its tty, look up the
    /// real Ghostty terminal id and overwrite the stored value if it differs.
    /// Cures historical drift caused by the old "focused terminal" heuristic
    /// (two sids ending up on the same gtid because of focus race at start).
    ///
    /// No-op if Ghostty < tip (snapshot returns empty → no map → nothing to
    /// reconcile).
    @discardableResult
    public static func reconcileSessionStore() -> (fixed: Int, cleared: Int, skipped: Int) {
        let snap = snapshot()
        guard !snap.isEmpty else {
            MLog("[GhosttyRegistry] snapshot empty (Ghostty not running, or pre-tip without tty property) — skipping reconcile")
            return (0, 0, 0)
        }

        // Map tty path ("/dev/ttys003") → gtid
        var ttyToId: [String: String] = [:]
        for (id, tty) in snap {
            ttyToId[tty] = id
        }

        var fixed = 0
        var cleared = 0
        var skipped = 0
        let store = SessionStore.shared
        for session in store.listAll() {
            // 我们 SessionData 里的 tty 是 "ttys003"（无前缀），Ghostty 返回
            // "/dev/ttys003"。两边对齐到全路径再查。
            let bareTty = session.terminalInfo?.tty ?? ""
            guard !bareTty.isEmpty else {
                skipped += 1
                continue
            }
            let ttyPath = bareTty.hasPrefix("/dev/") ? bareTty : "/dev/\(bareTty)"
            let realGtid = ttyToId[ttyPath]
            let storedGtid = (session.ghosttyTerminalId ?? "")

            if let real = realGtid {
                if real != storedGtid {
                    store.update(session.sessionId) { $0.ghosttyTerminalId = real }
                    MLog("[GhosttyRegistry] reconcile sid=\(session.sessionId.prefix(8)) tty=\(bareTty): \(storedGtid.prefix(8)) → \(real.prefix(8))")
                    fixed += 1
                }
            } else if !storedGtid.isEmpty {
                // tty 不在当前 Ghostty 终端里——session 的物理终端已经被关掉，
                // 但 SessionStore 里 gtid 还指着已死的 terminal。清掉，避免
                // MessageRouter 推到不存在的 terminal。
                store.update(session.sessionId) { $0.ghosttyTerminalId = nil }
                MLog("[GhosttyRegistry] reconcile sid=\(session.sessionId.prefix(8)) tty=\(bareTty): cleared stale gtid \(storedGtid.prefix(8)) (terminal gone)")
                cleared += 1
            }
        }
        if fixed > 0 || cleared > 0 {
            MLog("[GhosttyRegistry] reconcile done: fixed=\(fixed) cleared=\(cleared) skipped=\(skipped)")
        }
        return (fixed, cleared, skipped)
    }
}

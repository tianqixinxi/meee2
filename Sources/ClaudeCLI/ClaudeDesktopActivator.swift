import AppKit
import Foundation

/// Shared "open this Claude.app session" helper. Both BoardAPI (web board
/// double-click) and ClaudePlugin (Island tap) route Desktop-backed sessions
/// here so the open behaviour is identical regardless of surface.
///
/// Desktop sessions live in Claude.app, not a shell — TerminalManager has
/// nothing to focus. The right gesture is the `claude://` URL scheme that
/// Claude.app registers; activating the app brings it to the front in case
/// `NSWorkspace.open` only spawns the process.
enum ClaudeDesktopActivator {

    /// Heuristic: is this Claude session backed by Claude.app rather than the
    /// CLI? Two complementary signals — desktop's `metadata.json` index is
    /// authoritative once it's been scanned (every 30s), and the transcript
    /// `entrypoint` block is written immediately on hook ingress so it covers
    /// the first-scan window.
    static func isDesktopBacked(sid: String, transcriptPath: String?) -> Bool {
        if ClaudeDesktopMetadataReader.shared.lookup(cliSessionId: sid) != nil {
            return true
        }
        if let path = transcriptPath {
            return ClaudeEntrypointReader.read(transcriptPath: path)
                == ClaudeEntrypointReader.knownDesktop
        }
        return false
    }

    /// Activate Claude.app and resume the given CLI session id.
    ///
    /// Claude.app's URL handler (`com.anthropic.claudefordesktop`) dispatches
    /// on `URL.host` against an enum whose `Resume = "resume"`:
    ///
    ///     switch (t.host) {
    ///       case _E.Resume: {
    ///         const s = t.searchParams.get("session");
    ///         if (s && UUIDRegex.test(s)) {
    ///           Ys.importCliSession(s).then(o =>
    ///             dispatchNavigate(Ys.getSessionRoute(o)))
    ///         }
    ///       }
    ///     }
    ///
    /// So the URL must be `claude://resume?session=<UUID>` (host = "resume").
    /// A `claude://claude.ai/resume?session=…` form falls into the
    /// `ClaudeAI` host case, hits no path-level sub-handler, and silently
    /// just activates the app without navigating — which is the symptom we
    /// hit before this fix.
    ///
    /// `importCliSession` is idempotent get-or-create: if the cliSessionId
    /// already maps to a desktop local session it returns the existing one;
    /// otherwise it imports the CLI session as a desktop session — which is
    /// the wrong outcome for a pure CLI session. So callers MUST verify the
    /// session is desktop-backed (via `isDesktopBacked`) before calling.
    ///
    /// We also raise the app via AppleScript: `NSWorkspace.open(url)` doesn't
    /// always steal focus when Claude.app wasn't already running.
    static func activate(sid: String?) {
        if let sid = sid,
           let url = URL(string: "claude://resume?session=\(sid)") {
            NSWorkspace.shared.open(url)
            MLog("[ClaudeDesktopActivator] claude://resume?session=\(sid.prefix(8))…")
        }
        let script = "tell application \"Claude\" to activate"
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

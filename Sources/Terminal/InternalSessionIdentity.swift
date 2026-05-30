import Foundation

public enum InternalSessionIdentity {
    public static func normalizedManagedWorkspacePath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizedPath(trimmed)
        guard isMeee2ManagedWorkspace(normalized) else { return nil }
        return normalized
    }

    public static func externalManagedWorkspaceMatchesInternal(
        cwd: String?,
        internalManagedWorkspaceCwds: Set<String>
    ) -> Bool {
        guard let normalized = normalizedManagedWorkspacePath(cwd) else { return false }
        return internalManagedWorkspaceCwds.contains(normalized)
    }

    public static func isMeee2ManagedWorkspace(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        let workspacesRoot = normalizedPath(
            (NSHomeDirectory() as NSString).appendingPathComponent(".meee2/workspaces")
        )
        return normalized == workspacesRoot || normalized.hasPrefix(workspacesRoot + "/")
    }

    private static func normalizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    // MARK: - Surface → CLI correlation

    /// Terminal `termProgram` values that identify a meee2-owned surface/PTY
    /// session (as opposed to the real `claude` CLI session running inside it).
    /// Kept in sync with `BoardDTOBuilder.isInternalTerminalProgram`.
    private static let surfaceTermPrograms: Set<String> = [
        "meee2-internal",
        "meee2-ghostty-surface"
    ]

    /// Is this `terminalInfo` the meee2 surface session (the PTY shell we launch
    /// `claude` *inside*), as opposed to the CLI session that `claude` reports
    /// under its own uuid?
    public static func isSurfaceTerminal(termProgram: String?, termBundleId: String?) -> Bool {
        if let program = termProgram?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           surfaceTermPrograms.contains(program) {
            return true
        }
        if let bundle = termBundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           bundle == "meee2-ghostty-surface" {
            return true
        }
        return false
    }

    private static func isSurface(_ session: SessionData) -> Bool {
        isSurfaceTerminal(
            termProgram: session.terminalInfo?.termProgram,
            termBundleId: session.terminalInfo?.termBundleId
        )
    }

    private static func sessionCwd(_ session: SessionData) -> String? {
        // The CLI session's `cwd` carries the full managed-workspace path; only
        // fall back to `project` (historically a basename) when `cwd` is missing
        // OR blank — a present-but-empty `cwd` must not shadow `project`.
        let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cwd, !cwd.isEmpty {
            return normalizedManagedWorkspacePath(cwd)
        }
        return normalizedManagedWorkspacePath(session.project)
    }

    /// Cheap "this transcript file actually has content" probe — file exists and
    /// is non-empty on disk. Used to rank a CLI candidate whose `transcriptPath`
    /// points at a real, non-empty `.jsonl` above one whose path is stale (file
    /// deleted / never written). Deliberately byte-level, not a parse, to stay
    /// cheap on the per-poll hot path.
    private static func transcriptFileHasContent(_ rawPath: String?) -> Bool {
        guard let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attrs else { return false }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }

    /// Given a managed-workspace cwd and a pool of session records, find the
    /// real `claude` CLI session that is running inside the surface bound to a
    /// planner node. The surface record and the CLI record share ONE
    /// correlation key — the managed-workspace cwd — because
    /// `session-terminals.json` never captures `providerResumeSessionId`.
    ///
    /// Selection rules (all guard against false adoption):
    /// - candidate cwd MUST normalize to the SAME managed-workspace path
    ///   (never correlate across different cwds);
    /// - candidate must NOT itself be a surface session;
    /// - candidate must have a non-empty `transcriptPath` (it's the record the
    ///   hook pipeline tracks — without a transcript it can't drive progress);
    /// - prefer a candidate whose transcript file actually has content over one
    ///   whose `transcriptPath` is set but stale (file gone / empty);
    /// - then prefer a non-historical (still-live) session;
    /// - then the most recently active; ties broken by `startedAt`.
    ///
    /// Critically: filtering to {NOT surface, non-empty transcriptPath, same
    /// normalized cwd} happens FIRST, so a transcript-bearing *historical* CLI
    /// session (e.g. a `completed` e2e run) is still chosen even when
    /// transcript-less or surface sessions also share the workspace. Two surface
    /// sessions bound to two nodes in one workspace therefore resolve to the
    /// SAME CLI session.
    ///
    /// Returns `nil` when no such CLI session exists (e.g. it has genuinely
    /// exited *and* left no transcript) — callers must leave the surface DTO
    /// untouched in that case.
    public static func correlatedCliSession(
        forWorkspaceCwd rawCwd: String?,
        among candidates: [SessionData]
    ) -> SessionData? {
        guard let target = normalizedManagedWorkspacePath(rawCwd) else { return nil }

        // Step 1 — filter to transcript-bearing, non-surface, same-cwd CLI
        // candidates. This MUST come before any ranking so a substantive
        // transcript-bearing session can never be out-ranked by a transcript-
        // less or surface record that merely happens to be more recent.
        let matches = candidates.filter { candidate in
            guard sessionCwd(candidate) == target else { return false }
            guard !isSurface(candidate) else { return false }
            let transcript = (candidate.transcriptPath ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !transcript.isEmpty
        }
        guard !matches.isEmpty else { return nil }

        // Step 2 — rank by a total-order priority so selection is deterministic
        // even with several transcript-bearing candidates in one workspace.
        // `areInIncreasingOrder` for `max`: return true ⇒ lhs ranks BELOW rhs.
        // Priority, highest first:
        //   1. transcript file actually has content (beats a stale path)
        //   2. live (non-historical) over historical
        //   3. most-recent lastActivity
        //   4. newest startedAt
        return matches.max { lhs, rhs in
            let lhsContent = transcriptFileHasContent(lhs.transcriptPath)
            let rhsContent = transcriptFileHasContent(rhs.transcriptPath)
            if lhsContent != rhsContent { return rhsContent } // prefer real content
            let lhsLive = !lhs.status.isHistorical
            let rhsLive = !rhs.status.isHistorical
            if lhsLive != rhsLive { return rhsLive } // prefer the live one
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity < rhs.lastActivity
            }
            return lhs.startedAt < rhs.startedAt
        }
    }
}

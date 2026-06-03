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

    /// 进程生命周期内 `~/.meee2/workspaces` 的规范化路径不变 —— 提成常量,
    /// 避免在 surface→CLI 关联热路径(每次重算对 surface × 全量 session 调用)
    /// 里反复 `NSHomeDirectory()` + 路径规范化。
    private static let managedWorkspacesRoot: String = normalizedPath(
        (NSHomeDirectory() as NSString).appendingPathComponent(".meee2/workspaces")
    )

    public static func isMeee2ManagedWorkspace(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        return normalized == managedWorkspacesRoot || normalized.hasPrefix(managedWorkspacesRoot + "/")
    }

    private static let pathCacheLock = NSLock()
    private static var pathCache: [String: String] = [:]

    /// `expandingTildeInPath` + `standardizingPath` 是 NSString 路径规范化,在
    /// `correlatedCliSession` 的 O(surface × 全量 session) 过滤热路径上被反复
    /// 调用,且输入 cwd 高度重复(同一 canvas 的 workspace 被多个节点共享)。
    /// 做进程级 memoization:同一输入只规范化一次,后续 O(1) 命中。结果是纯
    /// 路径函数(进程内 `NSHomeDirectory()` 不变),缓存安全;设上限防无界增长。
    private static func normalizedPath(_ path: String) -> String {
        pathCacheLock.lock()
        if let cached = pathCache[path] {
            pathCacheLock.unlock()
            return cached
        }
        pathCacheLock.unlock()

        let normalized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath

        pathCacheLock.lock()
        if pathCache.count >= 4096 { pathCache.removeAll(keepingCapacity: true) }
        pathCache[path] = normalized
        pathCacheLock.unlock()
        return normalized
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
    /// planner node. This is the FALLBACK correlation, keyed on the managed-
    /// workspace cwd; prefer `authoritativeCliSession(forProviderResumeSessionId:)`
    /// whenever the surface's `providerResumeSessionId` is known (it is, once the
    /// first hook arrives). cwd-only correlation is inherently ambiguous when a
    /// workspace is shared by several nodes / re-dispatches — see that function.
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
    ///
    /// `surfaceStartedAt` (when provided) gates against adopting a CLI session
    /// that PREDATES this surface — the prior-run-staleness regression (BUG B).
    /// On a REUSED workspace, a dead/`completed` CLI from an earlier run shares
    /// the same cwd; a freshly-dispatched live surface must NOT adopt its dead
    /// status (which would flip the node running→failed).
    ///
    /// The discriminator is `lastActivity`: this surface's OWN CLI is spawned
    /// just after the surface and keeps writing its transcript, so its
    /// `lastActivity` is at/after the surface's `startedAt`. A prior run — even
    /// one that ended only ~30s before the new dispatch (the quick-rerun window)
    /// — has its LAST activity strictly before the surface started, so it is
    /// rejected. We allow only a few seconds of backward skew for clock
    /// granularity / spawn ordering, NOT the previous 120s window (which let a
    /// quick-rerun's just-ended stale CLI through and reintroduced BUG B). A
    /// fresh surface whose own CLI hasn't written a transcript yet → no
    /// candidate → keeps its own (running) status; once its own CLI starts
    /// writing, `lastActivity` advances past the surface start and it's adopted.
    public static func correlatedCliSession(
        forWorkspaceCwd rawCwd: String?,
        among candidates: [SessionData],
        surfaceStartedAt: Date? = nil
    ) -> SessionData? {
        guard let target = normalizedManagedWorkspacePath(rawCwd) else { return nil }

        // Only absorb genuine spawn-ordering / clock-granularity skew (the CLI is
        // created a beat after its surface). Anything older than this is a prior
        // run, not this surface's session.
        let skewToleranceSeconds: TimeInterval = 5

        // Step 1 — filter to transcript-bearing, non-surface, same-cwd CLI
        // candidates. This MUST come before any ranking so a substantive
        // transcript-bearing session can never be out-ranked by a transcript-
        // less or surface record that merely happens to be more recent.
        let matches = candidates.filter { candidate in
            guard sessionCwd(candidate) == target else { return false }
            guard !isSurface(candidate) else { return false }
            let transcript = (candidate.transcriptPath ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return false }
            // BUG B temporal guard: a candidate whose LAST activity is before this
            // surface started is by definition a prior run in this reused cwd —
            // reject it (covers the quick-rerun window, not just hour-old runs).
            if let surfaceStartedAt {
                let cutoff = surfaceStartedAt.addingTimeInterval(-skewToleranceSeconds)
                guard candidate.lastActivity >= cutoff else { return false }
            }
            return true
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

    /// AUTHORITATIVE surface→CLI correlation, keyed by the surface's own
    /// `providerResumeSessionId` rather than the shared workspace cwd.
    ///
    /// `ClaudePlugin` records, on the first hook of a meee2-internal surface, the
    /// real `claude` CLI session id that the surface actually launched
    /// (`SessionTerminalStore.setProviderResumeSessionId`). That id is the ONE
    /// CLI session this surface owns — so matching on it can never adopt a
    /// *sibling node's* CLI session that merely shares the per-canvas workspace
    /// dir. (The cwd heuristic in `correlatedCliSession` can: a venture canvas
    /// gives every node + every re-dispatch the SAME cwd, so cwd+recency picks
    /// whichever CLI most recently wrote a transcript — bleeding that session's
    /// `.dead` status onto a live surface and resetting the node to 未启动.)
    ///
    /// Returns `nil` when no `providerResumeSessionId` is recorded yet (the brief
    /// window before the first hook) or the referenced CLI record is gone — the
    /// caller falls back to `correlatedCliSession`.
    public static func authoritativeCliSession(
        forProviderResumeSessionId resumeId: String?,
        among candidates: [SessionData]
    ) -> SessionData? {
        guard let resumeId = resumeId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resumeId.isEmpty else { return nil }
        return candidates.first { candidate in
            candidate.sessionId == resumeId
                && !isSurface(candidate)
                && !(candidate.transcriptPath ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

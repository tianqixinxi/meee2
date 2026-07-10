import XCTest
@testable import meee2Kit
import Meee2CommKit
import Meee2PluginKit

/// Regression coverage for the planner surface→CLI correlation fix.
///
/// When a planner step is dispatched, meee2 launches `claude` inside a
/// meee2-owned surface session (`claude-ghostty-XXX`); the node binds to THAT
/// surface id. The real `claude` process runs under its own CLI uuid, and that
/// CLI session — not the surface — is the record the hook pipeline tracks
/// (transcript / status / pendingPermissionTool). The two SessionStore records
/// share only the managed-workspace cwd.
///
/// Pre-fix behaviour (what these tests guard against):
///   - Bug A: the bound surface session's DTO had `recentMessages == []`
///     forever, because `internalSessionDTO` hardcodes it and the surface
///     record has no transcriptPath.
///   - Bug B: a permission-required CLI session left the node stuck at
///     `running`, because `effectiveSessionStatus` read the surface DTO whose
///     `pendingPermissionTool` is nil → never mapped to `.gateWait`.
final class SessionCorrelationTests: XCTestCase {

    /// Managed-workspace cwd shared by the surface + CLI records (the only link).
    private func managedWorkspaceCwd() -> String {
        StorageRoots.processDefault.baseDirectory
            .appendingPathComponent(
                "workspaces/global/meee2-corr-\(UUID().uuidString)",
                isDirectory: true
            )
            .path
    }

    /// Write a minimal Claude transcript JSONL so `transcriptPreviewFromClaude`
    /// returns real entries, then return its path.
    private func writeTranscript(lines: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-corr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("transcript.jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func surfaceSnapshot(
        sessionId: String,
        surfaceId: String,
        cwd: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> TerminalSessionSnapshot {
        TerminalSessionSnapshot(
            sessionId: sessionId,
            surfaceId: surfaceId,
            backend: .ghosttySurface,
            status: "running",
            pid: nil,
            cwd: cwd,
            command: "claude --dangerously-skip-permissions",
            provider: "claude",
            canvasId: "canvas-corr",
            nodeId: "node-corr",
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    // MARK: - 1. Correlation helper resolves surface → CLI by cwd

    func testCorrelationResolvesSurfaceToCliByCwd() {
        let cwd = managedWorkspaceCwd()
        let surface = SessionData(
            sessionId: "claude-ghostty-\(UUID().uuidString)",
            project: cwd,
            cwd: cwd,
            transcriptPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            status: .active,
            terminalInfo: PluginTerminalInfo(
                termProgram: "meee2-ghostty-surface",
                termBundleId: "meee2-ghostty-surface"
            )
        )
        let cli = SessionData(
            sessionId: UUID().uuidString,
            project: cwd,
            cwd: cwd,
            transcriptPath: "/tmp/does-not-need-to-exist.jsonl",
            startedAt: Date(timeIntervalSince1970: 1_100),
            lastActivity: Date(timeIntervalSince1970: 1_200),
            status: .active,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        let resolved = InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: cwd,
            among: [surface, cli]
        )
        XCTAssertEqual(resolved?.sessionId, cli.sessionId,
                       "Surface should correlate to the CLI session sharing its managed-workspace cwd.")

        // Guard: never correlate across a DIFFERENT cwd.
        let otherCwd = managedWorkspaceCwd()
        XCTAssertNil(
            InternalSessionIdentity.correlatedCliSession(forWorkspaceCwd: otherCwd, among: [surface, cli]),
            "A different managed-workspace cwd must not adopt this CLI session."
        )

        // Guard: a surface with NO live CLI session (CLI gone) → nil, no crash.
        XCTAssertNil(
            InternalSessionIdentity.correlatedCliSession(forWorkspaceCwd: cwd, among: [surface]),
            "When only the surface record exists, correlation yields nil (leave surface as-is)."
        )
    }

    func testCorrelationPrefersLiveThenMostRecentCli() {
        let cwd = managedWorkspaceCwd()
        let stale = SessionData(
            sessionId: "stale-\(UUID().uuidString)", project: cwd, cwd: cwd,
            transcriptPath: "/tmp/a.jsonl",
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 9_999), // newer, but historical
            status: .completed
        )
        let live = SessionData(
            sessionId: "live-\(UUID().uuidString)", project: cwd, cwd: cwd,
            transcriptPath: "/tmp/b.jsonl",
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_200), // older, but live
            status: .active
        )
        let resolved = InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: cwd, among: [stale, live]
        )
        XCTAssertEqual(resolved?.sessionId, live.sessionId,
                       "A live CLI session is preferred over a more-recent historical one.")
    }

    // MARK: - 1b. Multi-session-per-workspace (the live張三/王五 edge case)

    /// Two surface sessions bound to two different nodes share ONE managed
    /// workspace. Only one transcript-bearing CLI session exists there and it is
    /// `completed` (historical) — mirroring the live `prd-e2e-91a682f6` case
    /// where `50b35574…` was the sole transcript-bearing record. Transcript-less
    /// `dead` CLI records AND a distractor whose `transcriptPath` is set but
    /// stale (file does not exist) also share the cwd. Both surfaces must adopt
    /// the substantive transcript-bearing CLI — never the stale-path distractor,
    /// never nil.
    func testMultipleSurfacesInOneWorkspaceAdoptSameTranscriptBearingCli() throws {
        let cwd = managedWorkspaceCwd()

        // The real, substantive CLI session — historical (completed) with a
        // transcript file that actually exists and has content.
        let transcriptPath = try writeTranscript(lines: [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"REAL-CLI substantive output"}]}}"#
        ])
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: transcriptPath).deletingLastPathComponent()
            )
        }
        let realCliId = "real-\(UUID().uuidString)"
        let realCli = SessionData(
            sessionId: realCliId, project: "prd-e2e", cwd: cwd,
            transcriptPath: transcriptPath,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_100),
            status: .completed, // historical — must STILL be chosen
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        // Distractor A: transcriptPath set, but the file does not exist (stale),
        // and it is MORE RECENT than the real one. Pre-hardening "most-recent"
        // ranking would have picked this → 0 messages.
        let stalePathCli = SessionData(
            sessionId: "stale-\(UUID().uuidString)", project: "prd-e2e", cwd: cwd,
            transcriptPath: "/tmp/meee2-stale-\(UUID().uuidString)-does-not-exist.jsonl",
            startedAt: Date(timeIntervalSince1970: 2_000),
            lastActivity: Date(timeIntervalSince1970: 9_999), // newest
            status: .completed,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        // Distractor B: transcript-less dead CLI session in the same cwd.
        let transcriptlessCli = SessionData(
            sessionId: "dead-\(UUID().uuidString)", project: "prd-e2e", cwd: cwd,
            transcriptPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_500),
            lastActivity: Date(timeIntervalSince1970: 1_500),
            status: .dead,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        // Two surface sessions (張三 / 王五) bound to two nodes, same workspace.
        func surface(_ tag: String) -> SessionData {
            SessionData(
                sessionId: "claude-ghostty-\(tag)-\(UUID().uuidString)",
                project: cwd, cwd: cwd, transcriptPath: nil,
                startedAt: Date(timeIntervalSince1970: 1_000),
                lastActivity: Date(timeIntervalSince1970: 1_000),
                status: .active,
                terminalInfo: PluginTerminalInfo(
                    termProgram: "meee2-ghostty-surface",
                    termBundleId: "meee2-ghostty-surface"
                )
            )
        }
        let surfaceZhang = surface("zhangsan")
        let surfaceWang = surface("wangwu")

        let pool = [stalePathCli, transcriptlessCli, surfaceZhang, surfaceWang, realCli]

        let zhangResolved = InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: surfaceZhang.cwd, among: pool
        )
        let wangResolved = InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: surfaceWang.cwd, among: pool
        )

        XCTAssertEqual(zhangResolved?.sessionId, realCliId,
                       "張三's surface must adopt the substantive transcript-bearing CLI, not the stale-path distractor.")
        XCTAssertEqual(wangResolved?.sessionId, realCliId,
                       "王五's surface must adopt the SAME transcript-bearing CLI as 張三.")
        XCTAssertEqual(zhangResolved?.sessionId, wangResolved?.sessionId,
                       "Two surfaces sharing one workspace must resolve to the same CLI session.")

        // And the adopted transcript actually surfaces content (end-to-end).
        let zhangDTO = BoardDTOBuilder.internalSessionDTO(
            surfaceSnapshot(sessionId: surfaceZhang.sessionId, surfaceId: surfaceZhang.sessionId, cwd: cwd)
        )
        let cli = try XCTUnwrap(zhangResolved)
        let enriched = BoardDTOBuilder.surfaceDTOAdoptingCliSession(zhangDTO, cli: cli)
        XCTAssertTrue(
            enriched.recentMessages.contains { $0.text.contains("REAL-CLI") },
            "Enriched surface DTO should carry the substantive CLI transcript's content."
        )
    }

    // MARK: - 1b. Authoritative correlation by providerResumeSessionId

    /// The real bug behind "a node keeps reverting to 未启动": a venture canvas
    /// gives every node + every re-dispatch the SAME workspace cwd, so the cwd
    /// heuristic resolves two sibling surfaces to the SAME CLI session. When one
    /// sibling's CLI goes `.dead`, that dead status bleeds onto the OTHER, still
    /// live, surface and resets its node. `authoritativeCliSession` keys on the
    /// surface's own `providerResumeSessionId`, so each surface adopts ONLY the
    /// CLI it actually launched — sibling state can never cross over.
    func testAuthoritativeCorrelationBindsEachSurfaceToItsOwnCli() throws {
        let cwd = managedWorkspaceCwd()
        let path = try writeTranscript(lines: [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#
        ])
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path).deletingLastPathComponent()
            )
        }
        func cli(_ id: String, status: SessionStatus, last: TimeInterval) -> SessionData {
            SessionData(
                sessionId: id, project: cwd, cwd: cwd, transcriptPath: path,
                startedAt: Date(timeIntervalSince1970: 1_000),
                lastActivity: Date(timeIntervalSince1970: last),
                status: status,
                terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
            )
        }
        // Node A's own CLI is live but quiet; node B's CLI is dead but the most
        // recently active in the shared cwd — exactly what made cwd+recency pick
        // B for BOTH surfaces.
        let cliA = cli("cli-A-\(UUID().uuidString)", status: .active, last: 1_100)
        let cliB = cli("cli-B-\(UUID().uuidString)", status: .dead, last: 9_999)
        let pool = [cliA, cliB]

        let resolvedA = InternalSessionIdentity.authoritativeCliSession(
            forProviderResumeSessionId: cliA.sessionId, among: pool
        )
        let resolvedB = InternalSessionIdentity.authoritativeCliSession(
            forProviderResumeSessionId: cliB.sessionId, among: pool
        )
        XCTAssertEqual(resolvedA?.sessionId, cliA.sessionId,
                       "Surface A must adopt its OWN CLI (by providerResumeSessionId), not the more-recent sibling.")
        XCTAssertEqual(resolvedB?.sessionId, cliB.sessionId,
                       "Surface B must adopt its OWN CLI.")
        XCTAssertNotEqual(resolvedA?.sessionId, resolvedB?.sessionId,
                          "Two surfaces in one shared workspace must NOT collapse onto the same CLI session.")
    }

    /// Authoritative correlation returns nil when no id is recorded yet (pre-first
    /// hook) or the referenced CLI is absent / transcript-less — the snapshot
    /// provider then falls back to cwd correlation.
    func testAuthoritativeCorrelationReturnsNilWhenUnresolvable() throws {
        let cwd = managedWorkspaceCwd()
        let path = try writeTranscript(lines: [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#
        ])
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path).deletingLastPathComponent()
            )
        }
        let real = SessionData(
            sessionId: "cli-\(UUID().uuidString)", project: cwd, cwd: cwd, transcriptPath: path,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_100),
            status: .active,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )
        let transcriptless = SessionData(
            sessionId: "cli-nt-\(UUID().uuidString)", project: cwd, cwd: cwd, transcriptPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_100),
            status: .active,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )
        XCTAssertNil(
            InternalSessionIdentity.authoritativeCliSession(forProviderResumeSessionId: nil, among: [real]),
            "nil resumeId → nil (fall back to cwd correlation).")
        XCTAssertNil(
            InternalSessionIdentity.authoritativeCliSession(forProviderResumeSessionId: "   ", among: [real]),
            "blank resumeId → nil.")
        XCTAssertNil(
            InternalSessionIdentity.authoritativeCliSession(forProviderResumeSessionId: "no-such-id", among: [real]),
            "resumeId with no matching candidate → nil.")
        XCTAssertNil(
            InternalSessionIdentity.authoritativeCliSession(
                forProviderResumeSessionId: transcriptless.sessionId, among: [transcriptless]),
            "a transcript-less candidate can't drive progress → nil (fall back).")
    }

    // MARK: - 2. Permission-required CLI drives the bound node to .gateWait

    func testPermissionRequiredCliDrivesBoundNodeToGateWait() throws {
        let cwd = managedWorkspaceCwd()
        let store = SessionStore.shared

        let surfaceId = "claude-ghostty-\(UUID().uuidString)"
        var surfaceData = SessionData(
            sessionId: surfaceId, project: cwd, cwd: cwd,
            transcriptPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            status: .active,
            terminalInfo: PluginTerminalInfo(
                termProgram: "meee2-ghostty-surface",
                termBundleId: "meee2-ghostty-surface"
            )
        )
        surfaceData.pendingPermissionTool = nil // surface never carries the gate

        let cliId = UUID().uuidString
        var cliData = SessionData(
            sessionId: cliId, project: cwd, cwd: cwd,
            transcriptPath: "/tmp/perm-\(UUID().uuidString).jsonl",
            startedAt: Date(timeIntervalSince1970: 1_100),
            lastActivity: Date(timeIntervalSince1970: 1_200),
            status: .active,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )
        cliData.pendingPermissionTool = "Bash"
        cliData.pendingPermissionMessage = "Run rm -rf build/"

        store.create(surfaceData)
        store.create(cliData)
        defer { store.delete(surfaceId); store.delete(cliId) }

        // Production path: build the surface DTO exactly as currentBoardSessions does.
        let surfaceDTO = BoardDTOBuilder.internalSessionDTO(
            surfaceSnapshot(sessionId: surfaceId, surfaceId: surfaceId, cwd: cwd)
        )

        // PRE-FIX path: feedPlannerSessionRunStates read the surface DTO directly.
        // Its pendingPermissionTool is nil → effectiveSessionStatus stays a
        // working state → node runState == .running (the stuck bug).
        let preFixStatus = BoardAPI.effectiveSessionStatus(for: surfaceDTO)
        XCTAssertNotEqual(PlannerSessionRunStateBridge.runState(for: preFixStatus), .gateWait,
                          "Pre-fix: the bare surface DTO must NOT reach gateWait (proves the bug existed).")

        // POST-FIX path: enrich the surface DTO with the correlated CLI session.
        let cli = try XCTUnwrap(InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: surfaceDTO.project,
            among: store.listAll()
        ))
        XCTAssertEqual(cli.sessionId, cliId)
        let enriched = BoardDTOBuilder.surfaceDTOAdoptingCliSession(surfaceDTO, cli: cli)

        XCTAssertEqual(enriched.pendingPermissionTool, "Bash",
                       "Enriched surface DTO adopts the CLI session's pending permission.")
        let postFixStatus = BoardAPI.effectiveSessionStatus(for: enriched)
        XCTAssertEqual(postFixStatus, .permissionRequired)
        XCTAssertEqual(PlannerSessionRunStateBridge.runState(for: postFixStatus), .gateWait,
                       "Post-fix: a permission-required CLI session drives the bound node to gateWait.")
    }

    // MARK: - 3. Bound surface session reflects the CLI session's transcript

    func testBoundSurfaceReflectsCliTranscript() throws {
        let cwd = managedWorkspaceCwd()
        let store = SessionStore.shared

        let transcriptPath = try writeTranscript(lines: [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Build the landing page"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"CORRELATION-MARKER assistant reply"}]}}"#
        ])

        let surfaceId = "claude-ghostty-\(UUID().uuidString)"
        let surfaceData = SessionData(
            sessionId: surfaceId, project: cwd, cwd: cwd,
            transcriptPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            status: .active,
            terminalInfo: PluginTerminalInfo(
                termProgram: "meee2-ghostty-surface",
                termBundleId: "meee2-ghostty-surface"
            )
        )
        let cliId = UUID().uuidString
        let cliData = SessionData(
            sessionId: cliId, project: cwd, cwd: cwd,
            transcriptPath: transcriptPath,
            startedAt: Date(timeIntervalSince1970: 1_100),
            lastActivity: Date(timeIntervalSince1970: 1_200),
            status: .active,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        store.create(surfaceData)
        store.create(cliData)
        defer {
            store.delete(surfaceId); store.delete(cliId)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: transcriptPath).deletingLastPathComponent()
            )
        }

        let surfaceDTO = BoardDTOBuilder.internalSessionDTO(
            surfaceSnapshot(sessionId: surfaceId, surfaceId: surfaceId, cwd: cwd)
        )
        // PRE-FIX: the bare surface DTO has no transcript progress.
        XCTAssertTrue(surfaceDTO.recentMessages.isEmpty,
                      "Pre-fix: the surface DTO carries no recentMessages (proves Bug A).")

        // POST-FIX: enrich from the correlated CLI session.
        let cli = try XCTUnwrap(InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: surfaceDTO.project,
            among: store.listAll()
        ))
        let enriched = BoardDTOBuilder.surfaceDTOAdoptingCliSession(surfaceDTO, cli: cli)

        XCTAssertFalse(enriched.recentMessages.isEmpty,
                       "Post-fix: the bound surface DTO reflects the CLI session's transcript.")
        XCTAssertTrue(
            enriched.recentMessages.contains { $0.text.contains("CORRELATION-MARKER") },
            "Enriched recentMessages should contain the CLI transcript's assistant reply."
        )
    }

    // MARK: - 4. End-to-end: large CJK CLI transcript still enriches the surface
    //
    // The exact live `prd-e2e-91a682f6` failure: surface built by the real
    // `internalSessionDTO`, correlated to a `completed` CLI whose transcript is
    // a ~700KB CJK-dense `.jsonl`. The 64KB tail cut landed mid-Chinese-char →
    // `transcriptPreviewFromClaude` decoded to nil → recentMessages stayed [].
    // This drives the surface through the full adopt path with such a transcript.
    func testBoundSurfaceReflectsLargeCJKCliTranscript() throws {
        let cwd = managedWorkspaceCwd()
        let store = SessionStore.shared

        // Build a >64KB CJK-dense transcript so the tail window cut lands
        // mid-character (the live shape).
        let marker = "CJK-CLI-MARKER-\(UUID().uuidString.prefix(8))"
        let cjk = String(repeating: "中文内容填充测试一二三四五六七八九十", count: 40)
        var lines: [String] = []
        let approxLineBytes = cjk.utf8.count + 80
        let count = max(8, (65536 * 2) / approxLineBytes)
        for i in 0..<count {
            let role = i % 2 == 0 ? "user" : "assistant"
            lines.append(#"{"type":"\#(role)","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(cjk) #\#(i)"}]}}"#)
        }
        lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(marker) \#(cjk)"}]}}"#)
        let transcriptPath = try writeTranscript(lines: lines)
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: transcriptPath).deletingLastPathComponent()
            )
        }
        let size = (try FileManager.default.attributesOfItem(atPath: transcriptPath)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 65536, "fixture must exceed the 64KB tail window to exercise the cut")

        let surfaceId = "claude-ghostty-\(UUID().uuidString)"
        let surfaceData = SessionData(
            sessionId: surfaceId, project: cwd, cwd: cwd, transcriptPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 1_000),
            status: .active,
            terminalInfo: PluginTerminalInfo(
                termProgram: "meee2-ghostty-surface",
                termBundleId: "meee2-ghostty-surface"
            )
        )
        let cliId = UUID().uuidString
        let cliData = SessionData(
            sessionId: cliId, project: "prd-e2e", cwd: cwd, transcriptPath: transcriptPath,
            startedAt: Date(timeIntervalSince1970: 1_100),
            lastActivity: Date(timeIntervalSince1970: 1_200),
            status: .completed, // historical — exactly like 50b35574
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )
        store.create(surfaceData)
        store.create(cliData)
        defer { store.delete(surfaceId); store.delete(cliId) }

        let surfaceDTO = BoardDTOBuilder.internalSessionDTO(
            surfaceSnapshot(sessionId: surfaceId, surfaceId: surfaceId, cwd: cwd)
        )
        let cli = try XCTUnwrap(InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: surfaceDTO.project, among: store.listAll()
        ))
        XCTAssertEqual(cli.sessionId, cliId)
        let enriched = BoardDTOBuilder.surfaceDTOAdoptingCliSession(surfaceDTO, cli: cli)

        XCTAssertFalse(enriched.recentMessages.isEmpty,
                       "Large CJK CLI transcript must still surface recentMessages (was 0 live).")
        XCTAssertTrue(enriched.recentMessages.contains { $0.text.contains(marker) },
                      "The latest CJK assistant message must be recovered past the tail cut.")
    }

    // MARK: - 5. BUG B — temporal guard: don't adopt a CLI that predates the surface

    /// A freshly-dispatched surface (startedAt = T) in a REUSED workspace that
    /// already contains an OLDER dead/completed CLI from a prior run must NOT
    /// adopt that stale CLI — doing so flipped the live node running→failed.
    func testCorrelation_rejectsStalePriorRunCli() {
        let cwd = managedWorkspaceCwd()
        let surfaceStart = Date(timeIntervalSince1970: 10_000)

        // Prior-run CLI: started AND last active well before this surface.
        let stalePriorRun = SessionData(
            sessionId: "prior-\(UUID().uuidString)", project: cwd, cwd: cwd,
            transcriptPath: "/tmp/prior.jsonl",
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivity: Date(timeIntervalSince1970: 2_000), // long before surfaceStart
            status: .completed,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        // No own CLI yet → must resolve to nil (keep own running status).
        XCTAssertNil(
            InternalSessionIdentity.correlatedCliSession(
                forWorkspaceCwd: cwd, among: [stalePriorRun], surfaceStartedAt: surfaceStart
            ),
            "A surface must NOT adopt a CLI session that predates its own lifetime."
        )

        // Once THIS surface's own CLI appears (started at/after the surface), adopt it.
        let ownCli = SessionData(
            sessionId: "own-\(UUID().uuidString)", project: cwd, cwd: cwd,
            transcriptPath: "/tmp/own.jsonl",
            startedAt: surfaceStart.addingTimeInterval(2), // spawned just after the surface
            lastActivity: surfaceStart.addingTimeInterval(5),
            status: .active,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )
        let resolved = InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: cwd, among: [stalePriorRun, ownCli], surfaceStartedAt: surfaceStart
        )
        XCTAssertEqual(resolved?.sessionId, ownCli.sessionId,
                       "A surface MUST adopt its own CLI (startedAt >= surface), not the stale prior run.")
    }

    /// P2 regression: the QUICK-RERUN window. A reused workspace where the
    /// previous CLI ended only ~30s before the new dispatch. Its `lastActivity`
    /// is still recent, but it is STILL a prior run (ended before this surface
    /// started) and must NOT be adopted. The old 120s backward tolerance let
    /// this through and reintroduced BUG B for the normal quick-retry flow.
    func testCorrelation_rejectsQuickRerunPriorCli() {
        let cwd = managedWorkspaceCwd()
        let surfaceStart = Date(timeIntervalSince1970: 10_000)

        // Prior run that ENDED ~30s before the new surface started.
        let quickPrior = SessionData(
            sessionId: "quick-prior-\(UUID().uuidString)", project: cwd, cwd: cwd,
            transcriptPath: "/tmp/quick-prior.jsonl",
            startedAt: surfaceStart.addingTimeInterval(-90),
            lastActivity: surfaceStart.addingTimeInterval(-30), // 30s before — within old 120s window
            status: .completed,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        XCTAssertNil(
            InternalSessionIdentity.correlatedCliSession(
                forWorkspaceCwd: cwd, among: [quickPrior], surfaceStartedAt: surfaceStart
            ),
            "A CLI that last-activity'd before the surface started is a prior run — even a 30s-old one — and must not be adopted."
        )

        // Sanity: a CLI active just after the surface (its own) is still adopted,
        // and the small skew tolerance (a few seconds) is honored.
        let ownWithinSkew = SessionData(
            sessionId: "own-skew-\(UUID().uuidString)", project: cwd, cwd: cwd,
            transcriptPath: "/tmp/own-skew.jsonl",
            startedAt: surfaceStart.addingTimeInterval(-2),
            lastActivity: surfaceStart.addingTimeInterval(-2), // within 5s skew tolerance
            status: .active,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )
        XCTAssertEqual(
            InternalSessionIdentity.correlatedCliSession(
                forWorkspaceCwd: cwd, among: [quickPrior, ownWithinSkew], surfaceStartedAt: surfaceStart
            )?.sessionId,
            ownWithinSkew.sessionId,
            "A CLI within the small spawn-skew tolerance is this surface's own and must be adopted over the quick-rerun prior."
        )
    }

    /// Observability invariant preserved: a surface DOES still adopt its own
    /// `completed` CLI (the prior PR's behavior) — the guard only rejects CLIs
    /// that predate the surface, not historical-but-own ones.
    func testCorrelation_stillAdoptsOwnCompletedCli() {
        let cwd = managedWorkspaceCwd()
        let surfaceStart = Date(timeIntervalSince1970: 10_000)
        let ownCompleted = SessionData(
            sessionId: "own-done-\(UUID().uuidString)", project: cwd, cwd: cwd,
            transcriptPath: "/tmp/own-done.jsonl",
            startedAt: surfaceStart.addingTimeInterval(3),
            lastActivity: surfaceStart.addingTimeInterval(40),
            status: .completed, // own, finished — still adopted for observability
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )
        let resolved = InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: cwd, among: [ownCompleted], surfaceStartedAt: surfaceStart
        )
        XCTAssertEqual(resolved?.sessionId, ownCompleted.sessionId,
                       "A surface must still adopt its OWN completed CLI (observability preserved).")
    }

    /// End-to-end via the run-state mirror: a live freshly-dispatched surface in
    /// a workspace whose ONLY CLI is an older dead prior-run keeps runState
    /// `.running`, not `.failed`. Pre-fix, the surface adopted the dead CLI's
    /// status (→ dead → `.failed`).
    func testDispatchedSurfaceKeepsRunningDespiteOlderDeadCli() throws {
        let cwd = managedWorkspaceCwd()
        let store = SessionStore.shared
        let surfaceStart = Date()

        // Older dead prior-run CLI (reused workspace).
        let deadCliId = "dead-\(UUID().uuidString)"
        let deadCli = SessionData(
            sessionId: deadCliId, project: "prd-e2e", cwd: cwd,
            transcriptPath: "/tmp/dead-prior-\(UUID().uuidString).jsonl",
            startedAt: surfaceStart.addingTimeInterval(-3_600), // an hour earlier
            lastActivity: surfaceStart.addingTimeInterval(-3_000),
            status: .dead,
            terminalInfo: PluginTerminalInfo(termProgram: "ghostty", termBundleId: "com.mitchellh.ghostty")
        )

        // Freshly-dispatched live surface, started now.
        let surfaceId = "claude-ghostty-\(UUID().uuidString)"
        let surfaceData = SessionData(
            sessionId: surfaceId, project: cwd, cwd: cwd, transcriptPath: nil,
            startedAt: surfaceStart, lastActivity: surfaceStart,
            status: .active,
            terminalInfo: PluginTerminalInfo(
                termProgram: "meee2-ghostty-surface", termBundleId: "meee2-ghostty-surface"
            )
        )
        store.create(deadCli)
        store.create(surfaceData)
        defer { store.delete(deadCliId); store.delete(surfaceId) }

        let surfaceDTO = BoardDTOBuilder.internalSessionDTO(
            surfaceSnapshot(sessionId: surfaceId, surfaceId: surfaceId, cwd: cwd, createdAt: surfaceStart)
        )

        // Temporal guard rejects the older dead CLI → no candidate.
        let cli = InternalSessionIdentity.correlatedCliSession(
            forWorkspaceCwd: surfaceDTO.project,
            among: store.listAll(),
            surfaceStartedAt: parseISODateForTest(surfaceDTO.startedAt)
        )
        XCTAssertNil(cli, "fresh surface must not correlate to an older dead prior-run CLI")

        // Run-state mirror sees the surface's OWN (running) status, not failed.
        let status = BoardAPI.effectiveSessionStatus(for: surfaceDTO)
        let runState = PlannerSessionRunStateBridge.runState(for: status)
        XCTAssertNotEqual(runState, .failed,
                          "a just-dispatched live surface must not be marked failed by a stale CLI")
        XCTAssertEqual(runState, .running,
                       "the live surface keeps running until its OWN CLI starts writing a transcript")
    }

    /// Mirror of BoardAPI.parseISODate (private there) for the test.
    private func parseISODateForTest(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }
}

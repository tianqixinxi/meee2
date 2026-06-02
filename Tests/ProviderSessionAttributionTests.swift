import XCTest
@testable import meee2Kit

/// Regression coverage for the internal-session → CLI-session attribution fix
/// (`ClaudePlugin.resolveStaleSessionId`).
///
/// Real-world failure this reproduces (canvas `venture-f913f303`): every node's
/// internal `claude` session runs in the SAME managed-workspace cwd. When meee2
/// resolved "which CLI session is this surface's" by cwd alone, node 3's
/// internal session got bound to a *phantom* CLI id (`c35279fd`) that had no
/// transcript on disk — an aborted sibling session in the shared cwd. That
/// phantom got frozen as the node's `providerResumeSessionId`, so every
/// `claude --resume c35279fd` failed forever and the card stuck at
/// "needs-response" with no live session.
///
/// The fix makes attribution deterministic: prefer an exact surface-id match
/// (internal sessions now export `CMUX_SURFACE_ID`, so hooks carry it) and never
/// adopt a candidate whose transcript is missing.
final class ProviderSessionAttributionTests: XCTestCase {

    private typealias Candidate = ClaudePlugin.ProviderSessionCandidate

    /// Shared managed-workspace cwd — the only thing every node's internal
    /// session has in common, and the source of the original ambiguity.
    private let sharedCwd = "/Users/x/.meee2/workspaces/global/venture-f913f303"

    private func resolve(
        surfaceId: String?,
        candidates: [Candidate],
        transcriptIds: Set<String>,
        claimedIds: Set<String> = []
    ) -> String? {
        ClaudePlugin.resolveStaleSessionId(
            surfaceId: surfaceId,
            cwd: sharedCwd,
            candidates: candidates,
            isClaimedByOther: { claimedIds.contains($0) },
            transcriptExists: { transcriptIds.contains($0) }
        )
    }

    // MARK: - The venture-f913f303 bug: never adopt a transcript-less phantom

    func testRejectsPhantomCandidateWithoutTranscript() {
        // Node 3's internal surface; the only same-cwd candidate is a phantom
        // CLI session with no transcript (an aborted sibling). Pre-fix this got
        // bound + frozen as the resume id; post-fix it must be rejected.
        let phantom = Candidate(sessionId: "c35279fd-phantom", cwd: sharedCwd, surfaceId: nil)
        let resolved = resolve(
            surfaceId: "SURFACE-NODE-3",
            candidates: [phantom],
            transcriptIds: []  // phantom has NO transcript
        )
        XCTAssertNil(resolved, "must not adopt a phantom CLI id that has no transcript")
    }

    // MARK: - Deterministic: exact surface-id match wins over cwd ambiguity

    func testPrefersSurfaceIdMatchOverSharedCwdSibling() {
        // Two valid CLI sessions in the SAME cwd: a sibling node's session and
        // THIS surface's session. cwd can't tell them apart; surface id can.
        let sibling = Candidate(sessionId: "sibling-cli", cwd: sharedCwd, surfaceId: "SURFACE-NODE-2")
        let mine = Candidate(sessionId: "my-cli", cwd: sharedCwd, surfaceId: "SURFACE-NODE-3")
        let resolved = resolve(
            surfaceId: "SURFACE-NODE-3",
            candidates: [sibling, mine],  // sibling listed first on purpose
            transcriptIds: ["sibling-cli", "my-cli"]  // both valid
        )
        XCTAssertEqual(resolved, "my-cli", "must bind by exact surface id, not the shared-cwd sibling")
    }

    // MARK: - Happy path

    func testBindsSurfaceMatchWithTranscript() {
        let mine = Candidate(sessionId: "my-cli", cwd: sharedCwd, surfaceId: "SURFACE-NODE-3")
        let resolved = resolve(
            surfaceId: "SURFACE-NODE-3",
            candidates: [mine],
            transcriptIds: ["my-cli"]
        )
        XCTAssertEqual(resolved, "my-cli")
    }

    // MARK: - Skip candidates claimed by another live PID

    func testSkipsCandidateClaimedByAnotherLivePid() {
        let claimed = Candidate(sessionId: "claimed-cli", cwd: sharedCwd, surfaceId: "SURFACE-NODE-3")
        let resolved = resolve(
            surfaceId: "SURFACE-NODE-3",
            candidates: [claimed],
            transcriptIds: ["claimed-cli"],
            claimedIds: ["claimed-cli"]  // owned by another alive PID
        )
        XCTAssertNil(resolved, "a candidate claimed by another live PID is not ours")
    }

    // MARK: - Back-compat: cwd fallback when no surface id is available

    func testFallsBackToCwdWhenNoSurfaceId() {
        // Legacy / non-internal sessions have no surface id; a single
        // unambiguous same-cwd candidate with a transcript should still bind.
        let legacy = Candidate(sessionId: "legacy-cli", cwd: sharedCwd, surfaceId: nil)
        let resolved = resolve(
            surfaceId: nil,
            candidates: [legacy],
            transcriptIds: ["legacy-cli"]
        )
        XCTAssertEqual(resolved, "legacy-cli")
    }

    func testCwdFallbackStillRejectsTranscriptlessCandidate() {
        // Even on the cwd path, a transcript-less candidate is a phantom.
        let legacyPhantom = Candidate(sessionId: "legacy-phantom", cwd: sharedCwd, surfaceId: nil)
        let resolved = resolve(
            surfaceId: nil,
            candidates: [legacyPhantom],
            transcriptIds: []
        )
        XCTAssertNil(resolved)
    }

    // MARK: - Edge cases

    func testReturnsNilWhenNoCandidates() {
        XCTAssertNil(resolve(surfaceId: "SURFACE-NODE-3", candidates: [], transcriptIds: []))
    }

    func testIgnoresCandidatesInDifferentCwdAndSurface() {
        let unrelated = Candidate(sessionId: "other-cli", cwd: "/somewhere/else", surfaceId: "OTHER-SURFACE")
        let resolved = resolve(
            surfaceId: "SURFACE-NODE-3",
            candidates: [unrelated],
            transcriptIds: ["other-cli"]
        )
        XCTAssertNil(resolved, "neither cwd nor surface id matches → not a candidate")
    }

    func testSurfaceMatchInDifferentCwdStillBinds() {
        // Surface id is a strong identity even if cwd drifted (user `cd`'d).
        let mine = Candidate(sessionId: "my-cli", cwd: "/some/other/cwd", surfaceId: "SURFACE-NODE-3")
        let resolved = resolve(
            surfaceId: "SURFACE-NODE-3",
            candidates: [mine],
            transcriptIds: ["my-cli"]
        )
        XCTAssertEqual(resolved, "my-cli")
    }
}

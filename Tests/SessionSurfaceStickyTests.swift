import XCTest
@testable import meee2Kit
import Meee2PluginKit

/// Regression coverage for the "open session → blank terminal" bug.
///
/// An internal session's record is first written by `createSurface` with the
/// PTY `cmuxSurfaceId` set. Later, a PID-scan-driven `syncToStore` update for
/// the same session arrives carrying tty/termProgram but NO surface id (the
/// scan doesn't know it). `SessionStore.upsert`'s terminalInfo sticky-merge only
/// looked at tty/termProgram/cmuxSocketPath — NOT cmuxSurfaceId — so it kept the
/// incoming (surface-less) terminalInfo and WIPED the known surface.
///
/// With the surface gone from the SessionStore DTO (`/api/state`), the web UI
/// can't resolve/attach the native terminal when you click "open session" →
/// the panel switches over but renders blank. This guards the sticky fix.
final class SessionSurfaceStickyTests: XCTestCase {

    private func internalTerminalInfo(surface: String?, tty: String? = nil) -> PluginTerminalInfo {
        PluginTerminalInfo(
            tty: tty,
            termProgram: "meee2-internal",
            termBundleId: "meee2-internal",
            cmuxSocketPath: nil,
            cmuxSurfaceId: surface
        )
    }

    func testCmuxSurfaceIdStaysStickyWhenPidScanUpdateOmitsIt() {
        let sid = "surface-sticky-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { store.delete(sid) }

        // 1) createSurface-style write: PTY surface id known.
        store.upsert(SessionData(
            sessionId: sid, project: "p", cwd: "/tmp/p", status: .active,
            currentTool: "terminal",
            terminalInfo: internalTerminalInfo(surface: "SURFACE-XYZ")
        ))
        XCTAssertEqual(store.get(sid)?.terminalInfo?.cmuxSurfaceId, "SURFACE-XYZ")

        // 2) PID-scan-driven update: brings tty/termProgram, but NO surface id.
        //    Pre-fix this wiped the surface; post-fix it stays sticky.
        store.upsert(SessionData(
            sessionId: sid, project: "p", cwd: "/tmp/p", status: .active,
            currentTool: "terminal",
            terminalInfo: internalTerminalInfo(surface: nil, tty: "ttys009")
        ))
        XCTAssertEqual(
            store.get(sid)?.terminalInfo?.cmuxSurfaceId, "SURFACE-XYZ",
            "cmuxSurfaceId must stay sticky when a PID-scan update omits it — else open-session shows a blank terminal"
        )
        // Sanity: the genuinely-updated field still flows through.
        XCTAssertEqual(store.get(sid)?.terminalInfo?.tty, "ttys009")
    }

    func testIncomingSurfaceIdStillOverridesWhenPresent() {
        // Sticky must not pin a STALE surface: a real new surface id wins.
        let sid = "surface-override-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { store.delete(sid) }

        store.upsert(SessionData(
            sessionId: sid, project: "p", status: .active,
            terminalInfo: internalTerminalInfo(surface: "SURFACE-OLD")
        ))
        store.upsert(SessionData(
            sessionId: sid, project: "p", status: .active,
            terminalInfo: internalTerminalInfo(surface: "SURFACE-NEW", tty: "ttys010")
        ))
        XCTAssertEqual(store.get(sid)?.terminalInfo?.cmuxSurfaceId, "SURFACE-NEW")
    }

    func testFullyEmptyIncomingStillRestoresWholePrevTerminalInfo() {
        // The pre-existing "incomingEmpty" path (no tty/termProgram/socket) must
        // still restore the entire previous terminalInfo, surface included.
        let sid = "surface-emptyincoming-\(UUID().uuidString)"
        let store = SessionStore.shared
        defer { store.delete(sid) }

        store.upsert(SessionData(
            sessionId: sid, project: "p", status: .active,
            terminalInfo: internalTerminalInfo(surface: "SURFACE-KEEP", tty: "ttys001")
        ))
        store.upsert(SessionData(
            sessionId: sid, project: "p", status: .active,
            terminalInfo: PluginTerminalInfo()  // entirely empty
        ))
        XCTAssertEqual(store.get(sid)?.terminalInfo?.cmuxSurfaceId, "SURFACE-KEEP")
        XCTAssertEqual(store.get(sid)?.terminalInfo?.tty, "ttys001")
    }
}

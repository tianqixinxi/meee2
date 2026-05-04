import XCTest
@testable import meee2Kit

/// Unit tests for the assistant's tool dispatcher. We exercise the pure
/// gating + validation paths (filter, unknown tool, missing args) — the
/// state-touching tools (`get_session_list`, `get_session_info`) hit
/// `PluginManager.shared` and `SessionStore.shared`, which are global
/// singletons; we only verify they don't crash when those are empty and
/// trust integration smoke tests for the data shape.
final class AssistantToolsTests: XCTestCase {

    // MARK: - Catalog shape

    func testCatalogContainsAllExpectedTools() {
        let names = AssistantTools.allNames
        XCTAssertEqual(names, ["get_session_list", "get_session_info", "create_session"])
    }

    func testCatalogToolDefsHaveSchemas() {
        for tool in AssistantTools.all {
            // Every tool must declare an object schema with a `properties` map.
            // LLMs reject tools whose schema is malformed or missing.
            XCTAssertEqual(
                tool.inputSchema["type"] as? String, "object",
                "tool '\(tool.name)' missing top-level type=object")
            XCTAssertNotNil(
                tool.inputSchema["properties"] as? [String: Any],
                "tool '\(tool.name)' missing properties map")
            XCTAssertFalse(tool.description.isEmpty,
                           "tool '\(tool.name)' missing description")
        }
    }

    // MARK: - Filter

    func testFilterReturnsAllWhenEnabledIsNil() {
        let filtered = AssistantTools.filter(nil)
        XCTAssertEqual(filtered.count, AssistantTools.all.count)
    }

    func testFilterRespectsEnabledSet() {
        let only = AssistantTools.filter(["get_session_list"])
        XCTAssertEqual(only.map(\.name), ["get_session_list"])
    }

    func testFilterEmptySetReturnsNoTools() {
        let none = AssistantTools.filter([])
        XCTAssertEqual(none.count, 0)
    }

    // MARK: - Dispatch gating

    func testDispatchUnknownToolFailsCleanly() {
        let r = AssistantTools.dispatch(name: "ghost_tool", args: [:], enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected failure for unknown tool, got \(r)")
        }
        XCTAssertTrue(msg.contains("unknown tool"))
    }

    func testDispatchHonorsEnabledFilter() {
        // create_session is a real tool, but if it's not in `enabled` the
        // dispatcher must refuse it before any side effects (no spawn).
        let r = AssistantTools.dispatch(
            name: "create_session",
            args: ["cwd": "/tmp"],
            enabled: ["get_session_list"])
        guard case .failure(let msg) = r else {
            return XCTFail("expected disabled tool to fail, got \(r)")
        }
        XCTAssertTrue(msg.contains("disabled"))
    }

    func testDispatchAllowsToolWhenEnabledNil() {
        // nil enabled = all tools available → unknown still fails, real tool
        // proceeds to its handler.
        let r = AssistantTools.dispatch(
            name: "create_session",
            args: [:],  // missing cwd → handler-level failure
            enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected handler-level failure for missing cwd")
        }
        XCTAssertTrue(msg.contains("cwd"),
                      "expected error to mention 'cwd', got: \(msg)")
    }

    // MARK: - create_session validation

    func testCreateSessionRejectsMissingCwd() {
        let r = AssistantTools.dispatch(name: "create_session", args: [:], enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected failure for missing cwd, got \(r)")
        }
        XCTAssertTrue(msg.contains("cwd"))
    }

    func testCreateSessionRejectsEmptyCwd() {
        let r = AssistantTools.dispatch(name: "create_session", args: ["cwd": ""], enabled: nil)
        guard case .failure = r else {
            return XCTFail("expected failure for empty cwd, got \(r)")
        }
    }

    func testCreateSessionRejectsNonexistentCwdWithoutCreateIfMissing() {
        // Pick a path that definitely doesn't exist.
        let bogus = "/tmp/meee2-tests-nonexistent-\(UUID().uuidString)"
        let r = AssistantTools.dispatch(
            name: "create_session",
            args: ["cwd": bogus],
            enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected failure for nonexistent cwd, got \(r)")
        }
        XCTAssertTrue(msg.contains("does not exist"))
        XCTAssertTrue(msg.contains("createIfMissing"),
                      "error message should hint at the createIfMissing escape hatch")
    }

    // MARK: - get_session_list / get_session_info smoke

    func testGetSessionListRunsAgainstEmptyStateWithoutCrashing() {
        // PluginManager.shared in test context has no live sessions; just
        // ensure the call returns success with whatever shape the runtime
        // happens to have, no crash on empty.
        let r = AssistantTools.dispatch(name: "get_session_list", args: [:], enabled: nil)
        guard case .success(let payload) = r else {
            return XCTFail("get_session_list should always succeed, got \(r)")
        }
        let dict = payload as? [String: Any]
        XCTAssertNotNil(dict?["sessions"] as? [Any])
        XCTAssertNotNil(dict?["total"] as? Int)
    }

    func testGetSessionInfoRejectsMissingSessionId() {
        let r = AssistantTools.dispatch(name: "get_session_info", args: [:], enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected missing-sessionId failure, got \(r)")
        }
        XCTAssertTrue(msg.contains("sessionId"))
    }

    func testGetSessionInfoRejectsUnknownSessionId() {
        let r = AssistantTools.dispatch(
            name: "get_session_info",
            args: ["sessionId": "definitely-not-a-real-sid-\(UUID().uuidString)"],
            enabled: nil)
        guard case .failure(let msg) = r else {
            return XCTFail("expected unknown-sid failure, got \(r)")
        }
        XCTAssertTrue(msg.contains("not found"))
    }
}

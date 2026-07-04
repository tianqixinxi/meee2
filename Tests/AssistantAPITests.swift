import XCTest
@testable import meee2Kit

/// Unit tests for `AssistantAPI`'s pure helpers — `parseSettings`
/// (request-body → typed settings) and `buildSystemPrompt` (composes the
/// system prompt from board state). Network + SSE flow lives in
/// integration smoke tests, not here.
final class AssistantAPITests: XCTestCase {

    // MARK: - parseSettings

    func testParseSettingsDefaultsToLocalProvider() {
        let s = AssistantAPI.parseSettings(nil)
        XCTAssertEqual(s.provider, .local)
        XCTAssertEqual(s.apiKey, "")
        XCTAssertEqual(s.baseUrl, "")
        XCTAssertEqual(s.model, "")
        XCTAssertNil(s.enabledTools)  // nil = all tools enabled
    }

    func testParseSettingsAcceptsAllProviders() {
        for raw in ["openai", "anthropic", "local", "localCodex"] {
            let s = AssistantAPI.parseSettings(["provider": raw])
            XCTAssertEqual(s.provider.rawValue, raw)
        }
    }

    func testParseSettingsFallsBackToLocalForUnknownProvider() {
        let s = AssistantAPI.parseSettings(["provider": "definitely-not-real"])
        XCTAssertEqual(s.provider, .local,
                       "unknown provider strings must default to local so a typo doesn't 500 the request")
    }

    func testParseSettingsCarriesApiKeyAndBaseUrl() {
        let s = AssistantAPI.parseSettings([
            "provider": "openai",
            "apiKey": "sk-test",
            "baseUrl": "https://example.com/v1",
            "model": "gpt-4o-mini",
        ])
        XCTAssertEqual(s.apiKey, "sk-test")
        XCTAssertEqual(s.baseUrl, "https://example.com/v1")
        XCTAssertEqual(s.model, "gpt-4o-mini")
    }

    func testParseSettingsCarriesCanvasContext() {
        let s = AssistantAPI.parseSettings([
            "canvasId": "canvas-a",
            "canvasName": "Planning",
            "workspacePath": " /tmp/meee2-canvas ",
        ])
        XCTAssertEqual(s.canvasId, "canvas-a")
        XCTAssertEqual(s.canvasName, "Planning")
        XCTAssertEqual(s.workspacePath, "/tmp/meee2-canvas")
    }

    func testParseSettingsCarriesSelectedElements() {
        let s = AssistantAPI.parseSettings([
            "selectedElements": [
                [
                    "id": "el-1",
                    "type": "text",
                    "label": "Text: Launch plan",
                    "textPreview": "Launch plan",
                    "x": 12,
                    "y": 24,
                    "width": 120,
                    "height": 40,
                ],
            ],
        ])
        XCTAssertEqual(s.selectedElements.count, 1)
        XCTAssertEqual(s.selectedElements[0].label, "Text: Launch plan")
        XCTAssertEqual(s.selectedElements[0].textPreview, "Launch plan")
        XCTAssertEqual(s.selectedElements[0].x, 12)
    }

    func testParseSettingsParsesEnabledToolsAsSet() {
        let s = AssistantAPI.parseSettings([
            "enabledTools": ["get_session_list", "create_session"],
        ])
        XCTAssertEqual(s.enabledTools, ["get_session_list", "create_session"])
    }

    func testParseSettingsTreatsMissingEnabledToolsAsAll() {
        let s = AssistantAPI.parseSettings([:])
        XCTAssertNil(s.enabledTools, "no key = nil = 'all tools enabled'; empty array = explicit 'no tools'")
    }

    func testParseSettingsTreatsEmptyEnabledToolsAsExplicitlyNone() {
        let s = AssistantAPI.parseSettings(["enabledTools": [String]()])
        XCTAssertEqual(s.enabledTools, [])
    }

    func testParseSettingsIgnoresGarbageTypes() {
        // Wrong-type fields shouldn't crash the parser; they fall through
        // to defaults. (Frontend validation is a defense-in-depth, not the
        // server's primary guard.)
        let s = AssistantAPI.parseSettings([
            "provider": 42,
            "apiKey": ["nested"],
            "baseUrl": false,
            "model": NSNull(),
        ])
        XCTAssertEqual(s.provider, .local)
        XCTAssertEqual(s.apiKey, "")
    }

    // MARK: - buildSystemPrompt

    func testBuildSystemPromptIncludesEssentials() {
        let s = AssistantAPI.parseSettings(nil)
        let prompt = AssistantAPI.buildSystemPrompt(settings: s)
        // Must mention the assistant's identity, the tool list, and the
        // path-handling guidance — these are load-bearing for tool routing.
        XCTAssertTrue(prompt.contains("meee2 board assistant"))
        XCTAssertTrue(prompt.contains("get_session_list"))
        XCTAssertTrue(prompt.contains("get_session_info"))
        XCTAssertTrue(prompt.contains("create_session"))
        XCTAssertTrue(prompt.contains("Default context policy"))
        XCTAssertTrue(prompt.contains("Current-canvas visible sessions"))
        XCTAssertTrue(prompt.contains("Selected canvas elements at chat start"))
        XCTAssertTrue(prompt.contains("absolute paths"),
                      "system prompt must instruct LLM to expand ~ to absolute paths")
    }

    func testBuildSystemPromptExposesUserHome() {
        let s = AssistantAPI.parseSettings(nil)
        let prompt = AssistantAPI.buildSystemPrompt(settings: s)
        XCTAssertTrue(prompt.contains(NSHomeDirectory()),
                      "prompt should expose the literal home dir so LLM can reason about ~ paths")
    }

    func testBuildSystemPromptDoesNotCrashWithDifferentProviders() {
        // The prompt builder is provider-agnostic right now, but be defensive:
        // it should produce a non-empty string for any settings shape.
        for kind in [AssistantSettings.Provider.local, .localCodex, .openai, .anthropic] {
            let s = AssistantSettings(
                provider: kind,
                apiKey: "",
                baseUrl: "",
                model: "",
                enabledTools: nil,
	                scope: "this-mac",
	                canvasId: "personal-default",
	                workspacePath: "",
	                canvasName: "Canvas",
                localRunPurpose: .interactive,
	                selectedElements: [])
            let prompt = AssistantAPI.buildSystemPrompt(settings: s)
            XCTAssertFalse(prompt.isEmpty, "empty prompt for provider=\(kind)")
        }
    }

    // MARK: - canvas tools

    func testProposeCanvasPatchRejectsUnknownOperation() {
        let settings = AssistantAPI.parseSettings(["canvasId": "personal-default"])
        let result = AssistantTools.dispatch(
            name: "propose_canvas_patch",
            args: [
                "operations": [
                    ["type": "delete_canvas"]
                ]
            ],
            enabled: nil,
            settings: settings
        )
        guard case .failure(let message) = result else {
            return XCTFail("expected failure for unsupported operation")
        }
        XCTAssertTrue(message.contains("unsupported type"))
    }

    func testProposeCanvasPatchRejectsMissingRequiredId() {
        let settings = AssistantAPI.parseSettings(["canvasId": "personal-default"])
        let result = AssistantTools.dispatch(
            name: "propose_canvas_patch",
            args: [
                "operations": [
                    ["type": "hide_session"]
                ]
            ],
            enabled: nil,
            settings: settings
        )
        guard case .failure(let message) = result else {
            return XCTFail("expected failure for missing sessionId")
        }
        XCTAssertTrue(message.contains("missing sessionId"))
    }

    func testProposeCanvasPatchAcceptsLowRiskNoteOperation() {
        let settings = AssistantAPI.parseSettings(["canvasId": "personal-default"])
        let result = AssistantTools.dispatch(
            name: "propose_canvas_patch",
            args: [
                "summary": "Add a note",
                "operations": [
                    ["type": "add_note", "text": "Follow up", "x": 120, "y": 240]
                ]
            ],
            enabled: nil,
            settings: settings
        )
        guard case .success(let payload) = result,
              let dict = payload as? [String: Any] else {
            return XCTFail("expected successful proposal")
        }
        XCTAssertEqual(dict["type"] as? String, "canvas_patch_proposal")
        XCTAssertEqual(dict["canvasId"] as? String, "personal-default")
        XCTAssertEqual(dict["operationCount"] as? Int, 1)
    }

    func testProposeCanvasPatchAcceptsStructuredDrawingOperations() {
        let settings = AssistantAPI.parseSettings(["canvasId": "personal-default"])
        let result = AssistantTools.dispatch(
            name: "propose_canvas_patch",
            args: [
                "summary": "Draw relationship notes",
                "operations": [
                    [
                        "type": "add_frame",
                        "title": "Group",
                        "x": 10,
                        "y": 20,
                        "width": 320,
                        "height": 180,
                        "stylePreset": "group"
                    ],
                    [
                        "type": "add_shape",
                        "shape": "diamond",
                        "text": "Decision",
                        "x": 50,
                        "y": 70,
                        "stylePreset": "dependency"
                    ],
                    [
                        "type": "add_label",
                        "text": "Coordinates",
                        "x": 80,
                        "y": 120,
                        "stylePreset": "coordination"
                    ]
                ]
            ],
            enabled: nil,
            settings: settings
        )
        guard case .success(let payload) = result,
              let dict = payload as? [String: Any],
              let operations = dict["operations"] as? [[String: Any]] else {
            return XCTFail("expected successful structured drawing proposal")
        }
        XCTAssertEqual(dict["operationCount"] as? Int, 3)
        XCTAssertEqual(operations.map { $0["type"] as? String }, ["add_frame", "add_shape", "add_label"])
    }

    func testGetCanvasContextUsesRequestedCanvas() {
        _ = BoardLayoutStore.shared.ensureDefaults(sessionIds: [])
        let settings = AssistantAPI.parseSettings(["canvasId": "personal-default"])
        let result = AssistantTools.dispatch(
            name: "get_canvas_context",
            args: [:],
            enabled: nil,
            settings: settings
        )
        guard case .success(let payload) = result,
              let dict = payload as? [String: Any],
              let canvas = dict["canvas"] as? [String: Any] else {
            return XCTFail("expected canvas context")
        }
        XCTAssertEqual(canvas["id"] as? String, "personal-default")
        XCTAssertNotNil(dict["sessions"])
    }
}

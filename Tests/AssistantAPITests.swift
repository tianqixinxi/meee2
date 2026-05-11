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
        for raw in ["openai", "anthropic", "local"] {
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
        for kind in [AssistantSettings.Provider.local, .openai, .anthropic] {
            let s = AssistantSettings(
                provider: kind,
                apiKey: "",
                baseUrl: "",
                model: "",
                enabledTools: nil,
                scope: "this-mac",
                workspacePath: "",
                canvasName: "Canvas")
            let prompt = AssistantAPI.buildSystemPrompt(settings: s)
            XCTAssertFalse(prompt.isEmpty, "empty prompt for provider=\(kind)")
        }
    }
}

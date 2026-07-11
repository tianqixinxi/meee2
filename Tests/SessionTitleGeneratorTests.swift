import XCTest
@testable import meee2Kit

final class SessionTitleGeneratorTests: XCTestCase {
    func testUsesLightweightPreferredModels() {
        XCTAssertEqual(SessionTitleGenerator.codexPreferredModel, "gpt-5.4-mini")
        XCTAssertEqual(SessionTitleGenerator.claudePreferredModel, "haiku")
    }

    private struct FakeProvider: AssistantProvider {
        let events: [ProviderEvent]

        func runTurn(
            systemPrompt: String,
            messages: [ChatMessage],
            tools: [ToolDef],
            settings: AssistantSettings
        ) -> AsyncThrowingStream<ProviderEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func testGenerateTitleCleansModelOutput() async {
        let title = await SessionTitleGenerator.generateTitle(
            prompt: "仔细读下代码，研究标题是怎么来的",
            provider: FakeProvider(events: [
                .textDelta("标题：\"梳理对话标题来源。\""),
                .turnDone(stopReason: nil),
            ]),
            settings: settings()
        )

        XCTAssertEqual(title, "梳理对话标题来源")
    }

    func testGenerateTitleFailsSilentOnProviderError() async {
        let title = await SessionTitleGenerator.generateTitle(
            prompt: "hello",
            provider: FakeProvider(events: [.error("offline")]),
            settings: settings()
        )
        XCTAssertNil(title)
    }

    private func settings() -> AssistantSettings {
        AssistantSettings(
            provider: .localCodex,
            apiKey: "",
            baseUrl: "",
            model: "",
            enabledTools: [],
            scope: "this-mac",
            canvasId: "test-title",
            workspacePath: FileManager.default.temporaryDirectory.path,
            canvasName: "Session title",
            localRunPurpose: .title,
            selectedElements: []
        )
    }
}

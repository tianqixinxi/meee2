import XCTest
@testable import meee2Kit

final class ProviderSessionTitleReaderTests: XCTestCase {
    func testCodexTitleUsesLatestIndexEntryAndCollapsesWhitespace() throws {
        let sessionId = "019f517c-23ac-7e41-a953-aeab95671d11"
        let indexURL = try temporaryIndex(lines: [
            #"{"id":"019f517c-23ac-7e41-a953-aeab95671d11","thread_name":"旧标题"}"#,
            #"{"id":"other","thread_name":"忽略"}"#,
            #"{"id":"019f517c-23ac-7e41-a953-aeab95671d11","thread_name":"  梳理  对话\n标题来源  "}"#,
        ])

        XCTAssertEqual(
            ProviderSessionTitleReader.codexTitle(sessionId: sessionId, indexURL: indexURL),
            "梳理 对话 标题来源"
        )
    }

    func testCodexTitleRejectsPlaceholdersAndMalformedIds() throws {
        let sessionId = "019f517c-23ac-7e41-a953-aeab95671d11"
        let indexURL = try temporaryIndex(lines: [
            #"{"id":"019f517c-23ac-7e41-a953-aeab95671d11","thread_name":"(untitled)"}"#,
        ])

        XCTAssertNil(ProviderSessionTitleReader.codexTitle(sessionId: sessionId, indexURL: indexURL))
        XCTAssertNil(ProviderSessionTitleReader.codexTitle(sessionId: "codex-ghostty-local", indexURL: indexURL))
    }

    func testCodexTitleCacheRefreshesAfterIndexChanges() throws {
        let sessionId = "019f517c-23ac-7e41-a953-aeab95671d11"
        let indexURL = try temporaryIndex(lines: [
            #"{"id":"019f517c-23ac-7e41-a953-aeab95671d11","thread_name":"第一版"}"#,
        ])
        XCTAssertEqual(
            ProviderSessionTitleReader.codexTitle(sessionId: sessionId, indexURL: indexURL),
            "第一版"
        )

        try (#"{"id":"019f517c-23ac-7e41-a953-aeab95671d11","thread_name":"更新后的标题"}"# + "\n")
            .write(to: indexURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ProviderSessionTitleReader.codexTitle(sessionId: sessionId, indexURL: indexURL),
            "更新后的标题"
        )
    }

    func testCodexTranscriptTitleUsesFirstRealUserMessage() throws {
        let sessionId = "019f51dc-ad33-7d31-bc9c-386f781b5de8"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-provider-transcript-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcriptURL = directory.appendingPathComponent("rollout-test.jsonl")
        let lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"  验证 meee2   自动采用语义标题。  "}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"后续消息"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            ProviderSessionTitleReader.codexTranscriptTitle(
                sessionId: sessionId,
                transcriptURL: transcriptURL
            ),
            "验证 meee2 自动采用语义标题。"
        )
    }

    private func temporaryIndex(lines: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meee2-provider-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session_index.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }
}

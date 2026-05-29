import XCTest
@testable import meee2Kit

final class BoardAPIArtifactSyncTests: XCTestCase {
    func testGenericSessionArtifactCapturesFinalTextOutput() {
        let payload = BoardAPI.genericSessionArtifactPayload(
            from: """
            Final deliverable:

            This page introduction explains the product promise, primary user
            workflow, evidence expectations, and acceptance criteria in a form
            ready for review.
            """,
            outputRef: "page-intro.md"
        )

        let object = payload?.objectValue
        XCTAssertEqual(object?["type"]?.stringValue, "text")
        XCTAssertTrue(object?["text"]?.stringValue?.contains("Final deliverable") == true)
    }

    func testGenericSessionArtifactCapturesHTMLBlock() {
        let payload = BoardAPI.genericSessionArtifactPayload(
            from: """
            ```html
            <main>
              <section><h1>Meee2</h1><p>Human and AI work, visible.</p></section>
            </main>
            ```
            """,
            outputRef: "landing-page.html"
        )

        let object = payload?.objectValue
        XCTAssertEqual(object?["type"]?.stringValue, "html")
        XCTAssertTrue(object?["html"]?.stringValue?.contains("<main>") == true)
    }

    func testGenericSessionArtifactRejectsFollowupQuestion() {
        let payload = BoardAPI.genericSessionArtifactPayload(
            from: "需要先确认页面是给开发者还是团队 owner 看吗？",
            outputRef: "summary.md"
        )

        XCTAssertNil(payload)
    }
}

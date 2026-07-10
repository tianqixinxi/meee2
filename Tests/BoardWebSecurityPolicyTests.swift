import XCTest
@testable import meee2Kit

final class BoardWebSecurityPolicyTests: XCTestCase {
    private let boardURL = URL(string: "http://127.0.0.1:9912")!

    func testAllowsOnlyExactBoardOrigin() {
        XCTAssertTrue(BoardWebSecurityPolicy.isTrustedBoardURL(
            URL(string: "http://127.0.0.1:9912/canvas/one"),
            boardURL: boardURL
        ))
        XCTAssertFalse(BoardWebSecurityPolicy.isTrustedBoardURL(
            URL(string: "http://127.0.0.1:9876"),
            boardURL: boardURL
        ))
        XCTAssertFalse(BoardWebSecurityPolicy.isTrustedBoardURL(
            URL(string: "http://localhost:9912"),
            boardURL: boardURL
        ))
        XCTAssertFalse(BoardWebSecurityPolicy.isTrustedBoardURL(
            URL(string: "https://127.0.0.1:9912"),
            boardURL: boardURL
        ))
    }

    func testClassifiesOnlyHTTPExternalLinksForSystemBrowser() {
        XCTAssertTrue(BoardWebSecurityPolicy.isExternalWebURL(
            URL(string: "https://docs.meee2.dev/guide"),
            boardURL: boardURL
        ))
        XCTAssertFalse(BoardWebSecurityPolicy.isExternalWebURL(
            URL(string: "file:///tmp/secret"),
            boardURL: boardURL
        ))
        XCTAssertFalse(BoardWebSecurityPolicy.isExternalWebURL(
            URL(string: "javascript:alert(1)"),
            boardURL: boardURL
        ))
    }

    func testLoopbackCallbackAndAPIResponsesAreNotTrustedBoardDocuments() {
        XCTAssertTrue(BoardWebSecurityPolicy.isTrustedBoardDocumentURL(
            URL(string: "http://127.0.0.1:9912/canvas/one"),
            boardURL: boardURL
        ))
        XCTAssertFalse(BoardWebSecurityPolicy.isTrustedBoardDocumentURL(
            URL(string: "http://127.0.0.1:9912/meee2/callback?state=attacker"),
            boardURL: boardURL
        ))
        XCTAssertFalse(BoardWebSecurityPolicy.isTrustedBoardDocumentURL(
            URL(string: "http://127.0.0.1:9912/api/control/bootstrap"),
            boardURL: boardURL
        ))
    }
}

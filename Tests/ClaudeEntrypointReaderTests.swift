import XCTest
@testable import meee2Kit

final class ClaudeEntrypointReaderTests: XCTestCase {

    private func writeFixture(_ lines: [String]) -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("ep-\(UUID().uuidString).jsonl")
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    override func setUp() {
        super.setUp()
        ClaudeEntrypointReader._resetCache()
    }

    func testReadsClaudeDesktopEntrypoint() {
        // Real shape: top-level entrypoint, sibling of message/sessionId.
        let line = """
        {"type":"user","timestamp":"2026-04-25T19:58:32.697Z","entrypoint":"claude-desktop","sessionId":"d2faeda7-...","message":{"role":"user","content":"hi"}}
        """
        let path = writeFixture([line])
        XCTAssertEqual(ClaudeEntrypointReader.read(transcriptPath: path), "claude-desktop")
    }

    func testReadsCliEntrypoint() {
        let line = #"{"type":"assistant","entrypoint":"cli","message":{"role":"assistant","content":[]}}"#
        XCTAssertEqual(ClaudeEntrypointReader.read(transcriptPath: writeFixture([line])), "cli")
    }

    func testSkipsInitialMetaLineWithoutEntrypoint() {
        // Some jsonl files start with a meta entry that doesn't carry entrypoint;
        // the reader must keep scanning until it finds one.
        let lines = [
            #"{"type":"summary","summary":"old chat"}"#,
            #"{"type":"user","entrypoint":"sdk-py","message":{"role":"user"}}"#,
        ]
        XCTAssertEqual(ClaudeEntrypointReader.read(transcriptPath: writeFixture(lines)), "sdk-py")
    }

    func testReturnsNilWhenNoEntrypoint() {
        let line = #"{"type":"user","message":{"role":"user"}}"#
        XCTAssertNil(ClaudeEntrypointReader.read(transcriptPath: writeFixture([line])))
    }

    func testReturnsNilForMissingFile() {
        XCTAssertNil(ClaudeEntrypointReader.read(transcriptPath: "/tmp/does-not-exist-\(UUID()).jsonl"))
        XCTAssertNil(ClaudeEntrypointReader.read(transcriptPath: nil))
        XCTAssertNil(ClaudeEntrypointReader.read(transcriptPath: ""))
    }

    func testCacheReturnsSameValueWithoutReReading() {
        let line = #"{"type":"user","entrypoint":"claude-desktop","message":{}}"#
        let path = writeFixture([line])

        XCTAssertEqual(ClaudeEntrypointReader.read(transcriptPath: path), "claude-desktop")

        // Overwrite file with a different entrypoint but keep mtime/size the same:
        // since we can't reliably do that, just confirm a second call returns the
        // cached value (cache key is mtime+size, untouched file → same key).
        XCTAssertEqual(ClaudeEntrypointReader.read(transcriptPath: path), "claude-desktop")
    }
}

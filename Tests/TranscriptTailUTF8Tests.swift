import XCTest
@testable import meee2Kit

/// Regression for the live "2/14 nodes stay opaque" bug.
///
/// Root cause: `TranscriptParser.parseTail` / `FullTranscriptReader.tailLines`
/// / `TranscriptStatusResolver.readTail` all seek to `fileSize - tailWindow`
/// and decode the slice with `String(data:encoding:.utf8)`. For a large
/// transcript whose content near the cut point is CJK/emoji, the slice starts
/// on a UTF-8 *continuation* byte (0x80–0xBF) → the WHOLE slice fails to decode
/// → the reader returns nil/[] → the surface DTO's `recentMessages` is empty
/// forever even though the correlated CLI session has a 700 KB transcript.
///
/// These tests build a transcript big enough to force a tail-window cut, with
/// dense CJK so the cut lands mid-character, and assert the readers still
/// surface the latest messages.
final class TranscriptTailUTF8Tests: XCTestCase {

    /// Write a transcript whose total size comfortably exceeds `windowBytes`,
    /// padded with CJK so the byte at `size - windowBytes` is almost certainly a
    /// UTF-8 continuation byte. The final assistant line carries `marker`.
    private func writeLargeCJKTranscript(windowBytes: Int, marker: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("utf8tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("transcript.jsonl")

        // Each padding line is dense CJK (3 bytes/char in UTF-8) so cut points
        // land mid-character. Build past the window from BOTH the user and
        // assistant side so the tail contains real user+assistant entries.
        let cjk = String(repeating: "中文内容填充测试一二三四五六七八九十", count: 40)
        var lines: [String] = []
        // ~ windowBytes * 2 of padding to guarantee the cut is inside padding.
        let approxLineBytes = cjk.utf8.count + 80
        let count = max(8, (windowBytes * 2) / approxLineBytes)
        for i in 0..<count {
            let role = i % 2 == 0 ? "user" : "assistant"
            lines.append(#"{"type":"\#(role)","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(cjk) #\#(i)"}]}}"#)
        }
        // Last few entries carry the marker so loadMessages(count:5) must see it.
        lines.append(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"请总结 \#(cjk)"}]}}"#)
        lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(marker) 完成总结 \#(cjk)"}]}}"#)

        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func removeParentDir(_ path: String) {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent()
        )
    }

    /// `loadMessages` reads a 65536-byte tail. A CJK-dense >64KB transcript used
    /// to decode to nil → []. After the fix it must surface the latest messages.
    func testLoadMessagesSurvivesMidCJKTailCut() throws {
        let marker = "MARKER-\(UUID().uuidString.prefix(8))"
        let path = try writeLargeCJKTranscript(windowBytes: 65536, marker: marker)
        defer { removeParentDir(path) }

        // Sanity: the file is bigger than the tail window AND the cut byte is a
        // UTF-8 continuation byte (proves we actually exercise the bug shape).
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 65536, "fixture must exceed the 64KB tail window")
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(size - 65536))
        let firstByte = handle.readData(ofLength: 1).first ?? 0
        XCTAssertTrue((0x80...0xBF).contains(firstByte),
                      "tail-window cut should land on a UTF-8 continuation byte (got 0x\(String(firstByte, radix: 16)))")

        let msgs = TranscriptParser.loadMessages(transcriptPath: path, count: 5)
        XCTAssertFalse(msgs.isEmpty, "parseTail must not return [] when the tail cut lands mid-CJK")
        XCTAssertTrue(msgs.contains { $0.text.contains(marker) },
                      "the latest assistant message must be recoverable past a mid-CJK tail cut")
    }

    /// `FullTranscriptReader.readTail` had the identical decode-nil bug.
    func testFullTranscriptReaderSurvivesMidCJKTailCut() throws {
        let marker = "FULLMARK-\(UUID().uuidString.prefix(8))"
        // readTail's limited window is bounded; use a window large enough to bite.
        let path = try writeLargeCJKTranscript(windowBytes: 200 * 1024, marker: marker)
        defer { removeParentDir(path) }

        let entries = FullTranscriptReader.readTail(transcriptPath: path, limit: 5, maxBytes: 200 * 1024)
        XCTAssertFalse(entries.isEmpty, "FullTranscriptReader.readTail must not return [] on a mid-CJK tail cut")
        let allText = entries.flatMap { $0.blocks.compactMap { $0.text } }.joined(separator: "\n")
        XCTAssertTrue(allText.contains(marker),
                      "the latest entry must be recoverable past a mid-CJK tail cut")
    }
}

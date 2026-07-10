import Foundation
import Meee2CommKit

struct AssistantLocalSessionMessage: Encodable, Equatable {
    let id: String
    let role: String
    let content: String
    let timestamp: String?
}

struct AssistantLocalSessionMessagesEnvelope: Encodable, Equatable {
    let sessionId: String
    let messages: [AssistantLocalSessionMessage]
}

private struct AssistantLocalSessionRecord: Codable {
    var sessionId: String
    var createdAt: Date
    var updatedAt: Date
}

final class AssistantLocalSessionStore {
    static let shared = AssistantLocalSessionStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: AssistantLocalSessionRecord]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = StorageRoots.processDefault.baseDirectory
                .appendingPathComponent("assistant/claude-sessions.json")
        }
    }

    func sessionId(forCanvasId canvasId: String) -> String {
        sessionId(forKey: Self.key(canvasId: canvasId))
    }

    func resetSessionId(forCanvasId canvasId: String) -> String {
        resetSessionId(forKey: Self.key(canvasId: canvasId))
    }

    func messages(forCanvasId canvasId: String, limit: Int = 80) -> AssistantLocalSessionMessagesEnvelope {
        let sid = sessionId(forCanvasId: canvasId)
        guard let path = transcriptPath(forSessionId: sid) else {
            return AssistantLocalSessionMessagesEnvelope(sessionId: sid, messages: [])
        }
        let entries = FullTranscriptReader.read(transcriptPath: path, limit: limit)
        return AssistantLocalSessionMessagesEnvelope(
            sessionId: sid,
            messages: AssistantLocalSessionProjection.messages(sessionId: sid, entries: entries)
        )
    }

    func transcriptPath(forSessionId sessionId: String) -> String? {
        let home = NSHomeDirectory()
        let projectsDir = "\(home)/.claude/projects"
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else {
            return nil
        }

        for projectDir in projectDirs {
            let transcriptPath = "\(projectsDir)/\(projectDir)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: transcriptPath) {
                return transcriptPath
            }
        }
        return nil
    }

    static func key(canvasId: String) -> String {
        let trimmed = canvasId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "global" : "canvas:\(trimmed)"
    }

    static func sessionName(canvasId: String, canvasName: String) -> String {
        let trimmedId = canvasId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = canvasName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmedName.isEmpty ? trimmedId : trimmedName
        if suffix.isEmpty { return "meee2ai:global" }
        return "meee2ai:\(String(suffix.prefix(48)))"
    }

    private func sessionId(forKey key: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var current = loadRecords()
        if var record = current[key], !record.sessionId.isEmpty {
            record.updatedAt = Date()
            current[key] = record
            records = current
            saveRecords(current)
            return record.sessionId
        }

        let record = AssistantLocalSessionRecord(
            sessionId: UUID().uuidString.lowercased(),
            createdAt: Date(),
            updatedAt: Date()
        )
        current[key] = record
        records = current
        saveRecords(current)
        return record.sessionId
    }

    private func resetSessionId(forKey key: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var current = loadRecords()
        let record = AssistantLocalSessionRecord(
            sessionId: UUID().uuidString.lowercased(),
            createdAt: Date(),
            updatedAt: Date()
        )
        current[key] = record
        records = current
        saveRecords(current)
        return record.sessionId
    }

    private func loadRecords() -> [String: AssistantLocalSessionRecord] {
        if let records { return records }
        guard let data = try? Data(contentsOf: fileURL) else {
            records = [:]
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([String: AssistantLocalSessionRecord].self, from: data)) ?? [:]
        records = decoded
        return decoded
    }

    private func saveRecords(_ records: [String: AssistantLocalSessionRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            MLog("[AssistantLocalSessionStore] failed to save session map: \(error.localizedDescription)")
        }
    }
}

enum AssistantLocalSessionProjection {
    static func messages(
        sessionId: String,
        entries: [FullTranscriptEntry]
    ) -> [AssistantLocalSessionMessage] {
        var out: [AssistantLocalSessionMessage] = []
        var seenContent = Set<String>()

        for entry in entries {
            guard ["user", "assistant", "injected"].contains(entry.type) else { continue }
            let parts = entry.blocks.compactMap { block -> String? in
                guard block.type == "text",
                      let raw = block.text else { return nil }
                return cleanText(raw, role: entry.type)
            }
            let content = parts
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            let role = entry.type == "assistant" ? "assistant" : entry.type
            let dedupeKey = "\(role):\(content)"
            if seenContent.contains(dedupeKey) { continue }
            seenContent.insert(dedupeKey)

            out.append(AssistantLocalSessionMessage(
                id: "claude:\(sessionId):\(entry.id)",
                role: role,
                content: content,
                timestamp: entry.timestamp
            ))
        }

        return out
    }

    private static func cleanText(_ raw: String, role: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if role == "assistant" {
            text = stripToolFences(text)
        }
        if role == "user" || role == "injected" {
            text = extractUserFacingPrompt(text)
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func stripToolFences(_ text: String) -> String {
        let pattern = #"```tool\s*\n[\s\S]*?\n```"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func extractUserFacingPrompt(_ text: String) -> String {
        guard text.hasPrefix("User:") else { return text }

        let pattern = #"(?m)^(User|Assistant|ToolResult\([^)]*\)):\s*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var userBlocks: [String] = []
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges > 1 else { continue }
            let role = ns.substring(with: match.range(at: 1))
            guard role == "User" else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard end >= start else { continue }
            let block = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { userBlocks.append(block) }
        }

        return userBlocks.last ?? text
    }
}

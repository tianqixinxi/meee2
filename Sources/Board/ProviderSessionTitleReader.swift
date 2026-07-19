import Foundation

/// Reads provider-owned, human-friendly session titles without asking a second
/// model to summarize the same opening prompt. Provider storage is an adapter
/// detail: callers only supply the provider and its resume/session id.
enum ProviderSessionTitleReader {
    private struct CachedCodexIndex {
        let modificationDate: Date?
        let fileSize: UInt64?
        let titlesBySessionId: [String: String]
    }

    private struct CachedCodexTranscriptTitle {
        let loadedAt: Date
        let title: String?
    }

    private static let lock = NSLock()
    private static var cachedCodexIndexes: [String: CachedCodexIndex] = [:]
    private static var cachedCodexTranscriptTitles: [String: CachedCodexTranscriptTitle] = [:]
    private static let transcriptCacheTTL: TimeInterval = 15
    private static let transcriptScanLimit = 8 * 1024 * 1024
    private static let transcriptChunkSize = 64 * 1024
    private static let transcriptLineLimit = 256 * 1024

    static func title(provider: String, providerSessionId: String?) -> String? {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedProvider.contains("codex") else { return nil }
        return codexTitle(
            sessionId: providerSessionId,
            indexURL: codexSessionIndexURL()
        ) ?? codexTranscriptTitle(
            sessionId: providerSessionId,
            sessionsRootURL: codexSessionsRootURL()
        )
    }

    static func codexTitle(sessionId: String?, indexURL: URL) -> String? {
        let id = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard AgentLaunchCommand.isLikelyProviderResumeSessionId(id) else { return nil }
        return codexTitles(indexURL: indexURL)[id]
    }

    private static func codexSessionIndexURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("session_index.jsonl")
    }

    private static func codexSessionsRootURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }

    private static func codexTitles(indexURL: URL) -> [String: String] {
        let cacheKey = indexURL.standardizedFileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheKey)
        let modificationDate = attributes?[.modificationDate] as? Date
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value

        lock.lock()
        if let cached = cachedCodexIndexes[cacheKey],
           cached.modificationDate == modificationDate,
           cached.fileSize == fileSize {
            lock.unlock()
            return cached.titlesBySessionId
        }
        lock.unlock()

        let titles = loadCodexTitles(indexURL: indexURL)
        let entry = CachedCodexIndex(
            modificationDate: modificationDate,
            fileSize: fileSize,
            titlesBySessionId: titles
        )
        lock.lock()
        cachedCodexIndexes[cacheKey] = entry
        lock.unlock()
        return titles
    }

    private static func loadCodexTitles(indexURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let content = String(data: data, encoding: .utf8) else {
            return [:]
        }
        var titles: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  AgentLaunchCommand.isLikelyProviderResumeSessionId(id),
                  let rawTitle = json["thread_name"] as? String,
                  let title = cleanedTitle(rawTitle) else {
                continue
            }
            // session_index.jsonl is append-only; the last record is authoritative.
            titles[id] = title
        }
        return titles
    }

    private static func codexTranscriptTitle(sessionId: String?, sessionsRootURL: URL) -> String? {
        let id = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard AgentLaunchCommand.isLikelyProviderResumeSessionId(id) else { return nil }
        let now = Date()
        lock.lock()
        if let cached = cachedCodexTranscriptTitles[id],
           now.timeIntervalSince(cached.loadedAt) < transcriptCacheTTL {
            lock.unlock()
            return cached.title
        }
        lock.unlock()

        let title = codexRolloutURL(sessionId: id, sessionsRootURL: sessionsRootURL)
            .flatMap { codexTranscriptTitle(sessionId: id, transcriptURL: $0) }
        lock.lock()
        cachedCodexTranscriptTitles[id] = CachedCodexTranscriptTitle(loadedAt: now, title: title)
        lock.unlock()
        return title
    }

    static func codexTranscriptTitle(sessionId: String, transcriptURL: URL) -> String? {
        guard AgentLaunchCommand.isLikelyProviderResumeSessionId(sessionId),
              let handle = try? FileHandle(forReadingFrom: transcriptURL) else {
            return nil
        }
        defer { try? handle.close() }
        var line = Data()
        var skippingOversizedLine = false
        var scannedBytes = 0
        while scannedBytes < transcriptScanLimit {
            let readLength = min(transcriptChunkSize, transcriptScanLimit - scannedBytes)
            let chunk = handle.readData(ofLength: readLength)
            guard !chunk.isEmpty else { break }
            scannedBytes += chunk.count
            for byte in chunk {
                if byte == 0x0A {
                    if !skippingOversizedLine, let title = codexUserMessageTitle(from: line) {
                        return title
                    }
                    line.removeAll(keepingCapacity: true)
                    skippingOversizedLine = false
                } else if !skippingOversizedLine {
                    if line.count < transcriptLineLimit {
                        line.append(byte)
                    } else {
                        // Image-bearing transcript records can be several MB. Their
                        // content is not a title candidate, so discard the rest of
                        // the record while continuing to scan later JSONL lines.
                        line.removeAll(keepingCapacity: true)
                        skippingOversizedLine = true
                    }
                }
            }
        }
        return skippingOversizedLine ? nil : codexUserMessageTitle(from: line)
    }

    private static func codexUserMessageTitle(from data: Data) -> String? {
        guard !data.isEmpty,
              let line = String(data: data, encoding: .utf8),
              line.contains("\"type\":\"user_message\""),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["type"] as? String == "event_msg",
              let payload = envelope["payload"] as? [String: Any],
              payload["type"] as? String == "user_message",
              let message = payload["message"] as? String else {
            return nil
        }
        return cleanedTitle(message)
    }

    private static func codexRolloutURL(sessionId: String, sessionsRootURL: URL) -> URL? {
        guard let anchor = uuidV7Date(sessionId) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: anchor) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = sessionsRootURL
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            if let match = files.first(where: { url in
                url.pathExtension == "jsonl" && url.lastPathComponent.contains(sessionId)
            }) {
                return match
            }
        }
        return nil
    }

    private static func uuidV7Date(_ id: String) -> Date? {
        let compact = id.replacingOccurrences(of: "-", with: "")
        guard compact.count == 32,
              let milliseconds = UInt64(compact.prefix(12), radix: 16) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func cleanedTitle(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = collapsed.replacingOccurrences(
            of: #"^(?:\[Image #[0-9]+\]\s*)+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        guard !title.isEmpty else { return nil }
        let normalized = title.lowercased()
        guard normalized != "(untitled)",
              normalized != "untitled",
              normalized != "new thread",
              normalized != "new conversation" else {
            return nil
        }
        return title.count <= 200 ? title : String(title.prefix(200))
    }
}

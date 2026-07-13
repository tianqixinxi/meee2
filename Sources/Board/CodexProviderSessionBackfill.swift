import Foundation

enum CodexProviderSessionBackfill {
    private struct Candidate {
        let id: String
        let cwd: String
        let timestamp: Date
    }

    private enum ResumeIdCacheEntry {
        case hit(String)
        case miss
    }

    private struct CandidateDirectoryCacheEntry {
        let loadedAt: Date
        let candidates: [Candidate]
    }

    private static let cacheLock = NSLock()
    private static let candidateCacheTTL: TimeInterval = 15
    private static let sessionMetaReadLimit = 256 * 1024
    private static var cachedBySessionId: [String: ResumeIdCacheEntry] = [:]
    private static var cachedCandidatesByDirectory: [String: CandidateDirectoryCacheEntry] = [:]
    private static var cachedKnownProviderSessionIds: [String: Bool] = [:]

    /// Checks the Codex rollout index by filename, which is authoritative even
    /// when a stale managed-surface record was later mislabeled as Claude.
    static func isKnownProviderSessionId(
        _ rawSessionId: String,
        sessionsRoot overrideRoot: URL? = nil
    ) -> Bool {
        let sessionId = rawSessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AgentLaunchCommand.isLikelyProviderResumeSessionId(sessionId) else { return false }

        if overrideRoot == nil {
            cacheLock.lock()
            if let cached = cachedKnownProviderSessionIds[sessionId] {
                cacheLock.unlock()
                return cached
            }
            cacheLock.unlock()
        }

        let root = overrideRoot ?? codexSessionsRoot()
        let suffix = "-\(sessionId).jsonl"
        let found = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )?.compactMap { $0 as? URL }.contains { url in
            url.lastPathComponent.lowercased().hasSuffix(suffix)
        } ?? false

        if overrideRoot == nil {
            cacheLock.lock()
            cachedKnownProviderSessionIds[sessionId] = found
            cacheLock.unlock()
        }
        return found
    }

    static func findAndPersistProviderResumeSessionId(
        sessionData: SessionData?,
        terminalInfo: SessionTerminalInfo?
    ) -> String? {
        guard let resolved = findProviderResumeSessionId(
            sessionData: sessionData,
            terminalInfo: terminalInfo
        ) else {
            return nil
        }
        let sessionId = sessionData?.sessionId ?? terminalInfo?.sessionId ?? ""
        SessionTerminalStore.shared.setProviderResumeSessionId(
            sessionId: sessionId,
            providerResumeSessionId: resolved
        )
        return resolved
    }

    /// Resolves a provider resume id without mutating either session store.
    /// DTO construction uses this path so `/api/state` remains a pure read.
    static func findProviderResumeSessionId(
        sessionData: SessionData?,
        terminalInfo: SessionTerminalInfo?
    ) -> String? {
        let sessionId = sessionData?.sessionId ?? terminalInfo?.sessionId ?? ""
        guard !sessionId.isEmpty else { return nil }

        cacheLock.lock()
        if let cached = cachedBySessionId[sessionId] {
            cacheLock.unlock()
            switch cached {
            case let .hit(providerResumeSessionId):
                return providerResumeSessionId
            case .miss:
                return nil
            }
        }
        cacheLock.unlock()

        let resolved = inferProviderResumeSessionId(sessionData: sessionData, terminalInfo: terminalInfo)
        cacheLock.lock()
        cachedBySessionId[sessionId] = resolved.map(ResumeIdCacheEntry.hit) ?? .miss
        cacheLock.unlock()
        return resolved
    }

    private static func inferProviderResumeSessionId(
        sessionData: SessionData?,
        terminalInfo: SessionTerminalInfo?
    ) -> String? {
        for storedId in [sessionData?.providerResumeSessionId, terminalInfo?.providerResumeSessionId] {
            if let storedId, AgentLaunchCommand.isLikelyProviderResumeSessionId(storedId) {
                return storedId
            }
        }
        guard isCodexSession(sessionData: sessionData, terminalInfo: terminalInfo) else { return nil }
        for directId in [sessionData?.sessionId, terminalInfo?.sessionId] {
            if let directId, AgentLaunchCommand.isLikelyProviderResumeSessionId(directId) {
                return directId
            }
        }
        if let commandResumeId = extractResumeSessionId(from: terminalInfo?.command),
           AgentLaunchCommand.isLikelyProviderResumeSessionId(commandResumeId) {
            return commandResumeId
        }

        let cwd = (sessionData?.cwd ?? terminalInfo?.cwd ?? sessionData?.project)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cwd.isEmpty else { return nil }

        let anchor = sessionData?.startedAt ?? terminalInfo?.lastActivityAt ?? sessionData?.lastActivity ?? Date()
        let candidates = codexRolloutCandidates(around: anchor)
            .filter { $0.cwd == cwd }
            .map { ($0, abs($0.timestamp.timeIntervalSince(anchor))) }
            .filter { $0.1 <= 10 * 60 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.timestamp > rhs.0.timestamp
            }

        return candidates.first?.0.id
    }

    private static func extractResumeSessionId(from command: String?) -> String? {
        let raw = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"(?i)(?:^|[\s"'=])(?:--resume|resume)(?:[\s"'=]+)([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})"#
              ) else {
            return nil
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: raw) else {
            return nil
        }
        return String(raw[idRange])
    }

    private static func isCodexSession(sessionData: SessionData?, terminalInfo: SessionTerminalInfo?) -> Bool {
        let haystack = [
            sessionData?.sessionId,
            terminalInfo?.sessionId,
            terminalInfo?.provider,
            terminalInfo?.command,
            sessionData?.terminalInfo?.termProgram,
            sessionData?.terminalInfo?.jumpHandlerId
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("codex")
    }

    private static func codexRolloutCandidates(around anchor: Date) -> [Candidate] {
        rolloutSearchDirectories(around: anchor).flatMap { directory in
            cachedRolloutCandidates(in: directory)
        }
    }

    private static func cachedRolloutCandidates(in directory: URL) -> [Candidate] {
        let cacheKey = directory.path
        let now = Date()

        cacheLock.lock()
        if let cached = cachedCandidatesByDirectory[cacheKey],
           now.timeIntervalSince(cached.loadedAt) < candidateCacheTTL {
            cacheLock.unlock()
            return cached.candidates
        }
        cacheLock.unlock()

        let candidates = rolloutFiles(in: directory).compactMap(readCandidate)
        cacheLock.lock()
        cachedCandidatesByDirectory[cacheKey] = CandidateDirectoryCacheEntry(loadedAt: now, candidates: candidates)
        cacheLock.unlock()
        return candidates
    }

    private static func rolloutSearchDirectories(around anchor: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let root = codexSessionsRoot()
        return (-1...1).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: anchor) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }
            return root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
        }
    }

    private static func codexSessionsRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }

    private static func rolloutFiles(in directory: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func readCandidate(fileURL: URL) -> Candidate? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: sessionMetaReadLimit)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"type\":\"session_meta\""),
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  AgentLaunchCommand.isLikelyProviderResumeSessionId(id),
                  let cwd = payload["cwd"] as? String,
                  let timestampRaw = payload["timestamp"] as? String,
                  let timestamp = parseISO8601(timestampRaw) else {
                continue
            }
            return Candidate(id: id, cwd: cwd, timestamp: timestamp)
        }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

import Foundation

struct BoardPerfMetricDTO: Encodable {
    let id: String
    let title: String
    let category: String
    let count: Int
    let totalMs: Double
    let averageMs: Double?
    let p50Ms: Double?
    let p95Ms: Double?
    let maxMs: Double?
    let totalBytes: Int
    let lastDetail: String?
    let lastAt: String?
}

struct BoardPerfEventDTO: Encodable {
    let id: String
    let metricId: String
    let title: String
    let category: String
    let durationMs: Double?
    let bytes: Int?
    let detail: String?
    let at: String
}

struct BoardPerfSnapshotDTO: Encodable {
    let enabled: Bool
    let pid: Int
    let startedAt: String
    let capturedAt: String
    let metrics: [BoardPerfMetricDTO]
    let recentEvents: [BoardPerfEventDTO]
}

final class BoardPerfProbe: @unchecked Sendable {
    static let shared = BoardPerfProbe()

    private struct MetricBucket {
        var title: String
        var category: String
        var count: Int = 0
        var totalMs: Double = 0
        var maxMs: Double?
        var samplesMs: [Double] = []
        var totalBytes: Int = 0
        var lastDetail: String?
        var lastAt: Date?
    }

    private let lock = NSLock()
    private var startedAt = Date()
    private var metrics: [String: MetricBucket] = [:]
    private var recentEvents: [BoardPerfEventDTO] = []
    private let maxSamples = 240
    private let maxRecentEvents = 80

    private init() {}

    var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["MEEE2_PERF_PROBE"] == "1"
        #endif
    }

    @discardableResult
    func measure<T>(
        _ id: String,
        title: String,
        category: String,
        detail: String? = nil,
        bytes: Int? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        guard isEnabled else { return try body() }
        let started = Date()
        do {
            let value = try body()
            record(
                id,
                title: title,
                category: category,
                durationMs: Date().timeIntervalSince(started) * 1_000,
                bytes: bytes,
                detail: detail
            )
            return value
        } catch {
            record(
                id,
                title: title,
                category: category,
                durationMs: Date().timeIntervalSince(started) * 1_000,
                bytes: bytes,
                detail: [detail, "error=\(error.localizedDescription)"].compactMap { $0 }.joined(separator: " ")
            )
            throw error
        }
    }

    func recordEvent(
        _ id: String,
        title: String,
        category: String,
        detail: String? = nil,
        bytes: Int? = nil
    ) {
        guard isEnabled else { return }
        record(id, title: title, category: category, durationMs: nil, bytes: bytes, detail: detail)
    }

    func snapshot() -> BoardPerfSnapshotDTO {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let metricDTOs = metrics
            .map { id, bucket in
                let sorted = bucket.samplesMs.sorted()
                let average = bucket.count > 0 && bucket.totalMs > 0 ? bucket.totalMs / Double(bucket.count) : nil
                return BoardPerfMetricDTO(
                    id: id,
                    title: bucket.title,
                    category: bucket.category,
                    count: bucket.count,
                    totalMs: Self.rounded(bucket.totalMs),
                    averageMs: average.map(Self.rounded),
                    p50Ms: Self.percentile(sorted, 0.50).map(Self.rounded),
                    p95Ms: Self.percentile(sorted, 0.95).map(Self.rounded),
                    maxMs: bucket.maxMs.map(Self.rounded),
                    totalBytes: bucket.totalBytes,
                    lastDetail: bucket.lastDetail,
                    lastAt: bucket.lastAt.map(BoardDTOBuilder.iso)
                )
            }
            .sorted { lhs, rhs in
                if lhs.category == rhs.category { return lhs.title < rhs.title }
                return lhs.category < rhs.category
            }
        return BoardPerfSnapshotDTO(
            enabled: isEnabled,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            startedAt: BoardDTOBuilder.iso(startedAt),
            capturedAt: BoardDTOBuilder.iso(now),
            metrics: metricDTOs,
            recentEvents: recentEvents
        )
    }

    func reset() {
        lock.lock()
        startedAt = Date()
        metrics.removeAll()
        recentEvents.removeAll()
        lock.unlock()
    }

    private func record(
        _ id: String,
        title: String,
        category: String,
        durationMs: Double?,
        bytes: Int?,
        detail: String?
    ) {
        let now = Date()
        lock.lock()
        var bucket = metrics[id] ?? MetricBucket(title: title, category: category)
        bucket.title = title
        bucket.category = category
        bucket.count += 1
        if let durationMs {
            bucket.totalMs += durationMs
            bucket.maxMs = max(bucket.maxMs ?? durationMs, durationMs)
            bucket.samplesMs.append(durationMs)
            if bucket.samplesMs.count > maxSamples {
                bucket.samplesMs.removeFirst(bucket.samplesMs.count - maxSamples)
            }
        }
        if let bytes {
            bucket.totalBytes += bytes
        }
        bucket.lastDetail = detail
        bucket.lastAt = now
        metrics[id] = bucket

        recentEvents.append(BoardPerfEventDTO(
            id: UUID().uuidString,
            metricId: id,
            title: title,
            category: category,
            durationMs: durationMs.map(Self.rounded),
            bytes: bytes,
            detail: detail,
            at: BoardDTOBuilder.iso(now)
        ))
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
        }
        lock.unlock()
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let clamped = max(0, min(1, percentile))
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}

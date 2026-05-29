import Foundation
import Combine

/// 监控 Claude Code 跨 session 的 input / output token 累计并按时间窗口算速率。
/// 数据来自 ClaudePlugin 的 sessionUsage——每条 assistant 消息被 TranscriptParser 解析时
/// 累加进去。这里只做"周期采样 + 差分 + 滑动窗口"。
///
/// 三档窗口 × 两种 token：
/// - `rateMinIn / rateMinOut` —— 最近 60 秒
/// - `rateHourIn / rateHourOut` —— 最近 3600 秒
/// - `rateDayIn / rateDayOut` —— 最近 86400 秒
///
/// 关键设计：
/// 1. **Lifetime counter**：内部维护 `lifetimeIn / lifetimeOut` 单调递增计数器，
///    每次 tick 把"真实增量"加进来。Spike 检测（一次 tick 增量 > maxDeltaPerSecond
///    认为是 lazy-load fill）防止启动瞬间几百万 cache token 一次性塞进来污染速率。
///    多个 session 同 tick 一起 fill 也会被吸收。
/// 2. **磁盘持久化**：`~/.meee2/token-rate-history.json` 保存 lifetime counter +
///    coarse buffer（最近 ~25h 的 1/min 样本）。重启后 `1d` 窗口立刻能用，
///    不需要等 24h。`1m / 1h` 在重启后头 1h 内会偏低（recent buffer 是冷启的）。
public final class TokenRateMonitor: ObservableObject {
    // MARK: - Published rates

    @Published public private(set) var rateMinIn: Double = 0
    @Published public private(set) var rateHourIn: Double = 0
    @Published public private(set) var rateDayIn: Double = 0

    @Published public private(set) var rateMinOut: Double = 0
    @Published public private(set) var rateHourOut: Double = 0
    @Published public private(set) var rateDayOut: Double = 0

    @Published public private(set) var totalIn: Int = 0
    @Published public private(set) var totalOut: Int = 0

    // MARK: - Input

    public typealias TokensSnapshot = (input: Int, output: Int)
    private let tokensProvider: () -> TokensSnapshot

    // MARK: - State

    /// 历史累计——单调递增、跨重启持久化。每次 tick 把过滤后的真实增量加进来。
    private var lifetimeIn: Int = 0
    private var lifetimeOut: Int = 0

    /// 上一次 tick 看到的 raw，用于差分。
    private var lastRaw: TokensSnapshot?
    /// 真实增量超过这个阈值（tokens/s）认为是 fill spike，不算速率。
    /// Claude API 单 session < 10k tok/s，多 session 合计也很少 > 50k。
    private let maxDeltaPerSecond: Int = 50_000

    // MARK: - Sample buffers

    private struct Sample { let t: Date; let cumIn: Int; let cumOut: Int }
    private var recent: [Sample] = []           // 1Hz, ~1h, 不持久化
    private let recentMax: Int = 3700
    private var coarse: [Sample] = []           // 1/min, ~25h, 持久化
    private let coarseMax: Int = 1500
    private var lastCoarseAt: Date?

    private var timer: Timer?
    private var lastSaveAt: Date?
    /// 至少这么久才落盘一次，避免每秒写文件。60s 跟 coarse 采样节奏对齐。
    private let saveInterval: TimeInterval = 60

    // MARK: - Init

    public init(tokensProvider: @escaping () -> TokensSnapshot) {
        self.tokensProvider = tokensProvider
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    public func start() {
        // start 必须幂等：第二次进来不能再 loadFromDisk（会读到自己写的中间态没事，
        // 但更重要的是不能在 loadFromDisk 之前触发 stop() 的 saveToDisk，否则会用
        // 启动前未加载的 (0,0) 覆盖磁盘 baseline。这就是上一版的 bug 根因。
        guard timer == nil else { return }
        loadFromDisk()
        tick()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        saveToDisk()
    }

    // MARK: - Testing

    /// 直接塞一笔"真实增量"，绕开 spike 过滤——给单元测试用。
    public func ingestForTesting(deltaIn: Int, deltaOut: Int, at date: Date = Date()) {
        lifetimeIn += max(0, deltaIn)
        lifetimeOut += max(0, deltaOut)
        appendSample(at: date)
        recomputeRates()
    }

    // MARK: - Internals

    private func tick() {
        let now = Date()
        let raw = tokensProvider()

        if let prev = lastRaw {
            let dIn = max(0, raw.input - prev.input)
            let dOut = max(0, raw.output - prev.output)
            // Spike 检测：tick 间隔约 1s，所以单次增量直接当 tok/s 比。
            if dIn + dOut <= maxDeltaPerSecond {
                lifetimeIn += dIn
                lifetimeOut += dOut
            }
        }
        lastRaw = raw

        appendSample(at: now)
        recomputeRates()
        maybeSave(at: now)
    }

    private func appendSample(at date: Date) {
        let s = Sample(t: date, cumIn: lifetimeIn, cumOut: lifetimeOut)

        recent.append(s)
        if recent.count > recentMax {
            recent.removeFirst(recent.count - recentMax)
        }

        if let last = lastCoarseAt, date.timeIntervalSince(last) < 60 {
            return
        }
        coarse.append(s)
        if coarse.count > coarseMax {
            coarse.removeFirst(coarse.count - coarseMax)
        }
        lastCoarseAt = date
    }

    private func recomputeRates() {
        guard let latest = recent.last else { return }
        let rMinIn = rate(over: 60, in: recent, keyPath: \.cumIn)
        let rMinOut = rate(over: 60, in: recent, keyPath: \.cumOut)
        let rHourIn = rate(over: 3600, in: recent, keyPath: \.cumIn)
        let rHourOut = rate(over: 3600, in: recent, keyPath: \.cumOut)

        // 1d 优先用 coarse（持久化、跨重启），coarse 只有一笔时回退 recent。
        let dayBuf = coarse.count >= 2 ? coarse : recent
        let rDayIn = rate(over: 86400, in: dayBuf, keyPath: \.cumIn)
        let rDayOut = rate(over: 86400, in: dayBuf, keyPath: \.cumOut)

        let tIn = latest.cumIn
        let tOut = latest.cumOut

        let apply: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.totalIn = tIn
            self.totalOut = tOut
            self.rateMinIn = rMinIn
            self.rateMinOut = rMinOut
            self.rateHourIn = rHourIn
            self.rateHourOut = rHourOut
            self.rateDayIn = rDayIn
            self.rateDayOut = rDayOut
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func rate(over window: TimeInterval, in buffer: [Sample], keyPath: KeyPath<Sample, Int>) -> Double {
        guard let latest = buffer.last, let first = buffer.first else { return 0 }
        let cutoff = latest.t.addingTimeInterval(-window)
        var baseline: Sample = first
        for sample in buffer.reversed() where sample.t <= cutoff {
            baseline = sample
            break
        }
        let dt = latest.t.timeIntervalSince(baseline.t)
        guard dt > 0 else { return 0 }
        let d = max(0, latest[keyPath: keyPath] - baseline[keyPath: keyPath])
        return Double(d) / dt
    }

    // MARK: - Persistence

    private struct PersistedSample: Codable {
        let t: TimeInterval  // unix epoch
        let i: Int
        let o: Int
    }

    private struct PersistedState: Codable {
        let version: Int
        let lifetimeIn: Int
        let lifetimeOut: Int
        let coarse: [PersistedSample]
    }

    private static var stateURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2")
            .appendingPathComponent("token-rate-history.json")
    }

    private func loadFromDisk() {
        let url = Self.stateURL
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == 1 else { return }

        // 历史 lifetime counter 恢复——后续 delta 在它上面继续累加。
        lifetimeIn = max(0, state.lifetimeIn)
        lifetimeOut = max(0, state.lifetimeOut)

        // 只保留最近 25h 的 coarse 样本，过老的扔掉。
        let cutoff = Date().timeIntervalSince1970 - 25 * 3600
        let recovered: [Sample] = state.coarse
            .filter { $0.t >= cutoff }
            .map { Sample(t: Date(timeIntervalSince1970: $0.t), cumIn: $0.i, cumOut: $0.o) }
            .sorted { $0.t < $1.t }

        coarse = recovered
        if coarse.count > coarseMax {
            coarse.removeFirst(coarse.count - coarseMax)
        }
        lastCoarseAt = coarse.last?.t
    }

    private func maybeSave(at now: Date) {
        if let last = lastSaveAt, now.timeIntervalSince(last) < saveInterval { return }
        saveToDisk()
        lastSaveAt = now
    }

    private func saveToDisk() {
        let state = PersistedState(
            version: 1,
            lifetimeIn: lifetimeIn,
            lifetimeOut: lifetimeOut,
            coarse: coarse.map { PersistedSample(t: $0.t.timeIntervalSince1970, i: $0.cumIn, o: $0.cumOut) }
        )
        let url = Self.stateURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

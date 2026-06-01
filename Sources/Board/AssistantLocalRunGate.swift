import Foundation

/// Defensive backstop against the recap-respawn storm.
///
/// The canvas "AI 回顾" recap spawns a `claude -p` headless run via
/// `LocalClaudeProvider`. A failing recap used to re-trigger from the frontend
/// on every `/api/state` poll, and each spawn churned hook ingestion + the
/// continuity-record rekey → the board HTTP server + main thread starved → the
/// app froze (needs `kill -9`).
///
/// Independent of the frontend fix, the spawn path MUST NOT be able to run
/// unbounded in a tight loop. This gate enforces, per canvas key:
///   • **max-in-flight = 1** — never spawn a second local run for a canvas
///     while one is already running;
///   • **cooldown** — after a run finishes, refuse a new run for `cooldown`
///     seconds, so even a fast fail→retry→fail cycle is rate-capped.
///
/// A rejected run surfaces as a normal "busy / cooling down" error to the
/// caller (the recap just shows its local baseRecap), never as a crash or a
/// silent spin. Legitimate recap generation is unaffected: it runs once, the
/// cooldown (seconds) is far below the recap interval (minutes).
final class AssistantLocalRunGate {
    static let shared = AssistantLocalRunGate()

    struct Lease {
        fileprivate let gate: AssistantLocalRunGate
        fileprivate let key: String
        private var released = false

        fileprivate init(gate: AssistantLocalRunGate, key: String) {
            self.gate = gate
            self.key = key
        }

        /// Release the in-flight slot and stamp the cooldown clock. Idempotent.
        mutating func release() {
            guard !released else { return }
            released = true
            gate.finish(key: key)
        }
    }

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var lastFinishedAt: [String: Date] = [:]
    private let cooldown: TimeInterval
    private let now: () -> Date

    /// `cooldown` defaults to 8s: comfortably longer than a hook/state churn
    /// cycle (a few seconds) so a failing recap can't re-spawn back-to-back,
    /// yet far below the minutes-scale recap interval so real recaps run.
    init(cooldown: TimeInterval = 8, now: @escaping () -> Date = Date.init) {
        self.cooldown = cooldown
        self.now = now
    }

    /// Try to acquire a run slot for `key` (a canvas key). Returns a `Lease` on
    /// success, or `nil` when a run is already in flight or the cooldown after
    /// the last run has not elapsed. Caller must `release()` the lease when the
    /// run finishes (success OR failure).
    func acquire(key rawKey: String) -> Lease? {
        let key = normalizedKey(rawKey)
        lock.lock()
        defer { lock.unlock() }

        if inFlight.contains(key) { return nil }
        if let last = lastFinishedAt[key], now().timeIntervalSince(last) < cooldown {
            return nil
        }
        inFlight.insert(key)
        return Lease(gate: self, key: key)
    }

    private func finish(key: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(key)
        lastFinishedAt[key] = now()
    }

    /// Test hook: clear all state.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        inFlight.removeAll()
        lastFinishedAt.removeAll()
    }

    private func normalizedKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "global" : trimmed
    }
}

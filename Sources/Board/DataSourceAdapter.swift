import Foundation

// MARK: - DataSource adapter (canvas-runtime-data-model.md §3.8 / §3.x)
//
// PR6+7 — make the DataSource atom *function* on the local Swift store. An
// adapter is the runtime backing for a `DataSourceRecord.kind`:
//
//   • `managed` → `ManagedAdapter`  (in-memory / local store backing)
//   • `fs`      → `LocalFsAdapter`  (file:// dir sources; local-only per the
//                                    v1 decision — no remote fs in this PR)
//
// The adapter exposes the read/write surface a node attempt needs, plus the
// queue-claim state machine from §3.8:
//
//     ready ──claim──▶ claimed ──markInProgress──▶ in-progress ──markDone──▶ done
//
// Scope: minimal but correct. The managed adapter keeps queue items in memory
// keyed by `(sourceId, itemId)`; the fs adapter enumerates a directory and
// claims files by atomic rename into a `.claimed/` sidecar so two attempts
// can't grab the same file. Freshness probing is best-effort.

// MARK: - State machine

/// Lifecycle of one claimable item in a queue-claimable DataSource (§3.8).
enum DataSourceItemState: String, Codable, Equatable {
    case ready
    case claimed
    case inProgress = "in-progress"
    case done
}

/// One item surfaced by a queue-claimable source.
struct DataSourceItem: Codable, Equatable {
    var itemId: String
    var state: DataSourceItemState
    /// Opaque payload reference (path / blob ref / inline marker).
    var ref: String
    /// Claimant attempt key (causalKey) while claimed / in-progress.
    var claimedBy: String?
    var claimedAt: Date?

    init(itemId: String, state: DataSourceItemState = .ready, ref: String,
         claimedBy: String? = nil, claimedAt: Date? = nil) {
        self.itemId = itemId
        self.state = state
        self.ref = ref
        self.claimedBy = claimedBy
        self.claimedAt = claimedAt
    }
}

/// Result of a freshness probe (§3.1 FreshnessPolicy).
struct DataSourceFreshness: Equatable {
    /// Current version per the source's version strategy (monotonic for managed).
    var currentVersion: Int
    /// Opaque cursor for incremental sources (etag / mtime). nil ⇒ unsupported.
    var cursorOpaque: String?
    /// Wall-clock of the probe.
    var probedAt: Date
}

enum DataSourceAdapterError: Error, LocalizedError {
    case unsupportedCapability(String)
    case itemNotFound(String)
    case claimConflict(itemId: String, heldBy: String)
    case invalidPath(String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCapability(let cap): return "data source does not support \(cap)"
        case .itemNotFound(let id): return "queue item not found: \(id)"
        case .claimConflict(let id, let by): return "item \(id) already claimed by \(by)"
        case .invalidPath(let p): return "invalid source path: \(p)"
        case .ioFailure(let m): return m
        }
    }
}

// MARK: - Protocol

/// Backing runtime for a `DataSourceRecord`. Methods mirror §3.8's
/// `DataSourceOps`. All methods are synchronous + thread-safe per adapter.
protocol DataSourceAdapter: AnyObject {
    var source: DataSourceRecord { get }

    /// Write a new version (append-only). Returns the new version number.
    @discardableResult
    func write(version payload: BoardJSONValue?, ref: String?) throws -> Int

    /// Claim up to `n` ready items for `claimant` (the attempt causalKey).
    /// Returns the claimed items, now in `.claimed` state.
    func claim(n: Int, claimant: String) throws -> [DataSourceItem]

    /// Move a claimed item to `in-progress`.
    func markInProgress(itemId: String, claimant: String) throws

    /// Move a claimed / in-progress item to `done`.
    func markDone(itemId: String, claimant: String) throws

    /// Probe current freshness (version + cursor).
    func probeFreshness() throws -> DataSourceFreshness
}

// MARK: - ManagedAdapter (in-memory / local store backing)

/// `managed` source backing. Versions + queue items live in memory, guarded by
/// a lock. The store is the source of truth for `currentVersion`; this adapter
/// owns the *runtime* queue state for the duration of the process. Suitable for
/// local dev / E2E; durable persistence of queue items lands with the online
/// backend (out of scope for this PR).
final class ManagedAdapter: DataSourceAdapter {
    private(set) var source: DataSourceRecord
    private let lock = NSLock()
    private var items: [String: DataSourceItem]
    private var version: Int

    init(source: DataSourceRecord, seedItems: [DataSourceItem] = []) {
        self.source = source
        self.version = source.currentVersion
        self.items = Dictionary(uniqueKeysWithValues: seedItems.map { ($0.itemId, $0) })
    }

    /// Test / dispatch seam: inject ready items into the queue.
    func enqueue(_ item: DataSourceItem) {
        lock.lock(); defer { lock.unlock() }
        items[item.itemId] = item
    }

    /// canvas-spec §5/§10 (P3) · Align the adapter's in-memory version counter
    /// with the store's `currentVersion` after an output→source push advanced it
    /// on the record. Monotonic — never moves backwards. Keeps `probeFreshness()`
    /// consistent with the persisted `DataSource.currentVersion`.
    func syncVersion(to target: Int) {
        lock.lock(); defer { lock.unlock() }
        if target > version {
            version = target
            source.currentVersion = target
        }
    }

    /// Number of items currently in `.ready` state (queue depth not yet
    /// claimed). Used by the monitor `queue-depth` card + regression tests.
    func readyDepth() -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.values.filter { $0.state == .ready }.count
    }

    /// Snapshot of one item's current state (test / inspection seam).
    func item(_ itemId: String) -> DataSourceItem? {
        lock.lock(); defer { lock.unlock() }
        return items[itemId]
    }

    @discardableResult
    func write(version payload: BoardJSONValue?, ref: String?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        version += 1
        source.currentVersion = version
        return version
    }

    func claim(n: Int, claimant: String) throws -> [DataSourceItem] {
        guard source.capabilities.queueClaimable else {
            throw DataSourceAdapterError.unsupportedCapability("queue-claim")
        }
        lock.lock(); defer { lock.unlock() }
        let ready = items.values
            .filter { $0.state == .ready }
            .sorted { $0.itemId < $1.itemId }
            .prefix(max(0, n))
        var claimed: [DataSourceItem] = []
        for var item in ready {
            item.state = .claimed
            item.claimedBy = claimant
            item.claimedAt = Date()
            items[item.itemId] = item
            claimed.append(item)
        }
        return claimed
    }

    func markInProgress(itemId: String, claimant: String) throws {
        try transition(itemId: itemId, claimant: claimant, to: .inProgress)
    }

    func markDone(itemId: String, claimant: String) throws {
        try transition(itemId: itemId, claimant: claimant, to: .done)
    }

    private func transition(itemId: String, claimant: String, to target: DataSourceItemState) throws {
        lock.lock(); defer { lock.unlock() }
        guard var item = items[itemId] else { throw DataSourceAdapterError.itemNotFound(itemId) }
        if let holder = item.claimedBy, holder != claimant {
            throw DataSourceAdapterError.claimConflict(itemId: itemId, heldBy: holder)
        }
        item.state = target
        items[itemId] = item
    }

    func probeFreshness() throws -> DataSourceFreshness {
        lock.lock(); defer { lock.unlock() }
        return DataSourceFreshness(currentVersion: version, cursorOpaque: nil, probedAt: Date())
    }
}

// MARK: - LocalFsAdapter (file:// dir sources, local-only)

/// `fs` source backing. Treats `pathPattern` as a local directory. Files in the
/// dir are queue items; claiming atomically renames a file into a `.claimed/`
/// sidecar so concurrent attempts can't double-claim. `markDone` moves the file
/// to `.done/`. Freshness = dir mtime + file count. Local-only by the v1 fs
/// decision — no remote/networked filesystems here.
final class LocalFsAdapter: DataSourceAdapter {
    private(set) var source: DataSourceRecord
    private let root: URL
    private let lock = NSLock()
    private let fm = FileManager.default

    init(source: DataSourceRecord, baseDirectory: URL) throws {
        self.source = source
        // selector 的 declarative expr(旧 pathPattern)relative to the canvas
        // workspace base;为空时退回 source.id。
        let pattern = source.pathHint
        self.root = baseDirectory.appendingPathComponent(pattern, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".claimed"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".done"), withIntermediateDirectories: true)
    }

    @discardableResult
    func write(version payload: BoardJSONValue?, ref: String?) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        // Append a new file as the new version's content. The version number is
        // the count of top-level files (sequence strategy).
        let name = ref ?? "v-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        let dest = root.appendingPathComponent(name)
        let data: Data
        if let payload { data = (try? JSONEncoder().encode(payload)) ?? Data() } else { data = Data() }
        do { try data.write(to: dest) } catch { throw DataSourceAdapterError.ioFailure(error.localizedDescription) }
        source.currentVersion = try topLevelFileCount()
        return source.currentVersion
    }

    func claim(n: Int, claimant: String) throws -> [DataSourceItem] {
        guard source.capabilities.queueClaimable else {
            throw DataSourceAdapterError.unsupportedCapability("queue-claim")
        }
        lock.lock(); defer { lock.unlock() }
        let ready = try readyFiles().sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(max(0, n))
        var claimed: [DataSourceItem] = []
        for url in ready {
            let claimedURL = root.appendingPathComponent(".claimed").appendingPathComponent(url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: claimedURL)
            } catch {
                // Lost the race — another claimant grabbed it. Skip.
                continue
            }
            claimed.append(DataSourceItem(
                itemId: url.lastPathComponent,
                state: .claimed,
                ref: claimedURL.path,
                claimedBy: claimant,
                claimedAt: Date()
            ))
        }
        return claimed
    }

    func markInProgress(itemId: String, claimant: String) throws {
        // fs adapter: claimed files are already off the ready queue; in-progress
        // is an in-memory distinction only (the file stays in .claimed/).
        let claimedURL = root.appendingPathComponent(".claimed").appendingPathComponent(itemId)
        guard fm.fileExists(atPath: claimedURL.path) else {
            throw DataSourceAdapterError.itemNotFound(itemId)
        }
    }

    func markDone(itemId: String, claimant: String) throws {
        lock.lock(); defer { lock.unlock() }
        let claimedURL = root.appendingPathComponent(".claimed").appendingPathComponent(itemId)
        let doneURL = root.appendingPathComponent(".done").appendingPathComponent(itemId)
        guard fm.fileExists(atPath: claimedURL.path) else {
            throw DataSourceAdapterError.itemNotFound(itemId)
        }
        do {
            try fm.moveItem(at: claimedURL, to: doneURL)
        } catch {
            throw DataSourceAdapterError.ioFailure(error.localizedDescription)
        }
    }

    func probeFreshness() throws -> DataSourceFreshness {
        lock.lock(); defer { lock.unlock() }
        let attrs = try? fm.attributesOfItem(atPath: root.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
        return DataSourceFreshness(
            currentVersion: (try? topLevelFileCount()) ?? source.currentVersion,
            cursorOpaque: ISO8601DateFormatter().string(from: mtime),
            probedAt: Date()
        )
    }

    private func readyFiles() throws -> [URL] {
        let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return contents.filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private func topLevelFileCount() throws -> Int {
        try readyFiles().count
    }
}

// MARK: - Bridge surface

/// Local execution-path entry points for the queue-claim state machine (§3.8).
/// Adapters are created on demand from a canvas's `DataSourceRecord`. The
/// managed registry is process-local; fs adapters resolve against the canvas
/// workspace dir. Exposed on `PlannerBoardBridge` so the dispatch / tool path
/// can drive claim → in-progress → done without reaching into the store.
extension PlannerBoardBridge {
    /// Process-local registry of managed adapters, keyed by `sourceId`, so
    /// queue state survives across calls within a run.
    private static var managedAdapters: [String: ManagedAdapter] {
        get { _managedAdaptersBox.value }
        set { _managedAdaptersBox.value = newValue }
    }

    /// Build (or fetch the cached) adapter for a source on a canvas.
    static func dataSourceAdapter(canvasId: String, sourceId: String) throws -> DataSourceAdapter {
        let record = try store.canvasRecordForBridge(canvasId: canvasId)
        guard let source = record.canvas.dataSources.first(where: { $0.id == sourceId }) else {
            throw PlannerCoreError.dataSourceNotFound(sourceId)
        }
        switch source.connectorKind {
        case "fs":
            let base = (try? BoardLayoutStore.shared.workspacePath(canvasId: canvasId))
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("meee2-fs-sources/\(canvasId)", isDirectory: true)
            return try LocalFsAdapter(source: source, baseDirectory: base)
        default: // "managed" and unknown kinds fall back to the managed backing.
            _managedAdaptersBox.lock.lock(); defer { _managedAdaptersBox.lock.unlock() }
            if let existing = _managedAdaptersBox.value[sourceId] { return existing }
            let adapter = ManagedAdapter(source: source)
            _managedAdaptersBox.value[sourceId] = adapter
            return adapter
        }
    }

    /// 读取某队列项的当前消费态(给 kanban 下游消费订阅派生用,只读)。
    /// 仅 managed 队列源支持;源/项不存在或非 managed → nil。
    static func dataSourceItemState(canvasId: String, sourceId: String, itemId: String) -> DataSourceItemState? {
        guard let managed = try? dataSourceAdapter(canvasId: canvasId, sourceId: sourceId) as? ManagedAdapter else {
            return nil
        }
        return managed.item(itemId)?.state
    }

    /// §3.8 claim: claim up to `n` items for the given attempt causalKey.
    static func dataSourceClaim(canvasId: String, sourceId: String, n: Int, claimant: String) throws -> [DataSourceItem] {
        try dataSourceAdapter(canvasId: canvasId, sourceId: sourceId).claim(n: n, claimant: claimant)
    }

    /// §3.8 markInProgress: advance a claimed item to `in-progress`.
    static func dataSourceMarkInProgress(canvasId: String, sourceId: String, itemId: String, claimant: String) throws {
        try dataSourceAdapter(canvasId: canvasId, sourceId: sourceId).markInProgress(itemId: itemId, claimant: claimant)
    }

    /// §3.8 markDone: complete a claimed item.
    static func dataSourceMarkDone(canvasId: String, sourceId: String, itemId: String, claimant: String) throws {
        try dataSourceAdapter(canvasId: canvasId, sourceId: sourceId).markDone(itemId: itemId, claimant: claimant)
    }

    /// canvas-spec §5/§10 (P3) · `claim_from_source` for a consumer node. The
    /// consumer reaches its upstream pool through a `queue-claim` edge whose
    /// `targetRef.nodeId == consumerNodeId` and whose `sourceRef.dataSourceId`
    /// names the DataSource the producer pushed into. We resolve that edge,
    /// determine claim count from the edge's strategy (claim-one ⇒ 1,
    /// claim-batch ⇒ n, claim-all-unclaimed ⇒ large), and claim ready items.
    /// Returns the claimed items (now `.claimed`) plus the resolved sourceId so
    /// the caller can later `mark_source_item_done`.
    static func claimFromSourceForConsumer(
        canvasId: String,
        consumerNodeId: String,
        claimant: String
    ) throws -> (sourceId: String, items: [DataSourceItem]) {
        let record = try store.canvasRecordForBridge(canvasId: canvasId)
        guard let edge = record.canvas.edges.first(where: { edge in
            edge.targetRef.nodeId == consumerNodeId
                && edge.edgeMode.mode == "queue-claim"
                && (edge.sourceRef.dataSourceId?.isEmpty == false)
        }), let sourceId = edge.sourceRef.dataSourceId else {
            throw PlannerCoreError.dataSourceNotFound("no queue-claim edge with a bound source for node \(consumerNodeId)")
        }
        let n: Int
        switch edge.edgeMode.strategy?.kind {
        case "claim-batch": n = edge.edgeMode.strategy?.n ?? 1
        case "claim-all-unclaimed": n = Int.max
        default: n = 1 // claim-one (default)
        }
        let items = try dataSourceClaim(canvasId: canvasId, sourceId: sourceId, n: n, claimant: claimant)
        return (sourceId, items)
    }
}

/// Lock-guarded box for the process-local managed adapter registry. Declared at
/// file scope because stored properties can't live in an extension.
final class _ManagedAdapterBox {
    let lock = NSLock()
    var value: [String: ManagedAdapter] = [:]
}
let _managedAdaptersBox = _ManagedAdapterBox()

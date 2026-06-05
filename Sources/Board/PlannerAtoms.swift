import Foundation

// MARK: - Canvas Runtime 5-Atom Data Model — DECODE-ONLY Swift twins
//
// Swift mirrors of the contract-v3 entity types introduced by the canvas
// runtime 5-atom data model (`doc/prd/canvas-runtime-data-model.md` +
// `…-skill-addendum.md`). The TS contract is the source of truth; these
// structs match the JSON wire shape (camelCase) emitted to
// `meee2-online/src/planner-runtime/contract/contract.generated.json`.
//
// ⚠️ PR2+6.5 scope: these are **decode-tolerant mirrors only**. They are NOT
// consumed by apply / proposal-execution logic yet (that is a later PR). Every
// field that the contract marks optional / defaulted decodes via
// `decodeIfPresent` with a legacy default so that BOTH legacy persisted data
// (which lacks all of these keys) and new data round-trip without throwing.
//
// Discriminated unions (`TriggerOrigin`, `EdgeMode`, `MonitorCard`,
// version/strategy unions) follow the codebase convention of decoding the
// `kind`/`mode`/`type` discriminator first, then the variant payload. For the
// open unions (`EdgeMode`, `MonitorCard`) an unknown discriminator decodes into
// a forward-compat case that preserves the raw discriminator string rather than
// throwing — matching the Zod `ForwardCompatMode` round-trip guarantee (§4.2).

// MARK: - Shared small types

/// Open-ended JSON-ish value reuse. The atoms carry several `z.unknown()` /
/// `z.record()` fields (filter `value`, card config) that we keep as
/// `BoardJSONValue` so they round-trip without imposing a premature schema.
typealias PlannerAtomJSON = BoardJSONValue

/// `EdgeFilterClause` (§4.1). `value` is `z.unknown()`.
struct EdgeFilterClause: Codable, Equatable {
    var field: String
    var op: String
    var value: PlannerAtomJSON?
}

/// `EdgeFilter` (§4.1).
struct EdgeFilter: Codable, Equatable {
    var clauses: [EdgeFilterClause]
    /// `'and' | 'or'`, default `'and'`.
    var combinator: String

    enum CodingKeys: String, CodingKey { case clauses, combinator }

    init(clauses: [EdgeFilterClause] = [], combinator: String = "and") {
        self.clauses = clauses
        self.combinator = combinator
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clauses = try c.decodeIfPresent([EdgeFilterClause].self, forKey: .clauses) ?? []
        combinator = try c.decodeIfPresent(String.self, forKey: .combinator) ?? "and"
    }
}

// MARK: - Atom 1 · DataSource (§3.1)

/// `PartitionRule` (§3.1). Stored as String for forward-compat with new rules.
/// Contract enum: `none | iso-week | day | month | fiscal-quarter | custom`.
struct DataSourceCapabilities: Codable, Equatable {
    var documentReadable: Bool
    var listEnumerable: Bool
    var queueClaimable: Bool
    var appendOnly: Bool
    var externallyMutable: Bool
    var schemaTyped: Bool

    enum CodingKeys: String, CodingKey {
        case documentReadable, listEnumerable, queueClaimable
        case appendOnly, externallyMutable, schemaTyped
    }

    init(
        documentReadable: Bool = false,
        listEnumerable: Bool = false,
        queueClaimable: Bool = false,
        appendOnly: Bool = false,
        externallyMutable: Bool = false,
        schemaTyped: Bool = false
    ) {
        self.documentReadable = documentReadable
        self.listEnumerable = listEnumerable
        self.queueClaimable = queueClaimable
        self.appendOnly = appendOnly
        self.externallyMutable = externallyMutable
        self.schemaTyped = schemaTyped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentReadable = try c.decodeIfPresent(Bool.self, forKey: .documentReadable) ?? false
        listEnumerable = try c.decodeIfPresent(Bool.self, forKey: .listEnumerable) ?? false
        queueClaimable = try c.decodeIfPresent(Bool.self, forKey: .queueClaimable) ?? false
        appendOnly = try c.decodeIfPresent(Bool.self, forKey: .appendOnly) ?? false
        externallyMutable = try c.decodeIfPresent(Bool.self, forKey: .externallyMutable) ?? false
        schemaTyped = try c.decodeIfPresent(Bool.self, forKey: .schemaTyped) ?? false
    }
}

/// `VersionStrategy` discriminated union (§3.1). Tolerant: keeps the raw `kind`
/// plus the only payload field (`algo`) so unknown future kinds round-trip.
struct VersionStrategy: Codable, Equatable {
    /// `sequence | content-hash | external-etag | mtime`.
    var kind: String
    /// Only present for `content-hash` (`'sha256'`).
    var algo: String?

    enum CodingKeys: String, CodingKey { case kind, algo }

    init(kind: String = "sequence", algo: String? = nil) {
        self.kind = kind
        self.algo = algo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "sequence"
        algo = try c.decodeIfPresent(String.self, forKey: .algo)
    }
}

/// `FreshnessPolicy` (§3.1). `pollSeconds` is `int | null`.
struct FreshnessPolicy: Codable, Equatable {
    var pollSeconds: Int?
    var cursorOpaque: String?

    init(pollSeconds: Int? = nil, cursorOpaque: String? = nil) {
        self.pollSeconds = pollSeconds
        self.cursorOpaque = cursorOpaque
    }
}

/// `IntegrationBinding` (§3.1). Absent ⇒ managed source.
struct DataSourceIntegrationBinding: Codable, Equatable {
    var integrationId: String
    var entityKind: String
    var entityRef: String
}

/// `SourceIdentity` (addendum Part A) —— 共享真相键 `connectorKind` + `realm`。
/// `realm` 是「一套凭证 + 一次一致同步」能覆盖的最小单元;两个 DataSource 同
/// identity ⇒ 共享真相。取代旧单层 `kind`/`pathPattern` 里的 `kind` 维度。
struct SourceIdentity: Codable, Equatable {
    var connectorKind: String
    var realm: String

    enum CodingKeys: String, CodingKey { case connectorKind, realm }

    init(connectorKind: String = "managed", realm: String = "") {
        self.connectorKind = connectorKind
        self.realm = realm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectorKind = try c.decodeIfPresent(String.self, forKey: .connectorKind) ?? "managed"
        realm = try c.decodeIfPresent(String.self, forKey: .realm) ?? ""
    }
}

/// `MemberRef` —— curated selector 的单个成员(某物理源里的一个单元,可跨 identity)。
struct MemberRef: Codable, Equatable {
    var identity: SourceIdentity
    var ref: String
}

/// `Selector` discriminated union (addendum Part A §4.1)。两种成员求值模式:
///  - `declarative`:规则(`dialect` + `expr`),connector 机械求值 + 静态求交。
///  - `curated`:AI session 物化成员集(可跨源),非同构 / 语义聚合。
/// 沿用本文件 `EdgeMode` 的容忍式 struct 惯例(keyed by `mode`),未知 mode 也 round-trip。
struct Selector: Codable, Equatable {
    /// `declarative | curated | <forward-compat>`.
    var mode: String
    // declarative
    var dialect: String?
    var expr: String?
    // curated
    var curatorSessionId: String?
    var members: [MemberRef]?
    var intent: String?
    /// curated `shapeSchema` —— AI 定义的形状,引擎对其 opaque(`z.unknown()`)。
    var shapeSchema: PlannerAtomJSON?

    enum CodingKeys: String, CodingKey {
        case mode, dialect, expr, curatorSessionId, members, intent, shapeSchema
    }

    init(
        mode: String = "declarative",
        dialect: String? = nil,
        expr: String? = nil,
        curatorSessionId: String? = nil,
        members: [MemberRef]? = nil,
        intent: String? = nil,
        shapeSchema: PlannerAtomJSON? = nil
    ) {
        self.mode = mode
        self.dialect = dialect
        self.expr = expr
        self.curatorSessionId = curatorSessionId
        self.members = members
        self.intent = intent
        self.shapeSchema = shapeSchema
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "declarative"
        dialect = try c.decodeIfPresent(String.self, forKey: .dialect)
        expr = try c.decodeIfPresent(String.self, forKey: .expr)
        curatorSessionId = try c.decodeIfPresent(String.self, forKey: .curatorSessionId)
        members = try c.decodeIfPresent([MemberRef].self, forKey: .members)
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        shapeSchema = try c.decodeIfPresent(PlannerAtomJSON.self, forKey: .shapeSchema)
    }

    /// declarative 便捷构造。
    static func declarative(dialect: String, expr: String) -> Selector {
        Selector(mode: "declarative", dialect: dialect, expr: expr)
    }
}

/// `Semantics` (addendum Part G §10.2) —— 每个原子的语义层(给 agent 治理 + UI 读)。
/// DataSource 用 `label` 收编旧 `title`。
struct Semantics: Codable, Equatable {
    /// 业务名(= UI title)。
    var label: String
    /// 为什么存在 / 职责(可选)。
    var purpose: String?

    enum CodingKeys: String, CodingKey { case label, purpose }

    init(label: String = "", purpose: String? = nil) {
        self.label = label
        self.purpose = purpose
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
    }
}

/// Atom 1 — `DataSource` (§3.1 + addendum Part A/G). The named addressable
/// location artifacts live at. `identity`(共享真相键)+ `selector`(成员求值)
/// 取代旧 `kind`/`pathPattern`;`semantics.label` 收编旧 `title`。Governance-layer
/// object;此处 decode-tolerant,并把 on-disk 旧形状合成成新形状(平滑升级)。
struct DataSourceRecord: Codable, Equatable {
    var id: String
    var canvasId: String
    /// addendum Part A —— 共享真相键(connectorKind + realm),取代旧 `kind`。
    var identity: SourceIdentity
    /// addendum Part A —— 成员求值(declarative 规则 / curated 物化成员集),取代旧 `pathPattern`。
    var selector: Selector
    /// addendum Part G —— 语义层(`label` 收编旧 `title`)。
    var semantics: Semantics
    /// Stored as String for forward-compat. Default `'none'`.
    var partitionRule: String
    var partitionTimezone: String
    var capabilities: DataSourceCapabilities
    var versionStrategy: VersionStrategy
    var freshness: FreshnessPolicy
    /// Absent ⇒ managed.
    var binding: DataSourceIntegrationBinding?
    var currentVersion: Int
    var createdAt: String
    /// Fully qualified to survive timezone changes (§3.4).
    var lastPartitionKey: String?
    /// PR6+7: governance archive marker (§10.4). Swift-local apply-state flag —
    /// NOT in the TS `DataSource` contract, so a delegated sidecar apply strips
    /// it; `applyProposal` re-merges it by id after adopting the sidecar result.
    var archived: Bool

    enum CodingKeys: String, CodingKey {
        case id, canvasId, identity, selector, semantics, partitionRule
        case partitionTimezone, capabilities, versionStrategy, freshness
        case binding, currentVersion, createdAt, lastPartitionKey, archived
    }

    /// Pre-addendum on-disk keys (`kind`/`title`/`pathPattern`). Decode-only:
    /// legacy `state.json` 里的旧 DataSource 由它们合成 identity/selector/semantics。
    private enum LegacyCodingKeys: String, CodingKey {
        case kind, title, pathPattern
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        canvasId = try c.decode(String.self, forKey: .canvasId)
        // 新形状优先;`identity` 缺失 ⇒ 旧形状,合成 identity/selector/semantics。
        if let identity0 = try c.decodeIfPresent(SourceIdentity.self, forKey: .identity) {
            identity = identity0
            selector = try c.decodeIfPresent(Selector.self, forKey: .selector)
                ?? Selector.declarative(dialect: "", expr: "")
            semantics = try c.decodeIfPresent(Semantics.self, forKey: .semantics) ?? Semantics()
        } else {
            let lc = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let legacyKind = try lc.decodeIfPresent(String.self, forKey: .kind) ?? "managed"
            let legacyPath = try lc.decodeIfPresent(String.self, forKey: .pathPattern) ?? ""
            let legacyTitle = try lc.decodeIfPresent(String.self, forKey: .title) ?? ""
            identity = SourceIdentity(connectorKind: legacyKind, realm: "\(legacyKind):\(canvasId)")
            selector = Selector.declarative(dialect: legacyKind == "fs" ? "glob" : "path", expr: legacyPath)
            semantics = Semantics(label: legacyTitle)
        }
        partitionRule = try c.decodeIfPresent(String.self, forKey: .partitionRule) ?? "none"
        partitionTimezone = try c.decodeIfPresent(String.self, forKey: .partitionTimezone) ?? "UTC"
        capabilities = try c.decodeIfPresent(DataSourceCapabilities.self, forKey: .capabilities)
            ?? DataSourceCapabilities()
        versionStrategy = try c.decodeIfPresent(VersionStrategy.self, forKey: .versionStrategy)
            ?? VersionStrategy()
        freshness = try c.decodeIfPresent(FreshnessPolicy.self, forKey: .freshness)
            ?? FreshnessPolicy()
        binding = try c.decodeIfPresent(DataSourceIntegrationBinding.self, forKey: .binding)
        currentVersion = try c.decodeIfPresent(Int.self, forKey: .currentVersion) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        lastPartitionKey = try c.decodeIfPresent(String.self, forKey: .lastPartitionKey)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    /// Memberwise convenience used by the apply path and tests. Mirrors the
    /// decode defaults so callers don't have to thread every field.
    init(
        id: String,
        canvasId: String,
        identity: SourceIdentity = SourceIdentity(),
        selector: Selector = Selector.declarative(dialect: "", expr: ""),
        semantics: Semantics = Semantics(),
        partitionRule: String = "none",
        partitionTimezone: String = "UTC",
        capabilities: DataSourceCapabilities = DataSourceCapabilities(),
        versionStrategy: VersionStrategy = VersionStrategy(),
        freshness: FreshnessPolicy = FreshnessPolicy(),
        binding: DataSourceIntegrationBinding? = nil,
        currentVersion: Int = 0,
        createdAt: String = "",
        lastPartitionKey: String? = nil,
        archived: Bool = false
    ) {
        self.id = id
        self.canvasId = canvasId
        self.identity = identity
        self.selector = selector
        self.semantics = semantics
        self.partitionRule = partitionRule
        self.partitionTimezone = partitionTimezone
        self.capabilities = capabilities
        self.versionStrategy = versionStrategy
        self.freshness = freshness
        self.binding = binding
        self.currentVersion = currentVersion
        self.createdAt = createdAt
        self.lastPartitionKey = lastPartitionKey
        self.archived = archived
    }

    // MARK: Compat accessors —— 收敛 adapter / UI 对旧 `kind`/`title`/`pathPattern` 的读取。

    /// 旧 `kind`(= `identity.connectorKind`)。
    var connectorKind: String { identity.connectorKind }
    /// 旧 `title`(= `semantics.label`)。
    var label: String { semantics.label }
    /// declarative selector 的 `expr`(curated / 未知 mode ⇒ nil)。
    var declarativeExpr: String? { selector.mode == "declarative" ? selector.expr : nil }
    /// fs adapter 的相对路径提示:declarative `expr` 非空,否则退回 `id`。
    var pathHint: String {
        if let expr = declarativeExpr, !expr.isEmpty { return expr }
        return id
    }
}

// MARK: - Atom 2 · EdgeMode + Edge (§4.1)

/// `EdgeModeKind` (§4.1). The closed enum used by `EdgeConsumption.edgeMode`:
/// `document-snapshot | queue-claim`.
enum EdgeModeKind: String, Codable, Equatable {
    case documentSnapshot = "document-snapshot"
    case queueClaim = "queue-claim"
}

/// `document-snapshot` / `queue-claim` strategy discriminated union (§4.1).
/// Tolerant union: raw `kind` + all optional payload fields. Unknown kinds
/// round-trip via the raw `kind` string.
struct EdgeModeStrategy: Codable, Equatable {
    var kind: String
    /// document-snapshot `pin`.
    var version: String?
    /// document-snapshot `pin-at-attempt-start`.
    var resolveAt: String?
    /// queue-claim `claim-batch`.
    var n: Int?

    enum CodingKeys: String, CodingKey { case kind, version, resolveAt, n }

    init(kind: String, version: String? = nil, resolveAt: String? = nil, n: Int? = nil) {
        self.kind = kind
        self.version = version
        self.resolveAt = resolveAt
        self.n = n
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version)
        resolveAt = try c.decodeIfPresent(String.self, forKey: .resolveAt)
        n = try c.decodeIfPresent(Int.self, forKey: .n)
    }
}

/// queue-claim `lock` block (§4.1).
struct EdgeModeLock: Codable, Equatable {
    /// `exclusive | shared | none`, default `exclusive`.
    var kind: String
    var ttlSeconds: Int
    var requeueOnFailure: Bool

    enum CodingKeys: String, CodingKey { case kind, ttlSeconds, requeueOnFailure }

    init(kind: String = "exclusive", ttlSeconds: Int = 3600, requeueOnFailure: Bool = true) {
        self.kind = kind
        self.ttlSeconds = ttlSeconds
        self.requeueOnFailure = requeueOnFailure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "exclusive"
        ttlSeconds = try c.decodeIfPresent(Int.self, forKey: .ttlSeconds) ?? 3600
        requeueOnFailure = try c.decodeIfPresent(Bool.self, forKey: .requeueOnFailure) ?? true
    }
}

/// `EdgeMode` open union (§4.1): `DocumentSnapshotMode | QueueClaimMode |
/// ForwardCompatMode`. Modeled as one tolerant struct keyed by `mode` so an
/// unknown future mode (`stream-tail`, `sample-n`) round-trips intact without
/// the older runtime losing the field (§4.2 forward-compat guarantee).
struct EdgeMode: Codable, Equatable {
    /// `document-snapshot | queue-claim | <forward-compat>`.
    var mode: String
    /// document-snapshot / queue-claim.
    var strategy: EdgeModeStrategy?
    /// queue-claim ordering: `priority | fifo | lifo`.
    var ordering: String?
    /// queue-claim lock.
    var lock: EdgeModeLock?
    /// queue-claim `per-item | all-or-nothing`.
    var batchAtomicity: String?
    /// document-snapshot / queue-claim filter.
    var filter: EdgeFilter?
    /// ForwardCompatMode opaque payload (unknown modes).
    var payload: PlannerAtomJSON?

    enum CodingKeys: String, CodingKey {
        case mode, strategy, ordering, lock, batchAtomicity, filter, payload
    }

    init(
        mode: String,
        strategy: EdgeModeStrategy? = nil,
        ordering: String? = nil,
        lock: EdgeModeLock? = nil,
        batchAtomicity: String? = nil,
        filter: EdgeFilter? = nil,
        payload: PlannerAtomJSON? = nil
    ) {
        self.mode = mode
        self.strategy = strategy
        self.ordering = ordering
        self.lock = lock
        self.batchAtomicity = batchAtomicity
        self.filter = filter
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        strategy = try c.decodeIfPresent(EdgeModeStrategy.self, forKey: .strategy)
        ordering = try c.decodeIfPresent(String.self, forKey: .ordering)
        lock = try c.decodeIfPresent(EdgeModeLock.self, forKey: .lock)
        batchAtomicity = try c.decodeIfPresent(String.self, forKey: .batchAtomicity)
        filter = try c.decodeIfPresent(EdgeFilter.self, forKey: .filter)
        payload = try c.decodeIfPresent(PlannerAtomJSON.self, forKey: .payload)
    }
}

/// `Edge.sourceRef` (§4.1).
struct EdgeSourceRef: Codable, Equatable {
    var nodeId: String
    var sourceKey: String
    /// §5 — an edge endpoint can be a DataSource (not only a node slot). When
    /// set, the producer node's `(nodeId, sourceKey)` output slot pushes its
    /// submitted artifact into this DataSource (the intermediary pool), and a
    /// `queue-claim` edge's source is that pool. Absent ⇒ classic slot→slot.
    var dataSourceId: String?

    enum CodingKeys: String, CodingKey { case nodeId, sourceKey, dataSourceId }

    init(nodeId: String, sourceKey: String, dataSourceId: String? = nil) {
        self.nodeId = nodeId
        self.sourceKey = sourceKey
        self.dataSourceId = dataSourceId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        sourceKey = try c.decode(String.self, forKey: .sourceKey)
        dataSourceId = try c.decodeIfPresent(String.self, forKey: .dataSourceId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodeId, forKey: .nodeId)
        try c.encode(sourceKey, forKey: .sourceKey)
        try c.encodeIfPresent(dataSourceId, forKey: .dataSourceId)
    }
}

/// `Edge.targetRef` (§4.1).
struct EdgeTargetRef: Codable, Equatable {
    var nodeId: String
    var inputKey: String
    /// §5 — symmetric to `EdgeSourceRef.dataSourceId`: a DataSource may also be
    /// the *target* endpoint (a node writes into a pool). Reserved for the
    /// write-into-pool framing; the push path keys off `sourceRef.dataSourceId`.
    var dataSourceId: String?

    enum CodingKeys: String, CodingKey { case nodeId, inputKey, dataSourceId }

    init(nodeId: String, inputKey: String, dataSourceId: String? = nil) {
        self.nodeId = nodeId
        self.inputKey = inputKey
        self.dataSourceId = dataSourceId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        inputKey = try c.decode(String.self, forKey: .inputKey)
        dataSourceId = try c.decodeIfPresent(String.self, forKey: .dataSourceId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodeId, forKey: .nodeId)
        try c.encode(inputKey, forKey: .inputKey)
        try c.encodeIfPresent(dataSourceId, forKey: .dataSourceId)
    }
}

/// Unified `Artifact.source` (canvas-spec §7 — artifact-unified-model).
///
/// Swift twin of the contract `ArtifactSource` discriminated union. Folds the
/// legacy two-mode `artifactConfig.dataSource` (authored | mirrored) into the
/// unified data-origin model (the third duplicated representation collapsed,
/// after edges → Edge and skill → harness).
///
///  - `.slot(nodeId, slotKey, direction)`  the artifact is a node I/O slot. An
///        authored seed/source maps here with `direction == .output`.
///  - `.dataSource(sourceId)`              bound to a named/external DataSource
///        (managed / integration). Legacy `mirrored` maps here.
///  - `.canvasRuntime`                     whole-canvas runtime snapshot (Monitor).
///  - `.forwardCompat(rawKind)`            unknown discriminator — round-trips
///        rather than throwing (matches the codebase's open-union convention).
enum ArtifactSource: Codable, Equatable {
    case slot(nodeId: String, slotKey: String, direction: Direction)
    case dataSource(sourceId: String)
    case canvasRuntime
    case forwardCompat(rawKind: String)

    enum Direction: String, Codable, Equatable { case input, output }

    enum CodingKeys: String, CodingKey { case kind, nodeId, slotKey, direction, sourceId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "slot":
            self = .slot(
                nodeId: try c.decode(String.self, forKey: .nodeId),
                slotKey: try c.decode(String.self, forKey: .slotKey),
                direction: (try c.decodeIfPresent(Direction.self, forKey: .direction)) ?? .output
            )
        case "dataSource":
            self = .dataSource(sourceId: try c.decode(String.self, forKey: .sourceId))
        case "canvas-runtime":
            self = .canvasRuntime
        default:
            self = .forwardCompat(rawKind: kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .slot(nodeId, slotKey, direction):
            try c.encode("slot", forKey: .kind)
            try c.encode(nodeId, forKey: .nodeId)
            try c.encode(slotKey, forKey: .slotKey)
            try c.encode(direction, forKey: .direction)
        case let .dataSource(sourceId):
            try c.encode("dataSource", forKey: .kind)
            try c.encode(sourceId, forKey: .sourceId)
        case .canvasRuntime:
            try c.encode("canvas-runtime", forKey: .kind)
        case let .forwardCompat(rawKind):
            try c.encode(rawKind, forKey: .kind)
        }
    }

    /// §7.4 authoring rule — only a seed/source OUTPUT slot is hand-fillable.
    /// A dataSource mirror, an input slot, or canvas-runtime is NOT authorable.
    var defaultAuthorable: Bool {
        if case let .slot(_, _, direction) = self { return direction == .output }
        return false
    }

    /// Normalize the legacy two-mode `artifactDataSource` string + node context
    /// into the unified source (canvas-spec §7.4 mapping). Decode-compat path
    /// for canvases persisted before the unification.
    ///   - `authored` / `self`     → seed OUTPUT slot, authorable.
    ///   - `mirrored` / `external` → dataSource-kind, NOT authorable.
    static func fromLegacy(
        mode: String?,
        nodeId: String,
        outputSlotKey: String?,
        mirroredSourceId: String?
    ) -> ArtifactSource? {
        guard let mode else { return nil }
        switch mode {
        case "mirrored", "external":
            // No bound integration id yet ⇒ leave the binding placeholder;
            // the actual sourceId is resolved when the mirror is attached.
            return .dataSource(sourceId: mirroredSourceId ?? "")
        case "authored", "self", "upstream", "aggregated":
            // legacy upstream/aggregated were already folded to authored.
            return .slot(nodeId: nodeId, slotKey: outputSlotKey ?? "output", direction: .output)
        default:
            return nil
        }
    }
}

/// Atom 2 — `Edge` (§4.1). First-class consumption contract between a source
/// node slot and a downstream input. Replaces implicit `dependsOnNodeIds`.
struct Edge: Codable, Equatable {
    var id: String
    var canvasId: String
    var sourceRef: EdgeSourceRef
    var targetRef: EdgeTargetRef
    var edgeMode: EdgeMode
    var createdAt: String
    var modeRevision: Int

    enum CodingKeys: String, CodingKey {
        case id, canvasId, sourceRef, targetRef, edgeMode, createdAt, modeRevision
    }

    init(
        id: String,
        canvasId: String,
        sourceRef: EdgeSourceRef,
        targetRef: EdgeTargetRef,
        edgeMode: EdgeMode,
        createdAt: String = "",
        modeRevision: Int = 0
    ) {
        self.id = id
        self.canvasId = canvasId
        self.sourceRef = sourceRef
        self.targetRef = targetRef
        self.edgeMode = edgeMode
        self.createdAt = createdAt
        self.modeRevision = modeRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        canvasId = try c.decode(String.self, forKey: .canvasId)
        sourceRef = try c.decode(EdgeSourceRef.self, forKey: .sourceRef)
        targetRef = try c.decode(EdgeTargetRef.self, forKey: .targetRef)
        edgeMode = try c.decode(EdgeMode.self, forKey: .edgeMode)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        modeRevision = try c.decodeIfPresent(Int.self, forKey: .modeRevision) ?? 0
    }
}

/// `EdgeConsumption` (§4.7). Recorded on each `NodeAttempt`.
struct EdgeConsumption: Codable, Equatable {
    var edgeId: String
    var edgeMode: EdgeModeKind
    var modeRevision: Int
    /// document-snapshot.
    var consumedSourceVersion: String?
    /// queue-claim.
    var claimedItemIds: [String]?
    var filterApplied: EdgeFilter?
    var consumedAt: String

    enum CodingKeys: String, CodingKey {
        case edgeId, edgeMode, modeRevision
        case consumedSourceVersion, claimedItemIds, filterApplied, consumedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edgeId = try c.decode(String.self, forKey: .edgeId)
        edgeMode = try c.decode(EdgeModeKind.self, forKey: .edgeMode)
        modeRevision = try c.decodeIfPresent(Int.self, forKey: .modeRevision) ?? 0
        consumedSourceVersion = try c.decodeIfPresent(String.self, forKey: .consumedSourceVersion)
        claimedItemIds = try c.decodeIfPresent([String].self, forKey: .claimedItemIds)
        filterApplied = try c.decodeIfPresent(EdgeFilter.self, forKey: .filterApplied)
        consumedAt = try c.decodeIfPresent(String.self, forKey: .consumedAt) ?? ""
    }
}

// MARK: - Atom 3 · TriggerOrigin (§5.1)

/// `UpstreamAttemptRef` (§5.1) — shared by auto-workflow / inherited origins.
struct UpstreamAttemptRef: Codable, Equatable {
    var canvasId: String
    var nodeId: String
    var attemptIndex: Int
    /// hash(canvasId, nodeId, attemptIndex, lamportSeq) — wall-clock independent.
    var causalKey: String
}

/// Atom 3 — `TriggerOrigin` (§5.1). Discriminated union on `kind`. Modeled as a
/// Swift enum with associated values (matches the Zod `discriminatedUnion`
/// shape and the codebase's preference for exhaustive variant handling). An
/// unknown future `kind` decodes into `.unknown(kind:)` so legacy/forward data
/// never throws — decode-tolerant per PR2 scope.
enum TriggerOrigin: Codable, Equatable {
    case human(actorId: String, commentary: String?)
    case autoWorkflow(upstreamEdgeRef: AutoWorkflowEdgeRef, upstreamAttemptId: UpstreamAttemptRef)
    case autoAgent(agentLoopRef: AutoAgentLoopRef, iterationIndex: Int)
    case external(sourceUri: String, payloadRef: String, integrationId: String?)
    case inherited(parentAttempt: UpstreamAttemptRef, childOrdinal: Int)
    /// Forward-compat: unrecognized discriminator preserved verbatim.
    case unknown(kind: String)

    struct AutoWorkflowEdgeRef: Codable, Equatable {
        var canvasId: String
        var fromNodeId: String
        var toNodeId: String
    }

    struct AutoAgentLoopRef: Codable, Equatable {
        var sessionId: String
        var loopId: String
    }

    /// The discriminator value as it appears on the wire.
    var kind: String {
        switch self {
        case .human: return "human"
        case .autoWorkflow: return "auto-workflow"
        case .autoAgent: return "auto-agent"
        case .external: return "external"
        case .inherited: return "inherited"
        case .unknown(let k): return k
        }
    }

    /// Legacy default per §9.1 migration note: persisted attempts predating the
    /// 5-atom model have no `origin`. They are reconstituted as a human origin
    /// attributed to a sentinel actor so downstream code can treat origin as
    /// always-present without faking causal provenance.
    static let legacy = TriggerOrigin.human(actorId: "__legacy__", commentary: nil)

    private enum CodingKeys: String, CodingKey {
        case kind, actorId, commentary
        case upstreamEdgeRef, upstreamAttemptId
        case agentLoopRef, iterationIndex
        case sourceUri, payloadRef, integrationId
        case parentAttempt, childOrdinal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "human":
            self = .human(
                actorId: try c.decodeIfPresent(String.self, forKey: .actorId) ?? "",
                commentary: try c.decodeIfPresent(String.self, forKey: .commentary)
            )
        case "auto-workflow":
            self = .autoWorkflow(
                upstreamEdgeRef: try c.decode(AutoWorkflowEdgeRef.self, forKey: .upstreamEdgeRef),
                upstreamAttemptId: try c.decode(UpstreamAttemptRef.self, forKey: .upstreamAttemptId)
            )
        case "auto-agent":
            self = .autoAgent(
                agentLoopRef: try c.decode(AutoAgentLoopRef.self, forKey: .agentLoopRef),
                iterationIndex: try c.decodeIfPresent(Int.self, forKey: .iterationIndex) ?? 0
            )
        case "external":
            self = .external(
                sourceUri: try c.decodeIfPresent(String.self, forKey: .sourceUri) ?? "",
                payloadRef: try c.decodeIfPresent(String.self, forKey: .payloadRef) ?? "",
                integrationId: try c.decodeIfPresent(String.self, forKey: .integrationId)
            )
        case "inherited":
            self = .inherited(
                parentAttempt: try c.decode(UpstreamAttemptRef.self, forKey: .parentAttempt),
                childOrdinal: try c.decodeIfPresent(Int.self, forKey: .childOrdinal) ?? 0
            )
        default:
            self = .unknown(kind: kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case let .human(actorId, commentary):
            try c.encode(actorId, forKey: .actorId)
            try c.encodeIfPresent(commentary, forKey: .commentary)
        case let .autoWorkflow(edgeRef, attemptId):
            try c.encode(edgeRef, forKey: .upstreamEdgeRef)
            try c.encode(attemptId, forKey: .upstreamAttemptId)
        case let .autoAgent(loopRef, iterationIndex):
            try c.encode(loopRef, forKey: .agentLoopRef)
            try c.encode(iterationIndex, forKey: .iterationIndex)
        case let .external(sourceUri, payloadRef, integrationId):
            try c.encode(sourceUri, forKey: .sourceUri)
            try c.encode(payloadRef, forKey: .payloadRef)
            try c.encodeIfPresent(integrationId, forKey: .integrationId)
        case let .inherited(parentAttempt, childOrdinal):
            try c.encode(parentAttempt, forKey: .parentAttempt)
            try c.encode(childOrdinal, forKey: .childOrdinal)
        case .unknown:
            break
        }
    }
}

// MARK: - Atom 4 · MonitorSpec + MonitorCard (§6.1)

/// `ViewerFilter` discriminated union (§6.1). Tolerant: raw `kind` + the only
/// payload field (`fieldPath`).
struct MonitorViewerFilter: Codable, Equatable {
    /// `none | assignee-is-viewer | owner-is-viewer | field-equals-viewer`.
    var kind: String
    var fieldPath: String?

    enum CodingKeys: String, CodingKey { case kind, fieldPath }

    init(kind: String = "none", fieldPath: String? = nil) {
        self.kind = kind
        self.fieldPath = fieldPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "none"
        fieldPath = try c.decodeIfPresent(String.self, forKey: .fieldPath)
    }
}

/// `CardLayout` (§6.1).
struct MonitorCardLayout: Codable, Equatable {
    var col: Int
    var row: Int
    var width: Int
    var height: Int
    var collapsed: Bool

    enum CodingKeys: String, CodingKey { case col, row, width, height, collapsed }

    init(col: Int = 0, row: Int = 0, width: Int = 1, height: Int = 1, collapsed: Bool = false) {
        self.col = col
        self.row = row
        self.width = width
        self.height = height
        self.collapsed = collapsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        col = try c.decodeIfPresent(Int.self, forKey: .col) ?? 0
        row = try c.decodeIfPresent(Int.self, forKey: .row) ?? 0
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}

/// `MonitorCard` discriminated union on `type` (§6.1). The per-type `config`
/// shapes are an open registry, so `config` is kept as `BoardJSONValue` rather
/// than mirroring every card config struct — decode-only, not consumed yet. An
/// unknown card `type` round-trips via the raw `type` string.
struct MonitorCard: Codable, Equatable {
    var id: String
    /// `period-selector | producer-status-grid | … | <forward-compat>`.
    var type: String
    var layout: MonitorCardLayout
    var title: String?
    /// `all | human-only | auto-only | hidden`, default `all`.
    var attemptVisibility: String
    var viewerFilter: MonitorViewerFilter
    /// Per-type config payload, kept opaque (decode-only).
    var config: PlannerAtomJSON?

    enum CodingKeys: String, CodingKey {
        case id, type, layout, title, attemptVisibility, viewerFilter, config
    }

    init(
        id: String,
        type: String,
        layout: MonitorCardLayout = MonitorCardLayout(),
        title: String? = nil,
        attemptVisibility: String = "all",
        viewerFilter: MonitorViewerFilter = MonitorViewerFilter(),
        config: PlannerAtomJSON? = nil
    ) {
        self.id = id
        self.type = type
        self.layout = layout
        self.title = title
        self.attemptVisibility = attemptVisibility
        self.viewerFilter = viewerFilter
        self.config = config
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try c.decode(String.self, forKey: .type)
        layout = try c.decodeIfPresent(MonitorCardLayout.self, forKey: .layout) ?? MonitorCardLayout()
        title = try c.decodeIfPresent(String.self, forKey: .title)
        attemptVisibility = try c.decodeIfPresent(String.self, forKey: .attemptVisibility) ?? "all"
        viewerFilter = try c.decodeIfPresent(MonitorViewerFilter.self, forKey: .viewerFilter)
            ?? MonitorViewerFilter()
        config = try c.decodeIfPresent(PlannerAtomJSON.self, forKey: .config)
    }
}

/// `MonitorSpec.globalFilters` (§6.1).
struct MonitorGlobalFilters: Codable, Equatable {
    var statusIn: [String]?
    var assigneeIn: [String]?
}

/// Atom 4 — `MonitorSpec` (§6.1). The owner-facing card grid bound into the
/// canvas. Decode-only mirror.
struct MonitorSpec: Codable, Equatable {
    var canvasId: String
    var version: Int
    var globalFilters: MonitorGlobalFilters?
    var cards: [MonitorCard]
    var appliedFromProposalId: String?

    enum CodingKeys: String, CodingKey {
        case canvasId, version, globalFilters, cards, appliedFromProposalId
    }

    init(
        canvasId: String,
        version: Int = 1,
        globalFilters: MonitorGlobalFilters? = nil,
        cards: [MonitorCard] = [],
        appliedFromProposalId: String? = nil
    ) {
        self.canvasId = canvasId
        self.version = version
        self.globalFilters = globalFilters
        self.cards = cards
        self.appliedFromProposalId = appliedFromProposalId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canvasId = try c.decodeIfPresent(String.self, forKey: .canvasId) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        globalFilters = try c.decodeIfPresent(MonitorGlobalFilters.self, forKey: .globalFilters)
        cards = try c.decodeIfPresent([MonitorCard].self, forKey: .cards) ?? []
        appliedFromProposalId = try c.decodeIfPresent(String.self, forKey: .appliedFromProposalId)
    }
}

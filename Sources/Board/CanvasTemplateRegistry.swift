import Foundation

/// 一个 builtin canvas template 的最小描述。
///
/// 与 `CardTemplateStore` 描述的 **card template**（节点级 prompt 模板）不同，
/// `CanvasTemplate` 描述的是 **整张 canvas 的初始形态**：
/// 用户从 Templates Gallery 选一张 → 后端按 `kind` 新建 canvas →
/// 用 `defaultNodes` 批量 seed 出占位节点，立刻进入"可用 demo"状态。
///
/// Spec: doc/goals/release-plan-qc-completion.md (Chunk F · Official templates)
struct CanvasTemplate: Equatable {
    let id: String
    let name: String
    let description: String
    /// lucide icon name；前端使用 lucide-react 渲染。
    let icon: String
    let kind: BoardLayoutStore.CanvasKind
    let category: String   // 'engineering' / 'team' / 'demo'
    let defaultNodes: [TemplateNodeSpec]

    init(
        id: String,
        name: String,
        description: String,
        icon: String,
        kind: BoardLayoutStore.CanvasKind,
        category: String,
        defaultNodes: [TemplateNodeSpec]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.kind = kind
        self.category = category
        self.defaultNodes = defaultNodes
    }
}

/// 一个 template 内的占位 node。
///
/// 字段保持最小：title / description / status / positionHint / widget。
/// `apply` 时由 `CanvasTemplateRegistry.materializeNodes` 翻译成完整的
/// `PlanningNode`（带 schema / executor / layout 等默认值）。
///
/// `widget` 字段（2026-05-28, chunk P2.8）= 节点级 widget 声明。nil 表示
/// 标准节点（标题 + 执行人 + run state），非 nil 表示该节点应渲染为对应
/// widget（kanban / inbox / matrix / artifact-preview / badge）。
struct TemplateNodeSpec: Equatable {
    let title: String
    let description: String?
    let status: String
    let doerId: String?
    let positionHint: [String: Double]?
    let widget: Widget?

    // MARK: - Workflow fields (orchestration templates)
    //
    // All optional with back-compat defaults so the existing widget/standard
    // templates are unaffected (their nodes stay human/.ready/no-deps with an
    // empty schema). A template that wants a real dependency-edge flow + auto
    // dispatch sets these.

    /// Indices (into the template's `defaultNodes`) this node depends on.
    /// `materializeNodes` maps them to the materialized node ids →
    /// `dependsOnNodeIds`, and the apply path reconciles them into edges.
    let dependsOn: [Int]?
    /// `ExecutionMode` raw value ("auto" / "human"). nil → `.human`.
    let executionMode: String?
    /// `ExecutorType` raw value ("claude" / "human" / …). nil → `.human`.
    let executorType: String?
    /// NodeSchema.goal. nil → falls back to `description` then `title`.
    let goal: String?
    /// NodeSchema.inputs. nil → [].
    let inputs: [String]?
    /// NodeSchema.outputs. nil → [].
    let outputs: [String]?

    init(
        title: String,
        description: String? = nil,
        status: String,
        doerId: String? = nil,
        positionHint: [String: Double]? = nil,
        widget: Widget? = nil,
        dependsOn: [Int]? = nil,
        executionMode: String? = nil,
        executorType: String? = nil,
        goal: String? = nil,
        inputs: [String]? = nil,
        outputs: [String]? = nil
    ) {
        self.title = title
        self.description = description
        self.status = status
        self.doerId = doerId
        self.positionHint = positionHint
        self.widget = widget
        self.dependsOn = dependsOn
        self.executionMode = executionMode
        self.executorType = executorType
        self.goal = goal
        self.inputs = inputs
        self.outputs = outputs
    }
}

enum CanvasTemplateRegistry {

    static let all: [CanvasTemplate] = [
        codingOrchestration
    ]

    static func get(_ id: String) -> CanvasTemplate? {
        return all.first { $0.id == id }
    }

    // MARK: - Templates

    /// 1. coding-orchestration — 主从派发编排，主 Agent 拆分需求 → 3 个 sub
    ///    并行实现 → 集成验证。全节点 auto + claude，所以用户只需手动「开干」
    ///    主 Agent：它完成后 3 个 sub（.auto + 依赖满足）自动派发，三者都 done
    ///    后集成节点自动派发。依赖以 `dependsOn`(索引)声明，apply 时落成依赖边。
    ///
    ///   index 0 主Agent ─┬─ 1 前端 ─┐
    ///                    ├─ 2 后端 ─┼─→ 4 集成与验证
    ///                    └─ 3 重构 ─┘
    static let codingOrchestration = CanvasTemplate(
        id: "coding-orchestration",
        name: "写代码 · 主从派发",
        description: "主 Agent 拆分需求并派发给前端/后端/重构子 Agent，完成后自动集成验证",
        icon: "git-branch",
        kind: .board,
        category: "engineering",
        defaultNodes: [
            // 0 — entry; user 手动开干。拆分需求 → 三份 task spec。
            TemplateNodeSpec(
                title: "主 Agent · 需求拆分与派发",
                description: "读取需求，拆成前端 / 后端 / 重构三块工作，为每块产出一份 task spec",
                status: "ready",
                positionHint: ["x": 0, "y": 240],
                executionMode: "auto",
                executorType: "claude",
                goal: "读取需求并拆分为前端、后端、重构三份可独立执行的 task spec",
                inputs: [],
                outputs: ["frontend_spec", "backend_spec", "refactor_spec"]
            ),
            // 1 — 前端实现，依赖主 Agent。
            TemplateNodeSpec(
                title: "前端实现",
                description: "按 frontend_spec 实现前端改动并开 PR",
                status: "ready",
                positionHint: ["x": 420, "y": 0],
                dependsOn: [0],
                executionMode: "auto",
                executorType: "claude",
                goal: "按 frontend_spec 实现前端改动并提交 PR",
                inputs: ["frontend_spec"],
                outputs: ["frontend_pr"]
            ),
            // 2 — 后端实现，依赖主 Agent。
            TemplateNodeSpec(
                title: "后端实现",
                description: "按 backend_spec 实现后端改动并开 PR",
                status: "ready",
                positionHint: ["x": 420, "y": 240],
                dependsOn: [0],
                executionMode: "auto",
                executorType: "claude",
                goal: "按 backend_spec 实现后端改动并提交 PR",
                inputs: ["backend_spec"],
                outputs: ["backend_pr"]
            ),
            // 3 — 重构，依赖主 Agent。
            TemplateNodeSpec(
                title: "重构",
                description: "按 refactor_spec 做重构并开 PR",
                status: "ready",
                positionHint: ["x": 420, "y": 480],
                dependsOn: [0],
                executionMode: "auto",
                executorType: "claude",
                goal: "按 refactor_spec 完成重构并提交 PR",
                inputs: ["refactor_spec"],
                outputs: ["refactor_pr"]
            ),
            // 4 — 集成与验证，依赖前端 / 后端 / 重构三者。
            TemplateNodeSpec(
                title: "集成与验证",
                description: "合并三个 PR，跑集成/回归，产出验证报告",
                status: "ready",
                positionHint: ["x": 840, "y": 240],
                dependsOn: [1, 2, 3],
                executionMode: "auto",
                executorType: "claude",
                goal: "集成前端 / 后端 / 重构三个 PR 并运行集成与回归验证，产出验证报告",
                inputs: ["frontend_pr", "backend_pr", "refactor_pr"],
                outputs: ["integration_report"]
            )
        ]
    )

    // MARK: - Materialization

    /// 把 `TemplateNodeSpec[]` 翻译成 `PlanningNode[]`，
    /// 套上一组 sane defaults（schema / executor / layout 等）。
    /// Internal — `PlanningNode` is module-internal, this can't be `public`.
    static func materializeNodes(
        template: CanvasTemplate,
        canvasId: String,
        ownerId: String
    ) -> [PlanningNode] {
        func nodeId(forIndex index: Int) -> String {
            "\(canvasId)-\(template.id)-\(index)"
        }
        let lastIndex = template.defaultNodes.count - 1
        return template.defaultNodes.enumerated().map { index, spec in
            let status = PlanningNodeStatus(rawValue: spec.status) ?? .ready
            let x = spec.positionHint?["x"] ?? Double(index) * 320
            let y = spec.positionHint?["y"] ?? 0
            let width = spec.positionHint?["width"] ?? 300
            let height = spec.positionHint?["height"] ?? 168
            let doer = spec.doerId ?? ownerId

            // Back-compat: nil → the historical human/human defaults, so the
            // existing widget/standard templates seed exactly as before.
            let executionMode = spec.executionMode.flatMap(ExecutionMode.init(rawValue:)) ?? .human
            let executorType = spec.executorType.flatMap(ExecutorType.init(rawValue:)) ?? .human

            // Map dependsOn indices → materialized node ids. Drop out-of-range /
            // self references defensively (a malformed template must not crash
            // apply); preserve nil when there are no declared dependencies to
            // keep dependency-free nodes byte-identical on-wire.
            let dependsOnNodeIds: [String]? = spec.dependsOn.map { indices in
                indices
                    .filter { $0 >= 0 && $0 <= lastIndex && $0 != index }
                    .map(nodeId(forIndex:))
            }

            let schema = NodeSchema(
                inputs: spec.inputs ?? [],
                outputs: spec.outputs ?? [],
                goal: spec.goal ?? spec.description ?? spec.title
            )

            return PlanningNode(
                id: nodeId(forIndex: index),
                canvasId: canvasId,
                title: spec.title,
                schema: schema,
                contextSources: [],
                executionMode: executionMode,
                executorType: executorType,
                doerId: doer,
                status: status,
                source: .planner,
                dependsOnNodeIds: dependsOnNodeIds,
                nodeKind: .step,
                layout: PlannerNodeLayout(x: x, y: y, width: width, height: height),
                widget: spec.widget
            )
        }
    }

}

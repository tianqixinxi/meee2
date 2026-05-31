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
        codeReview,
        releaseChecklist,
        overnightRecap,
        teamControlTower,
        engineeringRefactor,
        npcCanvas,
        codingOrchestration
    ]

    static func get(_ id: String) -> CanvasTemplate? {
        return all.first { $0.id == id }
    }

    // MARK: - Templates

    /// 1. code-review — 单个 kanban widget 节点，PR 评审看板。
    ///
    /// chunk P2.8 (2026-05-28): 从「4 个 standard 节点 + kanban 心智」改成
    /// 「1 个大节点 widget=kanban」。`source.inputKind=external` 留着接
    /// GitHub PR integration；具体绑定在 Inspector 里做。
    static let codeReview = CanvasTemplate(
        id: "code-review",
        name: "Code Review Kanban",
        description: "围绕 GitHub PR 的代码评审看板",
        icon: "git-pull-request",
        kind: .board,
        category: "engineering",
        defaultNodes: [
            TemplateNodeSpec(
                title: "PR 评审看板",
                description: "看板 widget · 需要在 Inspector 里把 input.external 绑到 GitHub PR integration",
                status: "ready",
                positionHint: ["x": 0, "y": 0, "width": 960, "height": 540],
                widget: Widget(
                    kind: .kanban,
                    source: WidgetSource(inputKind: .external, inputIndex: 0),
                    mapping: WidgetMapping(
                        statusField: "state",
                        titleField: "title",
                        subtitleField: "author",
                        sortField: "updatedAt"
                    )
                )
            )
        ]
    )

    /// 2. release-checklist — board，sequential gate→test→tag→notify
    static let releaseChecklist = CanvasTemplate(
        id: "release-checklist",
        name: "Release Checklist",
        description: "Release 前的 gate + smoke + tag + notify 流程",
        icon: "rocket",
        kind: .board,
        category: "engineering",
        defaultNodes: [
            TemplateNodeSpec(
                title: "[Gate] Feature freeze",
                description: "等 release owner approve cut-off",
                status: "blocked",
                positionHint: ["x": 0, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Run CI suite",
                description: "full validate.sh + swift test 全绿",
                status: "ready",
                positionHint: ["x": 320, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Smoke test prod-like env",
                description: "本地 release build + 真实 session 跑一遍",
                status: "ready",
                positionHint: ["x": 640, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Tag release",
                description: "git tag + ./build.sh 签名打包",
                status: "ready",
                positionHint: ["x": 960, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Notify stakeholders",
                description: "发 release notes + 同步团队群",
                status: "ready",
                positionHint: ["x": 1280, "y": 0]
            )
        ]
    )

    /// 3. overnight-recap — 单个 inbox widget 节点，AI 隔夜跑产物收件箱。
    ///
    /// chunk P2.8 (2026-05-28): inbox widget 聚合 sibling subcanvas 的 run
    /// 产物；`subcanvasIds` 留空，apply 时由 Inspector / runtime 填充。
    static let overnightRecap = CanvasTemplate(
        id: "overnight-recap",
        name: "Overnight Recap",
        description: "夜间 AI 跑完后，早晨 5 分钟翻完 recap 决定哪些 follow up",
        icon: "moon",
        kind: .board,
        category: "team",
        defaultNodes: [
            TemplateNodeSpec(
                title: "隔夜 Recap 收件箱",
                description: "收件箱 widget · 聚合 sibling subcanvas 的隔夜跑结果，需要在 Inspector 里选要聚合的 canvas",
                status: "ready",
                positionHint: ["x": 0, "y": 0, "width": 720, "height": 540],
                widget: Widget(
                    kind: .inbox,
                    source: WidgetSource(inputKind: .subcanvasAggregate, inputIndex: 0, subcanvasIds: []),
                    mapping: WidgetMapping(
                        titleField: "title",
                        subtitleField: "summary",
                        sortField: "createdAt"
                    )
                )
            )
        ]
    )

    /// 4. team-control-tower — 单个 matrix widget 节点，owner × status 总览。
    ///
    /// chunk P2.8 (2026-05-28): matrix widget 聚合 sibling subcanvas 的
    /// 工作流节点，按 doerId × status 摆。
    static let teamControlTower = CanvasTemplate(
        id: "team-control-tower",
        name: "Team Control Tower",
        description: "团队跨工作流总览，看每个人在哪个 status",
        icon: "users",
        kind: .board,
        category: "team",
        defaultNodes: [
            TemplateNodeSpec(
                title: "团队 Owner × Status 矩阵",
                description: "矩阵 widget · 聚合 sibling subcanvas 节点，按 owner × status 摆；需要在 Inspector 里选要聚合的 canvas",
                status: "ready",
                positionHint: ["x": 0, "y": 0, "width": 960, "height": 540],
                widget: Widget(
                    kind: .matrix,
                    source: WidgetSource(inputKind: .subcanvasAggregate, inputIndex: 0, subcanvasIds: []),
                    mapping: WidgetMapping(
                        statusField: "status",
                        titleField: "title",
                        rowGroupField: "doerId",
                        colGroupField: "status"
                    )
                )
            )
        ]
    )

    /// 5. engineering-refactor — board，scope + subcanvas + blocked
    static let engineeringRefactor = CanvasTemplate(
        id: "engineering-refactor",
        name: "Engineering Refactor",
        description: "工程重构 — 拆 scope、下钻 subcanvas、跟踪 blocked",
        icon: "tool",
        kind: .board,
        category: "engineering",
        defaultNodes: [
            // chunk P2.8 (2026-05-28): 第 1 个节点从 standard 改成
            // artifact-preview widget — 展示从 upstream 接进来的 PRD artifact。
            TemplateNodeSpec(
                title: "重构 PRD 预览",
                description: "artifact-preview widget · 需要在 Inspector 里把 input.upstream 接到 PRD artifact 节点",
                status: "ready",
                positionHint: ["x": 0, "y": 0, "width": 480, "height": 540],
                widget: Widget(
                    kind: .artifactPreview,
                    source: WidgetSource(inputKind: .upstream, inputIndex: 0),
                    mapping: WidgetMapping(
                        titleField: "title",
                        subtitleField: "summary"
                    )
                )
            ),
            TemplateNodeSpec(
                title: "Scope: PluginManager dylib reload",
                description: "支持热重载，避免重启 menubar app",
                status: "ready",
                positionHint: ["x": 320, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Scope: Hook ingestion path simplify",
                description: "blocked — 等 spec 决定 socket 路径",
                status: "blocked",
                positionHint: ["x": 640, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Subcanvas: BoardAPI route split-out",
                description: "占位 — 点开后会下钻到一张新 canvas",
                status: "ready",
                positionHint: ["x": 960, "y": 0]
            )
        ]
    )

    /// 6. npc-canvas — board，游戏 NPC 编排 demo
    static let npcCanvas = CanvasTemplate(
        id: "npc-canvas",
        name: "NPC Canvas",
        description: "游戏 NPC 编排画板（demo）",
        icon: "gamepad-2",
        kind: .board,
        category: "demo",
        defaultNodes: [
            TemplateNodeSpec(
                title: "Quest giver: village elder",
                description: "派发主线任务，需要 dialog tree",
                status: "ready",
                positionHint: ["x": 0, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Combat NPC: forest wolf",
                description: "中等难度 mob，drop table TBD",
                status: "ready",
                positionHint: ["x": 320, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Merchant: roaming trader",
                description: "动态库存，按 player level 调整",
                status: "ready",
                positionHint: ["x": 640, "y": 0]
            ),
            TemplateNodeSpec(
                title: "Lore NPC: ancient librarian",
                description: "只触发剧情，不可交易、不可战斗",
                status: "ready",
                positionHint: ["x": 960, "y": 0]
            )
        ]
    )

    /// 7. coding-orchestration — 主从派发编排，主 Agent 拆分需求 → 3 个 sub
    ///    并行实现 → 集成验证。全节点 auto + claude，所以用户只需手动「开干」
    ///    主 Agent：它完成后 3 个 sub（.auto + 依赖满足）自动派发，三者都 done
    ///    后集成节点自动派发。依赖以 `dependsOn`(索引) 声明，apply 时落成依赖边。
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

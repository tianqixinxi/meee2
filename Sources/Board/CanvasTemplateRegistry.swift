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
    let sceneSpec: CanvasSceneSpec?

    init(
        id: String,
        name: String,
        description: String,
        icon: String,
        kind: BoardLayoutStore.CanvasKind,
        category: String,
        defaultNodes: [TemplateNodeSpec],
        sceneSpec: CanvasSceneSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.kind = kind
        self.category = category
        self.defaultNodes = defaultNodes
        self.sceneSpec = sceneSpec
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
        travelSquad,
        pokerTable,
        codingOrchestration
    ]

    static func get(_ id: String) -> CanvasTemplate? {
        return all.first { $0.id == id }
    }

    private static func json(_ raw: [String: Any]) -> BoardJSONValue {
        BoardJSONValue.fromAny(raw) ?? .object([:])
    }

    private static func boardJSONValue<T: Encodable>(_ value: T) -> BoardJSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(BoardJSONValue.self, from: data)
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

    /// 7. travel-squad — canvas-level scene demo. Nodes stay executable work
    /// lines; cities/hotels/routes live in scene state and artifacts.
    static let travelSquad = CanvasTemplate(
        id: "travel-squad",
        name: "Travel Squad",
        description: "旅行规划小队：路线、酒店、美食、预算和最终确认由多个 AI/人工节点推进",
        icon: "map",
        kind: .board,
        category: "demo",
        defaultNodes: [
            TemplateNodeSpec(
                title: "路线规划 Agent",
                description: "根据城市、天数和约束产出 itinerary.json",
                status: "ready",
                positionHint: ["x": -360, "y": 420],
                executionMode: "auto",
                executorType: "claude",
                goal: "产出十天日本旅行的 itinerary.json，包含城市顺序、每日主题和交通建议",
                outputs: ["itinerary.json"]
            ),
            TemplateNodeSpec(
                title: "酒店 Agent",
                description: "比较住宿区域和候选酒店，产出 booking-candidates.json",
                status: "ready",
                positionHint: ["x": 0, "y": 420],
                executionMode: "auto",
                executorType: "claude",
                goal: "比较东京、京都、大阪的住宿区域和候选酒店，给出预算内推荐",
                outputs: ["booking-candidates.json"]
            ),
            TemplateNodeSpec(
                title: "美食 Agent",
                description: "整理餐厅、咖啡和当地体验，产出 places.json",
                status: "ready",
                positionHint: ["x": 360, "y": 420],
                executionMode: "auto",
                executorType: "claude",
                goal: "整理旅行中的餐厅、咖啡和当地体验，按城市产出 places.json",
                outputs: ["places.json"]
            ),
            TemplateNodeSpec(
                title: "预算审批",
                description: "人工确认预算边界和可接受的酒店价格",
                status: "blocked",
                positionHint: ["x": 720, "y": 420],
                executionMode: "human",
                executorType: "human",
                goal: "确认预算上限、住宿偏好和需要重新计算的路线约束",
                inputs: ["itinerary.json", "booking-candidates.json"],
                outputs: ["budget.json"]
            ),
            TemplateNodeSpec(
                title: "最终行程确认",
                description: "收敛路线、酒店、美食和预算，形成最终旅行 brief",
                status: "ready",
                positionHint: ["x": 1080, "y": 420],
                dependsOn: [0, 1, 2, 3],
                executionMode: "human",
                executorType: "human",
                goal: "审核 itinerary、places、booking candidates 和 budget，确认最终旅行方案",
                inputs: ["itinerary.json", "places.json", "booking-candidates.json", "budget.json"],
                outputs: ["travel-brief.md"]
            )
        ],
        sceneSpec: CanvasSceneSpec(
            kind: "travel-squad",
            assets: [
                "background": .string("template:travel-squad/map-paper"),
                "accent": .string("teal")
            ],
            initialState: json([
                "title": "日本十日旅行",
                "summary": "东京 → 京都 → 大阪，本地结构化示意，不接外部地图 API。",
                "route": [
                    ["id": "tokyo", "label": "东京", "days": "D1-D3", "x": 18, "y": 36],
                    ["id": "kyoto", "label": "京都", "days": "D4-D7", "x": 52, "y": 55],
                    ["id": "osaka", "label": "大阪", "days": "D8-D10", "x": 78, "y": 68]
                ],
                "timeline": [
                    ["day": "D1", "title": "抵达东京", "owner": "路线规划 Agent"],
                    ["day": "D4", "title": "新干线到京都", "owner": "路线规划 Agent"],
                    ["day": "D8", "title": "大阪美食与返程准备", "owner": "美食 Agent"]
                ],
                "budget": ["status": "awaiting", "label": "等待预算审批"],
                "hotels": [
                    ["city": "东京", "title": "上野 / 银座区域待比较"],
                    ["city": "京都", "title": "四条河原町 / 京都站待比较"]
                ]
            ]),
            artifactBindings: [
                CanvasSceneArtifactBinding(id: "itinerary", nodeId: "node:0", reference: "itinerary.json"),
                CanvasSceneArtifactBinding(id: "hotels", nodeId: "node:1", reference: "booking-candidates.json"),
                CanvasSceneArtifactBinding(id: "places", nodeId: "node:2", reference: "places.json"),
                CanvasSceneArtifactBinding(id: "budget", nodeId: "node:3", reference: "budget.json")
            ],
            nodeAnchors: [
                CanvasSceneNodeAnchor(id: "route", label: "路线", nodeId: "node:0", x: 44, y: 30, role: "route"),
                CanvasSceneNodeAnchor(id: "hotel", label: "酒店", nodeId: "node:1", x: 56, y: 43, role: "hotel"),
                CanvasSceneNodeAnchor(id: "food", label: "美食", nodeId: "node:2", x: 70, y: 58, role: "food"),
                CanvasSceneNodeAnchor(id: "budget", label: "预算", nodeId: "node:3", x: 32, y: 66, role: "approval")
            ],
            actions: [
                CanvasSceneAction(id: "replan-route", label: "重算路线", nodeId: "node:0", prompt: "按最新预算和城市偏好重算路线。"),
                CanvasSceneAction(id: "compare-hotels", label: "比较酒店", nodeId: "node:1", prompt: "更新酒店候选和利弊。"),
                CanvasSceneAction(id: "review-budget", label: "确认预算", nodeId: "node:3", prompt: "请确认预算约束并产出 budget.json。")
            ]
        )
    )

    /// 8. poker-table — rules-assisted AI role-play canvas. Cards/pot/seats are
    /// scene state; player agents / GM are executable nodes. Dealer is a
    /// system state owner for node-scoped artifacts, not an AI session.
    static let pokerTable = CanvasTemplate(
        id: "poker-table",
        name: "Poker Table",
        description: "德州扑克 AI 角色牌桌：规则调度器维护牌桌状态，玩家和 GM 节点驱动行动 artifact",
        icon: "club",
        kind: .board,
        category: "demo",
        defaultNodes: [
            TemplateNodeSpec(
                title: "Dealer / Table State",
                description: "系统状态挂载点：Rules Orchestrator 在这里写入 game-state.json 和 action-log.json",
                status: "ready",
                positionHint: ["x": -420, "y": 420],
                executionMode: "auto",
                executorType: "mock",
                goal: "作为德州扑克牌桌的权威状态出口；常规规则推进由 Rules Orchestrator 系统写入，不启动 AI session",
                outputs: ["game-state.json", "action-log.json"]
            ),
            TemplateNodeSpec(
                title: "Ada 玩家 Agent",
                description: "紧凶型玩家，根据公共信息选择行动",
                status: "ready",
                positionHint: ["x": -120, "y": 420],
                executionMode: "auto",
                executorType: "claude",
                goal: "扮演紧凶型玩家 Ada，在轮到自己时选择 fold/call/raise/check 并说明理由",
                inputs: ["game-state.json"],
                outputs: ["ada-action.json", "player-model.json"]
            ),
            TemplateNodeSpec(
                title: "Bruno 玩家 Agent",
                description: "诈唬型玩家，根据公共信息选择行动",
                status: "ready",
                positionHint: ["x": 180, "y": 420],
                executionMode: "auto",
                executorType: "claude",
                goal: "扮演诈唬型玩家 Bruno，在轮到自己时选择行动并说明策略",
                inputs: ["game-state.json"],
                outputs: ["bruno-action.json", "player-model.json"]
            ),
            TemplateNodeSpec(
                title: "Mina 玩家 Agent",
                description: "保守观察型玩家，根据公共信息选择行动",
                status: "ready",
                positionHint: ["x": 480, "y": 420],
                executionMode: "auto",
                executorType: "claude",
                goal: "扮演保守观察型玩家 Mina，在轮到自己时选择行动并说明风险判断",
                inputs: ["game-state.json"],
                outputs: ["mina-action.json", "player-model.json"]
            ),
            TemplateNodeSpec(
                title: "GM / 规则裁判",
                description: "人工审批揭示、纠正规则辅助判断",
                status: "ready",
                positionHint: ["x": 780, "y": 420],
                executionMode: "human",
                executorType: "human",
                goal: "审批揭示、纠正规则辅助判断，并决定是否进入下一手",
                inputs: ["game-state.json", "action-log.json"],
                outputs: ["gm-ruling.md"]
            )
        ],
        sceneSpec: CanvasSceneSpec(
            kind: "poker-table",
            assets: [
                "background": .string("template:poker-table/felt"),
                "felt": .string("emerald")
            ],
            initialState: json([
                "title": "AI Poker Table",
                "setup": [
                    "started": false,
                    "userRole": "observer",
                    "controlledPlayerId": NSNull(),
                    "autoRun": true
                ],
                "phase": "Pre-flop",
                "pot": 0,
                "nextActor": "setup",
                "nextAction": "Setup",
                "communityCards": ["??", "??", "??", "??", "??"],
                "legalActions": [],
                "handStatus": "setup",
                "players": [
                    ["id": "dealer", "name": "Dealer / Table State", "stack": 0, "status": "system", "seat": "top", "holeCards": []],
                    ["id": "ada", "name": "Ada", "style": "紧凶型", "stack": 1000, "status": "ready", "seat": "left", "holeCards": ["??", "??"]],
                    ["id": "bruno", "name": "Bruno", "style": "诈唬型", "stack": 1000, "status": "ready", "seat": "right", "holeCards": ["??", "??"]],
                    ["id": "mina", "name": "Mina", "style": "保守观察", "stack": 1000, "status": "ready", "seat": "bottom", "holeCards": ["??", "??"]]
                ],
                "actionLog": [
                    "请选择你在牌桌里的角色，然后开始游戏。"
                ],
                "rulesMode": "phase/order/card-uniqueness assisted; no side-pot engine"
            ]),
            artifactBindings: [
                CanvasSceneArtifactBinding(id: "game-state", nodeId: "node:0", reference: "game-state.json"),
                CanvasSceneArtifactBinding(id: "action-log", nodeId: "node:0", reference: "action-log.json"),
                CanvasSceneArtifactBinding(id: "ada", nodeId: "node:1", reference: "ada-action.json"),
                CanvasSceneArtifactBinding(id: "bruno", nodeId: "node:2", reference: "bruno-action.json"),
                CanvasSceneArtifactBinding(id: "mina", nodeId: "node:3", reference: "mina-action.json")
            ],
            nodeAnchors: [
                CanvasSceneNodeAnchor(id: "dealer", label: "Table State", nodeId: "node:0", x: 50, y: 16, role: "dealer"),
                CanvasSceneNodeAnchor(id: "ada", label: "Ada", nodeId: "node:1", x: 16, y: 52, role: "player"),
                CanvasSceneNodeAnchor(id: "bruno", label: "Bruno", nodeId: "node:2", x: 84, y: 52, role: "player"),
                CanvasSceneNodeAnchor(id: "mina", label: "Mina", nodeId: "node:3", x: 50, y: 82, role: "player"),
                CanvasSceneNodeAnchor(id: "gm", label: "GM", nodeId: "node:4", x: 78, y: 18, role: "approval")
            ],
            actions: [
                CanvasSceneAction(id: "next-street", label: "发下一轮牌", nodeId: "node:0", prompt: "推进到下一阶段并更新 game-state.json。"),
                CanvasSceneAction(id: "ask-ada", label: "要求 Ada 行动", nodeId: "node:1", prompt: "根据当前 game-state.json 给出 Ada 的下一步行动。"),
                CanvasSceneAction(id: "ask-bruno", label: "要求 Bruno 行动", nodeId: "node:2", prompt: "根据当前 game-state.json 给出 Bruno 的下一步行动。"),
                CanvasSceneAction(id: "ask-mina", label: "要求 Mina 行动", nodeId: "node:3", prompt: "根据当前 game-state.json 给出 Mina 的下一步行动。"),
                CanvasSceneAction(id: "gm-review", label: "GM 审批", nodeId: "node:4", prompt: "检查牌局状态和行动是否合法。"),
                CanvasSceneAction(id: "start-game", label: "开始游戏", nodeId: "node:0", prompt: "由规则调度器初始化 game-state.json 与 action-log.json。"),
                CanvasSceneAction(id: "step", label: "执行下一步", nodeId: "node:0", prompt: "由规则调度器推进一个可确定的牌局动作。"),
                CanvasSceneAction(id: "resume-auto", label: "继续自动", nodeId: "node:0", prompt: "由规则调度器继续自动流转直到暂停点。"),
                CanvasSceneAction(id: "pause-auto", label: "暂停", nodeId: "node:0", prompt: "暂停规则调度器自动流转。")
            ],
            orchestration: CanvasSceneOrchestration(
                kind: "poker-rules-v1",
                stateNodeId: "node:0",
                stateReference: "game-state.json",
                logReference: "action-log.json"
            )
        )
    )

    /// 9. coding-orchestration — 主从派发编排，主 Agent 拆分需求 → 3 个 sub
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

    static func materializeSceneSpec(
        template: CanvasTemplate,
        canvasId: String
    ) -> CanvasSceneSpec? {
        guard var scene = template.sceneSpec else { return nil }

        func nodeId(forIndex index: Int) -> String {
            "\(canvasId)-\(template.id)-\(index)"
        }
        func resolveNodeId(_ raw: String) -> String {
            guard raw.hasPrefix("node:"),
                  let index = Int(raw.dropFirst("node:".count)),
                  index >= 0,
                  index < template.defaultNodes.count else {
                return raw
            }
            return nodeId(forIndex: index)
        }

        scene.artifactBindings = scene.artifactBindings.map { binding in
            var next = binding
            next.nodeId = resolveNodeId(binding.nodeId)
            return next
        }
        scene.nodeAnchors = scene.nodeAnchors.map { anchor in
            var next = anchor
            next.nodeId = resolveNodeId(anchor.nodeId)
            return next
        }
        scene.actions = scene.actions.map { action in
            var next = action
            next.nodeId = resolveNodeId(action.nodeId)
            return next
        }
        if var orchestration = scene.orchestration {
            orchestration.stateNodeId = orchestration.stateNodeId.map(resolveNodeId)
            scene.orchestration = orchestration
        }
        return scene
    }

    static func materializeRenderProfile(
        template: CanvasTemplate,
        canvasId: String
    ) -> CanvasRenderProfile {
        let layout: CanvasRenderLayoutKind = template.sceneSpec == nil
            ? (template.kind == .monitor ? .collection : .graph)
            : .spatial
        var profile = CanvasRenderProfile.default(layout: layout)

        for (index, spec) in template.defaultNodes.enumerated() {
            let nodeId = "\(canvasId)-\(template.id)-\(index)"
            profile.values.objects["node:\(nodeId)"] = CanvasRenderObjectValues(
                x: spec.positionHint?["x"] ?? Double(index) * 320,
                y: spec.positionHint?["y"] ?? 0,
                width: spec.positionHint?["width"] ?? 300,
                height: spec.positionHint?["height"] ?? 168,
                zIndex: nil,
                hidden: nil,
                collapsed: nil,
                pinned: nil,
                rendererVariant: spec.widget?.kind.rawValue,
                density: nil,
                icon: nil,
                designToken: nil
            )
        }

        if let scene = materializeSceneSpec(template: template, canvasId: canvasId) {
            var metadata: [String: BoardJSONValue] = ["sceneKind": .string(scene.kind)]
            if let initialState = scene.initialState {
                metadata["initialState"] = initialState
            }
            if let sceneSpecValue = boardJSONValue(scene) {
                metadata["sceneSpec"] = sceneSpecValue
            }
            profile.values.renderOnlyObjects.append(CanvasObject(
                id: "scene:\(scene.kind):background",
                label: "\(scene.kind) background",
                entityRef: nil,
                renderOnly: CanvasRenderOnlyObject(kind: .background, id: "scene:\(scene.kind):background"),
                renderer: .asset,
                values: nil,
                metadata: .object(metadata)
            ))
            for action in scene.actions {
                profile.logic.actions.append(CanvasRenderActionRule(
                    id: "scene-action:\(action.id)",
                    action: .runSceneAction,
                    label: action.label,
                    targetObjectId: "node:\(action.nodeId)",
                    sceneActionId: action.id
                ))
            }
        }

        return profile
    }
}

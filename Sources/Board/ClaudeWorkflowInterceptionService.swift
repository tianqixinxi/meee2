import Foundation

enum ClaudeWorkflowCanvasMode: String, CaseIterable {
    static let defaultsKey = "meee2.claudeWorkflowCanvasMode"

    case off
    case ask
    case auto

    static func current(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeWorkflowCanvasMode {
        if let raw = environment["MEEE2_CLAUDE_WORKFLOW_CANVAS_MODE"],
           let mode = ClaudeWorkflowCanvasMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return mode
        }
        let raw = defaults.string(forKey: defaultsKey) ?? ClaudeWorkflowCanvasMode.ask.rawValue
        return ClaudeWorkflowCanvasMode(rawValue: raw) ?? .ask
    }
}

enum ClaudeWorkflowInterceptionOutcome: Equatable {
    case ignored
    case confirmationRequired(
        workflowId: String,
        commandName: String,
        meee2Prompt: String,
        claudePrompt: String
    )
    case intercepted(
        canvasId: String,
        workflowId: String,
        commandName: String,
        canvasName: String,
        mode: ClaudeWorkflowCanvasMode,
        reused: Bool,
        runId: String?
    )
    case failed(reason: String)
}

final class ClaudeWorkflowInterceptionService {
    static let shared = ClaudeWorkflowInterceptionService()

    typealias RunStarter = (
        _ canvasId: String,
        _ snapshot: BoardLayoutStore.Snapshot,
        _ title: String?,
        _ summary: String?
    ) throws -> WorkflowRun

    private struct CachedImport {
        let createdAt: Date
        let canvasId: String
        let workflowId: String
        let commandName: String
        let canvasName: String
        let runId: String?
    }

    private enum MatchedWorkflow {
        case saved(ClaudeWorkflowFile)
        case native(goal: String)

        var workflowId: String {
            switch self {
            case .saved(let workflow): return workflow.id
            case .native(let goal): return "native:\(ClaudeWorkflowInterceptionService.stableHash(goal))"
            }
        }

        var commandName: String {
            switch self {
            case .saved(let workflow): return workflow.commandName
            case .native(let goal): return "workflow \(goal)"
            }
        }

        var canvasName: String {
            switch self {
            case .saved(let workflow): return workflow.name
            case .native(let goal): return ClaudeWorkflowInterceptionService.nativeCanvasName(goal: goal)
            }
        }
    }

    private let library: ClaudeWorkflowLibrary
    private let importer: ClaudeWorkflowImporter
    private let modeProvider: () -> ClaudeWorkflowCanvasMode
    private let runStarter: RunStarter
    private let broadcaster: () -> Void
    private let boardOpener: (String) -> Void
    private let now: () -> Date
    private let cacheTTL: TimeInterval
    private var cache: [String: CachedImport] = [:]
    private let cacheLock = NSLock()

    init(
        library: ClaudeWorkflowLibrary = .shared,
        importer: ClaudeWorkflowImporter? = nil,
        modeProvider: @escaping () -> ClaudeWorkflowCanvasMode = { ClaudeWorkflowCanvasMode.current() },
        runStarter: @escaping RunStarter = { canvasId, snapshot, title, summary in
            try PlannerBoardBridge.startRun(
                for: canvasId,
                snapshot: snapshot,
                actorUserId: PlannerPermission.currentActorId(),
                title: title,
                summary: summary
            )
        },
        broadcaster: @escaping () -> Void = { BoardServer.shared.broadcastStateChanged() },
        boardOpener: @escaping (String) -> Void = { canvasId in
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("meee2.openPlannerItem"),
                    object: nil,
                    userInfo: ["canvasId": canvasId]
                )
            }
        },
        now: @escaping () -> Date = Date.init,
        cacheTTL: TimeInterval = 120
    ) {
        self.library = library
        self.importer = importer ?? ClaudeWorkflowImporter(library: library)
        self.modeProvider = modeProvider
        self.runStarter = runStarter
        self.broadcaster = broadcaster
        self.boardOpener = boardOpener
        self.now = now
        self.cacheTTL = cacheTTL
    }

    func controlResponse(for event: HookEvent) -> PermissionResponse? {
        guard event.event == .userPromptSubmit else { return nil }
        guard let rawPrompt = Self.promptText(fromRawJSON: event.rawData ?? "") else { return nil }

        switch intercept(sessionId: event.sessionId, cwd: event.cwd, rawPrompt: rawPrompt) {
        case .ignored:
            return nil
        case let .confirmationRequired(_, commandName, meee2Prompt, claudePrompt):
            let reason = """
            meee2 detected Claude Code workflow \(commandName).

            No canvas has been created yet.

            To run it in meee2 Canvas, submit:
            \(meee2Prompt)

            To let Claude Code handle it here, submit:
            \(claudePrompt)
            """
            return PermissionResponse(decision: "block", reason: reason)
        case .failed(let reason):
            MWarn("[ClaudeWorkflowInterception] failed sid=\(event.sessionId?.prefix(8) ?? "?"): \(reason)")
            return nil
        case let .intercepted(canvasId, _, commandName, canvasName, mode, reused, runId):
            let modeText = runId != nil
                ? "started a planner run\(runId.map { " \($0.prefix(8))" } ?? "")"
                : mode == .auto
                    ? "started a planner run"
                    : "is waiting for you to start the run from the canvas"
            let reusedText = reused ? "Reusing the existing canvas" : "Created a meee2 canvas"
            let reason = """
            \(reusedText) "\(canvasName)" for Claude Code workflow \(commandName). The original Claude Code workflow command was stopped before it could run here; meee2 Canvas \(modeText). meee2 is opening the Board to canvas \(canvasId.prefix(8)).
            """
            return PermissionResponse(decision: "block", reason: reason)
        }
    }

    func intercept(sessionId: String?, cwd: String?, rawPrompt: String) -> ClaudeWorkflowInterceptionOutcome {
        let mode = modeProvider()
        guard mode != .off else { return .ignored }
        guard let match = matchWorkflow(rawPrompt: rawPrompt) else { return .ignored }
        if Self.containsControlFlag(.claude, in: rawPrompt) {
            return .ignored
        }
        if case .saved(let workflow) = match, !workflow.readable {
            return .failed(reason: workflow.error ?? "workflow is not readable")
        }
        let confirmedForMeee2 = Self.containsControlFlag(.meee2, in: rawPrompt)
        if mode == .ask && !confirmedForMeee2 {
            return .confirmationRequired(
                workflowId: match.workflowId,
                commandName: match.commandName,
                meee2Prompt: Self.promptByAppendingControlFlag(.meee2, to: rawPrompt),
                claudePrompt: Self.promptByAppendingControlFlag(.claude, to: rawPrompt)
            )
        }

        let key = cacheKey(
            sessionId: sessionId,
            cwd: cwd,
            workflowId: match.workflowId,
            rawPrompt: Self.promptWithoutControlFlags(rawPrompt)
        )
        if let cached = cachedImport(for: key) {
            _ = try? BoardLayoutStore.shared.updateCanvas(id: cached.canvasId, name: nil, active: true)
            broadcaster()
            boardOpener(cached.canvasId)
            return .intercepted(
                canvasId: cached.canvasId,
                workflowId: cached.workflowId,
                commandName: cached.commandName,
                canvasName: cached.canvasName,
                mode: mode,
                reused: true,
                runId: cached.runId
            )
        }

        do {
            let snapshot = try importMatchedWorkflow(match)
            let canvasId = snapshot.activeCanvasId
            let canvasName = snapshot.canvases.first(where: { $0.id == canvasId })?.name ?? match.canvasName
            var runId: String?
            if mode == .auto || confirmedForMeee2 {
                let displayPrompt = Self.promptWithoutControlFlags(rawPrompt)
                let run = try runStarter(
                    canvasId,
                    BoardLayoutStore.shared.snapshot(),
                    "Claude workflow \(match.commandName)",
                    "Imported from Claude Code workflow command: \(displayPrompt)"
                )
                runId = run.id
            }

            remember(CachedImport(
                createdAt: now(),
                canvasId: canvasId,
                workflowId: match.workflowId,
                commandName: match.commandName,
                canvasName: canvasName,
                runId: runId
            ), for: key)
            broadcaster()
            boardOpener(canvasId)
            MInfo("[ClaudeWorkflowInterception] intercepted command=\(match.commandName) canvas=\(canvasId.prefix(8)) mode=\(mode.rawValue)")
            return .intercepted(
                canvasId: canvasId,
                workflowId: match.workflowId,
                commandName: match.commandName,
                canvasName: canvasName,
                mode: mode,
                reused: false,
                runId: runId
            )
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private func matchWorkflow(rawPrompt: String) -> MatchedWorkflow? {
        if let commandName = Self.leadingSlashCommand(in: rawPrompt) {
            let scan = library.scan()
            return scan.workflows
                .first(where: { $0.commandName == commandName })
                .map(MatchedWorkflow.saved)
        }
        if let goal = Self.nativeWorkflowGoal(in: rawPrompt) {
            return .native(goal: goal)
        }
        return nil
    }

    private func importMatchedWorkflow(_ match: MatchedWorkflow) throws -> BoardLayoutStore.Snapshot {
        switch match {
        case .saved(let workflow):
            return try importer.importWorkflow(id: workflow.id, name: nil, scope: .personal)
        case .native(let goal):
            return try importNativeWorkflow(goal: goal)
        }
    }

    private func importNativeWorkflow(goal: String) throws -> BoardLayoutStore.Snapshot {
        let canvasName = Self.nativeCanvasName(goal: goal)
        let snapshot = try BoardLayoutStore.shared.createCanvas(
            name: canvasName,
            scope: .personal,
            kind: .board
        )
        let canvasId = snapshot.activeCanvasId
        guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
            throw ClaudeWorkflowLibraryError.unreadable("freshly created canvas missing from snapshot")
        }
        let ownerId = boardCanvas.ownerUserId ?? boardCanvas.createdBy ?? "local-owner"
        let planningCanvas = PlanningCanvas(
            id: boardCanvas.id,
            ownerId: ownerId,
            title: boardCanvas.name,
            plannerContext: "claude-native-workflow:\(goal)"
        )
        let runNodeId = "\(canvasId)-claude-native-workflow-run"
        let nodes = [
            PlanningNode(
                id: runNodeId,
                canvasId: canvasId,
                title: "Run workflow",
                schema: NodeSchema(
                    inputs: [],
                    outputs: ["workflow result"],
                    goal: "Run Claude Code workflow: \(goal)"
                ),
                contextSources: [
                    ContextSource(kind: .document, title: "Claude Code native workflow request", reference: goal)
                ],
                executionMode: .auto,
                executorType: .claude,
                doerId: ownerId,
                status: .ready,
                source: .planner,
                dependsOnNodeIds: nil,
                nodeKind: .step,
                layout: PlannerNodeLayout(x: 0, y: 0, width: 300, height: 176),
                dispatch: PlannerNodeDispatch(
                    runner: .claude,
                    skill: "claude-code-workflow",
                    actor: ownerId,
                    command: "workflow \(goal)",
                    fallbackRunner: nil
                ),
                workflowRunState: .pending,
                blockedReason: nil
            )
        ]
        _ = try PlannerBoardBridge.store.record(for: planningCanvas, seedNodes: [])
        _ = try PlannerBoardBridge.store.setCanvasContext(planningCanvas.plannerContext, canvasId: canvasId)
        _ = try PlannerBoardBridge.store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: nodes)
        return snapshot
    }

    static func leadingSlashCommand(in rawPrompt: String) -> String? {
        let trimmed = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let command = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        guard command.count > 1 else { return nil }
        return command
    }

    static func nativeWorkflowGoal(in rawPrompt: String) -> String? {
        let tokens = promptTokens(rawPrompt).filter { token in
            token != ControlFlag.meee2.rawValue && token != ControlFlag.claude.rawValue
        }
        guard let first = tokens.first, first.caseInsensitiveCompare("workflow") == .orderedSame else {
            return nil
        }
        let goal = tokens.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? nil : goal
    }

    enum ControlFlag: String {
        case meee2 = "--meee2"
        case claude = "--claude"
    }

    static func containsControlFlag(_ flag: ControlFlag, in rawPrompt: String) -> Bool {
        promptTokens(rawPrompt).contains(flag.rawValue)
    }

    static func promptByAppendingControlFlag(_ flag: ControlFlag, to rawPrompt: String) -> String {
        let tokens = promptTokens(rawPrompt).filter { token in
            token != ControlFlag.meee2.rawValue && token != ControlFlag.claude.rawValue
        }
        return (tokens + [flag.rawValue]).joined(separator: " ")
    }

    static func promptWithoutControlFlags(_ rawPrompt: String) -> String {
        let tokens = promptTokens(rawPrompt).filter { token in
            token != ControlFlag.meee2.rawValue && token != ControlFlag.claude.rawValue
        }
        return tokens.joined(separator: " ")
    }

    private static func promptTokens(_ rawPrompt: String) -> [String] {
        rawPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func nativeCanvasName(goal: String) -> String {
        let compact = goal
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let capped = compact.count > 64 ? String(compact.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines) : compact
        return capped.isEmpty ? "Claude workflow" : "Workflow: \(capped)"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    static func promptText(fromRawJSON raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let value = firstPromptString(in: object) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static func firstPromptString(in object: Any) -> String? {
        let promptKeys = ["prompt", "user_prompt", "userPrompt", "message", "input"]
        if let dict = object as? [String: Any] {
            for key in promptKeys {
                if let value = dict[key] as? String {
                    return value
                }
            }
            for value in dict.values {
                if let prompt = firstPromptString(in: value) {
                    return prompt
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let prompt = firstPromptString(in: value) {
                    return prompt
                }
            }
        }
        return nil
    }

    private func cacheKey(sessionId: String?, cwd: String?, workflowId: String, rawPrompt: String) -> String {
        [
            sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            workflowId,
            rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    private func cachedImport(for key: String) -> CachedImport? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        purgeExpiredLocked()
        return cache[key]
    }

    private func remember(_ value: CachedImport, for key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        purgeExpiredLocked()
        cache[key] = value
    }

    private func purgeExpiredLocked() {
        let cutoff = now().addingTimeInterval(-cacheTTL)
        cache = cache.filter { $0.value.createdAt >= cutoff }
    }
}

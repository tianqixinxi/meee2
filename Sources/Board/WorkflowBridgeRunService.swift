import Foundation
import Meee2CommKit

/// workflow-bridge 代理执行的 meee2 侧宿主：把被拦截的 Claude Code Workflow
/// 变成一块可视化 canvas，并向源会话回流进度。
///
/// 链路（与 meee2-workflow-bridge 插件 0.2.0 配套）：
///   1. bridge 拦截原生 Workflow 调用 → 落盘 runDir → `POST /api/workflow-bridge/runs`
///   2. `register()`：建 personal canvas（exec 根 `.step` + phase 骨架 `.external`）
///      → spawn relay 会话（surface 直标 canvasId/nodeId）→ runState 自动回流
///   3. `tick()`（2s）：从 relay surface 解析 CLI 会话 → transcript dir → 发现
///      `subagents/workflows/wf_*` → 增量 tail journal.jsonl：
///        `started` → 动态追加 agent 镜像节点（`.external`，fan-out 挂 exec 根）
///        `result`  → 节点置 done + 挂结果 artifact
///      runDir/result.md 出现 → finalize(done)；停滞且 relay 已死 → failed + inject 源会话
///   4. 每次变化原子写 runDir/status.json —— 源会话（任何 Claude 会话）可
///      Read/Monitor 这个文件获得结构化进度，这就是"源会话感知"的文件协议。
///
/// journal 是引擎唯一的逐 agent 事件流（只有 started/result 两种事件、无
/// label/phase），agent 语义靠 agent-<id>.jsonl 首条 prompt + meta.json 的
/// agentType 事后精化；phase 归属运行时不可知，骨架节点只做静态展示。
final class WorkflowBridgeRunService {
    static let shared = WorkflowBridgeRunService()

    // MARK: - 注册请求/响应

    struct RegistrationPhase: Codable {
        let title: String
        let detail: String?
    }

    struct RegistrationMeta: Codable {
        let name: String?
        let description: String?
        let phases: [RegistrationPhase]?
    }

    struct Registration: Codable {
        let runId: String
        let runDir: String
        let originSessionId: String?
        let cwd: String
        let command: String
        let workflowName: String?
        let meta: RegistrationMeta?
    }

    struct RegisterResult: Codable {
        let canvasId: String
        let canvasName: String
        let sessionId: String
        let surfaceId: String
        let statusPath: String
    }

    // MARK: - 运行态

    enum RunState: String, Codable {
        case spawning
        case running
        case done
        case failed
    }

    struct AgentEntry: Codable {
        var agentId: String
        var nodeId: String
        var title: String
        var state: String        // "running" | "done"
        var startedAt: Date
        var titleRefined: Bool
    }

    struct RunHandle: Codable {
        let runId: String
        let runDir: String
        let canvasId: String
        let canvasName: String
        let originSessionId: String?
        let execNodeId: String
        let phaseNodeIds: [String]
        let surfaceSessionId: String
        var surfaceId: String?
        let workflowName: String?
        let workflowDescription: String?
        var relayCliSessionId: String?
        var transcriptDir: String?
        var wfDir: String?
        var journalOffset: UInt64 = 0
        var agents: [String: AgentEntry] = [:]   // agentId → entry
        var state: RunState
        var lastEvent: String
        var lastEventAt: Date
        var registeredAt: Date
        var error: String?
    }

    private let lock = NSLock()
    private let registrationCondition = NSCondition()
    private var registrationsInFlight = Set<String>()
    private var runs: [String: RunHandle] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "meee2.workflow-bridge-run-service", qos: .utility)

    /// relay CLI 会话出现的宽限（surface spawn → claude 起来发首个 hook）
    private let cliResolveGrace: TimeInterval = 120
    /// journal/agent 文件静默 + relay 已死 → 判失败。测试可经 env 调小。
    private let stallThreshold: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["MEEE2_WFBRIDGE_STALL_SECONDS"],
           let value = TimeInterval(raw), value > 0 {
            return value
        }
        return 10 * 60
    }()

    // MARK: - 生命周期

    func start() {
        guard timer == nil else { return }
        restoreFromDisk()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        MInfo("[WorkflowBridge] run service started (\(runs.count) run(s) restored)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - 注册（HTTP handler 调）

    func register(_ reg: Registration) throws -> RegisterResult {
        registrationCondition.lock()
        while registrationsInFlight.contains(reg.runId) {
            registrationCondition.wait()
        }
        registrationsInFlight.insert(reg.runId)
        registrationCondition.unlock()
        defer {
            registrationCondition.lock()
            registrationsInFlight.remove(reg.runId)
            registrationCondition.broadcast()
            registrationCondition.unlock()
        }

        // 幂等：同 runId 重复注册（bridge 重试）直接返回既有记录
        lock.lock()
        if let existing = runs[reg.runId] {
            lock.unlock()
            return RegisterResult(
                canvasId: existing.canvasId,
                canvasName: existing.canvasName,
                sessionId: existing.surfaceSessionId,
                surfaceId: existing.surfaceId
                    ?? TerminalSessionBackendRegistry.shared.snapshot(id: existing.surfaceSessionId)?.surfaceId
                    ?? existing.surfaceSessionId,
                statusPath: statusPath(runDir: existing.runDir)
            )
        }
        lock.unlock()

        // Restart-safe idempotency: terminal handles are not watched after a
        // restart, but they still prove that this runId was already
        // provisioned and must not create a second canvas/session.
        let persistedHandlePath = (reg.runDir as NSString).appendingPathComponent("handle.json")
        if let data = FileManager.default.contents(atPath: persistedHandlePath),
           let existing = try? Self.handleDecoder.decode(RunHandle.self, from: data),
           existing.runId == reg.runId {
            return RegisterResult(
                canvasId: existing.canvasId,
                canvasName: existing.canvasName,
                sessionId: existing.surfaceSessionId,
                surfaceId: existing.surfaceId ?? existing.surfaceSessionId,
                statusPath: statusPath(runDir: existing.runDir)
            )
        }

        let displayName = reg.meta?.name ?? reg.workflowName ?? reg.runId
        let stamp: String = {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            return f.string(from: Date())
        }()
        let canvasName = "WF: \(displayName) · \(stamp)"

        // 1. 外层板（personal scope：不进团队同步）
        let snapshot = try BoardLayoutStore.shared.createCanvas(
            name: canvasName,
            scope: .personal,
            kind: .board
        )
        let canvasId = snapshot.activeCanvasId
        var committed = false
        defer {
            if !committed {
                try? PlannerBoardBridge.store.removeCanvasRecord(canvasId: canvasId)
                _ = try? BoardLayoutStore.shared.deleteCanvas(id: canvasId)
            }
        }
        guard let boardCanvas = snapshot.canvases.first(where: { $0.id == canvasId }) else {
            throw PlannerCoreError.canvasNotFound(canvasId)
        }
        let ownerId = boardCanvas.ownerUserId ?? boardCanvas.createdBy ?? "local-owner"

        // 2. planner 图：exec 根 + phase 骨架
        let planningCanvas = PlanningCanvas(
            id: canvasId,
            ownerId: ownerId,
            title: canvasName,
            plannerContext: "workflow-bridge:\(reg.runId)"
        )
        let execNodeId = "wfb-\(reg.runId)-exec"
        var seedNodes: [PlanningNode] = [
            PlanningNode(
                id: execNodeId,
                canvasId: canvasId,
                title: "Relay 执行",
                schema: NodeSchema(
                    inputs: [],
                    outputs: ["workflow result"],
                    goal: reg.meta?.description
                        ?? "Execute relayed Claude Code workflow \(displayName)"
                ),
                contextSources: [
                    ContextSource(
                        kind: .document,
                        title: "workflow-bridge run",
                        reference: reg.runDir
                    )
                ],
                executionMode: .auto,
                executorType: .claude,
                doerId: ownerId,
                status: .ready,
                nodeKind: .step,
                layout: PlannerNodeLayout(x: 0, y: 0, width: 300, height: 176),
                dispatch: PlannerNodeDispatch(
                    runner: .claude,
                    skill: "workflow-bridge-relay",
                    actor: ownerId,
                    command: reg.command,
                    fallbackRunner: nil
                ),
                workflowRunState: .dispatched
            )
        ]
        var phaseNodeIds: [String] = []
        for (index, phase) in (reg.meta?.phases ?? []).enumerated() {
            let phaseNodeId = "wfb-\(reg.runId)-phase-\(index)"
            phaseNodeIds.append(phaseNodeId)
            seedNodes.append(PlanningNode(
                id: phaseNodeId,
                canvasId: canvasId,
                title: phase.title,
                schema: NodeSchema(inputs: [], outputs: [], goal: phase.detail ?? phase.title),
                contextSources: [],
                executionMode: .auto,
                executorType: .claude,
                doerId: ownerId,
                status: .ready,
                dependsOnNodeIds: [index == 0 ? execNodeId : phaseNodeIds[index - 1]],
                nodeKind: .external,
                layout: PlannerNodeLayout(
                    x: Double((index + 1) * 400), y: -300, width: 300, height: 150
                ),
                workflowRunState: .pending
            ))
        }
        _ = try PlannerBoardBridge.store.record(for: planningCanvas, seedNodes: [])
        _ = try PlannerBoardBridge.store.setCanvasContext(
            planningCanvas.plannerContext, canvasId: canvasId
        )
        _ = try PlannerBoardBridge.store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: seedNodes)

        // 3. spawn relay 会话（surface 直标 canvas/node 归属；command 由 bridge
        //    原样传来，含 MEEE2_WORKFLOW_RELAY=1 前缀 → 防循环 guard 不变）
        let surface = try SessionSurfaceLauncher.createInternalSessionSurface(
            provider: "claude",
            cwd: reg.cwd,
            command: reg.command,
            createIfMissing: false,
            canvasId: canvasId,
            nodeId: execNodeId,
            initialPrompt: nil,
            preferredSessionId: nil,
            recordLauncherInitialPrompt: false
        )

        // 4. 绑定 exec 根 → PlannerSessionRunStateBridge 之后自动回流会话状态
        _ = PlannerSessionRunStateBridge.observe(
            sessionId: surface.sessionId,
            purpose: "planner:\(execNodeId)",
            status: .active
        )

        let handle = RunHandle(
            runId: reg.runId,
            runDir: reg.runDir,
            canvasId: canvasId,
            canvasName: canvasName,
            originSessionId: reg.originSessionId,
            execNodeId: execNodeId,
            phaseNodeIds: phaseNodeIds,
            surfaceSessionId: surface.sessionId,
            surfaceId: surface.surfaceId,
            workflowName: displayName,
            workflowDescription: reg.meta?.description,
            state: .spawning,
            lastEvent: "relay session spawned",
            lastEventAt: Date(),
            registeredAt: Date()
        )
        writeStatus(handle)
        persistHandle(handle)

        lock.lock()
        runs[reg.runId] = handle
        lock.unlock()
        committed = true

        MInfo("[WorkflowBridge] registered run=\(reg.runId) canvas=\(canvasId.prefix(8)) relay=\(surface.sessionId.prefix(8))")
        return RegisterResult(
            canvasId: canvasId,
            canvasName: canvasName,
            sessionId: surface.sessionId,
            surfaceId: surface.surfaceId,
            statusPath: statusPath(runDir: reg.runDir)
        )
    }

    // MARK: - tick 状态机

    private func tick() {
        let active: [RunHandle]
        lock.lock()
        active = runs.values.filter { $0.state == .spawning || $0.state == .running }
        lock.unlock()

        for handle in active {
            var h = handle
            let before = snapshotForChangeDetection(h)
            step(&h)
            if snapshotForChangeDetection(h) != before {
                lock.lock()
                runs[h.runId] = h
                lock.unlock()
                writeStatus(h)
                persistHandle(h)
            }
        }
    }

    private func snapshotForChangeDetection(_ h: RunHandle) -> String {
        let agentState = h.agents.values.sorted { $0.agentId < $1.agentId }
            .map { "\($0.agentId):\($0.state):\($0.title):\($0.titleRefined)" }
            .joined(separator: "|")
        return "\(h.state.rawValue)|\(h.relayCliSessionId ?? "")|\(h.wfDir ?? "")|\(h.journalOffset)|\(agentState)|\(h.lastEvent)|\(h.error ?? "")"
    }

    private func step(_ h: inout RunHandle) {
        // 完成主信号：relay 按 instructions 写 result.md
        let resultPath = (h.runDir as NSString).appendingPathComponent("result.md")
        if FileManager.default.fileExists(atPath: resultPath) {
            // 先把 journal 尾巴吃干净再收官
            if h.wfDir != nil { tailJournal(&h) }
            finalize(&h, state: .done, error: nil)
            return
        }

        // 解析 relay 的 CLI 会话（surface → providerResumeSessionId → transcriptPath）
        if h.relayCliSessionId == nil {
            if let info = SessionTerminalStore.shared.get(sessionId: h.surfaceSessionId),
               let cliSid = info.providerResumeSessionId, !cliSid.isEmpty {
                h.relayCliSessionId = cliSid
                h.lastEvent = "relay CLI session resolved"
                h.lastEventAt = Date()
            } else if Date().timeIntervalSince(h.registeredAt) > cliResolveGrace,
                      !isRelayAlive(h) {
                finalize(
                    &h, state: .failed,
                    error: "relay 会话在 \(Int(cliResolveGrace))s 内未启动 Claude CLI 且已退出"
                )
                return
            }
        }

        // 定位 transcript dir 与 wf 目录
        if h.transcriptDir == nil, let cliSid = h.relayCliSessionId {
            if let transcriptPath = SessionStore.shared.get(cliSid)?.transcriptPath,
               !transcriptPath.isEmpty {
                let url = URL(fileURLWithPath: transcriptPath)
                h.transcriptDir = url.deletingPathExtension().path
            }
        }
        if h.wfDir == nil, let transcriptDir = h.transcriptDir {
            h.wfDir = discoverWorkflowDir(transcriptDir: transcriptDir, runDir: h.runDir)
            if h.wfDir != nil {
                h.state = .running
                h.lastEvent = "workflow run dir discovered"
                h.lastEventAt = Date()
            }
        }

        if h.wfDir != nil {
            tailJournal(&h)
            refineAgentTitles(&h)
        }

        // 停滞检测：journal/agent 文件都不动 && relay 会话不在了 → 失败
        if let stalledFor = stallDuration(h), stalledFor > stallThreshold, !isRelayAlive(h) {
            finalize(
                &h, state: .failed,
                error: "relay 会话已退出且 \(Int(stalledFor / 60)) 分钟无进展（result.md 未产出）"
            )
        }
    }

    /// `subagents/workflows/` 下找本 run 的 wf_* 目录。多个候选时用
    /// `<transcriptDir>/workflows/wf_*.json` 携带的 script 全文与
    /// runDir/workflow.mjs 精确配对；比不中取 mtime 最新。
    func discoverWorkflowDir(transcriptDir: String, runDir: String) -> String? {
        let fm = FileManager.default
        let wfRoot = (transcriptDir as NSString).appendingPathComponent("subagents/workflows")
        guard let entries = try? fm.contentsOfDirectory(atPath: wfRoot) else { return nil }
        let candidates = entries.filter { $0.hasPrefix("wf_") }
        guard !candidates.isEmpty else { return nil }
        let scriptPath = (runDir as NSString).appendingPathComponent("workflow.mjs")
        let script = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        let metaRoot = (transcriptDir as NSString).appendingPathComponent("workflows")
        var foundMetadataForCandidate = false
        if let script, let metaEntries = try? fm.contentsOfDirectory(atPath: metaRoot) {
            for metaName in metaEntries where metaName.hasPrefix("wf_") && metaName.hasSuffix(".json") {
                let metaPath = (metaRoot as NSString).appendingPathComponent(metaName)
                guard let data = fm.contents(atPath: metaPath),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let recorded = obj["script"] as? String else { continue }
                if recorded == script {
                    let dirName = (metaName as NSString).deletingPathExtension
                    if candidates.contains(dirName) {
                        return (wfRoot as NSString).appendingPathComponent(dirName)
                    }
                }
                let dirName = (metaName as NSString).deletingPathExtension
                if candidates.contains(dirName) {
                    foundMetadataForCandidate = true
                }
            }
        }

        // A fresh relay normally has one candidate. Multiple unmatched
        // candidates are ambiguous: waiting/failing is safer than mirroring a
        // different workflow into this canvas.
        if script != nil && foundMetadataForCandidate {
            return nil
        }
        if candidates.count == 1 {
            return (wfRoot as NSString).appendingPathComponent(candidates[0])
        }
        return nil
    }

    // MARK: - journal tail

    /// 单行上限：result 事件携带 agent 返回全文，正常几 KB；超过 2MB 视为
    /// 异常行，丢弃避免无界内存。
    private let maxJournalLineBytes = 2 * 1024 * 1024

    func tailJournal(_ h: inout RunHandle) {
        guard let wfDir = h.wfDir else { return }
        let journalPath = (wfDir as NSString).appendingPathComponent("journal.jsonl")
        guard let handle = FileHandle(forReadingAtPath: journalPath) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < h.journalOffset {
            h.journalOffset = 0
            h.lastEvent = "workflow journal rotated; resumed from beginning"
            h.lastEventAt = Date()
        }
        guard size > h.journalOffset else { return }
        try? handle.seek(toOffset: h.journalOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // 只消费完整行；最后半行留给下一轮（引擎是整行 append，短暂即齐）
        var consumable = data
        if data.last != UInt8(ascii: "\n") {
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                consumable = data.prefix(through: lastNewline)
            } else {
                if data.count > maxJournalLineBytes {
                    h.journalOffset += UInt64(data.count)   // 异常巨行，跳过
                }
                return
            }
        }
        h.journalOffset += UInt64(consumable.count)

        for lineData in consumable.split(separator: UInt8(ascii: "\n")) {
            guard lineData.count <= maxJournalLineBytes,
                  let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  let type = obj["type"] as? String,
                  let agentId = obj["agentId"] as? String else { continue }
            switch type {
            case "started":
                appendAgentNode(&h, agentId: agentId)
            case "result":
                finishAgentNode(&h, agentId: agentId, result: obj["result"] as? String)
            default:
                break
            }
        }
    }

    private func appendAgentNode(_ h: inout RunHandle, agentId: String) {
        guard h.agents[agentId] == nil else { return }
        let index = h.agents.count
        let nodeId = "wfb-\(h.runId)-agent-\(agentId)"
        let title = "agent \(agentId.prefix(8))"
        // fan-out 布局：exec 根右侧列，每列 6 个
        let column = index / 6
        let row = index % 6
        let node = PlanningNode(
            id: nodeId,
            canvasId: h.canvasId,
            title: title,
            schema: NodeSchema(inputs: [], outputs: ["result"], goal: "Workflow subagent"),
            contextSources: [],
            executionMode: .auto,
            executorType: .claude,
            doerId: "workflow-bridge",
            status: .ready,
            dependsOnNodeIds: [h.execNodeId],
            nodeKind: .external,
            layout: PlannerNodeLayout(
                x: Double(560 + column * 380), y: Double(row * 270), width: 300, height: 150
            ),
            workflowRunState: .running
        )
        do {
            _ = try PlannerBoardBridge.store.appendNodes(canvasId: h.canvasId, nodes: [node])
            h.agents[agentId] = AgentEntry(
                agentId: agentId, nodeId: nodeId, title: title,
                state: "running", startedAt: Date(), titleRefined: false
            )
            h.lastEvent = "agent \(agentId.prefix(8)) started"
            h.lastEventAt = Date()
        } catch {
            MWarn("[WorkflowBridge] appendNodes failed run=\(h.runId) agent=\(agentId): \(error)")
        }
    }

    private func finishAgentNode(_ h: inout RunHandle, agentId: String, result: String?) {
        if h.agents[agentId] == nil {
            // started 在 tail 窗口外/丢失——先补节点再收
            appendAgentNode(&h, agentId: agentId)
        }
        guard var entry = h.agents[agentId] else { return }
        do {
            _ = try PlannerBoardBridge.store.applyWorkflowNodeState(
                canvasId: h.canvasId,
                nodeId: entry.nodeId,
                runState: .done,
                status: .done
            )
            if let result, !result.isEmpty {
                let preview = String(result.prefix(4096))
                let artifact = PlannerArtifact(
                    id: "artifact-\(UUID().uuidString.lowercased())",
                    canvasId: h.canvasId,
                    nodeId: entry.nodeId,
                    kind: .checkResult,
                    title: "result · \(entry.title)",
                    reference: "wfbridge://\(h.runId)/\(agentId)",
                    status: "done",
                    createdAt: Date(),
                    payload: .string(preview),
                    producedBy: .agent
                )
                _ = try? PlannerBoardBridge.store.attachArtifact(artifact, canvasId: h.canvasId)
            }
            entry.state = "done"
            h.agents[agentId] = entry
            h.lastEvent = "agent \(agentId.prefix(8)) result received"
            h.lastEventAt = Date()
        } catch {
            MWarn("[WorkflowBridge] finishAgentNode failed run=\(h.runId) agent=\(agentId): \(error)")
        }
    }

    /// agent 节点标题精化：agent-<id>.jsonl 首条 user 消息的 prompt 首行 +
    /// meta.json 的 agentType。文件出现有延迟，逐 tick 重试直到成功。
    private func refineAgentTitles(_ h: inout RunHandle) {
        guard let wfDir = h.wfDir else { return }
        for (agentId, entry) in h.agents where !entry.titleRefined {
            var refined = entry
            var parts: [String] = []
            let metaPath = (wfDir as NSString).appendingPathComponent("agent-\(agentId).meta.json")
            if let data = FileManager.default.contents(atPath: metaPath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let agentType = obj["agentType"] as? String,
               agentType != "workflow-subagent" {
                parts.append(agentType)
            }
            if let promptLine = firstPromptLine(wfDir: wfDir, agentId: agentId) {
                parts.append(promptLine)
            }
            guard !parts.isEmpty else { continue }
            let title = String(parts.joined(separator: " · ").prefix(60))
            do {
                _ = try PlannerBoardBridge.store.applyWorkflowNodeState(
                    canvasId: h.canvasId,
                    nodeId: entry.nodeId,
                    runState: nil,
                    title: title
                )
                refined.title = title
                refined.titleRefined = true
                h.agents[agentId] = refined
            } catch {
                // 标题精化失败不致命，留初始标题
                refined.titleRefined = true
                h.agents[agentId] = refined
            }
        }
    }

    private func firstPromptLine(wfDir: String, agentId: String) -> String? {
        let path = (wfDir as NSString).appendingPathComponent("agent-\(agentId).jsonl")
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        guard let firstLine = data.split(separator: UInt8(ascii: "\n")).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              let msg = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = msg["content"] as? String {
            text = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            text = arr.compactMap { $0["text"] as? String }.first
        }
        guard let text else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 完成/失败

    private func finalize(_ h: inout RunHandle, state: RunState, error: String?) {
        h.state = state
        h.error = error
        h.lastEvent = state == .done ? "workflow completed" : "workflow failed: \(error ?? "unknown")"
        h.lastEventAt = Date()

        // exec 根收官（latch 防会话 idle 镜像回写降级）；phase 骨架统一置终态
        let rootState: PlannerWorkflowRunState = state == .done ? .done : .failed
        let rootStatus: PlanningNodeStatus = state == .done ? .done : .blocked
        _ = try? PlannerBoardBridge.store.applyWorkflowNodeState(
            canvasId: h.canvasId,
            nodeId: h.execNodeId,
            runState: rootState,
            status: rootStatus,
            blockedReason: state == .failed ? (error ?? "workflow failed") : nil,
            latch: true
        )
        for phaseNodeId in h.phaseNodeIds {
            _ = try? PlannerBoardBridge.store.applyWorkflowNodeState(
                canvasId: h.canvasId,
                nodeId: phaseNodeId,
                runState: rootState,
                status: state == .done ? .done : nil
            )
        }
        // 还挂着 running 的 agent 节点收尾
        for (agentId, entry) in h.agents where entry.state == "running" {
            _ = try? PlannerBoardBridge.store.applyWorkflowNodeState(
                canvasId: h.canvasId,
                nodeId: entry.nodeId,
                runState: rootState,
                status: state == .done ? .done : nil
            )
            var updated = entry
            updated.state = state == .done ? "done" : "failed"
            h.agents[agentId] = updated
        }

        // 失败/停滞才由 meee2 inject 源会话（成功通知归 relay 的 curl，避免双发）
        if state == .failed, let origin = h.originSessionId, !origin.isEmpty {
            injectOrigin(
                sessionId: origin,
                text: "[meee2-workflow-bridge] workflow run \(h.runId) 疑似失败：\(error ?? "未知原因")。"
                    + "canvas「\(h.canvasName)」有已完成部分的快照；运行目录 \(h.runDir)。"
            )
        }
        MInfo("[WorkflowBridge] run=\(h.runId) finalized state=\(state.rawValue)\(error.map { " error=\($0)" } ?? "")")
    }

    private func injectOrigin(sessionId: String, text: String) {
        do {
            let channel = try MessageRouter.shared.ensureOperatorChannel(sessionId: sessionId)
            _ = try MessageRouter.shared.send(
                channel: channel,
                fromAlias: "operator",
                toAlias: "session",
                content: text,
                injectedByHuman: false
            )
            BoardServer.shared.broadcastStateChanged()
        } catch {
            MWarn("[WorkflowBridge] inject origin \(sessionId.prefix(8)) failed: \(error)")
        }
    }

    // MARK: - 判活/停滞

    private func isRelayAlive(_ h: RunHandle) -> Bool {
        guard let snapshot = TerminalSessionBackendRegistry.shared.snapshot(id: h.surfaceSessionId) else {
            return false
        }
        if let pid = snapshot.pid, pid > 0 {
            return kill(pid_t(pid), 0) == 0
        }
        // surface 还注册着但没 pid（外部终端等）——按 status 保守判活
        return snapshot.status != "exited" && snapshot.status != "closed"
    }

    private func stallDuration(_ h: RunHandle) -> TimeInterval? {
        var latest = h.lastEventAt
        if let wfDir = h.wfDir {
            let journalPath = (wfDir as NSString).appendingPathComponent("journal.jsonl")
            if let m = mtime(journalPath), m > latest { latest = m }
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: wfDir) {
                for name in entries where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
                    let p = (wfDir as NSString).appendingPathComponent(name)
                    if let m = mtime(p), m > latest { latest = m }
                }
            }
        }
        return Date().timeIntervalSince(latest)
    }

    private func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - status.json（源会话感知的文件协议）

    private func statusPath(runDir: String) -> String {
        (runDir as NSString).appendingPathComponent("status.json")
    }

    private func writeStatus(_ h: RunHandle) {
        let agents = h.agents.values.sorted { $0.startedAt < $1.startedAt }
        var obj: [String: Any] = [
            "version": 1,
            "runId": h.runId,
            "state": h.state.rawValue,
            "canvasId": h.canvasId,
            "canvasName": h.canvasName,
            "boardUrl": BoardServer.shared.url,
            "relaySessionId": h.surfaceSessionId,
            "relayCliSessionId": h.relayCliSessionId as Any,
            "workflow": [
                "name": h.workflowName as Any,
                "description": h.workflowDescription as Any,
                "phasesTotal": h.phaseNodeIds.count
            ],
            "agentsTotal": agents.count,
            "agentsDone": agents.filter { $0.state == "done" }.count,
            "agents": agents.map { entry in
                [
                    "agentId": entry.agentId,
                    "title": entry.title,
                    "state": entry.state,
                    "startedAt": iso8601(entry.startedAt)
                ]
            },
            "lastEvent": h.lastEvent,
            "lastEventAt": iso8601(h.lastEventAt),
            "resultPath": (h.runDir as NSString).appendingPathComponent("result.md"),
            "updatedAt": iso8601(Date())
        ]
        if let error = h.error { obj["error"] = error }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: statusPath(runDir: h.runDir)), options: .atomic)
        } catch {
            MWarn("[WorkflowBridge] status write failed run=\(h.runId): \(error.localizedDescription)")
        }
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - 重启恢复

    /// meee2 重启后扫 runs/*/status.json，非终态且 48h 内的 run 重建内存态
    /// 继续盯（RunHandle 全量随 status 一起持久化在 handle.json）。
    private static let handleEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let handleDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func restoreFromDisk() {
        let root = StorageRoots.processDefault.baseDirectory
            .appendingPathComponent("workflow-bridge/runs", isDirectory: true).path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in entries {
            let runDir = (root as NSString).appendingPathComponent(name)
            let handlePath = (runDir as NSString).appendingPathComponent("handle.json")
            guard let data = FileManager.default.contents(atPath: handlePath),
                  var handle = try? Self.handleDecoder.decode(RunHandle.self, from: data) else {
                continue
            }
            guard handle.state == .spawning || handle.state == .running else { continue }
            guard Date().timeIntervalSince(handle.registeredAt) < 48 * 3600 else { continue }
            handle.lastEvent = "restored after meee2 restart"
            handle.lastEventAt = Date()
            runs[handle.runId] = handle
        }
    }

    /// RunHandle 持久化（写在 status.json 同目录，供 restoreFromDisk 用）
    private func persistHandle(_ h: RunHandle) {
        let path = (h.runDir as NSString).appendingPathComponent("handle.json")
        if let data = try? Self.handleEncoder.encode(h) {
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                MWarn("[WorkflowBridge] handle write failed run=\(h.runId): \(error.localizedDescription)")
            }
        }
    }
}

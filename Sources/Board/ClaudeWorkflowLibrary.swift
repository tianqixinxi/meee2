import Foundation
import CryptoKit

struct ClaudeWorkflowLibraryScan {
    let root: URL
    let workflows: [ClaudeWorkflowFile]
    let error: String?
}

struct ClaudeWorkflowFile: Equatable {
    let id: String
    let name: String
    let commandName: String
    let description: String?
    let phases: [ClaudeWorkflowPhase]
    let path: String
    let sizeBytes: Int
    let modifiedAt: Date
    let preview: String
    let readable: Bool
    let error: String?
}

struct ClaudeWorkflowPhase: Equatable {
    let title: String
    let detail: String?
}

enum ClaudeWorkflowLibraryError: LocalizedError, Equatable {
    case notFound(String)
    case unreadable(String)
    case tooLarge(Int, Int)
    case invalidSource
    case unsupportedFileType(String)
    case aiParseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Claude workflow not found: \(id)"
        case .unreadable(let reason):
            return reason
        case .tooLarge(let size, let max):
            return "Claude workflow is too large to import (\(size) bytes, max \(max) bytes)."
        case .invalidSource:
            return "Claude workflow source is not valid UTF-8 text."
        case .unsupportedFileType(let filename):
            return "Claude workflow upload must be a .js file: \(filename)"
        case .aiParseFailed(let reason):
            return "Claude workflow AI parse failed: \(reason)"
        }
    }
}

final class ClaudeWorkflowLibrary {
    static let shared = ClaudeWorkflowLibrary()
    static let maxSourceBytes = 256 * 1024
    static let previewBytes = 800

    private let fileManager: FileManager
    private let environment: () -> [String: String]
    private let homeDirectory: () -> URL

    init(
        fileManager: FileManager = .default,
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectory: @escaping () -> URL = { URL(fileURLWithPath: NSHomeDirectory()) }
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var workflowsRoot: URL {
        if let raw = environment()["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw).appendingPathComponent("workflows")
        }
        return homeDirectory()
            .appendingPathComponent(".claude")
            .appendingPathComponent("workflows")
    }

    func scan() -> ClaudeWorkflowLibraryScan {
        let root = workflowsRoot
        guard fileManager.fileExists(atPath: root.path) else {
            return ClaudeWorkflowLibraryScan(root: root, workflows: [], error: nil)
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let workflows = urls
                .filter { $0.pathExtension.lowercased() == "js" }
                .compactMap { workflowFile(at: $0) }
                .sorted {
                    if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            return ClaudeWorkflowLibraryScan(root: root, workflows: workflows, error: nil)
        } catch {
            return ClaudeWorkflowLibraryScan(root: root, workflows: [], error: error.localizedDescription)
        }
    }

    func find(id: String) throws -> ClaudeWorkflowFile {
        guard let workflow = scan().workflows.first(where: { $0.id == id }) else {
            throw ClaudeWorkflowLibraryError.notFound(id)
        }
        return workflow
    }

    func readSource(_ workflow: ClaudeWorkflowFile) throws -> String {
        guard workflow.readable else {
            throw ClaudeWorkflowLibraryError.unreadable(workflow.error ?? "Claude workflow is not readable.")
        }
        guard workflow.sizeBytes <= Self.maxSourceBytes else {
            throw ClaudeWorkflowLibraryError.tooLarge(workflow.sizeBytes, Self.maxSourceBytes)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: workflow.path))
        guard let source = String(data: data, encoding: .utf8) else {
            throw ClaudeWorkflowLibraryError.invalidSource
        }
        return source
    }

    private func workflowFile(at url: URL) -> ClaudeWorkflowFile? {
        let canonical = url.resolvingSymlinksInPath()
        guard isRegularFile(canonical) else { return nil }

        let attrs = (try? fileManager.attributesOfItem(atPath: canonical.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date.distantPast
        let baseName = canonical.deletingPathExtension().lastPathComponent

        var preview = ""
        var readable = true
        var readError: String?
        var metadata = ClaudeWorkflowMetadata(name: nil, description: nil, phases: [])
        if size > Self.maxSourceBytes {
            readable = false
            readError = "File exceeds \(Self.maxSourceBytes) bytes."
        } else {
            do {
                let source = try readText(at: canonical, maxBytes: Self.maxSourceBytes)
                preview = source
                    .replacingOccurrences(of: "\u{0}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(Self.previewBytes)
                    .description
                metadata = parseMetadata(from: source)
            } catch {
                readable = false
                readError = error.localizedDescription
            }
        }
        let displayName = normalizedMetadataValue(metadata.name) ?? baseName

        return ClaudeWorkflowFile(
            id: "global:\(sha256(canonical.path))",
            name: displayName,
            commandName: "/\(displayName)",
            description: normalizedMetadataValue(metadata.description),
            phases: metadata.phases,
            path: canonical.path,
            sizeBytes: size,
            modifiedAt: modified,
            preview: preview,
            readable: readable,
            error: readError
        )
    }

    private func isRegularFile(_ url: URL) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true
        } catch {
            return false
        }
    }

    private func readText(at url: URL, maxBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func metadata(from source: String) -> ClaudeWorkflowMetadata {
        Self.shared.parseMetadata(from: source)
    }

    private func parseMetadata(from source: String) -> ClaudeWorkflowMetadata {
        let metaObject = extractMetaObject(from: source)
        let name = metaObject.flatMap { firstStringProperty(in: $0, key: "name") }
        let description = metaObject.flatMap { firstStringProperty(in: $0, key: "description") }
        let metaPhases = metaObject.flatMap { phaseMetadata(fromMetaObject: $0) } ?? []
        let phases = metaPhases.isEmpty ? phaseCalls(from: source) : metaPhases
        return ClaudeWorkflowMetadata(name: name, description: description, phases: Array(phases.prefix(12)))
    }

    private func extractMetaObject(from source: String) -> String? {
        guard let marker = source.range(
            of: #"(?m)\b(?:export\s+)?const\s+meta\s*="#,
            options: .regularExpression
        ) else { return nil }
        guard let open = source[marker.upperBound...].firstIndex(of: "{") else { return nil }
        return extractBalancedText(in: source, from: open, opening: "{", closing: "}")
    }

    private func phaseMetadata(fromMetaObject object: String) -> [ClaudeWorkflowPhase] {
        guard let phasesKey = object.range(of: #"\bphases\s*:"#, options: .regularExpression),
              let open = object[phasesKey.upperBound...].firstIndex(of: "["),
              let arrayText = extractBalancedText(in: object, from: open, opening: "[", closing: "]") else {
            return []
        }
        return balancedChildren(in: arrayText, opening: "{", closing: "}").compactMap { phaseObject in
            guard let title = normalizedMetadataValue(firstStringProperty(in: phaseObject, key: "title")) else {
                return nil
            }
            return ClaudeWorkflowPhase(
                title: title,
                detail: normalizedMetadataValue(firstStringProperty(in: phaseObject, key: "detail"))
            )
        }
    }

    private func phaseCalls(from source: String) -> [ClaudeWorkflowPhase] {
        let pattern = #"phase\s*\(\s*(['"])((?:\\.|[^\\'"])*)\1\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let titleRange = Range(match.range(at: 2), in: source),
                  let title = normalizedMetadataValue(unescapeJavaScriptString(String(source[titleRange]))) else {
                return nil
            }
            return ClaudeWorkflowPhase(title: title, detail: nil)
        }
    }

    private func firstStringProperty(in source: String, key: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"\b\#(escapedKey)\s*:\s*(['"])((?:\\.|[^\\'"])*)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              match.numberOfRanges >= 3,
              let valueRange = Range(match.range(at: 2), in: source) else {
            return nil
        }
        return unescapeJavaScriptString(String(source[valueRange]))
    }

    private func extractBalancedText(
        in source: String,
        from open: String.Index,
        opening: Character,
        closing: Character
    ) -> String? {
        var depth = 0
        var quote: Character?
        var escaped = false
        var idx = open
        while idx < source.endIndex {
            let char = source[idx]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == activeQuote {
                    quote = nil
                }
            } else if char == "'" || char == "\"" || char == "`" {
                quote = char
            } else if char == opening {
                depth += 1
            } else if char == closing {
                depth -= 1
                if depth == 0 {
                    return String(source[open...idx])
                }
            }
            idx = source.index(after: idx)
        }
        return nil
    }

    private func balancedChildren(in source: String, opening: Character, closing: Character) -> [String] {
        var results: [String] = []
        var search = source.startIndex
        while search < source.endIndex,
              let open = source[search...].firstIndex(of: opening),
              let text = extractBalancedText(in: source, from: open, opening: opening, closing: closing) {
            results.append(text)
            search = source.index(open, offsetBy: text.count, limitedBy: source.endIndex) ?? source.endIndex
        }
        return results
    }

    private func unescapeJavaScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\'"#, with: "'", options: .literal)
            .replacingOccurrences(of: #"\""#, with: "\"", options: .literal)
            .replacingOccurrences(of: #"\\n"#, with: "\n", options: .literal)
            .replacingOccurrences(of: #"\\r"#, with: "\r", options: .literal)
            .replacingOccurrences(of: #"\\t"#, with: "\t", options: .literal)
            .replacingOccurrences(of: #"\\\\"#, with: "\\", options: .literal)
    }

    private func normalizedMetadataValue(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct ClaudeWorkflowMetadata: Equatable {
    var name: String?
    var description: String?
    var phases: [ClaudeWorkflowPhase]
}

struct ClaudeWorkflowImportPlan: Decodable, Equatable {
    var summary: String?
    var nodes: [ClaudeWorkflowNodeDraft]
}

struct ClaudeWorkflowNodeDraft: Decodable, Equatable {
    var title: String
    var goal: String
    var dependsOn: [Int]?
    var needsReview: Bool?
}

protocol ClaudeWorkflowNodeDraftGenerating {
    func generatePlan(workflow: ClaudeWorkflowFile, source: String) throws -> ClaudeWorkflowImportPlan
}

struct AssistantClaudeWorkflowNodeDraftGenerator: ClaudeWorkflowNodeDraftGenerating {
    private let provider: AssistantProvider
    private let settings: AssistantSettings
    private let timeoutSeconds: TimeInterval

    init(
        provider: AssistantProvider = AssistantProviderFactory.make(AssistantAPI.parseSettings(nil).provider),
        settings: AssistantSettings = AssistantAPI.parseSettings(nil),
        timeoutSeconds: TimeInterval = 120
    ) {
        self.provider = provider
        self.settings = settings
        self.timeoutSeconds = timeoutSeconds
    }

    func generatePlan(workflow: ClaudeWorkflowFile, source: String) throws -> ClaudeWorkflowImportPlan {
        let systemPrompt = """
        You convert saved Claude Code workflow JavaScript into a Meee2 canvas.
        Return ONLY strict JSON. Do not use markdown fences or prose.
        Do not claim the workflow has run. Do not include runtime session ids or execution results.
        Output shape:
        {
          "summary": "short summary",
          "nodes": [
            {
              "title": "node title",
              "goal": "what this step should accomplish",
              "dependsOn": [0],
              "needsReview": false
            }
          ]
        }
        Rules:
        - Return 3 to 8 nodes.
        - Use zero-based dependsOn indices pointing only to earlier nodes.
        - Include artifact/report/review nodes when the workflow implies them.
        - Mark needsReview=true only for explicit human review or approval gates.
        """
        let userPrompt = """
        Claude Code workflow metadata:
        filename: \(workflow.name).js
        slashCommand: \(workflow.commandName)
        description: \(workflow.description ?? "")
        phases: \(workflow.phases.map { "\($0.title): \($0.detail ?? "")" }.joined(separator: " | "))
        path: \(workflow.path)
        sizeBytes: \(workflow.sizeBytes)
        modifiedAt: \(ISO8601DateFormatter().string(from: workflow.modifiedAt))

        JavaScript source:
        ```javascript
        \(source)
        ```
        """

        let sequence = provider.runTurn(
            systemPrompt: systemPrompt,
            messages: [ChatMessage(role: .user, content: userPrompt)],
            tools: [],
            settings: settings
        )

        var output = ""
        var failure: String?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                for try await event in sequence {
                    switch event {
                    case .textDelta(let text):
                        output += text
                    case .error(let message):
                        failure = message
                    case .turnDone:
                        break
                    case .toolCall:
                        failure = "unexpected tool call"
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw ClaudeWorkflowLibraryError.aiParseFailed("timed out")
        }
        if let failure, !failure.isEmpty {
            throw ClaudeWorkflowLibraryError.aiParseFailed(failure)
        }

        return try decodePlan(from: output)
    }

    private func decodePlan(from raw: String) throws -> ClaudeWorkflowImportPlan {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw ClaudeWorkflowLibraryError.aiParseFailed("non-UTF8 output")
        }
        do {
            return try JSONDecoder().decode(ClaudeWorkflowImportPlan.self, from: data)
        } catch {
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}"),
               start < end {
                let sliced = String(trimmed[start...end])
                if let slicedData = sliced.data(using: .utf8),
                   let plan = try? JSONDecoder().decode(ClaudeWorkflowImportPlan.self, from: slicedData) {
                    return plan
                }
            }
            throw ClaudeWorkflowLibraryError.aiParseFailed(error.localizedDescription)
        }
    }
}

struct ClaudeWorkflowImporter {
    var library: ClaudeWorkflowLibrary
    var generator: ClaudeWorkflowNodeDraftGenerating
    var store: PlannerStore

    init(
        library: ClaudeWorkflowLibrary = .shared,
        generator: ClaudeWorkflowNodeDraftGenerating = AssistantClaudeWorkflowNodeDraftGenerator(),
        store: PlannerStore = PlannerBoardBridge.store
    ) {
        self.library = library
        self.generator = generator
        self.store = store
    }

    func importWorkflow(id: String, name rawName: String?, scope: BoardLayoutStore.CanvasScope) throws -> BoardLayoutStore.Snapshot {
        let workflow = try library.find(id: id)
        let source = try library.readSource(workflow)
        return try importWorkflowFile(workflow: workflow, source: source, name: rawName, scope: scope)
    }

    func importUploadedWorkflow(
        filename rawFilename: String,
        source: String,
        name rawName: String?,
        scope: BoardLayoutStore.CanvasScope
    ) throws -> BoardLayoutStore.Snapshot {
        let workflow = try uploadedWorkflow(filename: rawFilename, source: source)
        return try importWorkflowFile(workflow: workflow, source: source, name: rawName, scope: scope)
    }

    private func importWorkflowFile(
        workflow: ClaudeWorkflowFile,
        source: String,
        name rawName: String?,
        scope: BoardLayoutStore.CanvasScope
    ) throws -> BoardLayoutStore.Snapshot {
        let canvasName = normalizedCanvasName(rawName, fallback: workflow.name)

        let snapshot = try BoardLayoutStore.shared.createCanvas(
            name: canvasName,
            scope: scope,
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
            plannerContext: "claude-workflow:\(workflow.path)"
        )

        let nodes: [PlanningNode]
        if workflow.phases.isEmpty {
            do {
                let plan = try generator.generatePlan(workflow: workflow, source: source)
                nodes = try materialize(plan: plan, workflow: workflow, canvasId: canvasId, ownerId: ownerId)
            } catch {
                nodes = fallbackNodes(
                    workflow: workflow,
                    source: source,
                    canvasId: canvasId,
                    ownerId: ownerId,
                    reason: error.localizedDescription
                )
            }
        } else {
            nodes = phaseNodes(workflow: workflow, canvasId: canvasId, ownerId: ownerId)
        }

        _ = try store.record(for: planningCanvas, seedNodes: [])
        _ = try store.seedNodesIfEmpty(canvasId: canvasId, seedNodes: nodes)
        return snapshot
    }

    private func uploadedWorkflow(filename rawFilename: String, source: String) throws -> ClaudeWorkflowFile {
        let filename = URL(fileURLWithPath: rawFilename)
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else {
            throw ClaudeWorkflowLibraryError.unsupportedFileType(rawFilename)
        }
        let fileURL = URL(fileURLWithPath: filename)
        guard fileURL.pathExtension.lowercased() == "js" else {
            throw ClaudeWorkflowLibraryError.unsupportedFileType(filename)
        }
        let data = Data(source.utf8)
        guard data.count <= ClaudeWorkflowLibrary.maxSourceBytes else {
            throw ClaudeWorkflowLibraryError.tooLarge(data.count, ClaudeWorkflowLibrary.maxSourceBytes)
        }
        let basename = fileURL.deletingPathExtension().lastPathComponent
        let metadata = ClaudeWorkflowLibrary.metadata(from: source)
        let displayName = normalizedMetadataValue(metadata.name) ?? (basename.isEmpty ? "uploaded-workflow" : basename)
        let stableSeed = "\(filename)\n\(source)"
        return ClaudeWorkflowFile(
            id: "upload:\(sha256(stableSeed))",
            name: displayName,
            commandName: "/\(displayName)",
            description: normalizedMetadataValue(metadata.description),
            phases: metadata.phases,
            path: "uploaded:\(filename)",
            sizeBytes: data.count,
            modifiedAt: Date(),
            preview: source
                .replacingOccurrences(of: "\u{0}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(ClaudeWorkflowLibrary.previewBytes)
                .description,
            readable: true,
            error: nil
        )
    }

    private func phaseNodes(
        workflow: ClaudeWorkflowFile,
        canvasId: String,
        ownerId: String
    ) -> [PlanningNode] {
        let phases = Array(workflow.phases.prefix(7))
        let phaseIds = phases.indices.map { "\(canvasId)-claude-workflow-phase-\($0)" }
        var nodes = phases.enumerated().map { index, phase in
            workflowNode(
                id: phaseIds[index],
                canvasId: canvasId,
                title: phase.title,
                goal: phase.detail ?? "Complete the \(phase.title) phase from \(workflow.commandName).",
                ownerId: ownerId,
                workflow: workflow,
                x: Double(index % 4) * 340,
                y: Double(index / 4) * 220,
                dependsOnNodeIds: index == 0 ? [] : [phaseIds[index - 1]],
                needsReview: false,
                blockedReason: nil
            )
        }

        if nodes.count < 8 {
            nodes.append(workflowNode(
                id: "\(canvasId)-claude-workflow-report",
                canvasId: canvasId,
                title: "Collect report",
                goal: "Collect the workflow result, artifacts, and follow-up decisions back into this canvas. meee2 has not executed this workflow.",
                ownerId: ownerId,
                workflow: workflow,
                x: Double(nodes.count % 4) * 340,
                y: Double(nodes.count / 4) * 220,
                dependsOnNodeIds: phaseIds.last.map { [$0] } ?? [],
                needsReview: true,
                blockedReason: nil
            ))
        }
        return nodes
    }

    private func materialize(
        plan: ClaudeWorkflowImportPlan,
        workflow: ClaudeWorkflowFile,
        canvasId: String,
        ownerId: String
    ) throws -> [PlanningNode] {
        let drafts = Array(plan.nodes.prefix(8))
        guard drafts.count >= 3 else {
            throw ClaudeWorkflowLibraryError.aiParseFailed("expected 3 to 8 nodes")
        }
        for (idx, draft) in drafts.enumerated() {
            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ClaudeWorkflowLibraryError.aiParseFailed("node \(idx) has empty title or goal")
            }
            for dep in draft.dependsOn ?? [] where dep < 0 || dep >= idx {
                throw ClaudeWorkflowLibraryError.aiParseFailed("node \(idx) has invalid dependency \(dep)")
            }
        }

        let ids = drafts.indices.map { "\(canvasId)-claude-workflow-\($0)" }
        return drafts.enumerated().map { index, draft in
            workflowNode(
                id: ids[index],
                canvasId: canvasId,
                title: draft.title,
                goal: draft.goal,
                ownerId: ownerId,
                workflow: workflow,
                x: Double(index % 4) * 340,
                y: Double(index / 4) * 220,
                dependsOnNodeIds: (draft.dependsOn ?? []).map { ids[$0] },
                needsReview: draft.needsReview == true,
                blockedReason: nil
            )
        }
    }

    private func fallbackNodes(
        workflow: ClaudeWorkflowFile,
        source: String,
        canvasId: String,
        ownerId: String,
        reason: String
    ) -> [PlanningNode] {
        let specs: [(String, String, Bool)] = [
            ("Workflow source", "Review the saved Claude Code workflow source at \(workflow.path).", false),
            ("Review orchestration", "Manually identify phases, agents, handoffs, artifacts, and approval gates. AI parse failed: \(reason)", true),
            ("Run in Claude Code", "Run \(workflow.commandName) in Claude Code when ready; meee2 has not executed this workflow.", false),
            ("Collect report", "Collect generated report, artifacts, and follow-up decisions back into this canvas.", true)
        ]
        return specs.enumerated().map { index, spec in
            workflowNode(
                id: "\(canvasId)-claude-workflow-fallback-\(index)",
                canvasId: canvasId,
                title: spec.0,
                goal: spec.1,
                ownerId: ownerId,
                workflow: workflow,
                x: Double(index) * 340,
                y: 0,
                dependsOnNodeIds: index == 0 ? [] : ["\(canvasId)-claude-workflow-fallback-\(index - 1)"],
                needsReview: spec.2,
                blockedReason: index == 1 ? "AI parse failed: \(reason)" : nil
            )
        }
    }

    private func workflowNode(
        id: String,
        canvasId: String,
        title: String,
        goal: String,
        ownerId: String,
        workflow: ClaudeWorkflowFile,
        x: Double,
        y: Double,
        dependsOnNodeIds: [String],
        needsReview: Bool,
        blockedReason: String?
    ) -> PlanningNode {
        PlanningNode(
            id: id,
            canvasId: canvasId,
            title: title,
            schema: NodeSchema(
                inputs: dependsOnNodeIds.isEmpty ? [] : ["upstream workflow context"],
                outputs: needsReview ? ["review decision"] : ["workflow artifact"],
                goal: goal
            ),
            contextSources: [
                ContextSource(kind: .document, title: "Claude Code workflow", reference: workflow.path),
                ContextSource(kind: .artifact, title: workflow.commandName, reference: workflow.id)
            ],
            executionMode: needsReview ? .human : .auto,
            executorType: needsReview ? .human : .claude,
            doerId: ownerId,
            status: .ready,
            source: .planner,
            dependsOnNodeIds: dependsOnNodeIds.isEmpty ? nil : dependsOnNodeIds,
            nodeKind: .step,
            layout: PlannerNodeLayout(x: x, y: y, width: 300, height: 176),
            dispatch: needsReview ? nil : PlannerNodeDispatch(
                runner: .claude,
                skill: "claude-code-workflow",
                actor: ownerId,
                command: workflow.commandName,
                fallbackRunner: nil
            ),
            workflowRunState: .pending,
            blockedReason: blockedReason
        )
    }

    private func normalizedCanvasName(_ rawName: String?, fallback: String) -> String {
        let trimmed = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func normalizedMetadataValue(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

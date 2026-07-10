import Foundation
import Meee2CommKit

struct AutomationTemplateDTO: Encodable {
    let id: String
    let product: String
    let category: String
    let icon: String
    let title: String
    let description: String
    let prompt: String
    let cadence: String
}

struct AutomationDefinitionDTO: Codable {
    let id: String
    var title: String
    var description: String
    var prompt: String
    var cadence: String
    var scope: String
    var templateId: String?
    var enabled: Bool
    let createdAt: String
    var updatedAt: String
    var lastRunAt: String?
    var lastRunStatus: String?
    var lastRunSummary: String?
}

struct AutomationRunDTO: Codable {
    let id: String
    let automationId: String
    let status: String
    let output: String
    let error: String?
    let startedAt: String
    let finishedAt: String
}

struct AutomationsEnvelope: Encodable {
    let templates: [AutomationTemplateDTO]
    let automations: [AutomationDefinitionDTO]
}

struct AutomationEnvelope: Encodable {
    let automation: AutomationDefinitionDTO
}

struct AutomationRunEnvelope: Encodable {
    let automation: AutomationDefinitionDTO
    let run: AutomationRunDTO
}

final class AutomationStore {
    static let shared = AutomationStore()

    let templates: [AutomationTemplateDTO] = [
        AutomationTemplateDTO(
            id: "meee2-daily-session-brief",
            product: "meee2",
            category: "Status reports",
            icon: "💬",
            title: "Daily local session brief",
            description: "Summarize today's Claude, Codex, Cursor, and OpenClaw sessions; highlight blockers and sessions needing attention.",
            prompt: """
            Summarize the current meee2 board into a daily status brief.
            Rules:
            - Use get_session_list first, then inspect sessions that look active, blocked, or stale.
            - Group by project and plugin.
            - Call out permissionRequired sessions and stale sessions separately.
            - Keep it concise enough to paste into a team update.
            """,
            cadence: "Every weekday morning"
        ),
        AutomationTemplateDTO(
            id: "meee2-stuck-session-triage",
            product: "meee2",
            category: "Incidents & triage",
            icon: "🧭",
            title: "Stuck session triage",
            description: "Find local sessions that appear blocked, waiting, or idle too long and propose the smallest next action.",
            prompt: """
            Triage the meee2 board for stuck sessions.
            Rules:
            - Use get_session_list and inspect likely stuck sessions.
            - Separate observed evidence from guesses.
            - Suggest one concrete next action per session.
            - Do not create new sessions unless explicitly necessary.
            """,
            cadence: "Manual or every 2 hours"
        ),
        AutomationTemplateDTO(
            id: "meee2-release-prep",
            product: "meee2",
            category: "Release prep",
            icon: "✅",
            title: "meee2 release prep checklist",
            description: "Build release readiness notes from local sessions, known failures, packaging status, and open risks.",
            prompt: """
            Prepare a meee2 release readiness report.
            Rules:
            - Focus on board evidence, recent session messages, and explicit errors.
            - Include build/test/package checks that still need to be run.
            - Mark unknowns as unknown instead of assuming.
            - Output a short go/no-go recommendation.
            """,
            cadence: "Before tagging a release"
        ),
        AutomationTemplateDTO(
            id: "meee2-meee2-sync-audit",
            product: "meee2",
            category: "Operations",
            icon: "🔁",
            title: "meee2 sync audit",
            description: "Check whether local sessions are ready to sync to meee2 and list reporting gaps.",
            prompt: """
            Audit meee2 sessions for meee2 synchronization readiness.
            Rules:
            - Identify active projects, plugins, and sessions useful on the team board.
            - Call out sessions with thin metadata, no recent messages, or unclear status.
            - Recommend what should be synced or excluded.
            """,
            cadence: "Daily"
        )
    ]

    private struct StoreFile: Codable {
        var automations: [AutomationDefinitionDTO]
        var runs: [AutomationRunDTO]
    }

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func list() -> [AutomationDefinitionDTO] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().automations.sorted { $0.createdAt < $1.createdAt }
    }

    func create(input: [String: Any]) throws -> AutomationDefinitionDTO {
        lock.lock()
        defer { lock.unlock() }

        var store = loadUnlocked()
        let templateId = cleanString(input["templateId"])
        let template = templateId.flatMap { id in templates.first { $0.id == id } }
        let now = BoardDTOBuilder.iso(Date())
        let title = cleanString(input["title"]) ?? template?.title ?? "Untitled automation"
        let prompt = cleanString(input["prompt"]) ?? template?.prompt ?? ""
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AutomationStoreError.validation("prompt is required")
        }

        let automation = AutomationDefinitionDTO(
            id: UUID().uuidString,
            title: title,
            description: cleanString(input["description"]) ?? template?.description ?? "",
            prompt: prompt,
            cadence: cleanString(input["cadence"]) ?? template?.cadence ?? "Manual",
            scope: cleanString(input["scope"]) ?? "local-board",
            templateId: templateId,
            enabled: (input["enabled"] as? Bool) ?? true,
            createdAt: now,
            updatedAt: now,
            lastRunAt: nil,
            lastRunStatus: nil,
            lastRunSummary: nil
        )
        store.automations.append(automation)
        try saveUnlocked(store)
        return automation
    }

    func delete(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var store = loadUnlocked()
        let before = store.automations.count
        store.automations.removeAll { $0.id == id }
        store.runs.removeAll { $0.automationId == id }
        if store.automations.count == before {
            throw AutomationStoreError.notFound
        }
        try saveUnlocked(store)
    }

    func get(id: String) -> AutomationDefinitionDTO? {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().automations.first { $0.id == id }
    }

    func recordRun(automationId: String, status: String, output: String, error: String?, startedAt: String) throws -> AutomationRunEnvelope {
        lock.lock()
        defer { lock.unlock() }
        var store = loadUnlocked()
        guard let index = store.automations.firstIndex(where: { $0.id == automationId }) else {
            throw AutomationStoreError.notFound
        }

        let finishedAt = BoardDTOBuilder.iso(Date())
        let run = AutomationRunDTO(
            id: UUID().uuidString,
            automationId: automationId,
            status: status,
            output: output,
            error: error,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
        store.runs.append(run)
        if store.runs.count > 100 {
            store.runs = Array(store.runs.suffix(100))
        }
        store.automations[index].lastRunAt = finishedAt
        store.automations[index].lastRunStatus = status
        store.automations[index].lastRunSummary = summarize(output: output, error: error)
        store.automations[index].updatedAt = finishedAt
        let automation = store.automations[index]
        try saveUnlocked(store)
        return AutomationRunEnvelope(automation: automation, run: run)
    }

    private func cleanString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(12_000))
    }

    private func summarize(output: String, error: String?) -> String {
        if let error, !error.isEmpty { return String(error.prefix(500)) }
        let normalized = output
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(500))
    }

    private func loadUnlocked() -> StoreFile {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let store = try? decoder.decode(StoreFile.self, from: data) else {
            return StoreFile(automations: [], runs: [])
        }
        return store
    }

    private func saveUnlocked(_ store: StoreFile) throws {
        let url = fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(store)
        try data.write(to: url, options: [.atomic])
    }

    private func fileURL() -> URL {
        StorageRoots.processDefault.baseDirectory
            .appendingPathComponent("automations.json", isDirectory: false)
    }
}

enum AutomationStoreError: LocalizedError {
    case notFound
    case validation(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "automation not found"
        case .validation(let message):
            return message
        }
    }
}

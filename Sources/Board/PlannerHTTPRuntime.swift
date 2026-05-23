import Foundation

// HTTPPlannerAgentRuntime — drives the conversational TS planner runtime in
// meee2-online via HTTP + SSE.
//
// Wire-in: BoardServer.start() calls `HTTPPlannerAgentRuntime.installFromEnvironment()`
// which swaps `PlannerAgentRuntimeRegistry.shared` when both
// `MEEE2_PLANNER_RUNTIME_URL` and `MEEE2_BOARD_BASE_URL` are set. Otherwise
// the in-process `DefaultPlannerAgentRuntime` stays in place.
//
// Environment:
//   MEEE2_PLANNER_RUNTIME_URL  — e.g. http://127.0.0.1:3000  (meee2-online)
//   MEEE2_BOARD_BASE_URL       — e.g. http://127.0.0.1:9876  (this BoardServer)
final class HTTPPlannerAgentRuntime: PlannerAgentRuntime {
    static let runtimeUrlEnvVar = "MEEE2_PLANNER_RUNTIME_URL"
    static let boardUrlEnvVar = "MEEE2_BOARD_BASE_URL"

    let runtimeBaseUrl: URL
    let boardBaseUrl: String
    let urlSession: URLSession

    init(runtimeBaseUrl: String, boardBaseUrl: String, urlSession: URLSession = .shared) {
        guard let url = URL(string: runtimeBaseUrl) else {
            fatalError("HTTPPlannerAgentRuntime: invalid runtimeBaseUrl \(runtimeBaseUrl)")
        }
        self.runtimeBaseUrl = url
        self.boardBaseUrl = boardBaseUrl
        self.urlSession = urlSession
    }

    /// Swap `PlannerAgentRuntimeRegistry.shared` when both env vars are set.
    /// Idempotent: call from `BoardServer.start()` at boot.
    static func installFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let runtimeUrl = env[runtimeUrlEnvVar]?.trimmingCharacters(in: .whitespaces),
              !runtimeUrl.isEmpty,
              let boardUrl = env[boardUrlEnvVar]?.trimmingCharacters(in: .whitespaces),
              !boardUrl.isEmpty else {
            return
        }
        PlannerAgentRuntimeRegistry.shared = HTTPPlannerAgentRuntime(
            runtimeBaseUrl: runtimeUrl,
            boardBaseUrl: boardUrl
        )
        MInfo("[Planner] HTTPPlannerAgentRuntime installed runtime=\(runtimeUrl) board=\(boardUrl)")
    }

    func handle(
        _ event: PlannerAgentEvent,
        state: PlannerGraphState,
        settings: AssistantSettings
    ) async throws -> PlannerAgentOutcome {
        _ = state    // TS runtime re-fetches via the read_canvas tool
        _ = settings
        // For the skeleton we only forward `.userGoal`; the other events still
        // resolve via the in-process default runtime fallback below.
        guard case .userGoal(let canvasId, let goal, let context) = event else {
            return .noAction("HTTPPlannerAgentRuntime: event \(eventTag(event)) not yet routed to the TS runtime")
        }
        let seed: String = {
            guard let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return goal
            }
            return goal.isEmpty ? context : "\(goal)\n\nContext:\n\(context)"
        }()

        let sessionId = try await createSession(
            canvasId: canvasId,
            actorUserId: state.access.actorId,
            seedUserMessage: seed
        )
        let proposals = try await streamProposals(sessionId: sessionId, canvasId: canvasId)
        if proposals.isEmpty {
            return .noAction("TS planner runtime returned no proposals")
        }
        return PlannerAgentOutcome(
            proposals: proposals,
            rationale: "Generated via meee2-online TS planner runtime",
            risks: ["Proposal originates from a cross-process runtime — validated locally before persist."]
        )
    }

    // MARK: - HTTP helpers

    private func createSession(
        canvasId: String,
        actorUserId: String?,
        seedUserMessage: String
    ) async throws -> String {
        var req = URLRequest(url: runtimeBaseUrl.appendingPathComponent("api/planner/runtime/sessions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "canvasId": canvasId,
            "boardBaseUrl": boardBaseUrl,
            "harness": "stub",
            "seedUserMessage": seedUserMessage
        ]
        if let actorUserId, !actorUserId.isEmpty {
            body["actorUserId"] = actorUserId
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "HTTPPlannerAgentRuntime",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "createSession failed: \(status)"]
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let session = json?["session"] as? [String: Any],
              let id = session["id"] as? String else {
            throw NSError(
                domain: "HTTPPlannerAgentRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "createSession: malformed response"]
            )
        }
        return id
    }

    private func streamProposals(sessionId: String, canvasId: String) async throws -> [PlanProposal] {
        let url = runtimeBaseUrl
            .appendingPathComponent("api/planner/runtime/sessions")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("stream")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, resp) = try await urlSession.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "HTTPPlannerAgentRuntime",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "stream failed: \(status)"]
            )
        }
        var proposals: [PlanProposal] = []
        var currentData: String?
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                currentData = String(line.dropFirst("data: ".count))
            } else if line.isEmpty, let payload = currentData {
                if let proposal = decodeProposalEvent(payload, expectedCanvasId: canvasId) {
                    proposals.append(proposal)
                }
                currentData = nil
            }
        }
        return proposals
    }

    private func decodeProposalEvent(_ payload: String, expectedCanvasId: String) -> PlanProposal? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "proposal",
              let raw = json["proposal"] else {
            return nil
        }
        // Re-encode the proposal body so we can hand it to the existing strict
        // Codable PlanProposal decoder (same validator as the LLM path).
        guard let body = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        do {
            let proposal = try JSONDecoder().decode(PlanProposal.self, from: body)
            guard proposal.canvasId == expectedCanvasId else { return nil }
            return proposal
        } catch {
            return nil
        }
    }

    private func eventTag(_ event: PlannerAgentEvent) -> String {
        switch event {
        case .userGoal: return "userGoal"
        case .driftInspection: return "driftInspection"
        case .nodeRunStateChanged: return "nodeRunStateChanged"
        case .milestoneCompleted: return "milestoneCompleted"
        }
    }
}

import Foundation
import Swifter

/// IntegrationsAPI —— Phase 5「真接入」。
///
/// 这些路由只做 **只读浏览**：列出 GitHub / Lark 上可被选中的外部条目。
/// 真正把条目作为 artifact 绑到 planner 节点上，仍然走既有的
/// `POST /api/planner/canvases/:id/nodes/:nodeId/artifacts`
/// (`BoardAPI.attachPlannerArtifactToNode`) —— 不另起一条 attach 路径。
///
/// ## 鉴权约定（已落地，文档化于此）
/// - **GitHub**：通过 `ccops` 秘钥管理器读取 `GITHUB_TOKEN`
///   (`ccops get GITHUB_TOKEN`，先用 `ccops has GITHUB_TOKEN` 探测存在性)。
///   token 不存在时，接口返回明确的 `reason`，前端提示用户执行
///   `ccops set GITHUB_TOKEN --value ...`。绝不硬编码秘钥。
///   实际 HTTP 调用复用系统里已安装的 `gh` CLI（`gh api ...`），
///   token 经环境变量 `GH_TOKEN` 注入，不写盘、不进日志。
/// - **Lark**：通过既有的 `lark-cli` 工具链访问。当前 docs 列表尚未接入真实
///   远端拉取，见下方 `TODO(lark)` —— 契约（端点 + DTO）已定稿，返回空列表，
///   绝不伪造远端数据。
enum IntegrationsAPI {
    // MARK: - 子进程辅助

    /// 同步执行一个命令，返回 (exitCode, stdout, stderr)。
    /// 失败（找不到二进制等）时 exitCode = -1。
    private static func runCommand(
        _ launchPath: String,
        _ arguments: [String],
        extraEnv: [String: String] = [:]
    ) -> (code: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, "", "failed to launch \(launchPath): \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 解析 PATH 里的二进制；命令行工具（gh / ccops / lark-cli）不一定在
    /// `/usr/bin`，所以走 `/usr/bin/env <name>` 让它按 PATH 查找。
    private static func envRun(
        _ name: String,
        _ arguments: [String],
        extraEnv: [String: String] = [:]
    ) -> (code: Int32, stdout: String, stderr: String) {
        runCommand("/usr/bin/env", [name] + arguments, extraEnv: extraEnv)
    }

    // MARK: - ccops token

    /// 读取 GitHub token。不存在时返回 nil（不抛错、不记日志原始值）。
    private static func githubToken() -> String? {
        // 先探测存在性，避免在缺失时把 ccops 的 stderr 当作错误处理。
        let has = envRun("ccops", ["has", "GITHUB_TOKEN"])
        guard has.code == 0 else { return nil }
        let get = envRun("ccops", ["get", "GITHUB_TOKEN"])
        guard get.code == 0 else { return nil }
        let token = get.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// 用 `gh api` 调一个 GitHub REST 端点，返回解析后的 JSON。
    /// token 经 `GH_TOKEN` 环境变量注入。
    private static func ghApi(_ path: String, token: String) -> Result<Any, IntegrationError> {
        let result = envRun("gh", ["api", path, "-H", "Accept: application/vnd.github+json"],
                             extraEnv: ["GH_TOKEN": token])
        guard result.code == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.code == -1 {
                return .failure(.upstream("gh CLI not available: \(detail)"))
            }
            return .failure(.upstream("gh api \(path) failed: \(detail.isEmpty ? "exit \(result.code)" : detail)"))
        }
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.upstream("gh api \(path) returned unparseable JSON"))
        }
        return .success(json)
    }

    enum IntegrationError: Error {
        case noToken
        case upstream(String)
    }

    // MARK: - DTO（契约）

    /// 可被选中的外部条目通用形态。前端据 `kind` 选择 PlannerArtifactKind。
    struct ExternalItemDTO: Encodable {
        let id: String              // 稳定标识，如 "owner/repo#42"
        let title: String
        let subtitle: String?       // 状态 / 作者 / 仓库等附注
        let reference: String       // 绑定到 artifact 时写入的 reference（通常是 URL）
        /// 建议的 PlannerArtifactKind 原始值。前端可覆盖。
        /// PR -> impl-pr / merged -> main-merge / check -> check-result / lark doc -> lark-doc
        let suggestedArtifactKind: String
    }

    struct ExternalItemsEnvelope: Encodable {
        let provider: String
        let items: [ExternalItemDTO]
        /// 当数据降级（远端不可达 / 未接入）时携带的说明，正常为 nil。
        let notice: String?
    }

    // MARK: - 路由处理器

    /// GET /api/integrations/agent-scan
    /// agent × integration 检测矩阵(P1)。扫本地 Claude Code / Codex 的 MCP
    /// 配置 + 凭证,判断每个 integration 接没接通。
    static func getAgentScan(_ req: HttpRequest) -> HttpResponse {
        let statuses = IntegrationDetector.scan()
        return BoardAPI.jsonResponse(AgentScanEnvelope(
            agents: IntegrationDetector.agents,
            statuses: statuses
        ))
    }

    /// GET /api/integrations/side-effects?canvasId=<id>
    /// P2 —— 一个 canvas 里每个节点的输入/输出触达哪些 integration 副作用,
    /// 并交叉检测矩阵标出哪些副作用面没接通。
    static func getCanvasSideEffects(_ req: HttpRequest) -> HttpResponse {
        let canvasId = req.queryParams.first { $0.0 == "canvasId" }?.1 ?? ""
        guard !canvasId.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing canvasId", status: 400)
        }
        do {
            let graph = try PlannerBoardBridge.graphState(
                for: canvasId,
                snapshot: BoardLayoutStore.shared.snapshot(),
                actorUserId: PlannerPermission.currentActorId()
            )
            let nodes = NodeSideEffectInferrer.coverage(nodes: graph.nodes)
            return BoardAPI.jsonResponse(CanvasSideEffectsEnvelope(canvasId: canvasId, nodes: nodes))
        } catch {
            return BoardAPI.errorResponse("integration_error", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/integrations/:id/recommend-workflow
    /// 装完一个 integration 之后,让 planner agent 在指定 canvas 上提议一份
    /// 使用这个 integration 的小流程(2-4 步)—— 形成「装好就能用」的闭环。
    /// Body: `{ "canvasId": "...", "settings"?: {...} }`. 复用 BoardAPI 的
    /// runPlannerRuntimeProposal 走 .userGoal 事件 + 验证 + 入库。
    static func recommendWorkflow(_ req: HttpRequest) -> HttpResponse {
        guard let integrationId = req.params[":id"], !integrationId.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing integration id", status: 400)
        }
        guard let descriptor = IntegrationCatalog.all.first(where: { $0.id == integrationId }) else {
            return BoardAPI.errorResponse("integration_error", "unknown integration: \(integrationId)", status: 404)
        }
        guard let json = BoardAPI.parseJSONBody(req) else {
            return BoardAPI.errorResponse("invalid_json", "body must include canvasId", status: 400)
        }
        guard let canvasId = (json["canvasId"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return BoardAPI.errorResponse("bad_request", "missing canvasId", status: 400)
        }
        let settings = AssistantAPI.parseSettings(json["settings"] as? [String: Any])
        let snapshot = BoardLayoutStore.shared.snapshot()
        let actorUserId = PlannerPermission.currentActorId()

        let goal = "I just installed the \(descriptor.name) integration. Propose a small, useful workflow (2 to 4 step nodes) that exercises \(descriptor.name): typical inputs, what each step does, and where \(descriptor.name) tools are read/written. Keep nodes concrete and grounded in this canvas's existing structure if any."
        let context = descriptor.setupHint.isEmpty ? nil : descriptor.setupHint

        do {
            if let proposal = try BoardAPI.runPlannerRuntimeProposal(
                event: .userGoal(canvasId: canvasId, goal: goal, context: context),
                canvasId: canvasId,
                settings: settings,
                snapshot: snapshot,
                actorUserId: actorUserId
            ) {
                return BoardAPI.jsonResponse(
                    PlannerProposalEnvelope(proposal: proposal),
                    status: 201,
                    reason: "Created"
                )
            }
            return BoardAPI.errorResponse(
                "planner_error",
                "Planner runtime returned no proposal (timeout or no-action).",
                status: 503
            )
        } catch let err as PlannerCoreError {
            return BoardAPI.mapPlannerCoreError(err)
        } catch let err as BoardAPI.PlannerRuntimeError {
            return BoardAPI.errorResponse("planner_runtime_unavailable", err.localizedDescription, status: 503)
        } catch {
            return BoardAPI.errorResponse("planner_error", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/integrations/:id/install
    /// Pattern A 一键 —— 对 `.remoteHttp` 类的 integration,直接调
    /// `claude mcp add --transport http` + 写 Codex 的 toml mcp-remote 桥。
    /// 对 `.localStdio` 类(google-sheets / lark),注册 stdio server + 注入凭证 env。
    /// 前端按 install.kind 决定走这条还是 fallback 到 runbook。
    static func installIntegration(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing integration id", status: 400)
        }
        do {
            let result = try IntegrationInstaller.install(integrationId: id)
            return BoardAPI.jsonResponse(result)
        } catch {
            return BoardAPI.errorResponse("integration_error", error.localizedDescription, status: 400)
        }
    }

    /// POST /api/integrations/:id/credentials
    /// 接收用户上传的 OAuth client `credentials.json` 内容,校验是 GCP OAuth client
    /// (含 `installed` 或 `web` 顶级键),落到 ~/.meee2/connectors/<id>/credentials.json
    /// (0600)。localStdio connector(google-sheets)的「Connect」前置步骤 —— 之后
    /// install 时把它的路径作 CREDENTIALS_PATH 注入。Body: 原始 credentials.json 文本。
    static func uploadIntegrationCredentials(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing integration id", status: 400)
        }
        let raw = Data(req.body)
        guard !raw.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            return BoardAPI.errorResponse("invalid_credentials", "body must be the credentials.json file content (valid JSON).", status: 400)
        }
        // GCP OAuth client JSON 顶层是 `installed`(desktop app)或 `web`,内含 client_id。
        let clientBlock = (obj["installed"] as? [String: Any]) ?? (obj["web"] as? [String: Any])
        guard let client = clientBlock, client["client_id"] is String else {
            return BoardAPI.errorResponse(
                "invalid_credentials",
                "doesn't look like a GCP OAuth client credentials.json (expected top-level `installed` or `web` with a client_id). Create an OAuth client (Desktop app) in GCP, enable the Sheets API, and download its JSON.",
                status: 400
            )
        }
        do {
            let dir = IntegrationInstaller.connectorDir(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("credentials.json")
            try raw.write(to: path, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            struct Response: Encodable { let ok: Bool; let path: String; let message: String }
            return BoardAPI.jsonResponse(Response(
                ok: true, path: path.path,
                message: "credentials.json saved. Run Connect to register the server, then authorize in the browser."
            ))
        } catch {
            return BoardAPI.errorResponse("integration_error", "failed to save credentials.json — \(error.localizedDescription)", status: 500)
        }
    }

    /// POST /api/integrations/:id/preauth
    /// 在任何无头 dispatched 会话之前,主动触发 stdio connector 的 server 自带 OAuth
    /// 浏览器授权,把 token 缓存好(localStdio OAuth 模型,见 IntegrationInstaller)。
    /// best-effort:server 无 bootstrap 子命令,经一次 MCP 握手 + benign 工具调用 provoke。
    static func preauthIntegration(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing integration id", status: 400)
        }
        let result = IntegrationInstaller.triggerStdioPreAuth(integrationId: id)
        return BoardAPI.jsonResponse(result)
    }

    /// POST /api/integrations/:id/complete-auth
    /// 一键 OAuth —— 对已经装好但还没完成授权的 integration,直接通过
    /// `mcp-remote` shim 拉起浏览器走 OAuth,token 落到 `~/.mcp-auth/`。
    /// 完成后下次 agent-scan 会自动看到 connected 状态。
    static func completeAuth(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing integration id", status: 400)
        }
        guard let url = IntegrationInstaller.resolveOAuthURL(integrationId: id) else {
            return BoardAPI.errorResponse(
                "integration_not_oauth",
                "integration `\(id)` is not an OAuth-shaped MCP — no URL to authorize",
                status: 400
            )
        }
        let result = IntegrationInstaller.triggerOAuthHandshake(integrationId: id)
        let message: String
        if result.spawned, result.authUrl != nil {
            message = "Browser opening for OAuth. Click Allow there; token caches to ~/.mcp-auth/."
        } else if result.spawned {
            message = "mcp-remote launched but no auth URL surfaced in 5s — see \(result.logPath)."
        } else {
            message = result.detail ?? "Could not start OAuth shim."
        }
        return BoardAPI.jsonResponse(CompleteAuthEnvelope(
            integrationId: id,
            spawned: result.spawned,
            url: url,
            authUrl: result.authUrl,
            logPath: result.logPath,
            message: message
        ))
    }

    private struct CompleteAuthEnvelope: Encodable {
        let integrationId: String
        let spawned: Bool
        /// The MCP server URL we're authorizing against.
        let url: String
        /// Extracted OAuth URL — frontend renders this as a "Click here if
        /// browser didn't open" fallback link.
        let authUrl: String?
        let logPath: String
        let message: String
    }

    /// POST /api/integrations/:id/runbook
    /// P3 —— 为某个 integration 生成 agent 无关的 Markdown runbook(落
    /// `~/.meee2/runbooks/connect-<id>.md`),返回内容 + 派发命令。
    static func generateRunbook(_ req: HttpRequest) -> HttpResponse {
        guard let id = req.params[":id"], !id.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing integration id", status: 400)
        }
        do {
            let result = try IntegrationRunbookGenerator.generate(integrationId: id)
            return BoardAPI.jsonResponse(result)
        } catch {
            return BoardAPI.errorResponse("integration_error", error.localizedDescription, status: 400)
        }
    }

    /// GET /api/integrations/github/repos
    /// 列出当前 token 可见的仓库（按最近 push 排序）。
    static func getGithubRepos(_ req: HttpRequest) -> HttpResponse {
        guard let token = githubToken() else {
            return BoardAPI.errorResponse(
                "integration_not_connected",
                "GITHUB_TOKEN not found in ccops. Run: ccops set GITHUB_TOKEN --value <token>",
                status: 412
            )
        }
        switch ghApi("/user/repos?per_page=50&sort=pushed", token: token) {
        case .failure(let err):
            return mapIntegrationError(err)
        case .success(let json):
            guard let array = json as? [[String: Any]] else {
                return BoardAPI.errorResponse("integration_upstream", "unexpected repos shape", status: 502)
            }
            let items: [ExternalItemDTO] = array.compactMap { repo in
                guard let fullName = repo["full_name"] as? String else { return nil }
                let url = repo["html_url"] as? String ?? "https://github.com/\(fullName)"
                let priv = (repo["private"] as? Bool ?? false) ? "private" : "public"
                return ExternalItemDTO(
                    id: fullName,
                    title: fullName,
                    subtitle: priv,
                    reference: url,
                    suggestedArtifactKind: "generic"
                )
            }
            return BoardAPI.jsonResponse(ExternalItemsEnvelope(provider: "github", items: items, notice: nil))
        }
    }

    /// GET /api/integrations/github/repos/:owner/:repo/pulls
    static func getGithubPulls(_ req: HttpRequest) -> HttpResponse {
        guard let owner = req.params[":owner"], !owner.isEmpty,
              let repo = req.params[":repo"], !repo.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing owner or repo", status: 400)
        }
        guard let token = githubToken() else {
            return BoardAPI.errorResponse(
                "integration_not_connected",
                "GITHUB_TOKEN not found in ccops. Run: ccops set GITHUB_TOKEN --value <token>",
                status: 412
            )
        }
        switch ghApi("/repos/\(owner)/\(repo)/pulls?state=all&per_page=50", token: token) {
        case .failure(let err):
            return mapIntegrationError(err)
        case .success(let json):
            guard let array = json as? [[String: Any]] else {
                return BoardAPI.errorResponse("integration_upstream", "unexpected pulls shape", status: 502)
            }
            let items: [ExternalItemDTO] = array.compactMap { pr in
                guard let number = pr["number"] as? Int,
                      let title = pr["title"] as? String else { return nil }
                let url = pr["html_url"] as? String ?? "https://github.com/\(owner)/\(repo)/pull/\(number)"
                let merged = pr["merged_at"] is String
                let stateRaw = pr["state"] as? String ?? "open"
                let baseRef = (pr["base"] as? [String: Any])?["ref"] as? String
                // PR 合到 main/master -> main-merge；否则 -> impl-pr。
                let mergedToMain = merged && (baseRef == "main" || baseRef == "master")
                let stateLabel = merged ? "merged" : stateRaw
                return ExternalItemDTO(
                    id: "\(owner)/\(repo)#\(number)",
                    title: "#\(number) \(title)",
                    subtitle: "\(stateLabel)\(baseRef.map { " → \($0)" } ?? "")",
                    reference: url,
                    suggestedArtifactKind: mergedToMain ? "main-merge" : "impl-pr"
                )
            }
            return BoardAPI.jsonResponse(ExternalItemsEnvelope(provider: "github", items: items, notice: nil))
        }
    }

    /// GET /api/integrations/github/repos/:owner/:repo/issues
    static func getGithubIssues(_ req: HttpRequest) -> HttpResponse {
        guard let owner = req.params[":owner"], !owner.isEmpty,
              let repo = req.params[":repo"], !repo.isEmpty else {
            return BoardAPI.errorResponse("bad_request", "missing owner or repo", status: 400)
        }
        guard let token = githubToken() else {
            return BoardAPI.errorResponse(
                "integration_not_connected",
                "GITHUB_TOKEN not found in ccops. Run: ccops set GITHUB_TOKEN --value <token>",
                status: 412
            )
        }
        switch ghApi("/repos/\(owner)/\(repo)/issues?state=all&per_page=50", token: token) {
        case .failure(let err):
            return mapIntegrationError(err)
        case .success(let json):
            guard let array = json as? [[String: Any]] else {
                return BoardAPI.errorResponse("integration_upstream", "unexpected issues shape", status: 502)
            }
            // GitHub 的 issues 端点也会带回 PR；带 pull_request 字段的剔除。
            let items: [ExternalItemDTO] = array.compactMap { issue in
                guard issue["pull_request"] == nil,
                      let number = issue["number"] as? Int,
                      let title = issue["title"] as? String else { return nil }
                let url = issue["html_url"] as? String ?? "https://github.com/\(owner)/\(repo)/issues/\(number)"
                let stateRaw = issue["state"] as? String ?? "open"
                return ExternalItemDTO(
                    id: "\(owner)/\(repo)#\(number)",
                    title: "#\(number) \(title)",
                    subtitle: stateRaw,
                    reference: url,
                    suggestedArtifactKind: "idea-draft"
                )
            }
            return BoardAPI.jsonResponse(ExternalItemsEnvelope(provider: "github", items: items, notice: nil))
        }
    }

    /// GET /api/integrations/lark/docs
    ///
    /// TODO(lark): 真实的 Lark 文档检索尚未接入 lark-cli。契约（端点 + DTO）
    /// 已定稿：返回 `ExternalItemsEnvelope`，`provider="lark"`，
    /// `suggestedArtifactKind="lark-doc"`。当前返回空列表 + notice 说明降级原因，
    /// 绝不伪造远端数据。接入时把 lark-cli 的 docs 搜索结果映射进 `items` 即可，
    /// 前端无需改动。
    static func getLarkDocs(_ req: HttpRequest) -> HttpResponse {
        let larkProbe = envRun("lark-cli", ["--version"])
        let notice = larkProbe.code == 0
            ? "TODO(lark): lark-cli detected but doc search is not wired yet. Contract is final; list is empty."
            : "lark-cli not available on PATH. Install lark-cli to browse Lark docs."
        return BoardAPI.jsonResponse(ExternalItemsEnvelope(provider: "lark", items: [], notice: notice))
    }

    // MARK: - 错误映射

    private static func mapIntegrationError(_ err: IntegrationError) -> HttpResponse {
        switch err {
        case .noToken:
            return BoardAPI.errorResponse(
                "integration_not_connected",
                "GITHUB_TOKEN not found in ccops. Run: ccops set GITHUB_TOKEN --value <token>",
                status: 412
            )
        case .upstream(let message):
            return BoardAPI.errorResponse("integration_upstream", message, status: 502)
        }
    }
}

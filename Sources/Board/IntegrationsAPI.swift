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

    /// 单个集成的连接状态。`connected` = 可用；`reason` 解释未连接原因。
    struct IntegrationStatusDTO: Encodable {
        let id: String          // "github" | "lark"
        let name: String
        let connected: Bool
        let reason: String?     // 未连接时的人类可读说明（含修复建议）
    }

    struct IntegrationStatusEnvelope: Encodable {
        let integrations: [IntegrationStatusDTO]
    }

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

    /// GET /api/integrations/status
    static func getStatus(_ req: HttpRequest) -> HttpResponse {
        let token = githubToken()
        let github = IntegrationStatusDTO(
            id: "github",
            name: "GitHub",
            connected: token != nil,
            reason: token != nil
                ? nil
                : "GITHUB_TOKEN not found in ccops. Run: ccops set GITHUB_TOKEN --value <token>"
        )
        // Lark 走 lark-cli；探测 CLI 是否安装即可，真实鉴权由 lark-cli 自身维护。
        let larkProbe = IntegrationsAPI.envRun("lark-cli", ["--version"])
        let larkConnected = larkProbe.code == 0
        let lark = IntegrationStatusDTO(
            id: "lark",
            name: "Lark",
            connected: larkConnected,
            reason: larkConnected
                ? "Doc browsing not yet wired — see TODO(lark)."
                : "lark-cli not available on PATH."
        )
        return BoardAPI.jsonResponse(IntegrationStatusEnvelope(integrations: [github, lark]))
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

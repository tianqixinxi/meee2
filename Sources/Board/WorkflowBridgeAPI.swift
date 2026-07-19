import Foundation
import Swifter
import Meee2CommKit

/// workflow-bridge 的 HTTP 面（仿 ArtifactPageAPI 的 extension BoardAPI 分文件模式）。
extension BoardAPI {

    /// POST /api/workflow-bridge/runs
    ///
    /// meee2-workflow-bridge 插件（≥0.2.0）拦截原生 Workflow 调用后在这里注册：
    /// meee2 建 canvas 骨架、spawn relay 会话、挂 journal watcher。幂等——同
    /// runId 重复注册返回既有记录（bridge 超时重试安全）。旧版 bridge 不调
    /// 这个端点（fallback 走 /api/sessions/spawn，行为同旧版）。
    static func registerWorkflowBridgeRun(_ req: HttpRequest) -> HttpResponse {
        guard let json = parseJSONBody(req) else {
            return errorResponse("invalid_json", "body is not valid JSON", status: 400)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let registration = try? JSONDecoder().decode(
                  WorkflowBridgeRunService.Registration.self, from: data
              ) else {
            return errorResponse(
                "bad_request",
                "body must contain runId/runDir/cwd/command (workflowName/originSessionId/meta optional)",
                status: 400
            )
        }
        guard !registration.runId.isEmpty, !registration.runDir.isEmpty,
              !registration.cwd.isEmpty, !registration.command.isEmpty else {
            return errorResponse("bad_request", "runId/runDir/cwd/command must be non-empty", status: 400)
        }
        guard registration.runId.range(
            of: #"^wfbridge-[a-z0-9-]{8,120}$"#,
            options: .regularExpression
        ) != nil else {
            return errorResponse("bad_request", "runId has an invalid format", status: 400)
        }
        let allowedRoot = StorageRoots.processDefault.baseDirectory
            .appendingPathComponent("workflow-bridge/runs", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let runURL = URL(fileURLWithPath: registration.runDir, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let allowedPrefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
        guard runURL.path.hasPrefix(allowedPrefix),
              runURL.deletingLastPathComponent().path == allowedRoot.path else {
            return errorResponse("bad_request", "runDir must be a direct child of the workflow bridge runs directory", status: 400)
        }
        var cwdIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: registration.cwd, isDirectory: &cwdIsDirectory),
              cwdIsDirectory.boolValue else {
            return errorResponse("bad_request", "cwd must be an existing directory", status: 400)
        }
        guard registration.command.hasPrefix("MEEE2_WORKFLOW_RELAY=1 claude ") else {
            return errorResponse("bad_request", "command must be a guarded workflow relay command", status: 400)
        }
        do {
            let result = try WorkflowBridgeRunService.shared.register(registration)
            return jsonResponse(result, status: 201, reason: "Created")
        } catch {
            return errorResponse("register_failed", error.localizedDescription, status: 500)
        }
    }
}

import Foundation
import Swifter

/// 全局 "ask & spawn" assistant —— 跑本地 `claude -p` 帮用户选 cwd 并开新 session。
///
/// 设计背景：用户想在 Web UI 里用自然语言描述 "去 meee1 开个新 claude"，
/// 而不是手填路径。做成一个 per-conversation 的 chat endpoint，前端把全部
/// 历史 POST 过来，后端单轮 `claude -p` 吐下一条回复。
///
/// 为什么不用 `--session-id`：这种短交互多轮状态管理不划算；把历史拼回去
/// prompt 里足够了，而且每次 stateless 更好 debug。
///
/// 收敛信号：让 assistant 在确定 cwd 之后，输出一段 ```spawn fence：
///   ```spawn
///   {"cwd": "/abs/path"}
///   ```
/// 前端看到这个 fence 就渲染"Spawn here"按钮，点击走现有
/// `POST /api/sessions/spawn`。
enum AssistantAPI {

    // MARK: - 请求/响应

    private struct ChatRequest: Decodable {
        let messages: [ChatMessage]
    }
    private struct ChatMessage: Decodable {
        let role: String   // "user" | "assistant"
        let content: String
    }
    private struct ChatResponse: Encodable {
        let content: String
    }

    // MARK: - 路由

    /// POST /api/assistant/chat
    /// Body: `{"messages": [{"role": "user|assistant", "content": "..."}]}`
    static func chat(_ req: HttpRequest) -> HttpResponse {
        let data = Data(req.body)
        guard let parsed = try? JSONDecoder().decode(ChatRequest.self, from: data) else {
            return BoardAPI.errorResponse("invalid_json", "expected {messages: [{role, content}]}", status: 400)
        }
        guard !parsed.messages.isEmpty,
              parsed.messages.last?.role == "user",
              !(parsed.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            return BoardAPI.errorResponse("bad_request", "last message must be user with non-empty content", status: 400)
        }

        // 拼上下文
        let systemPrompt = buildSystemPrompt()
        let userPrompt = renderConversation(parsed.messages)

        // 跑 claude -p
        let result = runClaudePrint(systemPrompt: systemPrompt, userPrompt: userPrompt, timeout: 30.0)
        switch result {
        case .success(let text):
            return BoardAPI.jsonResponse(ChatResponse(content: text))
        case .failure(let reason):
            return BoardAPI.errorResponse("assistant_failed", reason, status: 500)
        }
    }

    // MARK: - System prompt & conversation rendering

    private static func buildSystemPrompt() -> String {
        let cwds = candidateCwds()
        let cwdList = cwds.isEmpty
            ? "(no recent projects found)"
            : cwds.map { "- \($0)" }.joined(separator: "\n")

        return """
        You are a concise assistant that helps the user pick a working directory (cwd) for a new Claude Code session, and then triggers the spawn via a structured final answer. You have no tools.

        Known recent project directories on this machine:
        \(cwdList)

        The user's home is \(NSHomeDirectory()).

        Guidelines:
        - Be brief. Ask at most one clarifying question per turn, only when strictly necessary.
        - Absolute paths (expand `~` to the user's home) are mandatory in the final answer.
        - If the user's intent is clear enough — e.g. they named a project that matches the list above, or gave an explicit path — skip confirmation and jump to the final answer.
        - The final answer MUST end with a fenced code block tagged `spawn` containing a single-line JSON object with key `cwd`:

          ```spawn
          {"cwd": "/Users/.../projects/foo"}
          ```

          The fenced block triggers the UI to render a "Spawn here" button. Include it only when you have a definitive cwd.
        - Do not invent paths not in the list unless the user explicitly provides one.
        - Do not suggest running arbitrary commands; only the `cwd` matters.
        - Respond in the same language as the user (usually Chinese).
        """
    }

    private static func renderConversation(_ messages: [ChatMessage]) -> String {
        // 把多轮对话渲染成一段文本喂给 claude -p。最后一行明确提示 assistant
        // 接着说哪一轮，减少 claude 把自己当用户接话的概率。
        var out: [String] = []
        for m in messages {
            let role = m.role.lowercased() == "assistant" ? "Assistant" : "User"
            out.append("\(role): \(m.content)")
        }
        out.append("Assistant:")
        return out.joined(separator: "\n\n")
    }

    // MARK: - 候选目录

    /// 从 SessionTerminalStore 里拿历史 session 的完整 cwd（hook 每次都带
    /// 真实 cwd 到这个 store），再加 `~/projects/*` 一层的子目录作为冷启动
    /// 兜底。返回去重后的绝对路径列表，最多 30 个避免 prompt 过长。
    ///
    /// 为什么不用 SessionData/PluginSession：SessionData.project 只存 basename
    /// ("meee1")、toPluginSession 把 cwd 也设成这个 basename，没完整路径。
    /// transcript 路径解码不稳（`_` 和 `/` 都被 mangle 成 `-`）。只有
    /// SessionTerminalStore 从 hook payload 里拿到真正的 cwd 并持久化了。
    private static func candidateCwds() -> [String] {
        var seen: Set<String> = []
        var out: [String] = []

        // 1) 历史 session terminal info 里的完整 cwd（按 lastActivityAt 从新到旧）
        let infos = SessionTerminalStore.shared.getAll().values
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        for info in infos {
            let cwd = (info.cwd as NSString).standardizingPath
            if cwd.hasPrefix("/"), !seen.contains(cwd) {
                seen.insert(cwd)
                out.append(cwd)
                if out.count >= 20 { break }
            }
        }

        // 2) ~/projects/*（一层），兜底给新环境
        let projectsRoot = (NSHomeDirectory() as NSString).appendingPathComponent("projects")
        if let children = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) {
            for child in children.sorted() {
                let path = (projectsRoot as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if !seen.contains(path) {
                    seen.insert(path)
                    out.append(path)
                    if out.count >= 30 { break }
                }
            }
        }

        return out
    }

    // MARK: - 跑 claude -p

    private enum RunResult {
        case success(String)
        case failure(String)
    }

    private static func runClaudePrint(systemPrompt: String, userPrompt: String, timeout: TimeInterval) -> RunResult {
        // claude 不一定在默认 PATH 上。先找几个常见位置，都没有再走 `/usr/bin/env claude`。
        let claudePath = resolveClaudeBinary()

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        if let claudePath = claudePath {
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = [
                "-p",
                "--append-system-prompt", systemPrompt,
                "--no-session-persistence",
                "--output-format", "text"
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "claude",
                "-p",
                "--append-system-prompt", systemPrompt,
                "--no-session-persistence",
                "--output-format", "text"
            ]
        }

        // 继承用户环境，保证 OAuth / HOME / PATH 都对齐。
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure("failed to launch claude: \(error.localizedDescription)")
        }

        // 喂 prompt
        let handle = stdin.fileHandleForWriting
        if let payload = userPrompt.data(using: .utf8) {
            handle.write(payload)
        }
        try? handle.close()

        // 带 timeout 等进程退出
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                return .failure("claude -p timed out after \(Int(timeout))s")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? ""
            return .failure("claude exited \(process.terminationStatus): \(err.prefix(400))")
        }

        return .success(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func resolveClaudeBinary() -> String? {
        let candidates = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }
}

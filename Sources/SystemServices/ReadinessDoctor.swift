import Foundation

public enum ReadinessStatus: String, Codable {
    case pass
    case fail
    case warn
    case info
}

public enum ReadinessSeverity: String, Codable {
    case required
    case recommended
    case informational
}

public enum ReadinessOverallStatus: String, Codable {
    case ready
    case needsSetup
    case broken
}

public struct ReadinessAction: Codable {
    public let id: String
    public let label: String
    public let kind: String
    public let command: String?
}

public struct ReadinessCheck: Codable {
    public let id: String
    public let title: String
    public let status: ReadinessStatus
    public let severity: ReadinessSeverity
    public let detail: String
    public let recoveryAction: ReadinessAction?
    public let metadata: [String: String]
}

public struct ReadinessReport: Codable {
    public let overall: ReadinessOverallStatus
    public let ready: Bool
    public let requiredFailed: Int
    public let checks: [ReadinessCheck]
    public let checkedAt: Date
}

public struct ReadinessRepairResult: Codable {
    public let ok: Bool
    public let actionId: String
    public let messages: [String]
    public let logs: [String]
    public let report: ReadinessReport
}

public enum ReadinessDoctor {
    public static func diagnose() -> ReadinessReport {
        let runtime = Meee2AgentRuntimeInstaller.diagnose()
        let hookStatus = SettingsConfigManager.shared.diagnoseHooks()
        let mcpStatus = MCPConfigManager.shared.diagnoseMeee2Server()

        var checks: [ReadinessCheck] = []
        checks.append(providerCheck(
            id: "provider.claude",
            title: "Claude Code runtime",
            providerName: "Claude Code",
            component: runtime.claude,
            actionId: "configure-provider-claude"
        ))
        checks.append(providerCheck(
            id: "provider.codex",
            title: "Codex runtime",
            providerName: "Codex",
            component: runtime.codex,
            actionId: "configure-provider-codex"
        ))
        checks.append(hookCheck(hookStatus))
        checks.append(hookSocketCheck())
        checks.append(boardServerCheck())
        checks.append(mcpCheck(mcpStatus))
        checks.append(contentsOf: storageChecks(
            stagedMCPServerPath: runtime.stagedMCPServerPath,
            expectedMCPServerPath: runtime.mcpServerPath
        ))

        let requiredFailed = checks.filter { $0.severity == .required && $0.status == .fail }.count
        let overall: ReadinessOverallStatus = requiredFailed == 0 ? .ready : .needsSetup
        return ReadinessReport(
            overall: overall,
            ready: requiredFailed == 0,
            requiredFailed: requiredFailed,
            checks: checks,
            checkedAt: Date()
        )
    }

    public static func repair(actionId: String) -> ReadinessRepairResult {
        let normalized = actionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var messages: [String] = []
        var logs: [String] = []

        switch normalized {
        case "configure-hooks":
            SettingsConfigManager.shared.ensureHooksConfigured()
            messages.append("Configured Claude Code hooks.")
            logs.append("[ReadinessDoctor] configured Claude Code hooks")
        case "configure-provider-claude":
            let result = Meee2AgentRuntimeInstaller.install(target: "claude")
            messages.append(contentsOf: result.messages)
            logs.append(contentsOf: result.logs)
        case "configure-provider-codex":
            let result = Meee2AgentRuntimeInstaller.install(target: "codex")
            messages.append(contentsOf: result.messages)
            logs.append(contentsOf: result.logs)
        case "configure-provider-all", "configure-runtime-all":
            SettingsConfigManager.shared.ensureHooksConfigured()
            let result = Meee2AgentRuntimeInstaller.install(target: "all")
            messages.append("Configured Claude Code hooks.")
            messages.append(contentsOf: result.messages)
            logs.append("[ReadinessDoctor] configured Claude Code hooks")
            logs.append(contentsOf: result.logs)
        default:
            messages.append("Unknown readiness recovery action: \(actionId)")
            logs.append("[ReadinessDoctor] unknown action \(actionId)")
        }

        let report = diagnose()
        let ok = !messages.first(where: { $0.lowercased().contains("unknown readiness") }).isSome
        return ReadinessRepairResult(
            ok: ok,
            actionId: normalized,
            messages: messages,
            logs: logs,
            report: report
        )
    }

    private static func providerCheck(
        id: String,
        title: String,
        providerName: String,
        component: AgentRuntimeComponentStatus,
        actionId: String
    ) -> ReadinessCheck {
        if component.available {
            let passed = component.configured
            return ReadinessCheck(
                id: id,
                title: title,
                status: passed ? .pass : .fail,
                severity: .required,
                detail: component.detail ?? (passed ? "\(providerName) is configured." : "\(providerName) is installed but not configured."),
                recoveryAction: passed ? nil : ReadinessAction(
                    id: actionId,
                    label: "Configure \(providerName)",
                    kind: "repair",
                    command: component.command
                ),
                metadata: [
                    "cliAvailable": component.cliAvailable ? "true" : "false",
                    "appAvailable": component.appAvailable ? "true" : "false",
                    "cliPath": component.cliPath ?? "",
                    "appPath": component.appPath ?? ""
                ]
            )
        }

        return ReadinessCheck(
            id: id,
            title: title,
            status: .info,
            severity: .informational,
            detail: "\(providerName) was not found on this Mac.",
            recoveryAction: nil,
            metadata: [
                "cliAvailable": "false",
                "appAvailable": "false"
            ]
        )
    }

    private static func hookCheck(_ status: SettingsConfigManager.HookConfigurationStatus) -> ReadinessCheck {
        let passed = status.configured
        let detail: String
        if passed {
            detail = "Claude Code hooks point at the current meee2 bridge."
        } else if status.unreadable {
            detail = status.error ?? "Claude Code settings could not be read."
        } else if !status.outdatedEvents.isEmpty {
            detail = "Claude Code hooks exist but some events point at an old bridge path."
        } else {
            detail = status.error ?? "Claude Code hooks are missing."
        }

        return ReadinessCheck(
            id: "provider-hook.claude",
            title: "Claude Code hooks",
            status: passed ? .pass : .fail,
            severity: .required,
            detail: detail,
            recoveryAction: passed ? nil : ReadinessAction(
                id: "configure-hooks",
                label: "Configure hooks",
                kind: "repair",
                command: nil
            ),
            metadata: [
                "settingsPath": status.settingsPath,
                "expectedBridgePath": status.expectedBridgePath,
                "missingEvents": status.missingEvents.joined(separator: ","),
                "outdatedEvents": status.outdatedEvents.joined(separator: ",")
            ]
        )
    }

    private static func hookSocketCheck() -> ReadinessCheck {
        let result = probeHookSocket()
        return ReadinessCheck(
            id: "surface.hook-socket",
            title: "Hook socket",
            status: result.ok ? .pass : .fail,
            severity: .required,
            detail: result.ok ? "Synthetic probe reached /tmp/meee2.sock." : result.message,
            recoveryAction: result.ok ? nil : ReadinessAction(
                id: "restart-meee2",
                label: "Restart meee2",
                kind: "manual",
                command: "meee2 gui"
            ),
            metadata: ["path": HookSocketServer.socketPath]
        )
    }

    private static func boardServerCheck() -> ReadinessCheck {
        let runtime = boardServerRuntime()
        let running = BoardServer.shared.isRunning || runtime.running
        let url = BoardServer.shared.isRunning ? BoardServer.shared.url : (runtime.url ?? BoardServer.shared.url)
        let port = BoardServer.shared.isRunning ? "\(BoardServer.shared.port)" : (runtime.port.map(String.init) ?? "\(BoardServer.shared.port)")
        return ReadinessCheck(
            id: "surface.board-server",
            title: "BoardServer",
            status: running ? .pass : .fail,
            severity: .required,
            detail: running ? "BoardServer is listening at \(url)." : "BoardServer is not running.",
            recoveryAction: running ? nil : ReadinessAction(
                id: "start-board-server",
                label: "Start BoardServer",
                kind: "manual",
                command: "meee2 board"
            ),
            metadata: [
                "url": url,
                "port": port,
                "pid": runtime.pid.map(String.init) ?? ""
            ]
        )
    }

    private static func boardServerRuntime() -> (running: Bool, url: String?, port: Int?, pid: Int?) {
        guard let fileURL = try? BoardServer.runtimeInfoFileURL(),
              let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, nil, nil, nil)
        }
        let pid = object["pid"] as? Int
        let url = object["url"] as? String
        let port = object["port"] as? Int
        let running: Bool
        if let pid {
            running = kill(pid_t(pid), 0) == 0
        } else {
            running = false
        }
        return (running, url, port, pid)
    }

    private static func mcpCheck(_ status: Meee2MCPStatus) -> ReadinessCheck {
        let passed = status.configured && status.serverExists && status.nodeAvailable && status.launches && status.missingRequiredTools.isEmpty
        return ReadinessCheck(
            id: "runtime.meee2-mcp",
            title: "Meee2 MCP runtime",
            status: passed ? .pass : .fail,
            severity: .required,
            detail: passed ? "Meee2 MCP server launches and exposes required tools." : (status.error ?? "Meee2 MCP runtime is not ready."),
            recoveryAction: passed ? nil : ReadinessAction(
                id: "configure-provider-all",
                label: "Configure runtime",
                kind: "repair",
                command: nil
            ),
            metadata: [
                "expectedServerPath": status.expectedServerPath,
                "serverPath": status.serverPath ?? "",
                "missingRequiredTools": status.missingRequiredTools.joined(separator: ",")
            ]
        )
    }

    private static func storageChecks(stagedMCPServerPath: String?, expectedMCPServerPath: String) -> [ReadinessCheck] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let meee2 = home.appendingPathComponent(".meee2", isDirectory: true)
        let sessions = meee2.appendingPathComponent("sessions", isDirectory: true)
        let board = meee2.appendingPathComponent("board-canvases.json", isDirectory: false)
        let runtime = (stagedMCPServerPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
            ?? meee2.appendingPathComponent("mcp-meee2", isDirectory: true)

        return [
            storageCheck(
                id: "storage.sessions",
                title: "Session store",
                path: sessions,
                directory: true,
                detailName: "session records"
            ),
            storageCheck(
                id: "storage.board-layout",
                title: "Board layout store",
                path: board.deletingLastPathComponent(),
                directory: true,
                detailName: "board layout state"
            ),
            storageCheck(
                id: "storage.runtime",
                title: "Runtime staging store",
                path: runtime,
                directory: true,
                detailName: "runtime setup state"
            )
        ]
    }

    private static func storageCheck(
        id: String,
        title: String,
        path: URL,
        directory: Bool,
        detailName: String
    ) -> ReadinessCheck {
        let target = directory ? path : path.deletingLastPathComponent()
        let result = verifyWritableDirectory(target)
        return ReadinessCheck(
            id: id,
            title: title,
            status: result.ok ? .pass : .fail,
            severity: .required,
            detail: result.ok ? "Can read and write \(detailName) at \(target.path)." : result.message,
            recoveryAction: result.ok ? nil : ReadinessAction(
                id: "open-\(id.replacingOccurrences(of: ".", with: "-"))",
                label: "Open folder",
                kind: "manual",
                command: "open \(shellQuote(target.path))"
            ),
            metadata: ["path": target.path]
        )
    }

    private static func verifyWritableDirectory(_ url: URL) -> (ok: Bool, message: String) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".meee2-readiness-\(UUID().uuidString)")
            try "ok".write(to: probe, atomically: true, encoding: .utf8)
            _ = try String(contentsOf: probe, encoding: .utf8)
            try FileManager.default.removeItem(at: probe)
            return (true, "ok")
        } catch {
            return (false, "Cannot read/write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func probeHookSocket() -> (ok: Bool, message: String) {
        guard FileManager.default.fileExists(atPath: HookSocketServer.socketPath) else {
            return (false, "Hook socket does not exist at \(HookSocketServer.socketPath).")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return (false, "Could not create Unix socket for synthetic probe.")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        HookSocketServer.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            return (false, "Synthetic probe could not connect to hook socket (errno \(errno)).")
        }

        let payload = #"{"meee2_probe":true}"#
        guard let data = payload.data(using: .utf8) else {
            return (false, "Synthetic probe payload could not be encoded.")
        }
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        guard written == data.count else {
            return (false, "Synthetic probe could not write to hook socket.")
        }
        shutdown(fd, SHUT_WR)

        var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFd, 1, 800)
        guard pollResult > 0 else {
            return (false, "Hook socket did not answer synthetic probe.")
        }

        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            return (false, "Hook socket closed before returning synthetic probe response.")
        }
        let text = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
        guard text.contains(#""ok":true"#) else {
            return (false, "Hook socket returned an unexpected synthetic probe response.")
        }
        return (true, "ok")
    }

    private static func shellQuote(_ raw: String) -> String {
        if raw.range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return raw
        }
        return "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private extension Optional {
    var isSome: Bool {
        switch self {
        case .some: return true
        case .none: return false
        }
    }
}

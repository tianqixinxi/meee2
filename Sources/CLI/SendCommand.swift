import Foundation
import Meee2PluginKit

/// Send 命令 - 向指定会话发送消息
public struct SendCommand {
    public static func run(sessionId: String, message: String) -> CLIExitCode {
        let resolution = CLISessionResolver.resolve(sessionId)
        guard case .matched(let session) = resolution else {
            return CLISessionResolver.reportFailure(resolution, prefix: sessionId)
        }

        // 将消息写入队列
        let msgId = SessionStore.shared.enqueue(session.sessionId, message: message)

        print("Message #\(msgId) queued for session \(session.sessionId)")
        print("  Project: \(session.project)")
        print("  Status: \(session.status.displayName)")
        return .success
    }
}

/// Jump 命令 - 显示会话终端信息（跳转需要 GUI 模式）
public struct JumpCommand {
    public static func run(sessionId: String) -> CLIExitCode {
        let resolution = CLISessionResolver.resolve(sessionId)
        guard case .matched(let session) = resolution else {
            return CLISessionResolver.reportFailure(resolution, prefix: sessionId)
        }

        let terminal = session.terminalInfo
        guard terminal?.termProgram != nil || terminal?.tty != nil || session.ghosttyTerminalId != nil else {
            CLIOutput.error("Error: session \(session.sessionId) has no terminal target")
            return .failure
        }

        var target = AISession(
            id: session.sessionId,
            pid: session.pid ?? 0,
            cwd: session.cwd ?? session.project,
            startedAt: session.startedAt,
            status: session.status,
            currentTask: session.currentTask,
            toolName: session.currentTool
        )
        target.tty = terminal?.tty
        target.termProgram = terminal?.termProgram
        target.termBundleId = terminal?.termBundleId
        target.cmuxSocketPath = terminal?.cmuxSocketPath
        target.cmuxSurfaceId = terminal?.cmuxSurfaceId
        target.ghosttyTerminalId = session.ghosttyTerminalId

        let resultBox = TerminalJumpResultBox()
        Task {
            resultBox.store(await TerminalJumper.shared.jump(to: target))
        }

        let deadline = Date().addingTimeInterval(5)
        while resultBox.load() == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let result = resultBox.load() else {
            CLIOutput.error("Error: terminal jump timed out")
            return .failure
        }
        switch result {
        case .success:
            print("Focused terminal for session \(session.sessionId)")
            return .success
        case .notFound:
            CLIOutput.error("Error: terminal application is not running")
            return .failure
        case .error(let message):
            CLIOutput.error("Error: terminal jump failed: \(message)")
            return .failure
        }
    }
}

/// Note 命令 - 为会话添加备注
public struct NoteCommand {
    public static func run(sessionId: String, note: String) -> CLIExitCode {
        let resolution = CLISessionResolver.resolve(sessionId)
        guard case .matched(let session) = resolution else {
            return CLISessionResolver.reportFailure(resolution, prefix: sessionId)
        }

        // 更新会话备注
        SessionStore.shared.update(session.sessionId) { data in
            data.description = note
        }

        print("Note added to session \(session.sessionId):")
        print("  \(note)")
        return .success
    }
}

private enum CLISessionResolution {
    case matched(SessionData)
    case missing
    case ambiguous([SessionData])
}

private enum CLISessionResolver {
    static func resolve(_ prefix: String) -> CLISessionResolution {
        let matches = SessionStore.shared.listAll().filter { $0.sessionId.hasPrefix(prefix) }
        let resolution: CLISessionResolution
        if let exact = matches.first(where: { $0.sessionId == prefix }) {
            resolution = .matched(exact)
        } else if matches.isEmpty {
            resolution = .missing
        } else if matches.count == 1 {
            resolution = .matched(matches[0])
        } else {
            resolution = .ambiguous(matches)
        }
        return resolution
    }

    static func reportFailure(_ resolution: CLISessionResolution, prefix: String) -> CLIExitCode {
        switch resolution {
        case .missing:
            CLIOutput.error("Error: no session found with ID: \(prefix)")
        case .ambiguous(let sessions):
            CLIOutput.error("Error: multiple sessions match ID prefix '\(prefix)':")
            for session in sessions {
                CLIOutput.error("  \(session.sessionId) - \(session.project)")
            }
        case .matched:
            return .success
        }
        return .notFound
    }
}

private final class TerminalJumpResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: TerminalJumpResult?

    func store(_ result: TerminalJumpResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> TerminalJumpResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

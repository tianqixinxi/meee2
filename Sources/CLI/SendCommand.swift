import Foundation
import Meee2PluginKit

/// Send 命令 - 向指定会话发送消息
public struct SendCommand {
    public static func run(sessionId: String, message: String) {
        let store = SessionStore.shared

        // 查找会话（支持短 ID 匹配）
        let sessions = store.listAll()
        let matchedSessions = sessions.filter { $0.sessionId.hasPrefix(sessionId) }

        if matchedSessions.isEmpty {
            print("No session found with ID: \(sessionId)")
            return
        }

        if matchedSessions.count > 1 {
            print("Multiple sessions match ID prefix '\(sessionId)':")
            for session in matchedSessions {
                print("  \(session.sessionId) - \(session.project)")
            }
            print("Please use a more specific ID")
            return
        }

        let session = matchedSessions[0]

        // 将消息写入队列
        let msgId = store.enqueue(session.sessionId, message: message)

        print("Message #\(msgId) queued for session \(session.sessionId)")
        print("  Project: \(session.project)")
        print("  Status: \(session.status.displayName)")
    }
}

/// Jump 命令 - 显示会话终端信息（跳转需要 GUI 模式）
public struct JumpCommand {
    public static func run(sessionId: String) {
        let store = SessionStore.shared

        // 查找会话（支持短 ID 匹配）
        let sessions = store.listAll()
        let matchedSessions = sessions.filter { $0.sessionId.hasPrefix(sessionId) }

        if matchedSessions.isEmpty {
            print("No session found with ID: \(sessionId)")
            return
        }

        if matchedSessions.count > 1 {
            print("Multiple sessions match ID prefix '\(sessionId)':")
            for session in matchedSessions {
                print("  \(session.sessionId) - \(session.project)")
            }
            print("Please use a more specific ID")
            return
        }

        let session = matchedSessions[0]

        // 显示终端信息
        print("Session: \(session.sessionId)")
        print("  Project: \(session.project)")
        print("  Status: \(session.status.displayName)")
        print("  TTY: \(session.terminalInfo?.tty ?? "N/A")")
        print("  Terminal: \(session.terminalInfo?.termProgram ?? "N/A")")
        print("")
        print("To jump to terminal, run: meee2 (GUI mode)")
        print("Click on the session in the dynamic island to activate terminal")
    }
}

/// Note 命令 - 为会话添加备注
public struct NoteCommand {
    public static func run(sessionId: String, note: String) {
        let store = SessionStore.shared

        // 查找会话（支持短 ID 匹配）
        let sessions = store.listAll()
        let matchedSessions = sessions.filter { $0.sessionId.hasPrefix(sessionId) }

        if matchedSessions.isEmpty {
            print("No session found with ID: \(sessionId)")
            return
        }

        if matchedSessions.count > 1 {
            print("Multiple sessions match ID prefix '\(sessionId)':")
            for session in matchedSessions {
                print("  \(session.sessionId) - \(session.project)")
            }
            print("Please use a more specific ID")
            return
        }

        let session = matchedSessions[0]

        // 更新会话备注
        store.update(session.sessionId) { data in
            data.description = note
        }

        print("Note added to session \(session.sessionId):")
        print("  \(note)")
    }
}
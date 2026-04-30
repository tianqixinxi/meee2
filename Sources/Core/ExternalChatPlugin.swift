// ExternalChatPlugin —— 接收浏览器插件 / 外部源推过来的 chat session。
//
// 不是 dylib —— 在 AppDelegate 里直接 init + register。这样 BoardAPI 的
// REST handler 能直接调到 plugin 实例的 upsert / appendMessage / remove
// 方法，不用走 dylib 边界。
//
// Sessions 模型：
//   - source 决定 `sessionPrefix`（chatgpt-web → "chatgpt-", claude-web →
//     "claude-web-"），sid = "<prefix><externalId>"
//   - 浏览器侧在每个 conversation 上以 conversation id 做 externalId
//   - title 来自浏览器 DOM 抓的对话标题
//   - cwd 用来塞 url（"https://chatgpt.com/c/<id>"）让 webui 能 click 跳回
//
// 相比 CursorPlugin（pull-based 扫文件夹），这个 plugin 是 push-based —
// `getSessions()` 直接返回内存数组；start/stop 没有 timer；refresh 是 noop。
// 数据由外部 REST 调用驱动，每次 mutate 后调 onSessionsUpdated 让
// PluginManager 推到 BoardServer / Meee360Pusher。

import Foundation
import SwiftUI
import AppKit
import Meee2PluginKit

public final class ExternalChatPlugin: SessionPlugin {

    // MARK: - 单例（BoardAPI handlers 直接拿）
    public static let shared = ExternalChatPlugin()

    // MARK: - 标识
    public override var pluginId: String { "com.meee2.plugin.external-chat" }
    public override var displayName: String { "Web Chat" }
    public override var icon: String { "globe" }
    public override var themeColor: Color { Color(red: 0.36, green: 0.51, blue: 0.78) }
    public override var version: String { "0.1.0" }

    // MARK: - In-memory store

    /// Source-specific config. Add a case here when the browser extension
    /// adds a new adapter (chatgpt / claude.ai / gemini / ...).
    public enum Source: String {
        case chatgptWeb = "chatgpt-web"
        case claudeWeb = "claude-web"
        case other = "external"

        var pluginColor: String {
            switch self {
            case .chatgptWeb: return "#10A37F"        // OpenAI green
            case .claudeWeb: return "#CC785C"         // Anthropic terracotta
            case .other:     return "#5B7FC7"
            }
        }
        var displayName: String {
            switch self {
            case .chatgptWeb: return "ChatGPT"
            case .claudeWeb: return "Claude"
            case .other:     return "Web Chat"
            }
        }
    }

    private struct ExternalSession {
        var sid: String
        var source: Source
        var externalId: String
        var title: String
        var url: String?
        var status: SessionStatus
        var startedAt: Date
        var lastUpdated: Date
        /// Last 20 messages for the recentMessages preview on the card.
        var recentMessages: [Message]
    }

    private struct Message {
        let role: String          // "user" | "assistant" | "system"
        let text: String
        let timestamp: Date
    }

    private let lock = NSLock()
    private var sessions: [String: ExternalSession] = [:]

    // MARK: - Lifecycle (push-based, nothing to start)
    public override func initialize() -> Bool { true }
    public override func start() -> Bool { true }
    public override func stop() {}
    public override func cleanup() {}

    public override func getSessions() -> [PluginSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .map { toPluginSession($0) }
    }

    public override func refresh() {
        // External-driven; nothing to pull.
    }

    public override func activateTerminal(for session: PluginSession) {
        // Click on a Web Chat card → re-open the conversation tab.
        // The url was stashed in cwd at upsert time so we don't have to
        // extend PluginSession for one optional field.
        guard let url = session.cwd, let nsurl = URL(string: url) else { return }
        NSWorkspace.shared.open(nsurl)
    }

    // MARK: - External REST entry points (called by BoardAPI handlers)

    public struct UpsertResult {
        public let sid: String
        public let isNew: Bool
    }

    /// Called by POST /api/external-sessions/upsert
    @discardableResult
    public func upsert(
        source rawSource: String,
        externalId: String,
        title: String,
        url: String?,
        status: String,
        recentMessages: [(role: String, text: String, timestamp: Date?)]
    ) -> UpsertResult {
        let source = Source(rawValue: rawSource) ?? .other
        let sid = "\(source.rawValue)-\(externalId)"

        lock.lock()
        let isNew = sessions[sid] == nil
        let now = Date()
        var existing = sessions[sid] ?? ExternalSession(
            sid: sid,
            source: source,
            externalId: externalId,
            title: title,
            url: url,
            status: parseStatus(status),
            startedAt: now,
            lastUpdated: now,
            recentMessages: []
        )
        existing.title = title
        existing.url = url ?? existing.url
        existing.status = parseStatus(status)
        existing.lastUpdated = now
        // Merge recent messages — keep last 20, dedupe by (role, text) on
        // adjacent rows so polling pushes don't duplicate the tail.
        for m in recentMessages {
            let entry = Message(role: m.role, text: m.text, timestamp: m.timestamp ?? now)
            if let last = existing.recentMessages.last,
               last.role == entry.role && last.text == entry.text {
                continue
            }
            existing.recentMessages.append(entry)
        }
        if existing.recentMessages.count > 20 {
            existing.recentMessages = Array(existing.recentMessages.suffix(20))
        }
        sessions[sid] = existing
        lock.unlock()

        notifyUpdated()
        return UpsertResult(sid: sid, isNew: isNew)
    }

    /// Called by POST /api/external-sessions/:sid/append-message
    public func appendMessage(sid: String, role: String, text: String, timestamp: Date?) -> Bool {
        lock.lock()
        guard var s = sessions[sid] else { lock.unlock(); return false }
        let entry = Message(role: role, text: text, timestamp: timestamp ?? Date())
        if let last = s.recentMessages.last, last.role == entry.role && last.text == entry.text {
            // Dedupe identical adjacent push.
            lock.unlock()
            return true
        }
        s.recentMessages.append(entry)
        if s.recentMessages.count > 20 {
            s.recentMessages = Array(s.recentMessages.suffix(20))
        }
        s.lastUpdated = Date()
        sessions[sid] = s
        lock.unlock()
        notifyUpdated()
        return true
    }

    /// Called by DELETE /api/external-sessions/:sid (browser tab closed).
    public func remove(sid: String) -> Bool {
        lock.lock()
        let existed = sessions.removeValue(forKey: sid) != nil
        lock.unlock()
        if existed { notifyUpdated() }
        return existed
    }

    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.keys)
    }

    // MARK: - Internals

    private func notifyUpdated() {
        let snapshot = getSessions()
        DispatchQueue.main.async { [weak self] in
            self?.onSessionsUpdated?(snapshot)
        }
    }

    private func parseStatus(_ raw: String) -> SessionStatus {
        switch raw.lowercased() {
        case "thinking", "active", "tooling": return .active
        case "idle", "waiting", "waitingforuser": return .idle
        case "completed": return .idle
        case "dead", "closed": return .dead
        default: return .idle
        }
    }

    private func toPluginSession(_ s: ExternalSession) -> PluginSession {
        // Use the latest assistant message (or any latest) as lastMessage so
        // the cards/list shows something meaningful at a glance.
        let preview = s.recentMessages.last.map { String($0.text.prefix(160)) }
        return PluginSession(
            id: s.sid,
            pluginId: pluginId,
            title: s.title.isEmpty ? s.source.displayName : s.title,
            status: s.status,
            startedAt: s.startedAt,
            subtitle: s.source.displayName,
            lastUpdated: s.lastUpdated,
            cwd: s.url,                                // url stashed for activateTerminal
            icon: "bubble.left.and.bubble.right",
            accentColor: nil,
            lastMessage: preview
        )
    }
}

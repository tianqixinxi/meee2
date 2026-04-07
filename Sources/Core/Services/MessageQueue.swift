import Foundation

/// 会话间消息 (来自 CSM)
struct SessionMessage: Codable {
    let id: String
    let fromSessionId: String
    let toSessionId: String
    let content: String
    let createdAt: Date
    var deliveredAt: Date?
}

/// 会话间消息队列
/// 移植自 CSM 的 queue.py，支持会话间通信
/// 消息在目标会话 Stop 时通过终端投递
class MessageQueue {
    static let shared = MessageQueue()

    private let queuesDir: URL
    private let queue = DispatchQueue(label: "com.peerisland.messagequeue")

    init(baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".peer-island")
        self.queuesDir = base.appendingPathComponent("queues")
        try? FileManager.default.createDirectory(at: queuesDir, withIntermediateDirectories: true)
    }

    // MARK: - 操作

    /// 入队消息
    func enqueue(from fromId: String, to toId: String, content: String) {
        queue.async { [self] in
            let msg = SessionMessage(
                id: UUID().uuidString,
                fromSessionId: fromId,
                toSessionId: toId,
                content: content,
                createdAt: Date()
            )
            let path = queuePath(for: toId)
            var messages = loadMessages(at: path)
            messages.append(msg)
            atomicWrite(messages, to: path)
        }
    }

    /// 出队一条消息 (FIFO)
    func dequeue(for sessionId: String) -> SessionMessage? {
        queue.sync { [self] in
            let path = queuePath(for: sessionId)
            var messages = loadMessages(at: path)
            guard !messages.isEmpty else { return nil }
            let msg = messages.removeFirst()
            if messages.isEmpty {
                try? FileManager.default.removeItem(at: path)
            } else {
                atomicWrite(messages, to: path)
            }
            return msg
        }
    }

    /// 查看待处理消息数
    func pending(for sessionId: String) -> Int {
        queue.sync {
            loadMessages(at: queuePath(for: sessionId)).count
        }
    }

    /// 清空某会话的所有待处理消息
    func clear(for sessionId: String) {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: queuePath(for: sessionId))
        }
    }

    // MARK: - 内部

    private func queuePath(for sessionId: String) -> URL {
        let safeName = sessionId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return queuesDir.appendingPathComponent("\(safeName).queue.json")
    }

    private func loadMessages(at path: URL) -> [SessionMessage] {
        guard let data = try? Data(contentsOf: path),
              let messages = try? JSONDecoder().decode([SessionMessage].self, from: data) else {
            return []
        }
        return messages
    }

    private func atomicWrite(_ messages: [SessionMessage], to path: URL) {
        let tmpPath = path.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: tmpPath)
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmpPath)
        } catch {
            try? FileManager.default.removeItem(at: tmpPath)
        }
    }
}

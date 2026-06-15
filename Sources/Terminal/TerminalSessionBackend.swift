import Foundation
import Meee2PluginKit

public enum TerminalSessionBackendKind: String, Codable {
    case ghosttySurface = "ghostty-surface"
    case external = "external"
}

public enum Meee2SessionScope: String, Codable {
    case meee2
    case canvas
    case node
    case external

    public static func managed(canvasId: String?, nodeId: String?) -> Meee2SessionScope {
        if nodeId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return .node }
        if canvasId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return .canvas }
        return .meee2
    }
}

public struct TerminalSessionRequest: Equatable {
    public let provider: String
    public let cwd: String
    public let command: String
    public let canvasId: String?
    public let nodeId: String?
    public let sessionScope: Meee2SessionScope
    public let initialPrompt: String?
    /// initialPrompt 就绪门控的硬上限(秒)。nil = 后端默认(20s,适合 fresh
    /// session 的快速启动)。大会话 `--resume` 的 TUI 加载可能远超 20s —
    /// 上限到点的「盲打」会把 prompt 敲进还没渲染好的界面而丢失;这类调用方
    /// 应给更长的耐心(settle 检测在加载安静后自然触发,上限只是最后兜底)。
    public let initialPromptSettleCeiling: TimeInterval?
    public let preferredSessionId: String?
    public let cols: UInt16
    public let rows: UInt16

    public init(
        provider: String,
        cwd: String,
        command: String,
        canvasId: String?,
        nodeId: String?,
        sessionScope: Meee2SessionScope? = nil,
        initialPrompt: String?,
        initialPromptSettleCeiling: TimeInterval? = nil,
        preferredSessionId: String? = nil,
        cols: UInt16 = 120,
        rows: UInt16 = 30
    ) {
        self.provider = provider
        self.cwd = cwd
        self.command = command
        self.canvasId = canvasId
        self.nodeId = nodeId
        self.sessionScope = sessionScope ?? Meee2SessionScope.managed(canvasId: canvasId, nodeId: nodeId)
        self.initialPrompt = initialPrompt
        self.initialPromptSettleCeiling = initialPromptSettleCeiling
        self.preferredSessionId = preferredSessionId
        self.cols = cols
        self.rows = rows
    }
}

public struct TerminalSessionSnapshot: Codable, Equatable {
    public let sessionId: String
    public let surfaceId: String
    public let backend: TerminalSessionBackendKind
    public let status: String
    public let pid: Int?
    public let cwd: String
    public let command: String
    public let provider: String
    public let canvasId: String?
    public let nodeId: String?
    public let sessionScope: Meee2SessionScope
    public let createdAt: Date
    public let updatedAt: Date
    public let fallbackReason: String?

    public init(
        sessionId: String,
        surfaceId: String,
        backend: TerminalSessionBackendKind,
        status: String,
        pid: Int?,
        cwd: String,
        command: String,
        provider: String,
        canvasId: String?,
        nodeId: String?,
        sessionScope: Meee2SessionScope? = nil,
        createdAt: Date,
        updatedAt: Date,
        fallbackReason: String? = nil
    ) {
        self.sessionId = sessionId
        self.surfaceId = surfaceId
        self.backend = backend
        self.status = status
        self.pid = pid
        self.cwd = cwd
        self.command = command
        self.provider = provider
        self.canvasId = canvasId
        self.nodeId = nodeId
        self.sessionScope = sessionScope ?? Meee2SessionScope.managed(canvasId: canvasId, nodeId: nodeId)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fallbackReason = fallbackReason
    }
}

public struct TerminalSessionHandle: Equatable {
    public let snapshot: TerminalSessionSnapshot

    public init(snapshot: TerminalSessionSnapshot) {
        self.snapshot = snapshot
    }
}

public protocol TerminalSessionBackend {
    var kind: TerminalSessionBackendKind { get }

    func createSession(request: TerminalSessionRequest) throws -> TerminalSessionHandle
    func closeSession(id: String) throws
    func resizeSession(id: String, cols: UInt16, rows: UInt16)
    func focusSession(id: String)
    func writeInput(id: String, data: Data)
    /// 向已就绪的 agent REPL 投递一条要**提交执行**的 prompt。和 writeInput
    /// 的区别:writeInput 是裸字节,文本里的 "\n" 在 TUI composer 里是插入
    /// 换行而非提交;deliverPrompt 负责「打字 + 按 Return 键」的完整提交
    /// 动作(节奏与 initialPrompt 的就绪门控投递一致)。提交排程期间(打字
    /// 到 Return 落键的窗口)的重复投递会被拒绝为 .busy — 否则第二条文本
    /// 会打进同一个 composer,被第一个 Return 拼成一条畸形请求提交。
    func deliverPrompt(id: String, text: String) -> PromptDeliveryOutcome
    func snapshot(id: String) -> TerminalSessionSnapshot?
    func listSnapshots() -> [TerminalSessionSnapshot]
}

/// deliverPrompt 的投递结果。调用方据此如实上报:busy 不是失败,是
/// 「上一条还在提交窗口里」的去重信号。
public enum PromptDeliveryOutcome {
    case delivered
    case busy
    case sessionNotFound
}

public enum TerminalSessionBackendMetadata {
    public static func kind(forSessionId sessionId: String) -> TerminalSessionBackendKind? {
        guard let raw = SessionTerminalStore.shared.get(sessionId: sessionId)?.backend else { return nil }
        return TerminalSessionBackendKind(rawValue: raw)
    }

    public static func fallbackReason(forSessionId sessionId: String) -> String? {
        SessionTerminalStore.shared.get(sessionId: sessionId)?.fallbackReason
    }

    public static func recordManagedSession(
        snapshot: TerminalSessionSnapshot,
        termProgram: String,
        termBundleId: String,
        lastMessage: String
    ) {
        let terminalInfo = PluginTerminalInfo(
            tty: nil,
            termProgram: termProgram,
            termBundleId: termBundleId,
            cmuxSocketPath: nil,
            cmuxSurfaceId: snapshot.surfaceId,
            jumpHandlerId: termProgram
        )
        SessionStore.shared.create(SessionData(
            sessionId: snapshot.sessionId,
            project: URL(fileURLWithPath: snapshot.cwd).lastPathComponent,
            cwd: snapshot.cwd,
            providerResumeSessionId: AgentLaunchCommand.isLikelyProviderResumeSessionId(snapshot.sessionId) ? snapshot.sessionId : nil,
            startedAt: snapshot.createdAt,
            lastActivity: snapshot.updatedAt,
            status: snapshot.status == InternalTerminalLifecycle.exited.rawValue ? .dead : .active,
            currentTool: "terminal",
            currentTask: snapshot.nodeId.map { "Node \($0)" },
            terminalInfo: terminalInfo,
            lastMessage: lastMessage
        ))
        SessionTerminalStore.shared.update(
            sessionId: snapshot.sessionId,
            tty: nil,
            termProgram: termProgram,
            termBundleId: termBundleId,
            cmuxSocketPath: nil,
            cmuxSurfaceId: snapshot.surfaceId,
            cwd: snapshot.cwd,
            status: snapshot.status,
            command: snapshot.command,
            provider: snapshot.provider,
            canvasId: snapshot.canvasId,
            nodeId: snapshot.nodeId,
            sessionScope: snapshot.sessionScope.rawValue,
            backend: snapshot.backend.rawValue,
            fallbackReason: snapshot.fallbackReason
        )
    }

    public static func updateManagedSessionStatus(
        snapshot: TerminalSessionSnapshot,
        termProgram: String,
        termBundleId: String
    ) {
        SessionTerminalStore.shared.update(
            sessionId: snapshot.sessionId,
            tty: nil,
            termProgram: termProgram,
            termBundleId: termBundleId,
            cmuxSocketPath: nil,
            cmuxSurfaceId: snapshot.surfaceId,
            cwd: snapshot.cwd,
            status: snapshot.status,
            command: snapshot.command,
            provider: snapshot.provider,
            canvasId: snapshot.canvasId,
            nodeId: snapshot.nodeId,
            sessionScope: snapshot.sessionScope.rawValue,
            backend: snapshot.backend.rawValue,
            fallbackReason: snapshot.fallbackReason
        )
        if var data = SessionStore.shared.get(snapshot.sessionId) {
            data.status = snapshot.status == InternalTerminalLifecycle.exited.rawValue ? .dead : .active
            data.lastActivity = snapshot.updatedAt
            data.currentTool = snapshot.status == InternalTerminalLifecycle.exited.rawValue ? nil : "terminal"
            SessionStore.shared.create(data)
        }
    }
}

public enum TerminalSessionBackendError: LocalizedError, Equatable {
    case sessionNotFound(String)
    case backendUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "terminal session not found: \(id)"
        case .backendUnavailable(let reason):
            return reason
        }
    }
}

public final class TerminalSessionBackendRegistry {
    public static let shared = TerminalSessionBackendRegistry()

    private let lock = NSLock()
    private var backends: [TerminalSessionBackendKind: TerminalSessionBackend] = [:]
    private var preferredOverride: TerminalSessionBackendKind?

    private init() {}

    public func register(_ backend: TerminalSessionBackend) {
        lock.lock()
        backends[backend.kind] = backend
        lock.unlock()
    }

    public func setPreferredKind(_ kind: TerminalSessionBackendKind?) {
        lock.lock()
        preferredOverride = kind
        lock.unlock()
    }

    public func preferredKind() -> TerminalSessionBackendKind {
        if let envKind = environmentPreferredKind() {
            return envKind
        }
        lock.lock()
        let preferred = preferredOverride ?? .ghosttySurface
        lock.unlock()
        return preferred
    }

    public func createSession(request: TerminalSessionRequest) throws -> TerminalSessionHandle {
        let kind = preferredKind()
        guard let selectedBackend = registeredBackend(for: kind) else {
            throw TerminalSessionBackendError.backendUnavailable(
                "\(kind.rawValue) backend is not registered in this process"
            )
        }
        return try selectedBackend.createSession(request: request)
    }

    public func closeSession(id: String) throws {
        guard let backend = backendForExistingSession(id: id) else {
            throw TerminalSessionBackendError.sessionNotFound(id)
        }
        try backend.closeSession(id: id)
    }

    @discardableResult
    public func closeSessionIfExists(id: String) -> Bool {
        guard let backend = backendForExistingSession(id: id) else { return false }
        do {
            try backend.closeSession(id: id)
            return true
        } catch {
            return false
        }
    }

    public func resizeSession(id: String, cols: UInt16, rows: UInt16) {
        backendForExistingSession(id: id)?.resizeSession(id: id, cols: cols, rows: rows)
    }

    public func focusSession(id: String) {
        backendForExistingSession(id: id)?.focusSession(id: id)
    }

    @discardableResult
    public func writeInput(id: String, data: Data) -> Bool {
        guard let backend = backendForExistingSession(id: id) else { return false }
        backend.writeInput(id: id, data: data)
        return true
    }

    public func deliverPrompt(id: String, text: String) -> PromptDeliveryOutcome {
        guard let backend = backendForExistingSession(id: id) else { return .sessionNotFound }
        return backend.deliverPrompt(id: id, text: text)
    }

    public func snapshot(id: String) -> TerminalSessionSnapshot? {
        backendForExistingSession(id: id)?.snapshot(id: id)
    }

    public func listSnapshots() -> [TerminalSessionSnapshot] {
        lock.lock()
        let values = Array(backends.values)
        lock.unlock()
        return values
            .flatMap { $0.listSnapshots() }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func isManagedSession(_ id: String) -> Bool {
        snapshot(id: id) != nil
    }

    private func registeredBackend(for kind: TerminalSessionBackendKind) -> TerminalSessionBackend? {
        lock.lock()
        let backend = backends[kind]
        lock.unlock()
        return backend
    }

    private func backendForExistingSession(id: String) -> TerminalSessionBackend? {
        let explicitKind: TerminalSessionBackendKind? = {
            guard let raw = SessionTerminalStore.shared.get(sessionId: id)?.backend else { return nil }
            return TerminalSessionBackendKind(rawValue: raw)
        }()
        lock.lock()
        let values = Array(backends.values)
        let explicitBackend = explicitKind.flatMap { backends[$0] }
        lock.unlock()
        if let explicitBackend,
           explicitBackend.snapshot(id: id) != nil {
            return explicitBackend
        }
        return values.first { $0.snapshot(id: id) != nil }
    }

    private func environmentPreferredKind() -> TerminalSessionBackendKind? {
        guard let raw = ProcessInfo.processInfo.environment["MEEE2_TERMINAL_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return TerminalSessionBackendKind(rawValue: raw)
    }
}

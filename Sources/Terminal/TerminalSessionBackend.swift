import Foundation
import Meee2PluginKit

public enum TerminalSessionBackendKind: String, Codable {
    case legacyInternal = "legacy-internal"
    case ghosttySurface = "ghostty-surface"
    case external = "external"
}

public struct TerminalSessionRequest: Equatable {
    public let provider: String
    public let cwd: String
    public let command: String
    public let canvasId: String?
    public let nodeId: String?
    public let initialPrompt: String?
    public let preferredSessionId: String?
    public let cols: UInt16
    public let rows: UInt16

    public init(
        provider: String,
        cwd: String,
        command: String,
        canvasId: String?,
        nodeId: String?,
        initialPrompt: String?,
        preferredSessionId: String? = nil,
        cols: UInt16 = 120,
        rows: UInt16 = 30
    ) {
        self.provider = provider
        self.cwd = cwd
        self.command = command
        self.canvasId = canvasId
        self.nodeId = nodeId
        self.initialPrompt = initialPrompt
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
    func snapshot(id: String) -> TerminalSessionSnapshot?
    func listSnapshots() -> [TerminalSessionSnapshot]
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

    private init() {
        backends[LegacyInternalTerminalBackend.shared.kind] = LegacyInternalTerminalBackend.shared
    }

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
        // New Canvas terminal sessions default to the persistent Ghostty native
        // surface backend. The legacy in-memory PTY backend remains as a
        // fallback or explicit MEEE2_TERMINAL_BACKEND override, but new sessions
        // should not depend on raw scrollback replay into a fresh TerminalView.
        let preferred = preferredOverride ?? .ghosttySurface
        lock.unlock()
        return preferred
    }

    public func createSession(request: TerminalSessionRequest) throws -> TerminalSessionHandle {
        let kind = preferredKind()
        guard let selectedBackend = registeredBackend(for: kind) else {
            return try createFallbackSession(
                request: request,
                attemptedKind: kind,
                reason: "backend is not registered in this process"
            )
        }
        do {
            return try selectedBackend.createSession(request: request)
        } catch {
            guard kind != .legacyInternal else { throw error }
            return try createFallbackSession(
                request: request,
                attemptedKind: kind,
                reason: error.localizedDescription
            )
        }
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

    private func backend(for kind: TerminalSessionBackendKind) -> TerminalSessionBackend {
        lock.lock()
        let backend = backends[kind] ?? backends[.legacyInternal] ?? LegacyInternalTerminalBackend.shared
        lock.unlock()
        return backend
    }

    private func registeredBackend(for kind: TerminalSessionBackendKind) -> TerminalSessionBackend? {
        lock.lock()
        let backend = backends[kind]
        lock.unlock()
        return backend
    }

    private func createFallbackSession(
        request: TerminalSessionRequest,
        attemptedKind: TerminalSessionBackendKind,
        reason: String
    ) throws -> TerminalSessionHandle {
        let legacy = backend(for: TerminalSessionBackendKind.legacyInternal)
        let fallback = try legacy.createSession(request: request)
        SessionTerminalStore.shared.updateBackend(
            sessionId: fallback.snapshot.sessionId,
            backend: TerminalSessionBackendKind.legacyInternal.rawValue,
            fallbackReason: "\(attemptedKind.rawValue): \(reason)"
        )
        return fallback
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

public final class LegacyInternalTerminalBackend: TerminalSessionBackend {
    public static let shared = LegacyInternalTerminalBackend()

    public let kind: TerminalSessionBackendKind = .legacyInternal

    public init() {}

    public func createSession(request: TerminalSessionRequest) throws -> TerminalSessionHandle {
        let surface = try InternalTerminalRuntime.shared.createSurface(
            provider: request.provider,
            cwd: request.cwd,
            command: request.command,
            canvasId: request.canvasId,
            nodeId: request.nodeId,
            initialPrompt: request.initialPrompt,
            preferredSessionId: request.preferredSessionId,
            cols: request.cols,
            rows: request.rows
        )
        markBackend(sessionId: surface.sessionId, surfaceId: surface.surfaceId)
        return TerminalSessionHandle(snapshot: Self.snapshot(from: surface, backend: kind))
    }

    public func closeSession(id: String) throws {
        guard InternalTerminalRuntime.shared.close(surfaceOrSessionId: id) else {
            throw TerminalSessionBackendError.sessionNotFound(id)
        }
    }

    public func resizeSession(id: String, cols: UInt16, rows: UInt16) {
        _ = InternalTerminalRuntime.shared.resize(surfaceOrSessionId: id, cols: cols, rows: rows)
    }

    public func focusSession(id: String) {
        _ = id
    }

    public func writeInput(id: String, data: Data) {
        _ = InternalTerminalRuntime.shared.writeInputData(surfaceOrSessionId: id, data: data)
    }

    public func snapshot(id: String) -> TerminalSessionSnapshot? {
        InternalTerminalRuntime.shared.snapshot(surfaceOrSessionId: id)
            .map { Self.snapshot(from: $0, backend: kind) }
    }

    public func listSnapshots() -> [TerminalSessionSnapshot] {
        InternalTerminalRuntime.shared.listSnapshots()
            .map { Self.snapshot(from: $0, backend: kind) }
    }

    private func markBackend(sessionId: String, surfaceId: String) {
        guard let existing = SessionTerminalStore.shared.get(sessionId: sessionId) else { return }
        SessionTerminalStore.shared.update(
            sessionId: sessionId,
            tty: existing.tty,
            termProgram: existing.termProgram,
            termBundleId: existing.termBundleId,
            cmuxSocketPath: existing.cmuxSocketPath,
            cmuxSurfaceId: existing.cmuxSurfaceId ?? surfaceId,
            cwd: existing.cwd,
            status: existing.status,
            command: existing.command,
            provider: existing.provider,
            providerResumeSessionId: existing.providerResumeSessionId,
            canvasId: existing.canvasId,
            nodeId: existing.nodeId,
            backend: kind.rawValue
        )
    }

    private static func snapshot(
        from surface: InternalTerminalSurfaceSnapshot,
        backend: TerminalSessionBackendKind
    ) -> TerminalSessionSnapshot {
        TerminalSessionSnapshot(
            sessionId: surface.sessionId,
            surfaceId: surface.surfaceId,
            backend: backend,
            status: surface.status,
            pid: surface.pid,
            cwd: surface.cwd,
            command: surface.command,
            provider: surface.provider,
            canvasId: surface.canvasId,
            nodeId: surface.nodeId,
            createdAt: surface.createdAt,
            updatedAt: surface.updatedAt
        )
    }
}

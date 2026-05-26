import Foundation
import Darwin
import Meee2PluginKit

public enum InternalTerminalLifecycle: String, Codable {
    case starting
    case running
    case exited
    case failed
}

public struct InternalTerminalSurfaceSnapshot: Encodable {
    public let surfaceId: String
    public let sessionId: String
    public let provider: String
    public let title: String
    public let cwd: String
    public let command: String
    public let canvasId: String?
    public let nodeId: String?
    public let status: String
    public let pid: Int?
    public let exitCode: Int?
    public let error: String?
    public let createdAt: Date
    public let updatedAt: Date
}

@MainActor
public protocol InternalTerminalSurfaceClient: AnyObject {
    func internalTerminalSurface(_ surfaceId: String, didReplayOutput data: Data)
    func internalTerminalSurface(_ surfaceId: String, didReplayOutput text: String)
    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput data: Data)
    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput text: String)
    func internalTerminalSurface(_ surfaceId: String, didChangeStatus snapshot: InternalTerminalSurfaceSnapshot)
    func internalTerminalSurface(_ surfaceId: String, didExitWithCode code: Int)
}

public extension InternalTerminalSurfaceClient {
    func internalTerminalSurface(_ surfaceId: String, didReplayOutput data: Data) {
        internalTerminalSurface(surfaceId, didReplayOutput: String(decoding: data, as: UTF8.self))
    }
    func internalTerminalSurface(_ surfaceId: String, didReplayOutput text: String) {}
    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput data: Data) {
        internalTerminalSurface(surfaceId, didReceiveOutput: String(decoding: data, as: UTF8.self))
    }
    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput text: String) {}
    func internalTerminalSurface(_ surfaceId: String, didChangeStatus snapshot: InternalTerminalSurfaceSnapshot) {}
    func internalTerminalSurface(_ surfaceId: String, didExitWithCode code: Int) {}
}

final class WeakInternalTerminalSurfaceClient {
    weak var value: InternalTerminalSurfaceClient?

    init(_ value: InternalTerminalSurfaceClient) {
        self.value = value
    }
}

public final class InternalTerminalRuntime {
    public static let shared = InternalTerminalRuntime()

    private let lock = NSLock()
    private var surfaces: [String: InternalTerminalSurface] = [:]
    private var surfaceBySessionId: [String: String] = [:]
    private var didRestorePersistedSurfaces = false

    private init() {}

    @discardableResult
    public func restorePersistedSurfaces() -> Int {
        lock.lock()
        if didRestorePersistedSurfaces {
            lock.unlock()
            return 0
        }
        didRestorePersistedSurfaces = true
        lock.unlock()

        let candidates = SessionTerminalStore.shared.getAll().values
            .filter { ($0.termProgram ?? "").lowercased() == "meee2-internal" }
            .filter {
                let status = $0.status.lowercased()
                return status != InternalTerminalLifecycle.exited.rawValue
                    && status != InternalTerminalLifecycle.failed.rawValue
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }

        var restored = 0
        for info in candidates {
            if isInternalSession(info.sessionId) { continue }
            let storedSession = SessionStore.shared.get(info.sessionId)
            guard let command = restoreCommand(for: info, storedSession: storedSession) else {
                continue
            }
            let provider = restoreProvider(for: info, command: command)
            do {
                _ = try createSurface(
                    provider: provider,
                    cwd: info.cwd,
                    command: command,
                    canvasId: info.canvasId,
                    nodeId: info.nodeId,
                    initialPrompt: nil,
                    preferredSessionId: info.sessionId
                )
                restored += 1
            } catch {
                SessionTerminalStore.shared.update(
                    sessionId: info.sessionId,
                    tty: nil,
                    termProgram: "meee2-internal",
                    termBundleId: "meee2-internal",
                    cmuxSocketPath: nil,
                    cmuxSurfaceId: info.cmuxSurfaceId,
                    cwd: info.cwd,
                    status: InternalTerminalLifecycle.failed.rawValue,
                    command: command,
                    provider: provider,
                    canvasId: info.canvasId,
                    nodeId: info.nodeId
                )
                MWarn("[InternalTerminalRuntime] restore failed sid=\(info.sessionId.prefix(8)): \(error.localizedDescription)")
            }
        }
        if restored > 0 {
            MLog("[InternalTerminalRuntime] restored \(restored) persisted internal session surface(s)")
        }
        return restored
    }

    public func createSurface(
        provider: String,
        cwd: String,
        command: String,
        canvasId: String?,
        nodeId: String?,
        initialPrompt: String?,
        preferredSessionId: String? = nil,
        cols: UInt16 = 120,
        rows: UInt16 = 30
    ) throws -> InternalTerminalSurfaceSnapshot {
        let normalizedProvider = provider == "codex" ? "codex" : "claude"
        let requestedSessionId = preferredSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionId = requestedSessionId.isEmpty ? "\(normalizedProvider)-internal-\(UUID().uuidString)" : requestedSessionId
        lock.lock()
        if let existingSurfaceId = surfaceBySessionId[sessionId],
           let existingSurface = surfaces[existingSurfaceId] {
            lock.unlock()
            return existingSurface.snapshot()
        }
        lock.unlock()

        let surface = InternalTerminalSurface(
            surfaceId: UUID().uuidString,
            sessionId: sessionId,
            provider: normalizedProvider,
            cwd: cwd,
            command: command,
            canvasId: canvasId,
            nodeId: nodeId
        )

        lock.lock()
        surfaces[surface.surfaceId] = surface
        surfaceBySessionId[surface.sessionId] = surface.surfaceId
        lock.unlock()

        let terminalInfo = PluginTerminalInfo(
            tty: nil,
            termProgram: "meee2-internal",
            termBundleId: "meee2-internal",
            cmuxSocketPath: nil,
            cmuxSurfaceId: surface.surfaceId,
            jumpHandlerId: "meee2-internal"
        )
        SessionStore.shared.create(SessionData(
            sessionId: sessionId,
            project: URL(fileURLWithPath: cwd).lastPathComponent,
            cwd: cwd,
            startedAt: surface.createdAt,
            lastActivity: surface.createdAt,
            status: .active,
            currentTool: "terminal",
            currentTask: nodeId.map { "Node \($0)" },
            terminalInfo: terminalInfo,
            lastMessage: "Internal terminal session started"
        ))
        SessionTerminalStore.shared.update(
            sessionId: sessionId,
            tty: nil,
            termProgram: "meee2-internal",
            termBundleId: "meee2-internal",
            cmuxSocketPath: nil,
            cmuxSurfaceId: surface.surfaceId,
            cwd: cwd,
            status: InternalTerminalLifecycle.starting.rawValue,
            command: command,
            provider: normalizedProvider,
            canvasId: canvasId,
            nodeId: nodeId
        )

        try surface.start(cols: cols, rows: rows)
        if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
                surface.writeInput(prompt + "\n")
            }
        }
        return surface.snapshot()
    }

    public func listSnapshots() -> [InternalTerminalSurfaceSnapshot] {
        lock.lock()
        let values = Array(surfaces.values)
        lock.unlock()
        return values
            .map { $0.snapshot() }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func snapshot(surfaceOrSessionId id: String) -> InternalTerminalSurfaceSnapshot? {
        surface(surfaceOrSessionId: id)?.snapshot()
    }

    public func surfaceId(forSessionId sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return surfaceBySessionId[sessionId]
    }

    public func isInternalSession(_ id: String) -> Bool {
        surface(surfaceOrSessionId: id) != nil
    }

    public func close(surfaceOrSessionId id: String) -> Bool {
        guard let surface = surface(surfaceOrSessionId: id) else { return false }
        surface.terminate()
        return true
    }

    public func writeInput(sessionId: String, text: String) -> Bool {
        guard let surface = surface(surfaceOrSessionId: sessionId) else { return false }
        surface.writeInput(text)
        return true
    }

    public func writeInput(surfaceOrSessionId id: String, text: String) -> Bool {
        guard let surface = surface(surfaceOrSessionId: id) else { return false }
        surface.writeInput(text)
        return true
    }

    public func writeInputData(surfaceOrSessionId id: String, data: Data) -> Bool {
        guard let surface = surface(surfaceOrSessionId: id) else { return false }
        surface.writeInput(data)
        return true
    }

    public func resize(surfaceOrSessionId id: String, cols: UInt16, rows: UInt16) -> Bool {
        guard let surface = surface(surfaceOrSessionId: id) else { return false }
        surface.resize(cols: cols, rows: rows)
        return true
    }

    public func addClient(_ client: InternalTerminalSurfaceClient, surfaceOrSessionId id: String) -> Bool {
        guard let surface = surface(surfaceOrSessionId: id) else { return false }
        surface.addClient(client)
        return true
    }

    public func removeClient(_ client: InternalTerminalSurfaceClient, surfaceOrSessionId id: String) {
        surface(surfaceOrSessionId: id)?.removeClient(client)
    }

    func remove(surface: InternalTerminalSurface) {
        lock.lock()
        surfaces.removeValue(forKey: surface.surfaceId)
        surfaceBySessionId.removeValue(forKey: surface.sessionId)
        lock.unlock()
    }

    private func surface(surfaceOrSessionId id: String) -> InternalTerminalSurface? {
        lock.lock()
        defer { lock.unlock() }
        if let direct = surfaces[id] { return direct }
        if let surfaceId = surfaceBySessionId[id] { return surfaces[surfaceId] }
        return nil
    }

    private func restoreCommand(for info: SessionTerminalInfo, storedSession: SessionData?) -> String? {
        if let command = info.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return command
        }
        guard storedSession != nil else {
            return nil
        }
        let sessionId = info.sessionId
        if sessionId.lowercased().contains("codex") {
            return "codex --dangerously-bypass-approvals-and-sandbox resume \(Self.shellQuote(sessionId))"
        }
        return "claude --resume \(Self.shellQuote(sessionId)) --dangerously-skip-permissions"
    }

    private func restoreProvider(for info: SessionTerminalInfo, command: String) -> String {
        if let provider = info.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !provider.isEmpty {
            return provider == "codex" ? "codex" : "claude"
        }
        let lower = command.lowercased()
        if lower.contains("codex") || info.sessionId.lowercased().contains("codex") {
            return "codex"
        }
        return "claude"
    }

    private static func shellQuote(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

final class InternalTerminalSurface {
    let surfaceId: String
    let sessionId: String
    let provider: String
    let cwd: String
    let command: String
    let canvasId: String?
    let nodeId: String?
    let createdAt: Date

    private let lock = NSLock()
    private var process: Foundation.Process?
    private var masterHandle: FileHandle?
    private var masterFD: Int32 = -1
    private var nativeClients: [ObjectIdentifier: WeakInternalTerminalSurfaceClient] = [:]
    private var scrollback = Data()
    private var status: InternalTerminalLifecycle = .starting
    private var pid: Int?
    private var exitCode: Int?
    private var errorMessage: String?
    private var updatedAt: Date

    init(surfaceId: String, sessionId: String, provider: String, cwd: String, command: String, canvasId: String?, nodeId: String?) {
        self.surfaceId = surfaceId
        self.sessionId = sessionId
        self.provider = provider
        self.cwd = cwd
        self.command = command
        self.canvasId = canvasId
        self.nodeId = nodeId
        self.createdAt = Date()
        self.updatedAt = self.createdAt
    }

    func start(cols: UInt16, rows: UInt16) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            markFailed("openpty failed: \(String(cString: strerror(errno)))")
            throw NSError(domain: "InternalTerminalRuntime", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "openpty failed"])
        }

        masterFD = master
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        self.masterHandle = masterHandle

        let proc = Foundation.Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "cd \(Self.shellQuote(cwd)) && exec \(command)"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        proc.environment = startupEnvironment()
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        proc.terminationHandler = { [weak self] process in
            self?.handleExit(code: Int(process.terminationStatus))
        }

        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.emitOutput(data)
        }

        do {
            try proc.run()
            slaveHandle.closeFile()
            process = proc
            pid = Int(proc.processIdentifier)
            status = .running
            touch()
            notifyNativeClientsStatus(snapshot())
            SessionStore.shared.update(sessionId) { session in
                session.pid = self.pid
                session.status = .active
                session.currentTool = "terminal"
                session.lastMessage = "Internal terminal running"
            }
            SessionTerminalStore.shared.update(
                sessionId: sessionId,
                tty: nil,
                termProgram: "meee2-internal",
                termBundleId: "meee2-internal",
                cmuxSocketPath: nil,
                cmuxSurfaceId: surfaceId,
                cwd: cwd,
                status: InternalTerminalLifecycle.running.rawValue,
                command: command,
                provider: provider,
                canvasId: canvasId,
                nodeId: nodeId
            )
        } catch {
            slaveHandle.closeFile()
            markFailed("process start failed: \(error.localizedDescription)")
            throw error
        }
    }

    func snapshot() -> InternalTerminalSurfaceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    func writeInput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        writeInput(data)
    }

    func writeInput(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.write(masterFD, base, rawBuffer.count)
        }
        touch()
    }

    func addClient(_ client: InternalTerminalSurfaceClient) {
        let key = ObjectIdentifier(client)
        lock.lock()
        nativeClients[key] = WeakInternalTerminalSurfaceClient(client)
        let replay = scrollback
        let snapshot = snapshotLocked()
        lock.unlock()

        Task { @MainActor in
            client.internalTerminalSurface(self.surfaceId, didChangeStatus: snapshot)
            if !replay.isEmpty {
                client.internalTerminalSurface(self.surfaceId, didReplayOutput: replay)
            }
        }
    }

    func removeClient(_ client: InternalTerminalSurfaceClient) {
        lock.lock()
        nativeClients.removeValue(forKey: ObjectIdentifier(client))
        lock.unlock()
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
        if let pid = process?.processIdentifier, pid > 0 {
            _ = Darwin.kill(pid, SIGWINCH)
        }
    }

    func terminate() {
        lock.lock()
        let proc = process
        lock.unlock()
        if proc?.isRunning == true {
            proc?.terminate()
        } else {
            handleExit(code: exitCode ?? 0)
        }
    }

    private func handleExit(code: Int) {
        masterHandle?.readabilityHandler = nil
        lock.lock()
        status = .exited
        exitCode = code
        updatedAt = Date()
        lock.unlock()

        SessionStore.shared.update(sessionId) { session in
            session.status = .dead
            session.currentTool = nil
            session.lastMessage = "Internal terminal exited with code \(code)"
        }
        SessionTerminalStore.shared.update(
            sessionId: sessionId,
            tty: nil,
            termProgram: "meee2-internal",
            termBundleId: "meee2-internal",
            cmuxSocketPath: nil,
            cmuxSurfaceId: surfaceId,
            cwd: cwd,
            status: InternalTerminalLifecycle.exited.rawValue,
            command: command,
            provider: provider,
            canvasId: canvasId,
            nodeId: nodeId
        )
        let snapshot = snapshot()
        notifyNativeClientsStatus(snapshot)
        notifyNativeClientsExit(code)
        BoardServer.shared.broadcastStateChanged()
    }

    private func markFailed(_ message: String) {
        lock.lock()
        status = .failed
        errorMessage = message
        updatedAt = Date()
        lock.unlock()
        SessionStore.shared.update(sessionId) { session in
            session.status = .dead
            session.currentTool = nil
            session.lastMessage = message
        }
        SessionTerminalStore.shared.update(
            sessionId: sessionId,
            tty: nil,
            termProgram: "meee2-internal",
            termBundleId: "meee2-internal",
            cmuxSocketPath: nil,
            cmuxSurfaceId: surfaceId,
            cwd: cwd,
            status: InternalTerminalLifecycle.failed.rawValue,
            command: command,
            provider: provider,
            canvasId: canvasId,
            nodeId: nodeId
        )
        notifyNativeClientsStatus(snapshot())
        BoardServer.shared.broadcastStateChanged()
    }

    private func touch() {
        lock.lock()
        updatedAt = Date()
        lock.unlock()
    }

    private func emitOutput(_ data: Data) {
        touch()
        lock.lock()
        appendScrollbackLocked(data)
        let nativeClients = compactNativeClientsLocked()
        lock.unlock()

        for client in nativeClients {
            Task { @MainActor in
                client.internalTerminalSurface(self.surfaceId, didReceiveOutput: data)
            }
        }
    }

    private func appendScrollbackLocked(_ data: Data) {
        scrollback.append(data)
        let maxLength = 240_000
        if scrollback.count > maxLength {
            scrollback.removeFirst(scrollback.count - maxLength)
        }
    }

    private func compactNativeClientsLocked() -> [InternalTerminalSurfaceClient] {
        var live: [InternalTerminalSurfaceClient] = []
        for (key, box) in nativeClients {
            if let value = box.value {
                live.append(value)
            } else {
                nativeClients.removeValue(forKey: key)
            }
        }
        return live
    }

    private func notifyNativeClientsStatus(_ snapshot: InternalTerminalSurfaceSnapshot) {
        lock.lock()
        let nativeClients = compactNativeClientsLocked()
        lock.unlock()
        for client in nativeClients {
            Task { @MainActor in
                client.internalTerminalSurface(self.surfaceId, didChangeStatus: snapshot)
            }
        }
    }

    private func notifyNativeClientsExit(_ code: Int) {
        lock.lock()
        let nativeClients = compactNativeClientsLocked()
        lock.unlock()
        for client in nativeClients {
            Task { @MainActor in
                client.internalTerminalSurface(self.surfaceId, didExitWithCode: code)
            }
        }
    }

    private func snapshotLocked() -> InternalTerminalSurfaceSnapshot {
        InternalTerminalSurfaceSnapshot(
            surfaceId: surfaceId,
            sessionId: sessionId,
            provider: provider,
            title: "\(provider == "codex" ? "Codex" : "Claude") · \(URL(fileURLWithPath: cwd).lastPathComponent)",
            cwd: cwd,
            command: command,
            canvasId: canvasId,
            nodeId: nodeId,
            status: status.rawValue,
            pid: pid,
            exitCode: exitCode,
            error: errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func startupEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MEEE2_SESSION_ID"] = sessionId
        env["MEEE2_SURFACE_ID"] = surfaceId
        env["MEEE2_TERMINAL_KIND"] = "internal"
        if let canvasId { env["MEEE2_CANVAS_ID"] = canvasId }
        if let nodeId { env["MEEE2_NODE_ID"] = nodeId }
        return env
    }

    private static func shellQuote(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

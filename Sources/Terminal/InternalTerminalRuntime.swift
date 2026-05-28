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
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        internalTerminalSurface(surfaceId, didReplayOutput: text)
    }
    func internalTerminalSurface(_ surfaceId: String, didReplayOutput text: String) {}
    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput data: Data) {
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        internalTerminalSurface(surfaceId, didReceiveOutput: text)
    }
    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput text: String) {}
    func internalTerminalSurface(_ surfaceId: String, didChangeStatus snapshot: InternalTerminalSurfaceSnapshot) {}
    func internalTerminalSurface(_ surfaceId: String, didExitWithCode code: Int) {}
}

final class WeakInternalTerminalSurfaceClient {
    weak var value: InternalTerminalSurfaceClient?
    var wantsOutput: Bool

    init(_ value: InternalTerminalSurfaceClient, wantsOutput: Bool = true) {
        self.value = value
        self.wantsOutput = wantsOutput
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
        var removedUnrestorable = 0
        for info in candidates {
            if isInternalSession(info.sessionId) { continue }
            let storedSession = SessionStore.shared.get(info.sessionId)
            guard let command = restoreCommand(for: info, storedSession: storedSession) else {
                SessionTerminalStore.shared.remove(sessionId: info.sessionId)
                removedUnrestorable += 1
                continue
            }
            guard shouldRestorePersistedSurface(info, command: command) else {
                SessionStore.shared.delete(info.sessionId)
                SessionTerminalStore.shared.remove(sessionId: info.sessionId)
                removedUnrestorable += 1
                MLog("[InternalTerminalRuntime] dropped stale planner internal session sid=\(info.sessionId.prefix(8)); missing provider resume id")
                continue
            }
            let provider = Self.restoreProvider(for: info, command: command)
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
        if removedUnrestorable > 0 {
            MLog("[InternalTerminalRuntime] removed \(removedUnrestorable) unrestorable internal session mapping(s)")
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
            if existingSurface.isReusable {
                lock.unlock()
                return existingSurface.snapshot()
            }
            surfaces.removeValue(forKey: existingSurfaceId)
            surfaceBySessionId.removeValue(forKey: sessionId)
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

        do {
            try surface.start(cols: cols, rows: rows)
        } catch {
            remove(surface: surface)
            SessionStore.shared.delete(sessionId)
            SessionTerminalStore.shared.remove(sessionId: sessionId)
            throw error
        }
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

    public func addClient(
        _ client: InternalTerminalSurfaceClient,
        surfaceOrSessionId id: String,
        replay: Bool = true,
        wantsOutput: Bool = true
    ) -> Bool {
        guard let surface = surface(surfaceOrSessionId: id) else { return false }
        surface.addClient(client, replay: replay, wantsOutput: wantsOutput)
        return true
    }

    public func pauseClientOutput(_ client: InternalTerminalSurfaceClient, surfaceOrSessionId id: String) -> Int64? {
        guard let surface = surface(surfaceOrSessionId: id) else { return nil }
        return surface.pauseClientOutput(client)
    }

    public func resumeClientOutput(
        _ client: InternalTerminalSurfaceClient,
        surfaceOrSessionId id: String,
        since position: Int64?
    ) -> Data? {
        guard let surface = surface(surfaceOrSessionId: id) else { return nil }
        return surface.resumeClientOutput(client, since: position)
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
        if let resumeId = Self.validProviderResumeSessionId(info.providerResumeSessionId) {
            return Self.resumeCommand(for: info, resumeSessionId: resumeId)
        }
        if let command = info.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            if AgentLaunchCommand.commandRequestsResume(command) {
                return Self.freshCommand(for: info, command: command)
            }
            return command
        }
        guard storedSession != nil else {
            return nil
        }
        let sessionId = info.sessionId
        guard !Self.isInternalSessionId(sessionId) else {
            return Self.freshCommand(for: info, command: nil)
        }
        if sessionId.lowercased().contains("codex") {
            return "codex --dangerously-bypass-approvals-and-sandbox resume \(Self.shellQuote(sessionId))"
        }
        return "claude --resume \(Self.shellQuote(sessionId)) --dangerously-skip-permissions"
    }

    private func shouldRestorePersistedSurface(_ info: SessionTerminalInfo, command: String) -> Bool {
        guard isPlannerBound(info) else { return true }
        if Self.validProviderResumeSessionId(info.providerResumeSessionId) != nil {
            return true
        }
        return !isAgentTerminal(info, command: command)
    }

    private func isPlannerBound(_ info: SessionTerminalInfo) -> Bool {
        let canvasId = info.canvasId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nodeId = info.nodeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !canvasId.isEmpty || !nodeId.isEmpty
    }

    private func isAgentTerminal(_ info: SessionTerminalInfo, command: String) -> Bool {
        let haystack = [
            info.provider,
            info.command,
            command,
            info.sessionId
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return haystack.contains("claude") || haystack.contains("codex")
    }

    private static func restoreProvider(for info: SessionTerminalInfo, command: String) -> String {
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

    private static func isInternalSessionId(_ sessionId: String) -> Bool {
        AgentLaunchCommand.isMeee2InternalSessionId(sessionId)
    }

    private static func validProviderResumeSessionId(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !AgentLaunchCommand.isMeee2InternalSessionId(trimmed) else { return nil }
        return trimmed
    }

    private static func resumeCommand(for info: SessionTerminalInfo, resumeSessionId: String) -> String {
        let provider = restoreProvider(for: info, command: info.command ?? "")
        if provider == "codex" {
            return "codex --dangerously-bypass-approvals-and-sandbox resume \(shellQuote(resumeSessionId))"
        }
        return "claude --resume \(shellQuote(resumeSessionId)) --dangerously-skip-permissions"
    }

    private static func freshCommand(for info: SessionTerminalInfo, command: String?) -> String {
        let provider = restoreProvider(for: info, command: command ?? "")
        if provider == "codex" {
            return "codex --dangerously-bypass-approvals-and-sandbox"
        }
        return "claude --dangerously-skip-permissions"
    }
}

final class InternalTerminalSurface {
    private static let maxScrollbackBytes = 2 * 1024 * 1024
    private static let maxPendingClientOutputBytes = 64_000
    private static let scrollbackTrimSearchBytes = 8_192
    private static let replayResetPrefix = Data("\u{001B}[0m\u{001B}[?25h\r\n".utf8)

    let surfaceId: String
    let sessionId: String
    let provider: String
    let cwd: String
    let command: String
    let canvasId: String?
    let nodeId: String?
    let createdAt: Date

    private let lock = NSLock()
    private var processSource: DispatchSourceProcess?
    private var primaryHandle: FileHandle?
    private var primaryFD: Int32 = -1
    private var nativeClients: [ObjectIdentifier: WeakInternalTerminalSurfaceClient] = [:]
    private var scrollback = Data()
    private var scrollbackWasTrimmed = false
    private var scrollbackBaseOffset: Int64 = 0
    private var totalOutputBytes: Int64 = 0
    private var pendingNativeClientOutput = Data()
    private var nativeClientOutputFlushScheduled = false
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
        Self.ensureStandardFileDescriptors()
        Self.markHostFileDescriptorsCloseOnExec()
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var secondaryName = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, &secondaryName, nil, &size) == 0 else {
            markFailed("openpty failed: \(String(cString: strerror(errno)))")
            throw NSError(domain: "InternalTerminalRuntime", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "openpty failed"])
        }
        Self.setCloseOnExec(primary)
        Self.setCloseOnExec(secondary)
        primaryFD = primary
        let primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        self.primaryHandle = primaryHandle

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let arguments = [shell, "-l", "-c", "cd \(Self.shellQuote(cwd)) && exec \(command)"]
        let environment = startupEnvironment(cols: cols, rows: rows)

        primaryHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.emitOutput(data)
        }

        do {
            let launchedPid = try Self.spawnProcess(
                executable: shell,
                arguments: arguments,
                environment: environment,
                secondaryFD: secondary
            )
            Darwin.close(secondary)
            pid = Int(launchedPid)
            processSource = makeProcessExitSource(pid: launchedPid)
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
            Darwin.close(secondary)
            primaryHandle.readabilityHandler = nil
            primaryHandle.closeFile()
            primaryFD = -1
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
        guard primaryFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            _ = Darwin.write(primaryFD, base, rawBuffer.count)
        }
        touch()
    }

    func addClient(
        _ client: InternalTerminalSurfaceClient,
        replay shouldReplay: Bool = true,
        wantsOutput: Bool = true
    ) {
        let key = ObjectIdentifier(client)
        lock.lock()
        nativeClients[key] = WeakInternalTerminalSurfaceClient(client, wantsOutput: wantsOutput)
        let replay = shouldReplay && status == .running ? replayDataLocked() : Data()
        let snapshot = snapshotLocked()
        lock.unlock()

        Task { @MainActor in
            client.internalTerminalSurface(self.surfaceId, didChangeStatus: snapshot)
            if !replay.isEmpty {
                client.internalTerminalSurface(self.surfaceId, didReplayOutput: replay)
            }
        }
    }

    func pauseClientOutput(_ client: InternalTerminalSurfaceClient) -> Int64 {
        let key = ObjectIdentifier(client)
        lock.lock()
        if let box = nativeClients[key] {
            box.wantsOutput = false
        }
        let position = totalOutputBytes
        lock.unlock()
        return position
    }

    func resumeClientOutput(_ client: InternalTerminalSurfaceClient, since position: Int64?) -> Data? {
        let key = ObjectIdentifier(client)
        lock.lock()
        if let box = nativeClients[key] {
            box.wantsOutput = true
        } else {
            nativeClients[key] = WeakInternalTerminalSurfaceClient(client, wantsOutput: true)
        }
        let output: Data
        if let position {
            output = outputDataLocked(since: position)
        } else {
            output = status == .running ? replayDataLocked() : Data()
        }
        lock.unlock()
        return output.isEmpty ? nil : output
    }

    func removeClient(_ client: InternalTerminalSurfaceClient) {
        lock.lock()
        nativeClients.removeValue(forKey: ObjectIdentifier(client))
        lock.unlock()
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard primaryFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(primaryFD, TIOCSWINSZ, &size)
        if let pid, pid > 0 {
            let processGroup = -pid_t(pid)
            if Darwin.kill(processGroup, SIGWINCH) != 0 {
                _ = Darwin.kill(pid_t(pid), SIGWINCH)
            }
        }
    }

    func terminate() {
        lock.lock()
        let pid = pid
        lock.unlock()
        if let pid, pid > 0 {
            _ = Darwin.kill(-pid_t(pid), SIGTERM)
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        } else {
            handleExit(code: exitCode ?? 0)
        }
    }

    private func handleExit(code: Int) {
        processSource?.cancel()
        processSource = nil
        primaryHandle?.readabilityHandler = nil
        primaryHandle?.closeFile()
        primaryFD = -1
        lock.lock()
        status = .exited
        exitCode = code
        updatedAt = Date()
        lock.unlock()

        flushNativeClientOutput()
        let snapshot = snapshot()
        notifyNativeClientsStatus(snapshot)
        notifyNativeClientsExit(code)
        InternalTerminalRuntime.shared.remove(surface: self)
        SessionStore.shared.delete(sessionId)
        SessionTerminalStore.shared.remove(sessionId: sessionId)
        BoardServer.shared.broadcastStateChanged()
    }

    private func makeProcessExitSource(pid: pid_t) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            let code = Self.exitCode(fromWaitStatus: status)
            self?.handleExit(code: code)
        }
        source.resume()
        return source
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int {
        let waitStatus = status & 0o177
        if waitStatus == 0 {
            return Int((status >> 8) & 0xFF)
        }
        if waitStatus != 0o177 {
            return 128 + Int(waitStatus)
        }
        return 0
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
        var immediateOutput: Data?
        var immediateClients: [InternalTerminalSurfaceClient] = []
        var shouldScheduleFlush = false
        lock.lock()
        appendScrollbackLocked(data)
        let hasOutputClients = hasNativeOutputClientsLocked()
        if hasOutputClients {
            pendingNativeClientOutput.append(data)
            if pendingNativeClientOutput.count >= Self.maxPendingClientOutputBytes {
                immediateOutput = pendingNativeClientOutput
                pendingNativeClientOutput.removeAll(keepingCapacity: true)
                nativeClientOutputFlushScheduled = false
                immediateClients = compactNativeClientsLocked(wantsOutputOnly: true)
            } else if !nativeClientOutputFlushScheduled {
                nativeClientOutputFlushScheduled = true
                shouldScheduleFlush = true
            }
        } else if !pendingNativeClientOutput.isEmpty {
            pendingNativeClientOutput.removeAll(keepingCapacity: true)
            nativeClientOutputFlushScheduled = false
        }
        lock.unlock()

        if let immediateOutput {
            notifyNativeClientsOutput(immediateOutput, clients: immediateClients)
        }
        if shouldScheduleFlush {
            DispatchQueue.main.async { [weak self] in
                self?.flushNativeClientOutput()
            }
        }
    }

    private func flushNativeClientOutput() {
        var output: Data?
        var nativeClients: [InternalTerminalSurfaceClient] = []
        lock.lock()
        nativeClientOutputFlushScheduled = false
        if !pendingNativeClientOutput.isEmpty {
            output = pendingNativeClientOutput
            pendingNativeClientOutput.removeAll(keepingCapacity: true)
            nativeClients = compactNativeClientsLocked(wantsOutputOnly: true)
        }
        lock.unlock()

        if let output {
            notifyNativeClientsOutput(output, clients: nativeClients)
        }
    }

    private func notifyNativeClientsOutput(_ data: Data, clients: [InternalTerminalSurfaceClient]) {
        guard !data.isEmpty else { return }
        for client in clients {
            Task { @MainActor in
                client.internalTerminalSurface(self.surfaceId, didReceiveOutput: data)
            }
        }
    }

    private func appendScrollbackLocked(_ data: Data) {
        scrollback.append(data)
        totalOutputBytes += Int64(data.count)
        if scrollback.count > Self.maxScrollbackBytes {
            let preferredCut = scrollback.count - Self.maxScrollbackBytes
            let cut = Self.safeScrollbackTrimIndex(in: scrollback, preferredIndex: preferredCut)
            if cut > 0 {
                scrollback.removeFirst(cut)
                scrollbackBaseOffset += Int64(cut)
                scrollbackWasTrimmed = true
            }
        }
    }

    private func replayDataLocked() -> Data {
        guard scrollbackWasTrimmed else { return scrollback }
        var replay = Data()
        replay.reserveCapacity(Self.replayResetPrefix.count + scrollback.count)
        replay.append(Self.replayResetPrefix)
        replay.append(scrollback)
        return replay
    }

    private func outputDataLocked(since position: Int64) -> Data {
        guard status == .running else { return Data() }
        if position < scrollbackBaseOffset {
            return replayDataLocked()
        }
        guard position < totalOutputBytes else { return Data() }
        let start = max(0, min(scrollback.count, Int(position - scrollbackBaseOffset)))
        let startIndex = scrollback.index(scrollback.startIndex, offsetBy: start)
        return Data(scrollback[startIndex...])
    }

    private static func safeScrollbackTrimIndex(in data: Data, preferredIndex: Int) -> Int {
        guard preferredIndex > 0 else { return 0 }
        let preferredOffset = min(preferredIndex, data.count)
        let upperOffset = min(data.count, preferredOffset + scrollbackTrimSearchBytes)
        let preferred = data.index(data.startIndex, offsetBy: preferredOffset)
        let upper = data.index(data.startIndex, offsetBy: upperOffset)
        var cut = preferredOffset
        if preferred < upper,
           let newline = data[preferred..<upper].firstIndex(of: 0x0A) {
            cut = data.distance(from: data.startIndex, to: data.index(after: newline))
        }
        while cut < data.count {
            let index = data.index(data.startIndex, offsetBy: cut)
            guard (data[index] & 0b1100_0000) == 0b1000_0000 else { break }
            cut += 1
        }
        return min(cut, data.count)
    }

    private func compactNativeClientsLocked(wantsOutputOnly: Bool = false) -> [InternalTerminalSurfaceClient] {
        var live: [InternalTerminalSurfaceClient] = []
        for (key, box) in nativeClients {
            if let value = box.value {
                if !wantsOutputOnly || box.wantsOutput {
                    live.append(value)
                }
            } else {
                nativeClients.removeValue(forKey: key)
            }
        }
        return live
    }

    private func hasNativeOutputClientsLocked() -> Bool {
        var hasOutputClient = false
        for (key, box) in nativeClients {
            if box.value == nil {
                nativeClients.removeValue(forKey: key)
                continue
            }
            if box.wantsOutput {
                hasOutputClient = true
            }
        }
        return hasOutputClient
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

    var isReusable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == .starting || status == .running
    }

    private func startupEnvironment(cols: UInt16, rows: UInt16) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "meee2"
        env["TERM_PROGRAM_VERSION"] = "internal"
        env["COLUMNS"] = "\(cols)"
        env["LINES"] = "\(rows)"
        env["PWD"] = cwd
        env["MEEE2_SESSION_ID"] = sessionId
        env["MEEE2_SURFACE_ID"] = surfaceId
        env["MEEE2_TERMINAL_KIND"] = "internal"
        if let canvasId { env["MEEE2_CANVAS_ID"] = canvasId }
        if let nodeId { env["MEEE2_NODE_ID"] = nodeId }
        return env
    }

    private static func spawnProcess(
        executable: String,
        arguments: [String],
        environment: [String: String],
        secondaryFD: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }

        let flags = Int16(POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&spawnAttributes, flags)

        var spawnedPid: pid_t = 0
        let environmentPairs = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let secondaryFlags = fcntl(secondaryFD, F_GETFD)
        let stdinAction = posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDIN_FILENO)
        let stdoutAction = posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDOUT_FILENO)
        let stderrAction = posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDERR_FILENO)
        let closeAction: Int32
        if secondaryFD > STDERR_FILENO {
            closeAction = posix_spawn_file_actions_addclose(&fileActions, secondaryFD)
        } else {
            closeAction = 0
        }
        let actionResults = [stdinAction, stdoutAction, stderrAction, closeAction]
        if let failedAction = actionResults.first(where: { $0 != 0 }) {
            throw NSError(
                domain: "InternalTerminalRuntime",
                code: Int(failedAction),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn file action failed: \(String(cString: strerror(failedAction))) secondaryFD=\(secondaryFD) secondaryFlags=\(secondaryFlags) actions=\(actionResults)"]
            )
        }
        let result = withCStringArray(arguments) { argv in
            withCStringArray(environmentPairs) { envp in
                executable.withCString { executablePtr in
                    posix_spawn(&spawnedPid, executablePtr, &fileActions, &spawnAttributes, argv, envp)
                }
            }
        }

        guard result == 0 else {
            throw NSError(
                domain: "InternalTerminalRuntime",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(result))) secondaryFD=\(secondaryFD) secondaryFlags=\(secondaryFlags) actions=\(actionResults)"]
            )
        }
        return spawnedPid
    }

    private static func markHostFileDescriptorsCloseOnExec() {
        let sysMax = Darwin.sysconf(_SC_OPEN_MAX)
        let maxFD = min(max(sysMax > 0 ? Int(sysMax) : 256, 256), 4096)
        guard maxFD > 3 else { return }
        for fd in 3..<maxFD {
            let rawFD = Int32(fd)
            let flags = fcntl(rawFD, F_GETFD)
            guard flags != -1 else { continue }
            _ = fcntl(rawFD, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    private static func setCloseOnExec(_ fd: Int32) {
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFD)
        guard flags != -1 else { return }
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }

    private static func ensureStandardFileDescriptors() {
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where fcntl(fd, F_GETFD) == -1 {
            let flags = fd == STDIN_FILENO ? O_RDONLY : O_WRONLY
            let devNull = Darwin.open("/dev/null", flags)
            guard devNull >= 0 else { continue }
            if devNull != fd {
                dup2(devNull, fd)
                Darwin.close(devNull)
            }
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> Result
    ) rethrows -> Result {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }

    private static func shellQuote(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

import AppKit
import GhosttyTerminal
import meee2Kit

final class GhosttySurfaceBackend: meee2Kit.TerminalSessionBackend {
    static let shared = GhosttySurfaceBackend()

    let kind: TerminalSessionBackendKind = .ghosttySurface

    private let termProgram = "meee2-ghostty-surface"
    private var sessions: [String: GhosttySurfaceSession] = [:]
    private var surfaceBySessionId: [String: String] = [:]
    private var parkingWindow: NSWindow?
    private var parkingView: NSView?

    private init() {}

    func createSession(request: TerminalSessionRequest) throws -> TerminalSessionHandle {
        try runOnMain {
            try createSessionOnMain(request: request)
        }
    }

    func closeSession(id: String) throws {
        try runOnMain {
            guard let session = resolveSession(id: id) else {
                throw TerminalSessionBackendError.sessionNotFound(id)
            }
            session.close()
            remove(session: session)
        }
    }

    func resizeSession(id: String, cols: UInt16, rows: UInt16) {
        try? runOnMain {
            resolveSession(id: id)?.fitToCurrentSize()
            _ = cols
            _ = rows
        }
    }

    func focusSession(id: String) {
        try? runOnMain {
            resolveSession(id: id)?.focus()
        }
    }

    func writeInput(id: String, data: Data) {
        try? runOnMain {
            guard let text = String(data: data, encoding: .utf8) else { return }
            resolveSession(id: id)?.writeInput(text)
        }
    }

    func snapshot(id: String) -> TerminalSessionSnapshot? {
        try? runOnMain {
            resolveSession(id: id)?.snapshot()
        }
    }

    func listSnapshots() -> [TerminalSessionSnapshot] {
        (try? runOnMain {
            sessions.values.map { $0.snapshot() }
        }) ?? []
    }

    func paneController(id: String) -> NativeTerminalPaneControlling? {
        try? runOnMain {
            resolveSession(id: id)
        }
    }

    @MainActor
    private func createSessionOnMain(request: TerminalSessionRequest) throws -> TerminalSessionHandle {
        let startedAt = Date()
        let provider = request.provider == "codex" ? "codex" : "claude"
        let requestedSessionId = request.preferredSessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionId = requestedSessionId.isEmpty ? "\(provider)-ghostty-\(UUID().uuidString)" : requestedSessionId
        if let existingSurfaceId = surfaceBySessionId[sessionId],
           let existing = sessions[existingSurfaceId],
           existing.isReusable {
            return TerminalSessionHandle(snapshot: existing.snapshot())
        }

        let session = try GhosttySurfaceSession(
            provider: provider,
            sessionId: sessionId,
            cwd: request.cwd,
            command: request.command,
            canvasId: request.canvasId,
            nodeId: request.nodeId,
            initialPrompt: request.initialPrompt,
            onExit: { [weak self] surfaceId in
                self?.markExited(surfaceId: surfaceId)
            },
            onStatusChange: { [weak self] surfaceId, event in
                self?.recordStatusChange(surfaceId: surfaceId, event: event)
            }
        )
        sessions[session.surfaceId] = session
        surfaceBySessionId[session.sessionId] = session.surfaceId
        park(session)
        logPerf("create_surface", session: session, startedAt: startedAt)
        TerminalSessionBackendMetadata.recordManagedSession(
            snapshot: session.snapshot(),
            termProgram: termProgram,
            termBundleId: termProgram,
            lastMessage: "Ghostty surface terminal session started"
        )
        return TerminalSessionHandle(snapshot: session.snapshot())
    }

    @MainActor
    private func resolveSession(id: String) -> GhosttySurfaceSession? {
        if let direct = sessions[id] { return direct }
        if let surfaceId = surfaceBySessionId[id] { return sessions[surfaceId] }
        return nil
    }

    @MainActor
    private func markExited(surfaceId: String) {
        guard let session = sessions[surfaceId] else { return }
        session.markExited()
        recordStatusChange(surfaceId: surfaceId, event: "process_exit")
    }

    @MainActor
    private func recordStatusChange(surfaceId: String, event: String) {
        guard let session = sessions[surfaceId] else { return }
        TerminalSessionBackendMetadata.updateManagedSessionStatus(
            snapshot: session.snapshot(),
            termProgram: termProgram,
            termBundleId: termProgram
        )
        BoardServer.shared.broadcastStateChanged()
        MInfo("[TerminalPerf][ghostty-surface] event=\(event) session=\(session.sessionId.prefix(12)) surface=\(session.surfaceId.prefix(12)) status=\(session.lifecycleStatus)")
    }

    @MainActor
    private func remove(session: GhosttySurfaceSession) {
        sessions.removeValue(forKey: session.surfaceId)
        surfaceBySessionId.removeValue(forKey: session.sessionId)
    }

    @MainActor
    private func park(_ session: GhosttySurfaceSession) {
        guard session.paneView.superview == nil else { return }
        let host = parkingHostView()
        session.paneView.frame = host.bounds
        session.paneView.autoresizingMask = [.width, .height]
        host.addSubview(session.paneView)
        session.layout(in: host.bounds, hidden: false, reason: "parking")
    }

    @MainActor
    private func parkingHostView() -> NSView {
        if let parkingView {
            return parkingView
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1200, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.parkingWindow = window
        self.parkingView = host
        return host
    }

    private func runOnMain<T>(_ work: @MainActor () throws -> T) throws -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated {
                try work()
            }
        }
        var result: Result<T, Error>!
        DispatchQueue.main.sync {
            result = Result {
                try MainActor.assumeIsolated {
                    try work()
                }
            }
        }
        return try result.get()
    }

    @MainActor
    private func logPerf(_ event: String, session: GhosttySurfaceSession, startedAt: Date) {
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000
        MInfo(String(format: "[TerminalPerf][ghostty-surface] event=%@ session=%@ surface=%@ elapsed_ms=%.1f",
                     event,
                     String(session.sessionId.prefix(12)),
                     String(session.surfaceId.prefix(12)),
                     elapsedMs))
    }
}

@MainActor
private final class GhosttySurfaceSession: NSObject, NativeTerminalPaneControlling {
    let surfaceId: String
    let sessionId: String
    let provider: String
    let cwd: String
    let command: String
    let canvasId: String?
    let nodeId: String?
    let view: NSView
    var paneView: NSView { view }

    private let terminalView: TerminalView
    private let terminalController: GhosttyTerminal.TerminalController
    private let initialPrompt: String?
    private let onExit: @MainActor (String) -> Void
    private let onStatusChange: @MainActor (String, String) -> Void
    private let createdAt = Date()
    private var updatedAt = Date()
    private var status = InternalTerminalLifecycle.starting.rawValue
    private var didSendCommand = false
    private var didSendInitialPrompt = false
    private var detached = false

    var isReusable: Bool {
        status != InternalTerminalLifecycle.exited.rawValue && status != InternalTerminalLifecycle.failed.rawValue
    }

    var lifecycleStatus: String { status }

    init(
        provider: String,
        sessionId: String,
        cwd: String,
        command: String,
        canvasId: String?,
        nodeId: String?,
        initialPrompt: String?,
        onExit: @escaping @MainActor (String) -> Void,
        onStatusChange: @escaping @MainActor (String, String) -> Void
    ) throws {
        Self.configureGhosttyResourcesIfNeeded()
        self.surfaceId = "ghostty-surface-\(UUID().uuidString)"
        self.sessionId = sessionId
        self.provider = provider
        self.cwd = cwd
        self.command = command
        self.canvasId = canvasId
        self.nodeId = nodeId
        self.initialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onExit = onExit
        self.onStatusChange = onStatusChange
        self.terminalController = Self.makeTerminalController()
        self.terminalView = TerminalView(frame: .zero)
        self.view = terminalView
        super.init()

        terminalView.translatesAutoresizingMaskIntoConstraints = true
        terminalView.autoresizingMask = []
        terminalView.delegate = self
        terminalView.controller = terminalController
        terminalView.configuration = TerminalSurfaceOptions(
            backend: GhosttyTerminal.TerminalSessionBackend.exec,
            workingDirectory: cwd,
            context: .window
        )
    }

    func snapshot() -> TerminalSessionSnapshot {
        TerminalSessionSnapshot(
            sessionId: sessionId,
            surfaceId: surfaceId,
            backend: .ghosttySurface,
            status: status,
            pid: nil,
            cwd: cwd,
            command: command,
            provider: provider,
            canvasId: canvasId,
            nodeId: nodeId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func layout(in frame: NSRect, hidden: Bool) {
        layout(in: frame, hidden: hidden, reason: "workspace")
    }

    func layout(in frame: NSRect, hidden: Bool, reason: String) {
        guard !detached else { return }
        let startedAt = Date()
        terminalView.frame = frame
        terminalView.isHidden = hidden
        terminalView.setSurfaceVisible(!hidden)
        if !hidden {
            fitToCurrentSize()
        }
        logPerf("layout", startedAt: startedAt, extra: "reason=\(reason) hidden=\(hidden)")
    }

    func focus() {
        guard !detached else { return }
        let startedAt = Date()
        terminalView.window?.makeFirstResponder(terminalView)
        terminalView.setSurfaceVisible(true)
        logPerf("focus", startedAt: startedAt)
    }

    func hide() {
        guard !detached else { return }
        terminalView.setSurfaceVisible(false)
        terminalView.isHidden = true
    }

    func detach() {
        guard !detached else { return }
        detached = true
        terminalView.setSurfaceVisible(false)
        terminalView.removeFromSuperview()
    }

    func close() {
        guard !detached else { return }
        if !terminalView.performBindingAction("close_surface") {
            terminalView.sendText("\u{4}")
        }
        markExited()
        detach()
    }

    func writeInput(_ text: String) {
        guard !detached else { return }
        let startedAt = Date()
        terminalView.sendText(text)
        touch()
        logPerf("write_input", startedAt: startedAt, extra: "bytes=\(text.utf8.count)")
    }

    func fitToCurrentSize() {
        guard !detached else { return }
        terminalView.layoutSubtreeIfNeeded()
        terminalView.fitToSize()
    }

    func markExited() {
        status = InternalTerminalLifecycle.exited.rawValue
        touch()
    }

    private func bootstrapIfNeeded() {
        guard !didSendCommand else { return }
        didSendCommand = true
        status = InternalTerminalLifecycle.running.rawValue
        touch()
        onStatusChange(surfaceId, "running")
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldSendLaunchCommand(trimmedCommand) {
            let startedAt = Date()
            terminalView.sendText(trimmedCommand + "\n")
            logPerf("launch_command", startedAt: startedAt, extra: "bytes=\(trimmedCommand.utf8.count)")
        }
        guard let initialPrompt, !initialPrompt.isEmpty, !didSendInitialPrompt else { return }
        didSendInitialPrompt = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.detached else { return }
            self.terminalView.sendText(initialPrompt + "\n")
            self.touch()
        }
    }

    private func shouldSendLaunchCommand(_ command: String) -> Bool {
        guard !command.isEmpty else { return false }
        let lower = command.lowercased()
        return lower != "shell" && lower != "/bin/zsh" && lower != "/bin/bash"
    }

    private func touch() {
        updatedAt = Date()
    }

    private func logPerf(_ event: String, startedAt: Date, extra: String = "") {
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000
        let suffix = extra.isEmpty ? "" : " \(extra)"
        MInfo(String(format: "[TerminalPerf][ghostty-surface] event=%@ session=%@ surface=%@ elapsed_ms=%.1f%@",
                     event,
                     String(sessionId.prefix(12)),
                     String(surfaceId.prefix(12)),
                     elapsedMs,
                     suffix))
    }

    private static func makeTerminalController() -> GhosttyTerminal.TerminalController {
        let embeddedDarkTheme = TerminalConfiguration { builder in
            builder.withBackground("#0b0b0b")
            builder.withForeground("#ebe8de")
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withCursorColor("#ebe8de")
            builder.withSelectionBackground("#4d4d4d")
            builder.withSelectionForeground("#ffffff")
            builder.withFontSize(14)
            builder.withFontThicken(true)
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
        }
        return GhosttyTerminal.TerminalController(
            theme: TerminalTheme(light: embeddedDarkTheme, dark: embeddedDarkTheme)
        )
    }

    private static func configureGhosttyResourcesIfNeeded() {
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else { return }
        let fileManager = FileManager.default
        let candidates = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            Bundle.main.resourceURL?.appendingPathComponent("ghostty").path
        ].compactMap { $0 }
        if let resources = candidates.first(where: { fileManager.fileExists(atPath: $0, isDirectory: nil) }) {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 0)
        }
    }
}

extension GhosttySurfaceSession:
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCommandFinishedDelegate {
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        logPerf("first_attach", startedAt: createdAt)
        bootstrapIfNeeded()
    }

    func terminalDidDetachSurface() {
        markExited()
        onExit(surfaceId)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        _ = size
        touch()
    }

    func terminalDidResize(columns: Int, rows: Int) {
        _ = columns
        _ = rows
        touch()
    }

    func terminalDidClose(processAlive: Bool) {
        _ = processAlive
        markExited()
        onExit(surfaceId)
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        _ = focused
        touch()
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        _ = exitCode
        touch()
        let durationMs = Double(durationNanos) / 1_000_000
        MInfo(String(format: "[TerminalPerf][ghostty-surface] event=command_finished session=%@ surface=%@ duration_ms=%.1f",
                     String(sessionId.prefix(12)),
                     String(surfaceId.prefix(12)),
                     durationMs))
    }
}

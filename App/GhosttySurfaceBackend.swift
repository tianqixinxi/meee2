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

    func deliverPrompt(id: String, text: String) -> PromptDeliveryOutcome {
        (try? runOnMain {
            guard let session = resolveSession(id: id) else {
                return PromptDeliveryOutcome.sessionNotFound
            }
            return session.deliverPrompt(text) ? .delivered : .busy
        }) ?? .sessionNotFound
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
            initialPromptSettleCeiling: request.initialPromptSettleCeiling,
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
        let snap = session.snapshot()
        // DIAGNOSTIC: the exec process (shell hosting the typed launch command)
        // exited — the surface is now dead, so the bound planner node flips to
        // failed and "open session" returns session_ended. Log which session +
        // command so a dispatched-node death is traceable.
        MWarn("[ghostty-surface] process_exit surface=\(surfaceId.prefix(12)) session=\(snap.sessionId.prefix(12)) cwd=\(snap.cwd) cmd=\(snap.command)")
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
    let sessionScope: Meee2SessionScope
    let view: NSView
    var paneView: NSView { view }
    var terminalSurfaceId: String { surfaceId }
    var terminalSessionId: String? { sessionId }

    private let terminalView: TerminalView
    private let terminalController: GhosttyTerminal.TerminalController
    private let initialPrompt: String?
    private let initialPromptSettleCeiling: TimeInterval?
    private let onExit: @MainActor (String) -> Void
    private let onStatusChange: @MainActor (String, String) -> Void
    private let createdAt = Date()
    private var updatedAt = Date()
    private var status = InternalTerminalLifecycle.starting.rawValue
    private var didSendCommand = false
    private var didSendInitialPrompt = false
    /// deliverPrompt 的提交窗口守卫:打字到 Return 落键之间为 true,期间的
    /// 重复投递被拒绝(P2 — 防止两条指令拼进同一个 composer)。
    private var pendingPromptSubmit = false
    private var detached = false
    private var lastLayoutFrame: NSRect = .zero

    // Ready-gated initialPrompt delivery. Ghostty exec surfaces do not expose
    // stdout, so we can't poll PTY bytes; instead we treat any surface signal
    // (grid resize / title / pwd / progress / command-finished) as "the TUI is
    // rendering" and update `lastSurfaceActivityAt`. The poller waits until the
    // surface has produced activity and gone quiet for a settle window, then
    // sends the prompt text and real Return key events separately. A hard
    // ceiling guarantees delivery even if signals never arrive; abort on exit.
    private var lastSurfaceActivityAt: Date?
    private var promptDeliveryStartedAt: Date?

    // BUG A (P1) — when a workspace-trust auto-accept Enter is scheduled, the
    // ready-gated prompt MUST NOT be submitted before that Enter lands, or the
    // prompt gets typed into the trust dialog and lost. `trustAutoAcceptPending`
    // blocks the poller from delivering until `trustAutoAcceptSentAt` is set.
    private var trustAutoAcceptPending = false
    private var trustAutoAcceptSentAt: Date?

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
        initialPromptSettleCeiling: TimeInterval? = nil,
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
        self.sessionScope = Meee2SessionScope.managed(canvasId: canvasId, nodeId: nodeId)
        self.initialPrompt = Self.normalizedPromptForPaste(initialPrompt)
        self.initialPromptSettleCeiling = initialPromptSettleCeiling
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
            sessionScope: sessionScope,
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
        let frameChanged = frame != lastLayoutFrame
        let visibilityChanged = terminalView.isHidden != hidden
        lastLayoutFrame = frame
        if frameChanged {
            terminalView.frame = frame
        }
        if visibilityChanged {
            terminalView.isHidden = hidden
        }
        terminalView.setSurfaceVisible(!hidden)
        if !hidden && (frameChanged || visibilityChanged) {
            fitToCurrentSize()
        }
        logPerf("layout", startedAt: startedAt, extra: "reason=\(reason) hidden=\(hidden) frameChanged=\(frameChanged) visibilityChanged=\(visibilityChanged)")
    }

    func focus() {
        guard !detached else { return }
        let startedAt = Date()
        terminalView.window?.makeFirstResponder(terminalView)
        terminalView.setSurfaceVisible(true)
        fitToCurrentSize()
        logPerf("focus", startedAt: startedAt)
    }

    func applyTheme(_ theme: String) {
        let scheme: TerminalColorScheme = theme == "light" ? .light : .dark
        terminalController.setColorScheme(scheme)
        terminalView.needsDisplay = true
    }

    func stabilizeLayout() {
        fitToCurrentSize()
    }

    func scrollWheel(with event: NSEvent) {
        guard !detached, !terminalView.isHidden else { return }
        terminalView.window?.makeFirstResponder(terminalView)
        terminalView.setSurfaceVisible(true)
        terminalView.scrollWheel(with: event)
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

    /// 打字 + 提交。writeInput 的裸 "\n" 在 agent TUI 的 composer 里是插入
    /// 换行而非提交(实测:artifact sync 复用投递的指令一直躺在输入框里,
    /// 会话纹丝不动);真正的提交是 Return 键。复刻 initial-prompt 投递的
    /// 提交节奏:打字后 400ms 按 Return,150ms 后补一次(首次可能被渲染吞)。
    /// 返回 false = 上一条 prompt 还在提交窗口内(P2:此刻再打字会把两条
    /// 文本拼进同一个 composer,被第一个 Return 当一条畸形请求提交)。
    func deliverPrompt(_ text: String) -> Bool {
        guard !detached, !pendingPromptSubmit else { return false }
        pendingPromptSubmit = true
        let startedAt = Date()
        terminalView.sendText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            guard let self else { return }
            guard !self.detached else {
                self.pendingPromptSubmit = false
                return
            }
            self.pressReturnKey(reason: "deliver_prompt_submit")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
                guard let self else { return }
                self.pendingPromptSubmit = false
                guard !self.detached else { return }
                self.pressReturnKey(reason: "deliver_prompt_submit_retry")
            }
        }
        touch()
        logPerf("deliver_prompt", startedAt: startedAt, extra: "bytes=\(text.utf8.count)")
        return true
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
            let envBootstrap = Self.surfaceEnvironmentBootstrap(surfaceId: surfaceId)
            terminalView.sendText(envBootstrap + trimmedCommand + "\n")
            logPerf("launch_command", startedAt: startedAt, extra: "bytes=\(trimmedCommand.utf8.count)")
            _ = scheduleWorkspaceTrustAutoAcceptIfNeeded(command: trimmedCommand)
        }
        guard let initialPrompt, !initialPrompt.isEmpty else { return }
        scheduleInitialPromptDeliveryWhenReady(initialPrompt)
    }

    /// Record that the surface produced a signal (resize / title / pwd /
    /// progress / command-finished). Drives the ready-gated prompt delivery:
    /// "ready" = produced activity AND quiet for a settle window.
    private func noteSurfaceActivity() {
        lastSurfaceActivityAt = Date()
    }

    /// Submit the dispatched node's initialPrompt once the agent TUI is actually
    /// ready, retrying until then. Replaces the old blind fixed-delay write that
    /// dropped the prompt on a fresh canvas (TUI not yet rendered at 1.2s).
    private func scheduleInitialPromptDeliveryWhenReady(_ rawPrompt: String) {
        guard let prompt = Self.normalizedPromptForPaste(rawPrompt),
              !prompt.isEmpty,
              !didSendInitialPrompt,
              promptDeliveryStartedAt == nil
        else { return }
        promptDeliveryStartedAt = Date()

        // Output (here: surface signals) must be quiet this long before we treat
        // the TUI as "ready". Hard ceiling delivers anyway even if no signal ever
        // arrives.
        let settleWindow: TimeInterval = 0.8
        // 默认 20s 兜底适合 fresh session;大会话 --resume 的加载远超 20s,
        // 调用方(artifact sync 等)可放宽 — settle 在加载安静后自然触发,
        // 上限只防"永远没有活动信号"的极端情况。
        let ceiling: TimeInterval = initialPromptSettleCeiling ?? 20.0
        let firstProbe: DispatchTimeInterval = .milliseconds(700)

        func probe() {
            guard !detached, !didSendInitialPrompt else { return }
            // Surface gone / never started → nothing to deliver into.
            guard isReusable else { return }

            let now = Date()
            let elapsed = promptDeliveryStartedAt.map { now.timeIntervalSince($0) } ?? 0
            let pastCeiling = elapsed >= ceiling
            let hadActivity = lastSurfaceActivityAt != nil
            let quietFor = lastSurfaceActivityAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let settled = hadActivity && quietFor >= settleWindow

            // P1: never submit while a trust auto-accept Enter is still pending —
            // the prompt would land in the trust dialog. Once the Enter has been
            // sent, `trustAutoAcceptSentAt` is set and delivery may proceed (the
            // Enter also refreshed `lastSurfaceActivityAt`, so the settle window
            // now measures quiet time after the dialog was dismissed).
            let trustReady = !trustAutoAcceptPending || trustAutoAcceptSentAt != nil

            if trustReady, settled || pastCeiling {
                didSendInitialPrompt = true
                let startedAt = Date()
                terminalView.sendText(prompt)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
                    guard let self, !self.detached else { return }
                    self.pressReturnKey(reason: "initial_prompt_submit")
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
                        guard let self, !self.detached else { return }
                        self.pressReturnKey(reason: "initial_prompt_submit_retry")
                    }
                }
                touch()
                logPerf("initial_prompt", startedAt: startedAt,
                        extra: "bytes=\(prompt.utf8.count) reason=\(pastCeiling ? "ceiling" : "settled")")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                guard let self, !self.detached else { return }
                MainActor.assumeIsolated { probe() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + firstProbe) { [weak self] in
            guard let self, !self.detached else { return }
            MainActor.assumeIsolated { probe() }
        }
    }

    @discardableResult
    private func scheduleWorkspaceTrustAutoAcceptIfNeeded(command: String) -> Bool {
        guard InternalWorkspaceTrustPromptDetector.shouldProactivelyAutoAccept(
            provider: provider,
            command: command,
            cwd: cwd
        ) else {
            return false
        }

        // Block the prompt poller from delivering until the trust Enter lands —
        // otherwise the prompt is typed into the trust dialog and lost (P1).
        trustAutoAcceptPending = true

        // Ghostty exec surfaces do not expose stdout, so trusted meee2 workspaces get a narrow startup Enter.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1_100)) { [weak self] in
            guard let self, !self.detached else { return }
            let startedAt = Date()
            self.pressReturnKey(reason: "auto_accept_workspace_trust")
            self.touch()
            self.trustAutoAcceptSentAt = Date()
            // The Enter itself counts as surface activity → the poller's settle
            // window now measures quiet time AFTER the trust dialog was dismissed.
            self.noteSurfaceActivity()
            self.logPerf("auto_accept_workspace_trust", startedAt: startedAt, extra: "mode=enter")
        }
        return true
    }

    private func pressReturnKey(reason: String) {
        let startedAt = Date()
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: terminalView.window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            terminalView.sendText("\r")
            logPerf("return_key_fallback", startedAt: startedAt, extra: "reason=\(reason)")
            return
        }
        terminalView.keyDown(with: event)
        logPerf("return_key", startedAt: startedAt, extra: "reason=\(reason)")
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
        let embeddedLightTheme = TerminalConfiguration { builder in
            builder.withBackground("#ffffff")
            builder.withForeground("#1a1c1f")
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withCursorColor("#2563eb")
            builder.withSelectionBackground("#cfe3ff")
            builder.withSelectionForeground("#111827")
            builder.withFontSize(14)
            builder.withFontThicken(true)
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
        }
        let embeddedDarkTheme = TerminalConfiguration { builder in
            builder.withBackground("#101214")
            builder.withForeground("#f4f7fb")
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withCursorColor("#60a5fa")
            builder.withSelectionBackground("#334155")
            builder.withSelectionForeground("#ffffff")
            builder.withFontSize(14)
            builder.withFontThicken(true)
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
        }
        return GhosttyTerminal.TerminalController(
            theme: TerminalTheme(light: embeddedLightTheme, dark: embeddedDarkTheme)
        )
    }

    private static func normalizedPromptForPaste(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        let prompt = lines.joined(separator: "\n")
        return prompt.isEmpty ? nil : prompt
    }

    private static func shellQuote(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func surfaceEnvironmentBootstrap(surfaceId: String) -> String {
        // Keep the surface id in the shell environment for provider hooks, but
        // do not prepend meee2 internals to the visible Codex/Claude command.
        // The leading space avoids shell history in common HISTCONTROL setups.
        " export CMUX_SURFACE_ID=\(shellQuote(surfaceId)); printf '\\033[2J\\033[H'\n"
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
    TerminalSurfaceTitleDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceCommandFinishedDelegate {
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        logPerf("first_attach", startedAt: createdAt)
        // The surface backing store is now live → start the ready-gated prompt
        // poller. Attach itself counts as the first activity signal.
        noteSurfaceActivity()
        bootstrapIfNeeded()
    }

    func terminalDidChangeTitle(_ title: String) {
        _ = title
        noteSurfaceActivity()
        touch()
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        _ = path
        noteSurfaceActivity()
        touch()
    }

    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        _ = state
        _ = percent
        noteSurfaceActivity()
        touch()
    }

    func terminalDidDetachSurface() {
        markExited()
        onExit(surfaceId)
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        _ = size
        noteSurfaceActivity()
        touch()
    }

    func terminalDidResize(columns: Int, rows: Int) {
        _ = columns
        _ = rows
        noteSurfaceActivity()
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
        noteSurfaceActivity()
        touch()
        let durationMs = Double(durationNanos) / 1_000_000
        // DIAGNOSTIC: surface the command exit code (was discarded). For a
        // dispatched node this is the typed launch command's result —
        // exit_code=127 ⇒ command not found (e.g. nvm `claude` not on the
        // exec shell's PATH), 0 ⇒ clean exit, etc. Helps explain "claude
        // produced no transcript / session ended immediately".
        MWarn(String(format: "[TerminalPerf][ghostty-surface] event=command_finished session=%@ surface=%@ exit_code=%@ duration_ms=%.1f cmd=%@",
                     String(sessionId.prefix(12)),
                     String(surfaceId.prefix(12)),
                     exitCode.map { String($0) } ?? "nil",
                     durationMs,
                     command.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

import AppKit
import GhosttyTerminal
import meee2Kit

@MainActor
final class EmbeddedNativeTerminalController: NSObject, InternalTerminalSurfaceClient {
    private static let maxPendingOutputBytes = 64_000

    let surfaceId: String
    let sessionId: String?
    let view: TerminalView

    private let terminalSession: InMemoryTerminalSession
    private let terminalController: GhosttyTerminal.TerminalController
    private let onExit: (String, String?) -> Void
    private var detached = false
    private var lastSyncedSize: (cols: UInt16, rows: UInt16)?
    private var lastLayoutFrame: NSRect = .zero
    private var pendingOutput = Data()
    private var outputFlushScheduled = false
    private var surfaceVisible = false
    private var refitScheduled = false
    private var followUpRefitScheduled = false
    private var terminalSurfaceAttached = false

    init?(surfaceId: String, sessionId: String?, onExit: @escaping (String, String?) -> Void = { _, _ in }) {
        guard Thread.isMainThread else { return nil }

        let resolvedSurfaceId: String
        if !surfaceId.isEmpty {
            resolvedSurfaceId = surfaceId
        } else if let sessionId, let mapped = InternalTerminalRuntime.shared.surfaceId(forSessionId: sessionId) {
            resolvedSurfaceId = mapped
        } else {
            return nil
        }

        guard let snapshot = InternalTerminalRuntime.shared.snapshot(surfaceOrSessionId: resolvedSurfaceId) else {
            return nil
        }

        self.surfaceId = resolvedSurfaceId
        self.sessionId = sessionId ?? snapshot.sessionId

        let terminalSession = InMemoryTerminalSession(
            write: { data in
                _ = InternalTerminalRuntime.shared.writeInputData(surfaceOrSessionId: resolvedSurfaceId, data: data)
            },
            resize: { _ in }
        )
        self.terminalSession = terminalSession
        Self.configureGhosttyResourcesIfNeeded()
        self.terminalController = Self.makeEmbeddedTerminalController()
        self.view = TerminalView(frame: .zero)
        self.onExit = onExit

        super.init()

        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        view.delegate = self
        view.controller = terminalController
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(terminalSession),
            workingDirectory: snapshot.cwd,
            context: .window
        )

        _ = InternalTerminalRuntime.shared.addClient(
            self,
            surfaceOrSessionId: resolvedSurfaceId,
            replay: true,
            wantsOutput: true
        )
    }

    func detach() {
        guard !detached else { return }
        detached = true
        flushPendingOutput()
        InternalTerminalRuntime.shared.removeClient(self, surfaceOrSessionId: surfaceId)
        setTerminalSurfaceVisible(false)
        view.removeFromSuperview()
    }

    func hide() {
        guard !detached else { return }
        flushPendingOutput()
        deactivateOutput()
        view.isHidden = true
    }

    func matches(surfaceId rawSurfaceId: String, sessionId rawSessionId: String?) -> Bool {
        if !rawSurfaceId.isEmpty, rawSurfaceId == surfaceId { return true }
        if let rawSessionId, !rawSessionId.isEmpty, rawSessionId == sessionId { return true }
        return false
    }

    func focus() {
        guard !detached, !view.isHidden else { return }
        view.window?.makeFirstResponder(view)
        setTerminalSurfaceVisible(true)
    }

    func layout(in frame: NSRect, hidden: Bool) {
        let frameChanged = frame != lastLayoutFrame
        let visibilityChanged = view.isHidden != hidden
        lastLayoutFrame = frame
        if frameChanged {
            view.frame = frame
        }
        if visibilityChanged {
            view.isHidden = hidden
        }
        guard !hidden else {
            flushPendingOutput()
            deactivateOutput()
            return
        }
        setTerminalSurfaceVisible(true)
        if frameChanged || visibilityChanged {
            scheduleRefit()
        }
    }

    func internalTerminalSurface(_ surfaceId: String, didReplayOutput data: Data) {
        enqueueOutput(data, includeFollowUpRefit: true)
    }

    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput data: Data) {
        enqueueOutput(data)
    }

    func internalTerminalSurface(_ surfaceId: String, didExitWithCode code: Int) {
        flushPendingOutput()
        terminalSession.finish(exitCode: UInt32(max(0, code)), runtimeMilliseconds: 0)
        onExit(self.surfaceId, sessionId)
    }

    private static func makeEmbeddedTerminalController() -> GhosttyTerminal.TerminalController {
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

    nonisolated private static func clamped(_ value: UInt16, lower: UInt16, upper: UInt16) -> UInt16 {
        min(max(value, lower), upper)
    }

    private func refitSurface() {
        guard !detached, !view.isHidden else { return }
        view.layoutSubtreeIfNeeded()
        view.fitToSize()
    }

    private func setTerminalSurfaceVisible(_ visible: Bool) {
        guard surfaceVisible != visible else { return }
        surfaceVisible = visible
        view.setSurfaceVisible(visible)
    }

    private func enqueueOutput(_ data: Data, includeFollowUpRefit: Bool = false) {
        guard !detached, !data.isEmpty else { return }
        pendingOutput.append(data)
        if pendingOutput.count >= Self.maxPendingOutputBytes {
            flushPendingOutput(includeFollowUpRefit: includeFollowUpRefit)
            return
        }
        guard !outputFlushScheduled else { return }
        outputFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingOutput(includeFollowUpRefit: includeFollowUpRefit)
        }
    }

    private func flushPendingOutput(includeFollowUpRefit: Bool = false) {
        outputFlushScheduled = false
        guard terminalSurfaceAttached, !pendingOutput.isEmpty else { return }
        let data = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        terminalSession.receive(data)
        scheduleRefit(includeFollowUp: includeFollowUpRefit)
    }

    private func deactivateOutput() {
        guard !detached else { return }
        setTerminalSurfaceVisible(false)
    }

    private func scheduleRefit(includeFollowUp: Bool = false) {
        if !refitScheduled {
            refitScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refitScheduled = false
                self.refitSurface()
            }
        }

        guard includeFollowUp, !followUpRefitScheduled else { return }
        followUpRefitScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            self.followUpRefitScheduled = false
            self.scheduleRefit()
        }
    }

    private func syncPtySize(columns: UInt16, rows: UInt16, force: Bool = false) {
        let cols = Self.clamped(columns, lower: 20, upper: 500)
        let rows = Self.clamped(rows, lower: 8, upper: 200)
        if !force, let lastSyncedSize, lastSyncedSize.cols == cols, lastSyncedSize.rows == rows {
            return
        }
        lastSyncedSize = (cols, rows)
        _ = InternalTerminalRuntime.shared.resize(surfaceOrSessionId: surfaceId, cols: cols, rows: rows)
    }
}

extension EmbeddedNativeTerminalController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate {
    func terminalDidChangeTitle(_ title: String) {}

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        terminalSurfaceAttached = true
        flushPendingOutput(includeFollowUpRefit: true)
    }

    func terminalDidDetachSurface() {
        terminalSurfaceAttached = false
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        syncPtySize(columns: size.columns, rows: size.rows)
    }

    func terminalDidResize(columns: Int, rows: Int) {
        syncPtySize(
            columns: UInt16(max(20, min(500, columns))),
            rows: UInt16(max(8, min(200, rows)))
        )
    }

    func terminalDidClose(processAlive: Bool) {
        if processAlive {
            _ = InternalTerminalRuntime.shared.close(surfaceOrSessionId: surfaceId)
        }
    }

    func terminalDidChangeFocus(_ focused: Bool) {
        setTerminalSurfaceVisible(!view.isHidden && (focused || view.window != nil))
    }
}

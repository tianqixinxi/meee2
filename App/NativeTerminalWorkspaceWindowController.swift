import AppKit
import GhosttyTerminal
import meee2Kit

@MainActor
final class EmbeddedNativeTerminalController: NSObject, InternalTerminalSurfaceClient {
    let surfaceId: String
    let sessionId: String?
    let view: TerminalView

    private let terminalSession: InMemoryTerminalSession
    private let terminalController: GhosttyTerminal.TerminalController
    private var detached = false
    private var lastSyncedSize: (cols: UInt16, rows: UInt16)?
    private var lastLayoutFrame: NSRect = .zero

    init?(surfaceId: String, sessionId: String?) {
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
            resize: { viewport in
                let cols = Self.clamped(viewport.columns, lower: 20, upper: 500)
                let rows = Self.clamped(viewport.rows, lower: 8, upper: 200)
                _ = InternalTerminalRuntime.shared.resize(surfaceOrSessionId: resolvedSurfaceId, cols: cols, rows: rows)
            }
        )
        self.terminalSession = terminalSession
        Self.configureGhosttyResourcesIfNeeded()
        self.terminalController = GhosttyTerminal.TerminalController(configFilePath: Self.ghosttyConfigPath())
        self.view = TerminalView(frame: .zero)

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

        _ = InternalTerminalRuntime.shared.addClient(self, surfaceOrSessionId: resolvedSurfaceId)
    }

    func detach() {
        guard !detached else { return }
        detached = true
        InternalTerminalRuntime.shared.removeClient(self, surfaceOrSessionId: surfaceId)
        view.setSurfaceVisible(false)
        view.removeFromSuperview()
    }

    func hide() {
        guard !detached else { return }
        view.setSurfaceVisible(false)
        view.isHidden = true
    }

    func matches(surfaceId rawSurfaceId: String, sessionId rawSessionId: String?) -> Bool {
        if !rawSurfaceId.isEmpty, rawSurfaceId == surfaceId { return true }
        if let rawSessionId, !rawSessionId.isEmpty, rawSessionId == sessionId { return true }
        return false
    }

    func focus() {
        view.window?.makeFirstResponder(view)
        view.setSurfaceVisible(true)
        refitSurface()
    }

    func layout(in frame: NSRect, hidden: Bool) {
        let frameChanged = frame != lastLayoutFrame
        lastLayoutFrame = frame
        view.frame = frame
        view.isHidden = hidden
        guard !hidden else { return }
        view.setSurfaceVisible(true)
        if frameChanged {
            refitSurface()
        }
    }

    func internalTerminalSurface(_ surfaceId: String, didReplayOutput data: Data) {
        refitSurface()
        terminalSession.receive(data)
        scheduleRefit()
    }

    func internalTerminalSurface(_ surfaceId: String, didReceiveOutput data: Data) {
        terminalSession.receive(data)
    }

    func internalTerminalSurface(_ surfaceId: String, didExitWithCode code: Int) {
        terminalSession.finish(exitCode: UInt32(max(0, code)), runtimeMilliseconds: 0)
    }

    private static func ghosttyConfigPath() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config.ghostty").path,
            home.appendingPathComponent(".config/ghostty/config").path,
        ]
        return candidates.first { fileManager.fileExists(atPath: $0) }
    }

    private static func configureGhosttyResourcesIfNeeded() {
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else { return }
        let fileManager = FileManager.default
        let candidates = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
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

    private func scheduleRefit() {
        Task { @MainActor [weak self] in
            self?.refitSurface()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.refitSurface()
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
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceFocusDelegate
{
    func terminalDidChangeTitle(_ title: String) {}

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
        view.setSurfaceVisible(focused || view.window != nil)
    }
}

import AppKit
import meee2Kit

@MainActor
enum NativeTerminalSurfaceCoordinator {
    static func controller(for surface: TerminalSessionSnapshot) -> NativeTerminalPaneControlling? {
        switch surface.backend {
        case .ghosttySurface:
            return controller(surfaceId: surface.surfaceId, sessionId: surface.sessionId)
        case .external:
            return nil
        }
    }

    static func controller(surfaceId: String, sessionId: String?) -> NativeTerminalPaneControlling? {
        let trimmedSurfaceId = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSurfaceId.isEmpty,
           let controller = GhosttySurfaceBackend.shared.paneController(id: trimmedSurfaceId) {
            return controller
        }
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else { return nil }
        return GhosttySurfaceBackend.shared.paneController(id: sessionId)
    }

    static func host(
        _ controller: NativeTerminalPaneControlling,
        in hostView: NSView,
        frame: NSRect,
        hidden: Bool,
        autoresizingMask: NSView.AutoresizingMask
    ) {
        let view = controller.paneView
        if view.superview !== hostView {
            view.removeFromSuperview()
            view.frame = frame
            view.autoresizingMask = autoresizingMask
            hostView.addSubview(view)
        } else if hostView.subviews.last !== view {
            view.removeFromSuperview()
            hostView.addSubview(view)
        }
        controller.layout(in: frame, hidden: hidden)
    }

    static func releaseFromHost(_ controller: NativeTerminalPaneControlling) {
        controller.releaseFromHost()
    }
}

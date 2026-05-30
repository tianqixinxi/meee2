import Cocoa
import Combine
import SwiftUI

// MARK: - Session Palette Manager

/// Session Palette 窗口生命周期管理器
/// 负责创建、显示、隐藏 palette 窗口，以及注册应用内快捷键
@MainActor
public final class SessionPaletteManager: ObservableObject {
    public static let shared = SessionPaletteManager()

    @Published public var isVisible: Bool = false

    private var paletteWindow: SessionPaletteWindow?
    private var hotKeyMonitor: Any?

    // 搜索状态
    public let searchEngine = SessionPaletteSearchEngine()

    private init() {}

    // MARK: - Lifecycle

    /// 显示 palette 窗口
    public func show() {
        if paletteWindow == nil {
            let window = SessionPaletteWindow()
            window.onDidHide = { [weak self] in
                self?.isVisible = false
            }
            paletteWindow = window
        }

        guard let window = paletteWindow else { return }

        // 定位到屏幕中央偏上
        if let screen = NSScreen.main {
            let width: CGFloat = 680
            let height: CGFloat = 420
            let x = screen.frame.midX - width / 2
            let y = screen.frame.maxY - 200 - height
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: true)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    /// 隐藏 palette 窗口
    public func hide() {
        paletteWindow?.orderOut(nil)
        isVisible = false
    }

    /// 切换显示状态
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// 注册应用内快捷键 (Cmd+Shift+P)。菜单项也绑定同一个 selector。
    public func registerHotKey() {
        guard hotKeyMonitor == nil else { return }
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 35 {
                // 35 = 'P' key
                self?.toggle()
                return nil
            }
            return event
        }
    }

    // MARK: - Session selection

    /// 选择并跳转到某个 session
    public func selectAndJump(to entry: SessionPaletteEntry) {
        hide()
        selectOnBoard(sessionId: entry.sessionId, surfaceId: entry.surfaceId)
    }

    private func selectOnBoard(sessionId: String, surfaceId: String?) {
        // 复用 AppDelegate → BoardWebWindowController 的 session 深链入口。
        var userInfo: [String: Any] = ["sessionId": sessionId]
        if let surfaceId, !surfaceId.isEmpty {
            userInfo["surfaceId"] = surfaceId
        }
        NotificationCenter.default.post(
            name: Notification.Name("meee2.openBoardSession"),
            object: nil,
            userInfo: userInfo
        )
    }

}

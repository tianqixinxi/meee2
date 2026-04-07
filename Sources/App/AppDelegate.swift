import SwiftUI
import PeerIslandKit

/// AppDelegate - 管理 macOS 特有的窗口和状态栏
public class AppDelegate: NSObject, NSApplicationDelegate {
    /// 状态栏图标
    private var statusItem: NSStatusItem?

    /// 灵动岛窗口
    private var islandWindow: DynamicIslandWindow?

    /// 设置窗口
    private var settingsWindow: NSWindow?

    /// 会话协调器 (新架构)
    private let coordinator = SessionCoordinator()

    /// 刘海尺寸 (检测到的实际刘海大小)
    private var deviceNotchSize: CGSize = .zero

    /// 默认灵动岛尺寸 (无刘海时使用)
    private let defaultIslandSize = CGSize(width: 150, height: 32)

    /// 窗口固定高度（需要足够容纳展开状态，SwiftUI 内部管理可见区域）
    private let windowHeight: CGFloat = 700

    /// 用户选择的屏幕 ID
    @AppStorage("selectedScreenId") private var selectedScreenId: String = "builtin"

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置为 accessory 应用 (不显示在 Dock，只有状态栏)
        NSApp.setActivationPolicy(.accessory)

        // 创建状态栏图标
        setupStatusBar()

        // 创建灵动岛窗口
        setupIslandWindow()

        // 启动新架构：PluginRegistry → SessionCoordinator
        coordinator.start()

        // 监听屏幕变化 (处理多显示器)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 监听用户屏幕选择变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenSelectionDidChange),
            name: .screenSelectionChanged,
            object: nil
        )
    }

    public func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 设置初始图标
        updateStatusBarIcon(hasActiveSessions: false)

        // 设置菜单
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(statusBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 监听 sessions 变化来更新图标
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionsDidChange),
            name: NSNotification.Name("SessionsDidChange"),
            object: nil
        )
    }

    private func updateStatusBarIcon(hasActiveSessions: Bool) {
        let iconName = hasActiveSessions ? "brain.filled.head.profile" : "brain.head.profile"
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Peer Island")
            button.image?.isTemplate = true
        }
    }

    @objc private func sessionsDidChange() {
        let hasSessions = !coordinator.sessions.isEmpty
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusBarIcon(hasActiveSessions: hasSessions)
        }
    }

    @objc private func openIsland() {
        if islandWindow == nil {
            setupIslandWindow()
        }
        islandWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func statusBarClicked() {
        openIsland()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createSettingsWindow() {
        let contentView = NSHostingView(rootView: SettingsView())
        contentView.frame = NSRect(x: 0, y: 0, width: 520, height: 450)

        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "Peer Island Settings"
        settingsWindow?.contentView = contentView
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Screen Selection

    private func getSelectedScreen() -> NSScreen? {
        if selectedScreenId == "builtin" {
            return NSScreen.builtin ?? NSScreen.main
        }
        if let screen = NSScreen.byId(selectedScreenId) {
            return screen
        }
        return NSScreen.builtin ?? NSScreen.main
    }

    @objc private func screenSelectionDidChange() {
        setupIslandWindow()
        positionIslandWindow()
    }

    // MARK: - Island Window

    private func setupIslandWindow() {
        guard let screen = getSelectedScreen() else { return }

        deviceNotchSize = screen.notchSize

        if deviceNotchSize == .zero {
            deviceNotchSize = defaultIslandSize
        }

        coordinator.notchSize = deviceNotchSize

        let windowWidth = max(deviceNotchSize.width, 500)
        let windowHeight = windowHeight

        if islandWindow == nil {
            islandWindow = DynamicIslandWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            let contentView = NSHostingView(rootView: IslandView(coordinator: coordinator))
            contentView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
            islandWindow?.contentView = contentView
        }

        positionIslandWindow()

        islandWindow?.makeKeyAndOrderFront(nil)
        islandWindow?.orderFrontRegardless()
    }

    private func positionIslandWindow() {
        guard let window = islandWindow,
              let screen = getSelectedScreen() else { return }

        let screenFrame = screen.frame
        let windowWidth = max(deviceNotchSize.width, 500)
        let windowHeight = windowHeight

        let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let y = screenFrame.origin.y + screenFrame.height - windowHeight

        let newFrame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
        window.setFrame(newFrame, display: true)
    }

    @objc private func screenParametersDidChange() {
        if let screen = getSelectedScreen() {
            let newNotchSize = screen.notchSize
            if newNotchSize != deviceNotchSize && newNotchSize != .zero {
                deviceNotchSize = newNotchSize
            }
        }
        positionIslandWindow()
    }
}

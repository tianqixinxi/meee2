import SwiftUI
import meee2Kit
import Meee2PluginKit

/// AppDelegate - 管理 macOS 特有的窗口和状态栏
public class AppDelegate: NSObject, NSApplicationDelegate {
    /// 状态栏图标
    private var statusItem: NSStatusItem?

    /// 灵动岛窗口
    private var islandWindow: DynamicIslandWindow?

    /// 设置窗口
    private var settingsWindow: NSWindow?

    /// Board 窗口控制器 (static 强引用，防止被释放)

    /// 状态管理器
    private let statusManager = StatusManager()

    /// 刘海尺寸 (检测到的实际刘海大小)
    private var deviceNotchSize: CGSize = .zero

    /// 默认灵动岛尺寸 (无刘海时使用)
    private let defaultIslandSize = CGSize(width: 150, height: 32)

    /// 展开后的灵动岛最大高度（匹配 IslandView.expandedMaxHeight）
    private let expandedHeight: CGFloat = 700

    /// 用户选择的屏幕 ID
    @AppStorage("selectedScreenId") private var selectedScreenId: String = "builtin"

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化日志管理器
        _ = LogManager.shared

        // 设置为 accessory 应用 (不显示在 Dock，只有状态栏)
        NSApp.setActivationPolicy(.accessory)

        // 创建状态栏图标
        setupStatusBar()

        // 创建灵动岛窗口
        setupIslandWindow()

        // 确保 Claude CLI hooks 配置存在
        SettingsConfigManager.shared.ensureHooksConfigured()

        // 自动在 `~/.claude.json` 注册 meee2 MCP server，让每个 Claude session
        // 原生拿到 send_message / list_channels / read_inbox / list_sessions tool。
        // 幂等：已注册且路径正确就 noop。
        MCPConfigManager.shared.ensureRegistered()

        // 把 host 实现注入 plugin-kit 的 A2AContext，**必须**在 plugin 加载之前。
        // Plugin 的 init/start 阶段（甚至 SessionPlugin 构造期间）就可能调
        // A2AContext.shared.* —— 如果 register 在 plugin 加载之后，那时 provider
        // 还是 nil，所有查询返回 fallback（空数组 / nil），plugin 自治逻辑被静默废掉。
        Meee2PluginKit.A2AContext.shared.register(A2AContextHostProvider())

        // 加载外部 plugins
        PluginManager.shared.loadExternalPlugins()

        // SessionStore 已经从 disk 载入。用 Ghostty PR #11922 提供的
        // tty AppleScript 属性反查每个 session 真正所在的 Ghostty terminal id，
        // 修正历史上 "focused terminal" 启发式造成的撞车 / 错配。
        // 在后台跑：osascript 可能 100-200ms，不阻塞 UI。
        DispatchQueue.global(qos: .utility).async {
            _ = GhosttyTerminalRegistry.reconcileSessionStore()
        }

        // 启动状态监控
        statusManager.start()

        // 自动启动 Board HTTP/WS 服务器 —— 开发工具，一直监听 9876。
        // 之前只在点击菜单 Open Board 时启动，导致浏览器直接访问 localhost:9876
        // 连不上。
        do {
            try BoardServer.shared.start()
            NSLog("[AppDelegate] BoardServer listening on \(BoardServer.shared.url)")
        } catch {
            NSLog("[AppDelegate] BoardServer failed to start: \(error)")
        }

        // 发送使用统计（异步，不阻塞启动）
        UsageTracker.shared.trackLaunch()

        // 启动 meee360 推送器（如果已连接且在线）
        Meee360Pusher.shared.activate()

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
        statusManager.stop()
        Meee360Pusher.shared.deactivate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 设置初始图标（无 session）
        updateStatusBarIcon(hasActiveSessions: false)

        // 设置菜单（简化版：只有 Settings 和 Quit）
        let menu = NSMenu()
        let tuiItem = NSMenuItem(title: "TUI", action: #selector(openTUI), keyEquivalent: "t")
        tuiItem.target = self
        menu.addItem(tuiItem)
        let boardItem = NSMenuItem(title: "Open Board", action: #selector(openBoardMenu), keyEquivalent: "b")
        boardItem.target = self
        menu.addItem(boardItem)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        // 点击图标时打开 Island（菜单通过右键或长按触发）
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

        // 监听打开设置窗口的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: NSNotification.Name("openSettings"),
            object: nil
        )

        // 监听打开 TUI 的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openTUI),
            name: NSNotification.Name("openTUI"),
            object: nil
        )

        // 监听打开 Board 的通知（来自灵动岛右上角菜单）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openBoardMenu),
            name: NSNotification.Name("openBoard"),
            object: nil
        )
    }

    private func updateStatusBarIcon(hasActiveSessions: Bool) {
        let iconName = hasActiveSessions ? "brain.filled.head.profile" : "brain.head.profile"
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "meee2")
            button.image?.isTemplate = true
        }
    }

    @objc private func sessionsDidChange() {
        let hasSessions = !statusManager.sessions.isEmpty
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

    /// 点击状态栏图标
    @objc private func statusBarClicked() {
        // 左键点击：打开 Island
        openIsland()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openBoardMenu() {
        if !BoardServer.shared.isRunning {
            do {
                try BoardServer.shared.start()
            } catch {
                NSLog("[AppDelegate] failed to start board server: \(error)")
                let alert = NSAlert()
                alert.messageText = "Failed to start Board server"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        }
        _ = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [BoardServer.shared.url]
        )
    }

    @objc private func openTUI() {
        NSLog("[AppDelegate] openTUI called")

        // 捕获主线程需要的值
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // 所有 AppleScript 操作放到后台线程，避免阻塞 GUI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 检查 CLI 是否已安装
            let cliPath = "/usr/local/bin/meee2"
            let expectedTarget = "/Applications/meee2.app/Contents/MacOS/meee2"

            var needsInstall = false
            if !FileManager.default.fileExists(atPath: cliPath) {
                NSLog("[AppDelegate] CLI not found at \(cliPath)")
                needsInstall = true
            } else if let linkDest = try? FileManager.default.destinationOfSymbolicLink(atPath: cliPath),
                      linkDest != expectedTarget {
                NSLog("[AppDelegate] CLI symlink points to \(linkDest), expected \(expectedTarget)")
                needsInstall = true
            } else {
                NSLog("[AppDelegate] CLI already installed correctly")
            }

            if needsInstall {
                NSLog("[AppDelegate] Attempting to install CLI...")
                let installScript = """
                do shell script "ln -sf \(expectedTarget) \(cliPath)" with administrator privileges
                """

                if let appleScript = NSAppleScript(source: installScript) {
                    var error: NSDictionary?
                    appleScript.executeAndReturnError(&error)
                    if let error = error {
                        NSLog("[AppDelegate] CLI install error: \(error)")
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "CLI Installation Required"
                            alert.informativeText = "To use TUI, meee2 CLI needs to be installed to /usr/local/bin/. Please authorize the installation."
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                        return
                    }
                    NSLog("[AppDelegate] CLI installed successfully")
                }
            }

            // 在后台线程启动 TUI
            NSLog("[AppDelegate] Launching TUI...")
            self.launchTUIAsync(frontmostApp: frontmostApp)
        }
    }

    /// 在后台线程启动 TUI（frontmostApp 已在主线程捕获）
    private func launchTUIAsync(frontmostApp: String) {
        NSLog("[AppDelegate] Frontmost app: \(frontmostApp)")

        switch frontmostApp {
        case "com.mitchellh.ghostty":
            launchTUIInGhostty()
        case "com.googlecode.iterm2":
            launchTUIIniTerm2()
        case "com.apple.Terminal":
            launchTUIInTerminal()
        default:
            launchTUIInTerminal()
        }
    }

    // MARK: - TUI Launch

    /// 解析 meee2 二进制文件路径（开发时用 .build/debug/，打包后用 app bundle）
    private var meee2BinaryPath: String {
        // 1. 优先使用 bundle 内的可执行文件（生产环境）
        if let bundlePath = Bundle.main.executablePath,
           FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }
        // 2. /usr/local/bin/meee2 (CLI symlink)
        let cliPath = "/usr/local/bin/meee2"
        if FileManager.default.fileExists(atPath: cliPath) {
            return cliPath
        }
        // 3. 最后尝试 PATH 中的 meee2
        return "meee2"
    }

    private func launchTUIInGhostty() {
        // Ghostty 使用 ghostty 命令打开新窗口
        // 检查 Ghostty 是否安装
        let ghosttyPath = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
        guard FileManager.default.fileExists(atPath: ghosttyPath) else {
            NSLog("[AppDelegate] Ghostty not found at \(ghosttyPath), falling back to Terminal")
            launchTUIInTerminal()
            return
        }

        let binaryPath = meee2BinaryPath
        let script = """
        tell application "Ghostty"
            activate
        end tell
        do shell script "\(ghosttyPath) -e \(binaryPath) tui &"
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[AppDelegate] Ghostty launch error: \(error), falling back to Terminal")
                launchTUIInTerminal()
            } else {
                NSLog("[AppDelegate] TUI launched in Ghostty")
            }
        } else {
            NSLog("[AppDelegate] Failed to create AppleScript for Ghostty, falling back to Terminal")
            launchTUIInTerminal()
        }
    }

    private func launchTUIIniTerm2() {
        // 检查 iTerm2 是否安装
        guard FileManager.default.fileExists(atPath: "/Applications/iTerm.app") ||
              FileManager.default.fileExists(atPath: "/Applications/iTerm2.app") else {
            NSLog("[AppDelegate] iTerm2 not found, falling back to Terminal")
            launchTUIInTerminal()
            return
        }

        let binaryPath = meee2BinaryPath
        let script = """
        tell application "iTerm2"
            activate
            tell current window
                create tab with default profile
                tell current session
                    write text "\(binaryPath) tui"
                end tell
            end tell
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[AppDelegate] iTerm2 launch error: \(error), falling back to Terminal")
                launchTUIInTerminal()
            } else {
                NSLog("[AppDelegate] TUI launched in iTerm2")
            }
        } else {
            NSLog("[AppDelegate] Failed to create AppleScript for iTerm2, falling back to Terminal")
            launchTUIInTerminal()
        }
    }

    private func launchTUIInTerminal() {
        let binaryPath = meee2BinaryPath
        let script = """
        tell application "Terminal"
            activate
            do script "\(binaryPath) tui"
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[AppDelegate] Terminal launch error: \(error)")
                // 显示错误提示
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Launch TUI"
                    alert.informativeText = "Could not open Terminal. Error: \(error[NSAppleScript.errorMessage] ?? "Unknown error")"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } else {
                NSLog("[AppDelegate] TUI launched in Terminal")
            }
        } else {
            NSLog("[AppDelegate] Failed to create AppleScript for Terminal")
        }
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
        settingsWindow?.title = "meee2 Settings"
        settingsWindow?.contentView = contentView
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Screen Selection

    /// 获取用户选择的屏幕
    private func getSelectedScreen() -> NSScreen? {
        // 如果选择 builtin，返回内置显示器
        if selectedScreenId == "builtin" {
            return NSScreen.builtin ?? NSScreen.main
        }

        // 根据 ID 查找屏幕
        if let screen = NSScreen.byId(selectedScreenId) {
            return screen
        }

        // 找不到则 fallback 到内置显示器或主屏幕
        return NSScreen.builtin ?? NSScreen.main
    }

    @objc private func screenSelectionDidChange() {
        // 用户更改屏幕选择，重新定位窗口
        setupIslandWindow()
        positionIslandWindow()
    }

    // MARK: - Island Window

    private func setupIslandWindow() {
        // 获取用户选择的屏幕
        guard let screen = getSelectedScreen() else { return }

        // 检测刘海尺寸
        deviceNotchSize = screen.notchSize

        // 调试输出
        print("Screen: \(screen.displayName)")
        print("Screen frame: \(screen.frame)")
        print("Screen safeAreaInsets: \(screen.safeAreaInsets)")
        print("Detected notch size: \(deviceNotchSize)")

        // 如果没有刘海，使用默认尺寸
        if deviceNotchSize == .zero {
            deviceNotchSize = defaultIslandSize
            print("No notch detected, using default size: \(deviceNotchSize)")
        }

        // 更新 StatusManager 中的刘海尺寸
        statusManager.notchSize = deviceNotchSize

        // 窗口尺寸：宽度使用刘海宽度，高度使用展开后的高度
        // 窗口会覆盖整个可能展开的区域
        let windowWidth = max(deviceNotchSize.width, 500)  // 至少 500 宽，容纳展开内容
        let windowHeight = expandedHeight

        // 如果窗口已存在，只更新位置
        if islandWindow == nil {
            // 创建自定义窗口
            islandWindow = DynamicIslandWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            // 设置 SwiftUI 内容
            let hostingView = NSHostingView(rootView: IslandView(statusManager: statusManager))
            hostingView.sizingOptions = []  // 禁用自动调整窗口大小，防止约束循环
            hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
            hostingView.autoresizingMask = [.width, .height]
            islandWindow?.contentView = hostingView
        }

        // 定位窗口
        positionIslandWindow()

        // 显示窗口
        islandWindow?.makeKeyAndOrderFront(nil)
        islandWindow?.orderFrontRegardless()  // 强制显示
        NSLog("[AppDelegate] Window frame: \(islandWindow?.frame ?? .zero)")
        NSLog("[AppDelegate] Window visible: \(islandWindow?.isVisible ?? false)")
        NSLog("[AppDelegate] Window level: \(islandWindow?.level.rawValue ?? -1)")
    }

    private func positionIslandWindow() {
        guard let window = islandWindow,
              let screen = getSelectedScreen() else {
            NSLog("[AppDelegate] positionIslandWindow: no window or screen")
            return
        }

        let screenFrame = screen.frame
        NSLog("[AppDelegate] Screen frame: \(screenFrame)")
        NSLog("[AppDelegate] Screen: \(screen.displayName)")

        // 窗口尺寸
        let windowWidth = max(deviceNotchSize.width, 500)
        let windowHeight = expandedHeight

        // 计算位置：屏幕顶部中央，窗口顶部和屏幕顶部齐平
        // macOS 坐标系：左下角是 (0,0)，Y 轴向上
        let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let y = screenFrame.origin.y + screenFrame.height - windowHeight

        let newFrame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
        window.setFrame(newFrame, display: true)
        NSLog("[AppDelegate] Window positioned at: (\(x), \(y)), size: \(windowWidth)x\(windowHeight)")
        NSLog("[AppDelegate] Window frame after: \(window.frame)")
    }

    @objc private func screenParametersDidChange() {
        // 屏幕参数变化时重新检测刘海并定位窗口
        if let screen = getSelectedScreen() {
            let newNotchSize = screen.notchSize
            if newNotchSize != deviceNotchSize && newNotchSize != .zero {
                deviceNotchSize = newNotchSize
            }
        }
        positionIslandWindow()
    }
}

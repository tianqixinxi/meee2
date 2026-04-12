import SwiftUI
import meee2Kit

/// AppDelegate - 管理 macOS 特有的窗口和状态栏
public class AppDelegate: NSObject, NSApplicationDelegate {
    /// 状态栏图标
    private var statusItem: NSStatusItem?

    /// 灵动岛窗口
    private var islandWindow: DynamicIslandWindow?

    /// 设置窗口
    private var settingsWindow: NSWindow?

    /// 状态管理器
    private let statusManager = StatusManager()

    /// 刘海尺寸 (检测到的实际刘海大小)
    private var deviceNotchSize: CGSize = .zero

    /// 默认灵动岛尺寸 (无刘海时使用)
    private let defaultIslandSize = CGSize(width: 150, height: 32)

    /// 展开后的灵动岛高度
    private let expandedHeight: CGFloat = 200

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

        // 加载外部 plugins
        PluginManager.shared.loadExternalPlugins()

        // 启动状态监控
        statusManager.start()

        // 发送使用统计（异步，不阻塞启动）
        UsageTracker.shared.trackLaunch()

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

    @objc private func openTUI() {
        NSLog("[AppDelegate] openTUI called")

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
            // 使用 AppleScript 执行 sudo 安装（会弹出授权提示）
            let installScript = """
            do shell script "ln -sf \(expectedTarget) \(cliPath)" with administrator privileges
            """

            if let appleScript = NSAppleScript(source: installScript) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    NSLog("[AppDelegate] CLI install error: \(error)")
                    // 用户取消授权或其他错误
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

        // 检测用户正在使用的终端并在其中运行 TUI
        NSLog("[AppDelegate] Launching TUI...")
        launchTUI()
    }

    /// 检测并启动 TUI 到用户正在使用的终端
    private func launchTUI() {
        // 检测最前面的应用是否是终端
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        NSLog("[AppDelegate] Frontmost app: \(frontmostApp)")

        // 根据终端类型选择启动方式
        switch frontmostApp {
        case "com.mitchellh.ghostty":
            // Ghostty
            launchTUIInGhostty()
        case "com.googlecode.iterm2":
            // iTerm2
            launchTUIIniTerm2()
        case "com.apple.Terminal":
            // Terminal.app
            launchTUIInTerminal()
        default:
            // 默认使用 Terminal.app
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
        // 2. 开发环境：.build/debug/meee2
        let debugPath = "/Users/bytedance/peer_island_workspace/meee2/.build/debug/meee2"
        if FileManager.default.fileExists(atPath: debugPath) {
            return debugPath
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
            let contentView = NSHostingView(rootView: IslandView(statusManager: statusManager))
            contentView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
            islandWindow?.contentView = contentView
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
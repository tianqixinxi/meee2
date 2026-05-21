import SwiftUI
import meee2Kit
import Meee2PluginKit
import Meee2CommKit
import Sparkle

/// AppDelegate - 管理 macOS 特有的窗口和状态栏
public class AppDelegate: NSObject, NSApplicationDelegate {
    /// 状态栏图标
    private var statusItem: NSStatusItem?

    /// Sparkle 自动更新控制器。Standard 版自带 UI（"Check for Updates…"
    /// 弹框、下载进度、relaunch 流程），用 Info.plist 的 SUFeedURL +
    /// SUPublicEDKey 决定从哪拉 appcast 以及拿什么公钥校验签名。
    ///
    /// 自定义 user driver —— 把 Sparkle 所有交互 dialog 全自动 confirm,
    /// 实现"点 pill 直接装 + relaunch,零弹框"。详见 SilentInstallUserDriver。
    private let silentDriver = SilentInstallUserDriver()

    /// SPUUpdater + 自定义 driver(取代 SPUStandardUpdaterController + 标准
    /// driver)。Sparkle 后台 24h 调度 + SUAutomaticallyUpdate=YES 自动下载
    /// stage,用户点 pill / menubar item 时调 installUpdatesIfAvailable() 立即
    /// apply,silentDriver 把所有"Install and Relaunch"等确认框自动 confirm。
    ///
    /// 历史:之前用 SPUStandardUpdaterController(startingUpdater:true) + 标准
    /// driver,一定会弹 "Install and Relaunch" 框。改成自管 SPUUpdater 是为
    /// 了能注入自定义 driver。
    private lazy var updater: SPUUpdater = {
        let u = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: silentDriver,
            delegate: nil
        )
        do {
            try u.start()
            NSLog("[Sparkle] updater started, automaticallyChecksForUpdates=\(u.automaticallyChecksForUpdates)")
        } catch {
            NSLog("[Sparkle] updater failed to start: \(error)")
        }
        return u
    }()

    /// 灵动岛窗口
    private var islandWindow: DynamicIslandWindow?

    /// 设置窗口
    private var settingsWindow: NSWindow?

    /// Board WebUI shell window controller (strong ref, otherwise NSWindowController is released).
    private var boardWindowController: BoardWebWindowController?

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

    /// 是否展示灵动岛窗口
    @AppStorage("showIsland") private var showIsland: Bool = true

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStartedAt = Date()
        // 初始化日志管理器
        _ = LogManager.shared
        AppIconProvider.installApplicationIcon()

        // 启动诊断头 —— 用户报"open board 不行"时第一眼要看的版本/路径/
        // 是否被 Gatekeeper translocated。必须在所有其他启动逻辑之前打。
        AppDiagnostics.logBootBanner()

        // Comm-kit 用一个独立的 logHandler;这里把它桥到主仓的 MLog 家族,
        // 让 MessageRouter / ChannelRegistry / AuditLogger 内部日志走同一管道。
        // 必须在 MessageRouter 第一次被触碰之前完成。
        commLogHandler = { level, msg in
            switch level {
            case .debug: MDebug(msg)
            case .info: MInfo(msg)
            case .warning: MWarn(msg)
            case .error: MError(msg)
            }
        }

        // 把 cwd → sessionId 的反查能力注入 comm-kit。Tests 不走 AppDelegate,
        // 因此 A2AIdentity 在测试里默认无 resolver,cwd 路径返回 nil(测试本来
        // 也不依赖 cwd 解析,符合现状)。
        A2AIdentity.resolver = SessionStoreIdentityResolver()

        // 设置为 accessory 应用 (不显示在 Dock，只有状态栏)
        NSApp.setActivationPolicy(.accessory)

        // 先建好主菜单栏——.accessory 时不显示，Board 窗口切 .regular 后自动出现
        setupMainMenu()

        // 创建状态栏图标
        setupStatusBar()

        // 创建灵动岛窗口
        if showIsland {
            setupIslandWindow()
        }

        registerAppObservers()

        // 把 silentDriver 的 staged 状态桥到 meee2Kit 模块。BoardAPI.getVersion
        // 读这两个 → frontend UpdatePill 决定是否渲染 + dev panel 显示版本号。
        SparkleStagedBridge.setSnapshot { [weak self] in
            self?.silentDriver.isReadyToInstall ?? false
        }
        SparkleStagedBridge.setStagedVersionProvider { [weak self] in
            self?.silentDriver.stagedVersion
        }

        // 到这里状态栏 + Island 已经可见。后面的磁盘扫描、动态 plugin 加载、
        // MCP/Hook 配置收敛和更新检查都走 post-launch 阶段，避免拖慢首帧。
        schedulePostLaunchStartup(launchStartedAt: launchStartedAt)
    }

    private func schedulePostLaunchStartup(launchStartedAt: Date) {
        DispatchQueue.main.async { [weak self] in
            self?.startSessionRuntime()
            self?.startBoardServer()

            if BoardCommand.shouldShowOnLaunch {
                DispatchQueue.main.async { [weak self] in
                    self?.openBoardMenu()
                }
            }

            // 发送使用统计（异步，不阻塞启动）
            UsageTracker.shared.trackLaunch()

            // 启动 meee2 推送器（如果已连接且在线）
            Meee2OnlinePusher.shared.activate()

            let elapsed = Date().timeIntervalSince(launchStartedAt) * 1_000
            MInfo(String(format: "[Startup] post-launch runtime scheduled after %.1fms", elapsed))
        }

        DispatchQueue.global(qos: .utility).async {
            // 确保 Claude CLI hooks 配置存在。可能读写 ~/.claude/settings.json，
            // 不需要卡在 UI 首帧前。
            SettingsConfigManager.shared.ensureHooksConfigured()

            // 自动在 `~/.claude.json` / Codex config 注册 meee2 MCP server，让每个
            // Claude/Codex session 原生拿到 send_message / list_channels 等 tool。
            // 这里会跑 `which node` 并读写用户配置，放到后台收敛即可。
            MCPConfigManager.shared.ensureRegistered()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            // 强制 init Sparkle updater(lazy var,不主动 touch 永远不创建,
            // 后台 24h 调度也跑不起来)。延后到首帧之后，避免 Sparkle 初始化影响
            // 菜单栏/Island 出现速度。
            _ = self.updater

            // 启动后再 kick 一次 bg check。给 BoardServer / plugin 启动腾出时间,
            // 然后触发一次完整 cycle:fetch appcast → 下载 → stage → halt。
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.updater.checkForUpdatesInBackground()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            // BoardServer 的 /api/version + Settings UI 都从 VersionChecker.shared 读。
            // 延迟首次网络请求，避免启动时和 Sparkle / plugin 扫描争资源。
            VersionChecker.shared.startBackgroundCheck(initialDelay: 2)
        }
    }

    private func startSessionRuntime() {
        // AgentInboxShell 是 plugin 路径的 push delegate(把消息 paste 到
        // 终端)。注册必须在 startAll() / bindChannelOrientationHook() 之前 ——
        // plugin 启动 / orientation 推送都会触发 send → deliver → push,漏注册
        // 会让首批消息缺失 push 通知。
        // `_ = AgentInboxShell.shared` 一并完成强制 init —— 之前是 MessageRouter.init
        // 里隐式触发的,现在改成在这里显式做,确保 SessionEventBus 订阅 +
        // 1.5s flushAllInboxes 调度生效。
        _ = AgentInboxShell.shared
        MessageRouter.shared.registerPushDelegate(AgentInboxShell.shared)

        // 把 host 实现注入 plugin-kit 的 A2AContext，**必须**在 plugin 加载之前。
        // Plugin 的 init/start 阶段（甚至 SessionPlugin 构造期间）就可能调
        // A2AContext.shared.* —— 如果 register 在 plugin 加载之后，那时 provider
        // 还是 nil，所有查询返回 fallback（空数组 / nil），plugin 自治逻辑被静默废掉。
        Meee2PluginKit.A2AContext.shared.register(A2AContextHostProvider())

        // Register builtin in-process plugins. ExternalChatPlugin receives
        // browser-extension pushed sessions (ChatGPT / Claude.ai web chats)
        // via /api/external-sessions/* — must register *before* startAll so
        // PluginManager wires up onSessionsUpdated callbacks.
        PluginManager.shared.register(ExternalChatPlugin.shared)

        // Claude Desktop session metadata 索引器：扫
        // ~/Library/Application Support/Claude/claude-code-sessions/
        // 把 desktop 起的 session（cliSessionId / title / model / isArchived）
        // 装饰到现有 ClaudePlugin session 上。Hook 已经把 desktop session 钩
        // 进来了，这一步只是补 metadata。Claude.app 没装的机器是 noop。
        ClaudeDesktopMetadataReader.shared.start()

        // 启用 channel join/leave 的 orientation 推送：当 session 加入 channel
        // 时往该 session 的 inbox 推一条 synthetic 系统消息（teammates / 用法
        // 提示），其他成员也会收到 "X joined" 通知。走现有 operator → session
        // 路径 + Stop-hook drain，零新基础设施。**production-only**：tests 不
        // 调这条，确保单测的 inbox 计数不被 orientation 污染。
        MessageRouter.shared.bindChannelOrientationHook()

        // SessionStore 已经从 disk 载入。用 Ghostty PR #11922 提供的
        // tty AppleScript 属性反查每个 session 真正所在的 Ghostty terminal id，
        // 修正历史上 "focused terminal" 启发式造成的撞车 / 错配。
        // 在后台跑：osascript 可能 100-200ms，不阻塞 UI。
        DispatchQueue.global(qos: .utility).async {
            _ = GhosttyTerminalRegistry.reconcileSessionStore()
        }

        // 启动状态监控
        statusManager.start()
        CoordinationWatcher.shared.start()

        // Codex / Cursor / OpenClaw 是 dylib 形式的外部 plugin，加载阶段会做文件
        // 同步、dlopen 和 plugin.json 扫描。先让 Claude/ExternalChat 这些进程内
        // plugin 出结果，再延后加载动态插件，避免它们拖慢启动后的首批可见 session。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PluginManager.shared.loadExternalPlugins()
            PluginManager.shared.startAll()
        }
    }

    private func startBoardServer() {
        // 自动启动 Board HTTP/WS 服务器。9876 是首选端口；如果被占用，
        // BoardServer 会选择后续空闲端口并在本进程内保持稳定。
        do {
            try BoardServer.shared.start()
            MInfo("[AppDelegate] BoardServer listening on \(BoardServer.shared.url)")
        } catch {
            MError("[AppDelegate] BoardServer failed to start: \(error)")
        }
    }

    private func registerAppObservers() {
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

        // 监听灵动岛显示开关
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(islandVisibilityDidChange),
            name: .islandVisibilityChanged,
            object: nil
        )

        // SettingsView (在 meee2Kit 模块,不能直接 import Sparkle) 发的
        // "Check for Updates" 通知 → 在这里桥到 SPUStandardUpdaterController。
        // 这条通道把 Settings 那个按钮和 menubar "Check for Updates…" 完全
        // 整成一套：触发同样的 Sparkle modal,同样的下载/安装流程。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCheckForUpdatesRequest),
            name: Notification.Name("meee2.checkForUpdates"),
            object: nil
        )
        // Background-only path:silent 拉 + 下载 + stage,不弹 UI。BoardServer
        // /api/update/check-in-background 走这条,主要给 dev 测试预下载流程用。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackgroundUpdateRequest),
            name: Notification.Name("meee2.checkForUpdatesInBackground"),
            object: nil
        )
    }

    /// pill click 入口。三条路径:
    ///   1. **staged 包是最新版** → confirmPendingInstall → Sparkle 秒装 + relaunch。
    ///   2. **staged 包过时**(远端出了更新版) → discardPending 丢掉旧 reply,
    ///      然后跑 user-initiated checkForUpdates 拉真正的最新版下来装。
    ///   3. **没 staged 包** → 直接 user-initiated checkForUpdates 走完整闭环。
    @objc private func handleCheckForUpdatesRequest() {
        let stagedV = silentDriver.stagedVersion
        let latestV = VersionChecker.shared.latestVersion
        if let stagedV, stagedV == latestV {
            // 路径 1
            _ = silentDriver.confirmPendingInstall()
            return
        }
        // 路径 2(staged 但版本对不上)/ 路径 3(完全没 staged):
        _ = silentDriver.discardPendingInstall()
        // user-initiated check —— silentDriver 看到 userInitiated=true,
        // 这次 cycle 的 showReady 会 auto-install 不再 halt,直接 relaunch。
        updater.checkForUpdates()
    }

    /// SPUUpdater.checkForUpdatesInBackground —— silent 路径,driver 也都 no-op。
    /// 走完整 cycle:fetch appcast → 下载 → 验签 → stage。
    /// dev UI 的 "Check" pill 调这个让 Sparkle 把 DMG 预下好,之后点 Update
    /// 才能立即 apply 不再下载。生产环境靠 24h 调度自己跑这条。
    @objc private func handleBackgroundUpdateRequest() {
        updater.checkForUpdatesInBackground()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        statusManager.stop()
        BoardServer.shared.stop()
        Meee2OnlinePusher.shared.deactivate()
        NotificationCenter.default.removeObserver(self)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let boardWindowController {
            boardWindowController.show()
            return false
        }
        return true
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // 设置初始图标（无 session）
        updateStatusBarIcon(hasActiveSessions: false)

        // 设置菜单（简化版：Open Board + diagnostics + Quit）。
        let menu = NSMenu()
        let boardItem = NSMenuItem(title: "Open Board", action: #selector(openBoardMenu), keyEquivalent: "b")
        boardItem.target = self
        menu.addItem(boardItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        // 诊断入口 —— 客户报问题时第一指引：菜单点 Reveal Log →
        // 拖 meee2.log 发我；或 Copy Diagnostic Info 把版本/BoardServer
        // 状态/9876 占用情况一键塞剪贴板。
        let revealLogItem = NSMenuItem(
            title: "Reveal Log in Finder",
            action: #selector(revealLogInFinder),
            keyEquivalent: ""
        )
        revealLogItem.target = self
        menu.addItem(revealLogItem)
        let diagItem = NSMenuItem(
            title: "Copy Diagnostic Info",
            action: #selector(copyDiagnosticInfo(_:)),
            keyEquivalent: ""
        )
        diagItem.target = self
        menu.addItem(diagItem)
        menu.addItem(NSMenuItem.separator())
        // Sparkle —— 跟 pill 同一条入口,silentDriver 把所有 dialog 自动 confirm,
        // 点完直接装 + relaunch,无弹框。
        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(handleCheckForUpdatesRequest),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        // 点击图标时打开 Island；Island 关闭时改为打开 Settings，避免入口丢失。
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
        guard showIsland else { return }
        if islandWindow == nil {
            setupIslandWindow()
        }
        islandWindow?.makeKeyAndOrderFront(nil)
    }

    /// 点击状态栏图标
    @objc private func statusBarClicked() {
        if showIsland {
            openIsland()
        } else {
            openSettings()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            createSettingsWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openBoardMenu() {
        MInfo("[AppDelegate] Open Board clicked (BoardServer.isRunning=\(BoardServer.shared.isRunning))")
        if !BoardServer.shared.isRunning {
            do {
                try BoardServer.shared.start()
                MInfo("[AppDelegate] BoardServer started on demand: \(BoardServer.shared.url)")
            } catch {
                MError("[AppDelegate] failed to start board server: \(error)")
                let alert = NSAlert()
                alert.messageText = "Failed to start Board server"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        }
        let fallbackURL = URL(string: BoardServer.shared.url)!
        let isFirstShow = boardWindowController == nil
        if isFirstShow {
            MInfo("[AppDelegate] Creating BoardWebWindowController for \(fallbackURL.absoluteString)")
            boardWindowController = BoardWebWindowController(boardURL: fallbackURL)
            boardWindowController?.onClose = { [weak self] in
                MInfo("[AppDelegate] Board window closed")
                self?.boardWindowController = nil
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            MInfo("[AppDelegate] Reusing existing BoardWebWindowController")
        }
        NSApp.setActivationPolicy(.regular)
        AppIconProvider.installDockTileIcon()
        boardWindowController?.show()
    }

    private func createSettingsWindow() {
        let contentView = NSHostingView(rootView: SettingsView())
        contentView.frame = NSRect(x: 0, y: 0, width: 520, height: 450)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(red: 0.055, green: 0.058, blue: 0.070, alpha: 1).cgColor

        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "meee2 Settings"
        settingsWindow?.appearance = NSAppearance(named: .darkAqua)
        settingsWindow?.backgroundColor = NSColor(red: 0.055, green: 0.058, blue: 0.070, alpha: 1)
        settingsWindow?.contentView = contentView
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Diagnostics

    @objc private func revealLogInFinder() {
        let url = LogManager.shared.logFileURL
        MInfo("[AppDelegate] Reveal Log clicked → \(url.path)")
        // 文件可能因为还没写过任何东西而不存在 —— 兜底创建空文件，免得
        // Finder 弹"找不到"。
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyDiagnosticInfo(_ sender: NSMenuItem) {
        MInfo("[AppDelegate] Copy Diagnostic Info clicked")
        let payload = AppDiagnostics.clipboardDiagnostic()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        // 短暂改菜单项标题作为反馈 —— 用户菜单已收起，但下次打开会看到
        // "Copied!"，0.8s 后恢复。比弹 alert 安静。
        let originalTitle = sender.title
        sender.title = "Copied to clipboard ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            sender.title = originalTitle
        }
    }

    // MARK: - Main Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // ── App menu (meee2) ──
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About meee2",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide meee2",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others",
                                             action: #selector(NSApplication.hideOtherApplications(_:)),
                                             keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit meee2",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ── File ──
        let fileMenu = NSMenu(title: "File")
        let boardItem = fileMenu.addItem(withTitle: "Open Board",
                                         action: #selector(openBoardMenu),
                                         keyEquivalent: "b")
        boardItem.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // ── Edit ──
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo",
                                        action: Selector(("redo:")),
                                        keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // ── View ──
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar",
                         action: #selector(BoardWebWindowController.toggleSidebarFromMenu(_:)),
                         keyEquivalent: "s")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Reload",
                         action: #selector(BoardWebWindowController.reloadFromMenu(_:)),
                         keyEquivalent: "r")
        let browserItem = viewMenu.addItem(
            withTitle: "Open in Browser",
            action: #selector(BoardWebWindowController.openInBrowserFromMenu(_:)),
            keyEquivalent: "b")
        browserItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(BoardWebWindowController.actualSizeFromMenu(_:)),
                         keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(BoardWebWindowController.zoomInFromMenu(_:)),
                         keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(BoardWebWindowController.zoomOutFromMenu(_:)),
                         keyEquivalent: "-")
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // ── Window ──
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // ── Help ──
        let helpMenu = NSMenu(title: "Help")
        let githubItem = helpMenu.addItem(withTitle: "meee2 on GitHub",
                                          action: #selector(openGitHubHelp(_:)),
                                          keyEquivalent: "")
        githubItem.target = self
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openGitHubHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/tianqixinxi/meee2") {
            NSWorkspace.shared.open(url)
        }
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
        guard showIsland else { return }
        // 用户更改屏幕选择，重新定位窗口
        setupIslandWindow()
        positionIslandWindow()
    }

    @objc private func islandVisibilityDidChange() {
        if showIsland {
            setupIslandWindow()
        } else {
            islandWindow?.orderOut(nil)
        }
    }

    // MARK: - Island Window

    private func setupIslandWindow() {
        guard showIsland else {
            islandWindow?.orderOut(nil)
            return
        }

        // 获取用户选择的屏幕
        guard let screen = getSelectedScreen() else { return }

        // 检测刘海尺寸
        deviceNotchSize = screen.notchSize

        // 调试输出
        MDebug("[AppDelegate] Screen: \(screen.displayName) frame=\(screen.frame) safeAreaInsets=\(screen.safeAreaInsets) notch=\(deviceNotchSize)")

        // 如果没有刘海，使用默认尺寸
        if deviceNotchSize == .zero {
            deviceNotchSize = defaultIslandSize
            MDebug("[AppDelegate] No notch detected, using default size: \(deviceNotchSize)")
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
        MDebug("[AppDelegate] Island window frame=\(islandWindow?.frame ?? .zero) visible=\(islandWindow?.isVisible ?? false) level=\(islandWindow?.level.rawValue ?? -1)")
    }

    private func positionIslandWindow() {
        guard let window = islandWindow,
              let screen = getSelectedScreen() else {
            MWarn("[AppDelegate] positionIslandWindow: no window or screen")
            return
        }

        let screenFrame = screen.frame

        // 窗口尺寸
        let windowWidth = max(deviceNotchSize.width, 500)
        let windowHeight = expandedHeight

        // 计算位置：屏幕顶部中央，窗口顶部和屏幕顶部齐平
        // macOS 坐标系：左下角是 (0,0)，Y 轴向上
        let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
        let y = screenFrame.origin.y + screenFrame.height - windowHeight

        let newFrame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
        window.setFrame(newFrame, display: true)
        MDebug("[AppDelegate] Island positioned screen=\(screen.displayName) frame=\(screenFrame) target=(\(x),\(y)) size=\(windowWidth)x\(windowHeight) actual=\(window.frame)")
    }

    @objc private func screenParametersDidChange() {
        guard showIsland else { return }

        // 屏幕参数变化（接外接 / 拔外接 / 刘海机回来）时全量重算：
        //   1. 同步 deviceNotchSize  → 决定窗口宽高
        //   2. 同步 statusManager.notchSize → IslandView 内部 shape 几何
        //   3. 重设 hosting view frame  → 防止 SwiftUI 缓存上次屏的 layout
        //   4. setFrame                 → 把窗口对齐到新屏顶部正中
        //
        // 之前只更新 deviceNotchSize 且加了 `!= .zero` 守卫，结果：
        //   - statusManager.notchSize 永远停在第一次启动时的值，岛内 shape
        //     不跟着新屏幕的真实刘海宽度走 → 视觉上和真刘海错位。
        //   - reconnect 瞬间 safeAreaInsets 可能短暂为 0，被守卫吞掉后值
        //     就锁死在旧屏的尺寸了。
        //
        // 现在的策略：拿到非零就直接更新；拿到零（外接 / 过渡瞬态）就
        // 退回 defaultIslandSize，并在 200ms 后重试一次抓真值。
        refreshIslandForCurrentScreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshIslandForCurrentScreen()
        }
    }

    /// 重新读取当前屏 notch、同步 StatusManager、重排窗口。幂等。
    private func refreshIslandForCurrentScreen() {
        guard showIsland else { return }
        guard let screen = getSelectedScreen() else { return }

        let detected = screen.notchSize
        let resolved: CGSize
        if detected != .zero {
            resolved = detected
        } else {
            // 外接显示器 / 过渡态：回退到默认尺寸而不是保留旧值
            resolved = defaultIslandSize
        }

        if resolved != deviceNotchSize {
            deviceNotchSize = resolved
        }
        // 关键修复：IslandView 是按 statusManager.notchSize 计算
        // compactWidth / 内部 shape 的，必须每次屏幕变都同步一次
        if statusManager.notchSize != resolved {
            statusManager.notchSize = resolved
        }

        // 重排 hosting view 大小 + 窗口位置
        if let window = islandWindow {
            let windowWidth = max(deviceNotchSize.width, 500)
            let windowHeight = expandedHeight
            window.contentView?.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        }
        positionIslandWindow()
    }
}

import SwiftUI
import Meee2PluginKit

/// 设置面板视图
public struct SettingsView: View {
    // MARK: - AppStorage

    /// 用户选择的屏幕 ID
    @AppStorage("selectedScreenId") private var selectedScreenId: String = "builtin"

    /// 是否自动展开
    @AppStorage("autoExpandEnabled") private var autoExpandEnabled: Bool = true

    /// 自动收起时间 (秒)
    @AppStorage("autoCloseInterval") private var autoCloseInterval: Double = 8

    /// 收起状态是否展示 session 信息
    @AppStorage("showSessionInCompact") private var showSessionInCompact: Bool = true

    /// 轮播时长 (秒)
    @AppStorage("carouselInterval") private var carouselInterval: Double = 10

    // MARK: - meee360 Settings

    /// meee360 是否已连接
    @AppStorage("meee360Connected") private var meee360Connected: Bool = false

    /// meee360 是否在线（同步到云端）
    @AppStorage("meee360Online") private var meee360Online: Bool = false

    /// Team ID
    @AppStorage("meee360TeamId") private var meee360TeamId: String = ""

    /// Team Name
    @AppStorage("meee360TeamName") private var meee360TeamName: String = ""

    /// User ID
    @AppStorage("meee360UserId") private var meee360UserId: String = ""

    /// Supabase URL
    @AppStorage("meee360SupabaseUrl") private var meee360SupabaseUrl: String = ""

    /// Supabase Key
    @AppStorage("meee360SupabaseKey") private var meee360SupabaseKey: String = ""

    /// Machine ID (auto-generated)
    private var meee360MachineId: String {
        Host.current().name ?? "unknown"
    }

    /// Session Key (per session, not stored)
    private var meee360SessionKey: String {
        "claude-\(UUID().uuidString.prefix(8))"
    }

    /// 连接码输入
    @State private var connectionCode: String = ""

    /// 正在验证连接码
    @State private var verifyingCode: Bool = false

    // MARK: - Init

    public init() {}

    // MARK: - State

    /// 可用屏幕列表
    private var availableScreens: [(id: String, name: String, hasNotch: Bool)] {
        NSScreen.screens.map { screen in
            (
                id: screen.screenId,
                name: screen.displayName,
                hasNotch: screen.notchSize != .zero
            )
        }
    }

    // MARK: - Body

    public var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            userSettings
                .tabItem {
                    Label("User", systemImage: "person")
                }

            pluginsSettings
                .tabItem {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                }

            aboutSettings
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 520)
        .padding()
        .onChange(of: meee360Connected) { _ in writeMeee360Settings() }
        .onChange(of: meee360Online) { _ in writeMeee360Settings() }
        .onChange(of: meee360SupabaseUrl) { _ in writeMeee360Settings() }
        .onChange(of: meee360SupabaseKey) { _ in writeMeee360Settings() }
        .onChange(of: meee360TeamId) { _ in writeMeee360Settings() }
        .onChange(of: meee360UserId) { _ in writeMeee360Settings() }
    }

    // MARK: - General Settings (合并 Display + Behavior)

    private var generalSettings: some View {
        Form {
            Section("Screen Selection") {
                Picker("Display Island on:", selection: $selectedScreenId) {
                    ForEach(availableScreens, id: \.id) { screen in
                        Text(screen.name)
                            .tag(screen.id)
                    }
                }
                .onChange(of: selectedScreenId) { _ in
                    NotificationCenter.default.post(
                        name: .screenSelectionChanged,
                        object: nil
                    )
                }

                // 显示当前选中屏幕的详细信息
                if let screen = NSScreen.screens.first(where: { $0.screenId == selectedScreenId }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Resolution:")
                                .foregroundColor(.secondary)
                            Text("\(Int(screen.frame.width)) x \(Int(screen.frame.height))")
                                .fontWeight(.medium)
                        }
                        HStack {
                            Text("Has Notch:")
                                .foregroundColor(.secondary)
                            if screen.notchSize != .zero && screen.notchSize.height > 25 {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                        HStack {
                            Text("Screen ID:")
                                .foregroundColor(.secondary)
                            Text(screen.screenId)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
            }

            Section("Compact View") {
                Toggle("Show session info in compact view", isOn: $showSessionInCompact)

                if showSessionInCompact {
                    HStack {
                        Text("Carousel interval:")
                        Spacer()
                        Slider(value: $carouselInterval, in: 3...30, step: 1)
                        Text("\(Int(carouselInterval))s")
                            .frame(width: 40)
                    }
                }
            }

            Section("Auto Expand & Close") {
                Toggle("Auto expand when needs attention", isOn: $autoExpandEnabled)

                HStack {
                    Text("Auto close after:")
                    Spacer()
                    Slider(value: $autoCloseInterval, in: 3...30, step: 1)
                    Text("\(Int(autoCloseInterval))s")
                        .frame(width: 40)
                }
            }

            Section("Sound Notifications") {
                @ObservedObject var soundManager = SoundManager.shared

                Toggle("Enable sound notifications", isOn: $soundManager.soundEnabled)

                if soundManager.soundEnabled {
                    HStack {
                        Text("Volume:")
                        Spacer()
                        Slider(value: $soundManager.volume, in: 0...1, step: 0.1)
                        Text("\(Int(soundManager.volume * 100))%")
                            .frame(width: 40)
                    }

                    // 各事件音效开关
                    ForEach(SoundEvent.allCases, id: \.self) { event in
                        HStack {
                            Toggle(event.displayName, isOn: Binding(
                                get: { soundManager.eventSounds[event] ?? event.defaultEnabled },
                                set: { soundManager.eventSounds[event] = $0 }
                            ))

                            Spacer()

                            // 测试按钮
                            Button(action: { soundManager.testSound(for: event) }) {
                                Image(systemName: "speaker.wave.2")
                            }
                            .buttonStyle(.borderless)
                            .help("Test sound")
                        }
                    }

                    // 重置按钮
                    Button("Reset to Defaults") {
                        soundManager.resetToDefaults()
                    }
                }
            }

            Section("Usage Statistics") {
                @AppStorage("usageTrackingEnabled") var usageTrackingEnabled: Bool = true

                Toggle("Help improve meee2", isOn: $usageTrackingEnabled)

                Text("Send anonymous usage statistics (device ID, version, OS) to help us understand usage. No personal information collected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Display Settings (保留用于向后兼容)

    private var displaySettings: some View {
        generalSettings
    }

    // MARK: - Behavior Settings (保留用于向后兼容)

    private var behaviorSettings: some View {
        generalSettings
    }

    // MARK: - User Settings (meee360)

    private var userSettings: some View {
        Form {
            Section("meee360 Cloud Sync") {
                if meee360Connected {
                    // Connected state
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading) {
                            Text("Connected to \(meee360TeamName)")
                                .font(.headline)
                            Text("Team: \(meee360TeamId)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    Toggle("Online (sync sessions)", isOn: $meee360Online)

                    HStack {
                        Button("Open Dashboard") {
                            NSWorkspace.shared.open(URL(string: "http://localhost:3000/dashboard")!)
                        }
                        Spacer()
                        Button("Disconnect") {
                            disconnectMeee360()
                        }
                    }
                } else {
                    // Not connected state
                    HStack {
                        Image(systemName: "cloud.slash")
                            .foregroundColor(.secondary)
                        Text("Not connected")
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    // Single connect button - opens browser with callback
                    Button("Connect to meee360") {
                        let callbackUrl = "http://localhost:9876/meee360/callback"
                        let connectUrl = "http://localhost:3000/connect?callback=\(callbackUrl)"
                        NSWorkspace.shared.open(URL(string: connectUrl)!)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Click to open browser, login to meee360, and automatically connect.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("When connected and online, your Claude sessions will sync to meee360 dashboard for team visibility.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("meee360.connected"))) { notification in
            // Handle callback from browser
            if let userInfo = notification.userInfo {
                meee360Connected = true
                meee360TeamId = userInfo["teamId"] as? String ?? ""
                meee360TeamName = userInfo["teamName"] as? String ?? ""
                meee360UserId = userInfo["userId"] as? String ?? ""
                meee360SupabaseUrl = userInfo["supabaseUrl"] as? String ?? ""
                meee360SupabaseKey = userInfo["supabaseKey"] as? String ?? ""
                meee360Online = true
            }
        }
    }

    private func verifyConnectionCode() {
        guard connectionCode.count == 6 else { return }

        verifyingCode = true

        Task {
            do {
                let result = try await verifyCode(code: connectionCode)

                // Store configuration
                meee360Connected = true
                meee360TeamId = result.team.id
                meee360TeamName = result.team.name
                meee360UserId = result.user.id
                meee360SupabaseUrl = result.supabase_url
                meee360SupabaseKey = result.supabase_key

                connectionCode = ""
                showAlert(title: "Connected!", message: "Successfully connected to \(result.team.name)")
            } catch {
                showAlert(title: "Connection Failed", message: error.localizedDescription)
            }

            verifyingCode = false
        }
    }

    private func verifyCode(code: String) async throws -> Meee360ConnectResult {
        let endpoint = URL(string: "http://localhost:3000/api/v1/connect")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(Meee360ConnectResult.self, from: data)
    }

    private func disconnectMeee360() {
        meee360Connected = false
        meee360Online = false
        meee360TeamId = ""
        meee360TeamName = ""
        meee360UserId = ""
        meee360SupabaseUrl = ""
        meee360SupabaseKey = ""
    }

    private var meee360DashboardUrl: URL? {
        guard !meee360SupabaseUrl.isEmpty else { return nil }
        // Extract project ref from Supabase URL for dashboard link
        // URL format: https://xxx.supabase.co -> dashboard at meee360 app
        return URL(string: "http://localhost:3000/dashboard")
    }

    private func testMeee360Connection() {
        guard !meee360SupabaseUrl.isEmpty,
              !meee360SupabaseKey.isEmpty,
              !meee360TeamId.isEmpty,
              !meee360UserId.isEmpty else {
            showAlert(title: "Missing Configuration", message: "Please fill in all required fields.")
            return
        }

        let url = meee360SupabaseUrl
        let key = meee360SupabaseKey
        let teamId = meee360TeamId
        let userId = meee360UserId

        Task {
            do {
                _ = try await testSupabaseConnection(url: url, key: key, teamId: teamId, userId: userId)
                showAlert(title: "Connection OK", message: "Successfully connected to meee360.")
            } catch {
                showAlert(title: "Connection Failed", message: error.localizedDescription)
            }
        }
    }

    private func testSupabaseConnection(url: String, key: String, teamId: String, userId: String) async throws -> Bool {
        let endpoint = URL(string: "\(url)/rest/v1/meee360_team_sessions?team_id=eq.\(teamId)&user_id=eq.\(userId)&limit=1")!
        var request = URLRequest(url: endpoint)
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return true
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func writeMeee360Settings() {
        guard meee360Connected else { return }

        let settings: [String: Any] = [
            "meee360": [
                "enabled": meee360Connected,
                "online": meee360Online,
                "supabaseUrl": meee360SupabaseUrl,
                "supabaseKey": meee360SupabaseKey,
                "teamId": meee360TeamId,
                "userId": meee360UserId,
                "machineId": Host.current().name ?? "unknown",
                "sessionKey": "claude-\(ProcessInfo.processInfo.processIdentifier)"
            ]
        ]

        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        let file = dir.appendingPathComponent("settings.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write JSON
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
            NSLog("[Settings] Wrote meee360 settings to \(file.path)")
        }
    }

    // MARK: - Plugins Settings

    @ObservedObject private var pluginManager = PluginManager.shared

    private var pluginsSettings: some View {
        Form {
            Section("Installed Plugins") {
                if pluginManager.loadedPlugins.isEmpty && pluginManager.failedPlugins.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                            Text("No plugins installed")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    // 成功加载的插件
                    ForEach(Array(pluginManager.loadedPlugins.keys.sorted()), id: \.self) { pluginId in
                        if let plugin = pluginManager.loadedPlugins[pluginId] {
                            PluginRowView(plugin: plugin)
                        }
                    }

                    // 加载失败的插件
                    if !pluginManager.failedPlugins.isEmpty {
                        ForEach(pluginManager.failedPlugins) { failedPlugin in
                            FailedPluginRowView(failedPlugin: failedPlugin)
                        }
                    }
                }
            }

            Section("Create Plugin") {
                Text("Create your own plugin to extend meee2 functionality.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Button("Human Read") {
                        showPluginGuide()
                    }
                    Button("Copy2Agent (Recommended)") {
                        copyPluginGuide()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("Info") {
                Text("Plugins extend meee2 to support additional AI assistants. Click a plugin to expand its settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func showPluginGuide() {
        let guide = pluginGuideContent
        let alert = NSAlert()
        alert.messageText = "Plugin Development Guide"
        alert.informativeText = guide
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func copyPluginGuide() {
        let guide = pluginGuideContent
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(guide, forType: .string)

        // Show confirmation
        let alert = NSAlert()
        alert.messageText = "Copied!"
        alert.informativeText = "Plugin guide has been copied to clipboard. Paste it to your AI assistant."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private var pluginGuideContent: String {
        """
        # How to Create a meee2 Plugin

        ## Quick Start

        1. Copy the plugin template:
           cp -r meee2/plugin-template ~/my-plugin
           cd ~/my-plugin

        2. Rename files and replace placeholders:
           - {{PLUGIN_NAME}} → YourPluginName
           - {{PLUGIN_ID}} → com.meee2.plugin.your-plugin
           - {{DISPLAY_NAME}} → Your Plugin Display Name

        3. Update Package.swift path:
           .package(name: "Meee2PluginKit", path: "/path/to/meee2/meee2-plugin-kit")

        4. Implement your plugin logic in the Swift file.

        5. Build and install:
           swift build -c release
           mkdir -p ~/.meee2/plugins/my-plugin
           cp .build/release/libYourPlugin.dylib ~/.meee2/plugins/my-plugin/YourPlugin.dylib

        6. Create plugin.json:
           echo '{"id":"com.meee2.plugin.your-plugin","name":"Your Plugin","version":"1.0.0","dylib":"YourPlugin.dylib"}' > ~/.meee2/plugins/my-plugin/plugin.json

        7. Restart meee2.

        ## Key Methods to Implement

        - pluginId: Unique identifier
        - displayName: Human-readable name
        - getSessions(): Return active sessions
        - activateTerminal(for:): Handle user click

        ## Location

        Plugin template: meee2/plugin-template/
        Install path: ~/.meee2/plugins/<plugin-name>/
        """
    }

    // MARK: - About Settings

    @ObservedObject private var versionChecker = VersionChecker()

    private var aboutSettings: some View {
        Form {
            Section("Version") {
                HStack {
                    Text("Current Version:")
                    Spacer()
                    Text(versionChecker.currentVersion)
                        .foregroundColor(.secondary)
                }

                // Latest Version - 始终显示
                HStack {
                    Text("Latest Version:")
                    Spacer()
                    if versionChecker.isChecking {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Checking...")
                                .foregroundColor(.secondary)
                        }
                    } else if let latest = versionChecker.latestVersion {
                        Text(latest)
                            .foregroundColor(versionChecker.hasUpdate ? .green : .secondary)
                    } else {
                        Text("—")
                            .foregroundColor(.secondary)
                    }
                }

                if versionChecker.hasUpdate {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                        Text("A new version is available!")
                            .foregroundColor(.green)

                        Spacer()

                        if let url = versionChecker.releasesPageUrl {
                            Link("Download", destination: url)
                                .foregroundColor(.blue)
                        }
                    }
                }

                Button("Check for Updates") {
                    Task {
                        await versionChecker.checkForUpdate()
                    }
                }
                .disabled(versionChecker.isChecking)
            }

            Section("Debug") {
                Button("Export Debug Data") {
                    DebugExporter.export()
                }

                Text("Export session data, logs, and plugin status for troubleshooting.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Info") {
                Text("meee2 displays Claude CLI session status in a Dynamic Island-style UI.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Link(destination: URL(string: "https://github.com/tianqixinxi/meee2")!) {
                    Text("GitHub: tianqixinxi/meee2")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            versionChecker.startBackgroundCheck()
        }
    }
}

// MARK: - Plugin Row View

struct PluginRowView: View {
    let plugin: SessionPlugin

    @AppStorage private var enabled: Bool
    @State private var isExpanded = false
    @ObservedObject private var versionChecker = PluginVersionChecker()

    init(plugin: SessionPlugin) {
        self.plugin = plugin
        // Use plugin ID as storage key
        _enabled = AppStorage(wrappedValue: plugin.config.enabled, "plugin_\(plugin.pluginId)_enabled")
    }

    private var sessionCount: Int {
        PluginManager.shared.sessions.filter { $0.pluginId == plugin.pluginId }.count
    }

    private var hasUpdate: Bool {
        versionChecker.hasUpdate(plugin: plugin)
    }

    private var latestVersion: String? {
        versionChecker.getLatestVersion(for: plugin.pluginId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主行
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(plugin.hasError ? Color.red.opacity(0.2) : plugin.themeColor.opacity(0.2))
                            .frame(width: 32, height: 32)
                        Image(systemName: plugin.hasError ? "exclamationmark.triangle.fill" : plugin.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(plugin.hasError ? .red : plugin.themeColor)
                    }

                    // Info
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(plugin.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)

                            Text("v\(plugin.version)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            // 帮助链接
                            if let helpUrl = plugin.helpUrl, let url = URL(string: helpUrl) {
                                Link(destination: url) {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 12))
                                        .foregroundColor(.blue.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .help("Open documentation: \(helpUrl)")
                            }

                            // 版本更新提示
                            if hasUpdate {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 10))
                                    Text("v\(latestVersion ?? "?")")
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.green.opacity(0.15))
                                )
                            }
                        }

                        HStack(spacing: 4) {
                            if plugin.hasError {
                                Text(plugin.lastError ?? "Error")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .lineLimit(1)

                                if let helpUrl = plugin.helpUrl, let url = URL(string: helpUrl) {
                                    Link("Help", destination: url)
                                        .font(.system(size: 11))
                                        .foregroundColor(.blue)
                                }
                            } else if enabled {
                                if sessionCount > 0 {
                                    Text("\(sessionCount) sessions")
                                        .font(.system(size: 11))
                                        .foregroundColor(.blue)
                                } else {
                                    Text("No active sessions")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("Disabled")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // 展开箭头 + Toggle
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)

                    Toggle("", isOn: $enabled)
                        .onChange(of: enabled) { newValue in
                            updatePluginConfig(enabled: newValue)
                        }
                        .labelsHidden()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 展开的详细设置
            if isExpanded {
                pluginSpecificSettings
                    .padding(.top, 8)
                    .padding(.leading, 44)
            }
        }
        .onAppear {
            versionChecker.startBackgroundCheck()
        }
    }

    @ViewBuilder
    private var pluginSpecificSettings: some View {
        switch plugin.pluginId {
        case "com.meee2.plugin.aime":
            AimePluginSettings()
        case "com.meee2.plugin.cursor":
            CursorPluginSettings()
        case "com.meee2.plugin.traecli":
            TraecliPluginSettings()
        case "com.meee2.plugin.openclaw":
            OpenClawPluginSettings()
        default:
            EmptyView()
        }
    }

    private func updatePluginConfig(enabled: Bool) {
        var config = plugin.config
        config.enabled = enabled
        plugin.config = config

        if enabled {
            _ = plugin.start()
            NSLog("[Settings] Enabled plugin: \(plugin.pluginId)")
        } else {
            plugin.stop()
            NSLog("[Settings] Disabled plugin: \(plugin.pluginId)")
        }
    }
}

// MARK: - Failed Plugin Row View

struct FailedPluginRowView: View {
    let failedPlugin: DynamicPluginLoader.FailedPlugin

    var body: some View {
        HStack(spacing: 12) {
            // Icon - 使用警告图标
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.red)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(failedPlugin.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("v\(failedPlugin.version)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    // 不兼容标签
                    if failedPlugin.isCompatibilityError {
                        Text("Incompatible")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.red.opacity(0.15))
                            )
                    }
                }

                HStack(spacing: 4) {
                    Text(failedPlugin.error)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if failedPlugin.isCompatibilityError {
                        Text("— Download new version required")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            // 帮助链接或下载按钮
            if let helpUrl = failedPlugin.helpUrl, let url = URL(string: helpUrl) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                        Text("Update")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .help("Download new version from: \(helpUrl)")
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Aime Plugin Settings

struct AimePluginSettings: View {
    @AppStorage("aimeRefreshInterval") private var refreshInterval: Double = 30.0
    @AppStorage("aimeSessionRetentionHours") private var sessionRetentionHours: Double = 24.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Refresh interval:")
                Spacer()
                Slider(value: $refreshInterval, in: 10...120, step: 5)
                Text("\(Int(refreshInterval))s")
                    .frame(width: 40)
            }

            HStack {
                Text("Session retention:")
                Spacer()
                Slider(value: $sessionRetentionHours, in: 1...72, step: 1)
                Text("\(Int(sessionRetentionHours))h")
                    .frame(width: 40)
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
        )
    }
}

// MARK: - Cursor Plugin Settings

struct CursorPluginSettings: View {
    @AppStorage("cursorRefreshInterval") private var refreshInterval: Double = 10.0
    @AppStorage("cursorProjectsPath") private var projectsPath: String = ""

    private var defaultPath: String {
        let home = NSHomeDirectory()
        return home + "/.cursor/projects"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Refresh interval:")
                Spacer()
                Slider(value: $refreshInterval, in: 2...30, step: 1)
                Text("\(Int(refreshInterval))s")
                    .frame(width: 40)
            }

            // 路径配置
            VStack(alignment: .leading, spacing: 6) {
                Text("Projects directory:")
                    .font(.system(size: 11))

                HStack(spacing: 8) {
                    TextField("Path", text: $projectsPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    Button("Reset") {
                        projectsPath = ""
                    }
                    .font(.system(size: 11))

                    Button("Browse...") {
                        browseCursorPath()
                    }
                    .font(.system(size: 11))
                }

                Text("Default: \(defaultPath)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    private func browseCursorPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select Cursor projects directory"

        if panel.runModal() == .OK, let url = panel.url {
            projectsPath = url.path
        }
    }
}

// MARK: - Traecli Plugin Settings

struct OpenClawPluginSettings: View {
    @AppStorage("openclawRefreshInterval") private var refreshInterval: Double = 10.0
    @AppStorage("openclawAgentsPath") private var agentsPath: String = ""

    private var defaultPath: String {
        let home = NSHomeDirectory()
        return home + "/.openclaw/agents"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Refresh interval:")
                Spacer()
                Slider(value: $refreshInterval, in: 2...30, step: 1)
                Text("\(Int(refreshInterval))s")
                    .frame(width: 40)
            }

            // 路径配置
            VStack(alignment: .leading, spacing: 6) {
                Text("Agents directory:")
                    .font(.system(size: 11))

                HStack(spacing: 8) {
                    TextField("Path", text: $agentsPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    Button("Reset") {
                        agentsPath = ""
                    }
                    .font(.system(size: 11))

                    Button("Browse...") {
                        browseOpenClawPath()
                    }
                    .font(.system(size: 11))
                }

                Text("Default: \(defaultPath)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    private func browseOpenClawPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select OpenClaw agents directory"

        if panel.runModal() == .OK, let url = panel.url {
            agentsPath = url.path
        }
    }
}

// MARK: - Traecli Plugin Settings

struct TraecliPluginSettings: View {
    @AppStorage("traecliRefreshInterval") private var refreshInterval: Double = 10.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Refresh interval:")
                Spacer()
                Slider(value: $refreshInterval, in: 2...30, step: 1)
                Text("\(Int(refreshInterval))s")
                    .frame(width: 40)
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
        )
    }
}

// MARK: - Meee360 Connection Result

struct Meee360ConnectResult: Codable {
    let team: Meee360Team
    let user: Meee360User
    let supabase_url: String
    let supabase_key: String
}

struct Meee360Team: Codable {
    let id: String
    let name: String
}

struct Meee360User: Codable {
    let id: String
}

// MARK: - Notification Name

public extension Notification.Name {
    static let screenSelectionChanged = Notification.Name("screenSelectionChanged")
}

// MARK: - Preview

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .onAppear {
                // Register a test plugin for preview
                let testPlugin = TestPlugin()
                PluginManager.shared.register(testPlugin)
            }
    }
}

// Test plugin for preview
class TestPlugin: SessionPlugin {
    override var pluginId: String { "com.meee2.plugin.test" }
    override var displayName: String { "Test Plugin" }
    override var icon: String { "puzzlepiece.extension" }
    override var themeColor: Color { .purple }
    override func initialize() -> Bool { true }
    override func start() -> Bool { return true }
    override func getSessions() -> [PluginSession] { [] }
    override func activateTerminal(for session: PluginSession) {}
}

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

            pluginsSettings
                .tabItem {
                    Label("Plugins", systemImage: "puzzlepiece.extension")
                }

            aboutSettings
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 450)
        .padding()
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
                if let currentScreen = availableScreens.first(where: { $0.id == selectedScreenId }) {
                    HStack {
                        Text("Current:")
                            .foregroundColor(.secondary)
                        Text(currentScreen.name)
                            .fontWeight(.medium)
                        if currentScreen.hasNotch {
                            Image(systemName: "notch")
                                .foregroundColor(.blue)
                        }
                    }
                    .font(.caption)
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
import SwiftUI
import Meee2PluginKit

private enum SettingsTheme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.070)
    static let card = Color(red: 0.086, green: 0.094, blue: 0.122)
    static let cardBorder = Color.white.opacity(0.08)
    static let accent = Color(red: 0.38, green: 0.48, blue: 0.95)
}

private extension View {
    func meee2SettingsForm() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(SettingsTheme.background)
            .tint(SettingsTheme.accent)
    }
}

/// 设置面板视图
public struct SettingsView: View {
    // MARK: - AppStorage

    /// 用户选择的屏幕 ID
    @AppStorage("selectedScreenId") private var selectedScreenId: String = "builtin"

    /// 是否展示灵动岛窗口
    @AppStorage("showIsland") private var showIsland: Bool = true

    /// 是否自动展开
    @AppStorage("autoExpandEnabled") private var autoExpandEnabled: Bool = true

    /// 自动收起时间 (秒)
    @AppStorage("autoCloseInterval") private var autoCloseInterval: Double = 8

    // MARK: - meee2 Settings

    /// meee2 是否已连接
    @AppStorage("meee2Connected") private var meee2Connected: Bool = false

    /// meee2 是否在线（同步到云端）
    @AppStorage("meee2Online") private var meee2Online: Bool = false

    /// Team ID
    @AppStorage("meee2TeamId") private var meee2TeamId: String = ""

    /// Team Name
    @AppStorage("meee2TeamName") private var meee2TeamName: String = ""

    /// Single connected meee2 team.
    @AppStorage("meee2Teams") private var meee2TeamsData: Data = Data()

    /// Legacy per-session team routing. Kept only to clear old settings.
    @AppStorage("meee2SessionTeamIds") private var meee2SessionTeamIdsData: Data = Data()

    /// User ID
    @AppStorage("meee2UserId") private var meee2UserId: String = ""

    /// Connected meee2 user profile
    @AppStorage("meee2UserName") private var meee2UserName: String = ""
    @AppStorage("meee2UserEmail") private var meee2UserEmail: String = ""
    @AppStorage("meee2UserAvatarUrl") private var meee2UserAvatarUrl: String = ""

    /// Per-session sync controls. Empty means no sessions have been disabled.
    @AppStorage("meee2DisabledSessionIds") private var meee2DisabledSessionIdsData: Data = Data()

    /// Per-session opt-in controls used when default meee2 sync is off.
    @AppStorage("meee2EnabledSessionIds") private var meee2EnabledSessionIdsData: Data = Data()

    /// Supabase URL
    @AppStorage("meee2SupabaseUrl") private var meee2SupabaseUrl: String = ""

    /// Supabase Key
    @AppStorage("meee2SupabaseKey") private var meee2SupabaseKey: String = ""

    /// Machine ID (auto-generated)
    private var meee2MachineId: String {
        Meee2Identity.machineId
    }

    /// Session Key (per session, not stored)
    private var meee2SessionKey: String {
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
        ZStack {
            SettingsTheme.background.ignoresSafeArea()
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
            .tint(SettingsTheme.accent)
        }
        .frame(width: 520, height: 520)
        .padding()
        .background(SettingsTheme.background)
        .preferredColorScheme(.dark)
        .onChange(of: meee2Connected) { _ in updateMeee2OnlineSyncActivation() }
        .onChange(of: meee2Online) { _ in updateMeee2OnlineSyncActivation() }
        .onChange(of: meee2SupabaseUrl) { _ in writeMeee2OnlineSettings() }
        .onChange(of: meee2SupabaseKey) { _ in writeMeee2OnlineSettings() }
        .onChange(of: meee2TeamId) { _ in writeMeee2OnlineSettings() }
        .onChange(of: meee2TeamName) { _ in writeMeee2OnlineSettings() }
        .onChange(of: meee2TeamsData) { _ in writeMeee2OnlineSettings() }
        .onChange(of: meee2UserId) { _ in writeMeee2OnlineSettings() }
        .onChange(of: meee2SessionTeamIdsData) { _ in writeMeee2OnlineSettings() }
        .onChange(of: meee2EnabledSessionIdsData) { _ in updateMeee2OnlineSyncActivation() }
        .onChange(of: meee2DisabledSessionIdsData) { _ in updateMeee2OnlineSyncActivation() }
    }

    // MARK: - General Settings (合并 Display + Behavior)

    private var generalSettings: some View {
        Form {
            Section("Screen Selection") {
                Toggle("Show Dynamic Island", isOn: $showIsland)
                    .onChange(of: showIsland) { _ in
                        NotificationCenter.default.post(
                            name: .islandVisibilityChanged,
                            object: nil
                        )
                    }

                Picker("Display Island on:", selection: $selectedScreenId) {
                    ForEach(availableScreens, id: \.id) { screen in
                        Text(screen.name)
                            .tag(screen.id)
                    }
                }
                .disabled(!showIsland)
                .onChange(of: selectedScreenId) { _ in
                    NotificationCenter.default.post(
                        name: .screenSelectionChanged,
                        object: nil
                    )
                }

                // 显示当前选中屏幕的详细信息
                if showIsland, let screen = NSScreen.screens.first(where: { $0.screenId == selectedScreenId }) {
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

            Section("Auto Expand & Close") {
                Toggle("Auto expand when needs attention", isOn: $autoExpandEnabled)
                    .disabled(!showIsland)

                HStack {
                    Text("Auto close after:")
                    Spacer()
                    Slider(value: $autoCloseInterval, in: 3...30, step: 1)
                    Text("\(Int(autoCloseInterval))s")
                        .frame(width: 40)
                }
                .disabled(!showIsland)
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
        .meee2SettingsForm()
    }

    // MARK: - Display Settings (保留用于向后兼容)

    private var displaySettings: some View {
        generalSettings
    }

    // MARK: - Behavior Settings (保留用于向后兼容)

    private var behaviorSettings: some View {
        generalSettings
    }

    // MARK: - User Settings (meee2)

    private var userSettings: some View {
        Form {
            Section("meee2 Online Sync") {
                if meee2Connected {
                    HStack {
                        meee2UserAvatar
                        VStack(alignment: .leading) {
                            Text(meee2DisplayName)
                                .font(.headline)
                            Text(meee2UserEmail.isEmpty ? "Connected to meee2" : meee2UserEmail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }

                    HStack {
                        Button("Open Dashboard") {
                            NSWorkspace.shared.open(Meee2OnlineConfig.appURL(path: "dashboard"))
                        }
                        Spacer()
                        Button("Disconnect") {
                            disconnectMeee2Online()
                        }
                    }

                    Toggle("Sync to meee2 by default", isOn: $meee2Online)

                    if !meee2DefaultTeamDisplayName.isEmpty {
                        LabeledContent("Team", value: meee2DefaultTeamDisplayName)

                        Text("A meee2 account belongs to one team. New local sessions sync to that team when default sync is on.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(meee2Online
                         ? "New sessions sync unless you turn off a row below."
                         : "Default is No sync. Turn on a row below to sync only that session.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if meee2SyncSessions.isEmpty {
                        Text("No local sessions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(meee2SyncSessions) { session in
                            HStack(alignment: .center, spacing: 12) {
                                meee2SessionSyncRow(session)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Toggle("Sync", isOn: meee2SessionSyncBinding(for: session.id))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            .padding(8)
                            .background(meee2SessionRowBackground(session))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isMeee2OnlineSessionEnabled(session.id) ? Color.green : Color.secondary.opacity(0.45))
                                    .frame(width: 3)
                            }
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
                    Button("Connect to meee2") {
                        var components = URLComponents(url: Meee2OnlineConfig.appURL(path: "connect"), resolvingAgainstBaseURL: false)!
                        components.queryItems = [
                            URLQueryItem(name: "callback", value: "\(BoardServer.shared.url)/meee2/callback")
                        ]
                        if let connectUrl = components.url {
                            NSWorkspace.shared.open(connectUrl)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Click to open browser, login to meee2, and automatically connect.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("Choose the exact local sessions that are visible in your meee2 dashboard.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .meee2SettingsForm()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("meee2.connected")).receive(on: RunLoop.main)) { notification in
            // Handle callback from browser
            if let userInfo = notification.userInfo {
                meee2Connected = true
                meee2TeamId = userInfo["teamId"] as? String ?? ""
                meee2TeamName = userInfo["teamName"] as? String ?? ""
                meee2UserId = userInfo["userId"] as? String ?? ""
                meee2UserName = userInfo["userName"] as? String ?? ""
                meee2UserEmail = userInfo["userEmail"] as? String ?? ""
                meee2UserAvatarUrl = userInfo["userAvatarUrl"] as? String ?? ""
                meee2SupabaseUrl = normalizedMeee2OnlineSupabaseUrl(userInfo["supabaseUrl"] as? String ?? "")
                meee2SupabaseKey = userInfo["supabaseKey"] as? String ?? ""
                if let teamsData = userInfo["teamsData"] as? Data {
                    meee2TeamsData = teamsData
                }
                meee2Online = true
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
                meee2Connected = true
                meee2TeamId = result.team.id
                meee2TeamName = result.team.name
                meee2UserId = result.user.id
                meee2UserName = result.user.name ?? ""
                meee2UserEmail = result.user.email ?? ""
                meee2UserAvatarUrl = result.user.avatar_url ?? ""
                meee2SupabaseUrl = normalizedMeee2OnlineSupabaseUrl(result.supabase_url)
                meee2SupabaseKey = result.supabase_key
                storeMeee2OnlineTeams(result.teams ?? [result.team])
                meee2Online = true
                updateMeee2OnlineSyncActivation()

                connectionCode = ""
                showAlert(title: "Connected!", message: "Successfully connected to \(result.team.name)")
            } catch {
                showAlert(title: "Connection Failed", message: error.localizedDescription)
            }

            verifyingCode = false
        }
    }

    private func verifyCode(code: String) async throws -> Meee2OnlineConnectResult {
        let endpoint = Meee2OnlineConfig.appURL(path: "api/v1/connect")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(Meee2OnlineConnectResult.self, from: data)
    }

    private func disconnectMeee2Online() {
        meee2Connected = false
        meee2Online = false
        meee2TeamId = ""
        meee2TeamName = ""
        meee2UserId = ""
        meee2UserName = ""
        meee2UserEmail = ""
        meee2UserAvatarUrl = ""
        meee2SupabaseUrl = ""
        meee2SupabaseKey = ""
        meee2TeamsData = Data()
        meee2SessionTeamIdsData = Data()
        meee2EnabledSessionIdsData = Data()
        meee2DisabledSessionIdsData = Data()
        updateMeee2OnlineSyncActivation()
    }

    private var meee2DashboardUrl: URL? {
        guard !meee2SupabaseUrl.isEmpty else { return nil }
        // Extract project ref from Supabase URL for dashboard link
        // URL format: https://xxx.supabase.co -> dashboard at meee2 app
        return Meee2OnlineConfig.appURL(path: "dashboard")
    }

    private func testMeee2OnlineConnection() {
        guard !meee2SupabaseUrl.isEmpty,
              !meee2SupabaseKey.isEmpty,
              !meee2TeamId.isEmpty,
              !meee2UserId.isEmpty else {
            showAlert(title: "Missing Configuration", message: "Please fill in all required fields.")
            return
        }

        let url = normalizedMeee2OnlineSupabaseUrl(meee2SupabaseUrl)
        let key = meee2SupabaseKey
        let teamId = meee2TeamId
        let userId = meee2UserId

        Task {
            do {
                _ = try await testSupabaseConnection(url: url, key: key, teamId: teamId, userId: userId)
                showAlert(title: "Connection OK", message: "Successfully connected to meee2.")
            } catch {
                showAlert(title: "Connection Failed", message: error.localizedDescription)
            }
        }
    }

    private func testSupabaseConnection(url: String, key: String, teamId: String, userId: String) async throws -> Bool {
        let endpoint = URL(string: "\(url)/rest/v1/meee2_board_sessions?team_id=eq.\(teamId)&user_id=eq.\(userId)&limit=1")!
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

    private func writeMeee2OnlineSettings() {
        guard meee2Connected else { return }
        let normalizedSupabaseUrl = normalizedMeee2OnlineSupabaseUrl(meee2SupabaseUrl)

        let settings: [String: Any] = [
            "meee2": [
                "enabled": meee2Connected,
                "online": meee2Online,
                "supabaseUrl": normalizedSupabaseUrl,
                "supabaseKey": meee2SupabaseKey,
                "teamId": meee2TeamId,
                "userId": meee2UserId,
                "userName": meee2UserName,
                "userEmail": meee2UserEmail,
                "userAvatarUrl": meee2UserAvatarUrl,
                "teams": meee2Teams.map { team in
                    [
                        "id": team.id,
                        "name": team.name,
                        "role": team.role ?? ""
                    ]
                },
                "sessionTeamIds": [:],
                "defaultSyncEnabled": meee2Online,
                "enabledSessionIds": Array(Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds")),
                "disabledSessionIds": Array(Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds")),
                "machineId": Meee2Identity.machineId,
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
            NSLog("[Settings] Wrote meee2 settings to \(file.path)")
        }
    }

    private func updateMeee2OnlineSyncActivation() {
        writeMeee2OnlineSettings()
        Meee2OnlinePusher.shared.refreshActivation()
    }

    private func normalizedMeee2OnlineSupabaseUrl(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var meee2DisplayName: String {
        if !meee2UserName.isEmpty { return meee2UserName }
        if !meee2UserEmail.isEmpty { return meee2UserEmail.components(separatedBy: "@").first ?? meee2UserEmail }
        return "meee2 user"
    }

    private var meee2UserInitials: String {
        let parts = meee2DisplayName
            .split { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" || $0 == "@" }
        let initials = parts.prefix(2).compactMap { $0.first?.uppercased() }.joined()
        return initials.isEmpty ? "U" : initials
    }

    @ViewBuilder
    private var meee2UserAvatar: some View {
        if let url = URL(string: meee2UserAvatarUrl), !meee2UserAvatarUrl.isEmpty {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Text(meee2UserInitials)
                    .font(.caption.bold())
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
        } else {
            Text(meee2UserInitials)
                .font(.caption.bold())
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.18))
                .clipShape(Circle())
        }
    }

    private var meee2SyncSessions: [PluginSession] {
        pluginManager.sessions.sorted {
            if $0.pluginId != $1.pluginId {
                return $0.pluginId < $1.pluginId
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func isMeee2OnlineSessionEnabled(_ sessionId: String) -> Bool {
        let aliases = Meee2OnlinePusher.sessionIdAliases(sessionId)
        let disabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds")
        if !aliases.isDisjoint(with: disabled) {
            return false
        }

        if meee2Online {
            return true
        }

        let enabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds")
        return !aliases.isDisjoint(with: enabled)
    }

    private func setMeee2OnlineSession(_ sessionId: String, enabled: Bool) {
        var disabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2DisabledSessionIds")
        var explicitlyEnabled = Meee2OnlinePusher.sessionIdSet(forKey: "meee2EnabledSessionIds")
        let aliases = Meee2OnlinePusher.sessionIdAliases(sessionId)

        if enabled {
            disabled.subtract(aliases)
            explicitlyEnabled.formUnion(aliases)
        } else {
            disabled.formUnion(aliases)
            explicitlyEnabled.subtract(aliases)
        }

        Meee2OnlinePusher.storeSessionIdSet(disabled, forKey: "meee2DisabledSessionIds")
        Meee2OnlinePusher.storeSessionIdSet(explicitlyEnabled, forKey: "meee2EnabledSessionIds")
        meee2DisabledSessionIdsData = UserDefaults.standard.data(forKey: "meee2DisabledSessionIds") ?? Data()
        meee2EnabledSessionIdsData = UserDefaults.standard.data(forKey: "meee2EnabledSessionIds") ?? Data()
        writeMeee2OnlineSettings()
        Meee2OnlinePusher.shared.refreshActivation()
    }

    private var meee2Teams: [Meee2OnlineTeam] {
        if let teams = try? JSONDecoder().decode([Meee2OnlineTeam].self, from: meee2TeamsData),
           let first = teams.first {
            return [first]
        }
        if !meee2TeamId.isEmpty {
            return [Meee2OnlineTeam(id: meee2TeamId, name: meee2TeamName.isEmpty ? "Default team" : meee2TeamName, role: nil)]
        }
        return []
    }

    private func storeMeee2OnlineTeams(_ teams: [Meee2OnlineTeam]) {
        let singleTeam = Array(teams.prefix(1))
        guard let data = try? JSONEncoder().encode(singleTeam) else { return }
        meee2TeamsData = data
        UserDefaults.standard.set(data, forKey: "meee2Teams")
        if let first = singleTeam.first {
            meee2TeamId = first.id
            meee2TeamName = first.name
        }
        writeMeee2OnlineSettings()
    }

    private var meee2DefaultTeamDisplayName: String {
        if let team = meee2Teams.first {
            return team.name
        }
        return meee2TeamName
    }

    private func meee2SessionSyncBinding(for sessionId: String) -> Binding<Bool> {
        Binding(
            get: { isMeee2OnlineSessionEnabled(sessionId) },
            set: { setMeee2OnlineSession(sessionId, enabled: $0) }
        )
    }

    @ViewBuilder
    private func meee2SessionSyncRow(_ session: PluginSession) -> some View {
        let plugin = pluginManager.getPluginInfo(for: session.pluginId)
        let syncing = isMeee2OnlineSessionEnabled(session.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(plugin?.displayName ?? session.pluginId)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(syncing ? "Syncing" : "No sync")
                    .font(.caption2.bold())
                    .foregroundColor(syncing ? .green : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(syncing ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                    )
            }

            Text(meee2SessionSubtitle(session))
                .font(.caption)
                .foregroundColor(syncing ? .secondary : .secondary.opacity(0.7))
                .lineLimit(1)
        }
    }

    private func meee2SessionRowBackground(_ session: PluginSession) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isMeee2OnlineSessionEnabled(session.id) ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06))
    }

    private func meee2SessionSubtitle(_ session: PluginSession) -> String {
        if let subtitle = session.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if let cwd = session.cwd, !cwd.isEmpty {
            return cwd
        }
        return "\(session.status.rawValue) · \(session.id.prefix(8))"
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
        .meee2SettingsForm()
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

    @ObservedObject private var versionChecker = VersionChecker.shared

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

                        // 触发 Sparkle install flow —— 不再走 GitHub 网页手动下载。
                        // AppDelegate 接到这条通知会优先消费已经 staged 的包;
                        // 没有 staged 包或 staged 已过时则跑 user-initiated
                        // checkForUpdates 下载、验签并重启。
                        Button("Install Update…") {
                            NotificationCenter.default.post(
                                name: Notification.Name("meee2.checkForUpdates"),
                                object: nil
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                // "Check for Updates" 同时干两件事：
                //   1. 跑自己的 appcast 拉取，刷 Settings 的 Current/Latest 显示
                //   2. 发通知让 AppDelegate 走同一套 Sparkle staged/fresh-check
                //      安装分支。
                // 数据源（appcast.xml）是一份的，这里只是把"显示新版本号"
                // 跟"真去装"两个动作合到一个按钮上。
                Button("Check for Updates") {
                    Task { await versionChecker.checkForUpdate() }
                    NotificationCenter.default.post(
                        name: Notification.Name("meee2.checkForUpdates"),
                        object: nil
                    )
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
        .meee2SettingsForm()
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
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SettingsTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SettingsTheme.cardBorder, lineWidth: 1)
        )
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
        PluginManager.shared.setPluginEnabled(plugin.pluginId, enabled: enabled)
        NSLog("[Settings] \(enabled ? "Enabled" : "Disabled") plugin: \(plugin.pluginId)")
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
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SettingsTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SettingsTheme.cardBorder, lineWidth: 1)
        )
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

// MARK: - Meee2Online Connection Result

struct Meee2OnlineConnectResult: Codable {
    let team: Meee2OnlineTeam
    let teams: [Meee2OnlineTeam]?
    let user: Meee2OnlineUser
    let supabase_url: String
    let supabase_key: String
}

struct Meee2OnlineTeam: Codable, Identifiable {
    let id: String
    let name: String
    let role: String?
}

struct Meee2OnlineUser: Codable {
    let id: String
    let email: String?
    let name: String?
    let avatar_url: String?
}

// MARK: - Notification Name

public extension Notification.Name {
    static let screenSelectionChanged = Notification.Name("screenSelectionChanged")
    static let islandVisibilityChanged = Notification.Name("islandVisibilityChanged")
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

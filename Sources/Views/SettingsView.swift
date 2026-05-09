import SwiftUI
import Meee2PluginKit

/// 设置面板视图
public struct SettingsView: View {
    private static let meee360NoSyncTarget = "__meee360_no_sync__"

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

    /// Teams available for per-session routing
    @AppStorage("meee360Teams") private var meee360TeamsData: Data = Data()

    /// Per-session team routing. Empty/default means use the first connected team.
    @AppStorage("meee360SessionTeamIds") private var meee360SessionTeamIdsData: Data = Data()

    /// User ID
    @AppStorage("meee360UserId") private var meee360UserId: String = ""

    /// Connected meee360 user profile
    @AppStorage("meee360UserName") private var meee360UserName: String = ""
    @AppStorage("meee360UserEmail") private var meee360UserEmail: String = ""
    @AppStorage("meee360UserAvatarUrl") private var meee360UserAvatarUrl: String = ""

    /// Per-session sync controls. Empty means no sessions have been disabled.
    @AppStorage("meee360DisabledSessionIds") private var meee360DisabledSessionIdsData: Data = Data()

    /// Per-session opt-in controls used when default meee360 sync is off.
    @AppStorage("meee360EnabledSessionIds") private var meee360EnabledSessionIdsData: Data = Data()

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
        .onChange(of: meee360Connected) { _ in updateMeee360SyncActivation() }
        .onChange(of: meee360Online) { _ in updateMeee360SyncActivation() }
        .onChange(of: meee360SupabaseUrl) { _ in writeMeee360Settings() }
        .onChange(of: meee360SupabaseKey) { _ in writeMeee360Settings() }
        .onChange(of: meee360TeamId) { _ in writeMeee360Settings() }
        .onChange(of: meee360UserId) { _ in writeMeee360Settings() }
        .onChange(of: meee360EnabledSessionIdsData) { _ in updateMeee360SyncActivation() }
        .onChange(of: meee360DisabledSessionIdsData) { _ in updateMeee360SyncActivation() }
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
                    HStack {
                        meee360UserAvatar
                        VStack(alignment: .leading) {
                            Text(meee360DisplayName)
                                .font(.headline)
                            Text(meee360UserEmail.isEmpty ? "Connected to meee360" : meee360UserEmail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }

                    HStack {
                        Button("Open Dashboard") {
                            NSWorkspace.shared.open(Meee360Config.appURL(path: "dashboard"))
                        }
                        Spacer()
                        Button("Disconnect") {
                            disconnectMeee360()
                        }
                    }

                    Toggle("Sync to meee360 by default", isOn: $meee360Online)

                    Text(meee360Online
                         ? "New sessions sync to the default team unless you set a row to No sync."
                         : "Default is No sync. Pick a team on any row to sync only that session.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if meee360SyncSessions.isEmpty {
                        Text("No local sessions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(meee360SyncSessions) { session in
                            HStack(alignment: .center, spacing: 12) {
                                meee360SessionSyncRow(session)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Picker("Sync target", selection: meee360SyncTargetBinding(for: session.id)) {
                                    Text("No sync").tag(Self.meee360NoSyncTarget)
                                    ForEach(meee360Teams) { team in
                                        Text(team.name).tag(team.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 180, alignment: .trailing)
                            }
                            .padding(8)
                            .background(meee360SessionRowBackground(session))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(isMeee360SessionEnabled(session.id) ? Color.green : Color.secondary.opacity(0.45))
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
                    Button("Connect to meee360") {
                        var components = URLComponents(url: Meee360Config.appURL(path: "connect"), resolvingAgainstBaseURL: false)!
                        components.queryItems = [
                            URLQueryItem(name: "callback", value: "\(BoardServer.shared.url)/meee360/callback")
                        ]
                        if let connectUrl = components.url {
                            NSWorkspace.shared.open(connectUrl)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Click to open browser, login to meee360, and automatically connect.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("Choose the exact local sessions that are visible in your meee360 dashboard.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("meee360.connected")).receive(on: RunLoop.main)) { notification in
            // Handle callback from browser
            if let userInfo = notification.userInfo {
                meee360Connected = true
                meee360TeamId = userInfo["teamId"] as? String ?? ""
                meee360TeamName = userInfo["teamName"] as? String ?? ""
                meee360UserId = userInfo["userId"] as? String ?? ""
                meee360UserName = userInfo["userName"] as? String ?? ""
                meee360UserEmail = userInfo["userEmail"] as? String ?? ""
                meee360UserAvatarUrl = userInfo["userAvatarUrl"] as? String ?? ""
                meee360SupabaseUrl = normalizedMeee360SupabaseUrl(userInfo["supabaseUrl"] as? String ?? "")
                meee360SupabaseKey = userInfo["supabaseKey"] as? String ?? ""
                if let teamsData = userInfo["teamsData"] as? Data {
                    meee360TeamsData = teamsData
                }
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
                meee360UserName = result.user.name ?? ""
                meee360UserEmail = result.user.email ?? ""
                meee360UserAvatarUrl = result.user.avatar_url ?? ""
                meee360SupabaseUrl = normalizedMeee360SupabaseUrl(result.supabase_url)
                meee360SupabaseKey = result.supabase_key
                storeMeee360Teams(result.teams ?? [result.team])
                meee360Online = true
                updateMeee360SyncActivation()

                connectionCode = ""
                showAlert(title: "Connected!", message: "Successfully connected to \(result.team.name)")
            } catch {
                showAlert(title: "Connection Failed", message: error.localizedDescription)
            }

            verifyingCode = false
        }
    }

    private func verifyCode(code: String) async throws -> Meee360ConnectResult {
        let endpoint = Meee360Config.appURL(path: "api/v1/connect")
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
        meee360UserName = ""
        meee360UserEmail = ""
        meee360UserAvatarUrl = ""
        meee360SupabaseUrl = ""
        meee360SupabaseKey = ""
        meee360TeamsData = Data()
        meee360SessionTeamIdsData = Data()
        meee360EnabledSessionIdsData = Data()
        meee360DisabledSessionIdsData = Data()
        updateMeee360SyncActivation()
    }

    private var meee360DashboardUrl: URL? {
        guard !meee360SupabaseUrl.isEmpty else { return nil }
        // Extract project ref from Supabase URL for dashboard link
        // URL format: https://xxx.supabase.co -> dashboard at meee360 app
        return Meee360Config.appURL(path: "dashboard")
    }

    private func testMeee360Connection() {
        guard !meee360SupabaseUrl.isEmpty,
              !meee360SupabaseKey.isEmpty,
              !meee360TeamId.isEmpty,
              !meee360UserId.isEmpty else {
            showAlert(title: "Missing Configuration", message: "Please fill in all required fields.")
            return
        }

        let url = normalizedMeee360SupabaseUrl(meee360SupabaseUrl)
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
        let normalizedSupabaseUrl = normalizedMeee360SupabaseUrl(meee360SupabaseUrl)

        let settings: [String: Any] = [
            "meee360": [
                "enabled": meee360Connected,
                "online": meee360Online,
                "supabaseUrl": normalizedSupabaseUrl,
                "supabaseKey": meee360SupabaseKey,
                "teamId": meee360TeamId,
                "userId": meee360UserId,
                "userName": meee360UserName,
                "userEmail": meee360UserEmail,
                "userAvatarUrl": meee360UserAvatarUrl,
                "teams": meee360Teams.map { team in
                    [
                        "id": team.id,
                        "name": team.name,
                        "role": team.role ?? ""
                    ]
                },
                "sessionTeamIds": meee360SessionTeamMap(),
                "defaultSyncEnabled": meee360Online,
                "enabledSessionIds": Array(Meee360Pusher.sessionIdSet(forKey: "meee360EnabledSessionIds")),
                "disabledSessionIds": Array(Meee360Pusher.sessionIdSet(forKey: "meee360DisabledSessionIds")),
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

    private func updateMeee360SyncActivation() {
        writeMeee360Settings()
        Meee360Pusher.shared.refreshActivation()
    }

    private func normalizedMeee360SupabaseUrl(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var meee360DisplayName: String {
        if !meee360UserName.isEmpty { return meee360UserName }
        if !meee360UserEmail.isEmpty { return meee360UserEmail.components(separatedBy: "@").first ?? meee360UserEmail }
        return "meee360 user"
    }

    private var meee360UserInitials: String {
        let parts = meee360DisplayName
            .split { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" || $0 == "@" }
        let initials = parts.prefix(2).compactMap { $0.first?.uppercased() }.joined()
        return initials.isEmpty ? "U" : initials
    }

    @ViewBuilder
    private var meee360UserAvatar: some View {
        if let url = URL(string: meee360UserAvatarUrl), !meee360UserAvatarUrl.isEmpty {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Text(meee360UserInitials)
                    .font(.caption.bold())
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
        } else {
            Text(meee360UserInitials)
                .font(.caption.bold())
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.18))
                .clipShape(Circle())
        }
    }

    private var meee360SyncSessions: [PluginSession] {
        pluginManager.sessions.sorted {
            if $0.pluginId != $1.pluginId {
                return $0.pluginId < $1.pluginId
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func isMeee360SessionEnabled(_ sessionId: String) -> Bool {
        let aliases = Meee360Pusher.sessionIdAliases(sessionId)
        let disabled = Meee360Pusher.sessionIdSet(forKey: "meee360DisabledSessionIds")
        if !aliases.isDisjoint(with: disabled) {
            return false
        }

        if meee360Online {
            return true
        }

        let enabled = Meee360Pusher.sessionIdSet(forKey: "meee360EnabledSessionIds")
        return !aliases.isDisjoint(with: enabled)
    }

    private func setMeee360Session(_ sessionId: String, enabled: Bool) {
        var disabled = Meee360Pusher.sessionIdSet(forKey: "meee360DisabledSessionIds")
        var explicitlyEnabled = Meee360Pusher.sessionIdSet(forKey: "meee360EnabledSessionIds")
        let aliases = Meee360Pusher.sessionIdAliases(sessionId)

        if enabled {
            disabled.subtract(aliases)
            explicitlyEnabled.formUnion(aliases)
        } else {
            disabled.formUnion(aliases)
            explicitlyEnabled.subtract(aliases)
        }

        Meee360Pusher.storeSessionIdSet(disabled, forKey: "meee360DisabledSessionIds")
        Meee360Pusher.storeSessionIdSet(explicitlyEnabled, forKey: "meee360EnabledSessionIds")
        meee360DisabledSessionIdsData = UserDefaults.standard.data(forKey: "meee360DisabledSessionIds") ?? Data()
        meee360EnabledSessionIdsData = UserDefaults.standard.data(forKey: "meee360EnabledSessionIds") ?? Data()
        writeMeee360Settings()
        Meee360Pusher.shared.refreshActivation()
    }

    private var meee360Teams: [Meee360Team] {
        if let teams = try? JSONDecoder().decode([Meee360Team].self, from: meee360TeamsData),
           !teams.isEmpty {
            return teams
        }
        if !meee360TeamId.isEmpty {
            return [Meee360Team(id: meee360TeamId, name: meee360TeamName.isEmpty ? "Default team" : meee360TeamName, role: nil)]
        }
        return []
    }

    private func storeMeee360Teams(_ teams: [Meee360Team]) {
        guard let data = try? JSONEncoder().encode(teams) else { return }
        meee360TeamsData = data
        UserDefaults.standard.set(data, forKey: "meee360Teams")
        writeMeee360Settings()
    }

    private func meee360SessionTeamMap() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: meee360SessionTeamIdsData)) ?? [:]
    }

    private func selectedMeee360TeamId(for sessionId: String) -> String {
        let teams = meee360Teams
        let fallback = teams.first?.id ?? meee360TeamId
        let map = meee360SessionTeamMap()
        for alias in Meee360Pusher.sessionIdAliases(sessionId) {
            if let teamId = map[alias], teams.contains(where: { $0.id == teamId }) {
                return teamId
            }
        }
        return fallback
    }

    private func setMeee360Team(_ teamId: String, for sessionId: String) {
        var map = meee360SessionTeamMap()
        for alias in Meee360Pusher.sessionIdAliases(sessionId) {
            map[alias] = teamId
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        meee360SessionTeamIdsData = data
        UserDefaults.standard.set(data, forKey: "meee360SessionTeamIds")
        writeMeee360Settings()
        Meee360Pusher.shared.refreshActivation()
    }

    private func selectedMeee360SyncTarget(for sessionId: String) -> String {
        guard isMeee360SessionEnabled(sessionId) else {
            return Self.meee360NoSyncTarget
        }
        return selectedMeee360TeamId(for: sessionId)
    }

    private func setMeee360SyncTarget(_ target: String, for sessionId: String) {
        if target == Self.meee360NoSyncTarget {
            setMeee360Session(sessionId, enabled: false)
            return
        }

        setMeee360Session(sessionId, enabled: true)
        setMeee360Team(target, for: sessionId)
    }

    private func meee360SyncTargetBinding(for sessionId: String) -> Binding<String> {
        Binding(
            get: { selectedMeee360SyncTarget(for: sessionId) },
            set: { setMeee360SyncTarget($0, for: sessionId) }
        )
    }

    @ViewBuilder
    private func meee360SessionSyncRow(_ session: PluginSession) -> some View {
        let plugin = pluginManager.getPluginInfo(for: session.pluginId)
        let syncing = isMeee360SessionEnabled(session.id)
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

            Text(meee360SessionSubtitle(session))
                .font(.caption)
                .foregroundColor(syncing ? .secondary : .secondary.opacity(0.7))
                .lineLimit(1)
        }
    }

    private func meee360SessionRowBackground(_ session: PluginSession) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isMeee360SessionEnabled(session.id) ? Color.green.opacity(0.08) : Color.secondary.opacity(0.06))
    }

    private func meee360SessionSubtitle(_ session: PluginSession) -> String {
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

                        // 触发 Sparkle modal —— 不再走 GitHub 网页手动下载。
                        // AppDelegate 接到这条通知会调
                        // SPUStandardUpdaterController.checkForUpdates,弹
                        // "Install / Skip / Remind" 对话框,用户点 Install
                        // 后 Sparkle 自动 download → verify EdDSA → relaunch。
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
                //   2. 发通知让 AppDelegate 调 SPUStandardUpdaterController 起
                //      Sparkle 的标准 modal flow（找到新版 → Install/Skip/Later
                //      用户对话框 → 下载 → 重启）。
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
    let teams: [Meee360Team]?
    let user: Meee360User
    let supabase_url: String
    let supabase_key: String
}

struct Meee360Team: Codable, Identifiable {
    let id: String
    let name: String
    let role: String?
}

struct Meee360User: Codable {
    let id: String
    let email: String?
    let name: String?
    let avatar_url: String?
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

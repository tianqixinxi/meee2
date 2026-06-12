import Foundation

/// OnlineProxy — synchronous-ish helper to forward a single HTTP call from the
/// local desktop BoardServer up to meee2-online (Supabase RPC for `rpc/...`
/// names, or the Next.js API surface for relative `path` strings).
///
/// Credential model (single source of truth):
///
///   - `~/.meee2/settings.json` is the ONLY persisted home for
///     accessToken / refreshToken. Every binary form of the app (bundled
///     `com.meee2.app`, SwiftPM debug binary whose `UserDefaults.standard`
///     lands in the `meee2` domain, CLI) reads the same file, so a re-login
///     in one form is immediately visible to all of them.
///   - UserDefaults never stores tokens. 历史版本曾把 token 写进偏好域，
///     bundled app 和 debug 二进制落在不同 domain，重新登录后另一形态仍
///     发旧 token，触发 Supabase refresh-token reuse-detection 吊销整个
///     token family —— 这里只读 env override + settings.json。
///   - Non-token connection fields (teamId, supabaseUrl, …) prefer
///     settings.json too; UserDefaults is a legacy fallback only.
///
/// Refresh model: Supabase rotates the refresh token on every use and
/// revokes the whole family on reuse, so refresh MUST be single-flight —
/// in-process via NSLock AND machine-wide via flock on settings.json.lock
/// (multiple app forms can run concurrently) — see `refreshAccessToken(stale:)`.
enum OnlineProxy {
    enum ProxyError: Error {
        case missingSettings(String)
        case badURL
        case transport(Error)
        case http(status: Int, body: Data)
    }

    struct Settings {
        let supabaseUrl: String
        let supabaseKey: String
        let onlineBaseUrl: String
        let accessToken: String
        let refreshToken: String
        let teamId: String
        let userId: String
        /// 服务端已吊销本地凭证（refresh 401/AUTH_INVALID 后置位）。
        /// 置位期间所有 online 调用直接短路，UI 进入「需要重新登录」态。
        let authExpired: Bool
    }

    static let authExpiredNotification = Notification.Name("meee2.authExpired")

    // MARK: - Test seams

    /// 单测注入：替换 settings.json 路径，避免测试碰真实用户配置。
    static var settingsFileURLOverride: URL?
    /// 单测注入：替换 UserDefaults，避免测试污染真实偏好域。
    static var userDefaultsOverride: UserDefaults?
    /// 单测注入:替换 refresh 的网络层(默认 performSync),用于断言 single-flight。
    static var refreshTransportOverride: ((URLRequest) -> Result<Data, ProxyError>)?

    static func resetRefreshStateForTesting() {
        refreshLock.lock()
        lastRefreshFailureAt = nil
        refreshLock.unlock()
    }

    private static var defaults: UserDefaults {
        userDefaultsOverride ?? .standard
    }

    static var hasEnvironmentOverride: Bool {
        let env = ProcessInfo.processInfo.environment
        return [
            "MEEE2_SUPABASE_URL",
            "MEEE2_SUPABASE_ANON_KEY",
            "MEEE2_ONLINE_BASE_URL",
            "MEEE2_ONLINE_ACCESS_TOKEN",
            "MEEE2_ONLINE_REFRESH_TOKEN",
            "MEEE2_ONLINE_TEAM_ID",
            "MEEE2_ONLINE_USER_ID"
        ].contains { key in
            !(env[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    static func loadSettings() -> Settings {
        let env = ProcessInfo.processInfo.environment
        let file = fileMeee2Dict()

        func fileString(_ key: String) -> String? {
            file[key] as? String
        }

        let supabaseUrl = firstNonEmpty(
            env["MEEE2_SUPABASE_URL"],
            fileString("supabaseUrl"),
            defaults.string(forKey: "meee2SupabaseUrl")
        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let supabaseKey = firstNonEmpty(
            env["MEEE2_SUPABASE_ANON_KEY"],
            fileString("supabaseKey"),
            defaults.string(forKey: "meee2SupabaseKey")
        )
        let onlineBaseUrl = firstNonEmpty(
            env["MEEE2_ONLINE_BASE_URL"],
            fileString("onlineBaseUrl"),
            defaults.string(forKey: "meee2OnlineBaseUrl")
        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Token 字段绝不读 UserDefaults：偏好域按二进制形态分裂
        // (com.meee2.app / meee2)，里面的副本可能属于已被吊销的 token family。
        let accessToken = firstNonEmpty(
            env["MEEE2_ONLINE_ACCESS_TOKEN"],
            fileString("accessToken")
        )
        let refreshToken = firstNonEmpty(
            env["MEEE2_ONLINE_REFRESH_TOKEN"],
            fileString("refreshToken")
        )
        let teamId = firstNonEmpty(
            env["MEEE2_ONLINE_TEAM_ID"],
            fileString("teamId"),
            defaults.string(forKey: "meee2TeamId")
        )
        let userId = firstNonEmpty(
            env["MEEE2_ONLINE_USER_ID"],
            fileString("userId"),
            defaults.string(forKey: "meee2UserId")
        )
        let envHasAccessToken = !firstNonEmpty(env["MEEE2_ONLINE_ACCESS_TOKEN"]).isEmpty
        let authExpired = !envHasAccessToken && (file["authExpired"] as? Bool ?? false)

        return Settings(
            supabaseUrl: supabaseUrl,
            supabaseKey: supabaseKey,
            onlineBaseUrl: onlineBaseUrl,
            accessToken: accessToken,
            refreshToken: refreshToken,
            teamId: teamId,
            userId: userId,
            authExpired: authExpired
        )
    }

    /// settings.json 里当前的凭证状态。settings.json 的其他写入方
    /// (SettingsView / BoardAPI) 重写整个文件时必须用它保留 token，
    /// 而不是把各自偏好域里的旧副本反写回来。
    static func persistedCredentialState() -> (accessToken: String, refreshToken: String, authExpired: Bool) {
        let file = fileMeee2Dict()
        return (
            accessToken: (file["accessToken"] as? String) ?? "",
            refreshToken: (file["refreshToken"] as? String) ?? "",
            authExpired: (file["authExpired"] as? Bool) ?? false
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    /// Forward to a Supabase RPC. Body is the raw payload (will be serialized
    /// as JSON). Synchronous (uses a semaphore) because BoardAPI handlers are
    /// blocking — request timeout 30s.
    static func callRPC(
        name: String,
        payload: [String: Any],
        settings: Settings? = nil
    ) -> Result<Data, ProxyError> {
        let s = settings ?? loadSettings()
        guard !s.supabaseUrl.isEmpty else { return .failure(.missingSettings("supabaseUrl")) }
        guard !s.supabaseKey.isEmpty else { return .failure(.missingSettings("supabaseKey")) }
        guard let url = URL(string: "\(s.supabaseUrl)/rest/v1/rpc/\(name)") else {
            return .failure(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(s.supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(s.supabaseKey)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .failure(.transport(error))
        }
        return performSync(request: request)
    }

    /// Forward to a meee2-online API path (e.g. "/api/v1/artifact-versions").
    /// Method may be GET/POST/etc. Query as URLQueryItems, body as Data.
    static func callOnlineAPI(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: Data? = nil,
        settings: Settings? = nil
    ) -> Result<Data, ProxyError> {
        let s = settings ?? loadSettings()
        if s.authExpired {
            // 凭证已被吊销:不再发注定 401 的请求,并让本进程 UI 落到重新登录态
            noteAuthExpiredLocally()
            return .failure(.missingSettings("meee2 online auth expired — reconnect required"))
        }
        let baseURL = URL(string: s.onlineBaseUrl) ?? Meee2OnlineConfig.appBaseURL
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        )
        if let query, !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else { return .failure(.badURL) }
        let request = onlineRequest(url: url, method: method, body: body, settings: s)
        let result = performSync(request: request)
        if case .failure(.http(status: 401, body: _)) = result,
           !s.refreshToken.isEmpty,
           let refreshed = refreshAccessToken(stale: s) {
            return performSync(request: onlineRequest(url: url, method: method, body: body, settings: refreshed))
        }
        return result
    }

    private static func onlineRequest(url: URL, method: String, body: Data?, settings: Settings) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.accessToken.isEmpty {
            request.setValue("Bearer \(settings.accessToken)", forHTTPHeaderField: "Authorization")
        } else if !settings.supabaseKey.isEmpty {
            request.setValue("Bearer \(settings.supabaseKey)", forHTTPHeaderField: "Authorization")
            request.setValue(settings.supabaseKey, forHTTPHeaderField: "apikey")
        }
        request.httpBody = body
        return request
    }

    // MARK: - Token refresh (single-flight)

    private static let refreshLock = NSLock()
    private static var lastRefreshFailureAt: Date?
    /// 刷新失败后的冷却窗口：避免一批并发 401 在失败后排队逐个重打 refresh 端点。
    private static let refreshFailureCooldownSeconds: TimeInterval = 15

    /// 用 refresh token 换新 access token。
    ///
    /// Single-flight：Supabase 每次刷新都轮换 refresh token，并在检测到旧
    /// token 复用时吊销整个 token family。access token 过期瞬间 app 内多个
    /// 并发请求会同时拿到 401 —— 若各自刷新，第二个请求就构成 reuse，所有
    /// 副本全部 AUTH_INVALID（2026-06-12 实测）。因此同一时刻只允许一个
    /// 刷新在飞，分两层：
    ///
    ///   - 进程内 `NSLock`：第一个 401 持锁刷新，其余阻塞等锁；
    ///   - 跨进程 `flock(settings.json.lock)`：bundled app / debug 二进制 /
    ///     CLI 可能同时在跑且共享 settings.json，文件锁保证全机器单飞。
    ///
    /// 等到锁后先 double-check settings.json —— 凭证已被（本进程其它线程
    /// 或另一个进程）轮换则直接复用，不再发起第二次刷新。
    static func refreshAccessToken(stale: Settings) -> Settings? {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        return withCrossProcessRefreshLock {
            refreshHoldingLocks(stale: stale)
        }
    }

    /// 围绕共享凭证文件的跨进程互斥。锁文件建不出来 / flock 失败时退化为
    /// 仅进程内互斥（比拒绝刷新好——单进程场景本就不需要文件锁）。
    private static func withCrossProcessRefreshLock<T>(_ body: () -> T) -> T {
        let lockURL = settingsFileURL().appendingPathExtension("lock")
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockURL.path, O_CREAT | O_WRONLY, 0o600)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return body() }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private static func refreshHoldingLocks(stale: Settings) -> Settings? {
        // Double-check（锁内）：等锁期间本进程其它线程或另一个进程可能已
        // 刷新成功并落盘
        let current = loadSettings()
        if !current.accessToken.isEmpty, current.accessToken != stale.accessToken {
            MInfo("[OnlineProxy] refresh reused — token already rotated by a concurrent request")
            return current
        }
        if current.authExpired || current.refreshToken.isEmpty {
            return nil
        }
        if let failedAt = lastRefreshFailureAt,
           Date().timeIntervalSince(failedAt) < refreshFailureCooldownSeconds {
            return nil
        }

        let baseURL = URL(string: current.onlineBaseUrl) ?? Meee2OnlineConfig.appBaseURL
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("connect")
            .appendingPathComponent("refresh")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "refreshToken": current.refreshToken
        ])

        let result = refreshTransportOverride?(request) ?? performSync(request: request)
        switch result {
        case .success(let body):
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
                MWarn("[OnlineProxy] refresh returned 2xx but no access_token")
                lastRefreshFailureAt = Date()
                return nil
            }
            if let superseded = settingsIfRefreshTokenSuperseded(requestToken: current.refreshToken) {
                // 等待网络期间用户已重新登录（登录路径不持文件锁），文件里
                // 已是更新的凭证 —— 丢弃本次刷新结果，以新登录为准
                MInfo("[OnlineProxy] refresh result discarded — credentials re-issued by a newer login")
                return superseded
            }
            let refreshToken = (object["refresh_token"] as? String) ?? current.refreshToken
            persistTokens(accessToken: accessToken, refreshToken: refreshToken)
            lastRefreshFailureAt = nil
            MInfo("[OnlineProxy] refresh ok — rotated token persisted to settings.json")
            return Settings(
                supabaseUrl: current.supabaseUrl,
                supabaseKey: current.supabaseKey,
                onlineBaseUrl: current.onlineBaseUrl,
                accessToken: accessToken,
                refreshToken: refreshToken,
                teamId: current.teamId,
                userId: current.userId,
                authExpired: false
            )
        case .failure(.http(let status, _)) where status == 401 || status == 403:
            if let superseded = settingsIfRefreshTokenSuperseded(requestToken: current.refreshToken) {
                // 被拒的是发起请求时那枚旧 token；等待期间用户已重新登录，
                // 文件里的新凭证不能被它连坐清掉
                MInfo("[OnlineProxy] stale refresh rejected (\(status)) — newer login credentials present, keeping them")
                return superseded
            }
            // AUTH_INVALID:refresh token 已被吊销,本地凭证作废。清掉并显式
            // 进入「需要重新登录」态,而不是让 app 顶着旧凭证持续 401。
            MWarn("[OnlineProxy] refresh rejected (\(status)) — credentials revoked, reconnect required")
            markAuthExpired()
            lastRefreshFailureAt = Date()
            return nil
        case .failure(let error):
            // 网络抖动 / 5xx:凭证未必失效,保留并冷却后重试
            MWarn("[OnlineProxy] refresh failed (\(describeForLog(error))) — keeping credentials, cooldown \(Int(refreshFailureCooldownSeconds))s")
            lastRefreshFailureAt = Date()
            return nil
        }
    }

    /// 刷新等待网络期间凭证是否已被「别的来源」换掉（典型：用户重新登录，
    /// 登录路径不持 refresh 文件锁）。是则返回文件里的新凭证，刷新结果
    /// （无论成败）都应让位于它 —— 尤其 401 不能把新登录连坐清掉。
    private static func settingsIfRefreshTokenSuperseded(requestToken: String) -> Settings? {
        let latest = loadSettings()
        guard !latest.refreshToken.isEmpty,
              latest.refreshToken != requestToken,
              !latest.accessToken.isEmpty,
              !latest.authExpired else {
            return nil
        }
        return latest
    }

    /// 登录成功（浏览器回调之外的路径，如连接码验证）或刷新成功后落盘新凭证。
    /// settings.json 为唯一真相；同时清掉历史版本写进当前偏好域的 token 缓存。
    static func persistTokens(accessToken: String, refreshToken: String) {
        let file = settingsFileURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var meee2 = (root["meee2"] as? [String: Any]) ?? [:]
        meee2["accessToken"] = accessToken
        meee2["refreshToken"] = refreshToken
        meee2["authExpired"] = false
        root["meee2"] = meee2
        if JSONSerialization.isValidJSONObject(root),
           let nextData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? nextData.write(to: file, options: .atomic)
        }

        let d = defaults
        d.removeObject(forKey: "meee2OnlineAccessToken")
        d.removeObject(forKey: "meee2OnlineRefreshToken")
        d.removeObject(forKey: "meee2AuthExpired")
    }

    /// refresh 被服务端拒绝（token family 已吊销）：清 settings.json 里的
    /// token 并打上 authExpired。所有形态的二进制读同一份文件，下一次调用
    /// 都会短路到重新登录态，不再拿旧凭证去撞 reuse-detection。
    static func markAuthExpired() {
        let file = settingsFileURL()
        if let data = try? Data(contentsOf: file),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var meee2 = (root["meee2"] as? [String: Any]) ?? [:]
            meee2["accessToken"] = ""
            meee2["refreshToken"] = ""
            meee2["authExpired"] = true
            root["meee2"] = meee2
            if JSONSerialization.isValidJSONObject(root),
               let nextData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? nextData.write(to: file, options: .atomic)
            }
        }
        noteAuthExpiredLocally()
    }

    /// 当前进程域的过期收尾：清 token 缓存、退出「已连接」态、广播给 UI。
    /// settings.json 的 authExpired 由别的进程置位时，本进程第一次 online
    /// 调用的短路路径也会走到这里，让两种二进制形态的 UI 都收敛。
    static func noteAuthExpiredLocally() {
        let d = defaults
        d.removeObject(forKey: "meee2OnlineAccessToken")
        d.removeObject(forKey: "meee2OnlineRefreshToken")
        let alreadyNoted = d.bool(forKey: "meee2AuthExpired") && !d.bool(forKey: "meee2Connected")
        guard !alreadyNoted else { return }
        d.set(true, forKey: "meee2AuthExpired")
        d.set(false, forKey: "meee2Connected")
        NotificationCenter.default.post(name: authExpiredNotification, object: nil)
    }

    private static func describeForLog(_ error: ProxyError) -> String {
        switch error {
        case .missingSettings(let what): return "missingSettings(\(what))"
        case .badURL: return "badURL"
        case .transport(let underlying): return "transport(\(underlying.localizedDescription))"
        case .http(let status, _): return "http(\(status))"
        }
    }

    private static func fileMeee2Dict() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFileURL()),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meee2 = root["meee2"] as? [String: Any] else {
            return [:]
        }
        return meee2
    }

    private static func settingsFileURL() -> URL {
        settingsFileURLOverride ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".meee2/settings.json")
    }

    private static func performSync(request: URLRequest) -> Result<Data, ProxyError> {
        var outcome: Result<Data, ProxyError> = .failure(.transport(URLError(.unknown)))
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error {
                outcome = .failure(.transport(error))
                return
            }
            let body = data ?? Data()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                outcome = .success(body)
            } else {
                outcome = .failure(.http(status: status, body: body))
            }
        }.resume()
        _ = sema.wait(timeout: .now() + 35)
        return outcome
    }
}

import Foundation

/// OnlineProxy — synchronous-ish helper to forward a single HTTP call from the
/// local desktop BoardServer up to meee2-online (Supabase RPC for `rpc/...`
/// names, or the Next.js API surface for relative `path` strings). Reads the
/// supabase URL + anon key + teamId/userId from the same locations the
/// existing Meee2OnlinePusher uses:
///
///   1. UserDefaults (`meee2SupabaseUrl`, `meee2SupabaseKey`, `meee2TeamId`, `meee2UserId`)
///   2. Falls back to `~/.meee2/settings.json` under the `meee2` key
///
/// Used by the 3 wave-1-3 integration routes (UI-2 assignPlannerNode,
/// UI-2 fetchOwnedCanvases, UI-6 fetchRecentArtifactVersions) so we don't
/// reimplement settings/auth in each handler.
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
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        var supabaseUrl = firstNonEmpty(env["MEEE2_SUPABASE_URL"], defaults.string(forKey: "meee2SupabaseUrl"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var supabaseKey = firstNonEmpty(env["MEEE2_SUPABASE_ANON_KEY"], defaults.string(forKey: "meee2SupabaseKey"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var onlineBaseUrl = firstNonEmpty(env["MEEE2_ONLINE_BASE_URL"], defaults.string(forKey: "meee2OnlineBaseUrl"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var accessToken = firstNonEmpty(env["MEEE2_ONLINE_ACCESS_TOKEN"], defaults.string(forKey: "meee2OnlineAccessToken"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var refreshToken = firstNonEmpty(env["MEEE2_ONLINE_REFRESH_TOKEN"], defaults.string(forKey: "meee2OnlineRefreshToken"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var teamId = firstNonEmpty(env["MEEE2_ONLINE_TEAM_ID"], defaults.string(forKey: "meee2TeamId"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var userId = firstNonEmpty(env["MEEE2_ONLINE_USER_ID"], defaults.string(forKey: "meee2UserId"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if supabaseUrl.isEmpty || supabaseKey.isEmpty || onlineBaseUrl.isEmpty || accessToken.isEmpty || refreshToken.isEmpty || teamId.isEmpty || userId.isEmpty {
            let file = settingsFileURL()
            if let data = try? Data(contentsOf: file),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let meee2 = root["meee2"] as? [String: Any] {
                if supabaseUrl.isEmpty,
                   let v = (meee2["supabaseUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    supabaseUrl = v.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                if supabaseKey.isEmpty,
                   let v = (meee2["supabaseKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    supabaseKey = v
                }
                if onlineBaseUrl.isEmpty,
                   let v = (meee2["onlineBaseUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    onlineBaseUrl = v.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                if accessToken.isEmpty,
                   let v = (meee2["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    accessToken = v
                }
                if refreshToken.isEmpty,
                   let v = (meee2["refreshToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    refreshToken = v
                }
                if teamId.isEmpty,
                   let v = (meee2["teamId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    teamId = v
                }
                if userId.isEmpty,
                   let v = (meee2["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    userId = v
                }
            }
        }

        return Settings(
            supabaseUrl: supabaseUrl,
            supabaseKey: supabaseKey,
            onlineBaseUrl: onlineBaseUrl,
            accessToken: accessToken,
            refreshToken: refreshToken,
            teamId: teamId,
            userId: userId
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
           let refreshed = refreshAccessToken(settings: s) {
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

    private static func refreshAccessToken(settings: Settings) -> Settings? {
        let baseURL = URL(string: settings.onlineBaseUrl) ?? Meee2OnlineConfig.appBaseURL
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("connect")
            .appendingPathComponent("refresh")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "refreshToken": settings.refreshToken
        ])
        guard let body = try? performSync(request: request).get(),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            return nil
        }
        let refreshToken = (object["refresh_token"] as? String) ?? settings.refreshToken
        persistTokens(accessToken: accessToken, refreshToken: refreshToken)
        return Settings(
            supabaseUrl: settings.supabaseUrl,
            supabaseKey: settings.supabaseKey,
            onlineBaseUrl: settings.onlineBaseUrl,
            accessToken: accessToken,
            refreshToken: refreshToken,
            teamId: settings.teamId,
            userId: settings.userId
        )
    }

    private static func persistTokens(accessToken: String, refreshToken: String) {
        let defaults = UserDefaults.standard
        defaults.set(accessToken, forKey: "meee2OnlineAccessToken")
        defaults.set(refreshToken, forKey: "meee2OnlineRefreshToken")

        let file = settingsFileURL()
        guard let data = try? Data(contentsOf: file),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var meee2 = (root["meee2"] as? [String: Any]) ?? [:]
        meee2["accessToken"] = accessToken
        meee2["refreshToken"] = refreshToken
        root["meee2"] = meee2
        guard JSONSerialization.isValidJSONObject(root),
              let nextData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? nextData.write(to: file, options: .atomic)
    }

    private static func settingsFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
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

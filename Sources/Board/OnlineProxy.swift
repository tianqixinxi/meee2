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
        let teamId: String
        let userId: String
    }

    static func loadSettings() -> Settings {
        let defaults = UserDefaults.standard
        var supabaseUrl = (defaults.string(forKey: "meee2SupabaseUrl") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var supabaseKey = (defaults.string(forKey: "meee2SupabaseKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var teamId = (defaults.string(forKey: "meee2TeamId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var userId = (defaults.string(forKey: "meee2UserId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if supabaseUrl.isEmpty || supabaseKey.isEmpty || teamId.isEmpty || userId.isEmpty {
            let file = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".meee2/settings.json")
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
            teamId: teamId,
            userId: userId
        )
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
        let baseURL = Meee2OnlineConfig.appBaseURL
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        )
        if let query, !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else { return .failure(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Pass the anon key in both headers — the Next.js route uses it via
        // the same Supabase client.
        if !s.supabaseKey.isEmpty {
            request.setValue("Bearer \(s.supabaseKey)", forHTTPHeaderField: "Authorization")
            request.setValue(s.supabaseKey, forHTTPHeaderField: "apikey")
        }
        if let body { request.httpBody = body }
        return performSync(request: request)
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

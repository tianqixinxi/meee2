import Foundation
import Swifter
import CryptoKit
import Security

/// Launch-local CSRF state for the browser -> loopback callback.
///
/// State is deliberately memory-only, short-lived and one-shot. A callback can
/// therefore mutate local credentials only after the user initiated Connect in
/// this running meee2 process.
final class Meee2OnlineCallbackStateStore {
    static let shared = Meee2OnlineCallbackStateStore()

    enum ConsumptionError: Error, Equatable {
        case missing
        case invalidOrReplayed
        case expired
    }

    struct AuthorizationRequest: Equatable {
        let state: String
        let codeChallenge: String
    }

    private struct Entry {
        let token: String
        let codeVerifier: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let ttl: TimeInterval
    private let now: () -> Date
    private let makeToken: () -> String
    private let makeVerifier: () -> String
    private let maxEntries: Int
    private var entries: [Entry] = []

    init(
        ttl: TimeInterval = 5 * 60,
        maxEntries: Int = 16,
        now: @escaping () -> Date = Date.init,
        makeToken: @escaping () -> String = Meee2OnlineCallbackStateStore.randomURLSafeSecret,
        makeVerifier: @escaping () -> String = Meee2OnlineCallbackStateStore.randomURLSafeSecret
    ) {
        self.ttl = max(1, ttl)
        self.maxEntries = max(1, maxEntries)
        self.now = now
        self.makeToken = makeToken
        self.makeVerifier = makeVerifier
    }

    func issue() -> AuthorizationRequest {
        let issuedAt = now()
        let token = makeToken()
        let verifier = makeVerifier()
        let challenge = Self.pkceChallenge(for: verifier)
        lock.lock()
        entries.removeAll { $0.expiresAt < issuedAt }
        // A broken/randomness-injected token source must not leave two valid
        // entries for one value, which would turn the second entry into replay.
        entries.removeAll { $0.token == token }
        entries.append(Entry(
            token: token,
            codeVerifier: verifier,
            expiresAt: issuedAt.addingTimeInterval(ttl)
        ))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
        return AuthorizationRequest(state: token, codeChallenge: challenge)
    }

    func consume(_ rawState: String?) throws -> String {
        guard let state = rawState?.trimmingCharacters(in: .whitespacesAndNewlines),
              !state.isEmpty else {
            throw ConsumptionError.missing
        }

        let consumedAt = now()
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.token == state }) else {
            throw ConsumptionError.invalidOrReplayed
        }
        let entry = entries.remove(at: index)
        guard entry.expiresAt >= consumedAt else {
            throw ConsumptionError.expired
        }
        return entry.codeVerifier
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomURLSafeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "secure randomness unavailable")
        return Data(bytes).base64URLEncodedString()
    }
}

enum Meee2OnlineCodeExchangeError: Error, Equatable {
    case invalidCode
    case transport
    case rejected
    case invalidPayload
    case timedOut
}

/// Secure browser callback for Meee2 Online.
///
/// The legacy callback accepted account metadata and bearer/refresh tokens in
/// the query string. Besides leaking credentials into URL history, that made a
/// cross-site navigation to localhost a credential-writing mutation. The new
/// contract accepts only a one-time state plus a short-lived authorization
/// code, then exchanges that code with Meee2 Online over HTTPS.
public struct Meee2OnlineCallbackAPI {
    typealias CodeExchange = (String, String) -> Result<Meee2OnlineConnectResult, Meee2OnlineCodeExchangeError>
    typealias ConnectionPersist = (Meee2OnlineConnectResult) -> Bool

    private static let allowedCallbackQueryKeys: Set<String> = [
        "state", "code", "error", "error_description"
    ]

    static func issueConnectURL(
        boardURL: URL = URL(string: BoardServer.shared.url)!,
        stateStore: Meee2OnlineCallbackStateStore = .shared
    ) -> URL {
        let authorization = stateStore.issue()
        var callbackComponents = URLComponents(
            url: boardURL
                .appendingPathComponent("meee2", isDirectory: true)
                .appendingPathComponent("callback", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        callbackComponents.queryItems = [URLQueryItem(name: "state", value: authorization.state)]

        var connectComponents = URLComponents(
            url: Meee2OnlineConfig.appURL(path: "connect"),
            resolvingAgainstBaseURL: false
        )!
        connectComponents.queryItems = [
            URLQueryItem(name: "callback", value: callbackComponents.url!.absoluteString),
            // Send state separately as well as binding it into the callback URL.
            // Online implementations that support standard OAuth state can
            // round-trip it; duplicate identical state values are accepted.
            URLQueryItem(name: "state", value: authorization.state),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: authorization.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return connectComponents.url!
    }

    public static func handleCallback(request: HttpRequest) -> HttpResponse {
        handleCallback(
            request: request,
            stateStore: .shared,
            exchange: exchangeConnectionCode,
            persist: persistConnection
        )
    }

    static func handleCallback(
        request: HttpRequest,
        stateStore: Meee2OnlineCallbackStateStore,
        exchange: CodeExchange,
        persist: ConnectionPersist
    ) -> HttpResponse {
        let state = uniqueQueryValue("state", in: request)
        let codeVerifier: String
        do {
            codeVerifier = try stateStore.consume(state)
        } catch Meee2OnlineCallbackStateStore.ConsumptionError.missing {
            return errorResponse(
                message: "This connection was not initiated by the running meee2 app.",
                status: 403,
                reason: "Forbidden"
            )
        } catch Meee2OnlineCallbackStateStore.ConsumptionError.expired {
            return errorResponse(
                message: "This connection request expired. Start Connect again from meee2 Settings.",
                status: 403,
                reason: "Forbidden"
            )
        } catch {
            return errorResponse(
                message: "This connection request is invalid or has already been used.",
                status: 403,
                reason: "Forbidden"
            )
        }

        // Fail closed if an older Online deployment tries to put credentials or
        // profile configuration back into the callback URL.
        let unexpectedKeys = Set(request.queryParams.map { $0.0.lowercased() })
            .subtracting(allowedCallbackQueryKeys)
        guard unexpectedKeys.isEmpty else {
            return errorResponse(
                message: "This Meee2 Online login flow is outdated. Update it to return an authorization code, then try again.",
                status: 400,
                reason: "Bad Request"
            )
        }

        if uniqueQueryValue("error", in: request) != nil {
            return errorResponse(
                message: "Authorization was not completed. Start Connect again from meee2 Settings.",
                status: 400,
                reason: "Bad Request"
            )
        }

        guard let code = uniqueQueryValue("code", in: request),
              !code.isEmpty,
              code.utf8.count <= 1_024 else {
            return errorResponse(
                message: "The secure authorization code is missing or invalid.",
                status: 400,
                reason: "Bad Request"
            )
        }

        let result: Meee2OnlineConnectResult
        switch exchange(code, codeVerifier) {
        case .success(let exchanged):
            result = exchanged
        case .failure:
            return errorResponse(
                message: "The secure authorization code could not be exchanged. Start Connect again from meee2 Settings.",
                status: 502,
                reason: "Bad Gateway"
            )
        }

        guard connectionResultIsComplete(result) else {
            return errorResponse(
                message: "Meee2 Online returned an incomplete connection response.",
                status: 502,
                reason: "Bad Gateway"
            )
        }
        guard persist(result) else {
            return errorResponse(
                message: "The secure connection could not be saved.",
                status: 500,
                reason: "Internal Server Error"
            )
        }
        return successResponse(teamName: result.team.name)
    }

    private static func uniqueQueryValue(_ key: String, in request: HttpRequest) -> String? {
        let values = request.queryParams
            .filter { $0.0.caseInsensitiveCompare(key) == .orderedSame }
            .map { raw -> String in
                let value = raw.1.replacingOccurrences(of: "+", with: " ")
                return value.removingPercentEncoding ?? value
            }
        guard let first = values.first,
              values.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func connectionResultIsComplete(_ result: Meee2OnlineConnectResult) -> Bool {
        !result.team.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !result.user.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !result.supabase_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !result.supabase_key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(result.access_token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func exchangeConnectionCode(
        _ code: String,
        codeVerifier: String
    ) -> Result<Meee2OnlineConnectResult, Meee2OnlineCodeExchangeError> {
        guard !code.isEmpty, code.utf8.count <= 1_024 else { return .failure(.invalidCode) }
        let endpoint = Meee2OnlineConfig.appURL(path: "api/v1/connect")
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONEncoder().encode([
                "code": code,
                "code_verifier": codeVerifier
            ])
        } catch {
            return .failure(.invalidCode)
        }

        let box = Meee2OnlineExchangeResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if error != nil {
                box.store(.failure(.transport))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                box.store(.failure(.rejected))
                return
            }
            guard let data,
                  data.count <= 2 * 1_024 * 1_024,
                  let result = try? JSONDecoder().decode(Meee2OnlineConnectResult.self, from: data) else {
                box.store(.failure(.invalidPayload))
                return
            }
            box.store(.success(result))
        }.resume()
        guard semaphore.wait(timeout: .now() + 20) == .success else {
            return .failure(.timedOut)
        }
        return box.load() ?? .failure(.transport)
    }

    private static func persistConnection(_ result: Meee2OnlineConnectResult) -> Bool {
        let rawTeams = (result.teams?.isEmpty == false ? result.teams : nil) ?? [result.team]
        let teams = rawTeams.map { team in
            [
                "id": team.id,
                "name": team.name.isEmpty ? team.id : team.name,
                "role": team.role ?? ""
            ]
        }
        let teamsData = jsonData(for: teams)
        let onlineBaseURL = result.online_base_url ?? ""
        let accessToken = result.access_token ?? ""
        let refreshToken = result.refresh_token ?? ""

        // The code exchange is the authorization boundary. Only after it has
        // succeeded may a stable machine id be generated or credentials stored.
        Meee2Identity.setApiUrlIfProvided(onlineBaseURL)
        let success = saveConfig(
            teamId: result.team.id,
            teamName: result.team.name,
            userId: result.user.id,
            userName: result.user.name ?? "",
            userEmail: result.user.email ?? "",
            userAvatarUrl: result.user.avatar_url ?? "",
            supabaseUrl: result.supabase_url,
            supabaseKey: result.supabase_key,
            onlineBaseUrl: onlineBaseURL,
            accessToken: accessToken,
            refreshToken: refreshToken,
            teams: teams,
            teamsData: teamsData
        )
        guard success else { return false }

        // No access/refresh token is copied into NotificationCenter. Settings
        // observes non-secret profile metadata; Keychain remains the sole source
        // of truth for credentials.
        var userInfo: [String: Any] = [
            "teamId": result.team.id,
            "teamName": result.team.name,
            "userId": result.user.id,
            "userName": result.user.name ?? "",
            "userEmail": result.user.email ?? "",
            "userAvatarUrl": result.user.avatar_url ?? "",
            "supabaseUrl": result.supabase_url,
            "onlineBaseUrl": onlineBaseURL
        ]
        if let teamsData { userInfo["teamsData"] = teamsData }
        NotificationCenter.default.post(
            name: Notification.Name("meee2.connected"),
            object: nil,
            userInfo: userInfo
        )
        Meee2OnlinePusher.shared.refreshActivation()
        return true
    }

    private static func saveConfig(
        teamId: String,
        teamName: String,
        userId: String,
        userName: String,
        userEmail: String,
        userAvatarUrl: String,
        supabaseUrl: String,
        supabaseKey: String,
        onlineBaseUrl: String,
        accessToken: String,
        refreshToken: String,
        teams: [[String: String]],
        teamsData: Data?
    ) -> Bool {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "meee2Connected")
        defaults.removeObject(forKey: "meee2Online")
        defaults.removeObject(forKey: "meee2EnabledSessionIds")
        defaults.removeObject(forKey: "meee2DisabledSessionIds")
        defaults.removeObject(forKey: "meee2AuthExpired")
        defaults.set(teamId, forKey: "meee2TeamId")
        defaults.set(teamName, forKey: "meee2TeamName")
        defaults.set(userId, forKey: "meee2UserId")
        defaults.set(userName, forKey: "meee2UserName")
        defaults.set(userEmail, forKey: "meee2UserEmail")
        defaults.set(userAvatarUrl, forKey: "meee2UserAvatarUrl")
        defaults.set(supabaseUrl, forKey: "meee2SupabaseUrl")
        defaults.removeObject(forKey: "meee2SupabaseKey")
        defaults.set(onlineBaseUrl, forKey: "meee2OnlineBaseUrl")
        defaults.removeObject(forKey: "meee2OnlineAccessToken")
        defaults.removeObject(forKey: "meee2OnlineRefreshToken")
        if let teamsData { defaults.set(teamsData, forKey: "meee2Teams") }

        let settings: [String: Any] = [
            "enabled": true,
            "online": true,
            "teamId": teamId,
            "teamName": teamName,
            "userId": userId,
            "userName": userName,
            "userEmail": userEmail,
            "userAvatarUrl": userAvatarUrl,
            "supabaseUrl": supabaseUrl,
            "onlineBaseUrl": onlineBaseUrl,
            "teams": teams,
            "defaultSyncEnabled": false,
            "enabledSessionIds": [],
            "disabledSessionIds": [],
            "machineId": Meee2Identity.machineId,
            "sessionKey": "claude-\(ProcessInfo.processInfo.processIdentifier)"
        ]

        return OnlineProxy.persistConfigurationAndTokens(
            meee2: settings,
            accessToken: accessToken,
            refreshToken: refreshToken,
            supabaseKey: supabaseKey
        )
    }

    private static func jsonData(for teams: [[String: String]]) -> Data? {
        try? JSONSerialization.data(withJSONObject: teams, options: [.sortedKeys])
    }

    private static func successResponse(teamName: String) -> HttpResponse {
        let safeTeamName = escapeHTML(teamName)
        let html = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Connected to Meee2</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
                .success { color: #22c55e; font-size: 48px; }
                h1 { margin: 20px 0; }
                p { color: #666; }
                .close-hint { margin-top: 30px; font-size: 14px; color: #999; }
            </style>
        </head>
        <body>
            <div class="success">&#10003;</div>
            <h1>Connected!</h1>
            <p>You are now connected to <strong>\(safeTeamName)</strong></p>
            <p>Your local sessions can now sync to Meee2 Online.</p>
            <div class="close-hint">You can close this window.</div>
        </body>
        </html>
        """
        return htmlResponse(html, status: 200, reason: "OK")
    }

    private static func errorResponse(
        message: String,
        status: Int,
        reason: String
    ) -> HttpResponse {
        let safeMessage = escapeHTML(message)
        let html = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Connection Failed</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
                .error { color: #ef4444; font-size: 48px; }
                h1 { margin: 20px 0; color: #ef4444; }
                p { color: #666; }
            </style>
        </head>
        <body>
            <div class="error">&#10007;</div>
            <h1>Connection Failed</h1>
            <p>\(safeMessage)</p>
            <p>Please try again from meee2 Settings.</p>
        </body>
        </html>
        """
        return htmlResponse(html, status: status, reason: reason)
    }

    private static func htmlResponse(_ html: String, status: Int, reason: String) -> HttpResponse {
        let headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store, max-age=0",
            "Pragma": "no-cache",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
            "Content-Security-Policy": "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
        ]
        return .raw(status, reason, headers) { writer in
            try writer.write(Array(html.utf8))
        }
    }

    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class Meee2OnlineExchangeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Meee2OnlineConnectResult, Meee2OnlineCodeExchangeError>?

    func store(_ value: Result<Meee2OnlineConnectResult, Meee2OnlineCodeExchangeError>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Result<Meee2OnlineConnectResult, Meee2OnlineCodeExchangeError>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

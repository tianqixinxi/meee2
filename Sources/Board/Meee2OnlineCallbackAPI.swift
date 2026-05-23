import Foundation
import Swifter

/// Meee2OnlineCallbackAPI - 处理 meee2 OAuth-style 回调
///
/// 当用户在浏览器完成登录后，meee2 redirect到此endpoint带上配置参数：
///   /meee2/callback?team_id=...&team_name=...&user_id=...&supabase_url=...&supabase_key=...
///
/// 此API保存配置到 ~/.meee2/settings.json 并返回成功页面
public struct Meee2OnlineCallbackAPI {

    public static func handleCallback(request: HttpRequest) -> HttpResponse {
        // 解析 query parameters
        let params = request.queryParams

        // URL decode the values
        func decode(_ key: String) -> String {
            let raw = params.first(where: { $0.0 == key })?.1 ?? ""
            return raw.removingPercentEncoding ?? raw
        }

        let teamId = decode("team_id")
        let teamName = decode("team_name")
        let userId = decode("user_id")
        let userName = decode("user_name")
        let userEmail = decode("user_email")
        let userAvatarUrl = decode("user_avatar_url")
        let supabaseUrl = decode("supabase_url")
        let supabaseKey = decode("supabase_key")
        let teamsJSON = decode("teams")
        // Optional: meee2-online forwards its own base URL so we can route
        // MCP-server writes back through /api/v1/* (M1). Blank values are
        // ignored — Meee2Identity.apiUrl falls back to the SaaS default.
        Meee2Identity.setApiUrlIfProvided(decode("api_url"))

        // 验证必要参数
        if teamId.isEmpty || userId.isEmpty || supabaseUrl.isEmpty || supabaseKey.isEmpty {
            return errorResponse(message: "Missing required parameters")
        }
        let teams = parseTeams(
            teamsJSON: teamsJSON,
            fallbackTeamId: teamId,
            fallbackTeamName: teamName
        )
        let teamsData = jsonData(for: teams)

        // 保存配置
        let success = saveConfig(
            teamId: teamId,
            teamName: teamName,
            userId: userId,
            userName: userName,
            userEmail: userEmail,
            userAvatarUrl: userAvatarUrl,
            supabaseUrl: supabaseUrl,
            supabaseKey: supabaseKey,
            teams: teams,
            teamsData: teamsData
        )

        if success {
            // 发送通知让 SettingsView 刷新
            var userInfo: [String: Any] = [
                "teamId": teamId,
                "teamName": teamName,
                "userId": userId,
                "userName": userName,
                "userEmail": userEmail,
                "userAvatarUrl": userAvatarUrl,
                "supabaseUrl": supabaseUrl,
                "supabaseKey": supabaseKey
            ]
            if let teamsData {
                userInfo["teamsData"] = teamsData
            }
            NotificationCenter.default.post(
                name: Notification.Name("meee2.connected"),
                object: nil,
                userInfo: userInfo
            )
            Meee2OnlinePusher.shared.refreshActivation()

            return successResponse(teamName: teamName)
        } else {
            return errorResponse(message: "Failed to save configuration")
        }
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
        teams: [[String: String]],
        teamsData: Data?
    ) -> Bool {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "meee2Connected")
        defaults.set(true, forKey: "meee2Online")
        defaults.set(teamId, forKey: "meee2TeamId")
        defaults.set(teamName, forKey: "meee2TeamName")
        defaults.set(userId, forKey: "meee2UserId")
        defaults.set(userName, forKey: "meee2UserName")
        defaults.set(userEmail, forKey: "meee2UserEmail")
        defaults.set(userAvatarUrl, forKey: "meee2UserAvatarUrl")
        defaults.set(supabaseUrl, forKey: "meee2SupabaseUrl")
        defaults.set(supabaseKey, forKey: "meee2SupabaseKey")
        if let teamsData {
            defaults.set(teamsData, forKey: "meee2Teams")
        }

        let settings: [String: Any] = [
            "meee2": [
                "enabled": true,
                "online": true,
                "teamId": teamId,
                "teamName": teamName,
                "userId": userId,
                "userName": userName,
                "userEmail": userEmail,
                "userAvatarUrl": userAvatarUrl,
                "supabaseUrl": supabaseUrl,
                "supabaseKey": supabaseKey,
                "teams": teams,
                "machineId": Meee2Identity.machineId,
                "sessionKey": "claude-\(ProcessInfo.processInfo.processIdentifier)"
            ]
        ]

        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".meee2")
        let file = dir.appendingPathComponent("settings.json")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 写入 JSON
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try data.write(to: file, options: .atomic)
                MInfo("[Meee2OnlineCallback] Saved config to \(file.path)")
                return true
            } catch {
                MError("[Meee2OnlineCallback] Failed to write config: \(error)")
                return false
            }
        }
        return false
    }

    private static func parseTeams(
        teamsJSON: String,
        fallbackTeamId: String,
        fallbackTeamName: String
    ) -> [[String: String]] {
        let fallback = [
            "id": fallbackTeamId,
            "name": fallbackTeamName.isEmpty ? "Default team" : fallbackTeamName,
            "role": ""
        ]
        guard let data = teamsJSON.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [fallback]
        }

        let teams = rows.compactMap { row -> [String: String]? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let role = row["role"] as? String ?? ""
            return ["id": id, "name": name, "role": role]
        }
        return teams.isEmpty ? [fallback] : teams
    }

    private static func jsonData(for teams: [[String: String]]) -> Data? {
        try? JSONSerialization.data(withJSONObject: teams, options: [.sortedKeys])
    }

    private static func successResponse(teamName: String) -> HttpResponse {
        let html = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Connected to meee2</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
                .success { color: #22c55e; font-size: 48px; }
                h1 { margin: 20px 0; }
                p { color: #666; }
                .close-hint { margin-top: 30px; font-size: 14px; color: #999; }
            </style>
            <script>
                // Auto-close after 3 seconds
                setTimeout(() => { window.close(); }, 3000);
            </script>
        </head>
        <body>
            <div class="success">✓</div>
            <h1>Connected!</h1>
            <p>You are now connected to <strong>\(teamName)</strong></p>
            <p>Your Claude sessions will sync to meee2 dashboard.</p>
            <div class="close-hint">This window will close automatically...</div>
        </body>
        </html>
        """
        let bytes = Array(html.utf8)
        return .raw(200, "OK", ["Content-Type": "text/html; charset=utf-8"]) { writer in
            try writer.write(bytes)
        }
    }

    private static func errorResponse(message: String) -> HttpResponse {
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
            <div class="error">✗</div>
            <h1>Connection Failed</h1>
            <p>\(message)</p>
            <p>Please try again from meee2 Settings.</p>
        </body>
        </html>
        """
        let bytes = Array(html.utf8)
        return .raw(400, "Bad Request", ["Content-Type": "text/html; charset=utf-8"]) { writer in
            try writer.write(bytes)
        }
    }
}

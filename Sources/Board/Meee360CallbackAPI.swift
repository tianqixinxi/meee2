import Foundation
import Swifter

/// Meee360CallbackAPI - 处理 meee360 OAuth-style 回调
///
/// 当用户在浏览器完成登录后，meee360 redirect到此endpoint带上配置参数：
///   /meee360/callback?team_id=...&team_name=...&user_id=...&supabase_url=...&supabase_key=...
///
/// 此API保存配置到 ~/.meee2/settings.json 并返回成功页面
public struct Meee360CallbackAPI {

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
        let supabaseUrl = decode("supabase_url")
        let supabaseKey = decode("supabase_key")

        // 验证必要参数
        if teamId.isEmpty || userId.isEmpty || supabaseUrl.isEmpty || supabaseKey.isEmpty {
            return errorResponse(message: "Missing required parameters")
        }

        // 保存配置
        let success = saveConfig(
            teamId: teamId,
            teamName: teamName,
            userId: userId,
            supabaseUrl: supabaseUrl,
            supabaseKey: supabaseKey
        )

        if success {
            // 发送通知让 SettingsView 刷新
            NotificationCenter.default.post(
                name: Notification.Name("meee360.connected"),
                object: nil,
                userInfo: [
                    "teamId": teamId,
                    "teamName": teamName,
                    "userId": userId,
                    "supabaseUrl": supabaseUrl,
                    "supabaseKey": supabaseKey
                ]
            )

            return successResponse(teamName: teamName)
        } else {
            return errorResponse(message: "Failed to save configuration")
        }
    }

    private static func saveConfig(
        teamId: String,
        teamName: String,
        userId: String,
        supabaseUrl: String,
        supabaseKey: String
    ) -> Bool {
        let settings: [String: Any] = [
            "meee360": [
                "enabled": true,
                "online": true,
                "teamId": teamId,
                "teamName": teamName,
                "userId": userId,
                "supabaseUrl": supabaseUrl,
                "supabaseKey": supabaseKey,
                "machineId": Host.current().name ?? "unknown",
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
                MInfo("[Meee360Callback] Saved config to \(file.path)")
                return true
            } catch {
                MError("[Meee360Callback] Failed to write config: \(error)")
                return false
            }
        }
        return false
    }

    private static func successResponse(teamName: String) -> HttpResponse {
        let html = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Connected to meee360</title>
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
            <p>Your Claude sessions will sync to meee360 dashboard.</p>
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
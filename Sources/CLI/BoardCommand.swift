import Foundation

/// BoardCommand —— CLI 入口 `meee2 board`
///
/// 流程：
///   1. 启动 BoardServer（Swifter HTTP + WebSocket）
///   2. 用 `/usr/bin/open <url>` 打开默认浏览器
///   3. 返回 `true`，让 GUI main loop 保持进程存活，服务器随之长期运行
public enum BoardCommand {
    /// 环境变量名 —— 让 GUI 启动后也识别「是从 board 命令进入的」（AppDelegate 可选读）
    public static let launchEnvVar = "MEEE2_SHOW_BOARD"

    public static func run() -> Bool {
        setenv(launchEnvVar, "1", 1)

        do {
            try BoardServer.shared.start()
        } catch {
            print("Error: failed to start board server: \(error)")
            return false
        }

        let url = BoardServer.shared.url
        print("Board running at \(url)")

        // 打开默认浏览器（不阻塞）
        _ = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [url]
        )

        // 继续启动 GUI —— GUI main loop 保证进程存活，服务器随之长期运行
        return true
    }

    /// AppDelegate 查询：本次启动是否来自 `meee2 board`
    public static var shouldShowOnLaunch: Bool {
        return ProcessInfo.processInfo.environment[launchEnvVar] == "1"
    }
}

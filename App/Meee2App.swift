import SwiftUI
import meee2Kit

@main
struct meee2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // CLI 模式处理
    init() {
        // 解析命令行参数（排除第一个 "meee2"）
        let args = Array(CommandLine.arguments.dropFirst())
        let execution = CLI.run(args: args)

        if case .exit(let code) = execution {
            exit(code.rawValue)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

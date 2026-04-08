import SwiftUI
import meee2Kit

@main
struct meee2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // CLI 模式处理
    init() {
        // 解析命令行参数（排除第一个 "meee2"）
        let args = Array(CommandLine.arguments.dropFirst())
        let shouldRunGUI = CLI.run(args: args)

        // 如果不是 GUI 模式，直接退出
        if !shouldRunGUI {
            exit(0)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
import Foundation
import Meee2PluginKit

/// CLI 入口 - 处理命令行参数
public struct CLI {
    public static func run(args: [String]) -> Bool {
        // 无参数或 "gui" - 启动 GUI
        if args.isEmpty || args.first == "gui" {
            return true  // 返回 true 表示继续启动 GUI
        }

        let command = args.first ?? ""

        switch command {
        case "tui":
            runTUI()
            return false

        case "board":
            return BoardCommand.run()  // 返回 false 表示退出，不启动 GUI

        case "list":
            let format: OutputFormat = args.contains("--json") ? .json :
                args.contains("--simple") ? .simple : .table
            ListCommand.run(format: format)
            return false

        case "send":
            if args.count < 3 {
                printUsage()
                return false
            }
            let sessionId = args[1]
            let message = args[2]
            SendCommand.run(sessionId: sessionId, message: message)
            return false

        case "jump":
            if args.count < 2 {
                printUsage()
                return false
            }
            JumpCommand.run(sessionId: args[1])
            return false

        case "note":
            if args.count < 3 {
                printUsage()
                return false
            }
            NoteCommand.run(sessionId: args[1], note: args[2])
            return false

        case "msg":
            MsgCommand.run(args: Array(args.dropFirst()))
            return false

        case "whoami":
            WhoAmICommand.run()
            return false

        case "channel":
            ChannelCommand.run(args: Array(args.dropFirst()))
            return false

        case "--help", "-h", "help":
            printHelp()
            return false

        case "--version", "-v", "version":
            printVersion()
            return false

        default:
            print("Unknown command: \(command)")
            printUsage()
            return false
        }
    }

    private static func runTUI() {
        var dashboard = DashboardView()
        dashboard.run()
    }

    private static func printHelp() {
        print("""
        meee2 - Claude Session Manager

        Usage:
          meee2                  Start GUI (default)
          meee2 gui              Start GUI
          meee2 tui              Start TUI dashboard
          meee2 board            Open whiteboard visualization (sessions + A2A channels)
          meee2 list             List sessions
          meee2 list --json      List sessions in JSON format
          meee2 send <id> "msg"  Send message to session
          meee2 jump <id>        Jump to session terminal
          meee2 note <id> "note" Add note to session
          meee2 channel <sub>    Manage A2A channels (ls, create, join, leave, mode, info)
          meee2 msg <sub>        A2A messaging (send, ls, get, hold, deliver, drop, edit)
          meee2 whoami           Show this session's A2A identity + memberships
          meee2 --help           Show this help
          meee2 --version        Show version

        A2A examples:
          meee2 channel create <name>
          meee2 channel join <name> --as <agent>
          meee2 msg send --channel <name> --from <a> --to <b> "message"
          meee2 msg ls --channel <name>

        Session ID can be short prefix (e.g., first 8 characters).
        """)
    }

    private static func printUsage() {
        print("Usage: meee2 <command> [args]")
        print("Commands: gui, tui, board, list, send, jump, note, channel, msg, whoami, help, version")
        print("Run 'meee2 --help' for more information")
    }

    private static func printVersion() {
        print("meee2 version 1.0.0")
    }
}
import Foundation
import Meee2PluginKit

public enum CLIExitCode: Int32, Equatable {
    case success = 0
    case failure = 1
    case usage = 64
    case notFound = 66
}

public enum CLIExecution: Equatable {
    case runGUI
    case exit(CLIExitCode)
}

/// CLI 入口。解析失败、目标不存在和运行失败使用稳定的 sysexits 风格状态码。
public struct CLI {
    public static func run(args: [String]) -> CLIExecution {
        if args.isEmpty { return .runGUI }

        let command = args[0]
        switch command {
        case "gui":
            guard args.count == 1 else { return usageError("gui does not accept arguments") }
            return .runGUI

        case "board":
            guard args.count == 1 else { return usageError("board does not accept arguments") }
            return BoardCommand.run() ? .runGUI : .exit(.failure)

        case "list":
            let flags = Set(args.dropFirst())
            let supported: Set<String> = ["--json", "--simple", "--all"]
            guard flags.isSubset(of: supported), !(flags.contains("--json") && flags.contains("--simple")) else {
                return usageError("list accepts only one format flag plus --all")
            }
            let format: OutputFormat = flags.contains("--json") ? .json :
                flags.contains("--simple") ? .simple : .table
            return .exit(ListCommand.run(format: format, includeAll: flags.contains("--all")))

        case "send":
            guard args.count == 3 else { return usageError("send requires <id> and one quoted message") }
            return .exit(SendCommand.run(sessionId: args[1], message: args[2]))

        case "jump":
            guard args.count == 2 else { return usageError("jump requires exactly one session id") }
            return .exit(JumpCommand.run(sessionId: args[1]))

        case "note":
            guard args.count == 3 else { return usageError("note requires <id> and one quoted note") }
            return .exit(NoteCommand.run(sessionId: args[1], note: args[2]))

        case "msg":
            MsgCommand.run(args: Array(args.dropFirst()))
            return .exit(.success)

        case "whoami":
            WhoAmICommand.run()
            return .exit(.success)

        case "doctor":
            DoctorCommand.run(args: Array(args.dropFirst()))
            return .exit(.success)

        case "channel":
            ChannelCommand.run(args: Array(args.dropFirst()))
            return .exit(.success)

        case "test":
            TestCommand.run(args: Array(args.dropFirst()))
            return .exit(.success)

        case "--help", "-h", "help":
            guard args.count == 1 else { return usageError("help does not accept arguments") }
            printHelp()
            return .exit(.success)

        case "--version", "-v", "version":
            guard args.count == 1 else { return usageError("version does not accept arguments") }
            print("meee2 version \(BuildInfo.version)")
            return .exit(.success)

        default:
            return usageError("unknown command: \(command)")
        }
    }

    private static func usageError(_ message: String) -> CLIExecution {
        CLIOutput.error("Error: \(message)")
        printUsage(toStandardError: true)
        return .exit(.usage)
    }

    private static func printHelp() {
        print("""
        meee2 - AI Session Manager

        Usage:
          meee2                  Start GUI (default)
          meee2 gui              Start GUI
          meee2 board            Open the Board window
          meee2 list [--all]     List active and recent sessions (--all includes history)
          meee2 list --json      List sessions as JSON
          meee2 send <id> "msg"  Send a message to a session
          meee2 jump <id>        Focus the session's real terminal tab
          meee2 note <id> "note" Add a note to a session
          meee2 channel <sub>    Manage A2A channels
          meee2 msg <sub>        Manage A2A messages
          meee2 whoami           Show this session's A2A identity
          meee2 doctor [--json]  Check local session readiness
          meee2 --help           Show this help
          meee2 --version        Show the app version

        Session IDs may be unambiguous prefixes.
        """)
    }

    private static func printUsage(toStandardError: Bool) {
        let text = "Usage: meee2 <gui|board|list|send|jump|note|channel|msg|whoami|doctor|help|version> [args]"
        if toStandardError { CLIOutput.error(text) } else { print(text) }
    }
}

enum CLIOutput {
    static func error(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }
}

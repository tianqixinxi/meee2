import Foundation

/// `meee2 channel ...` 的入口 - 人工面向的频道管理
public struct ChannelCommand {
    /// args[0] 为子命令名
    public static func run(args: [String]) {
        guard let sub = args.first else {
            printUsage()
            return
        }
        let rest = Array(args.dropFirst())

        switch sub {
        case "ls", "list":
            cmdList()
        case "create":
            cmdCreate(rest)
        case "delete", "rm":
            cmdDelete(rest)
        case "join":
            cmdJoin(rest)
        case "leave":
            cmdLeave(rest)
        case "mode":
            cmdMode(rest)
        case "inspect", "show":
            cmdInspect(rest)
        case "help", "--help", "-h":
            printUsage()
        default:
            print("Error: unknown subcommand '\(sub)'")
            printUsage()
        }
    }

    // MARK: - Subcommands

    private static func cmdList() {
        let channels = ChannelRegistry.shared.list()
        if channels.isEmpty {
            print("(no channels)")
            return
        }
        for ch in channels {
            let pending = MessageRouter.shared
                .listMessages(channel: ch.name, statuses: [.pending, .held])
                .count
            let memberList = ch.members.isEmpty
                ? "-"
                : ch.members.map { $0.alias }.joined(separator: ",")
            print("\(ch.name)  mode=\(ch.mode.rawValue)  members=[\(memberList)]  pending=\(pending)")
            if let d = ch.description, !d.isEmpty {
                print("    \(d)")
            }
        }
    }

    private static func cmdCreate(_ args: [String]) {
        guard let name = args.first else {
            print("Error: channel name required")
            print("Usage: meee2 channel create <name> [--mode auto|intercept|paused] [--description \"...\"]")
            return
        }
        let parsed = parseFlags(Array(args.dropFirst()), stringFlags: ["--mode", "--description"])
        var mode: ChannelMode = .auto
        if let m = parsed.strings["--mode"] {
            guard let parsedMode = ChannelMode(rawValue: m) else {
                print("Error: invalid --mode '\(m)'. Valid: auto, intercept, paused")
                return
            }
            mode = parsedMode
        }
        let desc = parsed.strings["--description"]
        do {
            let ch = try ChannelRegistry.shared.create(name: name, description: desc, mode: mode)
            print("Created channel '\(ch.name)' (mode=\(ch.mode.rawValue))")
        } catch {
            print("Error: \(error)")
        }
    }

    private static func cmdDelete(_ args: [String]) {
        guard let name = args.first else {
            print("Error: channel name required")
            return
        }
        do {
            try ChannelRegistry.shared.delete(name)
            print("Deleted channel '\(name)'")
        } catch {
            print("Error: \(error)")
        }
    }

    private static func cmdJoin(_ args: [String]) {
        guard let name = args.first else {
            print("Error: channel name required")
            print("Usage: meee2 channel join <name> --as <alias> --session <sid-prefix>")
            return
        }
        let parsed = parseFlags(Array(args.dropFirst()), stringFlags: ["--as", "--session"])
        guard let alias = parsed.strings["--as"] else {
            print("Error: --as <alias> required")
            return
        }
        guard let sidPrefix = parsed.strings["--session"] else {
            print("Error: --session <sid-prefix> required")
            return
        }

        guard let fullSid = resolveSessionPrefix(sidPrefix) else { return }

        do {
            let ch = try ChannelRegistry.shared.join(channel: name, alias: alias, sessionId: fullSid)
            print("Joined '\(ch.name)' as '\(alias)' (session \(fullSid.prefix(8)))")
        } catch {
            print("Error: \(error)")
        }
    }

    private static func cmdLeave(_ args: [String]) {
        guard let name = args.first else {
            print("Error: channel name required")
            print("Usage: meee2 channel leave <name> --as <alias>")
            return
        }
        let parsed = parseFlags(Array(args.dropFirst()), stringFlags: ["--as"])
        guard let alias = parsed.strings["--as"] else {
            print("Error: --as <alias> required")
            return
        }
        do {
            let ch = try ChannelRegistry.shared.leave(channel: name, alias: alias)
            print("'\(alias)' left '\(ch.name)'")
        } catch {
            print("Error: \(error)")
        }
    }

    private static func cmdMode(_ args: [String]) {
        guard args.count >= 2 else {
            print("Usage: meee2 channel mode <name> <auto|intercept|paused>")
            return
        }
        let name = args[0]
        let modeStr = args[1]
        guard let mode = ChannelMode(rawValue: modeStr) else {
            print("Error: invalid mode '\(modeStr)'. Valid: auto, intercept, paused")
            return
        }
        do {
            let ch = try ChannelRegistry.shared.setMode(name, mode: mode)
            print("Channel '\(ch.name)' mode -> \(ch.mode.rawValue)")
        } catch {
            print("Error: \(error)")
        }
    }

    private static func cmdInspect(_ args: [String]) {
        // 支持 --follow / -f 标志，其余参数按位置解析出 channel name
        var follow = false
        var positional: [String] = []
        for a in args {
            if a == "--follow" || a == "-f" {
                follow = true
            } else {
                positional.append(a)
            }
        }
        guard let name = positional.first else {
            print("Error: channel name required")
            print("Usage: meee2 channel inspect <name> [--follow|-f]")
            return
        }
        guard let ch = ChannelRegistry.shared.get(name) else {
            print("Error: channel not found: \(name)")
            return
        }
        print("Channel: \(ch.name)")
        print("  Mode: \(ch.mode.rawValue)")
        if let d = ch.description, !d.isEmpty {
            print("  Description: \(d)")
        }
        let iso = ISO8601DateFormatter()
        print("  Created: \(iso.string(from: ch.createdAt))")
        print("  Members (\(ch.members.count)):")
        if ch.members.isEmpty {
            print("    (none)")
        } else {
            for m in ch.members {
                print("    - \(m.alias)  session=\(m.sessionId.prefix(8))  joined=\(iso.string(from: m.joinedAt))")
            }
        }

        let pending = MessageRouter.shared
            .listMessages(channel: name, statuses: [.pending, .held])
        print("")
        print("  Pending/Held (\(pending.count)):")
        if pending.isEmpty {
            print("    (none)")
        } else {
            for m in pending {
                print("    [\(m.id)] \(m.status.rawValue)  \(m.fromAlias) -> \(m.toAlias)  \(truncate(m.content, 60))")
            }
        }

        let delivered = MessageRouter.shared
            .listMessages(channel: name, statuses: [.delivered])
            .suffix(10)
        print("")
        print("  Recent delivered (last \(delivered.count)):")
        if delivered.isEmpty {
            print("    (none)")
        } else {
            for m in delivered {
                let ts = m.deliveredAt.map { iso.string(from: $0) } ?? "-"
                print("    [\(m.id)] \(ts)  \(m.fromAlias) -> [\(m.deliveredTo.joined(separator: ","))]  \(truncate(m.content, 60))")
            }
        }

        if follow {
            print("")
            print("  -- following (Ctrl+C to exit) --")
            // 确保初始快照在被 Ctrl+C 打断前已经落到 stdout（redirect 到 pipe/file 时是全缓冲）
            fflush(stdout)
            followInspect(name: name, initialPending: pending, initialDelivered: Array(delivered))
        }
    }

    /// 跟随模式：每秒轮询一次，仅打印新增的 (id, status) 事件
    private static func followInspect(
        name: String,
        initialPending: [A2AMessage],
        initialDelivered: [A2AMessage]
    ) {
        // 去重 key: "<id>:<status>"
        var seen = Set<String>()
        for m in initialPending { seen.insert("\(m.id):\(m.status.rawValue)") }
        for m in initialDelivered { seen.insert("\(m.id):\(m.status.rawValue)") }

        let tsFmt = DateFormatter()
        tsFmt.dateFormat = "HH:mm:ss"

        // MVP：不安装 SIGINT handler，靠默认行为结束进程
        while true {
            // 让 runloop / io 刷新一下再睡
            sleep(1)

            // 频道可能被删除，做防御检查
            guard ChannelRegistry.shared.get(name) != nil else {
                print("[\(tsFmt.string(from: Date()))] channel '\(name)' removed, exiting follow")
                return
            }

            // 抓取所有非终态 + 最近 delivered + dropped
            let snapshots: [A2AMessage] =
                MessageRouter.shared.listMessages(channel: name, statuses: [.pending, .held])
                + MessageRouter.shared.listMessages(channel: name, statuses: [.delivered])
                + MessageRouter.shared.listMessages(channel: name, statuses: [.dropped])

            // 按 createdAt 稳定排序
            let sorted = snapshots.sorted { $0.createdAt < $1.createdAt }

            for m in sorted {
                let key = "\(m.id):\(m.status.rawValue)"
                if seen.contains(key) { continue }
                seen.insert(key)

                let ts = tsFmt.string(from: Date())
                let snippet = truncate(m.content, 60)
                print("[\(ts)] \(m.id) \(m.fromAlias) -> \(m.toAlias): \(m.status.rawValue)  \(snippet)")
                // 立刻刷新 stdout, 避免管道缓冲
                fflush(stdout)
            }
        }
    }

    // MARK: - Helpers

    /// 根据短前缀解析出完整 sessionId；多/无匹配时打印错误并返回 nil
    private static func resolveSessionPrefix(_ prefix: String) -> String? {
        let sessions = SessionStore.shared.listAll()
        let matches = sessions.filter { $0.sessionId.hasPrefix(prefix) }
        if matches.isEmpty {
            print("Error: no session matches prefix '\(prefix)'")
            return nil
        }
        if matches.count > 1 {
            print("Error: multiple sessions match prefix '\(prefix)':")
            for s in matches {
                print("  \(s.sessionId) - \(s.project)")
            }
            return nil
        }
        return matches[0].sessionId
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s.replacingOccurrences(of: "\n", with: " ") }
        let idx = s.index(s.startIndex, offsetBy: n)
        return String(s[..<idx]).replacingOccurrences(of: "\n", with: " ") + "…"
    }

    /// 解析 --flag value 形式的参数
    struct FlagParse {
        var strings: [String: String] = [:]
        var positional: [String] = []
    }
    static func parseFlags(_ args: [String], stringFlags: Set<String>) -> FlagParse {
        var out = FlagParse()
        var i = 0
        while i < args.count {
            let a = args[i]
            if stringFlags.contains(a), i + 1 < args.count {
                out.strings[a] = args[i + 1]
                i += 2
            } else {
                out.positional.append(a)
                i += 1
            }
        }
        return out
    }

    private static func printUsage() {
        print("""
        meee2 channel - manage A2A channels

        Usage:
          meee2 channel ls
          meee2 channel create <name> [--mode auto|intercept|paused] [--description "..."]
          meee2 channel delete <name>
          meee2 channel join <name> --as <alias> --session <sid-prefix>
          meee2 channel leave <name> --as <alias>
          meee2 channel mode <name> <auto|intercept|paused>
          meee2 channel inspect <name> [--follow|-f]
        """)
    }
}

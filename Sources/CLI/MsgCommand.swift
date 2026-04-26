import Foundation

/// `meee2 msg ...` 的入口 - agent + 人类的消息操作面
public struct MsgCommand {
    public static func run(args: [String]) {
        guard let sub = args.first else {
            printUsage()
            return
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "send":
            cmdSend(rest, injected: false)
        case "inject":
            cmdSend(rest, injected: true)
        case "ls", "list":
            cmdList(rest)
        case "hold":
            cmdHumanAction(rest, action: .hold)
        case "deliver":
            cmdHumanAction(rest, action: .deliver)
        case "drop":
            cmdHumanAction(rest, action: .drop)
        case "edit":
            cmdEdit(rest)
        case "peek":
            cmdPeek(rest)
        case "halt":
            cmdHalt(rest)
        case "audit":
            cmdAudit(rest)
        case "whoami":
            WhoAmICommand.run()
        case "help", "--help", "-h":
            printUsage()
        default:
            print("Error: unknown subcommand '\(sub)'")
            printUsage()
        }
    }

    // MARK: - send / inject

    private static func cmdSend(_ args: [String], injected: Bool) {
        let parsed = ChannelCommand.parseFlags(
            args,
            stringFlags: ["--channel", "--from", "--to", "--reply-to"]
        )

        // --to / content 仍是硬性必填
        guard let to = parsed.strings["--to"] else {
            print("Error: --to <alias-or-*> required")
            return
        }
        guard let content = parsed.positional.first else {
            print("Error: content required (pass as positional argument)")
            return
        }
        // --reply-to: 显式传入优先；没传时尝试从 ConversationContext 拿这条
        // session 在该 channel 上最近一条 inbound message 的 id 当 reply parent。
        // 这样让 hopCount + traceId 自然继承下去，agent 不需要管。
        // 注意：channel 还没确定，先占位，等 channel 算完后再 resolve。
        let explicitReplyTo = parsed.strings["--reply-to"]

        // --channel: 未显式传入时，尝试从当前会话的唯一频道成员身份推断
        let explicitChannel = parsed.strings["--channel"]
        var channelAutoResolved = false
        let channel: String
        if let explicit = explicitChannel {
            channel = explicit
        } else if let auto = A2AIdentity.soleChannel() {
            channel = auto
            channelAutoResolved = true
        } else {
            printSendResolutionError(missing: "channel")
            return
        }

        // --from: 未显式传入时，根据当前会话在该频道的 alias 自动填充
        let explicitFrom = parsed.strings["--from"]
        var fromAutoResolved = false
        let from: String
        if let explicit = explicitFrom {
            from = explicit
        } else if let auto = A2AIdentity.aliasInChannel(channel) {
            from = auto
            fromAutoResolved = true
        } else {
            printSendResolutionError(missing: "from", channel: channel)
            return
        }

        // Resolve replyTo: explicit > ConversationContext lookup > nil
        var replyToAutoResolved = false
        let replyTo: String? = explicitReplyTo ?? {
            guard let sid = A2AIdentity.currentSessionId() else { return nil }
            guard let prev = ConversationContext.shared.lastInbound(sessionId: sid, channel: channel) else { return nil }
            replyToAutoResolved = true
            return prev.id
        }()

        if channelAutoResolved || fromAutoResolved || replyToAutoResolved {
            var parts: [String] = []
            if channelAutoResolved { parts.append("channel=\(channel)") }
            if fromAutoResolved { parts.append("from=\(from)") }
            if replyToAutoResolved, let r = replyTo { parts.append("reply-to=\(r)") }
            print("(auto-resolved: \(parts.joined(separator: " ")))")
        }

        do {
            let msg = try MessageRouter.shared.send(
                channel: channel,
                fromAlias: from,
                toAlias: to,
                content: content,
                replyTo: replyTo,
                injectedByHuman: injected
            )
            print("\(msg.id)\tstatus=\(msg.status.rawValue)\tchannel=\(msg.channel)\t\(msg.fromAlias) -> \(msg.toAlias)")
            if msg.status == .delivered {
                print("  delivered to: [\(msg.deliveredTo.joined(separator: ","))]")
            }
        } catch {
            print("Error: \(error)")
        }
    }

    // MARK: - ls

    private static func cmdList(_ args: [String]) {
        let parsed = ChannelCommand.parseFlags(args, stringFlags: ["--channel", "--status"])
        let channel = parsed.strings["--channel"]
        var statuses: Set<MessageStatus>?
        if let s = parsed.strings["--status"] {
            guard let st = MessageStatus(rawValue: s) else {
                print("Error: invalid --status '\(s)'. Valid: pending, held, delivered, dropped")
                return
            }
            statuses = [st]
        }

        let messages = MessageRouter.shared.listMessages(channel: channel, statuses: statuses)
        if messages.isEmpty {
            print("(no messages)")
            return
        }
        let iso = ISO8601DateFormatter()
        for m in messages {
            let ts = iso.string(from: m.createdAt)
            let human = m.injectedByHuman ? " (injected)" : ""
            print("\(m.id)\t\(m.status.rawValue)\t\(ts)\t\(m.channel)\t\(m.fromAlias) -> \(m.toAlias)\(human)\t\(truncate(m.content, 60))")
        }
    }

    // MARK: - hold / deliver / drop

    private enum HumanAction {
        case hold, deliver, drop
    }

    private static func cmdHumanAction(_ args: [String], action: HumanAction) {
        guard let id = args.first else {
            print("Error: message id required")
            return
        }
        do {
            let msg: A2AMessage
            switch action {
            case .hold: msg = try MessageRouter.shared.hold(id)
            case .deliver: msg = try MessageRouter.shared.deliver(id)
            case .drop: msg = try MessageRouter.shared.drop(id)
            }
            print("\(msg.id)\tstatus=\(msg.status.rawValue)")
            if msg.status == .delivered {
                print("  delivered to: [\(msg.deliveredTo.joined(separator: ","))]")
            }
        } catch {
            print("Error: \(error)")
        }
    }

    // MARK: - edit

    private static func cmdEdit(_ args: [String]) {
        guard args.count >= 2 else {
            print("Usage: meee2 msg edit <msg-id> \"<new content>\"")
            return
        }
        let id = args[0]
        let newContent = args[1]
        do {
            let msg = try MessageRouter.shared.edit(id, newContent: newContent)
            print("\(msg.id)\tstatus=\(msg.status.rawValue)")
            print("  content: \(msg.content)")
        } catch {
            print("Error: \(error)")
        }
    }

    // MARK: - peek

    private static func cmdPeek(_ args: [String]) {
        let parsed = ChannelCommand.parseFlags(args, stringFlags: ["--session"])
        guard let prefix = parsed.strings["--session"] else {
            print("Error: --session <sid-prefix> required")
            return
        }
        guard let fullSid = resolveSessionPrefix(prefix) else { return }

        let inbox = MessageRouter.shared.peekInbox(sessionId: fullSid)
        if inbox.isEmpty {
            print("(inbox empty for \(fullSid.prefix(8)))")
            return
        }
        print("Inbox for session \(fullSid.prefix(8)) (\(inbox.count) message(s)):")
        let iso = ISO8601DateFormatter()
        for m in inbox {
            let ts = m.deliveredAt.map { iso.string(from: $0) } ?? "-"
            print("  [\(m.id)] \(ts)  \(m.fromAlias)@\(m.channel) -> \(m.toAlias)")
            print("    \(truncate(m.content, 120))")
        }
    }

    // MARK: - halt (MVP: 直接写合成消息到 inbox)

    private static func cmdHalt(_ args: [String]) {
        guard let prefix = args.first else {
            print("Usage: meee2 msg halt <sid-prefix>")
            return
        }
        guard let fullSid = resolveSessionPrefix(prefix) else { return }

        // MVP 约定：halt 直接落盘到目标 session 的 inbox，
        // 不要求目标必须处于某个频道。使用合成的 system/__halt__ 来源。
        let msg = A2AMessage(
            channel: "__halt__",
            fromAlias: "system",
            fromSessionId: "",
            toAlias: fullSid,
            content: "[HALT] Stop your current work and wait for human input.",
            status: .delivered,
            deliveredAt: Date(),
            deliveredTo: [fullSid],
            injectedByHuman: true
        )
        do {
            _ = try MessageRouter.shared.injectDirectToInbox(sessionId: fullSid, message: msg)
            print("\(msg.id)\thalt queued to session \(fullSid.prefix(8))")
        } catch {
            print("Error: \(error)")
        }
    }

    // MARK: - audit

    private static func cmdAudit(_ args: [String]) {
        let parsed = ChannelCommand.parseFlags(
            args,
            stringFlags: ["--channel", "--msg-id", "--actor", "--since", "--limit"]
        )

        let channel = parsed.strings["--channel"]
        let msgId = parsed.strings["--msg-id"]
        let actor = parsed.strings["--actor"]

        var since: Date?
        if let s = parsed.strings["--since"] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) {
                since = d
            } else {
                // 允许 fractional seconds
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: s) {
                    since = d
                } else {
                    print("Error: invalid --since '\(s)' (expected ISO8601)")
                    return
                }
            }
        }

        var limit = 50
        if let l = parsed.strings["--limit"] {
            guard let n = Int(l), n > 0 else {
                print("Error: --limit must be a positive integer")
                return
            }
            limit = n
        }

        let events = AuditLogger.shared.query(
            channel: channel,
            msgId: msgId,
            actor: actor,
            since: since,
            limit: limit
        )

        if events.isEmpty {
            print("(no audit events)")
            return
        }

        let iso = ISO8601DateFormatter()
        // 排序后是 newest-first；输出按时间升序读起来更顺 —— 但保持 query 合约（newest-first）
        for ev in events {
            let ts = iso.string(from: ev.ts)
            let route = "\(ev.fromAlias) -> \(ev.toAlias)"
            let line = String(
                format: "%@  %@  %@  %@  %@  %@",
                ts.padding(toLength: 20, withPad: " ", startingAt: 0),
                ev.msgId.padding(toLength: 12, withPad: " ", startingAt: 0),
                ev.channel.padding(toLength: 10, withPad: " ", startingAt: 0),
                ev.actor.padding(toLength: 16, withPad: " ", startingAt: 0),
                ev.event.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0),
                route
            )
            if let d = ev.details, !d.isEmpty {
                print("\(line)  (\(d))")
            } else {
                print(line)
            }
        }
    }

    // MARK: - Helpers

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

    private static func printSendResolutionError(missing: String, channel: String? = nil) {
        let (sid, source) = A2AIdentity.resolve()
        let envPresent = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"]?.isEmpty == false
        let sidLabel: String
        switch source {
        case .envVar:      sidLabel = "from CLAUDE_SESSION_ID env var"
        case .cwdMatch:    sidLabel = "from cwd match"
        case .unresolved:  sidLabel = "unresolved"
        }
        let sidStr = sid ?? "(unresolved)"

        switch missing {
        case "channel":
            print("Error: could not auto-resolve --channel.")
            print("  session: \(sidStr)  [\(sidLabel)]")
            print("  CLAUDE_SESSION_ID=\(envPresent ? "set" : "missing")")
            let memberships = A2AIdentity.currentMemberships()
            if memberships.isEmpty {
                print("  This session is not a member of any channel.")
            } else {
                print("  This session is in \(memberships.count) channels; pass --channel <name>:")
                for m in memberships {
                    print("    \(m.channel) as \(m.alias)")
                }
            }
            print("  Run 'meee2 whoami' to see your memberships.")
        case "from":
            let chName = channel ?? "<unknown>"
            print("Error: could not resolve sender alias for channel '\(chName)': this session is not a member.")
            print("  session: \(sidStr)  [\(sidLabel)]")
            print("  CLAUDE_SESSION_ID=\(envPresent ? "set" : "missing")")
            print("  Run 'meee2 whoami' to see your memberships.")
        default:
            print("Error: missing \(missing)")
        }
    }

    private static func printUsage() {
        print("""
        meee2 msg - agent-to-agent messaging

        Usage:
          meee2 msg send [--channel <name>] [--from <alias>] --to <alias-or-*> "<content>" [--reply-to <msg-id>]
          meee2 msg inject --channel <name> --from <alias> --to <alias-or-*> "<content>"
          meee2 msg ls [--channel <name>] [--status pending|held|delivered|dropped]
          meee2 msg hold <msg-id>
          meee2 msg deliver <msg-id>
          meee2 msg drop <msg-id>
          meee2 msg edit <msg-id> "<new content>"
          meee2 msg peek --session <sid-prefix>
          meee2 msg halt <sid-prefix>
          meee2 msg audit [--channel <name>] [--msg-id <m-...>] [--actor human|agent:<alias>] [--since <ISO8601>] [--limit N]
          meee2 msg whoami

        For `send`: when --channel or --from is omitted, the current session is
        auto-resolved via $CLAUDE_SESSION_ID (set by the Claude CLI) or by matching
        the process cwd to a known session's project. Run 'meee2 whoami' to inspect.
        """)
    }
}

/// `meee2 whoami` / `meee2 msg whoami` - diagnose the current session identity
public struct WhoAmICommand {
    public static func run() {
        let (sid, source) = A2AIdentity.resolve()
        let envPresent = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"]?.isEmpty == false
        let cwd = FileManager.default.currentDirectoryPath

        guard let sid = sid else {
            // Unresolved path
            print("Session: (unresolved)")
            if !envPresent {
                print("  - CLAUDE_SESSION_ID not set")
            } else {
                print("  - CLAUDE_SESSION_ID set but empty")
            }
            let cwdMatches = SessionStore.shared.listAll().filter { $0.project == cwd }
            print("  - cwd \(cwd) matched \(cwdMatches.count) active sessions")
            if cwdMatches.count > 1 {
                for s in cwdMatches {
                    print("      \(s.sessionId)  \(s.project)")
                }
            }
            print("No memberships available.")
            return
        }

        // Resolve the session's project (if known to SessionStore) for context
        let project = SessionStore.shared.listAll().first(where: { $0.sessionId == sid })?.project
        let projectSuffix = project.map { "  (project: \($0))" } ?? ""
        print("Session: \(sid)\(projectSuffix)")

        let sourceLabel: String
        switch source {
        case .envVar:     sourceLabel = "CLAUDE_SESSION_ID env var"
        case .cwdMatch:   sourceLabel = "cwd match"
        case .unresolved: sourceLabel = "unresolved"
        }
        print("Source:  \(sourceLabel)")
        print("")

        let memberships = A2AIdentity.currentMemberships()
        if memberships.isEmpty {
            print("Memberships: (none)")
            return
        }
        print("Memberships:")
        // Column-align alias under channel name
        let maxCh = memberships.map { $0.channel.count }.max() ?? 0
        for m in memberships {
            let pad = String(repeating: " ", count: max(1, maxCh - m.channel.count + 2))
            print("  \(m.channel)\(pad)as \(m.alias)")
        }
        print("  (\(memberships.count) channel\(memberships.count == 1 ? "" : "s"))")
    }
}

import SwiftUI
import Meee2PluginKit

/// 用户发起 A2A 连接请求的描述 —— 由 IslandView 作为 `.sheet(item:)` 的驱动值
/// 必须是顶层类型（非嵌套）以便 IslandView 作为 @State 使用
struct ConnectRequest: Identifiable, Equatable {
    let id = UUID()
    let fromSession: PluginSession
    let toSession: PluginSession

    static func == (lhs: ConnectRequest, rhs: ConnectRequest) -> Bool {
        lhs.id == rhs.id
    }
}

/// 右键 "Connect to..." 之后弹出的 sheet：让用户填写频道名 / 别名 / 模式并创建 A2A 频道
struct A2AConnectSheet: View {
    let request: ConnectRequest
    let onDismiss: () -> Void

    @State private var channelName: String = ""
    @State private var myAlias: String = ""
    @State private var theirAlias: String = ""
    @State private var mode: ChannelMode = .auto
    @State private var seedMessage: String = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题
            Text("Connect two agents")
                .font(.headline)

            // 概要行
            Text("\(request.fromSession.title)  ↔  \(request.toSession.title)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Divider()

            // 字段
            Form {
                TextField("Channel name", text: $channelName)
                TextField("My alias", text: $myAlias)
                TextField("Their alias", text: $theirAlias)
                Picker("Mode", selection: $mode) {
                    Text("auto").tag(ChannelMode.auto)
                    Text("intercept").tag(ChannelMode.intercept)
                    Text("paused").tag(ChannelMode.paused)
                }
                .pickerStyle(.segmented)
            }

            // 种子消息（可选）—— 建通道后立刻投递给双方，告诉它们被连上了该做什么
            VStack(alignment: .leading, spacing: 4) {
                Text("Seed message to both agents (optional)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextEditor(text: $seedMessage)
                    .font(.system(size: 11))
                    .frame(height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                Text("Example: \"You are connected to <other>. Debate whether TypeScript is worth learning in 2026. Use: meee2 msg send --to <other> \\\"...\\\". Keep replies 1–2 sentences. 5 rounds then wrap.\"")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 按钮
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDismiss() }
                Button("Create") { tryCreate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { applyDefaults() }
    }

    // MARK: - Validation

    private var isValid: Bool {
        let name = channelName.trimmingCharacters(in: .whitespaces)
        let ma = myAlias.trimmingCharacters(in: .whitespaces)
        let ta = theirAlias.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !ma.isEmpty && !ta.isEmpty && ma != ta
    }

    // MARK: - Defaults

    private func applyDefaults() {
        if channelName.isEmpty {
            channelName = "pair-\(randomSuffix(4))"
        }
        if myAlias.isEmpty {
            myAlias = aliasHint(for: request.fromSession)
        }
        if theirAlias.isEmpty {
            let hint = aliasHint(for: request.toSession)
            // 避免与 myAlias 默认冲突
            theirAlias = (hint == myAlias) ? "\(hint)-2" : hint
        }
    }

    // MARK: - Create

    private func tryCreate() {
        errorMessage = nil
        let trimmedName = channelName.trimmingCharacters(in: .whitespaces)
        let ma = myAlias.trimmingCharacters(in: .whitespaces)
        let ta = theirAlias.trimmingCharacters(in: .whitespaces)

        do {
            _ = try ChannelRegistry.shared.create(name: trimmedName, mode: mode)
            _ = try ChannelRegistry.shared.join(
                channel: trimmedName,
                alias: ma,
                sessionId: request.fromSession.id
            )
            _ = try ChannelRegistry.shared.join(
                channel: trimmedName,
                alias: ta,
                sessionId: request.toSession.id
            )

            // 种子消息（可选）：对双方各 inject 一条，告知它们被连上了 + 角色
            let seed = seedMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !seed.isEmpty {
                injectSeed(channel: trimmedName, recipientAlias: ma,
                           recipientSessionId: request.fromSession.id,
                           peerAlias: ta, content: seed)
                injectSeed(channel: trimmedName, recipientAlias: ta,
                           recipientSessionId: request.toSession.id,
                           peerAlias: ma, content: seed)
            }

            onDismiss()
        } catch {
            errorMessage = humanize(error)
        }
    }

    /// 给单个 agent inject 一条已交付的 seed 消息 —— 下次 Stop hook drain 时会被注入 context
    private func injectSeed(channel: String, recipientAlias: String,
                            recipientSessionId: String, peerAlias: String,
                            content: String) {
        // 模板化渲染：告诉 agent 它是谁、对手是谁、用什么命令回话
        let rendered = """
        [meee2 connect] You are '\(recipientAlias)' in channel '\(channel)'. \
        Your peer is '\(peerAlias)'. \
        To reply to them, run (via Bash tool): \
        meee2 msg send --to \(peerAlias) "<your message>"

        Instructions from operator:
        \(content)
        """
        let msg = A2AMessage(
            channel: channel,
            fromAlias: "__operator__",
            fromSessionId: "",
            toAlias: recipientAlias,
            content: rendered,
            status: .delivered,
            deliveredAt: Date(),
            deliveredTo: [recipientAlias],
            injectedByHuman: true
        )
        _ = try? MessageRouter.shared.injectDirectToInbox(
            sessionId: recipientSessionId,
            message: msg
        )
    }

    /// 尽力把 ChannelRegistryError 映射为可读字符串
    private func humanize(_ error: Error) -> String {
        if let e = error as? ChannelRegistryError {
            switch e {
            case .alreadyExists(let n):
                return "Channel '\(n)' already exists. Pick a different name."
            case .notFound(let n):
                return "Channel '\(n)' not found."
            case .aliasTaken(let a):
                return "Alias '\(a)' is already taken in this channel."
            case .aliasNotFound(let a):
                return "Alias '\(a)' not found."
            case .invalidName(let n):
                return "Invalid channel name '\(n)'. Use lowercase letters, digits, '-' or '_' (1–64 chars)."
            }
        }
        return error.localizedDescription
    }
}

// MARK: - File-private helpers

private func randomSuffix(_ n: Int) -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<n).map { _ in chars.randomElement()! })
}

/// 从 session.title / cwd 派生一个友好的别名提示
/// 策略：取 cwd 最后一段（或 title），小写，非字母数字替换为 `-`，去首尾 `-`，截断到 20。
/// 没有可用字符时 fallback 为 "agent"。
private func aliasHint(for s: PluginSession) -> String {
    let src: String
    if let cwd = s.cwd, !cwd.isEmpty {
        src = (cwd as NSString).lastPathComponent
    } else {
        src = s.title
    }
    let lowered = src.lowercased()
    let mapped = lowered.map { (c: Character) -> String in
        (c.isLetter || c.isNumber) ? String(c) : "-"
    }.joined()
    let trimmedDashes = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let truncated = String(trimmedDashes.prefix(20))
    return truncated.isEmpty ? "agent" : truncated
}

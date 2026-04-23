import SwiftUI
import Meee2PluginKit

/// Plugin Session 行视图 - 展开状态下的单个 plugin session 显示
/// 固定高度 56px（增加以显示 last message）
struct PluginSessionRowView: View {
    let session: PluginSession
    let pluginInfo: (displayName: String, icon: String, themeColor: Color)?
    let onOpenTerminal: () -> Void
    /// 其他活跃 session（用于右键 "Connect to..." 列表）；默认为空以保持旧调用点兼容
    var otherActiveSessions: [PluginSession] = []
    /// 用户点击某个目标 session 时回调 —— 父视图负责打开 A2AConnectSheet
    var onConnectRequest: ((PluginSession) -> Void)? = nil

    @State private var isHovered = false

    // 固定高度（简化后减小）
    private let rowHeight: CGFloat = 44

    // 按钮 label 根据 plugin 类型
    private var buttonLabel: String {
        if session.pluginId.contains("aime") {
            return "Open"
        } else if session.pluginId.contains("cursor") {
            return "IDE"
        }
        return "Open"
    }

    /// session.status 现在就是 resolver 统一解析后的值（Island / TUI / Web 三端同源）
    private var effectiveDetailedStatus: SessionStatus {
        session.status
    }

    /// StateTrace 日志用：把 SessionStatus.color 转成可读字符串（SwiftUI Color
    /// 的 description 在日志里太长，这里根据 case 反推）
    private func colorName(_ s: SessionStatus) -> String {
        switch s {
        case .permissionRequired: return "orange"
        case .thinking, .tooling, .active, .compacting: return "blue"
        case .idle, .completed, .waitingForUser: return "gray"
        case .dead: return "red"
        }
    }

    /// 右侧状态文字：如果 lastMessage 存在，显示 subtitle；否则显示状态名
    private var rightStatusText: String {
        if session.lastMessage != nil {
            return session.subtitle ?? effectiveDetailedStatus.displayName
        } else {
            return effectiveDetailedStatus.displayName
        }
    }

    /// 第二行显示的消息：优先 lastMessage，fallback subtitle
    private var displayMessage: String? {
        session.lastMessage ?? session.subtitle
    }

    /// A2A inbox 待取消息数（0 时不显示徽章）
    /// session.id 对 Claude plugin 而言即 sessionId；其他 plugin 不在 A2A 中，peekInbox 会返回空
    private var inboxCount: Int {
        MessageRouter.shared.peekInbox(sessionId: session.id).count
    }

    var body: some View {
        Button(action: onOpenTerminal) {
            HStack(spacing: 10) {
                // Plugin 图标 + 状态
                ZStack {
                    Circle()
                        .fill((pluginInfo?.themeColor ?? .blue).opacity(0.2))
                        .frame(width: 28, height: 28)

                    Image(systemName: session.icon ?? pluginInfo?.icon ?? "questionmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(session.accentColor ?? pluginInfo?.themeColor ?? .blue)
                }
                .overlay(
                    // 精细状态指示器
                    Circle()
                        .fill(effectiveDetailedStatus.color)
                        .frame(width: 8, height: 8)
                        .offset(x: 10, y: 10)
                )

                // 项目信息 - 简化为两行
                VStack(alignment: .leading, spacing: 2) {
                    // 第一行：标题 + 时间
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // 时间
                        Text(session.formattedDuration)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .monospacedDigit()
                    }

                    // 第二行：Plugin名称 + 消息（优先 lastMessage，fallback subtitle）
                    HStack(spacing: 6) {
                        // Plugin 名称
                        Text(pluginInfo?.displayName ?? "Plugin")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(session.accentColor ?? pluginInfo?.themeColor ?? .blue)

                        // 消息
                        if let msg = displayMessage, !msg.isEmpty {
                            Text(msg)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                // 右侧：状态 + 使用统计
                VStack(alignment: .trailing, spacing: 2) {
                    // 状态文字：如果 lastMessage 存在，显示 subtitle 或状态；否则显示状态
                    Text(rightStatusText)
                        .font(.system(size: 9))
                        .foregroundColor(effectiveDetailedStatus.needsUserAction ? .orange : .white.opacity(0.5))
                        .lineLimit(1)

                    // 任务进度 + 使用统计 + A2A inbox 徽章
                    HStack(spacing: 6) {
                        if let progress = session.progressText {
                            Text(progress)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.cyan)
                        }

                        if let stats = session.usageStats, stats.turns > 0 {
                            Text(stats.formattedCost)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.green.opacity(0.8))
                        }

                        // A2A 收件箱徽章：仅在有待取消息时显示
                        let count = inboxCount
                        if count > 0 {
                            Text("📨\(count)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            NSLog("[StateTrace][island-row] sid=\(session.id.prefix(8)) APPEAR status=\(session.status.rawValue) displayName=\(effectiveDetailedStatus.displayName) color=\(colorName(effectiveDetailedStatus))")
        }
        .onChange(of: session.status) { newValue in
            NSLog("[StateTrace][island-row] sid=\(session.id.prefix(8)) CHANGE → \(newValue.rawValue) displayName=\(newValue.displayName) color=\(colorName(newValue))")
        }
        .contextMenu {
            if otherActiveSessions.isEmpty {
                // 没有其他 session 时，展示一个 disabled 提示
                Text("Connect to... (no other sessions)")
            } else {
                Menu("Connect to...") {
                    ForEach(otherActiveSessions, id: \.id) { other in
                        Button(otherLabel(other)) {
                            onConnectRequest?(other)
                        }
                    }
                }
            }

            Divider()

            Button("Open terminal") { onOpenTerminal() }
        }
    }

    /// 子菜单项 label: "<title> · <short cwd>"
    private func otherLabel(_ other: PluginSession) -> String {
        let title = other.title
        if let cwd = other.cwd, !cwd.isEmpty {
            return "\(title) · \(shortCwd(cwd))"
        }
        return title
    }

    /// 把 "/Users/<user>/..." 折叠成 "~/..."
    private func shortCwd(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") {
            return "~" + String(cwd.dropFirst(home.count))
        }
        return cwd
    }
}

// MARK: - Preview

struct PluginSessionRowView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 6) {
            PluginSessionRowView(
                session: PluginSession(
                    id: "cursor-test-1",
                    pluginId: "com.meee2.plugin.cursor",
                    title: "MyProject",
                    status: .active,
                    startedAt: Date().addingTimeInterval(-120),
                    subtitle: "Writing code...",
                    toolName: "Edit",
                    cwd: "/tmp/test/project",
                    icon: "cursorarrow",
                    accentColor: .blue
                ),
                pluginInfo: ("Cursor", "cursorarrow", .blue),
                onOpenTerminal: { print("Open Cursor") }
            )

            PluginSessionRowView(
                session: PluginSession(
                    id: "copilot-test-1",
                    pluginId: "com.meee2.plugin.copilot",
                    title: "AnotherProject",
                    status: .permissionRequired,
                    startedAt: Date().addingTimeInterval(-300),
                    subtitle: "Permission required",
                    cwd: "/tmp/test/another"
                ),
                pluginInfo: ("Copilot", "sparkles", .purple),
                onOpenTerminal: { print("Open VSCode") }
            )
        }
        .padding()
        .frame(width: 400)
        .background(Color.black)
    }
}
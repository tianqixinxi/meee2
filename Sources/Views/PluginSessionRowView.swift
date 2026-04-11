import SwiftUI
import Meee2PluginKit

/// Plugin Session 行视图 - 展开状态下的单个 plugin session 显示
/// 固定高度 56px（增加以显示 last message）
struct PluginSessionRowView: View {
    let session: PluginSession
    let pluginInfo: (displayName: String, icon: String, themeColor: Color)?
    let onOpenTerminal: () -> Void

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

    /// 获取精细状态（优先使用详细状态，但需要结合 session.status 校正）
    private var effectiveDetailedStatus: DetailedStatus {
        // 如果有 detailedStatus 且不是 idle，直接使用
        if let ds = session.detailedStatus, ds != .idle {
            return ds
        }
        // 根据 status 推断（处理 detailedStatus 为 idle 但 status 为 running 的情况）
        switch session.status {
        case .running: return .active
        case .thinking: return .thinking
        case .tooling: return .tooling
        case .waitingInput: return .waitingForUser
        case .permissionRequest: return .permissionRequired
        case .failed: return .dead
        case .completed: return .completed
        case .compacting: return .compacting
        case .idle: return .idle
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

                    // 任务进度 + 使用统计
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
                    status: .running,
                    startedAt: Date().addingTimeInterval(-120),
                    subtitle: "Writing code...",
                    toolName: "Edit",
                    cwd: "/Users/test/project",
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
                    status: .permissionRequest,
                    startedAt: Date().addingTimeInterval(-300),
                    subtitle: "Permission required",
                    cwd: "/Users/test/another"
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
import SwiftUI
import Meee2PluginKit

/// Plugin Session 行视图 - 展开状态下的单个 plugin session 显示
/// 固定高度 56px（增加以显示 last message）
struct PluginSessionRowView: View {
    let session: PluginSession
    let pluginInfo: (displayName: String, icon: String, themeColor: Color)?
    let onOpenTerminal: () -> Void

    @State private var isHovered = false

    // 固定高度
    private let rowHeight: CGFloat = 56

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

                // 项目信息 - 固定宽度，截断显示
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Plugin 名称标签
                        Text(pluginInfo?.displayName ?? "Plugin")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(session.accentColor ?? pluginInfo?.themeColor ?? .blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill((session.accentColor ?? pluginInfo?.themeColor ?? .blue).opacity(0.2))
                            )

                        // 任务进度标签
                        if let progress = session.progressText {
                            Text(progress)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color.cyan.opacity(0.2))
                                )
                        }
                    }

                    // 副标题/状态 - 截断显示
                    HStack(spacing: 6) {
                        // 精细状态图标
                        if session.detailedStatus != nil {
                            Image(systemName: effectiveDetailedStatus.icon)
                                .font(.system(size: 9))
                                .foregroundColor(effectiveDetailedStatus.color)
                        }

                        Text(session.subtitle ?? session.status.description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // 工具名称
                        if let tool = session.toolName {
                            Text("• \(tool)")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }

                    // 最后消息 - 如果有
                    if let lastMsg = session.lastMessage, !lastMsg.isEmpty {
                        Text(lastMsg)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)

                Spacer()

                // 右侧：时间 + 使用统计
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.formattedDuration)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .monospacedDigit()

                    // 使用统计（如果有）
                    if let stats = session.usageStats, stats.turns > 0 {
                        HStack(spacing: 4) {
                            Text(stats.formattedTokens)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                            Text(stats.formattedCost)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.green.opacity(0.8))
                        }
                    } else if session.status.needsUserAction {
                        HStack(spacing: 2) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 8))
                            Text("Action")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .foregroundColor(.orange)
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
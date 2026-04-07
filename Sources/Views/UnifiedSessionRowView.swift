import SwiftUI
import PeerPluginKit

/// 统一 Session 行视图
/// 替代原有的 SessionRowView (AISession) 和 PluginSessionRowView (PluginSession)
/// 固定高度 44px
struct UnifiedSessionRowView: View {
    let session: Session
    let pluginInfo: (displayName: String, icon: String, themeColor: Color)?
    let onOpenTerminal: () -> Void

    @State private var isHovered = false

    private let rowHeight: CGFloat = 44

    private var displayIcon: String {
        session.iconOverride ?? pluginInfo?.icon ?? "brain.head.profile"
    }

    private var displayColor: Color {
        if let hex = session.colorOverride, let color = Color(hex: hex) {
            return color
        }
        return pluginInfo?.themeColor ?? .blue
    }

    var body: some View {
        Button(action: onOpenTerminal) {
            HStack(spacing: 10) {
                // 图标 + 状态指示器
                ZStack {
                    Circle()
                        .fill(displayColor.opacity(0.2))
                        .frame(width: 28, height: 28)

                    Image(systemName: displayIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(displayColor)
                }
                .overlay(
                    Circle()
                        .fill(session.status.color)
                        .frame(width: 8, height: 8)
                        .offset(x: 10, y: 10)
                )

                // 项目信息
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // 插件名称标签
                        Text(pluginInfo?.displayName ?? "AI")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(displayColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(displayColor.opacity(0.2))
                            )
                    }

                    // 副标题/状态
                    Text(session.subtitle ?? session.status.description)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 280, alignment: .leading)

                Spacer()

                // 右侧：时间 + 操作提示
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.formattedDuration)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .monospacedDigit()

                    if session.status.needsUserAction {
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

// MARK: - Color Hex Extension

private extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let rgb = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

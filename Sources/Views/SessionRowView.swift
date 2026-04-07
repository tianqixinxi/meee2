import SwiftUI

/// Session 行视图 - 展开状态下的单个 session 显示
/// 固定高度 44px，内容截断显示
struct SessionRowView: View {
    let session: AISession
    let onOpenTerminal: () -> Void
    let onConfirm: (() -> Void)?

    @State private var isHovered = false

    // 固定高度
    private let rowHeight: CGFloat = 44

    var body: some View {
        Button(action: onOpenTerminal) {
            HStack(spacing: 10) {
                // 类型图标 + 状态
                ZStack {
                    Circle()
                        .fill(session.type.themeColor.opacity(0.2))
                        .frame(width: 28, height: 28)

                    Image(systemName: session.type.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(session.type.themeColor)
                }
                .overlay(
                    Circle()
                        .fill(session.status.color)
                        .frame(width: 8, height: 8)
                        .offset(x: 10, y: 10)
                )

                // 项目信息 - 固定宽度，截断显示
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.projectName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // 类型标签
                        Text(session.type.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(session.type.themeColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(session.type.themeColor.opacity(0.2))
                            )
                    }

                    // 任务/状态 - 截断显示
                    Text(session.currentTask ?? session.status.description)
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

// MARK: - PreviewProvider

struct SessionRowView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 6) {
            SessionRowView(
                session: AISession(
                    id: "test-1",
                    pid: 1234,
                    cwd: "/Users/test/project",
                    startedAt: Date().addingTimeInterval(-120),
                    type: .claude,
                    status: .running,
                    currentTask: "Writing code...",
                    toolName: "Write"
                ),
                onOpenTerminal: { print("Open terminal") },
                onConfirm: nil
            )

            SessionRowView(
                session: AISession(
                    id: "test-2",
                    pid: 1235,
                    cwd: "/Users/test/urgent",
                    startedAt: Date().addingTimeInterval(-300),
                    type: .cursor,
                    status: .permissionRequest,
                    currentTask: "Permission required"
                ),
                onOpenTerminal: { print("Open terminal") },
                onConfirm: { print("Confirmed") }
            )

            SessionRowView(
                session: AISession(
                    id: "test-3",
                    pid: 1236,
                    cwd: "/Users/test/completed",
                    startedAt: Date().addingTimeInterval(-600),
                    type: .copilot,
                    status: .completed
                ),
                onOpenTerminal: { print("Open terminal") },
                onConfirm: nil
            )
        }
        .padding()
        .frame(width: 400)
        .background(Color.black)
    }
}
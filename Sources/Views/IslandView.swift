import SwiftUI
import Meee2PluginKit

/// 展开模式
enum ExpandMode {
    case manual    // 手动点击展开 → 8 秒后自动关闭
    case hover     // 悬停触发展开 → 离开后 1 秒关闭
    case auto      // urgent 自动展开 → 不自动关闭
}

/// 灵动岛主视图
/// 设计理念：
/// - 收起状态：完整黑色背景，凹形圆角，信息分布在左右两侧和刘海下方
/// - 展开状态：刘海下方显示 sessions 列表
/// - 自动收起：展开后无操作一段时间自动收起
public struct IslandView: View {
    @ObservedObject var statusManager: StatusManager
    @StateObject private var buddyReader = BuddyReader.shared

    // MARK: - Init

    public init(statusManager: StatusManager) {
        self.statusManager = statusManager
    }

    // MARK: - AppStorage Settings

    /// 收起状态是否展示 session 信息
    @AppStorage("showSessionInCompact") private var showSessionInCompact: Bool = true

    /// 是否显示 buddy
    @AppStorage("showBuddy") private var showBuddy: Bool = true

    /// 轮播时长 (秒)
    @AppStorage("carouselInterval") private var carouselInterval: Double = 10

    @State private var isExpanded = false
    @State private var expandMode: ExpandMode = .manual
    @State private var isClosing = false  // 正在关闭动画中，保持内容显示
    @State private var autoCloseTimer: Timer?
    @State private var carouselTimer: Timer?
    @State private var carouselIndex: Int = 0

    // MARK: - Hover State

    @State private var isHovered = false
    @State private var hoverExpandTimer: Timer?
    @State private var hoverCloseTimer: Timer?

    // MARK: - Animation State

    @State private var statusOpacity: Double = 1.0
    @State private var attentionOpacity: Double = 1.0
    @State private var breathTimer: Timer?
    @State private var attentionTimer: Timer?

    /// 是否有活跃 session
    private var hasActiveSessions: Bool {
        !statusManager.sessions.isEmpty
    }

    // MARK: - Constants

    private let animation: Animation = .interactiveSpring(duration: 0.5, extraBounce: 0.2, blendDuration: 0.1)
    private let autoCloseInterval: TimeInterval = 8
    private let hoverExpandDelay: TimeInterval = 0.3  // 悬停展开延迟
    private let hoverCloseDelay: TimeInterval = 1.0   // 悬停离开后关闭延迟

    /// 收起状态高度（包含刘海高度 + 下方内容区）
    private let compactExtraHeight: CGFloat = 28// 刘海下方额外高度

    /// 展开后的尺寸
    private let expandedWidth: CGFloat = 500
    private let expandedMinHeight: CGFloat = 120  // 最小高度
    private let expandedMaxHeight: CGFloat = 700  // 最大高度

    private let spacing: CGFloat = 12

    // MARK: - Computed Properties

    /// 是否是外接显示器（无刘海）
    private var isExternalDisplay: Bool { statusManager.notchSize.width == 0 }

    private var notchWidth: CGFloat {
        if isExternalDisplay { return 0 }
        return max(statusManager.notchSize.width, 200)
    }
    private var notchHeight: CGFloat { statusManager.notchSize.height > 0 ? statusManager.notchSize.height : 32 }

    /// 动态圆角（根据刘海高度调整）
    private var expandedCornerRadius: CGFloat { notchHeight * 0.35 }
    private var topConcaveRadius: CGFloat { notchHeight * 0.3 }
    private var bottomCornerRadius: CGFloat { notchHeight * 0.4 }

    /// 收起状态总宽度（外接显示器时更宽以容纳轮播信息）
    private var compactWidth: CGFloat { isExternalDisplay ? 300 : notchWidth + 60 }

    /// 左右两侧宽度（外接显示器固定 40，内置屏根据刘海计算）
    private var sideWidth: CGFloat { isExternalDisplay ? 40 : (compactWidth - notchWidth) / 2 }

    /// 收起状态总高度（刘海 + 下方内容）
    /// 外接显示器时固定为 notchHeight，内置屏根据 showSessionInCompact 决定
    private var compactHeight: CGFloat {
        if isExternalDisplay {
            return notchHeight  // 外接显示器固定高度
        }
        if showSessionInCompact {
            return notchHeight + compactExtraHeight
        } else {
            return notchHeight
        }
    }

    /// 动态计算展开高度
    private var calculatedExpandedHeight: CGFloat {
        let height = contentHeight
        return min(max(height, expandedMinHeight), expandedMaxHeight)
    }

    /// 计算内容实际高度（不含最大高度限制）
    private var contentHeight: CGFloat {
        var height = notchHeight + spacing * 2  // 顶部刘海 + 上下 padding

        // urgent panels 高度 (固定布局)
        if statusManager.hasUrgentSession {
            let urgentCount = min(statusManager.urgentSessions.count, 3)
            for (index, _) in statusManager.urgentSessions.prefix(3).enumerated() {
                height += urgentPanelFixedHeight
                if index < urgentCount - 1 {
                    height += spacing
                }
            }
        }

        // session list 高度 (非 auto 模式时显示)
        if expandMode != .auto {
            height += spacing  // divider

            let totalSessions = statusManager.sessions.count
            if totalSessions > 0 {
                // 每个 session 行约 56
                height += min(CGFloat(totalSessions) * 56, 250)

                // Buddy 高度（session 数 <= 4 时显示）
                if showBuddy, buddyReader.buddy != nil, totalSessions <= 4 {
                    height += 55  // buddy 区域高度
                }
            } else {
                // 空状态包含 buddy
                height += 120  // 空状态高度
            }
        }

        return height
    }

    /// Urgent panel 固定布局高度
    /// header(44) + message(104) + buttons(36) + spacing(12*2) + padding(14*2) = 236
    private let urgentPanelFixedHeight: CGFloat = 188

    /// 估算 message 高度（已弃用，使用固定布局）
    private func estimateMessageHeight(for message: String?) -> CGFloat {
        guard let message = message, !message.isEmpty else { return 0 }
        let lineCount = max(1, Int(ceil(Double(message.count) / 65.0)))
        let estimatedHeight = CGFloat(lineCount) * 18 + 20
        // 最小 60，最大 200
        return max(60, min(estimatedHeight, 200))
    }

    /// 是否需要滚动
    private var needsScroll: Bool {
        contentHeight > expandedMaxHeight
    }

    /// 当前轮播的 session
    private var currentCarouselSession: PluginSession? {
        let sessions = statusManager.sessions
        guard !sessions.isEmpty else { return nil }
        let index = carouselIndex % sessions.count
        return sessions[index]
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // 背景
                islandBackground

                // 内容层
                if isExpanded {
                    expandedContent
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                } else {
                    compactContent
                        .transition(.opacity)
                }
            }
            .frame(width: isExpanded ? expandedWidth : compactWidth)
            .frame(height: isExpanded ? calculatedExpandedHeight : compactHeight)
            .clipped()
            .contentShape(Rectangle())  // 扩大点击区域到整个 frame
            .onHover { hovering in
                handleHover(hovering)
            }
            .onTapGesture {
                if !isExpanded {
                    toggleExpanded()
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: isExpanded)
        .onAppear { startCarousel() }
        .onDisappear { stopCarousel() }
        .onChange(of: statusManager.hasUrgentSession) { needsAttention in
            NSLog("[IslandView] hasUrgentSession changed to: \(needsAttention), isExpanded: \(isExpanded)")
            if needsAttention && !isExpanded {
                // 需要用户介入时自动展开
                NSLog("[IslandView] Auto expanding due to urgent session")
                openExpanded()
            } else if !needsAttention && isExpanded && expandMode == .auto {
                // urgent 消失且是自动展开模式时，收起视图
                NSLog("[IslandView] Auto closing due to urgent session cleared")
                closeExpanded()
            }
        }
        .onChange(of: statusManager.systemStatus) { newStatus in
            NSLog("[IslandView] systemStatus changed to: \(newStatus)")
            if newStatus == .needsAttention && !isExpanded {
                openExpanded()
            }
        }
    }

    // MARK: - Background

    private var islandBackground: some View {
        Group {
            if isExpanded {
                IslandExpandShape(notchWidth: notchWidth, cornerRadius: expandedCornerRadius)
                    .fill(.black)
                    .frame(width: expandedWidth, height: calculatedExpandedHeight)
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            } else {
                // 收起状态：完整背景，顶部凹形圆角
                ConcaveTopShape(
                    topRadius: topConcaveRadius,
                    bottomRadius: bottomCornerRadius
                )
                .fill(.black)
                .frame(width: compactWidth, height: compactHeight)
            }
        }
    }

    // MARK: - Compact Content

    @ViewBuilder
    private var compactContent: some View {
        VStack(spacing: 0) {
            // 顶部：刘海区域 - 左侧显示产品图标，右侧显示状态图标
            HStack(spacing: 0) {
                // 左侧：产品图标（活跃时呼吸动效）
                HStack {
                    if hasActiveSessions {
                        let carousel = currentCarouselSession
                        let ds = carousel.map { effectiveDetailedStatus(for: $0) }
                        let hasAnimation = ds?.animation != StatusAnimation.none
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.orange)
                            .opacity(hasAnimation ? statusOpacity : 1.0)
                    } else {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.orange.opacity(0.5))
                    }
                }
                .padding(.leading, 12)
                .frame(width: sideWidth, height: notchHeight)

                // 中间：外接显示器直接显示轮播信息，内置屏留空
                if isExternalDisplay {
                    // 外接显示器：中间直接显示轮播信息
                    HStack(spacing: 8) {
                        if let session = currentCarouselSession {
                            Circle()
                                .fill(session.status.color)
                                .frame(width: 6, height: 6)

                            Text(session.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            if let subtitle = session.subtitle, !subtitle.isEmpty {
                                Text(subtitle.count > 20 ? String(subtitle.prefix(20)) + "…" : subtitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(1)
                            } else if let lastMsg = session.lastMessage, !lastMsg.isEmpty {
                                // 显示 lastMessage（当没有 subtitle 时）
                                Text(lastMsg.count > 25 ? String(lastMsg.prefix(25)) + "…" : lastMsg)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }

                            if session.status.needsUserAction {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                            }

                            Spacer()

                            Text(session.formattedDuration)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .monospacedDigit()
                        } else {
                            Text("No active sessions")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Spacer()
                }

                // 右侧：精细状态图标（呼吸动效或闪烁动效）
                HStack(spacing: 3) {
                    if let session = currentCarouselSession {
                        let ds = effectiveDetailedStatus(for: session)
                        let dsColor = ds.color

                        // 状态图标（已包含状态指示，无需额外显示点）
                        Image(systemName: ds.sfSymbolName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(dsColor)
                            .opacity(ds.animation == .bounce ? attentionOpacity :
                                     ds.animation == .pulse ? statusOpacity : 1.0)

                        // 任务进度（如果有）
                        if let progress = session.progressText {
                            Text(progress)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.cyan)
                        }
                    }
                }
                .padding(.trailing, 12)
                .frame(width: sideWidth, height: notchHeight)
            }
            .frame(height: notchHeight)

            // 刘海下方内容 - 仅内置屏且开启session显示时
            if !isExternalDisplay && showSessionInCompact {
                // Session 轮播信息
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        if let session = currentCarouselSession {
                            let ds = effectiveDetailedStatus(for: session)

                            Circle()
                                .fill(ds.color)
                                .frame(width: 6, height: 6)

                            Text(session.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            // 精细状态图标
                            Image(systemName: ds.sfSymbolName)
                                .font(.system(size: 9))
                                .foregroundColor(ds.color.opacity(0.8))

                            if let subtitle = session.subtitle, !subtitle.isEmpty {
                                Text(subtitle.count > 20 ? String(subtitle.prefix(20)) + "…" : subtitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(1)
                            } else if let lastMsg = session.lastMessage, !lastMsg.isEmpty {
                                // 显示 lastMessage（当没有 subtitle 时）
                                Text(lastMsg.count > 25 ? String(lastMsg.prefix(25)) + "…" : lastMsg)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }

                            // 任务进度标签
                            if let progress = session.progressText {
                                Text(progress)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.cyan)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.cyan.opacity(0.2)))
                            }

                            // 用户需要介入提示
                            if ds.needsUserAction {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                            }

                            Spacer()

                            // 时间 + 使用统计
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(session.formattedDuration)
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.5))
                                    .monospacedDigit()

                                // 使用统计（如果有）
                                if let stats = session.usageStats, stats.turns > 0 {
                                    Text(stats.formattedCost)
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(.green.opacity(0.7))
                                }
                            }
                        } else {
                            Text("No active sessions")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }

                    // 轮播指示器
                    carouselIndicators
                }
                .padding(.horizontal, 12)
                .frame(height: compactExtraHeight)
            }
        }
        .frame(width: compactWidth, height: compactHeight)
    }

    // MARK: - Carousel Indicators

    @ViewBuilder
    private var carouselIndicators: some View {
        let totalCount = statusManager.sessions.count

        if totalCount > 1 {
            HStack(spacing: 4) {
                ForEach(0..<totalCount, id: \.self) { index in
                    Circle()
                        .fill(index == carouselIndex % totalCount ? Color.white.opacity(0.8) : Color.white.opacity(0.3))
                        .frame(width: 4, height: 4)
                }
            }
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 0) {
            // 顶部刘海区域 - 左侧 Sessions 标题，右侧菜单按钮
            HStack(spacing: 0) {
                // 左侧：Sessions 标题
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.leading, spacing)

                Spacer()

                // 右侧：菜单按钮
                Menu {
                    Button("Settings...") {
                        NotificationCenter.default.post(name: NSNotification.Name("openSettings"), object: nil)
                    }
                    Divider()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.trailing, spacing)
            }
            .frame(height: notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded() }

            // 刘海下方内容
            ScrollView {
                VStack(spacing: spacing) {
                    // 如果正在关闭动画中，显示占位内容防止黑屏
                    if isClosing {
                        Color.black.opacity(0.01)  // 几乎不可见，但占位
                            .frame(height: 100)
                    } else {
                        // 紧急信息面板 - 显示所有（最多3个）
                        if statusManager.hasUrgentSession {
                            ForEach(statusManager.urgentSessions.prefix(3)) { session in
                                urgentPanel(session: session)
                            }
                        }

                        // 常规 session 列表 - 非 auto 模式时显示
                        if expandMode != .auto {
                            Divider().background(Color.white.opacity(0.15))

                            if statusManager.sessions.isEmpty {
                                // 空状态 - 显示帮助提示和 buddy
                                VStack(spacing: 12) {
                                    // Buddy 动画
                                    if showBuddy, let buddy = buddyReader.buddy {
                                        BuddyASCIIView(buddy: buddy)
                                            .frame(width: 80, height: 55)
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "brain.head.profile")
                                            .font(.system(size: 28))
                                            .foregroundColor(.orange.opacity(0.6))
                                    }

                                    VStack(spacing: 4) {
                                        Text("No active sessions")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white.opacity(0.7))

                                        Text("Run 'claude' in terminal to start")
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                }
                                .frame(height: 120)
                            } else {
                                LazyVStack(spacing: 6) {
                                    // 统一的 session 列表
                                    ForEach(statusManager.sessions) { session in
                                        PluginSessionRowView(
                                            session: session,
                                            pluginInfo: statusManager.getPluginInfo(for: session.pluginId),
                                            onOpenTerminal: { statusManager.activateTerminal(for: session) }
                                        )
                                    }
                                }

                                // Buddy 在底部右下角显示（session 数量 <= 4 时）
                                if showBuddy, let buddy = buddyReader.buddy,
                                   statusManager.sessions.count <= 4 {
                                    HStack {
                                        Spacer()
                                        BuddyASCIIView(buddy: buddy)
                                            .frame(width: 80, height: 50)
                                            .scaleEffect(0.7)
                                    }
                                    .padding(.top, 8)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, spacing)
                .padding(.bottom, spacing)
            }
            .scrollIndicators(needsScroll ? .visible : .hidden)
        }
        .frame(width: expandedWidth, height: calculatedExpandedHeight)
    }

    // MARK: - Urgent Panel (固定布局)

    @ViewBuilder
    private func urgentPanel(session: PluginSession) -> some View {
        if let event = session.urgentEvent {
            VStack(spacing: 4) {
                // Header: icon + title + 状态标签 + buttons，固定高度 44
                urgentPanelHeaderWithButtons(session: session, event: event)
                    .frame(height: 44)

                // Message Box: 固定高度 120
                urgentPanelMessageFixed(message: event.message)
                    .frame(height: 120)
            }
            .padding(10)
            .background(urgentPanelBackground)
        }
    }

    @ViewBuilder
    private func urgentPanelHeaderWithButtons(session: PluginSession, event: UrgentEventInfo) -> some View {
        HStack(spacing: 6) {
            // Icon
            ZStack {
                Circle()
                    .fill((statusManager.getPluginInfo(for: session.pluginId)?.themeColor ?? .blue).opacity(0.3))
                    .frame(width: 24, height: 24)
                Image(systemName: statusManager.getPluginInfo(for: session.pluginId)?.icon ?? "brain.head.profile")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusManager.getPluginInfo(for: session.pluginId)?.themeColor ?? .blue)
            }

            // Title
            Text(session.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            // 状态标签
            HStack(spacing: 3) {
                Image(systemName: event.eventType == "permission" ? "lock.shield" : "bell.fill")
                    .font(.system(size: 9))
                Text(event.eventType == "permission" ? "Permission" : event.eventType)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.15)))

            Spacer()

            // Buttons in header (smaller size)
            urgentPanelHeaderButtons(session: session, event: event)
        }
    }

    /// Header 中的按钮（紧凑样式）
    @ViewBuilder
    private func urgentPanelHeaderButtons(session: PluginSession, event: UrgentEventInfo) -> some View {
        HStack(spacing: 6) {
            // Ignore 按钮
            Button(action: {
                NSLog("[IslandView] Ignore button clicked for session: \(session.id)")
                // 立即清除 urgentEvent 状态
                statusManager.clearUrgentEvent(session: session)
                // 设置正在关闭状态，防止动画期间黑屏
                isClosing = true
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded = false
                    expandMode = .manual
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isClosing = false
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                    Text("Ignore")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.2)))
            }
            .buttonStyle(.plain)

            // Open 按钮 - 跳转到终端
            Button(action: {
                NSLog("[IslandView] Open button clicked for session: \(session.id)")
                // 立即清除 urgentEvent 状态
                statusManager.clearUrgentEvent(session: session)
                // 设置正在关闭状态，防止动画期间黑屏
                isClosing = true
                // 收起视图
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded = false
                    expandMode = .manual
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isClosing = false
                    statusManager.activateTerminal(for: session)
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                        .font(.system(size: 8, weight: .medium))
                    Text("Open")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.blue.opacity(0.5)))
            }
            .buttonStyle(.plain)

            // Approve 按钮 - 仅权限请求时显示
            if event.eventType == "permission" && event.respond != nil {
                Button(action: {
                    NSLog("[IslandView] Approve button clicked for session: \(session.id)")
                    // 响应权限
                    event.respond?(.allow)
                    // 收起视图
                    isClosing = true
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = false
                        expandMode = .manual
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isClosing = false
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .medium))
                        Text("Approve")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func urgentPanelMessage(message: String?) -> some View {
        ScrollView {
            if let message = message, !message.isEmpty {
                Text(attributedStringFromMarkdown(message))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                Text("No message content")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(minHeight: 60, maxHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    /// 固定高度 Message 区域（用于固定布局，可滚动）
    @ViewBuilder
    private func urgentPanelMessageFixed(message: String?) -> some View {
        ScrollView {
            if let message = message, !message.isEmpty {
                Text(attributedStringFromMarkdown(message))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                Text("No message content")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(height: 120)  // 固定高度
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var urgentPanelBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Plugin Urgent Panel (固定布局)

    @ViewBuilder
    private func pluginUrgentPanel(session: PluginSession, message: String?) -> some View {
        VStack(spacing: 4) {
            // Header: icon + title + 状态标签 + buttons，固定高度 44
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill((session.accentColor ?? .green).opacity(0.3))
                        .frame(width: 24, height: 24)
                    Image(systemName: session.icon ?? "pawprint.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(session.accentColor ?? .green)
                }

                Text(session.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                // 状态标签
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9))
                    Text("新消息")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.15)))

                Spacer()

                // Ignore 按钮
                Button(action: {
                    // 设置正在关闭状态，防止动画期间黑屏
                    isClosing = true
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = false
                        expandMode = .manual
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isClosing = false
                        statusManager.dismissUrgent(sessionId: session.id)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .medium))
                        Text("Ignore")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)

                // Open 按钮
                Button(action: {
                    // 设置正在关闭状态，防止动画期间黑屏
                    isClosing = true
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = false
                        expandMode = .manual
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isClosing = false
                        statusManager.dismissUrgent(sessionId: session.id)
                        statusManager.activateTerminal(for: session)
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: session.pluginId.contains("aime") ? "globe" : "terminal")
                            .font(.system(size: 8, weight: .medium))
                        Text("Open")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
            }
            .frame(height: 44)

            // Message: 固定高度 120，可滚动
            ScrollView {
                if let message = message, !message.isEmpty {
                    Text(attributedStringFromMarkdown(message))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    Text("No message content")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .padding(10)
        .background(urgentPanelBackground)
    }

    // MARK: - Session Type Icon

    @ViewBuilder
    private func sessionTypeIcon(for type: SessionType, size: CGFloat = 12) -> some View {
        Image(systemName: type.icon)
            .font(.system(size: size, weight: .medium))
            .foregroundColor(type.themeColor)
    }

    // MARK: - Markdown Helper

    /// 将 markdown 字符串转换为 AttributedString
    private func attributedStringFromMarkdown(_ markdown: String) -> AttributedString {
        do {
            var attributedString = try AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            // 设置基础颜色
            for run in attributedString.runs {
                let range = run.range
                attributedString[range].foregroundColor = .white.opacity(0.85)
            }
            return attributedString
        } catch {
            // 如果解析失败，返回普通文本
            return AttributedString(markdown)
        }
    }

    // MARK: - Carousel

    private func startCarousel() {
        guard carouselTimer == nil else { return }
        carouselTimer = Timer.scheduledTimer(withTimeInterval: carouselInterval, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                let totalCount = self.statusManager.sessions.count
                if totalCount > 0 {
                    self.carouselIndex = (self.carouselIndex + 1) % totalCount
                }
            }
        }
        startBreathingAnimation()
    }

    private func stopCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = nil
        stopBreathingAnimation()
    }

    // MARK: - Breathing Animation

    private func startBreathingAnimation() {
        guard breathTimer == nil else { return }
        breathTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.75)) {
                self.statusOpacity = self.statusOpacity == 1.0 ? 0.6 : 1.0
            }
        }
        startAttentionAnimation()
    }

    private func stopBreathingAnimation() {
        breathTimer?.invalidate()
        breathTimer = nil
        statusOpacity = 1.0
        stopAttentionAnimation()
    }

    // MARK: - Attention Animation (faster flash for Ask/Perm states)

    private func startAttentionAnimation() {
        guard attentionTimer == nil else { return }
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                self.attentionOpacity = self.attentionOpacity == 1.0 ? 0.3 : 1.0
            }
        }
    }

    private func stopAttentionAnimation() {
        attentionTimer?.invalidate()
        attentionTimer = nil
        attentionOpacity = 1.0
    }

    // MARK: - Helper Functions

    private func truncatedTitle(_ title: String, maxChars: Int) -> String {
        if title.count <= maxChars { return title }
        return String(title.prefix(maxChars - 1)) + "…"
    }

    /// 获取有效的精细状态（当 detailedStatus 为 idle 但 status 为 running 时使用 active）
    private func effectiveDetailedStatus(for session: PluginSession) -> DetailedStatus {
        if let detailed = session.detailedStatus, detailed != .idle {
            return detailed
        }
        return DetailedStatus.from(sessionStatus: session.status)
    }

    // MARK: - Timer Management

    private func toggleExpanded() {
        // 清除所有悬停相关计时器
        cancelHoverTimers()

        withAnimation(animation) {
            isExpanded.toggle()
            expandMode = .manual
        }
        updateAutoCloseTimer()
    }

    private func openExpanded() {
        cancelHoverTimers()
        withAnimation(animation) {
            isExpanded = true
            expandMode = .auto
        }
        // auto 模式不设置自动关闭计时器
    }

    private func openByHover() {
        cancelHoverTimers()
        withAnimation(animation) {
            isExpanded = true
            expandMode = .hover
        }
        // hover 模式不设置自动关闭计时器，由悬停离开触发
    }

    private func closeExpanded() {
        cancelHoverTimers()
        withAnimation(animation) {
            isExpanded = false
            expandMode = .manual
        }
        cancelAutoCloseTimer()
    }

    private func updateAutoCloseTimer() {
        cancelAutoCloseTimer()
        // 只在 manual 模式时设置自动关闭
        guard isExpanded && expandMode == .manual else { return }
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: autoCloseInterval, repeats: false) { _ in
            withAnimation(self.animation) {
                self.isExpanded = false
                self.expandMode = .manual
            }
        }
    }

    private func cancelAutoCloseTimer() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
    }

    // MARK: - Hover Handling

    private func handleHover(_ hovering: Bool) {
        isHovered = hovering

        if hovering {
            // 悬停进入
            if !isExpanded {
                // 收起状态：延迟后展开
                hoverExpandTimer = Timer.scheduledTimer(withTimeInterval: hoverExpandDelay, repeats: false) { _ in
                    openByHover()
                }
            } else if expandMode == .hover {
                // 悬停展开模式下鼠标回到区域，取消关闭计时器
                hoverCloseTimer?.invalidate()
                hoverCloseTimer = nil
            }
        } else {
            // 悬停离开
            hoverExpandTimer?.invalidate()
            hoverExpandTimer = nil

            if expandMode == .hover {
                // 悬停展开模式下，延迟后关闭
                hoverCloseTimer = Timer.scheduledTimer(withTimeInterval: hoverCloseDelay, repeats: false) { _ in
                    closeExpanded()
                }
            }
        }
    }

    private func cancelHoverTimers() {
        hoverExpandTimer?.invalidate()
        hoverExpandTimer = nil
        hoverCloseTimer?.invalidate()
        hoverCloseTimer = nil
    }
}

// MARK: - Concave Top Shape (直角顶部)
/// 收起状态的灵动岛形状
/// 顶部直角，底部圆角
struct ConcaveTopShape: Shape {
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 顶部直角
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // 右边
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))

        // 右下角圆角
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            radius: bottomRadius
        )

        // 底边
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))

        // 左下角圆角
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
            radius: bottomRadius
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - Island Expand Shape

struct IslandExpandShape: Shape {
    let notchWidth: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // 展开状态：简单的圆角矩形，顶部填充完整黑色
        // 不需要刘海区域的凹陷
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

struct IslandView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .top) {
            Color.gray.opacity(0.3).ignoresSafeArea()
            VStack {
                IslandView(statusManager: {
                    let sm = StatusManager()
                    sm.notchSize = CGSize(width: 220, height: 38)
                    let s1 = PluginSession(
                        id: "com.meee2.plugin.claude-1",
                        pluginId: "com.meee2.plugin.claude",
                        title: "project-one",
                        status: .running,
                        startedAt: Date().addingTimeInterval(-120)
                    )
                    let s2 = PluginSession(
                        id: "com.meee2.plugin.cursor-2",
                        pluginId: "com.meee2.plugin.cursor",
                        title: "project-two",
                        status: .thinking,
                        startedAt: Date().addingTimeInterval(-300)
                    )
                    sm.sessions = [s1, s2]
                    return sm
                }())
                .frame(width: 500, height: 220)
                Spacer()
            }
        }
    }
}
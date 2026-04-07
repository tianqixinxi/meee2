import SwiftUI
import PeerPluginKit

/// 展开模式
enum ExpandMode {
    case manual    // 手动点击展开 → 8 秒后自动关闭
    case hover     // 悬停触发展开 → 离开后 1 秒关闭
    case auto      // urgent 自动展开 → 不自动关闭
}

/// 灵动岛主视图
public struct IslandView: View {
    @ObservedObject var coordinator: SessionCoordinator

    // MARK: - Init

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - AppStorage Settings

    @AppStorage("showSessionInCompact") private var showSessionInCompact: Bool = true
    @AppStorage("carouselInterval") private var carouselInterval: Double = 10

    @State private var isExpanded = false
    @State private var expandMode: ExpandMode = .manual
    @State private var autoCloseTimer: Timer?
    @State private var carouselTimer: Timer?
    @State private var carouselIndex: Int = 0

    // MARK: - Hover State

    @State private var isHovered = false
    @State private var hoverExpandTimer: Timer?
    @State private var hoverCloseTimer: Timer?

    // MARK: - Constants

    private let animation: Animation = .interactiveSpring(duration: 0.5, extraBounce: 0.2, blendDuration: 0.1)
    private let autoCloseInterval: TimeInterval = 8
    private let hoverExpandDelay: TimeInterval = 0.3
    private let hoverCloseDelay: TimeInterval = 1.0

    private let compactExtraHeight: CGFloat = 28
    private let bottomCornerRadius: CGFloat = 16
    private let topConcaveRadius: CGFloat = 12

    private let expandedWidth: CGFloat = 500
    private let expandedMinHeight: CGFloat = 120
    private let expandedMaxHeight: CGFloat = 700
    private let expandedCornerRadius: CGFloat = 20

    private let spacing: CGFloat = 12

    // MARK: - Computed Properties

    private var notchWidth: CGFloat { max(coordinator.notchSize.width, 200) }
    private var notchHeight: CGFloat { max(coordinator.notchSize.height, 32) }
    private var compactWidth: CGFloat { notchWidth + 60 }

    private var compactHeight: CGFloat {
        showSessionInCompact ? notchHeight + compactExtraHeight : notchHeight
    }

    private var sideWidth: CGFloat { (compactWidth - notchWidth) / 2 }

    /// 展开高度 — 使用固定值避免布局循环
    private var calculatedExpandedHeight: CGFloat { 400 }

    private let urgentPanelFixedHeight: CGFloat = 236

    private var needsScroll: Bool { true }

    /// 当前轮播的 session
    private var currentCarouselSession: Session? {
        let sessions = coordinator.sessions
        guard !sessions.isEmpty else { return nil }
        return sessions[carouselIndex % sessions.count]
    }

    // MARK: - Helper

    private func pluginInfo(for session: Session) -> (displayName: String, icon: String, themeColor: Color) {
        coordinator.getPluginInfo(for: session.pluginId) ?? ("AI", "brain.head.profile", .blue)
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                islandBackground

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
            .contentShape(Rectangle())
            .onHover { hovering in handleHover(hovering) }
            .onTapGesture { if !isExpanded { toggleExpanded() } }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(animation, value: isExpanded)
        .onAppear { startCarousel() }
        .onDisappear { stopCarousel() }
        .onChange(of: coordinator.hasUrgentSession) { needsAttention in
            if needsAttention && !isExpanded { openExpanded() }
        }
        .onChange(of: coordinator.systemStatus) { newStatus in
            if newStatus == .needsAttention && !isExpanded { openExpanded() }
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
                ConcaveTopShape(topRadius: topConcaveRadius, bottomRadius: bottomCornerRadius)
                    .fill(.black)
                    .frame(width: compactWidth, height: compactHeight)
            }
        }
    }

    // MARK: - Compact Content

    @ViewBuilder
    private var compactContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }
                .frame(width: sideWidth, height: notchHeight)

                Spacer()

                HStack {
                    if coordinator.sessions.count > 0 {
                        Text("\(coordinator.sessions.count)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .frame(width: sideWidth, height: notchHeight)
            }
            .frame(height: notchHeight)

            if showSessionInCompact {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        if let session = currentCarouselSession {
                            Circle()
                                .fill(session.status.color)
                                .frame(width: 6, height: 6)

                            Text(session.projectName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Text(session.subtitle ?? session.status.description)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)

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
                            if coordinator.isLoading {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                                        .scaleEffect(0.7)
                                    Text("Loading...")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            } else {
                                Text("No active sessions")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                    }

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
        let totalCount = coordinator.sessions.count
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
            HStack(spacing: 0) {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.leading, spacing)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))

                Spacer()

                if !coordinator.sessions.isEmpty {
                    Text("\(coordinator.sessions.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                        .padding(.trailing, spacing)
                }
            }
            .frame(height: notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded() }

            ScrollView {
                VStack(spacing: spacing) {
                    // 紧急面板（统一，不区分 Claude/Plugin）
                    if coordinator.hasUrgentSession {
                        ForEach(coordinator.urgentSessions.prefix(5)) { session in
                            urgentPanel(
                                session: session,
                                message: coordinator.urgentMessages[session.id],
                                eventType: coordinator.urgentEventType(for: session.id)
                            )
                        }
                    }

                    // 常规 session 列表
                    if expandMode != .auto {
                        Divider().background(Color.white.opacity(0.15))

                        if coordinator.sessions.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 28))
                                    .foregroundColor(.orange.opacity(0.6))

                                VStack(spacing: 4) {
                                    Text("No active sessions")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))

                                    Text("Run 'claude' in terminal to start a session")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                            .frame(height: 100)
                        } else {
                            LazyVStack(spacing: 6) {
                                ForEach(coordinator.sessions) { session in
                                    UnifiedSessionRowView(
                                        session: session,
                                        pluginInfo: pluginInfo(for: session),
                                        onOpenTerminal: { coordinator.activateTerminal(for: session) }
                                    )
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

    // MARK: - Urgent Panel (统一，适用所有插件)

    @ViewBuilder
    private func urgentPanel(session: Session, message: String?, eventType: String?) -> some View {
        let info = pluginInfo(for: session)
        VStack(spacing: 8) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(info.themeColor.opacity(0.3))
                        .frame(width: 28, height: 28)
                    Image(systemName: session.iconOverride ?? info.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(info.themeColor)
                }

                Text(session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let eventType = eventType {
                    HStack(spacing: 4) {
                        Image(systemName: eventType == "PermissionRequest" ? "lock.shield" : "bell.fill")
                            .font(.system(size: 10))
                        Text(eventType == "PermissionRequest" ? "Permission" : eventType)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                }

                Spacer()

                Text(session.formattedDuration)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .monospacedDigit()
            }
            .frame(height: 44)

            // Message
            urgentPanelMessageFixed(message: message)
                .frame(height: 104)

            // Buttons
            HStack(spacing: 10) {
                Spacer()

                Button(action: {
                    coordinator.dismissUrgent(sessionId: session.id)
                    closeExpanded()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                        Text("Ignore")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)

                Button(action: {
                    coordinator.activateTerminal(for: session)
                    coordinator.dismissUrgent(sessionId: session.id)
                    closeExpanded()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .medium))
                        Text("Open")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
            }
            .frame(height: 36)
        }
        .padding(12)
        .background(urgentPanelBackground)
    }

    /// 固定高度 Message 区域
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
        .frame(height: 80)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var urgentPanelBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Markdown Helper

    private func attributedStringFromMarkdown(_ markdown: String) -> AttributedString {
        do {
            var attributedString = try AttributedString(markdown: markdown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            for run in attributedString.runs {
                attributedString[run.range].foregroundColor = .white.opacity(0.85)
            }
            return attributedString
        } catch {
            return AttributedString(markdown)
        }
    }

    // MARK: - Carousel

    private func startCarousel() {
        guard carouselTimer == nil else { return }
        carouselTimer = Timer.scheduledTimer(withTimeInterval: carouselInterval, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                let totalCount = self.coordinator.sessions.count
                if totalCount > 0 {
                    self.carouselIndex = (self.carouselIndex + 1) % totalCount
                }
            }
        }
    }

    private func stopCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = nil
    }

    // MARK: - Timer Management

    private func toggleExpanded() {
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
    }

    private func openByHover() {
        cancelHoverTimers()
        withAnimation(animation) {
            isExpanded = true
            expandMode = .hover
        }
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
            if !isExpanded {
                hoverExpandTimer = Timer.scheduledTimer(withTimeInterval: hoverExpandDelay, repeats: false) { _ in
                    openByHover()
                }
            } else if expandMode == .hover {
                hoverCloseTimer?.invalidate()
                hoverCloseTimer = nil
            }
        } else {
            hoverExpandTimer?.invalidate()
            hoverExpandTimer = nil

            if expandMode == .hover {
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

// MARK: - Concave Top Shape

struct ConcaveTopShape: Shape {
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            radius: bottomRadius
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
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
                IslandView(coordinator: {
                    let c = SessionCoordinator()
                    c.notchSize = CGSize(width: 220, height: 38)
                    return c
                }())
                .frame(width: 500, height: 220)
                Spacer()
            }
        }
    }
}

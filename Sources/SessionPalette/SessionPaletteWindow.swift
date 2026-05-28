import Cocoa
import Combine
import SwiftUI

/// Session Palette 窗口 —— 轻量无边框窗口，包含搜索框和结果列表
public class SessionPaletteWindow: NSWindow {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.borderless, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        setupWindow()

        let hostingView = NSHostingView(rootView: SessionPaletteRootView(manager: .shared))
        hostingView.frame = NSRect(x: 0, y: 0, width: 680, height: 420)
        contentView = hostingView
    }

    private func setupWindow() {
        isOpaque = false
        alphaValue = 0.97
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = NSColor.windowBackgroundColor

        collectionBehavior = [.transient, .fullScreenAuxiliary]
        level = .floating
        hasShadow = true
        hidesOnDeactivate = true
        isMovableByWindowBackground = false

        appearance = NSAppearance(named: .darkAqua)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    /// 处理 Escape 键关闭
    public override func cancelOperation(_ sender: Any?) {
        SessionPaletteManager.shared.hide()
    }
}

private struct SessionPaletteRootView: View {
    @ObservedObject var manager: SessionPaletteManager
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var sessionStore = SessionStore.shared
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var statusFilter: SessionPaletteSearchEngine.StatusFilter = .all
    @State private var pluginFilter: String?
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let entries = currentEntries()
        let plugins = currentPlugins()
        VStack(spacing: 0) {
            header
            filterBar(plugins: plugins)
            Divider().opacity(0.25)
            if entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                SessionPaletteRow(
                                    entry: entry,
                                    selected: index == selectedIndex,
                                    onOpen: { select(entry) }
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selectedIndex) { next in
                        guard entries.indices.contains(next) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(entries[next].id, anchor: .center)
                        }
                    }
                }
            }
            footer(count: entries.count)
        }
        .frame(width: 680, height: 420)
        .background(SessionPaletteBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            searchFocused = true
            selectedIndex = 0
        }
        .onReceive(refreshTimer) { _ in refreshTick += 1 }
        .onChange(of: query) { _ in selectedIndex = 0 }
        .onChange(of: statusFilter) { _ in selectedIndex = 0 }
        .onChange(of: pluginFilter ?? "") { _ in selectedIndex = 0 }
        .onMoveCommand { direction in
            guard !entries.isEmpty else { return }
            switch direction {
            case .down:
                selectedIndex = min(entries.count - 1, selectedIndex + 1)
            case .up:
                selectedIndex = max(0, selectedIndex - 1)
            default:
                break
            }
        }
        .onExitCommand {
            manager.hide()
        }
        .toolbar {
            Button("Open") {
                if entries.indices.contains(selectedIndex) {
                    select(entries[selectedIndex])
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .hidden()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions, project, status, tool, message", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .font(.system(size: 17, weight: .medium))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session Palette")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Jump to live Claude, Codex, internal terminal, or Board session")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    manager.hide()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func filterBar(plugins: [(id: String, displayName: String, count: Int)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(title: "All", count: nil, active: statusFilter == .all && pluginFilter == nil) {
                    statusFilter = .all
                    pluginFilter = nil
                }
                ForEach([SessionPaletteSearchEngine.StatusFilter.active, .thinking, .tooling, .waitingForUser, .permissionRequired], id: \.self) { status in
                    FilterChip(title: statusLabel(status), count: nil, active: statusFilter == status) {
                        statusFilter = status
                    }
                }
                Divider()
                    .frame(height: 18)
                    .opacity(0.35)
                ForEach(plugins, id: \.id) { plugin in
                    FilterChip(title: plugin.displayName, count: plugin.count, active: pluginFilter == plugin.id) {
                        pluginFilter = plugin.id
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No matching live sessions")
                .font(.system(size: 14, weight: .semibold))
            Text("Start Claude or Codex, or clear the filters.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(count: Int) -> some View {
        HStack {
            Text("\(count) live session\(count == 1 ? "" : "s")")
            Spacer()
            Text("↑↓ select · Return open · Esc close")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.black.opacity(0.16))
    }

    private func currentEntries() -> [SessionPaletteEntry] {
        _ = refreshTick
        let engine = manager.searchEngine
        engine.query = query
        engine.statusFilter = statusFilter
        engine.pluginFilter = pluginFilter
        let entries = engine.search(
            sessions: pluginManager.sessions,
            storeSessions: sessionStore.sessions,
            internalSurfaces: InternalTerminalRuntime.shared.listSnapshots()
        )
        if selectedIndex >= entries.count {
            DispatchQueue.main.async {
                selectedIndex = max(0, entries.count - 1)
            }
        }
        return entries
    }

    private func currentPlugins() -> [(id: String, displayName: String, count: Int)] {
        _ = refreshTick
        return manager.searchEngine.distinctPlugins(
            sessions: pluginManager.sessions,
            internalSurfaces: InternalTerminalRuntime.shared.listSnapshots()
        )
    }

    private func select(_ entry: SessionPaletteEntry) {
        manager.selectAndJump(to: entry)
    }

    private func statusLabel(_ status: SessionPaletteSearchEngine.StatusFilter) -> String {
        switch status {
        case .all: return "All"
        case .active: return "Active"
        case .thinking: return "Thinking"
        case .tooling: return "Tooling"
        case .idle: return "Idle"
        case .waitingForUser: return "Waiting"
        case .permissionRequired: return "Permission"
        case .completed: return "Done"
        case .dead: return "Dead"
        }
    }
}

private struct SessionPaletteRow: View {
    let entry: SessionPaletteEntry
    let selected: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.18))
                    Image(systemName: entry.terminalKind == "internal" ? "terminal.fill" : "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(entry.status)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    HStack(spacing: 6) {
                        Text(entry.pluginDisplayName)
                        Text(entry.project)
                        if let tool = entry.currentTool, !tool.isEmpty {
                            Text(tool)
                        }
                        if let permission = entry.pendingPermissionTool, !permission.isEmpty {
                            Text("Permission: \(permission)")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let message = entry.lastMessage, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(relativeTime(entry.lastActivity))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(entry.terminalKind == "internal" ? "Board" : (entry.isTerminalJumpable ? "Jump" : "Open"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2, perform: onOpen)
    }

    private var statusColor: Color {
        switch entry.statusRaw {
        case .permissionRequired:
            return Color(red: 0.95, green: 0.62, blue: 0.34)
        case .thinking, .tooling, .active, .compacting:
            return Color(red: 0.55, green: 0.72, blue: 0.88)
        case .dead:
            return Color(red: 0.84, green: 0.36, blue: 0.32)
        case .idle, .waitingForUser, .completed:
            return Color(red: 0.67, green: 0.65, blue: 0.60)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count {
                    Text(String(count))
                        .foregroundStyle(active ? Color.black.opacity(0.7) : .secondary)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(active ? Color.white.opacity(0.82) : Color.white.opacity(0.06))
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.84))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct SessionPaletteBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            Color(red: 0.12, green: 0.12, blue: 0.11).opacity(0.78)
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

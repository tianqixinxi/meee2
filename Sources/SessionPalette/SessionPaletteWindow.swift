import Cocoa
import Combine
import Meee2PluginKit
import SwiftUI

private enum SessionPaletteStyle {
    static let windowRadius: CGFloat = 26
    static let searchRadius: CGFloat = 18
    static let rowRadius: CGFloat = 16
    static let chipRadius: CGFloat = 14
    static let statusRadius: CGFloat = 8

    static let background = Color(red: 0.149, green: 0.149, blue: 0.141)
    static let paper = Color(red: 0.173, green: 0.169, blue: 0.161)
    static let surface = Color(red: 0.188, green: 0.188, blue: 0.180)
    static let surfaceRaised = Color(red: 0.227, green: 0.227, blue: 0.220)
    static let accent = Color(red: 0.800, green: 0.471, blue: 0.361)
    static let text = Color(red: 0.961, green: 0.957, blue: 0.937)
    static let textDim = Color(red: 0.659, green: 0.647, blue: 0.608)
    static let border = Color(red: 0.290, green: 0.286, blue: 0.271)
}

/// Quick Open 窗口 —— 轻量无边框窗口，包含搜索框和结果列表
public class SessionPaletteWindow: NSWindow {
    public var onDidHide: (() -> Void)?

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
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = SessionPaletteStyle.windowRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        contentView = hostingView
    }

    private func setupWindow() {
        isOpaque = false
        alphaValue = 0.97
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear

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

    public override func resignKey() {
        super.resignKey()
        guard isVisible else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.orderOut(nil)
        }
    }

    public override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onDidHide?()
    }
}

private struct SessionPaletteRootView: View {
    @ObservedObject var manager: SessionPaletteManager
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var sessionStore = SessionStore.shared
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var domainFilter: SessionPaletteSearchEngine.DomainFilter = .all
    @State private var refreshTick = 0
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let data = currentSearchData()
        let entries = currentEntries(data: data)
        let counts = currentCounts(data: data)
        let safeSelectedIndex = clampedSelectedIndex(for: entries)
        VStack(spacing: 0) {
            header
            filterBar(counts: counts)
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
                                    selected: index == safeSelectedIndex,
                                    onOpen: { select(entry) }
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selectedIndex) { next in
                        let target = min(max(next, 0), max(entries.count - 1, 0))
                        guard entries.indices.contains(target) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(entries[target].id, anchor: .center)
                        }
                    }
                }
            }
            footer(count: entries.count)
        }
        .frame(width: 680, height: 420)
        .background(SessionPaletteBackground())
        .clipShape(RoundedRectangle(cornerRadius: SessionPaletteStyle.windowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SessionPaletteStyle.windowRadius, style: .continuous)
                .stroke(SessionPaletteStyle.border.opacity(0.92), lineWidth: 1)
        )
        .onAppear {
            searchFocused = true
            selectedIndex = 0
        }
        .onReceive(refreshTimer) { _ in refreshTick += 1 }
        .onChange(of: query) { _ in selectedIndex = 0 }
        .onChange(of: domainFilter) { _ in selectedIndex = 0 }
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
                if entries.indices.contains(safeSelectedIndex) {
                    select(entries[safeSelectedIndex])
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
                TextField("Meee2 search sessions, canvases, artifacts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .font(.system(size: 17, weight: .medium))
                    .onSubmit {
                        let entries = currentEntries(data: currentSearchData())
                        let index = clampedSelectedIndex(for: entries)
                        if entries.indices.contains(index) {
                            select(entries[index])
                        }
                    }
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
            .background(SessionPaletteStyle.surface.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: SessionPaletteStyle.searchRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SessionPaletteStyle.searchRadius, style: .continuous)
                    .stroke(SessionPaletteStyle.border.opacity(0.9), lineWidth: 1)
            )

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Open")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SessionPaletteStyle.text)
                }
                Spacer()
            }
        }
        .padding(14)
    }

    private func filterBar(counts: [SessionPaletteSearchEngine.DomainFilter: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SessionPaletteSearchEngine.DomainFilter.allCases, id: \.self) { domain in
                    FilterChip(title: domainLabel(domain), count: counts[domain], active: domainFilter == domain) {
                        domainFilter = domain
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
            Text("No matching items")
                .font(.system(size: 14, weight: .semibold))
            Text(hasActiveFilters ? "Clear filters or search another term." : "Sessions, canvases, and artifacts will appear here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if hasActiveFilters {
                Button("Clear filters") {
                    clearFilters()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(count: Int) -> some View {
        HStack {
            Text("\(count) result\(count == 1 ? "" : "s") · sorted by updated")
            Spacer()
            Text("↑↓ select · Return open · Esc close")
        }
        .font(.system(size: 11))
        .foregroundStyle(SessionPaletteStyle.textDim)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(SessionPaletteStyle.paper.opacity(0.9))
    }

    private struct SearchData {
        var sessions: [PluginSession]
        var storeSessions: [SessionData]
        var internalSurfaces: [TerminalSessionSnapshot]
        var canvases: [BoardLayoutStore.Canvas]
        var artifacts: [PlannerArtifact]
    }

    private func currentSearchData() -> SearchData {
        _ = refreshTick
        let snapshot = BoardLayoutStore.shared.snapshot()
        let artifacts = snapshot.canvases.flatMap { canvas -> [PlannerArtifact] in
            (try? PlannerBoardBridge.canvasState(
                for: canvas.id,
                snapshot: snapshot,
                actorUserId: PlannerPermission.currentActorId()
            ).artifacts) ?? []
        }
        return SearchData(
            sessions: pluginManager.sessions,
            storeSessions: sessionStore.sessions,
            internalSurfaces: TerminalSessionBackendRegistry.shared.listSnapshots(),
            canvases: snapshot.canvases,
            artifacts: artifacts
        )
    }

    private func currentEntries(data: SearchData) -> [SessionPaletteEntry] {
        let engine = manager.searchEngine
        engine.query = query
        engine.domainFilter = domainFilter
        engine.sortBy = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .lastActivity : .relevance
        let entries = engine.search(
            sessions: data.sessions,
            storeSessions: data.storeSessions,
            internalSurfaces: data.internalSurfaces,
            canvases: data.canvases,
            artifacts: data.artifacts
        )
        if selectedIndex >= entries.count {
            DispatchQueue.main.async {
                selectedIndex = max(0, entries.count - 1)
            }
        }
        return entries
    }

    private func currentCounts(data: SearchData) -> [SessionPaletteSearchEngine.DomainFilter: Int] {
        manager.searchEngine.counts(
            sessions: data.sessions,
            storeSessions: data.storeSessions,
            internalSurfaces: data.internalSurfaces,
            canvases: data.canvases,
            artifacts: data.artifacts
        )
    }

    private var hasActiveFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || domainFilter != .all
    }

    private func clearFilters() {
        query = ""
        domainFilter = .all
        selectedIndex = 0
        searchFocused = true
    }

    private func clampedSelectedIndex(for entries: [SessionPaletteEntry]) -> Int {
        guard !entries.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), entries.count - 1)
    }

    private func select(_ entry: SessionPaletteEntry) {
        manager.selectAndJump(to: entry)
    }

    private func domainLabel(_ domain: SessionPaletteSearchEngine.DomainFilter) -> String {
        switch domain {
        case .all: return "All"
        case .sessions: return "Sessions"
        case .canvases: return "Canvases"
        case .artifacts: return "Artifacts"
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
                    Image(systemName: iconName)
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
                            .clipShape(RoundedRectangle(cornerRadius: SessionPaletteStyle.statusRadius, style: .continuous))
                    }
                    HStack(spacing: 6) {
                        Text(kindLabel)
                        Text(entry.subtitle)
                        if let detail = entry.detail, !detail.isEmpty {
                            Text(detail)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(SessionPaletteStyle.textDim)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(relativeTime(entry.lastActivity))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SessionPaletteStyle.textDim)
                    Text(actionLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SessionPaletteStyle.textDim)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? SessionPaletteStyle.accent.opacity(0.18) : SessionPaletteStyle.surface.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: SessionPaletteStyle.rowRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SessionPaletteStyle.rowRadius, style: .continuous)
                    .stroke(selected ? SessionPaletteStyle.accent.opacity(0.42) : SessionPaletteStyle.border.opacity(0.78), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2, perform: onOpen)
    }

    private var iconName: String {
        switch entry.kind {
        case .session:
            return entry.terminalKind == "internal" ? "terminal.fill" : "arrow.up.right.square"
        case .canvas:
            return "rectangle.3.group"
        case .artifact:
            return "doc.text.fill"
        }
    }

    private var kindLabel: String {
        switch entry.kind {
        case .session: return "Session"
        case .canvas: return "Canvas"
        case .artifact: return "Artifact"
        }
    }

    private var actionLabel: String {
        switch entry.kind {
        case .session:
            return entry.terminalKind == "external" ? "Jump" : "Board"
        case .canvas, .artifact:
            return "Open"
        }
    }

    private var statusColor: Color {
        switch entry.statusRaw {
        case .some(.permissionRequired):
            return Color(red: 0.95, green: 0.62, blue: 0.34)
        case .some(.thinking), .some(.tooling), .some(.active), .some(.compacting):
            return Color(red: 0.55, green: 0.72, blue: 0.88)
        case .some(.dead):
            return Color(red: 0.84, green: 0.36, blue: 0.32)
        case .some(.idle), .some(.waitingForUser), .some(.completed), .none:
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
                        .foregroundStyle(active ? SessionPaletteStyle.text : SessionPaletteStyle.textDim)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(active ? SessionPaletteStyle.accent.opacity(0.22) : SessionPaletteStyle.surface.opacity(0.8))
            .foregroundStyle(active ? SessionPaletteStyle.text : SessionPaletteStyle.text.opacity(0.84))
            .clipShape(RoundedRectangle(cornerRadius: SessionPaletteStyle.chipRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SessionPaletteStyle.chipRadius, style: .continuous)
                    .stroke(active ? SessionPaletteStyle.accent.opacity(0.36) : SessionPaletteStyle.border.opacity(0.65), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SessionPaletteBackground: View {
    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
            SessionPaletteStyle.background.opacity(0.92)
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

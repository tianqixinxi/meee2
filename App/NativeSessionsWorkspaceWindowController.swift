import AppKit
import Combine
import meee2Kit
import Meee2PluginKit

@MainActor
final class NativeSessionsWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NativeSessionsWorkspaceWindowController()

    private static let frameAutosaveName = "meee2.native-sessions.window"

    private let workspaceController = NativeSessionsWorkspaceViewController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "meee2 Sessions"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)
        window.contentView = workspaceController.view
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(sessionId: String? = nil, surfaceId: String? = nil) {
        NSApp.setActivationPolicy(.regular)
        AppIconProvider.installDockTileIcon()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        workspaceController.activate(sessionId: sessionId, surfaceId: surfaceId)
    }

    func windowWillClose(_ notification: Notification) {
        workspaceController.suspend()
    }
}

@MainActor
final class NativeSessionsWorkspaceViewController: NSViewController {
    private let rootView = NSView()
    private let railView = NSView()
    private let rowStack = NSStackView()
    private let terminalHostView = NativeTerminalPaneHostView()
    private let titleLabel = NSTextField(labelWithString: "Sessions")
    private let countLabel = NSTextField(labelWithString: "0")
    private let searchField = NSSearchField()
    private let emptyTerminalLabel = NSTextField(labelWithString: "Select an internal session")
    private let registry: TerminalPaneRegistry

    private var cancellables: Set<AnyCancellable> = []
    private var selectedRailId: String?
    private var rowButtons: [String: NativeSessionRowButton] = [:]
    private var collapsedSectionIds: Set<String> = ["internal-inactive", "external-inactive"]
    private var searchQuery = ""
    private var lastRailSignature = ""
    private var pendingReloadWorkItem: DispatchWorkItem?
    private var terminalOnlyMode = false

    init() {
        registry = TerminalPaneRegistry(hostView: terminalHostView)

        super.init(nibName: nil, bundle: nil)
        view = rootView
        buildLayout()
        bindState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTerminalOnlyMode(_ terminalOnly: Bool) {
        guard terminalOnlyMode != terminalOnly else { return }
        terminalOnlyMode = terminalOnly
        railView.isHidden = terminalOnly
        lastRailSignature = ""
        if terminalOnly {
            selectedRailId = nil
            rowButtons.removeAll()
            rowStack.arrangedSubviews.forEach {
                rowStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        } else {
            reloadRows()
        }
    }

    func activate(
        sessionId: String? = nil,
        surfaceId: String? = nil,
        terminalOnly: Bool = false,
        tracePayload: [String: Any]? = nil
    ) {
        setTerminalOnlyMode(terminalOnly)
        if !terminalOnly {
            reloadRows()
        }
        if let target = resolveTarget(sessionId: sessionId, surfaceId: surfaceId) {
            focus(target, tracePayload: tracePayload)
        } else if terminalOnly {
            selectedRailId = nil
            registry.hideActive()
            emptyTerminalLabel.stringValue = "Select an internal session"
            emptyTerminalLabel.isHidden = false
        } else if selectedRailId == nil,
                  let first = internalSessions().first(where: {
                      $0.status == InternalTerminalLifecycle.starting.rawValue
                          || $0.status == InternalTerminalLifecycle.running.rawValue
                  }) ?? internalSessions().first {
            focus(first, tracePayload: tracePayload)
        }
    }

    func suspend() {
        registry.hideActive()
    }

    private func buildLayout() {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let split = NSStackView()
        split.orientation = .horizontal
        split.alignment = .height
        split.spacing = 0
        split.distribution = .fill
        split.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(split)

        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.wantsLayer = true
        railView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        railView.layer?.borderColor = NSColor.separatorColor.cgColor
        railView.layer?.borderWidth = 0.5
        split.addArrangedSubview(railView)

        let railHeader = NSStackView()
        railHeader.orientation = .horizontal
        railHeader.alignment = .centerY
        railHeader.spacing = 8
        railHeader.translatesAutoresizingMaskIntoConstraints = false
        railView.addSubview(railHeader)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        railHeader.addArrangedSubview(titleLabel)
        railHeader.addArrangedSubview(NSView())
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        railHeader.addArrangedSubview(countLabel)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search sessions"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.sendsWholeSearchString = false
        (searchField.cell as? NSSearchFieldCell)?.sendsSearchStringImmediately = true
        railView.addSubview(searchField)

        rowStack.orientation = .vertical
        rowStack.alignment = .width
        rowStack.spacing = 4
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = rowStack
        railView.addSubview(scrollView)

        let terminalShell = NSView()
        terminalShell.translatesAutoresizingMaskIntoConstraints = false
        terminalShell.wantsLayer = true
        terminalShell.layer?.backgroundColor = NSColor.black.cgColor
        split.addArrangedSubview(terminalShell)

        terminalHostView.translatesAutoresizingMaskIntoConstraints = false
        terminalHostView.wantsLayer = true
        terminalHostView.layer?.backgroundColor = NSColor.black.cgColor
        terminalHostView.onLayout = { [weak self] in
            self?.registry.layoutActive()
        }
        terminalShell.addSubview(terminalHostView)

        emptyTerminalLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyTerminalLabel.textColor = .secondaryLabelColor
        emptyTerminalLabel.alignment = .center
        emptyTerminalLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalShell.addSubview(emptyTerminalLabel)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            split.topAnchor.constraint(equalTo: rootView.topAnchor),
            split.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            railView.widthAnchor.constraint(equalToConstant: 304),

            railHeader.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 12),
            railHeader.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -12),
            railHeader.topAnchor.constraint(equalTo: railView.topAnchor, constant: 34),
            railHeader.heightAnchor.constraint(equalToConstant: 28),

            searchField.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: railHeader.bottomAnchor, constant: 6),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -8),
            rowStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            terminalHostView.leadingAnchor.constraint(equalTo: terminalShell.leadingAnchor),
            terminalHostView.trailingAnchor.constraint(equalTo: terminalShell.trailingAnchor),
            terminalHostView.topAnchor.constraint(equalTo: terminalShell.topAnchor),
            terminalHostView.bottomAnchor.constraint(equalTo: terminalShell.bottomAnchor),

            emptyTerminalLabel.centerXAnchor.constraint(equalTo: terminalShell.centerXAnchor),
            emptyTerminalLabel.centerYAnchor.constraint(equalTo: terminalShell.centerYAnchor)
        ])
    }

    private func bindState() {
        SessionStore.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleReloadRows()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("SessionsDidChange"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleReloadRows()
            }
            .store(in: &cancellables)

        PluginManager.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleReloadRows()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification, object: searchField)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.searchQuery = self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.reloadRows()
            }
            .store(in: &cancellables)
    }

    private func scheduleReloadRows() {
        guard !terminalOnlyMode else { return }
        pendingReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reloadRows()
        }
        pendingReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func reloadRows() {
        guard !terminalOnlyMode else { return }
        let allItems = sessionRailItems()
        let items = filteredItems(allItems)
        let sections = railSections(for: items)
        let signature = railSignature(for: sections, visibleCount: items.count, totalCount: allItems.count)
        if signature == lastRailSignature {
            updateCountLabel(visibleCount: items.count, totalCount: allItems.count)
            updateRowSelection()
            return
        }
        lastRailSignature = signature
        updateCountLabel(visibleCount: items.count, totalCount: allItems.count)
        rowStack.arrangedSubviews.forEach {
            rowStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowButtons.removeAll()

        if items.isEmpty {
            addEmptyRailMessage(totalCount: allItems.count)
        } else {
            sections.forEach(addSection)
        }

        let filteredIds = Set(items.map(\.id))
        let allIds = Set(allItems.map(\.id))
        let itemById = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        if let selectedRailId, filteredIds.contains(selectedRailId) {
            updateRowSelection()
            emptyTerminalLabel.isHidden = itemById[selectedRailId]?.isInternal == true
        } else if let selectedRailId, allIds.contains(selectedRailId) {
            updateRowSelection()
            emptyTerminalLabel.isHidden = itemById[selectedRailId]?.isInternal == true
        } else if let first = allItems.first(where: { $0.isInternal && $0.isActive }) ?? allItems.first(where: \.isInternal) {
            focus(first.surfaceSnapshot)
        } else {
            selectedRailId = nil
            registry.hideActive()
            emptyTerminalLabel.stringValue = items.filter { !$0.isInternal }.isEmpty
                ? "No live sessions"
                : "Select an external session to open it in its host app"
            emptyTerminalLabel.isHidden = false
        }
    }

    private func addSection(_ section: NativeSessionRailSection) {
        let isCollapsed = isSectionCollapsed(section)
        let header = NativeSessionSectionHeaderButton(
            sectionId: section.id,
            title: section.title,
            count: section.items.count,
            isCollapsed: isCollapsed
        )
        header.target = self
        header.action = #selector(toggleSection(_:))
        rowStack.addArrangedSubview(header)
        header.heightAnchor.constraint(equalToConstant: 26).isActive = true
        if !isCollapsed {
            section.items.forEach(addRow)
        }
    }

    private func addRow(_ item: NativeSessionRailItem) {
        let button = NativeSessionRowButton(item: item)
        button.target = self
        button.action = #selector(selectSessionRow(_:))
        button.isSelected = item.id == selectedRailId
        button.refresh()
        rowButtons[item.id] = button
        rowStack.addArrangedSubview(button)
        button.heightAnchor.constraint(equalToConstant: 64).isActive = true
    }

    private func addEmptyRailMessage(totalCount: Int) {
        let text = totalCount == 0 ? "No sessions" : "No matching sessions"
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(label)
        label.heightAnchor.constraint(equalToConstant: 52).isActive = true
    }

    private func updateCountLabel(visibleCount: Int, totalCount: Int) {
        countLabel.stringValue = searchQuery.isEmpty ? "\(totalCount)" : "\(visibleCount)/\(totalCount)"
    }

    private func updateRowSelection() {
        for (itemId, button) in rowButtons {
            button.isSelected = itemId == selectedRailId
            button.refresh()
        }
    }

    @objc private func selectSessionRow(_ sender: NativeSessionRowButton) {
        if sender.item.isInternal {
            focus(sender.item.surfaceSnapshot)
        } else {
            focusExternal(sender.item)
        }
    }

    @objc private func toggleSection(_ sender: NativeSessionSectionHeaderButton) {
        if collapsedSectionIds.contains(sender.sectionId) {
            collapsedSectionIds.remove(sender.sectionId)
        } else {
            collapsedSectionIds.insert(sender.sectionId)
        }
        reloadRows()
    }

    private func focus(_ surface: TerminalSessionSnapshot, tracePayload: [String: Any]? = nil) {
        selectedRailId = NativeSessionRailItem.internalId(for: surface)
        updateRowSelection()
        emptyTerminalLabel.isHidden = true
        if !registry.focus(surface: surface, tracePayload: tracePayload) {
            emptyTerminalLabel.stringValue = "Unable to open terminal surface"
            emptyTerminalLabel.isHidden = false
        }
    }

    private func focusExternal(_ item: NativeSessionRailItem) {
        selectedRailId = item.id
        updateRowSelection()
        registry.hideActive()
        emptyTerminalLabel.stringValue = "Opened in host app: \(item.title)"
        emptyTerminalLabel.isHidden = false
        if let pluginSession = item.pluginSession {
            PluginManager.shared.activateTerminal(for: pluginSession)
        } else if let external = item.externalSession {
            ExternalSessionActivator.activate(external)
        }
    }

    private func resolveTarget(sessionId: String?, surfaceId: String?) -> TerminalSessionSnapshot? {
        if let surfaceId, !surfaceId.isEmpty,
           let surface = TerminalSessionBackendRegistry.shared.snapshot(id: surfaceId) {
            return surface
        }
        if let sessionId, !sessionId.isEmpty,
           let surface = TerminalSessionBackendRegistry.shared.snapshot(id: sessionId) {
            return surface
        }
        return nil
    }

    private func sessionRailItems() -> [NativeSessionRailItem] {
        let internalSessions = internalSessions()
        let internalSessionIds = Set(internalSessions.map(\.sessionId))
        let internalItems = internalSessions.map(NativeSessionRailItem.internalSurface)
        let pluginItems = PluginManager.shared.sessions
            .filter { pluginSession in
                let realId = Self.realSessionId(for: pluginSession)
                return !internalSessionIds.contains(realId)
                    && SessionControlStore.shared.state(for: [pluginSession.id, realId]) == .active
            }
            .map(NativeSessionRailItem.pluginExternalSession)
        let pluginSessionIds = Set(PluginManager.shared.sessions.flatMap { [$0.id, Self.realSessionId(for: $0)] })
        let storeItems = SessionStore.shared.listAll()
            .filter { session in
                !internalSessionIds.contains(session.sessionId)
                    && !pluginSessionIds.contains(session.sessionId)
                    && session.terminalInfo?.termProgram != "meee2-ghostty-surface"
                    && SessionControlStore.shared.state(for: [session.sessionId]) == .active
            }
            .map(NativeSessionRailItem.externalSession)
        let externalItems = (pluginItems + storeItems).sorted { $0.updatedAt > $1.updatedAt }
        return internalItems + externalItems
    }

    private func filteredItems(_ items: [NativeSessionRailItem]) -> [NativeSessionRailItem] {
        guard !searchQuery.isEmpty else { return items }
        let query = searchQuery.lowercased()
        return items.filter { $0.matches(query: query) }
    }

    private func railSections(for items: [NativeSessionRailItem]) -> [NativeSessionRailSection] {
        [
            NativeSessionRailSection(
                id: "internal-active",
                title: "Internal active",
                items: items.filter { $0.isInternal && $0.isActive }
            ),
            NativeSessionRailSection(
                id: "external-active",
                title: "External active",
                items: items.filter { !$0.isInternal && $0.isActive }
            ),
            NativeSessionRailSection(
                id: "internal-inactive",
                title: "Internal inactive",
                items: items.filter { $0.isInternal && !$0.isActive }
            ),
            NativeSessionRailSection(
                id: "external-inactive",
                title: "External inactive",
                items: items.filter { !$0.isInternal && !$0.isActive }
            )
        ].filter { !$0.items.isEmpty }
    }

    private func isSectionCollapsed(_ section: NativeSessionRailSection) -> Bool {
        !searchQuery.isEmpty ? false : collapsedSectionIds.contains(section.id)
    }

    private func railSignature(for sections: [NativeSessionRailSection], visibleCount: Int, totalCount: Int) -> String {
        let sectionText = sections.map { section in
            let collapsed = isSectionCollapsed(section)
            let itemText = collapsed
                ? ""
                : section.items.map {
                    "\($0.id)|\($0.isInternal ? "i" : "e")|\($0.isActive ? "a" : "n")|\($0.status)|\($0.title)|\($0.subtitle)"
                }.joined(separator: "\u{1e}")
            return "\(section.id)|\(collapsed)|\(section.items.count)|\(itemText)"
        }.joined(separator: "\u{1f}")
        return "\(searchQuery)|\(visibleCount)|\(totalCount)|\(sectionText)"
    }

    private func internalSessions() -> [TerminalSessionSnapshot] {
        TerminalSessionBackendRegistry.shared.listSnapshots()
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func realSessionId(for session: PluginSession) -> String {
        let prefix = "\(session.pluginId)-"
        return session.id.hasPrefix(prefix)
            ? String(session.id.dropFirst(prefix.count))
            : session.id
    }
}

private struct NativeSessionRailSection {
    let id: String
    let title: String
    let items: [NativeSessionRailItem]
}

private struct NativeSessionRailItem {
    let id: String
    let title: String
    let subtitle: String
    let status: String
    let updatedAt: Date
    let surfaceSnapshot: TerminalSessionSnapshot
    let externalSession: SessionData?
    let pluginSession: PluginSession?
    let isInternal: Bool

    var isActive: Bool {
        if isInternal {
            return status == InternalTerminalLifecycle.starting.rawValue
                || status == InternalTerminalLifecycle.running.rawValue
        }
        guard let sessionStatus = SessionStatus(rawValue: status) else {
            return status == "active" || status == "running"
        }
        switch sessionStatus {
        case .active, .thinking, .tooling, .permissionRequired, .compacting:
            return true
        case .idle, .waitingForUser, .completed, .dead:
            return false
        }
    }

    func matches(query: String) -> Bool {
        let haystack = [
            id,
            title,
            subtitle,
            status,
            isInternal ? "internal" : "external",
            surfaceSnapshot.sessionId,
            surfaceSnapshot.surfaceId,
            surfaceSnapshot.provider,
            surfaceSnapshot.cwd
        ]
        return haystack.contains { $0.lowercased().contains(query) }
    }

    static func internalSurface(_ surface: TerminalSessionSnapshot) -> NativeSessionRailItem {
        NativeSessionRailItem(
            id: internalId(for: surface),
            title: "\(surface.provider.capitalized) - \(URL(fileURLWithPath: surface.cwd).lastPathComponent)",
            subtitle: surface.cwd,
            status: surface.status,
            updatedAt: surface.updatedAt,
            surfaceSnapshot: surface,
            externalSession: nil,
            pluginSession: nil,
            isInternal: true
        )
    }

    static func pluginExternalSession(_ session: PluginSession) -> NativeSessionRailItem {
        let fallbackCwd = session.cwd ?? session.title
        let snapshot = TerminalSessionSnapshot(
            sessionId: session.id,
            surfaceId: session.id,
            backend: .external,
            status: session.status.rawValue,
            pid: nil,
            cwd: fallbackCwd,
            command: "",
            provider: "external",
            canvasId: nil,
            nodeId: nil,
            createdAt: session.startedAt,
            updatedAt: session.lastUpdated ?? session.startedAt
        )
        let pluginName = PluginManager.shared.loadedPlugins[session.pluginId]?.displayName
            ?? session.pluginId
        let subtitle = [pluginName, fallbackCwd]
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
        return NativeSessionRailItem(
            id: "plugin:\(session.id)",
            title: session.title,
            subtitle: subtitle,
            status: session.status.rawValue,
            updatedAt: session.lastUpdated ?? session.startedAt,
            surfaceSnapshot: snapshot,
            externalSession: nil,
            pluginSession: session,
            isInternal: false
        )
    }

    static func externalSession(_ session: SessionData) -> NativeSessionRailItem {
        let fallbackCwd = session.cwd ?? session.project
        let placeholder = TerminalSessionSnapshot(
            sessionId: session.sessionId,
            surfaceId: session.sessionId,
            backend: .external,
            status: session.status.rawValue,
            pid: session.pid,
            cwd: fallbackCwd,
            command: "",
            provider: "external",
            canvasId: nil,
            nodeId: nil,
            createdAt: session.startedAt,
            updatedAt: session.lastActivity
        )
        return NativeSessionRailItem(
            id: "external:\(session.sessionId)",
            title: session.project,
            subtitle: fallbackCwd,
            status: session.status.rawValue,
            updatedAt: session.lastActivity,
            surfaceSnapshot: placeholder,
            externalSession: session,
            pluginSession: nil,
            isInternal: false
        )
    }

    static func internalId(for surface: TerminalSessionSnapshot) -> String {
        "internal:\(surface.surfaceId)"
    }
}

private final class NativeSessionSectionHeaderButton: NSControl {
    let sectionId: String

    private let arrowLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(sectionId: String, title: String, count: Int, isCollapsed: Bool) {
        self.sectionId = sectionId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setup()
        arrowLabel.stringValue = isCollapsed ? ">" : "v"
        titleLabel.stringValue = title.uppercased()
        countLabel.stringValue = "\(count)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    private func setup() {
        layer?.cornerRadius = 5
        [arrowLabel, titleLabel, countLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isEditable = false
            $0.isBordered = false
            $0.drawsBackground = false
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingTail
            addSubview($0)
        }
        arrowLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        arrowLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        countLabel.alignment = .right

        NSLayoutConstraint.activate([
            arrowLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            arrowLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowLabel.widthAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: arrowLabel.trailingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 18)
        ])
    }
}

@MainActor
private final class TerminalPaneRegistry {
    private static let maxCachedPanes = 8

    private weak var hostView: NativeTerminalPaneHostView?
    private var controllers: [String: NativeTerminalPaneControlling] = [:]
    private var lru: [String] = []
    private var activeKey: String?

    init(hostView: NativeTerminalPaneHostView) {
        self.hostView = hostView
    }

    func focus(surface: TerminalSessionSnapshot, tracePayload: [String: Any]? = nil) -> Bool {
        let startedAt = Self.timestampMillis()
        let key = surface.surfaceId
        if activeKey != key {
            activeController?.hide()
        }
        let controller: NativeTerminalPaneControlling
        if let cached = controllers[key] {
            Self.logTrace(
                tracePayload,
                phase: "native.workspace.registry.cache.hit",
                startedAt: startedAt,
                extra: "surface=\(key.prefix(8))"
            )
            controller = cached
        } else {
            let createStartedAt = Self.timestampMillis()
            let created: NativeTerminalPaneControlling?
            switch surface.backend {
            case .ghosttySurface:
                created = GhosttySurfaceBackend.shared.paneController(id: surface.surfaceId)
                    ?? GhosttySurfaceBackend.shared.paneController(id: surface.sessionId)
            case .legacyInternal, .external:
                created = EmbeddedNativeTerminalController(
                    surfaceId: surface.surfaceId,
                    sessionId: surface.sessionId,
                    onExit: { [weak self] exitedSurfaceId, _ in
                        Task { @MainActor in
                            self?.remove(surfaceId: exitedSurfaceId)
                        }
                    }
                )
            }
            guard let created else {
                Self.logTrace(
                    tracePayload,
                    phase: "native.workspace.registry.create.failed",
                    startedAt: createStartedAt,
                    extra: "surface=\(key.prefix(8)) backend=\(surface.backend.rawValue)"
                )
                return false
            }
            Self.logTrace(
                tracePayload,
                phase: "native.workspace.registry.create.done",
                startedAt: createStartedAt,
                extra: "surface=\(key.prefix(8)) backend=\(surface.backend.rawValue)"
            )
            controller = created
            controllers[key] = created
        }
        activeKey = key
        remember(key)
        attach(controller)
        controller.focus()
        Self.logTrace(
            tracePayload,
            phase: "native.workspace.focus.done",
            startedAt: startedAt,
            extra: "surface=\(key.prefix(8)) cacheCount=\(controllers.count)"
        )
        return true
    }

    func layoutActive() {
        guard let hostView, let controller = activeController else { return }
        controller.layout(in: hostView.bounds, hidden: hostView.bounds.width < 8 || hostView.bounds.height < 8)
    }

    func hideActive() {
        activeController?.hide()
        activeKey = nil
    }

    private var activeController: NativeTerminalPaneControlling? {
        guard let activeKey else { return nil }
        return controllers[activeKey]
    }

    private func attach(_ controller: NativeTerminalPaneControlling) {
        guard let hostView else { return }
        if controller.paneView.superview !== hostView {
            controller.paneView.removeFromSuperview()
            controller.paneView.autoresizingMask = [.width, .height]
            hostView.addSubview(controller.paneView)
        }
        controller.layout(in: hostView.bounds, hidden: false)
    }

    private func remember(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
        while lru.count > Self.maxCachedPanes {
            guard let evictedKey = lru.first(where: { $0 != activeKey }) else { break }
            lru.removeAll { $0 == evictedKey }
            if let evicted = controllers.removeValue(forKey: evictedKey) {
                evicted.detach()
            }
        }
    }

    private func remove(surfaceId: String) {
        if let removed = controllers.removeValue(forKey: surfaceId) {
            removed.detach()
        }
        lru.removeAll { $0 == surfaceId }
        if activeKey == surfaceId {
            activeKey = nil
        }
    }

    private static func timestampMillis() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? CGFloat { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func logTrace(
        _ payload: [String: Any]?,
        phase: String,
        startedAt: Double? = nil,
        extra: String = ""
    ) {
        guard
            let payload,
            let traceId = payload["traceId"] as? String,
            !traceId.isEmpty
        else {
            return
        }
        let now = timestampMillis()
        let sentAt = doubleValue(payload["sentAtMs"])
        let clickStartedAt = doubleValue(payload["clickStartedAtMs"])
        let sendToNative = sentAt.map { String(format: "%.1f", now - $0) } ?? "-"
        let clickToNative = clickStartedAt.map { String(format: "%.1f", now - $0) } ?? "-"
        let duration = startedAt.map { String(format: "%.1f", now - $0) } ?? "-"
        let webPhase = payload["webPhase"] as? String ?? "-"
        let suffix = extra.isEmpty ? "" : " \(extra)"
        NSLog(
            "[TerminalSwitchPerf] trace=\(traceId) phase=\(phase) webPhase=\(webPhase) sendToNativeMs=\(sendToNative) clickToNativeMs=\(clickToNative) durationMs=\(duration)\(suffix)"
        )
    }
}

@MainActor
protocol NativeTerminalPaneControlling: AnyObject {
    var paneView: NSView { get }
    func layout(in frame: NSRect, hidden: Bool)
    func focus()
    func hide()
    func detach()
}

private final class NativeTerminalPaneHostView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class NativeSessionRowButton: NSControl {
    var item: NativeSessionRailItem
    var isSelected = false

    private let kindLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(item: NativeSessionRailItem) {
        self.item = item
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setup()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    func refresh() {
        layer?.cornerRadius = 7
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor

        kindLabel.stringValue = item.isInternal ? "INTERNAL" : "EXTERNAL"
        kindLabel.textColor = item.isInternal ? .systemOrange : .systemBlue
        statusLabel.stringValue = item.status
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
    }

    private func setup() {
        [kindLabel, statusLabel, titleLabel, subtitleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isEditable = false
            $0.isBordered = false
            $0.drawsBackground = false
            $0.lineBreakMode = .byTruncatingMiddle
            $0.maximumNumberOfLines = 1
            addSubview($0)
        }

        kindLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        NSLayoutConstraint.activate([
            kindLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            kindLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            kindLabel.widthAnchor.constraint(equalToConstant: 68),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: kindLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: kindLabel.trailingAnchor, constant: 8),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: kindLabel.bottomAnchor, constant: 5),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7)
        ])
    }
}

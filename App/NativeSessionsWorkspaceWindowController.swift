import AppKit
import Combine
import meee2Kit

@MainActor
final class NativeSessionsWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NativeSessionsWorkspaceWindowController()

    private static let frameAutosaveName = "meee2.native-sessions.window"

    private let rootView = NSView()
    private let railView = NSView()
    private let rowStack = NSStackView()
    private let terminalHostView = NativeTerminalPaneHostView()
    private let inspectorView = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Sessions")
    private let countLabel = NSTextField(labelWithString: "0")
    private let emptyTerminalLabel = NSTextField(labelWithString: "Select an internal session")
    private let registry: TerminalPaneRegistry

    private var cancellables: Set<AnyCancellable> = []
    private var selectedSessionId: String?
    private var rowButtons: [String: NativeSessionRowButton] = [:]

    private init() {
        registry = TerminalPaneRegistry(hostView: terminalHostView)

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
        window.delegate = self
        buildLayout()
        bindState()
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
        reloadRows()
        if let target = resolveTarget(sessionId: sessionId, surfaceId: surfaceId) {
            focus(target)
        } else if selectedSessionId == nil,
                  let first = liveInternalSessions().first {
            focus(first)
        }
    }

    func windowWillClose(_ notification: Notification) {
        registry.hideActive()
    }

    private func buildLayout() {
        guard let window else { return }
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = rootView

        let split = NSStackView()
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 0
        split.distribution = .fill
        split.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(split)

        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.wantsLayer = true
        railView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
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

        inspectorView.orientation = .vertical
        inspectorView.alignment = .leading
        inspectorView.spacing = 10
        inspectorView.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        inspectorView.translatesAutoresizingMaskIntoConstraints = false
        inspectorView.wantsLayer = true
        inspectorView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        split.addArrangedSubview(inspectorView)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            split.topAnchor.constraint(equalTo: rootView.topAnchor),
            split.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            railView.widthAnchor.constraint(equalToConstant: 292),
            inspectorView.widthAnchor.constraint(equalToConstant: 286),

            railHeader.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 12),
            railHeader.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -12),
            railHeader.topAnchor.constraint(equalTo: railView.topAnchor, constant: 34),
            railHeader.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: railHeader.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -8),
            rowStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            terminalHostView.leadingAnchor.constraint(equalTo: terminalShell.leadingAnchor),
            terminalHostView.trailingAnchor.constraint(equalTo: terminalShell.trailingAnchor),
            terminalHostView.topAnchor.constraint(equalTo: terminalShell.topAnchor),
            terminalHostView.bottomAnchor.constraint(equalTo: terminalShell.bottomAnchor),

            emptyTerminalLabel.centerXAnchor.constraint(equalTo: terminalShell.centerXAnchor),
            emptyTerminalLabel.centerYAnchor.constraint(equalTo: terminalShell.centerYAnchor)
        ])

        updateInspector(surface: nil)
    }

    private func bindState() {
        SessionStore.shared.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadRows()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("SessionsDidChange"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadRows()
            }
            .store(in: &cancellables)
    }

    private func reloadRows() {
        let sessions = liveInternalSessions()
        countLabel.stringValue = "\(sessions.count)"
        let existingIds = Set(sessions.map(\.sessionId))
        for sessionId in rowButtons.keys.filter({ !existingIds.contains($0) }) {
            if let button = rowButtons[sessionId] {
                rowStack.removeArrangedSubview(button)
                button.removeFromSuperview()
            }
            rowButtons.removeValue(forKey: sessionId)
        }
        for session in sessions {
            let button = rowButtons[session.sessionId] ?? NativeSessionRowButton(session: session)
            button.session = session
            button.target = self
            button.action = #selector(selectSessionRow(_:))
            button.isSelected = session.sessionId == selectedSessionId
            button.refresh()
            if rowButtons[session.sessionId] == nil {
                rowButtons[session.sessionId] = button
                rowStack.addArrangedSubview(button)
                button.heightAnchor.constraint(equalToConstant: 58).isActive = true
            }
        }
        if let selectedSessionId,
           let selected = sessions.first(where: { $0.sessionId == selectedSessionId }) {
            updateInspector(surface: selected)
        } else if sessions.isEmpty {
            selectedSessionId = nil
            registry.hideActive()
            emptyTerminalLabel.isHidden = false
            updateInspector(surface: nil)
        }
    }

    @objc private func selectSessionRow(_ sender: NativeSessionRowButton) {
        focus(sender.session)
    }

    private func focus(_ surface: TerminalSessionSnapshot) {
        selectedSessionId = surface.sessionId
        for (sessionId, button) in rowButtons {
            button.isSelected = sessionId == surface.sessionId
            button.refresh()
        }
        emptyTerminalLabel.isHidden = true
        if !registry.focus(surface: surface) {
            emptyTerminalLabel.stringValue = "Unable to open terminal surface"
            emptyTerminalLabel.isHidden = false
        }
        updateInspector(surface: surface)
    }

    private func updateInspector(surface: TerminalSessionSnapshot?) {
        inspectorView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = inspectorLabel("Inspector", size: 13, weight: .semibold, color: .labelColor)
        inspectorView.addArrangedSubview(header)
        guard let surface else {
            inspectorView.addArrangedSubview(inspectorLabel("No internal session selected", color: .secondaryLabelColor))
            return
        }
        inspectorView.addArrangedSubview(inspectorLabel(displayTitle(for: surface), size: 16, weight: .semibold, color: .labelColor))
        inspectorView.addArrangedSubview(inspectorLabel("status  \(surface.status)", color: .secondaryLabelColor))
        inspectorView.addArrangedSubview(inspectorLabel("backend  \(surface.backend.rawValue)", color: .secondaryLabelColor))
        if let fallbackReason = TerminalSessionBackendMetadata.fallbackReason(forSessionId: surface.sessionId) {
            inspectorView.addArrangedSubview(inspectorLabel("fallback  \(fallbackReason)", color: .systemOrange))
        }
        inspectorView.addArrangedSubview(inspectorLabel("session  \(short(surface.sessionId))", color: .secondaryLabelColor))
        inspectorView.addArrangedSubview(inspectorLabel("surface  \(short(surface.surfaceId))", color: .secondaryLabelColor))
        inspectorView.addArrangedSubview(inspectorLabel("cwd", size: 11, weight: .semibold, color: .secondaryLabelColor))
        inspectorView.addArrangedSubview(inspectorLabel(surface.cwd, color: .labelColor))
        if let canvasId = surface.canvasId {
            inspectorView.addArrangedSubview(inspectorLabel("canvas  \(short(canvasId))", color: .secondaryLabelColor))
        }
        if let nodeId = surface.nodeId {
            inspectorView.addArrangedSubview(inspectorLabel("node  \(short(nodeId))", color: .secondaryLabelColor))
        }
    }

    private func inspectorLabel(
        _ text: String,
        size: CGFloat = 12,
        weight: NSFont.Weight = .regular,
        color: NSColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        return label
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

    private func liveInternalSessions() -> [TerminalSessionSnapshot] {
        TerminalSessionBackendRegistry.shared.listSnapshots()
            .filter { $0.status != InternalTerminalLifecycle.exited.rawValue && $0.status != InternalTerminalLifecycle.failed.rawValue }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func displayTitle(for session: TerminalSessionSnapshot) -> String {
        "\(session.provider.capitalized) - \(URL(fileURLWithPath: session.cwd).lastPathComponent)"
    }

    private func short(_ value: String) -> String {
        value.count > 12 ? "\(value.prefix(12))..." : value
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

    func focus(surface: TerminalSessionSnapshot) -> Bool {
        let key = surface.surfaceId
        if activeKey != key {
            activeController?.hide()
        }
        let controller: NativeTerminalPaneControlling
        if let cached = controllers[key] {
            controller = cached
        } else {
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
                return false
            }
            controller = created
            controllers[key] = created
        }
        activeKey = key
        remember(key)
        attach(controller)
        controller.focus()
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

private final class NativeSessionRowButton: NSButton {
    var session: TerminalSessionSnapshot
    var isSelected = false

    init(session: TerminalSessionSnapshot) {
        self.session = session
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        alignment = .left
        imagePosition = .noImage
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        layer?.cornerRadius = 7
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor

        let title = NSMutableAttributedString()
        title.append(NSAttributedString(
            string: "\(session.provider.capitalized) - \(URL(fileURLWithPath: session.cwd).lastPathComponent)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        title.append(NSAttributedString(
            string: "\(session.status)  \(short(session.sessionId))",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        attributedTitle = title
    }

    private func short(_ value: String) -> String {
        value.count > 10 ? "\(value.prefix(10))..." : value
    }
}

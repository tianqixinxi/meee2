import AppKit
import WebKit
import meee2Kit

/// WKWebView 在 `.fullSizeContentView` 下会贪心地吃掉所有 NSEvent，包括
/// 本来该让 NSWindow 的 titlebar 层处理的拖动事件。社区标准修复（Craft、
/// 早期 GitHub Desktop、Linear 等都用过）：subclass，重写 hitTest，对顶部
/// 那条 drag region 返回 nil —— 让事件穿透到 titlebar。
///
/// 参考：https://www.craft.do/blog/thinking-outside-of-the-wkwebview
final class DragRegionWebView: WKWebView {
    /// titlebar 高度。macOS 标准 titled window 是 28pt，要和 webui 那边的
    /// 任何 padding-top（如果有）保持一致。
    var dragRegionHeight: CGFloat = 28

    /// Carve-out rects (window coords, top-left origin via `fromTop`/`fromLeft`)
    /// where clicks within the top drag region should still reach the
    /// webview instead of being swallowed for window-drag. Used to host
    /// HTML buttons (sidebar toggle) inside the title-bar visual band
    /// without sacrificing their clickability.
    ///
    /// Frame layout matches the CSS: x is "from left", y is "from top",
    /// both in points (= CSS px since we don't scale).
    var clickThroughRects: [CGRect] = [
        // Sidebar toggle icon — sits to the right of macOS traffic lights
        // (which end around x≈72) so it visually shares the title-bar row
        // but does NOT trigger a window drag. The CSS positions the
        // button at left:80, top:4, 20×20; this rect adds ~4px slack on
        // each side so the user doesn't have to hit the exact pixel edge.
        CGRect(x: 76, y: 0, width: 28, height: 28)
    ]

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` 在 superview 坐标系。把它换到 window 坐标（bottom-left
        // 原点），看 y 是不是在最顶 dragRegionHeight 那条里。
        // 在那条里 → 返回 nil → 事件落到 NSTitlebarContainerView，原生处理拖动 / 双击放大 / 等等。
        guard let window else { return super.hitTest(point) }
        let inWindow = superview?.convert(point, to: nil) ?? point
        let fromTop = window.frame.height - inWindow.y
        let fromLeft = inWindow.x
        if fromTop >= 0 && fromTop < dragRegionHeight {
            // Carve-out: if the point lands inside any registered rect
            // (e.g. the sidebar toggle), let the webview handle the
            // click — same as if it were below the drag region.
            for rect in clickThroughRects where rect.contains(NSPoint(x: fromLeft, y: fromTop)) {
                return super.hitTest(point)
            }
            return nil
        }
        return super.hitTest(point)
    }

    /// 显式拦截 cmd+V / cmd+C / cmd+X / cmd+A 把它们转成 paste:/copy:/cut:/
    /// selectAll: 走 NSResponder chain。
    ///
    /// 背景：WKWebView 在嵌入场景下默认会把 cmd+V 翻译成 keydown 派发给
    /// JS 但**不会**自动触发 paste 事件 / textarea 默认插入（即使开了
    /// `_javaScriptCanAccessClipboard` SPI 也不够），导致客户端里 cmd+V
    /// 完全没反应。同样地 cmd+C 也不会自动 copy。
    ///
    /// 这里在 performKeyEquivalent 阶段强制调对应 NSResponder 方法。
    /// WKWebView 自身实现 paste(_:) / copy(_:) 等，会调 WebKit 内的
    /// editor pipeline，正确触发 textarea 默认行为 + JS clipboard 事件。
    /// 返回 true 告诉 NSWindow "事件已处理"，跳过菜单 keyEquivalent 二次
    /// 派发避免重复粘贴。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            switch event.charactersIgnoringModifiers {
            case "v":
                if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
                    return true
                }
            case "c":
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) {
                    return true
                }
            case "x":
                if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) {
                    return true
                }
            case "a":
                if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) {
                    return true
                }
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 把 WKWebView 内 JS 的 `console.error / console.warn / window.onerror /
/// unhandledrejection` 转回 native log。注入脚本在 documentStart 跑一次，
/// 把上述事件 postMessage 到 `meee2Diag` handler，本类落到 `~/Library/Logs/meee2.log`。
///
/// 拆成独立的 NSObject 是为了规避 WKUserContentController → handler →
/// controller 的循环引用：BoardWebWindowController 强引用 controller，
/// controller 强引用 handler，所以 handler 不能再引用 BoardWebWindowController。
/// 这里只调全局 MLog 家族，无需任何上下文。
private final class JSConsoleBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "meee2Diag"

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        let level = (dict["level"] as? String) ?? "error"
        let msg = (dict["msg"] as? String) ?? ""
        // 截断单条日志，防 React 抛个 10MB JSON 把日志撑爆
        let trimmed = msg.count > 2000 ? String(msg.prefix(2000)) + "…(truncated)" : msg
        switch level {
        case "warn": MWarn("[BoardWebWindow.js] \(trimmed)")
        default: MError("[BoardWebWindow.js] \(trimmed)")
        }
    }

    /// 在 documentStart 注入：包裹 console.error/warn + 监听全局错误 +
    /// 未处理 promise rejection。所有 catch 都吞 try/catch，再失败就放弃，
    /// 不能让 logging 自己把页面打挂。
    static let captureScript: String = """
    (function() {
      function send(level, args) {
        try {
          var parts = [];
          for (var i = 0; i < args.length; i++) {
            var a = args[i];
            if (a instanceof Error) {
              parts.push(a.stack || a.message || String(a));
            } else if (typeof a === 'object' && a !== null) {
              try { parts.push(JSON.stringify(a)); }
              catch (e) { parts.push(String(a)); }
            } else {
              parts.push(String(a));
            }
          }
          window.webkit.messageHandlers.meee2Diag.postMessage({
            level: level,
            msg: parts.join(' ')
          });
        } catch (e) { /* ignore — never let the bridge crash the page */ }
      }
      var origErr = console.error.bind(console);
      console.error = function() { send('error', arguments); origErr.apply(console, arguments); };
      var origWarn = console.warn.bind(console);
      console.warn = function() { send('warn', arguments); origWarn.apply(console, arguments); };
      window.addEventListener('error', function(e) {
        var loc = (e.filename || '?') + ':' + (e.lineno || '?') + ':' + (e.colno || '?');
        send('error', ['[uncaught] ' + (e.message || '?') + ' @ ' + loc]);
      });
      window.addEventListener('unhandledrejection', function(e) {
        var reason = e.reason;
        var msg = '?';
        if (reason instanceof Error) msg = reason.stack || reason.message;
        else if (reason !== undefined) { try { msg = JSON.stringify(reason); } catch (x) { msg = String(reason); } }
        send('error', ['[unhandled rejection] ' + msg]);
      });
    })();
    """
}

private final class NativeTerminalBridge: NSObject, WKScriptMessageHandler {
    static let messageName = "meee2NativeTerminal"
    weak var owner: BoardWebWindowController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            self?.owner?.handleNativeTerminalMessage(payload)
        }
    }
}

private final class NativeTerminalHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() where !subview.isHidden && subview.alphaValue > 0.01 {
            let converted = convert(point, to: subview)
            if let hit = subview.hitTest(converted) {
                return hit
            }
        }
        return nil
    }
}

final class BoardWebWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let frameAutosaveName = "meee2.board.window"
    private static let maxEmbeddedTerminalCacheCount = 6

    private let rootView = NSView()
    private let terminalHostView = NativeTerminalHostView()
    private let webView: DragRegionWebView
    private let boardURL: URL
    private var retryWorkItem: DispatchWorkItem?
    private var isShowingLoadError = false
    private let jsConsoleBridge = JSConsoleBridge()
    private let nativeTerminalBridge = NativeTerminalBridge()
    private var embeddedTerminals: [String: EmbeddedNativeTerminalController] = [:]
    private var embeddedTerminalLRU: [String] = []
    private var activeEmbeddedTerminalKey: String?
    private var terminalScrollMonitor: Any?
    private var embeddedTerminal: EmbeddedNativeTerminalController? {
        guard let activeEmbeddedTerminalKey else { return nil }
        return embeddedTerminals[activeEmbeddedTerminalKey]
    }
    private struct EmbeddedTerminalLayout {
        let frame: NSRect
        let hidden: Bool
    }
    private var pendingOpenSettings = false
    private var pendingOpenSession: (sessionId: String?, surfaceId: String?)?
    var onClose: (() -> Void)?

    init(boardURL: URL) {
        self.boardURL = boardURL

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "meee2-board-shell"
        // 打开 WKWebView 的 DOM clipboard SPI —— WebKit 在嵌入场景下默认
        // 关闭 cmd+V / cmd+C 的 paste/copy 事件分发到 JS（也不让 textarea
        // 的原生 paste 走完整 flow），导致客户端里复制粘贴一律不响应。
        // Safari / Chrome 是因为它们自己也设了同款 SPI 才不出问题。
        //
        // 安全 KVC：直接 setValue:forKey: 命中未知 key 抛 NSUndefinedKey
        // Exception，Swift 不接 ObjC 异常 → 整个 app 闪退（早上 19:34 那
        // 次就是这么挂的）。先用 responds(to:) 探针 setter 存在再调，未知
        // 静默跳过。两套候选 setter 名（无下划线 / 带下划线）轮试一遍 ——
        // Apple 不同 macOS 版本之间在 SPI 名上互换过。
        let prefs = configuration.preferences as NSObject
        for key in ["javaScriptCanAccessClipboard", "domPasteAllowed"] {
            let cap = key.prefix(1).uppercased() + key.dropFirst()
            for setterName in ["set\(cap):", "_set\(cap):"] {
                let sel = NSSelectorFromString(setterName)
                if prefs.responds(to: sel) {
                    prefs.setValue(true, forKey: key)
                    NSLog("[BoardWebWindowController] enabled WKPreferences SPI key=\(key) via \(setterName)")
                    break
                }
            }
        }

        // 注入 JS 控制台桥 —— 把 React app 内部的 console.error / 抛错
        // 转回 native log。配置必须在 WKWebView init 之前完成。
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: JSConsoleBridge.captureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.add(jsConsoleBridge, name: JSConsoleBridge.messageName)
        userContentController.add(nativeTerminalBridge, name: NativeTerminalBridge.messageName)
        configuration.userContentController = userContentController

        webView = DragRegionWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        // 开 Web Inspector —— `isInspectable` 是 macOS 13.3+ 公开 API，
        // 直接走 typed property（KVC 也行但风格不统一）。@available 编译
        // 时已经卡住低版本，无需 runtime check。
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        let window = NSWindow(
            contentRect: Self.defaultContentRect(),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        // 透明 titlebar + webview 顶到 0,0 + drag 由 DragRegionWebView 兜底：
        //   - .fullSizeContentView —— contentView 占满整个窗口，webview 内容
        //     延伸到 y=0
        //   - titlebarAppearsTransparent + titleVisibility = .hidden —— titlebar
        //     不画自己的背景、不显示文字。底下 webview 画啥就显示啥。
        //   - DragRegionWebView.hitTest 对顶 28pt 返 nil → titlebar 拿事件，
        //     macOS 原生处理拖窗口 / 双击放大。
        // 不设 backgroundColor / appearance —— 让系统按 webview 实际像素显示。
        window.title = "meee2 Board"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.miniwindowImage = AppIconProvider.loadIcon() ?? NSApp.applicationIconImage
        window.minSize = NSSize(width: 1040, height: 680)
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)

        nativeTerminalBridge.owner = self
        window.delegate = self
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(webView)
        terminalHostView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(terminalHostView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            terminalHostView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            terminalHostView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            terminalHostView.topAnchor.constraint(equalTo: rootView.topAnchor),
            terminalHostView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
        window.contentView = rootView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 不再挂 NSToolbar —— Reload / Open in Browser 走 web 内的 CommandBar
        // 入口（或菜单栏 / 上下文菜单），title bar 干净一片。
        installTerminalScrollMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let terminalScrollMonitor {
            NSEvent.removeMonitor(terminalScrollMonitor)
        }
    }

    private static func defaultContentRect() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(1440, visible.width * 0.9), max(1040, visible.width - 48))
        let height = min(max(900, visible.height * 0.88), max(680, visible.height - 48))
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    func show() {
        loadIfNeeded()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        pendingOpenSettings = true
        show()
        dispatchOpenSettingsIfPossible()
    }

    func openSession(sessionId: String?, surfaceId: String?) {
        pendingOpenSession = (sessionId, surfaceId)
        show()
        dispatchOpenSessionIfPossible()
    }

    private func loadIfNeeded() {
        guard webView.url == nil else { return }
        isShowingLoadError = false
        MInfo("[BoardWebWindow] initial load → \(boardURL.absoluteString)")
        // ignore HTTP cache on first load —— meee2 重启时 BoardServer 端
        // WebDist 通常已经被 swift build 重新拷过来（vite 出的 chunk 文件
        // 名带 hash，但 index.html 不带），WKWebView 默认走持久化 HTTP cache
        // 会复用上次跑的旧 index.html → 看到的是上一版 UI，新 feature 凭空
        // 不见。强制 ignore 让每次新启动都重新 fetch 入口。
        var req = URLRequest(url: boardURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(req)
    }

    func reload() {
        isShowingLoadError = false
        MInfo("[BoardWebWindow] reload → \(boardURL.absoluteString)")
        // 与 loadIfNeeded 同源：用户主动 reload 时也吞掉 HTTP cache
        var req = URLRequest(url: boardURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(req)
    }

    func openInBrowser() {
        NSWorkspace.shared.open(boardURL)
    }

    func windowWillClose(_ notification: Notification) {
        MInfo("[BoardWebWindow] windowWillClose")
        detachAllEmbeddedTerminals()
        retryWorkItem?.cancel()
        retryWorkItem = nil
        onClose?()
    }

    private func installTerminalScrollMonitor() {
        guard terminalScrollMonitor == nil else { return }
        terminalScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.forwardScrollWheelToEmbeddedTerminal(event) ? nil : event
        }
    }

    private func forwardScrollWheelToEmbeddedTerminal(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        guard event.window === window else { return false }
        guard let terminal = embeddedTerminal, !terminal.view.isHidden else { return false }
        let pointInHost = terminalHostView.convert(event.locationInWindow, from: nil)
        guard terminal.view.frame.contains(pointInHost) else { return false }
        terminal.scrollWheel(with: event)
        return true
    }

    func handleNativeTerminalMessage(_ payload: [String: Any]) {
        let type = payload["type"] as? String ?? "attach"
        logTerminalTrace(payload, phase: "native.received", extra: "type=\(type)")
        switch type {
        case "prewarm":
            let surfaceId = payload["surfaceId"] as? String ?? ""
            let sessionId = payload["sessionId"] as? String
            prewarmEmbeddedTerminal(surfaceId: surfaceId, sessionId: sessionId, tracePayload: payload)
        case "attach", "embed", "open":
            let surfaceId = payload["surfaceId"] as? String ?? ""
            let sessionId = payload["sessionId"] as? String
            let rectPayload = payload["rect"] as? [String: Any]
            _ = embedNativeTerminal(surfaceId: surfaceId, sessionId: sessionId, rectPayload: rectPayload, tracePayload: payload)
        case "layout":
            let surfaceId = payload["surfaceId"] as? String ?? ""
            let sessionId = payload["sessionId"] as? String
            if let rectPayload = payload["rect"] as? [String: Any] {
                _ = updateEmbeddedTerminalFrame(
                    rectPayload,
                    surfaceId: surfaceId,
                    sessionId: sessionId,
                    tracePayload: payload
                )
            } else {
                dispatchNativeTerminalSyncAck(type: "layout", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "missingRect", tracePayload: payload)
            }
        case "focus":
            let surfaceId = payload["surfaceId"] as? String ?? ""
            let sessionId = payload["sessionId"] as? String
            if activeEmbeddedTerminalMatches(surfaceId: surfaceId, sessionId: sessionId) {
                embeddedTerminal?.focus()
                logTerminalTrace(payload, phase: "native.focus.done", extra: "hasTerminal=\(embeddedTerminal != nil)")
                dispatchNativeTerminalSyncAck(type: "focus", surfaceId: surfaceId, sessionId: sessionId, ok: true, tracePayload: payload)
            } else {
                logTerminalTrace(payload, phase: "native.focus.skipped", extra: "reason=staleTarget")
                dispatchNativeTerminalSyncAck(type: "focus", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "staleTarget", tracePayload: payload)
            }
        case "hide", "detach":
            let surfaceId = payload["surfaceId"] as? String ?? ""
            let sessionId = payload["sessionId"] as? String
            let ok = hideEmbeddedTerminal(surfaceId: surfaceId, sessionId: sessionId)
            dispatchNativeTerminalSyncAck(type: type, surfaceId: surfaceId, sessionId: sessionId, ok: ok, reason: ok ? nil : "staleTarget", tracePayload: payload)
            logTerminalTrace(payload, phase: "native.hide.done")
        default:
            break
        }
    }

    private func prewarmEmbeddedTerminal(surfaceId: String, sessionId: String?, tracePayload: [String: Any]? = nil) {
        guard !surfaceId.isEmpty || sessionId?.isEmpty == false else { return }
        let key = embeddedTerminalCacheKey(surfaceId: surfaceId, sessionId: sessionId)
        if embeddedTerminals[key] != nil {
            rememberEmbeddedTerminal(key)
            dispatchNativeTerminalPrewarmAck(surfaceId: surfaceId, sessionId: sessionId, ready: true, cacheHit: true)
            logTerminalTrace(tracePayload, phase: "native.prewarm.done", extra: "cacheHit=true cacheCount=\(embeddedTerminals.count)")
            return
        }
        let webPhase = tracePayload?["webPhase"] as? String ?? ""
        if webPhase == "react.idleTabPrewarm" {
            dispatchNativeTerminalPrewarmAck(surfaceId: surfaceId, sessionId: sessionId, ready: false, cacheHit: false, reason: "backgroundIdle")
            logTerminalTrace(tracePayload, phase: "native.prewarm.skipped", extra: "reason=backgroundIdle cacheHit=false cacheCount=\(embeddedTerminals.count)")
            return
        }
        guard let created = makeEmbeddedTerminal(surfaceId: surfaceId, sessionId: sessionId) else {
            dispatchNativeTerminalPrewarmAck(surfaceId: surfaceId, sessionId: sessionId, ready: false, cacheHit: false, reason: "createFailed")
            logTerminalTrace(tracePayload, phase: "native.prewarm.failed", extra: "cacheHit=false")
            return
        }
        hostEmbeddedTerminalView(created, frame: defaultHiddenTerminalFrame(), hidden: true)
        embeddedTerminals[key] = created
        rememberEmbeddedTerminal(key)
        dispatchNativeTerminalPrewarmAck(surfaceId: surfaceId, sessionId: sessionId, ready: true, cacheHit: false)
        logTerminalTrace(tracePayload, phase: "native.prewarm.done", extra: "cacheHit=false hosted=true cacheCount=\(embeddedTerminals.count)")
    }

    private func embedNativeTerminal(surfaceId: String, sessionId: String?, rectPayload: [String: Any]?, tracePayload: [String: Any]? = nil) -> Bool {
        guard !surfaceId.isEmpty || sessionId?.isEmpty == false else {
            dispatchNativeTerminalSyncAck(type: "attach", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "missingTarget", tracePayload: tracePayload)
            return false
        }
        let key = embeddedTerminalCacheKey(surfaceId: surfaceId, sessionId: sessionId)
        let cacheHit = embeddedTerminals[key] != nil
        let activeChanged = activeEmbeddedTerminalKey != key
        let initialLayout = rectPayload.flatMap { embeddedTerminalLayout(from: $0) }
        var hostedDuringAttach = false
        if activeEmbeddedTerminalKey != key {
            embeddedTerminal?.hide()
            let controller: EmbeddedNativeTerminalController
            if let cached = embeddedTerminals[key] {
                controller = cached
            } else {
                guard let created = makeEmbeddedTerminal(surfaceId: surfaceId, sessionId: sessionId) else {
                    logTerminalTrace(tracePayload, phase: "native.embed.failed", extra: "cacheHit=false activeChanged=\(activeChanged)")
                    dispatchNativeTerminalSyncAck(type: "attach", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "createFailed", tracePayload: tracePayload, cacheHit: false, activeChanged: activeChanged)
                    NSSound.beep()
                    return false
                }
                controller = created
                embeddedTerminals[key] = created
            }
            activeEmbeddedTerminalKey = key
            rememberEmbeddedTerminal(key)
            hostEmbeddedTerminalView(
                controller,
                frame: initialLayout?.frame ?? .zero,
                hidden: initialLayout?.hidden ?? true
            )
            hostedDuringAttach = true
        } else if embeddedTerminal == nil {
            activeEmbeddedTerminalKey = nil
            guard let controller = makeEmbeddedTerminal(surfaceId: surfaceId, sessionId: sessionId) else {
                logTerminalTrace(tracePayload, phase: "native.embed.failed", extra: "cacheHit=false activeChanged=false")
                dispatchNativeTerminalSyncAck(type: "attach", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "createFailed", tracePayload: tracePayload, cacheHit: false, activeChanged: false)
                NSSound.beep()
                return false
            }
            embeddedTerminals[key] = controller
            activeEmbeddedTerminalKey = key
            rememberEmbeddedTerminal(key)
            hostEmbeddedTerminalView(
                controller,
                frame: initialLayout?.frame ?? .zero,
                hidden: initialLayout?.hidden ?? true
            )
            hostedDuringAttach = true
        }
        if let rectPayload {
            if hostedDuringAttach || initialLayout == nil {
                if let initialLayout {
                    logTerminalLayoutDone(initialLayout, tracePayload: tracePayload)
                } else {
                    logTerminalTrace(tracePayload, phase: "native.layout.skipped", extra: "reason=badRect")
                }
            } else {
                _ = updateEmbeddedTerminalFrame(
                    rectPayload,
                    surfaceId: surfaceId,
                    sessionId: sessionId,
                    tracePayload: tracePayload
                )
            }
        }
        embeddedTerminal?.focus()
        logTerminalTrace(
            tracePayload,
            phase: "native.embed.done",
            extra: "cacheHit=\(cacheHit) activeChanged=\(activeChanged) cacheCount=\(embeddedTerminals.count)"
        )
        dispatchNativeTerminalSyncAck(type: "attach", surfaceId: surfaceId, sessionId: sessionId, ok: true, tracePayload: tracePayload, cacheHit: cacheHit, activeChanged: activeChanged)
        return true
    }

    private func makeEmbeddedTerminal(surfaceId: String, sessionId: String?) -> EmbeddedNativeTerminalController? {
        EmbeddedNativeTerminalController(surfaceId: surfaceId, sessionId: sessionId) { [weak self] exitedSurfaceId, exitedSessionId in
            self?.removeEmbeddedTerminal(surfaceId: exitedSurfaceId, sessionId: exitedSessionId)
        }
    }

    private func hostEmbeddedTerminalView(_ controller: EmbeddedNativeTerminalController, frame: NSRect, hidden: Bool) {
        let initialFrame = frame.width >= 8 && frame.height >= 8 ? frame : defaultHiddenTerminalFrame()
        if controller.view.superview == nil {
            controller.view.frame = initialFrame
            controller.view.autoresizingMask = []
            terminalHostView.addSubview(controller.view)
        } else if controller.view.superview !== terminalHostView {
            controller.view.removeFromSuperview()
            controller.view.frame = initialFrame
            terminalHostView.addSubview(controller.view)
        }
        controller.layout(in: hidden && (frame.width < 8 || frame.height < 8) ? initialFrame : frame, hidden: hidden)
    }

    private func defaultHiddenTerminalFrame() -> NSRect {
        let bounds = terminalHostView.bounds
        if bounds.width >= 640, bounds.height >= 360 {
            return NSRect(x: 0, y: 0, width: min(bounds.width, 1180), height: min(bounds.height, 760)).integral
        }
        return NSRect(x: 0, y: 0, width: 960, height: 540)
    }

    private func hideEmbeddedTerminal(surfaceId: String, sessionId: String?) -> Bool {
        guard let active = embeddedTerminal else { return false }
        guard surfaceId.isEmpty && (sessionId?.isEmpty ?? true) || active.matches(surfaceId: surfaceId, sessionId: sessionId) else {
            return false
        }
        active.hide()
        activeEmbeddedTerminalKey = nil
        return true
    }

    private func activeEmbeddedTerminalMatches(surfaceId: String, sessionId: String?) -> Bool {
        guard let active = embeddedTerminal else { return false }
        if surfaceId.isEmpty && (sessionId?.isEmpty ?? true) { return true }
        return active.matches(surfaceId: surfaceId, sessionId: sessionId)
    }

    private func detachAllEmbeddedTerminals() {
        for controller in embeddedTerminals.values {
            controller.detach()
        }
        embeddedTerminals.removeAll()
        embeddedTerminalLRU.removeAll()
        activeEmbeddedTerminalKey = nil
    }

    private func removeEmbeddedTerminal(surfaceId: String, sessionId: String?) {
        let directKey = embeddedTerminalCacheKey(surfaceId: surfaceId, sessionId: sessionId)
        let matchingKeys = embeddedTerminals.compactMap { key, controller in
            key == directKey || controller.matches(surfaceId: surfaceId, sessionId: sessionId) ? key : nil
        }
        for key in matchingKeys {
            if let removed = embeddedTerminals.removeValue(forKey: key) {
                dispatchNativeTerminalPrewarmAck(
                    surfaceId: removed.surfaceId,
                    sessionId: removed.sessionId,
                    ready: false,
                    cacheHit: false,
                    reason: "removed"
                )
                removed.detach()
            }
            embeddedTerminalLRU.removeAll { $0 == key }
            if activeEmbeddedTerminalKey == key {
                activeEmbeddedTerminalKey = nil
            }
        }
    }

    private func embeddedTerminalCacheKey(surfaceId: String, sessionId: String?) -> String {
        if !surfaceId.isEmpty { return "surface:\(surfaceId)" }
        return "session:\(sessionId ?? "")"
    }

    private func rememberEmbeddedTerminal(_ key: String) {
        embeddedTerminalLRU.removeAll { $0 == key }
        embeddedTerminalLRU.append(key)
        while embeddedTerminalLRU.count > Self.maxEmbeddedTerminalCacheCount {
            guard let evictedKey = embeddedTerminalLRU.first(where: { $0 != activeEmbeddedTerminalKey }) else {
                break
            }
            embeddedTerminalLRU.removeAll { $0 == evictedKey }
            if let evicted = embeddedTerminals.removeValue(forKey: evictedKey) {
                dispatchNativeTerminalPrewarmAck(
                    surfaceId: evicted.surfaceId,
                    sessionId: evicted.sessionId,
                    ready: false,
                    cacheHit: false,
                    reason: "evicted"
                )
                evicted.detach()
            }
        }
    }

    private func updateEmbeddedTerminalFrame(
        _ rectPayload: [String: Any],
        surfaceId: String = "",
        sessionId: String? = nil,
        tracePayload: [String: Any]? = nil
    ) -> Bool {
        guard let embeddedTerminal else {
            logTerminalTrace(tracePayload, phase: "native.layout.skipped", extra: "reason=noTerminal")
            dispatchNativeTerminalSyncAck(type: "layout", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "noTerminal", tracePayload: tracePayload)
            return false
        }
        guard activeEmbeddedTerminalMatches(surfaceId: surfaceId, sessionId: sessionId) else {
            logTerminalTrace(tracePayload, phase: "native.layout.skipped", extra: "reason=staleTarget")
            dispatchNativeTerminalSyncAck(type: "layout", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "staleTarget", tracePayload: tracePayload)
            return false
        }
        guard let layout = embeddedTerminalLayout(from: rectPayload) else {
            logTerminalTrace(tracePayload, phase: "native.layout.skipped", extra: "reason=badRect")
            dispatchNativeTerminalSyncAck(type: "layout", surfaceId: surfaceId, sessionId: sessionId, ok: false, reason: "badRect", tracePayload: tracePayload)
            return false
        }
        embeddedTerminal.layout(in: layout.frame, hidden: layout.hidden)
        logTerminalLayoutDone(layout, tracePayload: tracePayload)
        dispatchNativeTerminalSyncAck(type: "layout", surfaceId: surfaceId, sessionId: sessionId, ok: true, tracePayload: tracePayload)
        return true
    }

    private func embeddedTerminalLayout(from rectPayload: [String: Any]) -> EmbeddedTerminalLayout? {
        guard
            let x = Self.doubleValue(rectPayload["x"]),
            let y = Self.doubleValue(rectPayload["y"]),
            let width = Self.doubleValue(rectPayload["width"]),
            let height = Self.doubleValue(rectPayload["height"])
        else {
            return nil
        }
        let rootHeight = rootView.bounds.height
        let frame = NSRect(
            x: x,
            y: rootHeight - y - height,
            width: max(1, width),
            height: max(1, height)
        ).integral
        let hidden = width < 8 || height < 8
        return EmbeddedTerminalLayout(frame: frame, hidden: hidden)
    }

    private func logTerminalLayoutDone(_ layout: EmbeddedTerminalLayout, tracePayload: [String: Any]?) {
        logTerminalTrace(
            tracePayload,
            phase: "native.layout.done",
            extra: "frame=\(Int(layout.frame.width))x\(Int(layout.frame.height)) hidden=\(layout.hidden)"
        )
    }

    private func requestEmbeddedTerminalLayout() {
        webView.evaluateJavaScript("""
        window.dispatchEvent(new CustomEvent('meee2:layout-native-terminal'));
        """, completionHandler: nil)
    }

    private func dispatchNativeTerminalPrewarmAck(
        surfaceId: String,
        sessionId: String?,
        ready: Bool,
        cacheHit: Bool,
        reason: String? = nil
    ) {
        var detail: [String: Any] = [
            "surfaceId": surfaceId,
            "ready": ready,
            "cacheHit": cacheHit
        ]
        if let sessionId, !sessionId.isEmpty {
            detail["sessionId"] = sessionId
        }
        if let reason, !reason.isEmpty {
            detail["reason"] = reason
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: detail),
            let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("""
        window.dispatchEvent(new CustomEvent('meee2:native-terminal-prewarm', { detail: \(json) }));
        """, completionHandler: nil)
    }

    private func dispatchNativeTerminalSyncAck(
        type: String,
        surfaceId: String,
        sessionId: String?,
        ok: Bool,
        reason: String? = nil,
        tracePayload: [String: Any]? = nil,
        cacheHit: Bool? = nil,
        activeChanged: Bool? = nil
    ) {
        var detail: [String: Any] = [
            "type": type,
            "surfaceId": surfaceId,
            "ok": ok,
            "nativeAtMs": Self.timestampMillis()
        ]
        if let sessionId, !sessionId.isEmpty {
            detail["sessionId"] = sessionId
        }
        if let reason, !reason.isEmpty {
            detail["reason"] = reason
        }
        if let traceId = tracePayload?["traceId"] as? String, !traceId.isEmpty {
            detail["traceId"] = traceId
        }
        if let cacheHit {
            detail["cacheHit"] = cacheHit
        }
        if let activeChanged {
            detail["activeChanged"] = activeChanged
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: detail),
            let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("""
        window.dispatchEvent(new CustomEvent('meee2:native-terminal-sync', { detail: \(json) }));
        """, completionHandler: nil)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? CGFloat { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func logTerminalTrace(_ payload: [String: Any]?, phase: String, extra: String = "") {
        guard
            let payload,
            let traceId = payload["traceId"] as? String,
            !traceId.isEmpty
        else {
            return
        }
        let now = Self.timestampMillis()
        let sentAt = Self.doubleValue(payload["sentAtMs"])
        let clickStartedAt = Self.doubleValue(payload["clickStartedAtMs"])
        let sendToNative = sentAt.map { Self.formatMillis(now - $0) } ?? "-"
        let clickToNative = clickStartedAt.map { Self.formatMillis(now - $0) } ?? "-"
        let webPhase = payload["webPhase"] as? String ?? "-"
        let suffix = extra.isEmpty ? "" : " \(extra)"
        NSLog(
            "[TerminalSwitchPerf] trace=\(traceId) phase=\(phase) webPhase=\(webPhase) sendToNativeMs=\(sendToNative) clickToNativeMs=\(clickToNative)\(suffix)"
        )
    }

    private static func timestampMillis() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private static func formatMillis(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MError("[BoardWebWindow] navigation failed: \(error.localizedDescription) (url=\(webView.url?.absoluteString ?? "?"))")
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MError("[BoardWebWindow] provisional navigation failed: \(error.localizedDescription) (target=\(boardURL.absoluteString))")
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isShowingLoadError {
            MInfo("[BoardWebWindow] load finished → \(webView.url?.absoluteString ?? "?")")
            retryWorkItem?.cancel()
            retryWorkItem = nil
        }
        // 页面加载完后立刻把 traffic light 的真实位置喂给 webui，让
        // sidebar-collapsed-toggle 能精确对齐。窗口 resize / titlebar 模式
        // 切换时也要更新（NSWindow.didResize 通知触发）。
        injectTitlebarMetrics()
        dispatchOpenSettingsIfPossible()
        dispatchOpenSessionIfPossible()
    }

    private func dispatchOpenSettingsIfPossible() {
        guard pendingOpenSettings, webView.url != nil, !webView.isLoading, !isShowingLoadError else { return }
        pendingOpenSettings = false
        webView.evaluateJavaScript("""
        window.dispatchEvent(new CustomEvent('meee2:open-settings'));
        """) { [weak self] _, error in
            if let error {
                MWarn("[BoardWebWindow] open settings event failed: \(error.localizedDescription)")
                self?.pendingOpenSettings = true
            }
        }
    }

    private func dispatchOpenSessionIfPossible() {
        guard let pendingOpenSession, webView.url != nil, !webView.isLoading, !isShowingLoadError else { return }
        var detail: [String: String] = [:]
        if let sessionId = pendingOpenSession.sessionId, !sessionId.isEmpty {
            detail["sessionId"] = sessionId
        }
        if let surfaceId = pendingOpenSession.surfaceId, !surfaceId.isEmpty {
            detail["surfaceId"] = surfaceId
        }
        guard !detail.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: detail),
              let json = String(data: data, encoding: .utf8) else {
            self.pendingOpenSession = nil
            return
        }
        self.pendingOpenSession = nil
        webView.evaluateJavaScript("""
        window.dispatchEvent(new CustomEvent('meee2:open-session', { detail: \(json) }));
        """) { [weak self] _, error in
            if let error {
                MWarn("[BoardWebWindow] open session event failed: \(error.localizedDescription)")
                self?.pendingOpenSession = pendingOpenSession
            }
        }
    }

    /// 把 macOS 系统级 traffic light 按钮的中心点（webview CSS 坐标）注入
    /// document root style 上的两个 CSS 变量。这样 webui 那边的对齐 button
    /// 不再硬编码 top:Xpx 猜测，直接用：
    ///   top: calc(var(--titlebar-btn-center-y) - 10px);  // 10 = 自身高/2
    ///   left: calc(var(--titlebar-btn-right-edge) + 8px); // lights 右边 + 间距
    ///
    /// 触发时机：webView didFinish 一次（页面 mount 后）+ window resize / state
    /// 变化（didResize / didEnterFullScreen 等）每次。fullscreen 进出和 zoom
    /// 都会让 lights 位置变（fullscreen 期间 NSStandardWindowButton.frame
    /// 还是有效但实际不显示——CSS variable 会更新成 0/0，sidebar 那侧的
    /// `--titlebar-btn-center-y: 0` 不影响布局，按钮会顶到 top:0 自然 hidden
    /// 在 fullscreen UI 下也合理）。
    func injectTitlebarMetrics() {
        guard let window = window,
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton) else {
            return
        }
        guard let contentView = window.contentView else { return }

        // close.frame / zoom.frame 是它们各自 superview 的坐标系。在
        // .fullSizeContentView 模式下 AppKit 通常把 traffic light 直接挂到
        // contentView 上（也就是这里的 WKWebView，本身 isFlipped=true），
        // 所以 frame.y 已经是 "从顶部往下"。如果挂在 NSThemeFrame 这种
        // 非 flipped 的 superview 上，要先转换到 contentView 坐标系再判断。
        //
        // 决定 centerY (CSS top) 的关键：contentView 是不是 flipped。
        //   • flipped (WKWebView) → centerY = closeRectInCV.midY 直接用
        //   • 非 flipped (NSView) → centerY = bounds.height - closeRectInCV.midY
        let closeRectInCV: NSRect
        let zoomRectInCV: NSRect
        if let closeSV = close.superview {
            closeRectInCV = contentView.convert(close.frame, from: closeSV)
        } else {
            closeRectInCV = close.frame
        }
        if let zoomSV = zoom.superview {
            zoomRectInCV = contentView.convert(zoom.frame, from: zoomSV)
        } else {
            zoomRectInCV = zoom.frame
        }

        let cvHeight = contentView.bounds.height
        let isFlipped = contentView.isFlipped
        let centerY_top: CGFloat = isFlipped
            ? closeRectInCV.midY
            : (cvHeight - closeRectInCV.midY)
        let lightsRight = zoomRectInCV.maxX

        // Sanity clamp — titlebar height is < 40 on macOS standard windows.
        // 如果计算出来不合理（负数 / >40 / >150），用回 fallback (13 / 72)，
        // 不要把 sidebar toggle 推到屏幕外让用户找不到。
        let centerY: Double = {
            let v = Double(centerY_top)
            if v.isFinite && v > 0 && v < 40 { return v }
            return 13
        }()
        let rightEdge: Double = {
            let v = Double(lightsRight)
            if v.isFinite && v > 0 && v < 200 { return v }
            return 72
        }()

        NSLog("[BoardWindow] titlebar metrics: close.frame=\(close.frame) closeInCV=\(closeRectInCV) cvHeight=\(cvHeight) flipped=\(isFlipped) raw_centerY_top=\(centerY_top) → centerY=\(centerY) lightsRight=\(rightEdge)")

        let js = """
        (function(){
          document.documentElement.classList.add('meee2-board-shell');
          const r = document.documentElement.style;
          r.setProperty('--titlebar-btn-center-y', '\(centerY)px');
          r.setProperty('--titlebar-lights-right', '\(rightEdge)px');
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func windowDidResize(_ notification: Notification) {
        injectTitlebarMetrics()
        requestEmbeddedTerminalLayout()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        injectTitlebarMetrics()
        requestEmbeddedTerminalLayout()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        injectTitlebarMetrics()
        requestEmbeddedTerminalLayout()
    }

    /// HTTP 4xx / 5xx 不会触发 `didFail*` —— WKWebView 把"服务器有响应"当成
    /// 正常 navigation。但用户体感是白屏 / 错乱。这里在 navigationResponse
    /// 里探一眼状态码，非 2xx/3xx 就 MWarn 一行 +URL，让客户日志能定位。
    /// 仍然 .allow，让页面照常渲染（500 页面自己也会画 something）。
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           !(200..<400).contains(http.statusCode) {
            MWarn("[BoardWebWindow] HTTP \(http.statusCode) for \(http.url?.absoluteString ?? "?")")
        }
        decisionHandler(.allow)
    }

    /// Renderer 进程崩溃 —— 页面变白、navigationDelegate 不会回调
    /// didFail。表现就是"open board 一片白，刷新有时管用有时不"。
    /// 这里至少先记一笔 + 自动 reload，让客户能看到"崩了"的证据。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MError("[BoardWebWindow] WebContent process terminated; reloading")
        reload()
    }

    /// `<a target="_blank">` 在嵌入式 WKWebView 里默认是哑的：WebKit 调
    /// `createWebViewWith` 让宿主决定怎么开新窗口，宿主不实现这个方法时
    /// 点击就一片寂静。这里把所有 target=_blank（以及 JS `window.open`）的
    /// http(s) 链接都丢给系统浏览器；返回 nil 不在嵌入 webview 里再起一个
    /// 嵌套 view（meee2 的 board shell 不打算变多窗口浏览器）。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    private func showLoadError(_ error: Error) {
        isShowingLoadError = true
        let escapedURL = Self.escapeHTML(boardURL.absoluteString)
        let escapedError = Self.escapeHTML(error.localizedDescription)
        webView.loadHTMLString(
            """
            <!doctype html>
            <html>
              <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                  body {
                    margin: 0;
                    min-height: 100vh;
                    display: grid;
                    place-items: center;
                    font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                    color: #1f2937;
                    background: #f8fafc;
                  }
                  main {
                    width: min(520px, calc(100vw - 48px));
                    border: 1px solid #d8dee8;
                    border-radius: 10px;
                    background: white;
                    padding: 24px;
                    box-shadow: 0 16px 40px rgba(15, 23, 42, 0.08);
                  }
                  h1 { margin: 0 0 12px; font-size: 18px; }
                  p { margin: 8px 0; line-height: 1.5; }
                  code {
                    display: inline-block;
                    max-width: 100%;
                    overflow-wrap: anywhere;
                    border-radius: 6px;
                    background: #eef2f7;
                    padding: 2px 6px;
                    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    font-size: 12px;
                  }
                </style>
              </head>
              <body>
                <main>
                  <h1>Board failed to load</h1>
                  <p><code>\(escapedURL)</code></p>
                  <p>\(escapedError)</p>
                  <p>Make sure the local BoardServer is running.</p>
                </main>
              </body>
            </html>
            """,
            baseURL: nil
        )
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
// MARK: - Menu Bar Actions (responder chain — active only when board window is key)

extension BoardWebWindowController {
    @objc func reloadFromMenu(_ sender: Any?) {
        reload()
    }

    @objc func openInBrowserFromMenu(_ sender: Any?) {
        openInBrowser()
    }

    @objc func toggleSidebarFromMenu(_ sender: Any?) {
        webView.evaluateJavaScript("""
            (function() {
                var btn = document.querySelector('button[title="Expand sidebar"]') ||
                          document.querySelector('button[title="Collapse"]');
                if (btn) btn.click();
            })()
            """)
    }

    @objc func zoomInFromMenu(_ sender: Any?) {
        webView.pageZoom = min(webView.pageZoom + 0.1, 3.0)
    }

    @objc func zoomOutFromMenu(_ sender: Any?) {
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.5)
    }

    @objc func actualSizeFromMenu(_ sender: Any?) {
        webView.pageZoom = 1.0
    }
}

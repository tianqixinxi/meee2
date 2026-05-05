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
}

final class BoardWebWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private let webView: DragRegionWebView
    private let boardURL: URL
    private var retryWorkItem: DispatchWorkItem?
    private var isShowingLoadError = false
    var onClose: (() -> Void)?

    init(boardURL: URL) {
        self.boardURL = boardURL

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "meee2-board-shell"

        webView = DragRegionWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
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
        window.minSize = NSSize(width: 900, height: 620)
        window.center()

        super.init(window: window)

        window.delegate = self
        window.contentView = webView
        webView.navigationDelegate = self
        // 不再挂 NSToolbar —— Reload / Open in Browser 走 web 内的 CommandBar
        // 入口（或菜单栏 / 上下文菜单），title bar 干净一片。
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        loadIfNeeded()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadIfNeeded() {
        guard webView.url == nil else { return }
        isShowingLoadError = false
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
        // 与 loadIfNeeded 同源：用户主动 reload 时也吞掉 HTTP cache
        var req = URLRequest(url: boardURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(req)
    }

    func openInBrowser() {
        NSWorkspace.shared.open(boardURL)
    }

    func windowWillClose(_ notification: Notification) {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        onClose?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isShowingLoadError {
            retryWorkItem?.cancel()
            retryWorkItem = nil
        }
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

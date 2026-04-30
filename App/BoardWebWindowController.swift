import AppKit
import WebKit
import meee2Kit

final class BoardWebWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private let webView: WKWebView
    private let boardURL: URL
    private var retryWorkItem: DispatchWorkItem?
    private var isShowingLoadError = false
    var onClose: (() -> Void)?

    init(boardURL: URL) {
        self.boardURL = boardURL

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "meee2-board-shell"

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "meee2 Board"
        window.minSize = NSSize(width: 900, height: 620)
        window.center()

        super.init(window: window)

        window.delegate = self
        window.contentView = webView
        webView.navigationDelegate = self
        window.toolbar = makeToolbar()
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
        webView.load(URLRequest(url: boardURL))
    }

    func reload() {
        isShowingLoadError = false
        if webView.url == boardURL {
            webView.reload()
        } else {
            webView.load(URLRequest(url: boardURL))
        }
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

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "meee2.board.toolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        return toolbar
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

extension BoardWebWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.reloadBoard, .openBoardInBrowser, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.reloadBoard, .openBoardInBrowser, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .reloadBoard:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reload"
            item.paletteLabel = "Reload"
            item.toolTip = "Reload Board"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.target = self
            item.action = #selector(reloadToolbarItem)
            return item
        case .openBoardInBrowser:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open in Browser"
            item.paletteLabel = "Open in Browser"
            item.toolTip = "Open Board in browser"
            item.image = NSImage(systemSymbolName: "safari", accessibilityDescription: "Open in Browser")
            item.target = self
            item.action = #selector(openInBrowserToolbarItem)
            return item
        default:
            return nil
        }
    }

    @objc private func reloadToolbarItem() {
        reload()
    }

    @objc private func openInBrowserToolbarItem() {
        openInBrowser()
    }
}

private extension NSToolbarItem.Identifier {
    static let reloadBoard = NSToolbarItem.Identifier("meee2.board.reload")
    static let openBoardInBrowser = NSToolbarItem.Identifier("meee2.board.openInBrowser")
}

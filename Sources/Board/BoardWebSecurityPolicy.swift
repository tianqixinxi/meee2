import Foundation

/// Pure URL policy shared by the AppKit WebView host and unit tests. The board
/// shell is an application surface, not a general-purpose browser.
public enum BoardWebSecurityPolicy {
    public static func isTrustedBoardURL(_ candidate: URL?, boardURL: URL) -> Bool {
        guard let candidate,
              let candidateOrigin = origin(candidate),
              let boardOrigin = origin(boardURL) else { return false }
        return candidateOrigin == boardOrigin
    }

    /// A document hosted on the loopback origin is not automatically the Board
    /// shell. In particular, OAuth callbacks and API responses must never gain
    /// access to WKScriptMessage handlers or native file/terminal bridges.
    public static func isTrustedBoardDocumentURL(_ candidate: URL?, boardURL: URL) -> Bool {
        guard isTrustedBoardURL(candidate, boardURL: boardURL), let candidate else { return false }
        let path = candidate.path.lowercased()
        if path == "/meee2/callback" || path.hasPrefix("/meee2/callback/") { return false }
        if path == "/api" || path.hasPrefix("/api/") { return false }
        return true
    }

    public static func isExternalWebURL(_ candidate: URL?, boardURL: URL) -> Bool {
        guard let candidate,
              let scheme = candidate.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return !isTrustedBoardURL(candidate, boardURL: boardURL)
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        let port: Int
        if let explicitPort = url.port {
            port = explicitPort
        } else if scheme == "http" {
            port = 80
        } else if scheme == "https" {
            port = 443
        } else {
            return nil
        }
        return "\(scheme)://\(host):\(port)"
    }
}

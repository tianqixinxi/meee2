import Foundation

/// Resolves the WebDist root used by BoardServer.
///
/// Default path is the bundled SwiftPM resource. OTA updates can atomically
/// switch the active web bundle by writing:
///
///   ~/Library/Application Support/meee2/WebDist/current.json
///
/// with:
///
///   {"version":"1.2.3","path":"versions/1.2.3"}
///
/// `path` may be relative to the WebDist application-support directory, or an
/// absolute path inside that directory. The selected directory must contain an
/// `index.html`; otherwise the bundled WebDist is used.
public enum BoardWebDistLocator {
    private struct ActiveManifest: Decodable {
        let version: String
        let path: String
    }

    public static func webRootURL() -> URL? {
        if let active = activeOverrideURL() {
            return active
        }
        return Bundle.module.url(forResource: "WebDist", withExtension: nil)
    }

    public static func activeWebRootDescription() -> String {
        if let active = activeOverrideURL() {
            return active.path
        }
        return Bundle.module.url(forResource: "WebDist", withExtension: nil)?.path ?? "<missing WebDist>"
    }

    private static func activeOverrideURL() -> URL? {
        let root = applicationSupportWebDistRoot()
        let manifestURL = root.appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ActiveManifest.self, from: data),
              !manifest.version.isEmpty,
              !manifest.path.isEmpty else {
            return nil
        }

        let candidate: URL
        if manifest.path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: manifest.path)
        } else {
            candidate = root.appendingPathComponent(manifest.path)
        }

        let standardizedRoot = root.standardizedFileURL.path
        let standardizedCandidate = candidate.standardizedFileURL
        let candidatePath = standardizedCandidate.path
        guard candidatePath == standardizedRoot || candidatePath.hasPrefix(standardizedRoot + "/") else {
            NSLog("[BoardWebDistLocator] rejecting WebDist outside application support: \(manifest.path)")
            return nil
        }

        let indexURL = standardizedCandidate.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            NSLog("[BoardWebDistLocator] active WebDist missing index.html: \(standardizedCandidate.path)")
            return nil
        }

        return standardizedCandidate
    }

    private static func applicationSupportWebDistRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("meee2/WebDist", isDirectory: true)
    }
}

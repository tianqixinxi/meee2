import Foundation

/// Single source of truth for user-visible version and generated build metadata.
public enum BuildInfo {
    public static var version: String {
        resolveVersion(
            infoDictionary: Bundle.main.infoDictionary,
            environment: ProcessInfo.processInfo.environment
        )
    }

    public static var gitCommit: String { GeneratedBuildInfo.gitCommit }
    public static var gitBranch: String { GeneratedBuildInfo.gitBranch }
    public static var buildDate: String { GeneratedBuildInfo.buildDate }
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func resolveVersion(infoDictionary: [String: Any]?, environment: [String: String]) -> String {
        if let override = environment["MEEE2_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        if let bundled = infoDictionary?["CFBundleShortVersionString"] as? String {
            let value = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return "0.0.0-dev"
    }
}

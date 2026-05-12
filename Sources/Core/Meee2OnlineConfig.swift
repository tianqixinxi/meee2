import Foundation

enum Meee2OnlineConfig {
    static var appBaseURL: URL {
        for key in ["MEEE2_ONLINE_APP_BASE_URL", "MEEE2_APP_BASE_URL", "MEEE360_APP_BASE_URL"] {
            if let raw = ProcessInfo.processInfo.environment[key],
               let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
        }

        #if DEBUG
        return URL(string: "http://localhost:3000")!
        #else
        return URL(string: "https://www.meee2.com")!
        #endif
    }

    static func appURL(path: String) -> URL {
        let base = appBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(normalizedPath)")!
    }
}

import Foundation

enum Meee360Config {
    static var appBaseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["MEEE360_APP_BASE_URL"],
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }

        #if DEBUG
        return URL(string: "http://localhost:3000")!
        #else
        return URL(string: "https://meee360-meee1.vercel.app")!
        #endif
    }

    static func appURL(path: String) -> URL {
        let base = appBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(normalizedPath)")!
    }
}

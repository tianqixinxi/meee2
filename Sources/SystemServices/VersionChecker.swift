import Foundation
import Combine

/// 版本检查器 - 每 6 小时后台异步检测 GitHub Releases
class VersionChecker: ObservableObject {
    // MARK: - Published

    /// 最新版本号
    @Published var latestVersion: String?

    /// 当前版本号
    @Published var currentVersion: String

    /// 是否有新版本
    @Published var hasUpdate: Bool = false

    /// 是否正在检查
    @Published var isChecking: Bool = false

    /// 检查错误
    @Published var lastError: String?

    // MARK: - Private

    private var timer: Timer?
    private let checkInterval: TimeInterval = 6 * 3600  // 6 小时

    // GitHub 仓库信息 (需要替换为实际的仓库)
    private let githubRepo = "tianqixinxi/meee2"

    // MARK: - Init

    init() {
        // 获取当前版本
        currentVersion = Self.getCurrentAppVersion()
    }

    // MARK: - Public

    /// 启动后台检查
    func startBackgroundCheck() {
        // 立即检查一次（异步）
        Task {
            await checkVersion()
        }

        // 启动定时器
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.checkVersion()
            }
        }

        NSLog("[VersionChecker] Started background check, interval: \(checkInterval)s")
    }

    /// 停止后台检查
    func stopBackgroundCheck() {
        timer?.invalidate()
        timer = nil
        NSLog("[VersionChecker] Stopped")
    }

    /// 手动检查更新
    func checkForUpdate() async {
        await checkVersion()
    }

    // MARK: - Private

    private func checkVersion() async {
        guard !isChecking else { return }

        await MainActor.run {
            isChecking = true
            lastError = nil
        }

        let urlString = "https://api.github.com/repos/\(githubRepo)/releases/latest"

        guard let url = URL(string: urlString) else {
            await MainActor.run {
                isChecking = false
                lastError = "Invalid URL"
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw VersionError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw VersionError.httpError(httpResponse.statusCode)
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tagName = json?["tag_name"] as? String

            // 解析版本号 (去除 v 前缀)
            let version = tagName?.replacingOccurrences(of: "^v", with: "", options: .regularExpression)

            await MainActor.run {
                self.latestVersion = version
                self.hasUpdate = self.isNewerVersion(new: version, current: self.currentVersion)
                self.isChecking = false

                if self.hasUpdate {
                    NSLog("[VersionChecker] New version available: \(version ?? "unknown")")
                }
            }

        } catch {
            await MainActor.run {
                self.isChecking = false
                self.lastError = error.localizedDescription
                NSLog("[VersionChecker] Check failed: \(error)")
            }
        }
    }

    /// 比较版本号
    private func isNewerVersion(new: String?, current: String) -> Bool {
        guard let new = new, !new.isEmpty else { return false }

        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        // 补齐版本号位数
        let maxCount = max(newParts.count, currentParts.count)
        let newPadded = newParts + Array(repeating: 0, count: maxCount - newParts.count)
        let currentPadded = currentParts + Array(repeating: 0, count: maxCount - currentParts.count)

        for i in 0..<maxCount {
            if newPadded[i] > currentPadded[i] {
                return true
            } else if newPadded[i] < currentPadded[i] {
                return false
            }
        }

        return false
    }

    /// 获取当前 App 版本
    private static func getCurrentAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "1.0.0"
    }

    /// 获取 GitHub Releases 页面 URL
    var releasesPageUrl: URL? {
        URL(string: "https://github.com/\(githubRepo)/releases")
    }
}

// MARK: - Error

enum VersionError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        }
    }
}

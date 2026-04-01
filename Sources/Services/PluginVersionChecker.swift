import Foundation
import Combine
import PeerPluginKit

/// Plugin 版本检查器 - 检测统一仓库 PeerPlugins 中的最新版本
class PluginVersionChecker: ObservableObject {
    // MARK: - Published

    /// Plugin 最新版本 (pluginId -> latestVersion)
    @Published var pluginUpdates: [String: String] = [:]

    /// 是否正在检查
    @Published var isChecking: Bool = false

    /// 检查错误
    @Published var lastError: String?

    // MARK: - Private

    private var timer: Timer?
    private let checkInterval: TimeInterval = 6 * 3600  // 6 小时

    // 统一 Plugin 仓库
    private let repoUrl = "https://api.github.com/repos/anthropics/PeerPlugins/contents/releases/latest.json"

    // MARK: - Public

    /// 启动后台检查
    func startBackgroundCheck() {
        // 立即检查一次（异步）
        Task {
            await checkAllPlugins()
        }

        // 启动定时器
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.checkAllPlugins()
            }
        }

        NSLog("[PluginVersionChecker] Started background check, interval: \(checkInterval)s")
    }

    /// 停止后台检查
    func stopBackgroundCheck() {
        timer?.invalidate()
        timer = nil
        NSLog("[PluginVersionChecker] Stopped")
    }

    /// 手动检查更新
    func checkForUpdates() async {
        await checkAllPlugins()
    }

    /// 获取 Plugin 最新版本
    func getLatestVersion(for pluginId: String) -> String? {
        return pluginUpdates[pluginId]
    }

    /// 检查 Plugin 是否有更新
    func hasUpdate(plugin: SessionPlugin) -> Bool {
        guard let latest = pluginUpdates[plugin.pluginId] else { return false }
        return isNewerVersion(new: latest, current: plugin.version)
    }

    // MARK: - Private

    private func checkAllPlugins() async {
        guard !isChecking else { return }

        await MainActor.run {
            isChecking = true
            lastError = nil
        }

        guard let url = URL(string: repoUrl) else {
            await MainActor.run {
                isChecking = false
                lastError = "Invalid URL"
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw VersionError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw VersionError.httpError(httpResponse.statusCode)
            }

            // 解析 JSON
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let plugins = json?["plugins"] as? [String: String]

            await MainActor.run {
                if let plugins = plugins {
                    self.pluginUpdates = plugins
                    NSLog("[PluginVersionChecker] Found \(plugins.count) plugin versions")
                }
                self.isChecking = false
            }

        } catch {
            await MainActor.run {
                self.isChecking = false
                self.lastError = error.localizedDescription
                NSLog("[PluginVersionChecker] Check failed: \(error)")
            }
        }
    }

    /// 比较版本号
    private func isNewerVersion(new: String, current: String) -> Bool {
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

    /// 获取 Plugin Releases 页面 URL
    func releasesPageUrl(for pluginId: String) -> URL? {
        // 指向统一仓库的 releases 页面
        return URL(string: "https://github.com/anthropics/PeerPlugins/releases")
    }
}
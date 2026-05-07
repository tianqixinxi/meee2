import Foundation
import Combine

/// VersionChecker —— Settings 里 "Current / Latest / Check for Updates" UI
/// 的数据源。统一走 Sparkle 的 appcast.xml（SUFeedURL）作为唯一真相，跟
/// menubar "Check for Updates…" 是同一份 feed。
///
/// 历史：原本用 GitHub Releases API 的 `/releases/latest`,**默认排除 prerelease**,
/// 而我们现在 release 流程里大部分是 rc/beta。结果 Settings 显示的 "Latest"
/// 是好几周前的老正式版,跟 menubar Sparkle 给的"有 v0.3.0-rc4 可下载"自相
/// 矛盾。改成解析 appcast.xml 的第一个 `<item>` —— Sparkle 自己也是这样判
/// "最新"。
public class VersionChecker: ObservableObject {
    /// 进程级共享实例。AppDelegate 启动时 startBackgroundCheck();
    /// SettingsView 跟 BoardServer 都从这里读 latestVersion/hasUpdate,
    /// 不再各自起一份避免 N 倍 raw.githubusercontent 拉取。
    public static let shared = VersionChecker()

    @Published public var latestVersion: String?
    @Published public var currentVersion: String
    @Published public var hasUpdate: Bool = false
    @Published public var isChecking: Bool = false
    @Published public var lastError: String?

    private var timer: Timer?
    /// Background check interval. Lower than Sparkle's 24h schedule so the
    /// Settings UI's "Latest" stays fresh while the panel is open; Sparkle's
    /// own scheduler still owns the actual update prompt timing.
    private let checkInterval: TimeInterval = 6 * 3600

    public init() {
        currentVersion = Self.getCurrentAppVersion()
    }

    public func startBackgroundCheck() {
        Task { await checkVersion() }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { await self?.checkVersion() }
        }
        NSLog("[VersionChecker] Started background check, interval: \(checkInterval)s")
    }

    public func stopBackgroundCheck() {
        timer?.invalidate()
        timer = nil
        NSLog("[VersionChecker] Stopped")
    }

    public func checkForUpdate() async {
        await checkVersion()
    }

    /// **DEV-ONLY** 后门:手动 override latest version,触发 hasUpdate 重算。
    /// 用来 e2e 测试"staged 包过时"场景(staged 0.4.1 + 假 latest=0.4.99
    /// → 点 pill 时 driver 应该 discard pending → fresh check)。
    /// 传 nil/空:**强制 re-fetch appcast 恢复真实 latest**(不是清空,
    /// 否则 webui pill 会暂时不渲染)。
    public func devOverrideLatest(_ version: String?) {
        if let v = version, !v.isEmpty {
            Task { @MainActor in
                self.latestVersion = v
                self.hasUpdate = self.isNewerVersion(new: v, current: self.currentVersion)
                NSLog("[VersionChecker] DEV override latest=\(v) hasUpdate=\(self.hasUpdate)")
            }
        } else {
            // Clear override = re-fetch real appcast。这是同步阻塞的 ?
            // 不,checkVersion 是 async。e2e 测试调完这条会立刻 assert
            // latest,所以等一下再返回 —— 给 checkVersion 时间完成。
            Task {
                await self.checkForUpdate()
                NSLog("[VersionChecker] DEV override cleared, re-fetched latest=\(self.latestVersion ?? "nil")")
            }
        }
    }

    /// Releases 页面 URL —— 仅作 fallback 给 Settings 的 "Download" link 用。
    /// 正经 update flow 走 Sparkle（settingsView 的按钮调
    /// SPUStandardUpdaterController.checkForUpdates(_:)）。
    var releasesPageUrl: URL? {
        URL(string: "https://github.com/tianqixinxi/meee2/releases")
    }

    // MARK: - Private

    private func checkVersion() async {
        guard !isChecking else { return }
        await MainActor.run {
            isChecking = true
            lastError = nil
        }

        // appcast URL 来自 Info.plist 的 SUFeedURL —— 跟 Sparkle 共享同一条
        // 配置，避免两套配置漂。fallback 到硬编码值兜底（理论上不会触发）。
        let feedURLString = (Bundle.main.infoDictionary?["SUFeedURL"] as? String)
            ?? "https://raw.githubusercontent.com/tianqixinxi/meee2/appcast/appcast.xml"
        guard let url = URL(string: feedURLString) else {
            await MainActor.run {
                isChecking = false
                lastError = "Invalid SUFeedURL"
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        // raw.githubusercontent 缓存 5min；强制 reload 让 Settings 上点
        // refresh 立刻看到最新。
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw VersionError.invalidResponse
            }
            guard http.statusCode == 200 else {
                throw VersionError.httpError(http.statusCode)
            }
            let version = Self.parseLatestVersion(fromAppcast: data)
            await MainActor.run {
                self.latestVersion = version
                self.hasUpdate = self.isNewerVersion(new: version, current: self.currentVersion)
                self.isChecking = false
                if self.hasUpdate {
                    NSLog("[VersionChecker] New version available: \(version ?? "unknown") (current: \(self.currentVersion))")
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

    /// 从 appcast.xml 拿"最新"版本号 —— **扫所有 sparkle:shortVersionString 取
    /// 最大值**，不依赖 item 文件顺序。早期 sparkle-publish.sh 把新 item 加在
    /// channel 末尾（应该 prepend 但写成了 append），导致 first-match-wins
    /// 拿到最老 entry。即使脚本修了，存量 appcast.xml 顺序还是乱的；这个
    /// parser 用语义版本最大值兜住所有历史顺序。
    /// 不引第三方 XML 库，appcast schema 稳定，正则够用。
    static func parseLatestVersion(fromAppcast data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        // 优先 sparkle:shortVersionString（user-facing），fallback sparkle:version。
        let candidates = collectAll(in: xml,
                                    pattern: #"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"#)
            ?? collectAll(in: xml, pattern: #"<sparkle:version>([^<]+)</sparkle:version>"#)
            ?? []
        guard !candidates.isEmpty else { return nil }
        // 用 isNewerVersion 当排序 key —— 同一份 semver 比较逻辑。
        return candidates.max(by: { a, b in
            // a < b iff b is newer than a
            VersionChecker.staticIsNewerVersion(new: b, current: a)
        })
    }

    /// 把所有 `<tag>VALUE</tag>` 形式的内容收齐返回。开闭标签由调用者拼好的
    /// pattern 决定 —— 这里用 NSRegularExpression 而不是 String.range(of:) 因为
    /// 我们要拿到所有匹配，不止第一个。
    private static func collectAll(in xml: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, options: [], range: NSRange(location: 0, length: ns.length))
        let results: [String] = matches.compactMap { m in
            guard m.numberOfRanges >= 2 else { return nil }
            return ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return results.isEmpty ? nil : results
    }

    /// Static 版的 isNewerVersion，用于 parseLatestVersion 排序。逻辑跟 instance
    /// 版完全一致 —— 重复一份是因为 instance 方法不能直接当 closure key 在
    /// `max(by:)` 里用 self（static parser 没 self）。
    private static func staticIsNewerVersion(new: String, current: String) -> Bool {
        let (newCore, newPre) = splitPrerelease(new)
        let (curCore, curPre) = splitPrerelease(current)
        let cmp = compareCore(newCore, curCore)
        if cmp != .orderedSame { return cmp == .orderedDescending }
        switch (newPre, curPre) {
        case (nil, nil): return false
        case (nil, _?):  return true
        case (_?, nil):  return false
        case (let a?, let b?):
            return a.compare(b, options: .numeric) == .orderedDescending
        }
    }

    /// 简化版 SemVer-ish 比较，能处理 `0.3.0`、`0.3.0-rc4`、`1.0.0` 这种。
    /// 拆主版本（点分整数）→ 数字比；主版本一致再看 prerelease 后缀（有 `-`
    /// 标记的视为更老）。这跟 Sparkle 内部 SUStandardVersionComparator 的行为
    /// 不完全一致，但对我们目前的版本号格式够用。
    func isNewerVersion(new: String?, current: String) -> Bool {
        guard let new = new, !new.isEmpty else { return false }

        let (newCore, newPre) = Self.splitPrerelease(new)
        let (curCore, curPre) = Self.splitPrerelease(current)

        let cmp = Self.compareCore(newCore, curCore)
        if cmp != .orderedSame { return cmp == .orderedDescending }

        // Core 一致：有 prerelease 后缀的更老（0.3.0 > 0.3.0-rc4）；
        // 都带后缀就字符串比；都没后缀视为相等（不算新版）。
        switch (newPre, curPre) {
        case (nil, nil): return false
        case (nil, _?):  return true   // 0.3.0 > 0.3.0-rc4
        case (_?, nil):  return false  // 0.3.0-rc4 < 0.3.0
        case (let a?, let b?):
            return a.compare(b, options: .numeric) == .orderedDescending
        }
    }

    private static func splitPrerelease(_ s: String) -> (core: String, pre: String?) {
        if let dash = s.firstIndex(of: "-") {
            return (String(s[..<dash]), String(s[s.index(after: dash)...]))
        }
        return (s, nil)
    }

    private static func compareCore(_ a: String, _ b: String) -> ComparisonResult {
        let aP = a.split(separator: ".").compactMap { Int($0) }
        let bP = b.split(separator: ".").compactMap { Int($0) }
        let n = max(aP.count, bP.count)
        for i in 0..<n {
            let av = i < aP.count ? aP[i] : 0
            let bv = i < bP.count ? bP[i] : 0
            if av > bv { return .orderedDescending }
            if av < bv { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func getCurrentAppVersion() -> String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return v
        }
        return "0.0.0-dev"
    }
}

enum VersionError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code): return "HTTP error: \(code)"
        }
    }
}

import XCTest
@testable import meee2Kit

/// 登录态一天内反复失效的两个根因的回归测试（2026-06-12 实测复现）：
///
/// 1. refresh 无 single-flight —— access token 过期瞬间多个并发请求各自带
///    同一个 refresh token 调 /api/v1/connect/refresh，Supabase 轮换 +
///    reuse-detection 吊销整个 token family，所有副本全部 AUTH_INVALID。
/// 2. 凭证存储三处分裂（settings.json / com.meee2.app / meee2 偏好域）——
///    重新登录后另一形态的二进制仍从自己的偏好域读旧 token。
///
/// 约定：token 唯一真相 = ~/.meee2/settings.json；偏好域绝不存 token；
/// refresh 401 → 清凭证 + authExpired 显式重新登录态。
final class OnlineProxyAuthTests: XCTestCase {
    private var tempDir: URL!
    private var settingsFile: URL!
    private var testDefaults: UserDefaults!
    private let suiteName = "OnlineProxyAuthTests"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("online-proxy-auth-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        settingsFile = tempDir.appendingPathComponent("settings.json")
        testDefaults = UserDefaults(suiteName: suiteName)
        testDefaults.removePersistentDomain(forName: suiteName)

        OnlineProxy.settingsFileURLOverride = settingsFile
        OnlineProxy.userDefaultsOverride = testDefaults
        OnlineProxy.resetRefreshStateForTesting()
    }

    override func tearDown() {
        OnlineProxy.settingsFileURLOverride = nil
        OnlineProxy.userDefaultsOverride = nil
        OnlineProxy.refreshTransportOverride = nil
        OnlineProxy.resetRefreshStateForTesting()
        testDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeSettingsFile(_ meee2: [String: Any]) {
        let root: [String: Any] = ["meee2": meee2]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: settingsFile, options: .atomic)
    }

    private func fileMeee2() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return (root["meee2"] as? [String: Any]) ?? [:]
    }

    private func baseSettings(accessToken: String, refreshToken: String) -> [String: Any] {
        [
            "supabaseUrl": "https://example.supabase.co",
            "supabaseKey": "anon-key",
            "onlineBaseUrl": "https://online.example.com",
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "teamId": "team-1",
            "userId": "user-1"
        ]
    }

    private func refreshSuccessBody(access: String, refresh: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "access_token": access,
            "refresh_token": refresh
        ])
    }

    // MARK: - 凭证读取：settings.json 是唯一真相

    func testLoadSettingsIgnoresUserDefaultsTokens() {
        // 偏好域里是另一形态二进制留下的旧 token family —— 必须被无视
        testDefaults.set("stale-access", forKey: "meee2OnlineAccessToken")
        testDefaults.set("stale-refresh", forKey: "meee2OnlineRefreshToken")
        writeSettingsFile(baseSettings(accessToken: "fresh-access", refreshToken: "fresh-refresh"))

        let settings = OnlineProxy.loadSettings()
        XCTAssertEqual(settings.accessToken, "fresh-access")
        XCTAssertEqual(settings.refreshToken, "fresh-refresh")
        XCTAssertFalse(settings.authExpired)
    }

    func testLoadSettingsTokensEmptyWhenFileHasNone() {
        // 文件没 token 时绝不回落到偏好域缓存 —— 那正是分裂根因
        testDefaults.set("stale-access", forKey: "meee2OnlineAccessToken")
        var meee2 = baseSettings(accessToken: "", refreshToken: "")
        meee2.removeValue(forKey: "accessToken")
        meee2.removeValue(forKey: "refreshToken")
        writeSettingsFile(meee2)

        let settings = OnlineProxy.loadSettings()
        XCTAssertEqual(settings.accessToken, "")
        XCTAssertEqual(settings.refreshToken, "")
    }

    func testLoadSettingsNonTokenFieldsPreferFileOverDefaults() {
        // 非 token 字段文件优先：登录回调总是写文件，偏好域只是 legacy fallback
        testDefaults.set("stale-team", forKey: "meee2TeamId")
        writeSettingsFile(baseSettings(accessToken: "a", refreshToken: "r"))

        XCTAssertEqual(OnlineProxy.loadSettings().teamId, "team-1")

        // 文件缺字段时回落偏好域（旧安装迁移）
        var meee2 = baseSettings(accessToken: "a", refreshToken: "r")
        meee2.removeValue(forKey: "teamId")
        writeSettingsFile(meee2)
        XCTAssertEqual(OnlineProxy.loadSettings().teamId, "stale-team")
    }

    func testPersistTokensWritesFileAndPurgesDefaultsCache() {
        writeSettingsFile(baseSettings(accessToken: "old-a", refreshToken: "old-r"))
        testDefaults.set("old-a", forKey: "meee2OnlineAccessToken")
        testDefaults.set(true, forKey: "meee2AuthExpired")

        OnlineProxy.persistTokens(accessToken: "new-a", refreshToken: "new-r")

        let meee2 = fileMeee2()
        XCTAssertEqual(meee2["accessToken"] as? String, "new-a")
        XCTAssertEqual(meee2["refreshToken"] as? String, "new-r")
        XCTAssertEqual(meee2["authExpired"] as? Bool, false)
        XCTAssertNil(testDefaults.object(forKey: "meee2OnlineAccessToken"))
        XCTAssertNil(testDefaults.object(forKey: "meee2OnlineRefreshToken"))
        XCTAssertNil(testDefaults.object(forKey: "meee2AuthExpired"))
        // 其余字段不能被冲掉
        XCTAssertEqual(meee2["teamId"] as? String, "team-1")
    }

    // MARK: - Single-flight refresh

    func testConcurrentRefreshSingleFlight() {
        writeSettingsFile(baseSettings(accessToken: "expired-a", refreshToken: "rt-1"))

        let transportCalls = ManagedAtomicCounter()
        OnlineProxy.refreshTransportOverride = { _ in
            transportCalls.increment()
            // 模拟网络往返，让其余并发 401 真正排队在锁上
            Thread.sleep(forTimeInterval: 0.2)
            return .success(self.refreshSuccessBody(access: "rotated-a", refresh: "rt-2"))
        }

        let stale = OnlineProxy.loadSettings()
        let results = ConcurrentResults()
        // 模拟 access token 过期瞬间 8 个并发请求同时拿到 401
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.append(OnlineProxy.refreshAccessToken(stale: stale))
        }

        // Supabase refresh token 一次性轮换：upstream 只允许被打一次
        XCTAssertEqual(transportCalls.value, 1, "并发 401 必须 single-flight，多打一次就触发 reuse-detection 吊销全家")
        let tokens = Set(results.values.map { $0?.accessToken ?? "<nil>" })
        XCTAssertEqual(tokens, ["rotated-a"], "等待方必须复用第一个刷新的结果")
        let meee2 = fileMeee2()
        XCTAssertEqual(meee2["accessToken"] as? String, "rotated-a")
        XCTAssertEqual(meee2["refreshToken"] as? String, "rt-2")
    }

    func testRefreshReusesResultWhenFileAlreadyRotated() {
        // 等锁期间别的请求已刷新落盘：double-check 直接复用，不再打网络
        writeSettingsFile(baseSettings(accessToken: "expired-a", refreshToken: "rt-1"))
        let stale = OnlineProxy.loadSettings()
        writeSettingsFile(baseSettings(accessToken: "rotated-by-peer", refreshToken: "rt-2"))

        OnlineProxy.refreshTransportOverride = { _ in
            XCTFail("token 已被并发请求轮换，不应再发起第二次刷新")
            return .failure(.badURL)
        }

        let refreshed = OnlineProxy.refreshAccessToken(stale: stale)
        XCTAssertEqual(refreshed?.accessToken, "rotated-by-peer")
    }

    func testRefreshWaitsForCrossProcessLockAndReusesRotatedTokens() {
        // codex P1：NSLock 只管进程内 —— bundled app / debug 二进制 / CLI
        // 同时运行时仍可能各自拿同一个 refresh token 并发刷新。这里模拟
        // 「另一个进程」先持有 settings.json.lock 并完成轮换：本进程的
        // refresh 必须阻塞在文件锁上，等到锁后复用文件里的新凭证，不打网络。
        writeSettingsFile(baseSettings(accessToken: "expired-a", refreshToken: "rt-1"))
        let stale = OnlineProxy.loadSettings()

        let lockPath = settingsFile.path + ".lock"
        let fd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)

        OnlineProxy.refreshTransportOverride = { _ in
            XCTFail("另一进程已轮换凭证，等到文件锁后应直接复用，不再打 refresh")
            return .failure(.badURL)
        }

        let done = expectation(description: "refresh returns")
        let results = ConcurrentResults()
        DispatchQueue.global().async {
            results.append(OnlineProxy.refreshAccessToken(stale: stale))
            done.fulfill()
        }

        // 「另一个进程」持锁期间完成刷新落盘，然后放锁
        Thread.sleep(forTimeInterval: 0.3)
        writeSettingsFile(baseSettings(accessToken: "rotated-by-other-process", refreshToken: "rt-2"))
        flock(fd, LOCK_UN)
        close(fd)

        wait(for: [done], timeout: 5)
        XCTAssertEqual(results.values.first??.accessToken, "rotated-by-other-process")
    }

    func testRefreshFailureCooldownPreventsRetryStorm() {
        writeSettingsFile(baseSettings(accessToken: "expired-a", refreshToken: "rt-1"))
        let transportCalls = ManagedAtomicCounter()
        OnlineProxy.refreshTransportOverride = { _ in
            transportCalls.increment()
            return .failure(.http(status: 503, body: Data()))
        }

        let stale = OnlineProxy.loadSettings()
        XCTAssertNil(OnlineProxy.refreshAccessToken(stale: stale))
        XCTAssertNil(OnlineProxy.refreshAccessToken(stale: stale), "冷却窗口内不得重试")
        XCTAssertEqual(transportCalls.value, 1)
        // 非 AUTH_INVALID 失败（网络/5xx）不清凭证
        XCTAssertEqual(fileMeee2()["refreshToken"] as? String, "rt-1")
    }

    // MARK: - AUTH_INVALID → 清凭证 + 显式重新登录态

    func testRefresh401ClearsCredentialsAndMarksAuthExpired() {
        writeSettingsFile(baseSettings(accessToken: "expired-a", refreshToken: "revoked-rt"))
        testDefaults.set(true, forKey: "meee2Connected")
        let transportCalls = ManagedAtomicCounter()
        OnlineProxy.refreshTransportOverride = { _ in
            transportCalls.increment()
            return .failure(.http(status: 401, body: Data(#"{"code":"AUTH_INVALID"}"#.utf8)))
        }

        let notified = expectation(forNotification: OnlineProxy.authExpiredNotification, object: nil)
        let stale = OnlineProxy.loadSettings()
        XCTAssertNil(OnlineProxy.refreshAccessToken(stale: stale))
        wait(for: [notified], timeout: 2)

        // settings.json：token 清空 + authExpired 置位（所有二进制形态可见）
        let meee2 = fileMeee2()
        XCTAssertEqual(meee2["accessToken"] as? String, "")
        XCTAssertEqual(meee2["refreshToken"] as? String, "")
        XCTAssertEqual(meee2["authExpired"] as? Bool, true)
        // 当前进程域：显式退出「已连接」态，UI 提示重新登录
        XCTAssertFalse(testDefaults.bool(forKey: "meee2Connected"))
        XCTAssertTrue(testDefaults.bool(forKey: "meee2AuthExpired"))
        XCTAssertTrue(OnlineProxy.loadSettings().authExpired)

        // 吊销后再 401 不得再碰 refresh 端点（refresh token 已清空）
        XCTAssertNil(OnlineProxy.refreshAccessToken(stale: stale))
        XCTAssertEqual(transportCalls.value, 1)
    }

    func testCallOnlineAPIShortCircuitsWhenAuthExpired() {
        var meee2 = baseSettings(accessToken: "", refreshToken: "")
        meee2["authExpired"] = true
        writeSettingsFile(meee2)
        testDefaults.set(true, forKey: "meee2Connected")

        // authExpired 短路：不发网络请求（发了会撞真实 URLSession 超时 35s）
        let started = Date()
        let result = OnlineProxy.callOnlineAPI(method: "GET", path: "/api/v1/anything")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        guard case .failure(.missingSettings) = result else {
            return XCTFail("authExpired 时应短路为 missingSettings，实际: \(result)")
        }
        // 短路路径也要把本进程 UI 收敛到重新登录态
        XCTAssertFalse(testDefaults.bool(forKey: "meee2Connected"))
        XCTAssertTrue(testDefaults.bool(forKey: "meee2AuthExpired"))
    }

    func testMarkAuthExpiredPreservesNonCredentialFields() {
        writeSettingsFile(baseSettings(accessToken: "a", refreshToken: "r"))
        OnlineProxy.markAuthExpired()
        let meee2 = fileMeee2()
        XCTAssertEqual(meee2["teamId"] as? String, "team-1")
        XCTAssertEqual(meee2["supabaseKey"] as? String, "anon-key")
        XCTAssertEqual(meee2["authExpired"] as? Bool, true)
    }
}

/// NSLock 包一个 Int —— 测试里跨 concurrentPerform 线程计数用
private final class ManagedAtomicCounter {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ConcurrentResults {
    private let lock = NSLock()
    private var storage: [OnlineProxy.Settings?] = []

    func append(_ value: OnlineProxy.Settings?) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [OnlineProxy.Settings?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

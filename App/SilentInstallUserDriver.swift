import Foundation
import Sparkle
import AppKit

/// Custom SPUUserDriver —— codex-style "gentle reminders" 模式:
///
/// 1. **后台调度**(SUEnableAutomaticChecks 24h)发现新版 → driver
///    auto-confirm 让 Sparkle 跑下载 → staged + verified 后**halt**
///    (`showReady(toInstallAndRelaunch:)` 不立即 reply,把 reply closure
///    保存,把 `isReadyToInstall=true` 暴露给外部观察)。
///
/// 2. host(BoardServer /api/version)读 `isReadyToInstall`,frontend
///    UpdatePill 只在这时渲染 → 用户看到 pill 时**包已经下完了**。
///
/// 3. 用户点 pill → AppDelegate 调 `confirmPendingInstall()` → 之前保存的
///    reply 现在被调用 → Sparkle 立刻 apply + relaunch,**无下载等待**。
///
/// 4. **user-initiated**(menubar "Check for Updates…" / 用户主动 check)
///    调用方手动跑 `updater.checkForUpdates()`,driver 在 showUpdateFound
///    时看到 state.userInitiated=true,后续 showReady 直接 auto-confirm,
///    走完整 download+install+relaunch 闭环(没机会"等用户点 pill")。
///
/// 历史:第一版 driver 在所有 showReady 都 auto-reply,导致后台 schedule
/// 一发现就装,没有"看到 pill 才装"的体验。改成区分 user-initiated vs
/// background 后才符合 codex 行为。
final class SilentInstallUserDriver: NSObject, SPUUserDriver {

    /// 保存 background 路径的 install confirmation closure。pill 点击时调
    /// `confirmPendingInstall()` 来 consume 它,Sparkle 接收 .install 后开
    /// 始 relaunch 流程。nil = 当前没有 staged 的更新。
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?

    /// 上次 showUpdateFound 看到的 state.userInitiated。决定后面 showReady
    /// 该 auto-install 还是 hold-for-user-click。一次 update cycle 内多次回
    /// 调共享同一个值。
    private var lastUserInitiated: Bool = false

    /// 当前 staged 包的版本字符串(showUpdateFound 时 appcastItem 给的)。
    /// AppDelegate 比对它跟 VersionChecker.shared.latestVersion:
    ///   - 相等 → 用户点 pill 时直接 confirmPendingInstall(秒重启)
    ///   - 不相等(远端出了更新版,staged 包过时)→ discardPending() 丢
    ///     掉旧 reply,跑 fresh checkForUpdates 下最新的
    private(set) var stagedVersion: String?

    /// 通知外部 isReadyToInstall 翻转 —— BoardServer 的 /api/version 通过
    /// `VersionChecker.shared.recomputeAfterStateChange()` 轮询,这里发个
    /// notification 触发 webui 提前刷新而不必等下次 8min poll。
    static let stagedStateDidChange = Notification.Name("meee2.sparkle.stagedStateChanged")

    /// host 观测的"可以瞬间装了吗" —— UpdatePill 渲染条件。
    /// 后台 schedule cycle 把包下完到 staged 时 → 翻成 true。
    /// pill 点击 → confirmPendingInstall 后 Sparkle 准备 relaunch,翻回 false
    /// (虽然 app 即将重启,这个状态被读到的窗口很短,但还是保持一致)。
    private(set) var isReadyToInstall: Bool = false {
        didSet {
            if oldValue != isReadyToInstall {
                NotificationCenter.default.post(name: Self.stagedStateDidChange, object: nil)
            }
        }
    }

    /// pill 点击入口。如果有 staged update(背景已下载完),consume 那个
    /// pending reply,Sparkle 立即 apply。返回 true 表示走的是"瞬间装"路径,
    /// 调用方不必再 fallback 到 user-initiated check。
    func confirmPendingInstall() -> Bool {
        guard let reply = pendingInstallReply else { return false }
        pendingInstallReply = nil
        isReadyToInstall = false
        stagedVersion = nil
        reply(.install)
        return true
    }

    /// 丢掉当前 staged 的更新(版本对不上了)。把 reply 用 .dismiss 关掉,
    /// Sparkle 会清理 install cycle,然后 host 通常会立刻起一次 user-initiated
    /// check 拉真正的最新版下来装。
    /// 返回 true 表示"确实有 pending 被丢了",false 表示本来就没东西丢。
    func discardPendingInstall() -> Bool {
        guard let reply = pendingInstallReply else { return false }
        let dropped = stagedVersion ?? "<unknown>"
        pendingInstallReply = nil
        isReadyToInstall = false
        stagedVersion = nil
        // .dismiss = 用户暂时不装,Sparkle 留 staged 包但停止 install cycle
        // 这里其实想"丢弃 staged 包",但 SPUUserUpdateChoice 没 .discard。
        // .dismiss 已经够用 —— 之后的 fresh check 看到新版本会重新下载,
        // 旧 staged 是 .skip 的话 Sparkle 会记住跳过,所以不能用 .skip。
        reply(.dismiss)
        NSLog("[SilentDriver] dropped stale staged update v\(dropped) — newer version exists")
        return true
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Info.plist 已写死 SUEnableAutomaticChecks=YES,直接同意
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // pill / menubar 已经显示进度,不弹 "Checking..." 框
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // 记录这次 cycle 的 userInitiated,后面 showReady 用
        lastUserInitiated = state.userInitiated
        // 记录正在下载/将要 stage 的版本号,供 AppDelegate 在 pill 点击时
        // 跟 VersionChecker.shared.latestVersion 比对
        stagedVersion = appcastItem.versionString
        // 一律 .install 让 Sparkle 进入下载阶段;真正的"halt 等用户"在
        // showReady 那一步处理(下完 + 验签 + extract 之后)
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // 没 UI 显示 release notes,丢弃
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        NSLog("[SilentDriver] release notes download failed: \(error)")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // pill 自动重新检查时每天都会走这里("已是最新")
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        NSLog("[SilentDriver] updater error: \(error.localizedDescription)")
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        // 默认会弹下载进度框,no-op 后台下
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // 关键路径分叉:
        if lastUserInitiated {
            // 用户主动点 menubar "Check..." / dev 跑 user-initiated cycle
            // → 走完整闭环,无停顿
            reply(.install)
        } else {
            // 后台调度路径 → halt,把 reply 留给 pill 点击 consume
            pendingInstallReply = reply
            isReadyToInstall = true
            NSLog("[SilentDriver] update staged + ready to install (background path); waiting for user pill click")
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        // app 已 terminate / 正在 install,默认会弹"Installing..."进度框,no-op
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        // 重启后第一次 launch 默认弹"Update installed!",no-op + ack
        acknowledgement()
    }

    func showUpdateInFocus() {
        // pill 已经是 host UI,Sparkle 不需要 focus 任何窗口
    }

    func dismissUpdateInstallation() {
        // 没装东西可 dismiss,no-op
    }
}

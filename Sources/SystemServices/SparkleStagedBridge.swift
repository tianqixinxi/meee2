import Foundation

/// 跨模块小桥:App 模块的 SilentInstallUserDriver 把"已 staged"状态注入这
/// 个 enum,meee2Kit 模块的 BoardAPI 读它构造 /api/version 的 isStaged 字段。
///
/// 这个 enum 本来该跟 SilentInstallUserDriver 放一起,但 BoardAPI 在
/// meee2Kit 模块,无法 import App 模块,所以反向拆出来放 meee2Kit 这边。
public enum SparkleStagedBridge {
    private static let queue = DispatchQueue(label: "meee2.sparkle-staged-bridge")
    private static var _snapshot: () -> Bool = { false }
    private static var _stagedVersion: () -> String? = { nil }

    /// 由 App 模块的 AppDelegate 在启动时调一次。Closure 内通常 read
    /// SilentInstallUserDriver.isReadyToInstall。
    public static func setSnapshot(_ snap: @escaping () -> Bool) {
        queue.sync { _snapshot = snap }
    }

    public static func setStagedVersionProvider(_ provider: @escaping () -> String?) {
        queue.sync { _stagedVersion = provider }
    }

    /// BoardAPI.getVersion 每次 request 调一次。是个轻量 read,不做 IO。
    public static func snapshot() -> Bool {
        queue.sync { _snapshot() }
    }

    public static func stagedVersion() -> String? {
        queue.sync { _stagedVersion() }
    }
}

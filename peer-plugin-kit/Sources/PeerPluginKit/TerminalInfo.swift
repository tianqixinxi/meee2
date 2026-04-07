import Foundation

/// 终端跳转信息
public struct TerminalInfo: Hashable, Codable {
    /// TTY 设备路径
    public var tty: String?

    /// 终端程序名称 (如 "ghostty", "iterm2", "cmux")
    public var termProgram: String?

    /// 终端应用 Bundle ID (如 "com.mitchellh.ghostty")
    public var termBundleId: String?

    /// cmux socket 路径
    public var cmuxSocketPath: String?

    /// cmux surface ID
    public var cmuxSurfaceId: String?

    /// 插件特定的跳转数据 (如 Ghostty terminal ID, Cursor project path)
    public var customData: [String: String]?

    public init(
        tty: String? = nil,
        termProgram: String? = nil,
        termBundleId: String? = nil,
        cmuxSocketPath: String? = nil,
        cmuxSurfaceId: String? = nil,
        customData: [String: String]? = nil
    ) {
        self.tty = tty
        self.termProgram = termProgram
        self.termBundleId = termBundleId
        self.cmuxSocketPath = cmuxSocketPath
        self.cmuxSurfaceId = cmuxSurfaceId
        self.customData = customData
    }
}

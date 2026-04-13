import Cocoa

// MARK: - NSScreen Extension for Notch Detection

public extension NSScreen {
    /// 检测屏幕刘海尺寸
    /// 使用 safeAreaInsets 和 auxiliaryTopArea 来计算
    var notchSize: CGSize {
        // 如果有刘海
        if safeAreaInsets.top > 0 {
            let notchHeight = safeAreaInsets.top
            let fullWidth = frame.width

            // 使用 auxiliaryTopLeftArea 和 auxiliaryTopRightArea 计算刘海宽度
            let leftPadding = auxiliaryTopLeftArea?.width ?? 0
            let rightPadding = auxiliaryTopRightArea?.width ?? 0

            guard leftPadding > 0, rightPadding > 0 else { return .zero }

            let notchWidth = fullWidth - leftPadding - rightPadding
            return CGSize(width: notchWidth, height: notchHeight)
        }

        // 无刘海：外接显示器返回菜单栏高度（宽度为 0，由 AppDelegate 使用默认宽度）
        if !isBuiltinDisplay {
            // 使用固定高度 25px（菜单栏标准高度）
            return CGSize(width: 0, height: 25)
        }

        return .zero
    }

    /// 检查是否是内置显示器
    var isBuiltinDisplay: Bool {
        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        guard let id = deviceDescription[screenNumberKey],
              let rid = (id as? NSNumber)?.uint32Value,
              CGDisplayIsBuiltin(rid) == 1
        else { return false }
        return true
    }

    /// 获取内置显示器
    static var builtin: NSScreen? {
        screens.first { $0.isBuiltinDisplay }
    }

    // MARK: - 多屏幕支持

    /// 屏幕的唯一标识符 (用于存储用户选择)
    var screenId: String {
        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        if let id = deviceDescription[screenNumberKey],
           let rid = (id as? NSNumber)?.uint32Value {
            return String(rid)
        }
        // fallback: 使用 frame 作为标识
        return "\(frame.origin.x)-\(frame.origin.y)"
    }

    /// 屏幕显示名称
    var displayName: String {
        if isBuiltinDisplay {
            return "Built-in Display"
        }

        // 尝试获取显示器名称
        let nameKey = NSDeviceDescriptionKey(rawValue: "NSDisplayName")
        if let name = deviceDescription[nameKey] as? String, !name.isEmpty {
            return name
        }

        // 使用屏幕序号
        let index = NSScreen.screens.firstIndex { $0.screenId == self.screenId } ?? 0
        return "Display \(index + 1)"
    }

    /// 根据 ID 查找屏幕
    static func byId(_ id: String) -> NSScreen? {
        if id == "builtin" {
            return builtin
        }
        return screens.first { $0.screenId == id }
    }
}
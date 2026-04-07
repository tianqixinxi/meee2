import Cocoa

/// 灵动岛窗口 - 自定义窗口类
/// 确保窗口正确显示在最顶层
public class DynamicIslandWindow: NSWindow {
    public override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        setupWindow()
    }

    private func setupWindow() {
        // 窗口属性设置
        isOpaque = false
        alphaValue = 1
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = NSColor.clear
        isMovable = false

        // 关键：设置窗口层级和集合行为
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]

        // 使用 statusBar + 8 确保在状态栏之上
        level = .statusBar + 8

        hasShadow = false
        hidesOnDeactivate = false

        // 设置深色外观，确保滚动条样式匹配
        appearance = NSAppearance(named: .darkAqua)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    /// 阻止 NSHostingView 触发窗口 resize，避免约束循环崩溃
    public override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
        // 只允许初始化和显式调用（positionIslandWindow），忽略 SwiftUI 自动 resize
        if frameRect.size == self.frame.size || self.frame.size == .zero {
            super.setFrame(frameRect, display: displayFlag)
        }
    }
}
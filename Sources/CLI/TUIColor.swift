import Foundation

// 旧 Sources/TUI/Colors.swift 里 ListCommand 真正用到的最小子集。
// 其他色键 / Chtype attr / curses 互通函数都跟着 TUI 一起排除编译了。
public enum TUIColor {
    public static let reset = "\u{1B}[0m"
    public static let bold = "\u{1B}[1m"
    public static let dim = "\u{1B}[2m"

    public static let cyan = "\u{1B}[36m"
    public static let yellow = "\u{1B}[33m"
    public static let green = "\u{1B}[32m"
    public static let red = "\u{1B}[31m"
}

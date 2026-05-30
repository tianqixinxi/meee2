import Cocoa
import Combine
import Carbon
import SwiftUI

private let quickOpenHotKeySignature = OSType(0x514F504E)
private let quickOpenHotKeyID = UInt32(1)

public struct QuickOpenShortcut: RawRepresentable, Equatable, Identifiable {
    public static let defaultsKey = "quickOpenShortcut"
    public static let didChangeNotification = Notification.Name("meee2.quickOpenShortcutChanged")
    public static let disabledRawValue = "disabled"
    public static let defaultRawValue = "cmd+option+KeyP"

    public var id: String { rawValue }
    public let rawValue: String

    private static var detectedConflictWarning: String?

    public init?(rawValue: String) {
        let normalized = Self.normalizedRawValue(rawValue)
        guard normalized == Self.disabledRawValue || Self.parse(normalized) != nil else { return nil }
        self.rawValue = normalized
    }

    public var displayName: String {
        guard let parsed = parsed else { return "Disabled" }
        let modifiers = parsed.modifiers.map(\.displayName).joined(separator: "+")
        return "\(modifiers)+\(parsed.key.displayName)"
    }

    public var menuDisplayName: String {
        guard let parsed = parsed else { return "Disabled" }
        let modifiers = parsed.modifiers.map(\.glyph).joined()
        return "\(modifiers)\(parsed.key.displayName)"
    }

    public var keyEquivalent: String {
        parsed?.key.menuKeyEquivalent ?? ""
    }

    public var modifierMask: NSEvent.ModifierFlags {
        parsed?.modifierMask ?? []
    }

    public var isDisabled: Bool {
        parsed == nil
    }

    var carbonKeyCode: UInt32? {
        guard let keyCode = parsed?.key.carbonKeyCode else { return nil }
        return UInt32(keyCode)
    }

    var carbonModifiers: UInt32 {
        parsed?.carbonModifiers ?? 0
    }

    private var parsed: ParsedShortcut? {
        Self.parse(rawValue)
    }

    public static var current: QuickOpenShortcut {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultRawValue
            return QuickOpenShortcut(rawValue: raw) ?? QuickOpenShortcut(rawValue: defaultRawValue)!
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    public static var currentConflictWarning: String? {
        detectedConflictWarning
    }

    public static func setCurrentConflictWarning(_ warning: String?) {
        detectedConflictWarning = warning
    }

    public static func conflictWarning(for shortcut: QuickOpenShortcut) -> String? {
        guard !shortcut.isDisabled,
              let keyCode = shortcut.carbonKeyCode else { return nil }
        var probeRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: quickOpenHotKeySignature, id: UInt32.max),
            GetApplicationEventTarget(),
            OptionBits(0),
            &probeRef
        )
        if let probeRef {
            UnregisterEventHotKey(probeRef)
        }
        guard status != noErr else { return nil }
        return "This shortcut appears to be used by macOS or another app."
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let parsed else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        return modifiers == parsed.modifierMask && Int(event.keyCode) == parsed.key.carbonKeyCode
    }

    private static func normalizedRawValue(_ raw: String) -> String {
        switch raw {
        case "commandOptionP": return "cmd+option+KeyP"
        case "commandShiftP": return "cmd+shift+KeyP"
        case "commandOptionK": return "cmd+option+KeyK"
        case "commandShiftO": return "cmd+shift+KeyO"
        default:
            return raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "command", with: "cmd")
                .replacingOccurrences(of: "alt", with: "option")
        }
    }

    private static func parse(_ rawValue: String) -> ParsedShortcut? {
        guard rawValue != disabledRawValue else { return nil }
        let parts = rawValue.split(separator: "+").map(String.init)
        guard parts.count >= 2,
              let keyPart = parts.last,
              let key = ShortcutKey(code: keyPart) else { return nil }
        let modifiers = parts.dropLast().compactMap(ShortcutModifier.init(rawValue:))
        guard modifiers.count == parts.count - 1,
              modifiers.contains(where: { $0 != .shift }) else { return nil }
        return ParsedShortcut(
            modifiers: Array(modifiers).sorted { $0.sortOrder < $1.sortOrder },
            key: key
        )
    }

    private struct ParsedShortcut {
        let modifiers: [ShortcutModifier]
        let key: ShortcutKey

        var modifierMask: NSEvent.ModifierFlags {
            modifiers.reduce(into: NSEvent.ModifierFlags()) { result, modifier in
                result.insert(modifier.eventFlag)
            }
        }

        var carbonModifiers: UInt32 {
            modifiers.reduce(UInt32(0)) { result, modifier in
                result | modifier.carbonFlag
            }
        }
    }

    private enum ShortcutModifier: String {
        case command = "cmd"
        case option
        case control
        case shift

        var sortOrder: Int {
            switch self {
            case .control: return 0
            case .option: return 1
            case .shift: return 2
            case .command: return 3
            }
        }

        var displayName: String {
            switch self {
            case .command: return "Cmd"
            case .option: return "Option"
            case .control: return "Control"
            case .shift: return "Shift"
            }
        }

        var glyph: String {
            switch self {
            case .command: return "⌘"
            case .option: return "⌥"
            case .control: return "⌃"
            case .shift: return "⇧"
            }
        }

        var eventFlag: NSEvent.ModifierFlags {
            switch self {
            case .command: return .command
            case .option: return .option
            case .control: return .control
            case .shift: return .shift
            }
        }

        var carbonFlag: UInt32 {
            switch self {
            case .command: return UInt32(cmdKey)
            case .option: return UInt32(optionKey)
            case .control: return UInt32(controlKey)
            case .shift: return UInt32(shiftKey)
            }
        }
    }

    private struct ShortcutKey {
        let code: String
        let displayName: String
        let carbonKeyCode: Int
        let menuKeyEquivalent: String

        init?(code: String) {
            guard let value = Self.keyMap[code] else { return nil }
            self.code = code
            self.displayName = value.display
            self.carbonKeyCode = value.keyCode
            self.menuKeyEquivalent = value.menu
        }

        static let keyMap: [String: (display: String, keyCode: Int, menu: String)] = [
            "KeyA": ("A", 0x00, "a"), "KeyS": ("S", 0x01, "s"),
            "KeyD": ("D", 0x02, "d"), "KeyF": ("F", 0x03, "f"),
            "KeyH": ("H", 0x04, "h"), "KeyG": ("G", 0x05, "g"),
            "KeyZ": ("Z", 0x06, "z"), "KeyX": ("X", 0x07, "x"),
            "KeyC": ("C", 0x08, "c"), "KeyV": ("V", 0x09, "v"),
            "KeyB": ("B", 0x0B, "b"), "KeyQ": ("Q", 0x0C, "q"),
            "KeyW": ("W", 0x0D, "w"), "KeyE": ("E", 0x0E, "e"),
            "KeyR": ("R", 0x0F, "r"), "KeyY": ("Y", 0x10, "y"),
            "KeyT": ("T", 0x11, "t"), "Digit1": ("1", 0x12, "1"),
            "Digit2": ("2", 0x13, "2"), "Digit3": ("3", 0x14, "3"),
            "Digit4": ("4", 0x15, "4"), "Digit6": ("6", 0x16, "6"),
            "Digit5": ("5", 0x17, "5"), "Equal": ("=", 0x18, "="),
            "Digit9": ("9", 0x19, "9"), "Digit7": ("7", 0x1A, "7"),
            "Minus": ("-", 0x1B, "-"), "Digit8": ("8", 0x1C, "8"),
            "Digit0": ("0", 0x1D, "0"), "BracketRight": ("]", 0x1E, "]"),
            "KeyO": ("O", 0x1F, "o"), "KeyU": ("U", 0x20, "u"),
            "BracketLeft": ("[", 0x21, "["), "KeyI": ("I", 0x22, "i"),
            "KeyP": ("P", 0x23, "p"), "KeyL": ("L", 0x25, "l"),
            "KeyJ": ("J", 0x26, "j"), "Quote": ("'", 0x27, "'"),
            "KeyK": ("K", 0x28, "k"), "Semicolon": (";", 0x29, ";"),
            "Backslash": ("\\", 0x2A, "\\"), "Comma": (",", 0x2B, ","),
            "Slash": ("/", 0x2C, "/"), "KeyN": ("N", 0x2D, "n"),
            "KeyM": ("M", 0x2E, "m"), "Period": (".", 0x2F, "."),
            "Tab": ("Tab", 0x30, "\t"), "Space": ("Space", 0x31, " "),
            "Backquote": ("`", 0x32, "`"), "Backspace": ("Delete", 0x33, "\u{8}"),
            "Escape": ("Esc", 0x35, "\u{1B}"), "Enter": ("Return", 0x24, "\r"),
            "ArrowLeft": ("Left", 0x7B, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))),
            "ArrowRight": ("Right", 0x7C, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))),
            "ArrowDown": ("Down", 0x7D, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))),
            "ArrowUp": ("Up", 0x7E, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        ]
    }
}

private func quickOpenHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var eventHotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &eventHotKeyID
    )
    guard status == noErr,
          eventHotKeyID.signature == quickOpenHotKeySignature,
          eventHotKeyID.id == quickOpenHotKeyID else {
        return OSStatus(eventNotHandledErr)
    }
    Task { @MainActor in
        SessionPaletteManager.shared.toggle()
    }
    return noErr
}

// MARK: - Session Palette Manager

/// Quick Open 窗口生命周期管理器。
@MainActor
public final class SessionPaletteManager: ObservableObject {
    public static let shared = SessionPaletteManager()

    @Published public var isVisible: Bool = false

    private var paletteWindow: SessionPaletteWindow?
    private var hotKeyMonitor: Any?
    private var globalHotKeyRef: EventHotKeyRef?
    private var globalHotKeyHandlerRef: EventHandlerRef?
    private var shortcutObserver: NSObjectProtocol?

    // 搜索状态
    let searchEngine = SessionPaletteSearchEngine()

    private init() {
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: QuickOpenShortcut.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshHotKeyRegistration()
            }
        }
    }

    // MARK: - Lifecycle

    /// 显示 palette 窗口
    public func show() {
        if paletteWindow == nil {
            let window = SessionPaletteWindow()
            window.onDidHide = { [weak self] in
                self?.isVisible = false
            }
            paletteWindow = window
        }

        guard let window = paletteWindow else { return }

        // 定位到屏幕中央偏上
        if let screen = NSScreen.main {
            let width: CGFloat = 680
            let height: CGFloat = 420
            let x = screen.frame.midX - width / 2
            let y = screen.frame.maxY - 200 - height
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: true)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isVisible = true
    }

    /// 隐藏 palette 窗口
    public func hide() {
        paletteWindow?.orderOut(nil)
        isVisible = false
    }

    /// 切换显示状态
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// 注册 Quick Open 快捷键。全局 hot key 负责后台唤起，本地 monitor 覆盖菜单焦点内触发。
    public func registerHotKey() {
        installGlobalHotKeyHandlerIfNeeded()
        refreshHotKeyRegistration()
        if hotKeyMonitor == nil {
            hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if QuickOpenShortcut.current.matches(event) {
                    self?.toggle()
                    return nil
                }
                return event
            }
        }
    }

    public func refreshHotKeyRegistration() {
        unregisterGlobalHotKey()
        let shortcut = QuickOpenShortcut.current
        guard !shortcut.isDisabled,
              let keyCode = shortcut.carbonKeyCode else {
            QuickOpenShortcut.setCurrentConflictWarning(nil)
            return
        }

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: quickOpenHotKeySignature, id: quickOpenHotKeyID),
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            globalHotKeyRef = hotKeyRef
            QuickOpenShortcut.setCurrentConflictWarning(nil)
        } else {
            QuickOpenShortcut.setCurrentConflictWarning("This shortcut appears to be used by macOS or another app.")
        }
    }

    private func installGlobalHotKeyHandlerIfNeeded() {
        guard globalHotKeyHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            quickOpenHotKeyHandler,
            1,
            &eventType,
            nil,
            &globalHotKeyHandlerRef
        )
    }

    private func unregisterGlobalHotKey() {
        if let globalHotKeyRef {
            UnregisterEventHotKey(globalHotKeyRef)
            self.globalHotKeyRef = nil
        }
    }

    // MARK: - Session selection

    /// 选择并跳转到某个 session
    func selectAndJump(to entry: SessionPaletteEntry) {
        hide()
        switch entry.kind {
        case .session:
            if entry.terminalKind == "external",
               let session = PluginManager.shared.sessions.first(where: { $0.id == entry.sessionId }) {
                PluginManager.shared.activateTerminal(for: session)
            } else {
                selectSessionOnBoard(sessionId: entry.sessionId, surfaceId: entry.surfaceId)
            }
        case .canvas:
            openPlannerItem(canvasId: entry.canvasId, nodeId: nil, artifactId: nil)
        case .artifact:
            openPlannerItem(canvasId: entry.canvasId, nodeId: entry.nodeId, artifactId: entry.artifactId)
        }
    }

    private func selectSessionOnBoard(sessionId: String, surfaceId: String?) {
        // 复用 AppDelegate → BoardWebWindowController 的 session 深链入口。
        var userInfo: [String: Any] = ["sessionId": sessionId]
        if let surfaceId, !surfaceId.isEmpty {
            userInfo["surfaceId"] = surfaceId
        }
        NotificationCenter.default.post(
            name: Notification.Name("meee2.openBoardSession"),
            object: nil,
            userInfo: userInfo
        )
    }

    private func openPlannerItem(canvasId: String?, nodeId: String?, artifactId: String?) {
        guard let canvasId, !canvasId.isEmpty else { return }
        var userInfo: [String: Any] = ["canvasId": canvasId]
        if let nodeId, !nodeId.isEmpty {
            userInfo["nodeId"] = nodeId
        }
        if let artifactId, !artifactId.isEmpty {
            userInfo["artifactId"] = artifactId
        }
        NotificationCenter.default.post(
            name: Notification.Name("meee2.openPlannerItem"),
            object: nil,
            userInfo: userInfo
        )
    }

}

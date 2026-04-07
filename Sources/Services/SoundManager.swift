import Foundation
import AVFoundation
import AppKit

/// 音效事件类型
public enum SoundEvent: String, Codable, CaseIterable {
    case sessionStart = "SessionStart"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    case error = "Error"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"

    /// 是否默认启用
    public var defaultEnabled: Bool {
        switch self {
        case .permissionRequest, .stop, .error:
            return true
        default:
            return false
        }
    }

    /// 显示名称
    public var displayName: String {
        switch self {
        case .sessionStart: return "Session Start"
        case .permissionRequest: return "Permission Request"
        case .notification: return "Notification"
        case .stop: return "Task Complete"
        case .sessionEnd: return "Session End"
        case .error: return "Error"
        case .userPromptSubmit: return "Prompt Submitted"
        case .preToolUse: return "Tool Preparing"
        case .postToolUse: return "Tool Complete"
        }
    }

    /// 系统音效名称
    public var systemSoundName: NSSound.Name {
        switch self {
        case .permissionRequest:
            return .init("Submarine")  // 提醒音
        case .stop:
            return .init("Hero")       // 成功音
        case .error:
            return .init("Sosumi")     // 错误音
        case .sessionStart:
            return .init("Purr")       // 开始音
        case .sessionEnd:
            return .init("Glass")      // 结束音
        case .notification:
            return .init("Pop")        // 通知音
        case .userPromptSubmit:
            return .init("Frog")       // 提交音
        case .preToolUse:
            return .init("Pop")        // 准备音
        case .postToolUse:
            return .init("Pop")        // 完成音
        }
    }
}

/// 音效管理器 - 管理 8-bit 风格的事件音效
public class SoundManager: ObservableObject {
    public static let shared = SoundManager()

    // MARK: - Published Properties

    /// 是否启用音效
    @Published public var soundEnabled: Bool = true {
        didSet { saveSettings() }
    }

    /// 全局音量 (0.0 - 1.0)
    @Published public var volume: Float = 0.5 {
        didSet { saveSettings() }
    }

    /// 各事件音效启用状态
    @Published public var eventSounds: [SoundEvent: Bool] = [:] {
        didSet { saveSettings() }
    }

    // MARK: - Private Properties

    private let defaults = UserDefaults.standard

    // MARK: - Initialization

    private init() {
        loadSettings()
    }

    // MARK: - Public Methods

    /// 播放指定事件的音效
    public func play(event: SoundEvent) {
        guard soundEnabled else { return }
        guard eventSounds[event] ?? event.defaultEnabled else { return }

        // 在后台线程播放音效，避免阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.playSound(named: event.systemSoundName)
        }
    }

    /// 播放指定名称的系统音效
    public func playSound(named name: NSSound.Name) {
        guard let sound = NSSound(named: name) else {
            NSLog("[SoundManager] Sound not found: \(name)")
            return
        }

        sound.volume = volume
        sound.play()
        NSLog("[SoundManager] Playing sound: \(name) at volume \(volume)")
    }

    /// 测试音效（用于设置界面预览）
    public func testSound(for event: SoundEvent) {
        let originalEnabled = eventSounds[event]
        eventSounds[event] = true
        play(event: event)
        eventSounds[event] = originalEnabled
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        // 加载全局开关
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true

        // 加载音量
        volume = defaults.object(forKey: "soundVolume") as? Float ?? 0.5

        // 加载各事件启用状态
        for event in SoundEvent.allCases {
            let key = "sound_\(event.rawValue)"
            if let saved = defaults.object(forKey: key) as? Bool {
                eventSounds[event] = saved
            } else {
                eventSounds[event] = event.defaultEnabled
            }
        }

        NSLog("[SoundManager] Loaded settings: enabled=\(soundEnabled), volume=\(volume)")
    }

    private func saveSettings() {
        defaults.set(soundEnabled, forKey: "soundEnabled")
        defaults.set(volume, forKey: "soundVolume")

        for (event, enabled) in eventSounds {
            defaults.set(enabled, forKey: "sound_\(event.rawValue)")
        }
    }

    /// 重置为默认设置
    public func resetToDefaults() {
        soundEnabled = true
        volume = 0.5
        for event in SoundEvent.allCases {
            eventSounds[event] = event.defaultEnabled
        }
        saveSettings()
    }
}// test comment

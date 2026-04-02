import Foundation
import SwiftUI
import PeerPluginKit

/// 动态 Plugin 加载器 - 使用 dlopen 加载 .dylib 文件
class DynamicPluginLoader {
    // MARK: - Types

    /// Plugin 工厂函数类型
    typealias PluginCreateFunction = @convention(c) () -> UnsafeMutableRawPointer

    /// Plugin 销毁函数类型
    typealias PluginDestroyFunction = @convention(c) (UnsafeMutableRawPointer) -> Void

    // MARK: - Properties

    /// 已加载的动态库句柄
    private var loadedHandles: [String: UnsafeMutableRawPointer] = [:]

    /// Plugin 目录
    private let pluginDirectory: URL

    // MARK: - Init

    init() {
        let home = NSHomeDirectory()
        pluginDirectory = URL(fileURLWithPath: home)
            .appendingPathComponent(".peer-island")
            .appendingPathComponent("plugins")
    }

    // MARK: - Public

    /// 扫描并加载所有外部 Plugin
    func loadAllPlugins() -> [SessionPlugin] {
        var plugins: [SessionPlugin] = []

        // 预加载 PeerPluginKit，确保所有 plugins 使用同一个类定义
        preloadPeerPluginKit()

        // 确保目录存在
        try? FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)

        // 遍历子目录
        guard let enumerator = FileManager.default.enumerator(
            at: pluginDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return plugins
        }

        for case let fileURL as URL in enumerator {
            // 查找 plugin.json
            if fileURL.lastPathComponent == "plugin.json" {
                let pluginDir = fileURL.deletingLastPathComponent()
                if let plugin = loadPlugin(from: pluginDir) {
                    plugins.append(plugin)
                }
            }
        }

        NSLog("[DynamicPluginLoader] Loaded \(plugins.count) external plugins")
        return plugins
    }

    /// 卸载所有 Plugin
    func unloadAllPlugins() {
        for (path, handle) in loadedHandles {
            dlclose(handle)
            NSLog("[DynamicPluginLoader] Unloaded: \(path)")
        }
        loadedHandles.removeAll()
    }

    // MARK: - Private

    /// 预加载 PeerPluginKit 动态库
    /// 确保所有 plugins 使用同一个 SessionPlugin 类定义
    private func preloadPeerPluginKit() {
        let home = NSHomeDirectory()
        let libPath = URL(fileURLWithPath: home)
            .appendingPathComponent(".peer-island")
            .appendingPathComponent("lib")
            .appendingPathComponent("libPeerPluginKit.dylib")

        guard FileManager.default.fileExists(atPath: libPath.path) else {
            NSLog("[DynamicPluginLoader] PeerPluginKit not found at: \(libPath.path)")
            return
        }

        // 使用 RTLD_GLOBAL 让符号对后续加载的 plugins 可见
        guard dlopen(libPath.path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            let error = String(cString: dlerror())
            NSLog("[DynamicPluginLoader] Failed to preload PeerPluginKit: \(error)")
            return
        }

        NSLog("[DynamicPluginLoader] Preloaded PeerPluginKit from: \(libPath.path)")
    }

    private func loadPlugin(from directory: URL) -> SessionPlugin? {
        // 1. 读取 plugin.json
        let configFile = directory.appendingPathComponent("plugin.json")

        guard let configData = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(PluginMetadata.self, from: configData) else {
            NSLog("[DynamicPluginLoader] Failed to load plugin.json from: \(directory.path)")
            return nil
        }

        // 2. 加载动态库
        let dylibPath = directory.appendingPathComponent(config.dylib).path

        guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            NSLog("[DynamicPluginLoader] Failed to load \(dylibPath): \(error)")
            return nil
        }

        loadedHandles[dylibPath] = handle

        // 3. 获取创建函数
        guard let createSymbol = dlsym(handle, "createPlugin") else {
            NSLog("[DynamicPluginLoader] createPlugin symbol not found in \(dylibPath)")
            return nil
        }

        let createFunc = unsafeBitCast(createSymbol, to: PluginCreateFunction.self)

        // 4. 创建 Plugin 实例
        let pluginPtr = createFunc()

        // 将指针转换为 AnyObject，然后检查是否符合 SessionPlugin
        let pluginObject = Unmanaged<AnyObject>.fromOpaque(pluginPtr).takeUnretainedValue()

        guard let plugin = pluginObject as? SessionPlugin else {
            NSLog("[DynamicPluginLoader] Loaded object does not conform to SessionPlugin: \(dylibPath)")
            return nil
        }

        NSLog("[DynamicPluginLoader] Loaded plugin: \(config.id)")
        return plugin
    }
}

// MARK: - Plugin Metadata

/// Plugin 元数据（从 plugin.json 解析）
struct PluginMetadata: Codable {
    let id: String
    let name: String
    let version: String
    let icon: String
    let color: String
    let dylib: String
    let settings: [PluginSettingDefinition]?
    let helpUrl: String?
}

/// Plugin 设置定义
struct PluginSettingDefinition: Codable {
    let key: String
    let type: String  // "slider", "toggle", "text"
    let min: Double?
    let max: Double?
    let `default`: CodableValue?
    let label: String?
}

/// 可编码的值（用于 JSON 解析）
struct CodableValue: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let doubleValue = value as? Double {
            try container.encode(doubleValue)
        } else if let stringValue = value as? String {
            try container.encode(stringValue)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue)
        }
    }
}

// MARK: - Plugin Metadata
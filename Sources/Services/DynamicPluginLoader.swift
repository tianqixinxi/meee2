import Foundation
import SwiftUI
import Meee2PluginKit

/// 动态 Plugin 加载器 - 使用 dlopen 加载 .dylib 文件
public class DynamicPluginLoader {
    // MARK: - Types

    /// Plugin 工厂函数类型
    typealias PluginCreateFunction = @convention(c) () -> UnsafeMutableRawPointer

    /// Plugin 销毁函数类型
    typealias PluginDestroyFunction = @convention(c) (UnsafeMutableRawPointer) -> Void

    /// 加载失败的插件信息
    public struct FailedPlugin: Identifiable {
        public let id: String
        public let name: String
        public let version: String
        public let dylibPath: String
        public let error: String
        public let isCompatibilityError: Bool  // 是否为 ABI 不兼容错误

        public var helpUrl: String?
    }

    // MARK: - Properties

    /// 已加载的动态库句柄
    private var loadedHandles: [String: UnsafeMutableRawPointer] = [:]

    /// 加载失败的插件列表
    public private(set) var failedPlugins: [FailedPlugin] = []

    /// Plugin 目录
    private let pluginDirectory: URL

    // MARK: - Init

    init() {
        let home = NSHomeDirectory()
        pluginDirectory = URL(fileURLWithPath: home)
            .appendingPathComponent(".meee2")
            .appendingPathComponent("plugins")
    }

    // MARK: - Public

    /// 扫描并加载所有外部 Plugin
    public func loadAllPlugins() -> [SessionPlugin] {
        var plugins: [SessionPlugin] = []

        // 清空上次失败的列表
        failedPlugins = []

        // 预加载 Meee2PluginKit，确保所有 plugins 使用同一个类定义
        preloadMeee2PluginKit()

        // 安装内置插件（从 app bundle 复制到 ~/.meee2/plugins/）
        installBuiltinPlugins()

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

        MLog("[DynamicPluginLoader] Loaded \(plugins.count) external plugins, \(failedPlugins.count) failed")
        return plugins
    }

    /// 安装内置插件（从 app bundle 复制）
    private func installBuiltinPlugins() {
        guard let bundlePluginsDir = Bundle.main.resourceURL?.appendingPathComponent("Plugins") else {
            return
        }

        guard FileManager.default.fileExists(atPath: bundlePluginsDir.path) else {
            return
        }

        // 遍历 app bundle 中的插件目录
        guard let pluginDirs = try? FileManager.default.contentsOfDirectory(
            at: bundlePluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let pluginName = pluginDir.lastPathComponent
            let destDir = pluginDirectory.appendingPathComponent(pluginName)

            // 确保目标目录存在
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            // 复制插件目录中的所有文件（覆盖已存在的）
            if let files = try? FileManager.default.contentsOfDirectory(
                at: pluginDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for file in files {
                    let destFile = destDir.appendingPathComponent(file.lastPathComponent)
                    // 先删除已存在的文件
                    try? FileManager.default.removeItem(at: destFile)
                    // 复制新文件
                    try? FileManager.default.copyItem(at: file, to: destFile)
                }
                MLog("[DynamicPluginLoader] Installed builtin plugin: \(pluginName)")
            }
        }
    }

    /// 卸载所有 Plugin
    func unloadAllPlugins() {
        for (path, handle) in loadedHandles {
            dlclose(handle)
            MLog("[DynamicPluginLoader] Unloaded: \(path)")
        }
        loadedHandles.removeAll()
    }

    // MARK: - Private

    /// 预加载 Meee2PluginKit 动态库
    /// 确保所有 plugins 使用同一个 SessionPlugin 类定义
    private func preloadMeee2PluginKit() {
        // 先检查 SessionPlugin 符号是否已存在（说明库已加载）
        // nil 表示搜索所有已加载的库
        let symbolName = "_$s14Meee2PluginKit13SessionPluginCMm"  // Swift mangled name for SessionPlugin class metadata
        if dlsym(nil, symbolName) != nil {
            MInfo("[DynamicPluginLoader] Meee2PluginKit already loaded (SessionPlugin symbol found), skip dlopen")
            return
        }

        // 清除之前的 dlerror
        dlerror()

        let home = NSHomeDirectory()
        let libDir = URL(fileURLWithPath: home)
            .appendingPathComponent(".meee2")
            .appendingPathComponent("lib")
        let libPath = libDir.appendingPathComponent("libMeee2PluginKit.dylib")

        // 尝试从 app bundle 复制 dylib
        let bundlePath = Bundle.main.resourceURL?.appendingPathComponent("Frameworks/libMeee2PluginKit.dylib")
        if let bundlePath = bundlePath, FileManager.default.fileExists(atPath: bundlePath.path) {
            let needsUpdate = !FileManager.default.fileExists(atPath: libPath.path) ||
                              shouldUpdateLibrary(bundlePath: bundlePath, installedPath: libPath)

            if needsUpdate {
                try? FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: libPath)
                try? FileManager.default.copyItem(at: bundlePath, to: libPath)
                MInfo("[DynamicPluginLoader] Updated Meee2PluginKit from app bundle to: \(libPath.path)")
            }
        }

        // 加载库
        guard FileManager.default.fileExists(atPath: libPath.path) else {
            MWarn("[DynamicPluginLoader] Meee2PluginKit not found at: \(libPath.path)")
            return
        }

        guard dlopen(libPath.path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            let error = String(cString: dlerror())
            MError("[DynamicPluginLoader] Failed to preload Meee2PluginKit: \(error)")
            return
        }

        MInfo("[DynamicPluginLoader] Preloaded Meee2PluginKit from: \(libPath.path)")
    }

    /// 检查是否需要更新库文件（比较修改时间）
    private func shouldUpdateLibrary(bundlePath: URL, installedPath: URL) -> Bool {
        guard let bundleAttrs = try? FileManager.default.attributesOfItem(atPath: bundlePath.path),
              let installedAttrs = try? FileManager.default.attributesOfItem(atPath: installedPath.path),
              let bundleModDate = bundleAttrs[.modificationDate] as? Date,
              let installedModDate = installedAttrs[.modificationDate] as? Date else {
            // 无法获取属性，保守地更新
            return true
        }

        // 如果 app bundle 中的版本更新，需要更新
        return bundleModDate > installedModDate
    }

    private func loadPlugin(from directory: URL) -> SessionPlugin? {
        // 1. 读取 plugin.json
        let configFile = directory.appendingPathComponent("plugin.json")

        guard let configData = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(PluginMetadata.self, from: configData) else {
            MLog("[DynamicPluginLoader] Failed to load plugin.json from: \(directory.path)")
            return nil
        }

        // 2. 加载动态库
        let dylibPath = directory.appendingPathComponent(config.dylib).path

        guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            MLog("[DynamicPluginLoader] Failed to load \(dylibPath): \(error)")

            // 检测是否为 ABI 不兼容错误（Symbol not found 且包含 Meee2PluginKit）
            let isCompatError = error.contains("Symbol not found") && error.contains("Meee2PluginKit")

            // 构建用户友好的错误消息
            let errorMessage: String
            if isCompatError {
                errorMessage = "This plugin needs to be rebuilt for the current meee2 version. Please check the plugin's documentation for update instructions."
            } else {
                errorMessage = error
            }

            // 记录失败插件
            failedPlugins.append(FailedPlugin(
                id: config.id,
                name: config.name,
                version: config.version,
                dylibPath: dylibPath,
                error: errorMessage,
                isCompatibilityError: isCompatError,
                helpUrl: config.helpUrl
            ))

            return nil
        }

        loadedHandles[dylibPath] = handle

        // 3. 获取创建函数
        guard let createSymbol = dlsym(handle, "createPlugin") else {
            let error = String(cString: dlerror())
            MLog("[DynamicPluginLoader] createPlugin symbol not found in \(dylibPath): \(error)")
            return nil
        }

        let createFunc = unsafeBitCast(createSymbol, to: PluginCreateFunction.self)

        // 4. 创建 Plugin 实例 - 添加保护
        let pluginPtr = createFunc()
        guard pluginPtr != nil else {
            MLog("[DynamicPluginLoader] createPlugin returned nil for \(dylibPath)")
            return nil
        }

        // 将指针转换为 AnyObject，然后检查是否符合 SessionPlugin
        let pluginObject = Unmanaged<AnyObject>.fromOpaque(pluginPtr).takeUnretainedValue()

        guard let plugin = pluginObject as? SessionPlugin else {
            MLog("[DynamicPluginLoader] Loaded object does not conform to SessionPlugin: \(dylibPath)")
            return nil
        }

        MLog("[DynamicPluginLoader] Loaded plugin: \(config.id)")
        return plugin
    }
}

// MARK: - Plugin Metadata

/// Plugin 元数据（从 plugin.json 解析）
struct PluginMetadata: Codable {
    let id: String
    let name: String
    let version: String
    let icon: String?
    let color: String?
    let dylib: String
    let settings: [PluginSettingDefinition]?
    let helpUrl: String?
    /// 最低 PluginKit 版本要求 (可选)
    let minKitVersion: String?
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
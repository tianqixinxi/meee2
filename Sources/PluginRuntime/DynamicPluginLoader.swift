import Foundation
import SwiftUI
import Meee2PluginKit

/// Current Meee2PluginKit ABI version. Bumped whenever the SessionPlugin
/// open class layout changes in a way that breaks dylibs built against the
/// previous SDK (e.g. new `open var widgets` added in island widget plugin
/// commit 48aa4f1 changed the vtable slot count, crashing pre-existing
/// codex / cursor / openclaw dylibs with EXC_BAD_ACCESS at 0x58).
///
/// Plugin authors declare what version they built against in plugin.json:
///   { "abi_version": 2, ... }
/// Plugins missing the field or below this version are recorded as
/// compatibility-failed and SKIPPED at load time — they do NOT progress
/// to dlopen / instantiation, so the live vtable mismatch never executes.
public let CURRENT_PLUGIN_KIT_ABI_VERSION: Int = 2

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

    private struct BuiltinPluginInstallSpec {
        let directoryName: String
        let dylibName: String
        let metadata: String
    }

    private static let builtinPluginSpecs: [BuiltinPluginInstallSpec] = [
        BuiltinPluginInstallSpec(
            directoryName: "cursor",
            dylibName: "CursorPlugin.dylib",
            metadata: """
            {
                "id": "com.meee2.plugin.cursor",
                "name": "Cursor",
                "version": "0.2.0",
                "dylib": "CursorPlugin.dylib",
                "helpUrl": "https://docs.cursor.com/meee2-plugin"
            }
            """
        ),
        BuiltinPluginInstallSpec(
            directoryName: "openclaw",
            dylibName: "OpenClawPlugin.dylib",
            metadata: """
            {
                "id": "com.meee2.plugin.openclaw",
                "name": "OpenClaw",
                "version": "0.2.0",
                "dylib": "OpenClawPlugin.dylib"
            }
            """
        ),
        BuiltinPluginInstallSpec(
            directoryName: "codex",
            dylibName: "CodexPlugin.dylib",
            metadata: """
            {
                "id": "com.meee2.plugin.codex",
                "name": "Codex",
                "version": "0.2.0",
                "dylib": "CodexPlugin.dylib",
                "helpUrl": "https://github.com/openai/codex"
            }
            """
        )
    ]

    // MARK: - Init

    init() {
        pluginDirectory = MEEE2Env.pluginsDir
    }

    // MARK: - Public

    /// 扫描并加载所有外部 Plugin
    public func loadAllPlugins() -> [SessionPlugin] {
        var plugins: [SessionPlugin] = []

        // 清空上次失败的列表
        failedPlugins = []

        // 预加载 Meee2PluginKit，确保所有 plugins 使用同一个类定义
        preloadMeee2PluginKit()

        // 安装内置插件（从 app bundle / SwiftPM build products 复制到 ~/.meee2/plugins/）
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
        installBundlePlugins()
        installSwiftPMBuiltins()
    }

    private func installBundlePlugins() {
        guard let bundlePluginsDir = Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
              FileManager.default.fileExists(atPath: bundlePluginsDir.path),
              let pluginDirs = try? FileManager.default.contentsOfDirectory(
                  at: bundlePluginsDir,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let pluginName = pluginDir.lastPathComponent
            let destDir = pluginDirectory.appendingPathComponent(pluginName)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: pluginDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files {
                copyIfNewer(source: file, destination: destDir.appendingPathComponent(file.lastPathComponent))
            }
            MLog("[DynamicPluginLoader] Installed builtin plugin: \(pluginName)")
        }
    }

    /// SwiftPM runs from `.build/.../{debug,release}` and has no bundled
    /// `Plugins/` resource directory. Keep the installed builtin plugin dylibs
    /// in sync so `swift run` does not load stale copies from `~/.meee2/plugins`.
    private func installSwiftPMBuiltins() {
        guard let productsDir = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return
        }

        for spec in Self.builtinPluginSpecs {
            let source = productsDir.appendingPathComponent("lib\(spec.dylibName)")
            guard FileManager.default.fileExists(atPath: source.path) else {
                continue
            }

            let destDir = pluginDirectory.appendingPathComponent(spec.directoryName)
            let destDylib = destDir.appendingPathComponent(spec.dylibName)
            let metadataFile = destDir.appendingPathComponent("plugin.json")

            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                copyIfNewer(source: source, destination: destDylib)
                if !FileManager.default.fileExists(atPath: metadataFile.path) {
                    try spec.metadata.write(to: metadataFile, atomically: true, encoding: .utf8)
                }
                MLog("[DynamicPluginLoader] Synced SwiftPM builtin plugin: \(spec.directoryName)")
            } catch {
                MWarn("[DynamicPluginLoader] Failed to sync SwiftPM builtin plugin \(spec.directoryName): \(error)")
            }
        }
    }

    private func copyIfNewer(source: URL, destination: URL) {
        let needsCopy = !FileManager.default.fileExists(atPath: destination.path) ||
            shouldUpdateLibrary(bundlePath: source, installedPath: destination)

        guard needsCopy else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
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
        if NSClassFromString("Meee2PluginKit.SessionPlugin") != nil {
            MInfo("[DynamicPluginLoader] Meee2PluginKit already loaded (SessionPlugin class found), skip dlopen")
            return
        }

        // 清除之前的 dlerror
        dlerror()

        let libDir = MEEE2Env.home.appendingPathComponent("lib", isDirectory: true)
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

        // 1.5 ABI 版本硬隔离 —— Plugin 必须声明用什么 ABI 版本 build 的,
        // 不匹配就拒绝(不走 dlopen,不走 vtable lookup,从根上避免老 dylib 跟新
        // SessionPlugin 类布局错位导致的 EXC_BAD_ACCESS)。
        let declaredABI = config.abi_version ?? 0
        let dylibPath = directory.appendingPathComponent(config.dylib).path
        if declaredABI < CURRENT_PLUGIN_KIT_ABI_VERSION {
            let msg = "Plugin built for ABI \(declaredABI) but meee2 needs ABI " +
                      "\(CURRENT_PLUGIN_KIT_ABI_VERSION). Rebuild the plugin against the current SDK " +
                      "and bump `abi_version` in plugin.json."
            MWarn("[DynamicPluginLoader] Rejecting \(config.id): \(msg)")
            failedPlugins.append(FailedPlugin(
                id: config.id,
                name: config.name,
                version: config.version,
                dylibPath: dylibPath,
                error: msg,
                isCompatibilityError: true,
                helpUrl: config.helpUrl
            ))
            return nil
        }

        // 2. 加载动态库

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
        // pluginPtr 是 non-optional，检查指针是否有效
        guard pluginPtr != UnsafeMutableRawPointer(bitPattern: 0) else {
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
    /// 最低 PluginKit 版本要求 (可选,目前未启用 — 用 abi_version 做硬隔离)
    let minKitVersion: String?
    /// Plugin 编译时基于的 Meee2PluginKit ABI 版本。
    /// 缺省 → 视为 0,跟 `CURRENT_PLUGIN_KIT_ABI_VERSION` 比较失败 → reject。
    /// Plugin 作者必须在重 build 后把这个数字调到当前。
    let abi_version: Int?
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

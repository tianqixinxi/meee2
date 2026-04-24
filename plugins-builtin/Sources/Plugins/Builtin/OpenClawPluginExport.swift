import Foundation
import Meee2PluginKit

/// Plugin 导出函数
/// DynamicPluginLoader 通过 dlsym 查找 createPlugin 函数来创建 Plugin 实例

@_cdecl("createPlugin")
public func createOpenClawPlugin() -> UnsafeMutableRawPointer {
    let plugin = OpenClawPlugin()
    return Unmanaged.passRetained(plugin).toOpaque()
}

@_cdecl("destroyPlugin")
public func destroyOpenClawPlugin(_ ptr: UnsafeMutableRawPointer) {
    Unmanaged<OpenClawPlugin>.fromOpaque(ptr).release()
}

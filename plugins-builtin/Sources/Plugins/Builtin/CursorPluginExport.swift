import Foundation
import Meee2PluginKit

/// Plugin 导出函数
/// DynamicPluginLoader 通过 dlsym 查找 createPlugin 函数来创建 Plugin 实例

@_cdecl("createPlugin")
public func createCursorPlugin() -> UnsafeMutableRawPointer {
    let plugin = CursorPlugin()
    return Unmanaged.passRetained(plugin).toOpaque()
}

@_cdecl("destroyPlugin")
public func destroyCursorPlugin(_ ptr: UnsafeMutableRawPointer) {
    Unmanaged<CursorPlugin>.fromOpaque(ptr).release()
}
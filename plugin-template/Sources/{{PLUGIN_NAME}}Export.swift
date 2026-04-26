import Foundation

/// Export the plugin class so it can be dynamically loaded.
/// SwiftPM dynamic libraries need an export function to expose symbols.
@_cdecl("plugin_export")
public func pluginExport() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained({{PLUGIN_NAME}}Plugin()).toOpaque()
}

// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Meee2PluginsBuiltin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CursorPlugin", type: .dynamic, targets: ["CursorPlugin"]),
        .library(name: "OpenClawPlugin", type: .dynamic, targets: ["OpenClawPlugin"]),
    ],
    dependencies: [
        .package(name: "Meee2PluginKit", path: "../meee2-plugin-kit"),
    ],
    targets: [
        .target(
            name: "CursorPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "Sources/Plugins/Builtin",
            sources: ["CursorPlugin.swift", "CursorPluginExport.swift"]
        ),
        .target(
            name: "OpenClawPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "Sources/Plugins/Builtin",
            sources: ["OpenClawPlugin.swift", "OpenClawPluginExport.swift"]
        ),
    ]
)
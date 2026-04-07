// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "meee2",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "meee2", targets: ["meee2App"]),
        .library(name: "meee2Kit", targets: ["meee2Kit"]),
        // Builtin plugins
        .library(name: "CursorPlugin", type: .dynamic, targets: ["CursorPlugin"]),
    ],
    dependencies: [
        .package(name: "Meee2PluginKit", path: "meee2-plugin-kit"),
    ],
    targets: [
        .target(
            name: "meee2Kit",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "Sources"
        ),
        .executableTarget(
            name: "meee2App",
            dependencies: ["meee2Kit", .product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "App",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        // Builtin plugins
        .target(
            name: "CursorPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "plugins-builtin/Sources/Plugins/Builtin",
            sources: ["CursorPlugin.swift", "CursorPluginExport.swift"]
        ),
    ]
)
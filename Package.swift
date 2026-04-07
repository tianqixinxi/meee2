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
        .package(name: "PeerPluginKit", path: "peer-plugin-kit"),
    ],
    targets: [
        .target(
            name: "meee2Kit",
            dependencies: [.product(name: "PeerPluginKit", package: "PeerPluginKit")],
            path: "Sources"
        ),
        .executableTarget(
            name: "meee2App",
            dependencies: ["meee2Kit", .product(name: "PeerPluginKit", package: "PeerPluginKit")],
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
            dependencies: [.product(name: "PeerPluginKit", package: "PeerPluginKit")],
            path: "peer-plugins-builtin/Sources/Plugins/Builtin",
            sources: ["CursorPlugin.swift", "CursorPluginExport.swift"]
        ),
    ]
)

// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PeerPluginsBuiltin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CursorPlugin", type: .dynamic, targets: ["CursorPlugin"]),
    ],
    dependencies: [
        .package(name: "PeerPluginKit", path: "../peer-plugin-kit"),
    ],
    targets: [
        .target(
            name: "CursorPlugin",
            dependencies: [.product(name: "PeerPluginKit", package: "PeerPluginKit")],
            path: "Sources/Plugins/Builtin",
            sources: ["CursorPlugin.swift", "CursorPluginExport.swift"]
        ),
    ]
)

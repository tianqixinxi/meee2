// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PeerIsland",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PeerIsland", targets: ["PeerIslandApp"]),
        .library(name: "PeerIslandKit", targets: ["PeerIslandKit"]),
        // Builtin plugins
        .library(name: "CursorPlugin", type: .dynamic, targets: ["CursorPlugin"]),
    ],
    dependencies: [
        .package(name: "PeerPluginKit", path: "peer-plugin-kit"),
    ],
    targets: [
        .target(
            name: "PeerIslandKit",
            dependencies: [.product(name: "PeerPluginKit", package: "PeerPluginKit")],
            path: "Sources"
        ),
        .executableTarget(
            name: "PeerIslandApp",
            dependencies: ["PeerIslandKit", .product(name: "PeerPluginKit", package: "PeerPluginKit")],
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

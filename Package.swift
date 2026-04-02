// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PeerIsland",
    platforms: [
        .macOS(.v13)  // macOS 13 Ventura for SwiftUI improvements
    ],
    products: [
        .executable(name: "PeerIsland", targets: ["PeerIslandApp"]),
        .library(name: "PeerIslandKit", targets: ["PeerIslandKit"])
    ],
    dependencies: [
        .package(name: "PeerPluginKit", path: "peer-plugin-kit"),
    ],
    targets: [
        // Library target with all code
        .target(
            name: "PeerIslandKit",
            dependencies: [.product(name: "PeerPluginKit", package: "PeerPluginKit")],
            path: "Sources"
        ),
        // Minimal executable target that just runs the app
        .executableTarget(
            name: "PeerIslandApp",
            dependencies: ["PeerIslandKit", .product(name: "PeerPluginKit", package: "PeerPluginKit")],
            path: "App",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)

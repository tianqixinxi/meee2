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
        .library(name: "OpenClawPlugin", type: .dynamic, targets: ["OpenClawPlugin"]),
    ],
    dependencies: [
        .package(name: "Meee2PluginKit", path: "meee2-plugin-kit"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "meee2Kit",
            dependencies: [
                .product(name: "Meee2PluginKit", package: "Meee2PluginKit"),
                .product(name: "Swifter", package: "swifter"),
            ],
            path: "Sources",
            resources: [
                .copy("Board/WebDist"),
            ]
        ),
        .testTarget(
            name: "meee2Tests",
            dependencies: ["meee2Kit"],
            path: "Tests",
            exclude: ["Fixtures"]
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
            exclude: ["OpenClawPlugin.swift", "OpenClawPluginExport.swift"],
            sources: ["CursorPlugin.swift", "CursorPluginExport.swift"]
        ),
        .target(
            name: "OpenClawPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "plugins-builtin/Sources/Plugins/Builtin",
            exclude: ["CursorPlugin.swift", "CursorPluginExport.swift"],
            sources: ["OpenClawPlugin.swift", "OpenClawPluginExport.swift"]
        ),
    ]
)
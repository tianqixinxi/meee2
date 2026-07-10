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
        .library(name: "CodexPlugin", type: .dynamic, targets: ["CodexPlugin"]),
    ],
    dependencies: [
        .package(name: "Meee2PluginKit", path: "meee2-plugin-kit"),
        .package(name: "Meee2CommKit", path: "meee2-comm-kit"),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.1.9"),
        // Sparkle —— Andy Matuschak's auto-update framework. EdDSA-signed
        // appcast feed at SUFeedURL (raw.githubusercontent.com/.../appcast.xml);
        // public key in App/Info.plist's SUPublicEDKey; private key only
        // ever lives in the user's macOS keychain + GitHub Secret
        // SPARKLE_ED_PRIVATE_KEY_BASE64 for CI signing.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(
            name: "meee2Kit",
            dependencies: [
                .product(name: "Meee2PluginKit", package: "Meee2PluginKit"),
                .product(name: "Meee2CommKit", package: "Meee2CommKit"),
                .product(name: "Swifter", package: "swifter"),
            ],
            path: "Sources",
            // ncurses TUI 入口已经从 CLI / 菜单里下掉；整个 TUI/ 目录排除
            // 编译。ListCommand 用的 ANSI 颜色片段保留在 CLI/TUIColor.swift。
            exclude: [
                "TUI",
            ],
            resources: [
                .copy("Board/WebDist"),
                .copy("PluginRuntime/BuiltinManifests"),
            ]
        ),
        .testTarget(
            name: "meee2Tests",
            dependencies: [
                "meee2Kit",
                .product(name: "Swifter", package: "swifter"),
            ],
            path: "Tests",
            exclude: ["Fixtures"]
        ),
        .executableTarget(
            name: "meee2App",
            dependencies: [
                "meee2Kit",
                .product(name: "Meee2PluginKit", package: "Meee2PluginKit"),
                .product(name: "Meee2CommKit", package: "Meee2CommKit"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "App",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit")
            ]
        ),
        // Builtin plugins
        .target(
            name: "CursorPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "plugins-builtin/Sources/Plugins/Builtin",
            exclude: ["OpenClawPlugin.swift", "OpenClawPluginExport.swift", "CodexPlugin.swift", "CodexPluginExport.swift"],
            sources: ["CursorPlugin.swift", "CursorPluginExport.swift"]
        ),
        .target(
            name: "OpenClawPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "plugins-builtin/Sources/Plugins/Builtin",
            exclude: ["CursorPlugin.swift", "CursorPluginExport.swift", "CodexPlugin.swift", "CodexPluginExport.swift"],
            sources: ["OpenClawPlugin.swift", "OpenClawPluginExport.swift"]
        ),
        .target(
            name: "CodexPlugin",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "plugins-builtin/Sources/Plugins/Builtin",
            exclude: ["CursorPlugin.swift", "CursorPluginExport.swift", "OpenClawPlugin.swift", "OpenClawPluginExport.swift"],
            sources: ["CodexPlugin.swift", "CodexPluginExport.swift"]
        ),
    ]
)

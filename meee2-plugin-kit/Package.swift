// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Meee2PluginKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Meee2PluginKit", type: .dynamic, targets: ["Meee2PluginKit"]),
    ],
    targets: [
        .target(
            name: "Meee2PluginKit",
            path: "Sources/Meee2PluginKit"
        ),
    ]
)
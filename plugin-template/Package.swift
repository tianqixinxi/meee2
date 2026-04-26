// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "{{PLUGIN_NAME}}",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "{{PLUGIN_NAME}}", type: .dynamic, targets: ["{{PLUGIN_NAME}}"]),
    ],
    dependencies: [
        // Update this path to point to your meee2 repo
        .package(name: "Meee2PluginKit", path: "../meee2-plugin-kit"),
    ],
    targets: [
        .target(
            name: "{{PLUGIN_NAME}}",
            dependencies: [.product(name: "Meee2PluginKit", package: "Meee2PluginKit")],
            path: "Sources",
            sources: ["{{PLUGIN_NAME}}.swift", "{{PLUGIN_NAME}}Export.swift"]
        ),
    ]
)

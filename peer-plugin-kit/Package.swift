// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PeerPluginKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PeerPluginKit", type: .dynamic, targets: ["PeerPluginKit"]),
    ],
    targets: [
        .target(
            name: "PeerPluginKit",
            path: "Sources/PeerPluginKit"
        ),
    ]
)

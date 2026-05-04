// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Meee2CommKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Meee2CommKit", type: .dynamic, targets: ["Meee2CommKit"]),
    ],
    targets: [
        .target(
            name: "Meee2CommKit",
            path: "Sources/Meee2CommKit"
        ),
    ]
)

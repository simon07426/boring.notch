// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchExtras",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotchExtrasCore", targets: ["NotchExtrasCore"]),
        .executable(name: "boring-fand", targets: ["BoringFand"]),
    ],
    targets: [
        .target(name: "NotchExtrasCore"),
        .executableTarget(name: "BoringFand", dependencies: ["NotchExtrasCore"]),
        .testTarget(name: "NotchExtrasCoreTests", dependencies: ["NotchExtrasCore"]),
    ]
)

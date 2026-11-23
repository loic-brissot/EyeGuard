// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EyeGuard",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "EyeGuardCore",
            targets: ["EyeGuardCore"]
        ),
        .executable(
            name: "EyeGuard",
            targets: ["EyeGuard"]
        ),
    ],
    targets: [
        .target(
            name: "EyeGuardCore",
            dependencies: [],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "EyeGuard",
            dependencies: ["EyeGuardCore"],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "EyeGuardCoreTests",
            dependencies: ["EyeGuardCore"]
        ),
        .testTarget(
            name: "EyeGuardAppTests",
            dependencies: ["EyeGuard"]
        ),
    ]
)

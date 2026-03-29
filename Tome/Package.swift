// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Tome",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tome",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/Tome",
            exclude: ["Info.plist", "Tome.entitlements", "Assets"]
        ),
    ]
)

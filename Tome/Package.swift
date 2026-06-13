// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Tome",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // argmax-oss-swift (formerly WhisperKit), pinned to the merge commit of PR #463,
        // which adds DiarizationResult.speakerCentroidEmbeddings — the official version of
        // the voiceprint centroids (see docs/voiceprints.md). Unreleased as of this pin;
        // re-pin to a tagged release once #463 ships in one.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", revision: "94cf6b120cf9dde32d9dea01acc326e77371302c"),
    ],
    targets: [
        .executableTarget(
            name: "Tome",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/Tome",
            exclude: ["Info.plist", "Tome.entitlements", "Assets"]
        ),
    ]
)

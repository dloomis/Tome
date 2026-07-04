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
        // ObjC shim to catch NSExceptions from AVFoundation (Swift can't) —
        // an NSException unwinding through async frames corrupts the
        // concurrency runtime and crashes later in an unrelated stack.
        .target(
            name: "ObjCExceptionGuard",
            path: "Sources/ObjCExceptionGuard"
        ),
        .executableTarget(
            name: "Tome",
            dependencies: [
                "ObjCExceptionGuard",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/Tome",
            exclude: ["Info.plist", "Tome.entitlements", "Assets"]
        ),
        // Diagnostic/backfill CLI (not part of the app). See Sources/VoiceprintAudit/main.swift.
        .executableTarget(
            name: "VoiceprintAudit",
            dependencies: [
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/VoiceprintAudit"
        ),
    ]
)

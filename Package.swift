// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonoAiBar",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(
            name: "MonoAiBar",
            targets: ["MonoAiBar"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MonoAiBar",
            dependencies: [],
            path: "Sources/MonoAiBar",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny")
            ]
        )
    ]
)

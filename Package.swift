// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Huh",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Huh", targets: ["Huh"])
    ],
    dependencies: [
        // Parakeet TDT on the Apple Neural Engine, plus speaker diarisation.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "Huh",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Huh",
            swiftSettings: [
                // Skeleton uses Swift 5 concurrency checking so AppKit/AVFoundation
                // callbacks don't drown it in Sendable errors. Tighten to .v6 later.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

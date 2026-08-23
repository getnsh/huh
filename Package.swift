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
        // Qwen3 4B for meeting summaries. Optional at runtime, but its Metal
        // kernels mean the project now needs Xcode plus the separately
        // downloaded Metal toolchain to build. See CONTRIBUTING.md.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "Huh",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
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

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RulebookKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // Retrieval, citations and the Apple Foundation Models backend. No third-party dependencies.
        .library(name: "RulebookKit", targets: ["RulebookKit"]),
        // On-device open model (Gemma 4 E4B) via MLX. Kept separate so RulebookKit tests stay fast.
        .library(name: "RulebookMLX", targets: ["RulebookMLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.13.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        .target(
            name: "RulebookKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "RulebookMLX",
            dependencies: [
                "RulebookKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .testTarget(
            name: "RulebookKitTests",
            dependencies: ["RulebookKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

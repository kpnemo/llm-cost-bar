// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LLMCostBarCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LLMCostBarCore", targets: ["LLMCostBarCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(name: "LLMCostBarCore",
                dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LLMCostBarCoreTests", dependencies: ["LLMCostBarCore"]),
    ]
)

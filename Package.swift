// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "yap",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "yap", targets: ["yap"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/tuist/Noora.git", from: "0.40.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.0")),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/groue/Semaphore.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "yap",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Semaphore", package: "Semaphore"),
            ]
        )
    ]
)

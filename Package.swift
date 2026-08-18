// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meister",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MeisterAPI", targets: ["MeisterAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeisterAPI",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/MeisterAPI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MeisterAPITests",
            dependencies: [
                .target(name: "MeisterAPI"),
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)

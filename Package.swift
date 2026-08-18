// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meister",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MeisterAPI", targets: ["MeisterAPI"]),
        .library(name: "MeisterCore", targets: ["MeisterCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CLibArchive",
            path: "Sources/CLibArchive",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("archive"),
            ]
        ),
        .target(
            name: "MeisterCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "CLibArchive",
            ],
            path: "Sources/MeisterCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "MeisterAPI",
            dependencies: [
                .target(name: "MeisterCore"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/MeisterAPI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MeisterCoreTests",
            dependencies: [
                .target(name: "MeisterCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "MeisterAPITests",
            dependencies: [
                .target(name: "MeisterAPI"),
                .target(name: "MeisterCore"),
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)

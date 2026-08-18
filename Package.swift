// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meister",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "MeisterAPI", targets: ["MeisterAPI"]),
        .executable(name: "meister", targets: ["MeisterCLI"]),
        .library(name: "MeisterCore", targets: ["MeisterCore"]),
        .library(name: "MeisterDeterministic", targets: ["MeisterDeterministic"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/swift-jobs.git", from: "1.4.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.3.1"),
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
                .product(name: "Yams", package: "Yams"),
                "CLibArchive",
            ],
            path: "Sources/MeisterCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "MeisterDeterministic",
            dependencies: [
                .target(name: "MeisterCore"),
            ],
            path: "Sources/MeisterDeterministic",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "MeisterAPI",
            dependencies: [
                .target(name: "MeisterCore"),
                .target(name: "MeisterDeterministic"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Jobs", package: "swift-jobs"),
            ],
            path: "Sources/MeisterAPI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "MeisterCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/MeisterCLI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MeisterCoreTests",
            dependencies: [
                .target(name: "MeisterCore"),
                .target(name: "MeisterDeterministic"),
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

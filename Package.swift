// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gegenlesen",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "GegenlesenAPI", targets: ["GegenlesenAPI"]),
        .executable(name: "gegenlesen", targets: ["GegenlesenCLI"]),
        .library(name: "GegenlesenCore", targets: ["GegenlesenCore"]),
        .library(name: "GegenlesenDeterministic", targets: ["GegenlesenDeterministic"]),
        .library(name: "GegenlesenAgent", targets: ["GegenlesenAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/swift-jobs.git", from: "1.4.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.3.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
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
            name: "GegenlesenCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Crypto", package: "swift-crypto"),
                "CLibArchive",
            ],
            path: "Sources/GegenlesenCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "GegenlesenDeterministic",
            dependencies: [
                .target(name: "GegenlesenCore"),
            ],
            path: "Sources/GegenlesenDeterministic",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "GegenlesenAgent",
            dependencies: [
                .target(name: "GegenlesenCore"),
            ],
            path: "Sources/GegenlesenAgent",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "GegenlesenAPI",
            dependencies: [
                .target(name: "GegenlesenCore"),
                .target(name: "GegenlesenDeterministic"),
                .target(name: "GegenlesenAgent"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Jobs", package: "swift-jobs"),
            ],
            path: "Sources/GegenlesenAPI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "GegenlesenCLI",
            dependencies: [
                .target(name: "GegenlesenCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/GegenlesenCLI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "GegenlesenCoreTests",
            dependencies: [
                .target(name: "GegenlesenCore"),
                .target(name: "GegenlesenDeterministic"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "GegenlesenAgentTests",
            dependencies: [
                .target(name: "GegenlesenAgent"),
                .target(name: "GegenlesenCore"),
            ]
        ),
        .testTarget(
            name: "GegenlesenAPITests",
            dependencies: [
                .target(name: "GegenlesenAPI"),
                .target(name: "GegenlesenCore"),
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)

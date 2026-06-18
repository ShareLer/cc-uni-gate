// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ApiManager",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ApiManagerCore", targets: ["ApiManagerCore"]),
        .executable(name: "ApiManagerApp", targets: ["ApiManagerApp"]),
        .executable(name: "ApiManagerInspect", targets: ["ApiManagerInspect"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.6.0")
    ],
    targets: [
        .target(
            name: "ApiManagerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "ApiManagerApp",
            dependencies: ["ApiManagerCore"]
        ),
        .executableTarget(
            name: "ApiManagerInspect",
            dependencies: ["ApiManagerCore"]
        ),
        .testTarget(
            name: "ApiManagerCoreTests",
            dependencies: ["ApiManagerCore"]
        )
    ]
)

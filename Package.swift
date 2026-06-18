// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UniGate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UniGateCore", targets: ["UniGateCore"]),
        .executable(name: "UniGateApp", targets: ["UniGateApp"]),
        .executable(name: "UniGateInspect", targets: ["UniGateInspect"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.6.0")
    ],
    targets: [
        .target(
            name: "UniGateCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "UniGateApp",
            dependencies: ["UniGateCore"]
        ),
        .executableTarget(
            name: "UniGateInspect",
            dependencies: ["UniGateCore"]
        ),
        .testTarget(
            name: "UniGateCoreTests",
            dependencies: ["UniGateCore"]
        )
    ]
)

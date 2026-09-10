// swift-tools-version: 6.3
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "YagartoMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "YagartoCore", targets: ["YagartoCore"]),
        .executable(name: "yagarto-mac", targets: ["YagartoMacCLI"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        )
    ],
    targets: [
        .target(
            name: "YagartoCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "YagartoMacCLI",
            dependencies: [
                "YagartoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "YagartoCoreTests",
            dependencies: ["YagartoCore"]
        )
    ]
)

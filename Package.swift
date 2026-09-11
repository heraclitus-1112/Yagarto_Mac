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
        .library(name: "YagartoAppSupport", targets: ["YagartoAppSupport"]),
        .executable(name: "yagarto-mac", targets: ["YagartoMacCLI"]),
        .executable(name: "YagartoMacApp", targets: ["YagartoMacApp"])
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
        .target(
            name: "YagartoAppSupport",
            dependencies: ["YagartoCore"]
        ),
        .executableTarget(
            name: "YagartoMacCLI",
            dependencies: [
                "YagartoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "YagartoMacApp",
            dependencies: ["YagartoAppSupport", "YagartoCore"]
        ),
        .testTarget(
            name: "YagartoCoreTests",
            dependencies: ["YagartoCore"]
        ),
        .testTarget(
            name: "YagartoAppSupportTests",
            dependencies: ["YagartoAppSupport", "YagartoCore"]
        )
    ]
)

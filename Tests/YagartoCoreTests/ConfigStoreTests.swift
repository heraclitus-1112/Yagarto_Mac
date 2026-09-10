// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class ConfigStoreTests: XCTestCase {
    func testDefaultConfigurationMatchesTaskOneContract() {
        let configuration = ProjectConfiguration.default

        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.profile, .arm7tdmi)
        XCTAssertEqual(configuration.entry, "start")
        XCTAssertEqual(configuration.sources, ["demo.s"])
        XCTAssertEqual(configuration.outputName, "demo")
    }

    func testRoundTripWritesStableJSONAndSupportsChineseAndSpaces() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigStore(projectDirectory: directory.url)
        let configuration = ProjectConfiguration(
            profile: .cortexM4,
            entry: "启动入口",
            sources: ["源 文件/启动.S"],
            outputName: "固件 文件"
        )

        try store.save(configuration)
        let firstWrite = try Data(contentsOf: store.configurationURL)
        try store.save(configuration)
        let secondWrite = try Data(contentsOf: store.configurationURL)

        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(firstWrite, secondWrite)
        XCTAssertTrue(String(decoding: firstWrite, as: UTF8.self).hasSuffix("\n"))
    }

    func testCorruptedJSONThrowsConfigurationError() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigStore(projectDirectory: directory.url)
        try Data("{broken".utf8).write(to: store.configurationURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error is YagartoError)
        }
    }

    func testUnknownSchemaVersionIsRejected() throws {
        let directory = try TemporaryDirectory()
        let store = ConfigStore(projectDirectory: directory.url)
        let json = """
        {"schemaVersion":2,"profile":"arm7tdmi","entry":"start","sources":["demo.s"],"outputName":"demo"}
        """
        try Data(json.utf8).write(to: store.configurationURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? YagartoError, .unsupportedSchemaVersion(2))
        }
    }

    func testEmptySourcesAreRejected() {
        let configuration = ProjectConfiguration(sources: [])

        XCTAssertThrowsError(try ConfigStore.validate(configuration)) { error in
            XCTAssertEqual(error as? YagartoError, .emptySources)
        }
    }

    func testNonAssemblySourcesAreRejected() {
        for source in ["main.c", "main.asm", "main"] {
            let configuration = ProjectConfiguration(sources: [source])
            XCTAssertThrowsError(try ConfigStore.validate(configuration)) { error in
                XCTAssertEqual(error as? YagartoError, .invalidSourceExtension(source))
            }
        }
    }

    func testUnsafeSourcePathsAreRejected() {
        for source in ["../secret.s", "src/../../secret.S", "/tmp/secret.s"] {
            let configuration = ProjectConfiguration(sources: [source])
            XCTAssertThrowsError(try ConfigStore.validate(configuration)) { error in
                XCTAssertTrue(error is YagartoError)
            }
        }
    }

    func testUnsafeOutputNamesAreRejected() {
        for outputName in ["../demo", "/tmp/demo", "build/demo", "build\\demo"] {
            let configuration = ProjectConfiguration(outputName: outputName)
            XCTAssertThrowsError(try ConfigStore.validate(configuration)) { error in
                XCTAssertEqual(error as? YagartoError, .invalidOutputName(outputName))
            }
        }
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class CLIIntegrationTests: XCTestCase {
    func testHelpListsTaskOneCommands() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(["--help"], in: directory.url)

        XCTAssertEqual(result.status, 0)
        for command in ["doctor", "init", "profile", "build", "disassemble"] {
            XCTAssertTrue(result.stdout.contains(command), "help 缺少 \(command)")
        }
    }

    func testInvalidInvocationUsesUsageExitCodeTwo() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(["not-a-command"], in: directory.url)

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        XCTAssertTrue(result.stderr.contains("not-a-command"))
    }

    func testInvalidProfileWithJSONFormatEmitsStableStructuredChineseError() throws {
        let directory = try CLITemporaryDirectory()
        let arguments = ["init", "--profile", "invalid", "--format", "json"]

        let first = try runCLI(arguments, in: directory.url)
        let second = try runCLI(arguments, in: directory.url)

        XCTAssertEqual(first.status, YagartoExitCode.usage.rawValue)
        XCTAssertEqual(first.stdout, "")
        XCTAssertEqual(first.stderr, second.stderr)
        let payload = try JSONDecoder().decode(
            CLIUsageErrorPayload.self,
            from: Data(first.stderr.utf8)
        )
        XCTAssertFalse(payload.success)
        XCTAssertEqual(payload.exitCode, YagartoExitCode.usage.rawValue)
        XCTAssertTrue(payload.message.contains("profile"))
        XCTAssertTrue(payload.message.contains("invalid"))
        XCTAssertTrue(payload.message.contains("可选值"))
        XCTAssertFalse(payload.message.contains("The value"))
    }

    func testInvalidProfileWithTextFormatEmitsActionableChineseError() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            ["init", "--profile", "invalid", "--format", "text"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        XCTAssertTrue(result.stderr.contains("profile"))
        XCTAssertTrue(result.stderr.contains("invalid"))
        XCTAssertTrue(result.stderr.contains("可选值"))
        XCTAssertTrue(result.stderr.contains("请"))
        XCTAssertFalse(result.stderr.contains("The value"))
        XCTAssertFalse(result.stderr.contains("Usage:"))
    }

    func testInitAndProfileSetPersistSelectedProfilesWithJSONOutput() throws {
        let directory = try CLITemporaryDirectory()

        let initialized = try runCLI(
            ["init", "--profile", "cortex-m4", "--format", "json"],
            in: directory.url
        )
        XCTAssertEqual(initialized.status, 0, initialized.stderr)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(initialized.stdout.utf8)))
        XCTAssertEqual(try ConfigStore(projectDirectory: directory.url).load().profile, .cortexM4)

        let changed = try runCLI(
            ["profile", "set", "stm32f4-discovery", "--format", "json"],
            in: directory.url
        )
        XCTAssertEqual(changed.status, 0, changed.stderr)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(changed.stdout.utf8)))
        XCTAssertEqual(
            try ConfigStore(projectDirectory: directory.url).load().profile,
            .stm32f4Discovery
        )
    }

    func testDoctorEmitsStructuredJSONReport() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(["doctor", "--format", "json"], in: directory.url)

        XCTAssertEqual(result.status, 0, result.stderr)
        let report = try JSONDecoder().decode(DoctorReport.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(report.entries.count, 8)
        XCTAssertEqual(report.entries.filter(\.required).count, 5)
        XCTAssertEqual(report.entries.filter { !$0.required }.count, 3)
    }

    func testBuildWithoutConfigurationOrSourceUsesConfigurationExitCode() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(["build", "--format", "text"], in: directory.url)

        XCTAssertEqual(result.status, YagartoExitCode.configuration.rawValue)
        XCTAssertTrue(result.stderr.contains("yagarto-mac init"))
    }

    func testSingleFileBuildOverridesConfiguredSourcesAndDisassemblesELF() throws {
        let directory = try CLITemporaryDirectory()
        try Data("""
        .text
        .global start
        start:
            mov r0, #0
            bx lr
        """.utf8).write(to: directory.url.appendingPathComponent("演示 文件.s"))
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            sources: ["不存在.s"],
            outputName: "firmware"
        ))

        let build = try runCLI(
            ["build", "演示 文件.s", "--format", "json"],
            in: directory.url
        )
        XCTAssertEqual(build.status, 0, build.stderr)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(build.stdout.utf8)))

        let outputDirectory = directory.url.appendingPathComponent(".yagarto/build/arm7tdmi")
        for filename in ["演示 文件.o", "firmware.elf", "firmware.map", "firmware.bin", "firmware.lst"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent(filename).path),
                "缺少构建产物 \(filename)"
            )
        }

        let disassembly = try runCLI(
            ["disassemble", outputDirectory.appendingPathComponent("firmware.elf").path, "--format", "json"],
            in: directory.url
        )
        XCTAssertEqual(disassembly.status, 0, disassembly.stderr)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(disassembly.stdout.utf8)) as? [String: Any]
        )
        XCTAssertTrue((payload["disassembly"] as? String)?.contains("<start>") == true)
    }
}

private struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct CLIUsageErrorPayload: Decodable {
    let success: Bool
    let exitCode: Int32
    let message: String
    let details: String?
}

private func runCLI(_ arguments: [String], in directory: URL) throws -> CLIResult {
    let process = Process()
    process.executableURL = cliExecutableURL()
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIResult(
        status: process.terminationStatus,
        stdout: String(decoding: stdout, as: UTF8.self),
        stderr: String(decoding: stderr, as: UTF8.self)
    )
}

private func cliExecutableURL() -> URL {
    Bundle(for: CLIIntegrationTests.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("yagarto-mac", isDirectory: false)
}

private struct CLITemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

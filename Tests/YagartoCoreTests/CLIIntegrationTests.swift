// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class CLIIntegrationTests: XCTestCase {
    func testProcessHarnessCapturesTwoMegabytesOfStderrWithoutDeadlock() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            throw XCTSkip("系统未提供 /usr/bin/perl，跳过大 stderr harness 回归")
        }
        let directory = try CLITemporaryDirectory()

        let result = try runCapturedProcess(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "print STDERR 'x' x (2 * 1024 * 1024); exit 7"],
            in: directory.url
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr.utf8.count, 2 * 1024 * 1024)
    }

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
            CLIErrorEnvelope.self,
            from: Data(first.stderr.utf8)
        )
        XCTAssertFalse(payload.success)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.exitCode, YagartoExitCode.usage.rawValue)
        XCTAssertEqual(payload.error.code, "usage.invalid_value")
        XCTAssertTrue(payload.error.message.contains("profile"))
        XCTAssertTrue(payload.error.message.contains("invalid"))
        XCTAssertTrue(payload.error.message.contains("可选值"))
        XCTAssertFalse(payload.error.message.contains("The value"))
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

    func testAttachedInvalidProfileIsLocalizedAsInvalidValue() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            ["init", "--profile=invalid", "--format=json"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "usage.invalid_value")
        XCTAssertTrue(payload.error.message.contains("--profile"))
        XCTAssertTrue(payload.error.message.contains("invalid"))
        XCTAssertFalse(payload.error.message.contains("The value"))
    }

    func testMissingProfileValueIsLocalizedAsMissingValue() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            ["init", "--profile", "--format", "json"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "usage.missing_value")
        XCTAssertTrue(payload.error.message.contains("--profile"))
        XCTAssertTrue(payload.error.message.contains("缺少"))
    }

    func testUnknownOptionIsLocalizedAsUnsupportedOption() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            ["init", "--wat", "--format", "json"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "usage.unknown_option")
        XCTAssertTrue(payload.error.message.contains("--wat"))
        XCTAssertTrue(payload.error.message.contains("不支持"))
    }

    func testProfileOptionIsUnsupportedForBuildSubcommand() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            ["build", "--profile", "invalid", "--format", "json"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "usage.unknown_option")
        XCTAssertTrue(payload.error.message.contains("--profile"))
        XCTAssertFalse(payload.error.message.contains("可选值"))
    }

    func testInitInUnwritableDirectoryUsesConfigurationErrorEnvelope() throws {
        let directory = try CLITemporaryDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.url.path
            )
        }

        let result = try runCLI(
            ["init", "--profile", "arm7tdmi", "--format", "json"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.configuration.rawValue)
        XCTAssertEqual(result.stdout, "")
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertFalse(payload.success)
        XCTAssertEqual(payload.exitCode, YagartoExitCode.configuration.rawValue)
        XCTAssertEqual(payload.error.code, "configuration.io")
        XCTAssertTrue(payload.error.message.contains("配置文件"))
        XCTAssertFalse(payload.error.message.contains("NSCocoaErrorDomain"))
        XCTAssertNil(payload.error.details)
    }

    func testDefaultTextConfigurationErrorOmitsFoundationDetails() throws {
        let directory = try CLITemporaryDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.url.path
            )
        }

        let result = try runCLI(
            ["init", "--profile", "arm7tdmi", "--format", "text"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.configuration.rawValue)
        XCTAssertTrue(result.stderr.contains("无法读写配置文件"))
        XCTAssertFalse(result.stderr.contains("详情："))
        XCTAssertFalse(result.stderr.contains("NSCocoaErrorDomain"))
    }

    func testCorruptedConfigurationUsesStableChineseErrorAndOmitsRawDetails() throws {
        let directory = try CLITemporaryDirectory()
        try Data("{broken".utf8).write(
            to: directory.url.appendingPathComponent("yagarto.json")
        )

        let result = try runCLI(["build", "--format", "json"], in: directory.url)

        XCTAssertEqual(result.status, YagartoExitCode.configuration.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "configuration.invalid_json")
        XCTAssertEqual(payload.error.message, "yagarto.json 格式无效。请修正 JSON 后重试。")
        XCTAssertNil(payload.error.details)
        XCTAssertFalse(payload.error.message.contains("NSCocoaErrorDomain"))
        XCTAssertFalse(payload.error.message.contains("DecodingError"))
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
        try requireARMBuildTools()
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
        let objectFiles = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "o" }
        XCTAssertEqual(objectFiles.count, 1)
        XCTAssertTrue(objectFiles[0].lastPathComponent.hasPrefix("演示 文件-"))
        for filename in ["firmware.elf", "firmware.map", "firmware.bin", "firmware.lst"] {
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

    func testRealBuildRejectsPreexistingMapSymlinkWithoutChangingVictim() throws {
        try requireARMBuildTools()
        let directory = try CLITemporaryDirectory()
        let outside = try CLITemporaryDirectory()
        try Data("""
        .text
        .global start
        start:
            bx lr
        """.utf8).write(to: directory.url.appendingPathComponent("demo.s"))
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            sources: ["demo.s"],
            outputName: "firmware"
        ))
        let outputDirectory = directory.url.appendingPathComponent(
            ".yagarto/build/arm7tdmi",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let victim = outside.url.appendingPathComponent("victim.txt")
        try Data("不可修改".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            atPath: outputDirectory.appendingPathComponent("firmware.map").path,
            withDestinationPath: victim.path
        )

        let result = try runCLI(["build", "--format", "json"], in: directory.url)

        XCTAssertEqual(result.status, YagartoExitCode.configuration.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "configuration.output_symlink")
        XCTAssertNil(payload.error.details)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "不可修改")
        let objectFiles = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "o" }
        XCTAssertTrue(objectFiles.isEmpty)
    }
}

private struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct CLIErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
        let details: String?
    }

    let schemaVersion: Int
    let success: Bool
    let exitCode: Int32
    let error: ErrorBody
}

private func decodeErrorEnvelope(_ string: String) throws -> CLIErrorEnvelope {
    try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(string.utf8))
}

private func requireARMBuildTools() throws {
    let requiredTools: [ToolIdentifier] = [.assembler, .linker, .objcopy, .objdump]
    let resolver = ToolResolver()
    let missingTools = requiredTools.filter { (try? resolver.resolve($0)) == nil }
    guard missingTools.isEmpty else {
        throw XCTSkip("缺少真实 ARM 工具：\(missingTools.map(\.rawValue).joined(separator: ", "))")
    }
}

private func runCLI(_ arguments: [String], in directory: URL) throws -> CLIResult {
    try runCapturedProcess(
        executable: cliExecutableURL(),
        arguments: arguments,
        in: directory
    )
}

private func runCapturedProcess(
    executable: URL,
    arguments: [String],
    in directory: URL
) throws -> CLIResult {
    let captureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: captureDirectory) }
    let stdoutURL = captureDirectory.appendingPathComponent("stdout")
    let stderrURL = captureDirectory.appendingPathComponent("stderr")
    guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
          FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()
    process.waitUntilExit()
    try stdoutHandle.close()
    try stderrHandle.close()
    let stdout = try Data(contentsOf: stdoutURL)
    let stderr = try Data(contentsOf: stderrURL)
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

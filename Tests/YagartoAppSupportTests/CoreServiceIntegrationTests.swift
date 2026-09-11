// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import YagartoAppSupport

final class CoreServiceIntegrationTests: XCTestCase {
    func testCoreBuildServiceRunsRealConfigPlannerAndExecutor() async throws {
        let fixture = try CoreServiceFixture()
        let service = CoreBuildService(overrides: fixture.toolOverrides)

        let result = try await service.build(projectDirectory: fixture.directory)

        XCTAssertEqual(result.configuration.profile, .arm7tdmi)
        XCTAssertEqual(result.elf.lastPathComponent, "课程固件.elf")
        let extensions = Set(result.artifacts.map(\.pathExtension))
        XCTAssertTrue(Set(["elf", "map", "bin", "lst"]).isSubset(of: extensions))
        XCTAssertTrue(result.artifacts.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(result.output.contains("listing"))
    }

    func testCoreBuildServiceMapsRealExecutorFailureToStructuredDiagnostic() async throws {
        let fixture = try CoreServiceFixture(failBuild: true)
        let service = CoreBuildService(overrides: fixture.toolOverrides)

        do {
            _ = try await service.build(projectDirectory: fixture.directory)
            XCTFail("Expected build failure")
        } catch let error as BuildServiceFailure {
            XCTAssertTrue(error.message.contains("构建"))
            XCTAssertEqual(error.diagnostics.first?.line, 2)
            XCTAssertEqual(error.diagnostics.first?.severity, .error)
            XCTAssertLessThanOrEqual(error.output.utf8.count, BuildDiagnosticParser.defaultOutputLimit)
        }
    }

    func testCoreDebugAdapterUsesDebugPlannerForBothModes() async throws {
        let fixture = try CoreServiceFixture()
        let build = AppBuildResult(
            configuration: fixture.configuration,
            projectDirectory: fixture.directory,
            elf: fixture.directory.appendingPathComponent("firmware.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        )
        let adapter = CoreDebugAdapter(
            overrides: [.gdb: "/usr/bin/true"],
            gdbSimulatorPath: "/usr/bin/true"
        )

        try await adapter.prepare(build)

        let backend = await adapter.preparedBackend
        let modes = await adapter.preparedModes
        XCTAssertEqual(backend, .gdbSimulator)
        XCTAssertEqual(modes, [.debug, .run])
    }
}

private struct CoreServiceFixture {
    let directory: URL
    let configuration: ProjectConfiguration
    let toolOverrides: [ToolIdentifier: String]

    init(failBuild: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Core 服务 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["主 程序.s"],
            outputName: "课程固件"
        )
        try ConfigStore(projectDirectory: directory).save(configuration)
        try Data(".global start\nstart: MOV r0, #1\n".utf8)
            .write(to: directory.appendingPathComponent("主 程序.s"))
        let tool = directory.appendingPathComponent("fake-arm-tool")
        let failureLine = failBuild
            ? "echo \"$PWD/主 程序.s:2: Error: bad instruction\" >&2; exit 1"
            : ""
        let script = """
        #!/bin/sh
        set -eu
        \(failureLine)
        output=""
        map=""
        previous=""
        last=""
        for argument in "$@"; do
          if [ "$previous" = "-o" ]; then output="$argument"; fi
          if [ "$previous" = "-Map" ]; then map="$argument"; fi
          previous="$argument"
          last="$argument"
        done
        if [ -n "$output" ]; then mkdir -p "$(dirname "$output")"; : > "$output"; fi
        if [ -n "$map" ]; then : > "$map"; fi
        if [ "${1:-}" = "-O" ]; then : > "$last"; fi
        if [ "${1:-}" = "-d" ]; then echo "listing"; fi
        """
        try Data(script.utf8).write(to: tool)
        guard chmod(tool.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        toolOverrides = [
            .assembler: tool.path,
            .compiler: tool.path,
            .linker: tool.path,
            .objcopy: tool.path,
            .objdump: tool.path
        ]
    }
}

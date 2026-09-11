// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class BackendE2ETests: XCTestCase {
    func testRealCortexAndSTMStartupBuildsWhenArmToolchainIsAvailable() throws {
        let resolver = ToolResolver()
        let required: [ToolIdentifier] = [.assembler, .linker, .objcopy, .objdump]
        var tools: [ToolIdentifier: String] = [:]
        for tool in required {
            guard let path = try? resolver.resolve(tool) else {
                throw XCTSkip("缺少真实 ARM 工具 \(tool.rawValue)，跳过 startup E2E")
            }
            tools[tool] = path
        }

        let expectations: [(ProfileID, [UInt8])] = [
            (.cortexM4, [0x00, 0x00, 0x40, 0x20]),
            (.stm32f4Discovery, [0x00, 0x00, 0x02, 0x20])
        ]
        for (profile, expectedStackBytes) in expectations {
            let project = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: project) }
            try Data("""
            .syntax unified
            .thumb
            .text
            .global user_main
            .thumb_func
            user_main:
                b .
            """.utf8).write(to: project.appendingPathComponent("demo.s"))

            let plan = try BuildPlanner(toolPaths: tools).plan(
                configuration: ProjectConfiguration(
                    profile: profile,
                    entry: "user_main",
                    sources: ["demo.s"],
                    outputName: "firmware"
                ),
                projectDirectory: project
            )
            _ = try BuildExecutor().execute(plan)

            for artifact in plan.artifactFiles {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: artifact.path),
                    "\(profile.rawValue) 缺少真实构建产物 \(artifact.lastPathComponent)"
                )
            }
            let binary = try Data(contentsOf: plan.binaryFile)
            XCTAssertGreaterThanOrEqual(binary.count, 8)
            XCTAssertEqual(Array(binary.prefix(4)), expectedStackBytes)
            XCTAssertEqual(binary[4] & 1, 1, "Reset_Handler 向量必须带 Thumb 状态位")
        }
    }

    func testRequiredQEMUMachinesWhenQEMUIsInstalled() throws {
        guard let qemu = try? ToolResolver().resolve(.qemuSystemARM) else {
            throw XCTSkip("未安装 qemu-system-arm，跳过 QEMU E2E capability 检查")
        }

        let result = try ProcessRunner().run(CommandSpec(
            executable: qemu,
            args: ["-machine", "help"],
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ))
        XCTAssertEqual(result.exitStatus, 0, result.toolOutput ?? "")
        let output = result.stdout + result.stderr
        XCTAssertTrue(output.contains("integratorcp"))
        XCTAssertTrue(output.contains("mps2-an386"))
    }
}

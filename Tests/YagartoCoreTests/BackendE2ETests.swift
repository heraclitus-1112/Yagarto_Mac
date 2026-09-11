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
            let map = try String(contentsOf: plan.mapFile, encoding: .utf8)
            let listing = try String(contentsOf: plan.listingFile, encoding: .utf8)
            XCTAssertFalse(map.contains("-staging-"), map)
            XCTAssertFalse(listing.contains("-staging-"), listing)
            XCTAssertTrue(map.contains(plan.outputDirectory.path), map)
            XCTAssertTrue(listing.contains(plan.elfFile.path), listing)
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

    func testInstalledOpenOCDCanInitializeDummyAdapterWithAllNetworkPortsDisabled() throws {
        guard let openOCD = try? ToolResolver().resolve(.openOCD) else {
            throw XCTSkip("未安装 OpenOCD，跳过本机端口禁用 smoke test")
        }
        let disabledPorts = "gdb_port disabled; tcl_port disabled; telnet_port disabled"
        let result = try ProcessRunner().run(CommandSpec(
            executable: openOCD,
            args: [
                "-c", "adapter driver dummy",
                "-c", disabledPorts,
                "-c", "init",
                "-c", "shutdown"
            ],
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.temporaryDirectory.path,
                isDirectory: true
            )
        ))

        XCTAssertEqual(result.exitStatus, 0, result.toolOutput ?? "")
        let output = result.stdout + result.stderr
        XCTAssertFalse(output.contains("Listening on port 3333"), output)
        XCTAssertFalse(output.contains("Listening on port 4444"), output)
        XCTAssertFalse(output.contains("Listening on port 6666"), output)
    }

    func testRealCustomInitializedWritableSectionsUseStartupDataCopyRange() throws {
        let resolver = ToolResolver()
        let required: [ToolIdentifier] = [.assembler, .linker, .objcopy, .objdump]
        var tools: [ToolIdentifier: String] = [:]
        for tool in required {
            guard let path = try? resolver.resolve(tool) else {
                throw XCTSkip("缺少真实 ARM 工具 \(tool.rawValue)，跳过初始化段 E2E")
            }
            tools[tool] = path
        }

        let profiles: [(ProfileID, UInt64, Range<UInt64>)] = [
            (.cortexM4, 0x00000000, 0x20000000..<0x203ff000),
            (.stm32f4Discovery, 0x08000000, 0x20000000..<0x2001f000)
        ]
        for (profile, codeOrigin, ramRange) in profiles {
            let project = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: project) }
            try Data("""
            .syntax unified
            .thumb
            .section .custom_writable, "aw", %progbits
            .global custom_initialized
            custom_initialized:
                .word 0x12345678
            .section .bss.probe, "aw", %nobits
            .global bss_probe
            bss_probe:
                .space 4
            .section .noinit.probe, "aw", %nobits
            .global noinit_probe
            noinit_probe:
                .space 4
            .text
            .global user_main
            .thumb_func
            user_main:
                b .
            """.utf8).write(to: project.appendingPathComponent("sections.s"))

            let plan = try BuildPlanner(toolPaths: tools).plan(
                configuration: ProjectConfiguration(
                    profile: profile,
                    entry: "user_main",
                    sources: ["sections.s"],
                    outputName: "sections"
                ),
                projectDirectory: project
            )
            try FileManager.default.createDirectory(
                at: plan.outputDirectory,
                withIntermediateDirectories: true
            )
            guard let linkIndex = plan.steps.firstIndex(where: {
                $0.command.executable == tools[.linker]
            }) else {
                return XCTFail("构建计划缺少链接步骤")
            }
            for step in plan.steps[...linkIndex] {
                let result = try ProcessRunner().run(step.command)
                XCTAssertEqual(result.exitStatus, 0, result.toolOutput ?? "")
                guard result.exitStatus == 0 else { continue }
            }

            let headersResult = try ProcessRunner().run(CommandSpec(
                executable: try XCTUnwrap(tools[.objdump]),
                args: ["-h", plan.elfFile.path],
                workingDirectory: project
            ))
            XCTAssertEqual(headersResult.exitStatus, 0, headersResult.toolOutput ?? "")
            let symbolsResult = try ProcessRunner().run(CommandSpec(
                executable: try XCTUnwrap(tools[.objdump]),
                args: ["-t", plan.elfFile.path],
                workingDirectory: project
            ))
            XCTAssertEqual(symbolsResult.exitStatus, 0, symbolsResult.toolOutput ?? "")

            let sections = parseELFSectionHeaders(headersResult.stdout)
            let symbols = parseELFSymbols(symbolsResult.stdout)
            guard let data = sections[".data"],
                  let bss = sections[".bss"],
                  let noinit = sections[".noinit"],
                  let custom = symbols["custom_initialized"],
                  let bssProbe = symbols["bss_probe"],
                  let noinitProbe = symbols["noinit_probe"],
                  let dataStart = symbols["__data_start__"]?.address,
                  let dataEnd = symbols["__data_end__"]?.address,
                  let dataLoad = symbols["__data_load__"]?.address,
                  let bssStart = symbols["__bss_start__"]?.address,
                  let bssEnd = symbols["__bss_end__"]?.address,
                  let stackLimit = symbols["__stack_limit__"]?.address else {
                XCTFail("\(profile.rawValue) ELF 缺少启动复制/清零契约符号\n\(headersResult.stdout)\n\(symbolsResult.stdout)")
                continue
            }

            XCTAssertEqual(custom.section, ".data")
            XCTAssertTrue(ramRange.contains(custom.address))
            XCTAssertGreaterThanOrEqual(custom.address, dataStart)
            XCTAssertLessThanOrEqual(custom.address + 4, dataEnd)
            XCTAssertEqual(data.vma, dataStart)
            XCTAssertEqual(data.lma, dataLoad)
            XCTAssertEqual(
                dataLoad + (custom.address - dataStart),
                data.lma + (custom.address - data.vma)
            )
            XCTAssertGreaterThanOrEqual(data.lma, codeOrigin)
            XCTAssertLessThan(data.lma, ramRange.lowerBound)
            XCTAssertLessThanOrEqual(data.vma + data.size, stackLimit)

            XCTAssertEqual(bssProbe.section, ".bss")
            XCTAssertGreaterThanOrEqual(bssProbe.address, bssStart)
            XCTAssertLessThan(bssProbe.address, bssEnd)
            XCTAssertFalse(bss.flags.contains("CONTENTS"), "bss 必须保持 NOLOAD")
            XCTAssertEqual(noinitProbe.section, ".noinit")
            XCTAssertFalse(noinit.flags.contains("CONTENTS"), "noinit 必须保持 NOLOAD")
            XCTAssertFalse(noinitProbe.address >= bssStart && noinitProbe.address < bssEnd)
            XCTAssertLessThanOrEqual(noinit.vma + noinit.size, stackLimit)

            let binaryResult = try ProcessRunner().run(CommandSpec(
                executable: try XCTUnwrap(tools[.objcopy]),
                args: ["-O", "binary", plan.elfFile.path, plan.binaryFile.path],
                workingDirectory: project
            ))
            XCTAssertEqual(binaryResult.exitStatus, 0, binaryResult.toolOutput ?? "")
            let binary = try Data(contentsOf: plan.binaryFile)
            let customLoadAddress = data.lma + (custom.address - data.vma)
            let customOffset = try XCTUnwrap(Int(exactly: customLoadAddress - codeOrigin))
            XCTAssertGreaterThanOrEqual(binary.count, customOffset + 4)
            XCTAssertEqual(
                Array(binary[customOffset..<(customOffset + 4)]),
                [0x78, 0x56, 0x34, 0x12],
                "\(profile.rawValue) 冷启动镜像必须携带自定义 writable 初值"
            )
        }
    }

    func testRealCortexLinkersKeepBSSNoInitAndOrphanWritableSectionsOutOfStack() throws {
        let resolver = ToolResolver()
        let required: [ToolIdentifier] = [.assembler, .linker, .objcopy, .objdump]
        var tools: [ToolIdentifier: String] = [:]
        for tool in required {
            guard let path = try? resolver.resolve(tool) else {
                throw XCTSkip("缺少真实 ARM 工具 \(tool.rawValue)，跳过 RAM 边界 E2E")
            }
            tools[tool] = path
        }

        let profiles: [(ProfileID, Int)] = [
            (.cortexM4, 4 * 1024 * 1024),
            (.stm32f4Discovery, 128 * 1024)
        ]
        let writableSections = [".bss", ".noinit", ".custom_writable"]
        for (profile, ramBytes) in profiles {
            let maximumWritableBytes = ramBytes - 4 * 1024
            for section in writableSections {
                let fittingPlan = try makeWritableBoundaryPlan(
                    profile: profile,
                    section: section,
                    byteCount: maximumWritableBytes,
                    tools: tools
                )
                XCTAssertNoThrow(
                    try BuildExecutor().execute(fittingPlan),
                    "\(profile.rawValue) \(section) 边界内应成功"
                )

                let overflowingPlan = try makeWritableBoundaryPlan(
                    profile: profile,
                    section: section,
                    byteCount: maximumWritableBytes + 1,
                    tools: tools
                )
                XCTAssertThrowsError(try BuildExecutor().execute(overflowingPlan)) { error in
                    let yagartoError = error as? YagartoError
                    XCTAssertEqual(yagartoError?.diagnosticCode, "build.step_failed")
                    let output = yagartoError?.toolOutput ?? ""
                    XCTAssertTrue(output.contains("RAM"), output)
                    XCTAssertTrue(output.localizedCaseInsensitiveContains("overflow"), output)
                }
            }
        }
    }

    private func makeWritableBoundaryPlan(
        profile: ProfileID,
        section: String,
        byteCount: Int,
        tools: [ToolIdentifier: String]
    ) throws -> BuildPlan {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("""
        .syntax unified
        .thumb
        .section \(section), "aw", %nobits
        .space \(byteCount)
        .text
        .global user_main
        .thumb_func
        user_main:
            b .
        """.utf8).write(to: project.appendingPathComponent("boundary.s"))
        addTeardownBlock { try? FileManager.default.removeItem(at: project) }
        return try BuildPlanner(toolPaths: tools).plan(
            configuration: ProjectConfiguration(
                profile: profile,
                entry: "user_main",
                sources: ["boundary.s"],
                outputName: "boundary"
            ),
            projectDirectory: project
        )
    }
}

private struct ELFSectionHeader {
    let size: UInt64
    let vma: UInt64
    let lma: UInt64
    let flags: String
}

private struct ELFSymbol {
    let address: UInt64
    let section: String
}

private func parseELFSectionHeaders(_ output: String) -> [String: ELFSectionHeader] {
    let lines = output.components(separatedBy: .newlines)
    var result: [String: ELFSectionHeader] = [:]
    for index in lines.indices {
        let fields = lines[index].split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 7,
              Int(fields[0]) != nil,
              let size = UInt64(fields[2], radix: 16),
              let vma = UInt64(fields[3], radix: 16),
              let lma = UInt64(fields[4], radix: 16) else {
            continue
        }
        let flags = index + 1 < lines.count ? lines[index + 1] : ""
        result[String(fields[1])] = ELFSectionHeader(
            size: size,
            vma: vma,
            lma: lma,
            flags: flags
        )
    }
    return result
}

private func parseELFSymbols(_ output: String) -> [String: ELFSymbol] {
    var result: [String: ELFSymbol] = [:]
    for line in output.components(separatedBy: .newlines) {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 4,
              let address = UInt64(fields[0], radix: 16) else {
            continue
        }
        let symbol = String(fields[fields.count - 1])
        let section = String(fields[fields.count - 3])
        result[symbol] = ELFSymbol(address: address, section: section)
    }
    return result
}

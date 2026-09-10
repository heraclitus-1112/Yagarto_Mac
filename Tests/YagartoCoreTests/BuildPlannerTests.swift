// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class BuildPlannerTests: XCTestCase {
    private let projectDirectory = URL(fileURLWithPath: "/tmp/项目 空格", isDirectory: true)
    private let tools: [ToolIdentifier: String] = [
        .assembler: "/tools/arm-none-eabi-as",
        .compiler: "/tools/arm-none-eabi-gcc",
        .linker: "/tools/arm-none-eabi-ld",
        .objcopy: "/tools/arm-none-eabi-objcopy",
        .objdump: "/tools/arm-none-eabi-objdump"
    ]

    func testArm7TDMILowercaseAssemblyGoldenPlan() throws {
        let configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "",
            sources: ["start/demo.s"],
            outputName: "demo"
        )

        let plan = try makePlanner().plan(
            configuration: configuration,
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(
            plan.commands,
            expectedCommands(
                profile: .arm7tdmi,
                source: "start/demo.s",
                assembler: .assembler,
                cpuArguments: ["-mcpu=arm7tdmi", "-g"],
                entry: "start",
                scriptName: "arm7tdmi.ld"
            )
        )
        XCTAssertEqual(plan.outputDirectory.path, "/tmp/项目 空格/.yagarto/build/arm7tdmi")
        XCTAssertEqual(plan.objectFiles.map(\.lastPathComponent), ["demo.o"])
        XCTAssertEqual(plan.elfFile.lastPathComponent, "demo.elf")
        XCTAssertEqual(plan.mapFile.lastPathComponent, "demo.map")
        XCTAssertEqual(plan.binaryFile.lastPathComponent, "demo.bin")
        XCTAssertEqual(plan.listingFile.lastPathComponent, "demo.lst")
        XCTAssertEqual(plan.steps.last?.standardOutputFile, plan.listingFile)
    }

    func testCortexM4PreprocessedAssemblyGoldenPlan() throws {
        let configuration = ProjectConfiguration(
            profile: .cortexM4,
            entry: "Reset_Handler",
            sources: ["源 代码/启动.S"],
            outputName: "固件 文件"
        )

        let plan = try makePlanner().plan(
            configuration: configuration,
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(
            plan.commands,
            expectedCommands(
                profile: .cortexM4,
                source: "源 代码/启动.S",
                assembler: .compiler,
                cpuArguments: ["-mcpu=cortex-m4", "-mthumb", "-g", "-c", "-x", "assembler-with-cpp"],
                entry: "Reset_Handler",
                scriptName: "mps2-an386.ld",
                outputName: "固件 文件"
            )
        )
        XCTAssertTrue(plan.commands[0].args.contains("/tmp/项目 空格/源 代码/启动.S"))
    }

    func testSTM32F4DiscoveryGoldenPlan() throws {
        let configuration = ProjectConfiguration(
            profile: .stm32f4Discovery,
            entry: "Reset_Handler",
            sources: ["startup.s"],
            outputName: "board"
        )

        let plan = try makePlanner().plan(
            configuration: configuration,
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(
            plan.commands,
            expectedCommands(
                profile: .stm32f4Discovery,
                source: "startup.s",
                assembler: .assembler,
                cpuArguments: ["-mcpu=cortex-m4", "-mthumb", "-g"],
                entry: "Reset_Handler",
                scriptName: "stm32f4-discovery.ld",
                outputName: "board"
            )
        )
    }

    func testMultipleSourcesProduceOneObjectPerSource() throws {
        let configuration = ProjectConfiguration(
            sources: ["start.s", "drivers/uart.S"],
            outputName: "multi"
        )

        let plan = try makePlanner().plan(
            configuration: configuration,
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(plan.objectFiles.map(\.lastPathComponent), ["start.o", "uart.o"])
        XCTAssertEqual(plan.steps.count, 5)
        XCTAssertEqual(Array(plan.commands[2].args.suffix(2)), [
            "/tmp/项目 空格/.yagarto/build/arm7tdmi/start.o",
            "/tmp/项目 空格/.yagarto/build/arm7tdmi/uart.o"
        ])
    }

    func testDuplicateSourceBasenamesAreRejected() {
        let configuration = ProjectConfiguration(
            sources: ["a/start.s", "b/start.S"]
        )

        XCTAssertThrowsError(
            try makePlanner().plan(
                configuration: configuration,
                projectDirectory: projectDirectory
            )
        ) { error in
            XCTAssertEqual(error as? YagartoError, .duplicateObjectName("start.o"))
        }
    }

    func testBundledLinkerScriptsContainCompleteMemoryAndSectionDefinitions() throws {
        let expectations: [(ProfileID, String, [String])] = [
            (.arm7tdmi, "arm7tdmi.ld", ["ORIGIN = 0x8000", "LENGTH = 64K"]),
            (.cortexM4, "mps2-an386.ld", ["ORIGIN = 0x00000000", "LENGTH = 4M", "ORIGIN = 0x20000000"]),
            (.stm32f4Discovery, "stm32f4-discovery.ld", ["ORIGIN = 0x08000000", "LENGTH = 1M", "LENGTH = 128K"])
        ]

        for (profile, filename, fragments) in expectations {
            let url = try LinkerScriptStore.url(for: profile)
            let script = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(url.lastPathComponent, filename)
            XCTAssertTrue(script.contains("ENTRY(start)"))
            XCTAssertTrue(script.contains("MEMORY"))
            XCTAssertTrue(script.contains("SECTIONS"))
            XCTAssertTrue(script.contains(".text"))
            XCTAssertTrue(script.contains(".data"))
            XCTAssertTrue(script.contains(".bss"))
            for fragment in fragments {
                XCTAssertTrue(script.contains(fragment), "\(filename) 缺少 \(fragment)")
            }
        }
    }

    private func makePlanner() -> BuildPlanner {
        BuildPlanner(
            toolPaths: tools,
            linkerScriptURL: { profile in
                URL(fileURLWithPath: "/scripts/\(profile.linkerScriptName)")
            }
        )
    }

    private func expectedCommands(
        profile: ProfileID,
        source: String,
        assembler: ToolIdentifier,
        cpuArguments: [String],
        entry: String,
        scriptName: String,
        outputName: String = "demo"
    ) -> [CommandSpec] {
        let outputDirectory = "/tmp/项目 空格/.yagarto/build/\(profile.rawValue)"
        let objectName = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent + ".o"
        let object = "\(outputDirectory)/\(objectName)"
        let elf = "\(outputDirectory)/\(outputName).elf"
        let map = "\(outputDirectory)/\(outputName).map"
        let binary = "\(outputDirectory)/\(outputName).bin"
        let workingDirectory = projectDirectory.standardizedFileURL

        return [
            CommandSpec(
                executable: tools[assembler]!,
                args: cpuArguments + ["-o", object, "/tmp/项目 空格/\(source)"],
                workingDirectory: workingDirectory
            ),
            CommandSpec(
                executable: tools[.linker]!,
                args: ["-T", "/scripts/\(scriptName)", "-e", entry, "-Map", map, "-o", elf, object],
                workingDirectory: workingDirectory
            ),
            CommandSpec(
                executable: tools[.objcopy]!,
                args: ["-O", "binary", elf, binary],
                workingDirectory: workingDirectory
            ),
            CommandSpec(
                executable: tools[.objdump]!,
                args: ["-d", "-S", elf],
                workingDirectory: workingDirectory
            )
        ]
    }
}

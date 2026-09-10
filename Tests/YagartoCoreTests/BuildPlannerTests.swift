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
        XCTAssertEqual(plan.projectDirectory, projectDirectory.standardizedFileURL)
        XCTAssertEqual(plan.objectFiles.map(\.lastPathComponent), ["demo-24d07e4e3695.o"])
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

        XCTAssertEqual(plan.objectFiles.map(\.lastPathComponent), [
            "start-d26c439e7789.o",
            "uart-bf0847a9541a.o"
        ])
        XCTAssertEqual(plan.steps.count, 5)
        XCTAssertEqual(Array(plan.commands[2].args.suffix(2)), [
            "/tmp/项目 空格/.yagarto/build/arm7tdmi/start-d26c439e7789.o",
            "/tmp/项目 空格/.yagarto/build/arm7tdmi/uart-bf0847a9541a.o"
        ])
    }

    func testCaseOnlySourceBasenamesProduceStableDistinctObjects() throws {
        let configuration = ProjectConfiguration(
            sources: ["a/foo.s", "b/FOO.s"]
        )

        let first = try makePlanner().plan(
            configuration: configuration,
            projectDirectory: projectDirectory
        )
        let second = try makePlanner().plan(
            configuration: configuration,
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(first.objectFiles, second.objectFiles)
        XCTAssertEqual(first.objectFiles.map(\.lastPathComponent), [
            "foo-601f8a7cde47.o",
            "FOO-6bfebb9b87f3.o"
        ])
        XCTAssertEqual(Set(first.objectFiles.map { $0.lastPathComponent.lowercased() }).count, 2)
    }

    func testRepeatedIdenticalSourceIsRejected() {
        let configuration = ProjectConfiguration(sources: ["same.s", "same.s"])

        XCTAssertThrowsError(try makePlanner().plan(
            configuration: configuration,
            projectDirectory: projectDirectory
        )) { error in
            XCTAssertEqual(
                (error as? YagartoError)?.diagnosticCode,
                "configuration.duplicate_source"
            )
        }
    }

    func testLexicallyEquivalentSourcePathsAreRejectedAsDuplicates() {
        let equivalentPairs = [
            ["same.s", "./same.s"],
            ["dir/x.s", "dir//x.s"]
        ]

        for sources in equivalentPairs {
            XCTAssertThrowsError(try makePlanner().plan(
                configuration: ProjectConfiguration(sources: sources),
                projectDirectory: projectDirectory
            )) { error in
                XCTAssertEqual(
                    (error as? YagartoError)?.diagnosticCode,
                    "configuration.duplicate_source"
                )
            }
        }
    }

    func testExistingFileAndInProjectSymlinkAliasAreRejectedAsDuplicates() throws {
        let root = try BuildTemporaryDirectory()
        let project = root.url.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = project.appendingPathComponent("same.s")
        try Data(".text".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(
            atPath: project.appendingPathComponent("alias.s").path,
            withDestinationPath: source.path
        )

        XCTAssertThrowsError(try makePlanner().plan(
            configuration: ProjectConfiguration(sources: ["same.s", "alias.s"]),
            projectDirectory: project
        )) { error in
            XCTAssertEqual(
                (error as? YagartoError)?.diagnosticCode,
                "configuration.duplicate_source"
            )
        }
    }

    func testExistingHardLinksWithSameInodeAreRejectedAsDuplicates() throws {
        let root = try BuildTemporaryDirectory()
        let project = root.url.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = project.appendingPathComponent("same.s")
        let hardLink = project.appendingPathComponent("hard-link.s")
        try Data(".text".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: hardLink)

        XCTAssertThrowsError(try makePlanner().plan(
            configuration: ProjectConfiguration(sources: ["same.s", "hard-link.s"]),
            projectDirectory: project
        )) { error in
            XCTAssertEqual(
                (error as? YagartoError)?.diagnosticCode,
                "configuration.duplicate_source"
            )
        }
    }

    func testCanonicalEquivalentPathsProduceSameObjectNameIndividually() throws {
        let direct = try makePlanner().plan(
            configuration: ProjectConfiguration(sources: ["same.s"]),
            projectDirectory: projectDirectory
        )
        let dotted = try makePlanner().plan(
            configuration: ProjectConfiguration(sources: ["./same.s"]),
            projectDirectory: projectDirectory
        )

        XCTAssertEqual(
            direct.objectFiles.first?.lastPathComponent,
            dotted.objectFiles.first?.lastPathComponent
        )
    }

    func testExistingSourceSymlinkResolvingOutsideProjectIsRejected() throws {
        let root = try BuildTemporaryDirectory()
        let project = root.url.appendingPathComponent("project", isDirectory: true)
        let outside = root.url.appendingPathComponent("outside.s")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(".text".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: project.appendingPathComponent("linked.s").path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(try makePlanner().plan(
            configuration: ProjectConfiguration(sources: ["linked.s"]),
            projectDirectory: project
        )) { error in
            guard let error = error as? YagartoError else {
                return XCTFail("越界 symlink 必须产生 YagartoError")
            }
            XCTAssertEqual(error.diagnosticCode, "configuration.source_escape")
            XCTAssertEqual(error.exitCode, .configuration)
        }
    }

    func testEveryExistingOutputHierarchySymlinkIsRejected() throws {
        let symlinkComponents = [
            [".yagarto"],
            [".yagarto", "build"],
            [".yagarto", "build", "arm7tdmi"]
        ]

        for (index, components) in symlinkComponents.enumerated() {
            let root = try BuildTemporaryDirectory()
            let project = root.url.appendingPathComponent("project", isDirectory: true)
            let outside = root.url.appendingPathComponent("outside-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let link = components.reduce(project) { $0.appendingPathComponent($1, isDirectory: true) }
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: outside.path
            )

            XCTAssertThrowsError(try makePlanner().plan(
                configuration: .default,
                projectDirectory: project
            )) { error in
                guard let error = error as? YagartoError else {
                    return XCTFail("输出 symlink 必须产生 YagartoError")
                }
                XCTAssertEqual(error.diagnosticCode, "configuration.output_symlink")
                XCTAssertEqual(error.exitCode, .configuration)
            }
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
        let expectedHashes: [String: String] = [
            "start/demo.s": "24d07e4e3695",
            "源 代码/启动.S": "2835d723abfc",
            "startup.s": "6fca6fd5fc43"
        ]
        let stem = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
        let objectName = "\(stem)-\(expectedHashes[source]!).o"
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

private struct BuildTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class DebugPlannerTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/调试 项目", isDirectory: true)
    private let elf = URL(fileURLWithPath: "/tmp/调试 项目/.yagarto/build/arm7tdmi/演示 固件.elf")

    func testDebugModelsHaveStableRawValues() {
        XCTAssertEqual(DebugBackend.gdbSimulator.rawValue, "gdb-simulator")
        XCTAssertEqual(DebugBackend.qemuARM926Compatible.rawValue, "qemu-arm926-compatible")
        XCTAssertEqual(DebugBackend.qemuMPS2AN386.rawValue, "qemu-mps2-an386")
        XCTAssertEqual(DebugBackend.openOCDSTM32F4Discovery.rawValue, "openocd-stm32f4-discovery")
        XCTAssertEqual(DebugMode.debug.rawValue, "debug")
        XCTAssertEqual(DebugMode.run.rawValue, "run")
    }

    func testARM7DebugPrefersSimulatorAndStopsAtEntry() throws {
        let plan = try planner(gdbSimulator: "/tools/arm-none-eabi-gdb-sim").plan(
            mode: .debug,
            configuration: ProjectConfiguration(entry: "课程入口"),
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(plan.backend, .gdbSimulator)
        XCTAssertEqual(plan.gdbExecutable, "/tools/arm-none-eabi-gdb-sim")
        XCTAssertEqual(plan.initCommands, [
            "file \"/tmp/调试 项目/.yagarto/build/arm7tdmi/演示 固件.elf\"",
            "target sim",
            "load",
            "tbreak 课程入口",
            "run"
        ])
        XCTAssertEqual(plan.gdbArguments, gdbArguments(plan.initCommands))
        XCTAssertTrue(plan.warnings.isEmpty)
        XCTAssertEqual(plan.elf, elf.path)
        XCTAssertEqual(plan.projectDirectory, project.path)
    }

    func testARM7RunSimulatorLoadsAndRunsWithoutTemporaryBreakpoint() throws {
        let plan = try planner(gdbSimulator: "/tools/gdb-sim").plan(
            mode: .run,
            configuration: .default,
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(plan.initCommands, [
            "file \"/tmp/调试 项目/.yagarto/build/arm7tdmi/演示 固件.elf\"",
            "target sim",
            "load",
            "run"
        ])
    }

    func testDebugUsesSameDefaultEntryAsBuildWhenConfiguredEntryIsBlank() throws {
        let plan = try planner(gdbSimulator: "/tools/gdb-sim").plan(
            mode: .debug,
            configuration: ProjectConfiguration(entry: "  \n "),
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(Array(plan.initCommands.suffix(2)), ["tbreak start", "run"])
    }

    func testARM7FallsBackToExplicitARM926CompatibleQEMUPipe() throws {
        let plan = try planner(qemu: "/tools/qemu system-arm").plan(
            mode: .debug,
            configuration: .default,
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(plan.backend, .qemuARM926Compatible)
        XCTAssertEqual(plan.gdbExecutable, "/tools/arm-none-eabi-gdb")
        XCTAssertEqual(plan.warnings, ["ARM926 是 ARM7TDMI 兼容超集，非精确模型"])
        XCTAssertEqual(plan.initCommands[0], "file \"/tmp/调试 项目/.yagarto/build/arm7tdmi/演示 固件.elf\"")
        XCTAssertEqual(
            plan.initCommands[1],
            "target remote | exec '/tools/qemu system-arm' '-M' 'integratorcp' '-cpu' 'arm926' '-kernel' '/tmp/调试 项目/.yagarto/build/arm7tdmi/演示 固件.elf' '-S' '-gdb' 'stdio' '-nographic' '-monitor' 'none' '-serial' 'none'"
        )
        XCTAssertEqual(Array(plan.initCommands.suffix(2)), ["tbreak start", "continue"])
    }

    func testARM7WithoutSimulatorOrQEMUIsActionableMissingBackendError() {
        XCTAssertThrowsError(try planner().plan(
            mode: .debug,
            configuration: .default,
            elf: elf,
            projectDirectory: project
        )) { error in
            guard let error = error as? YagartoError else {
                return XCTFail("必须返回 YagartoError")
            }
            XCTAssertEqual(error.exitCode, .missingTool)
            XCTAssertEqual(error.diagnosticCode, "debug.backend_unavailable")
            XCTAssertTrue(error.localizedDescription.contains("GDB target sim"))
            XCTAssertTrue(error.localizedDescription.contains("QEMU"))
        }
    }

    func testCortexM4DebugUsesMPS2AN386PipeAndStopsAtUserEntry() throws {
        let m4ELF = project.appendingPathComponent("固件's.elf")
        let plan = try planner(qemu: "/tools/qemu's arm").plan(
            mode: .debug,
            configuration: ProjectConfiguration(profile: .cortexM4, entry: "user_main"),
            elf: m4ELF,
            projectDirectory: project
        )

        XCTAssertEqual(plan.backend, .qemuMPS2AN386)
        XCTAssertEqual(
            plan.initCommands[1],
            "target remote | exec '/tools/qemu'\\''s arm' '-M' 'mps2-an386' '-kernel' '/tmp/调试 项目/固件'\\''s.elf' '-S' '-gdb' 'stdio' '-nographic' '-monitor' 'none' '-serial' 'none'"
        )
        XCTAssertEqual(Array(plan.initCommands.suffix(2)), ["tbreak user_main", "continue"])
    }

    func testCortexM4RunContinuesWithoutBreakpoint() throws {
        let plan = try planner(qemu: "/tools/qemu").plan(
            mode: .run,
            configuration: ProjectConfiguration(profile: .cortexM4),
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(plan.initCommands.last, "continue")
        XCTAssertFalse(plan.initCommands.contains(where: { $0.hasPrefix("tbreak ") }))
    }

    func testCortexM4WithoutQEMUUsesMissingToolExitFive() {
        XCTAssertThrowsError(try planner().plan(
            mode: .run,
            configuration: ProjectConfiguration(profile: .cortexM4),
            elf: elf,
            projectDirectory: project
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .missingTool)
        }
    }

    func testSTM32DebugUsesInstalledBoardConfigPipeAndInheritedStderrLog() throws {
        let board = URL(fileURLWithPath: "/opt/Open OCD/scripts/board/stm32f4discovery.cfg")
        let plan = try planner(openOCD: "/tools/openocd", board: board).plan(
            mode: .debug,
            configuration: ProjectConfiguration(profile: .stm32f4Discovery, entry: "main"),
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(plan.backend, .openOCDSTM32F4Discovery)
        XCTAssertEqual(plan.initCommands[0], "file \"/tmp/调试 项目/.yagarto/build/arm7tdmi/演示 固件.elf\"")
        XCTAssertEqual(
            plan.initCommands[1],
            "target extended-remote | exec '/tools/openocd' '-f' '/opt/Open OCD/scripts/board/stm32f4discovery.cfg' '-c' 'gdb_port pipe; tcl_port disabled; telnet_port disabled; log_output /dev/stderr'"
        )
        XCTAssertEqual(Array(plan.initCommands.suffix(3)), [
            "monitor reset halt", "tbreak main", "continue"
        ])
        XCTAssertFalse(plan.initCommands.contains("load"))
    }

    func testSTM32RunAttachesWithoutWritingFlashOrSettingBreakpoint() throws {
        let plan = try planner(
            openOCD: "/tools/openocd",
            board: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            mode: .run,
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(Array(plan.initCommands.suffix(2)), ["monitor reset halt", "continue"])
        XCTAssertFalse(plan.initCommands.contains("load"))
        XCTAssertFalse(plan.initCommands.contains(where: { $0.hasPrefix("tbreak ") }))
    }

    func testSTM32PlanningDoesNotCreateOrInspectProjectLogPaths() throws {
        let root = try DebugTemporaryDirectory()
        let outside = try DebugTemporaryDirectory()
        try FileManager.default.createSymbolicLink(
            atPath: root.url.appendingPathComponent(".yagarto").path,
            withDestinationPath: outside.url.path
        )

        let plan = try planner(
            openOCD: "/tools/openocd",
            board: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            mode: .debug,
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: root.url.appendingPathComponent("demo.elf"),
            projectDirectory: root.url
        )

        XCTAssertEqual(
            plan.initCommands[1],
            "target extended-remote | exec '/tools/openocd' '-f' '/board.cfg' '-c' 'gdb_port pipe; tcl_port disabled; telnet_port disabled; log_output /dev/stderr'"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.url.appendingPathComponent("logs").path
            )
        )
    }

    func testPipeArgumentsRejectNewlineAndNULInjection() {
        for unsafe in ["/tools/qemu\n-ex quit", "/tools/qemu\0evil"] {
            XCTAssertThrowsError(try planner(qemu: unsafe).plan(
                mode: .debug,
                configuration: ProjectConfiguration(profile: .cortexM4),
                elf: elf,
                projectDirectory: project
            )) { error in
                XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "debug.unsafe_pipe_value")
            }
        }
    }

    func testGDBEntryRejectsCommandInjection() {
        XCTAssertThrowsError(try planner(gdbSimulator: "/tools/gdb-sim").plan(
            mode: .debug,
            configuration: ProjectConfiguration(entry: "start\n-ex shell touch /tmp/nope"),
            elf: elf,
            projectDirectory: project
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "configuration.invalid_entry")
        }
    }

    private func planner(
        gdbSimulator: String? = nil,
        qemu: String? = nil,
        openOCD: String? = nil,
        board: URL? = nil
    ) -> DebugPlanner {
        var tools: [ToolIdentifier: String] = [.gdb: "/tools/arm-none-eabi-gdb"]
        tools[.qemuSystemARM] = qemu
        tools[.openOCD] = openOCD
        return DebugPlanner(
            toolPaths: tools,
            gdbSimulatorPath: gdbSimulator,
            openOCDBoardConfig: board
        )
    }

    private func gdbArguments(_ commands: [String]) -> [String] {
        ["-q", "-nx"] + commands.flatMap { ["-ex", $0] }
    }
}

private struct DebugTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

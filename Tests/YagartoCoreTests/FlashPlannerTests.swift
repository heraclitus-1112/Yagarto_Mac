// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import YagartoCore

final class FlashPlannerTests: XCTestCase {
    func testFlashPlanUsesDirectOpenOCDArgumentsAndTclSafeELFPath() throws {
        let project = URL(fileURLWithPath: "/tmp/烧录 项目", isDirectory: true)
        let elf = project.appendingPathComponent("固件; shutdown.elf")
        let board = URL(fileURLWithPath: "/opt/Open OCD/board/stm32f4discovery.cfg")

        let plan = try FlashPlanner(
            openOCDExecutable: "/tools/openocd",
            boardConfig: board
        ).plan(
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(plan.profile, .stm32f4Discovery)
        XCTAssertEqual(plan.elf, elf.path)
        XCTAssertEqual(plan.boardConfig, board.path)
        XCTAssertEqual(plan.command, CommandSpec(
            executable: "/tools/openocd",
            args: [
                "-f", board.path,
                "-c", "program {/tmp/烧录 项目/固件; shutdown.elf} verify reset exit"
            ],
            workingDirectory: project
        ))
    }

    func testFlashRejectsControlCharactersBeforeBuildingTclCommand() {
        let project = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        XCTAssertThrowsError(try FlashPlanner(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: URL(fileURLWithPath: "/tmp/project/demo\nshutdown.elf"),
            projectDirectory: project
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "flash.unsafe_tcl_value")
        }
        XCTAssertThrowsError(try tclQuote(
            "/tmp/project/demo\0shutdown.elf",
            error: .unsafeTclValue("/tmp/project/demo\0shutdown.elf")
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "flash.unsafe_tcl_value")
        }
    }

    func testTclQuotingPreservesBraceDollarBracketAndBackslashPathCharacters() throws {
        let project = URL(fileURLWithPath: "/tmp/烧录 项目", isDirectory: true)
        let elf = project.appendingPathComponent(#"固件{a}$x[shutdown]\demo.elf"#)

        let plan = try FlashPlanner(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: elf,
            projectDirectory: project
        )

        XCTAssertEqual(
            plan.command.args.last,
            #"program "/tmp/烧录 项目/固件{a}\$x\[shutdown\]\\demo.elf" verify reset exit"#
        )
    }

    func testFlashRejectsNonDiscoveryProfile() {
        XCTAssertThrowsError(try FlashPlanner(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            configuration: .default,
            elf: URL(fileURLWithPath: "/tmp/demo.elf"),
            projectDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "flash.unsupported_profile")
        }
    }

    func testHardwareProbeUsesOpenOCDInitShutdownAndReportsNoBoard() throws {
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 1,
            stdout: "",
            stderr: "no device found"
        ))
        let probe = OpenOCDHardwareProbe(runner: runner)
        let project = URL(fileURLWithPath: "/tmp/探针 项目", isDirectory: true)

        XCTAssertFalse(try probe.isBoardConnected(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board config.cfg"),
            projectDirectory: project
        ))
        XCTAssertEqual(runner.commands, [CommandSpec(
            executable: "/tools/openocd",
            args: ["-f", "/board config.cfg", "-c", "init", "-c", "shutdown"],
            workingDirectory: project
        )])
    }

    func testHardwareProbePreservesUnexpectedOpenOCDFailureInsteadOfClaimingNoBoard() {
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 2,
            stdout: "",
            stderr: "Error: syntax error in board configuration"
        ))
        let probe = OpenOCDHardwareProbe(runner: runner)

        XCTAssertThrowsError(try probe.isBoardConnected(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/broken-board.cfg"),
            projectDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "build.step_failed")
            XCTAssertEqual(
                (error as? YagartoError)?.toolOutput,
                "Error: syntax error in board configuration"
            )
        }
    }

    func testHardwareProbePrioritizesActionableErrorsOverNoDeviceMarkers() {
        let diagnostics = [
            "no device found\nError: LIBUSB_ERROR_ACCESS permission denied",
            "no device found\nError: USB access failed",
            "LIBUSB_ERROR_NO_DEVICE\nError: debug adapter is busy",
            "no cmsis-dap device found\nError: invalid board configuration",
            "no cmsis-dap device found\nError: invalid config script",
            "no device found\nError: transport initialization failed",
            "unable to find any matching cmsis-dap device\nError: adapter driver unavailable"
        ]

        for diagnostic in diagnostics {
            let probe = OpenOCDHardwareProbe(runner: FlashRecordingRunner(result: ProcessResult(
                exitStatus: 1,
                stdout: "",
                stderr: diagnostic
            )))

            XCTAssertThrowsError(try probe.isBoardConnected(
                openOCDExecutable: "/tools/openocd",
                boardConfig: URL(fileURLWithPath: "/board.cfg"),
                projectDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            ), "不应把可操作错误降级为无板：\(diagnostic)") { error in
                XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "build.step_failed")
                XCTAssertEqual((error as? YagartoError)?.toolOutput, diagnostic)
            }
        }
    }

    func testHardwareProbeDoesNotTreatAmbiguousOpenFailureAsNoBoard() {
        let diagnostic = "Error: open failed"
        let probe = OpenOCDHardwareProbe(runner: FlashRecordingRunner(result: ProcessResult(
            exitStatus: 1,
            stdout: "",
            stderr: diagnostic
        )))

        XCTAssertThrowsError(try probe.isBoardConnected(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board.cfg"),
            projectDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "build.step_failed")
            XCTAssertEqual((error as? YagartoError)?.toolOutput, diagnostic)
        }
    }

    func testFlashExecutorReturnsExitSixAndDoesNotProgramWhenBoardIsAbsent() throws {
        let project = URL(fileURLWithPath: "/tmp/烧录项目", isDirectory: true)
        let plan = try FlashPlanner(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: project.appendingPathComponent("demo.elf"),
            projectDirectory: project
        )
        let probe = StubHardwareProbe(connected: false)
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 0,
            stdout: "不应烧录",
            stderr: ""
        ))

        XCTAssertThrowsError(try FlashExecutor(
            hardwareProbe: probe,
            runner: runner
        ).execute(plan)) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .unsupported)
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "flash.board_not_found")
        }
        XCTAssertEqual(probe.invocationCount, 1)
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testFlashExecutorProgramsOnlyAfterSuccessfulHardwareProbe() throws {
        let project = URL(fileURLWithPath: "/tmp/烧录项目", isDirectory: true)
        let plan = try FlashPlanner(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: project.appendingPathComponent("demo.elf"),
            projectDirectory: project
        )
        let probe = StubHardwareProbe(connected: true)
        let expected = ProcessResult(exitStatus: 0, stdout: "verified", stderr: "")
        let runner = FlashRecordingRunner(result: expected)

        let result = try FlashExecutor(
            hardwareProbe: probe,
            runner: runner
        ).execute(plan)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(probe.invocationCount, 1)
        XCTAssertEqual(runner.commands, [plan.command])
    }

    func testFlashExecutorMapsOpenOCDFailureToControlledBuildError() throws {
        let project = URL(fileURLWithPath: "/tmp/烧录项目", isDirectory: true)
        let plan = try FlashPlanner(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board.cfg")
        ).plan(
            configuration: ProjectConfiguration(profile: .stm32f4Discovery),
            elf: project.appendingPathComponent("demo.elf"),
            projectDirectory: project
        )
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 9,
            stdout: "",
            stderr: "verify failed"
        ))

        XCTAssertThrowsError(try FlashExecutor(
            hardwareProbe: StubHardwareProbe(connected: true),
            runner: runner
        ).execute(plan)) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "build.step_failed")
            XCTAssertEqual((error as? YagartoError)?.toolOutput, "verify failed")
        }
    }
}

private final class FlashRecordingRunner: ProcessRunning {
    let result: ProcessResult
    private(set) var commands: [CommandSpec] = []

    init(result: ProcessResult) {
        self.result = result
    }

    func run(_ command: CommandSpec) throws -> ProcessResult {
        commands.append(command)
        return result
    }
}

private final class StubHardwareProbe: HardwareProbing {
    let connected: Bool
    private(set) var invocationCount = 0

    init(connected: Bool) {
        self.connected = connected
    }

    func isBoardConnected(
        openOCDExecutable: String,
        boardConfig: URL,
        projectDirectory: URL
    ) throws -> Bool {
        invocationCount += 1
        return connected
    }
}

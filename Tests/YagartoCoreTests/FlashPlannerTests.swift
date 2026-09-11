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
                "-c", "gdb_port disabled; tcl_port disabled; telnet_port disabled",
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

    func testHardwareProbeUsesOpenOCDInitShutdownAndPreservesNoDeviceFailure() throws {
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 1,
            stdout: "",
            stderr: "no device found"
        ))
        let probe = OpenOCDHardwareProbe(runner: runner)
        let project = URL(fileURLWithPath: "/tmp/探针 项目", isDirectory: true)

        XCTAssertThrowsError(try probe.isBoardConnected(
            openOCDExecutable: "/tools/openocd",
            boardConfig: URL(fileURLWithPath: "/board config.cfg"),
            projectDirectory: project
        )) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertEqual((error as? YagartoError)?.toolOutput, "no device found")
        }
        XCTAssertEqual(runner.commands, [CommandSpec(
            executable: "/tools/openocd",
            args: [
                "-f", "/board config.cfg",
                "-c", "gdb_port disabled; tcl_port disabled; telnet_port disabled",
                "-c", "init", "-c", "shutdown"
            ],
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

    func testSystemProfilerEnumeratorRecognizesCanonicalSTLinkVIDPID() throws {
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 0,
            stdout: """
            {"SPUSBDataType":[{"_name":"ST-LINK/V2-1","vendor_id":"0x0483  (STMicroelectronics)","product_id":"0x374b"}]}
            """,
            stderr: ""
        ))
        let enumerator = SystemProfilerSTLinkUSBEnumerator(runner: runner)

        XCTAssertEqual(try enumerator.presence(), .present)
        XCTAssertEqual(runner.commands, [CommandSpec(
            executable: "/usr/sbin/system_profiler",
            args: ["SPUSBDataType", "-json"],
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
        )])
    }

    func testSystemProfilerEnumeratorRecognizesNewSTLinkPIDsAcrossNestedRepresentations() throws {
        let fixtures = [
            #"{"SPUSBDataType":[{"hub":{"device":{"vendor_id":1155,"product_id":14165}}}]}"#,
            #"{"SPUSBDataType":[{"items":[{"vendor_id":"0X0483","product_id":"0X3757"}]}]}"#
        ]

        for fixture in fixtures {
            let runner = FlashRecordingRunner(result: ProcessResult(
                exitStatus: 0,
                stdout: fixture,
                stderr: ""
            ))
            XCTAssertEqual(
                try SystemProfilerSTLinkUSBEnumerator(runner: runner).presence(),
                .present,
                fixture
            )
        }
    }

    func testSystemProfilerEnumeratorReportsExplicitAbsenceForUnrelatedUSBDevices() throws {
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 0,
            stdout: """
            {"SPUSBDataType":[{"vendor_id":"0x05ac","product_id":"0x1234"}]}
            """,
            stderr: ""
        ))

        XCTAssertEqual(
            try SystemProfilerSTLinkUSBEnumerator(runner: runner).presence(),
            .absent
        )
    }

    func testSystemProfilerEnumeratorPreservesEnumerationFailure() {
        let diagnostic = "USB data source unavailable"
        let secret = "STLINK-SERIAL-SECRET"
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 7,
            stdout: "USB device serial_number = \(secret)",
            stderr: diagnostic
        ))

        XCTAssertThrowsError(try SystemProfilerSTLinkUSBEnumerator(
            runner: runner
        ).presence()) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            let output = (error as? YagartoError)?.toolOutput ?? ""
            XCTAssertTrue(output.contains(diagnostic), output)
            XCTAssertTrue(output.contains("退出码 7"), output)
            XCTAssertFalse(output.contains(secret), output)
            XCTAssertFalse(output.contains("serial_number"), output)
        }
    }

    func testSystemProfilerEnumeratorRejectsMissingUSBDataSchemaAsFailure() {
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 0,
            stdout: "{}",
            stderr: ""
        ))

        XCTAssertThrowsError(try SystemProfilerSTLinkUSBEnumerator(
            runner: runner
        ).presence()) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertTrue(
                (error as? YagartoError)?.toolOutput?.contains("SPUSBDataType") == true
            )
        }
    }

    func testSystemProfilerEnumeratorParseAndSchemaErrorsDoNotLeakUSBStdout() {
        let secret = "SERIAL-DO-NOT-ECHO-1234"
        let fixtures: [(stdout: String, expectedReason: String)] = [
            ("not json \(secret)", "无法解析 USB 枚举 JSON"),
            (#"{"serial_number":"\#(secret)"}"#, "缺少 SPUSBDataType 数组")
        ]

        for fixture in fixtures {
            let runner = FlashRecordingRunner(result: ProcessResult(
                exitStatus: 0,
                stdout: fixture.stdout,
                stderr: "system_profiler warning"
            ))

            XCTAssertThrowsError(try SystemProfilerSTLinkUSBEnumerator(
                runner: runner
            ).presence()) { error in
                let output = (error as? YagartoError)?.toolOutput ?? ""
                XCTAssertTrue(output.contains(fixture.expectedReason), output)
                XCTAssertTrue(output.contains("system_profiler warning"), output)
                XCTAssertFalse(output.contains(secret), output)
                XCTAssertFalse(output.contains(fixture.stdout), output)
            }
        }
    }

    func testFlashExecutorUsesUSBAbsenceAsExitSixWithoutRunningOpenOCD() throws {
        let plan = try flashTestPlan()
        let enumerator = StubSTLinkUSBEnumerator(result: .success(.absent))
        let probe = StubHardwareProbe(connected: true)
        let runner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 0,
            stdout: "",
            stderr: ""
        ))

        XCTAssertThrowsError(try FlashExecutor(
            stLinkUSBEnumerator: enumerator,
            hardwareProbe: probe,
            runner: runner
        ).execute(plan)) { error in
            XCTAssertEqual(error as? YagartoError, .flashBoardNotFound)
        }
        XCTAssertEqual(enumerator.invocationCount, 1)
        XCTAssertEqual(probe.invocationCount, 0)
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testFlashExecutorPreservesOpenOCDErrorsWhenUSBDeviceIsPresent() throws {
        for diagnostic in [
            "Error: open failed",
            "Error: LIBUSB_ERROR_ACCESS permission denied",
            "Error: debug adapter is busy",
            "Error: invalid board configuration"
        ] {
            let probeRunner = FlashRecordingRunner(result: ProcessResult(
                exitStatus: 1,
                stdout: "",
                stderr: diagnostic
            ))
            let programRunner = FlashRecordingRunner(result: ProcessResult(
                exitStatus: 0,
                stdout: "",
                stderr: ""
            ))

            XCTAssertThrowsError(try FlashExecutor(
                stLinkUSBEnumerator: StubSTLinkUSBEnumerator(result: .success(.present)),
                hardwareProbe: OpenOCDHardwareProbe(runner: probeRunner),
                runner: programRunner
            ).execute(try flashTestPlan())) { error in
                XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
                XCTAssertEqual((error as? YagartoError)?.toolOutput, diagnostic)
            }
            XCTAssertTrue(programRunner.commands.isEmpty)
        }
    }

    func testFlashExecutorTreatsOpenOCDNoDeviceOutputAsConflictWhenUSBIsPresent() throws {
        let diagnostic = "Error: no device found"
        let probeRunner = FlashRecordingRunner(result: ProcessResult(
            exitStatus: 1,
            stdout: "",
            stderr: diagnostic
        ))

        XCTAssertThrowsError(try FlashExecutor(
            stLinkUSBEnumerator: StubSTLinkUSBEnumerator(result: .success(.present)),
            hardwareProbe: OpenOCDHardwareProbe(runner: probeRunner),
            runner: FlashRecordingRunner(result: ProcessResult(
                exitStatus: 0,
                stdout: "",
                stderr: ""
            ))
        ).execute(try flashTestPlan())) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertEqual((error as? YagartoError)?.toolOutput, diagnostic)
        }
    }

    func testFlashExecutorPreservesUSBEnumerationFailureBeforeOpenOCDProbe() throws {
        let diagnostic = "system_profiler USB enumeration failed"
        let enumerator = StubSTLinkUSBEnumerator(result: .failure(.buildStepFailed(
            "/usr/sbin/system_profiler",
            9,
            diagnostic
        )))
        let probe = StubHardwareProbe(connected: true)

        XCTAssertThrowsError(try FlashExecutor(
            stLinkUSBEnumerator: enumerator,
            hardwareProbe: probe,
            runner: FlashRecordingRunner(result: ProcessResult(
                exitStatus: 0,
                stdout: "",
                stderr: ""
            ))
        ).execute(try flashTestPlan())) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertEqual((error as? YagartoError)?.toolOutput, diagnostic)
        }
        XCTAssertEqual(probe.invocationCount, 0)
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
            stLinkUSBEnumerator: StubSTLinkUSBEnumerator(result: .success(.absent)),
            hardwareProbe: probe,
            runner: runner
        ).execute(plan)) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .unsupported)
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "flash.board_not_found")
        }
        XCTAssertEqual(probe.invocationCount, 0)
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
            stLinkUSBEnumerator: StubSTLinkUSBEnumerator(result: .success(.present)),
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
            stLinkUSBEnumerator: StubSTLinkUSBEnumerator(result: .success(.present)),
            hardwareProbe: StubHardwareProbe(connected: true),
            runner: runner
        ).execute(plan)) { error in
            XCTAssertEqual((error as? YagartoError)?.exitCode, .buildFailure)
            XCTAssertEqual((error as? YagartoError)?.diagnosticCode, "build.step_failed")
            XCTAssertEqual((error as? YagartoError)?.toolOutput, "verify failed")
        }
    }
}

private func flashTestPlan() throws -> FlashPlan {
    let project = URL(fileURLWithPath: "/tmp/烧录项目", isDirectory: true)
    return try FlashPlanner(
        openOCDExecutable: "/tools/openocd",
        boardConfig: URL(fileURLWithPath: "/board.cfg")
    ).plan(
        configuration: ProjectConfiguration(profile: .stm32f4Discovery),
        elf: project.appendingPathComponent("demo.elf"),
        projectDirectory: project
    )
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

private final class StubSTLinkUSBEnumerator: STLinkUSBEnumerating {
    let result: Result<STLinkUSBPresence, YagartoError>
    private(set) var invocationCount = 0

    init(result: Result<STLinkUSBPresence, YagartoError>) {
        self.result = result
    }

    func presence() throws -> STLinkUSBPresence {
        invocationCount += 1
        return try result.get()
    }
}

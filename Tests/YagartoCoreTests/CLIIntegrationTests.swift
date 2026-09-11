// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin
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

    func testHelpListsBuildAndExecutionCommands() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(["--help"], in: directory.url)

        XCTAssertEqual(result.status, 0)
        for command in [
            "doctor", "init", "profile", "build", "disassemble",
            "run", "debug", "flash"
        ] {
            XCTAssertTrue(result.stdout.contains(command), "help 缺少 \(command)")
        }
    }

    func testInvalidInvocationUsesUsageExitCodeTwo() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(["not-a-command"], in: directory.url)

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        XCTAssertTrue(result.stderr.contains("not-a-command"))
    }

    func testDuplicateFormatIsRejectedConsistentlyBeforeCommandExecution() throws {
        let directory = try CLITemporaryDirectory()
        let commands = [
            ["doctor"],
            ["build"],
            ["run", "firmware.elf", "--profile", "cortex-m4"],
            ["debug", "firmware.elf", "--profile", "cortex-m4"],
            ["flash", "firmware.elf", "--profile", "stm32f4-discovery", "--yes"]
        ]
        let duplicateSpellings = [
            ["--format", "json", "--format=text"],
            ["--format=text", "--format", "json"]
        ]

        for command in commands {
            for formats in duplicateSpellings {
                let result = try runCLI(command + formats, in: directory.url)

                XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
                XCTAssertEqual(result.stdout, "")
                let payload = try decodeErrorEnvelope(result.stderr)
                XCTAssertEqual(payload.exitCode, YagartoExitCode.usage.rawValue)
                XCTAssertEqual(payload.error.code, "usage.duplicate_option")
                XCTAssertTrue(payload.error.message.contains("--format"))
            }
        }
    }

    func testDuplicateTextFormatUsesOnlyTextUsageDiagnostic() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            ["debug", "firmware.elf", "--format=text", "--format", "text"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("usage.duplicate_option"))
        XCTAssertTrue(result.stderr.contains("--format"))
        XCTAssertThrowsError(try decodeErrorEnvelope(result.stderr))
    }

    func testRunFormatPrescanStopsAtDoubleDashBeforeFormatLikeELFFilename() throws {
        let directory = try CLITemporaryDirectory()
        let tools = directory.url.appendingPathComponent("double-dash-tools", isDirectory: true)
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: tools.appendingPathComponent("arm-none-eabi-gdb")
        )
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: tools.appendingPathComponent("qemu-system-arm")
        )

        let result = try runCLI(
            [
                "run", "--profile", "cortex-m4", "--dry-run",
                "--format", "json", "--", "--format=json.s"
            ],
            in: directory.url,
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let plan = try JSONDecoder().decode(
            DebugLaunchPlan.self,
            from: Data(result.stdout.utf8)
        )
        XCTAssertTrue(plan.elf.hasSuffix("/--format=json.s"), plan.elf)
    }

    func testBuildFormatPrescanStopsAtDoubleDashBeforeFormatLikeSourceFilename() throws {
        try requireARMBuildTools()
        let directory = try CLITemporaryDirectory()
        try Data("""
        .text
        .global start
        start:
            bx lr
        """.utf8).write(to: directory.url.appendingPathComponent("--format=json.s"))

        let result = try runCLI(
            ["build", "--format", "json", "--", "--format=json.s"],
            in: directory.url
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)))
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

    func testInitWhenConfigurationPathIsDirectoryUsesConfigurationErrorEnvelope() throws {
        let directory = try CLITemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory.url.appendingPathComponent("yagarto.json"),
            withIntermediateDirectories: true
        )

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

    func testDefaultTextConfigurationPathConflictOmitsFoundationDetails() throws {
        let directory = try CLITemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory.url.appendingPathComponent("yagarto.json"),
            withIntermediateDirectories: true
        )

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

    func testMissingSourceReportsControlledToolOutputInTextAndJSON() throws {
        try requireARMBuildTools()
        let directory = try CLITemporaryDirectory()
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            sources: ["缺失 source.s"],
            outputName: "missing"
        ))

        let json = try runCLI(["build", "--format", "json"], in: directory.url)
        XCTAssertEqual(json.status, YagartoExitCode.buildFailure.rawValue)
        let payload = try decodeErrorEnvelope(json.stderr)
        XCTAssertEqual(payload.error.code, "build.step_failed")
        XCTAssertNil(payload.error.details)
        let jsonToolOutput = try XCTUnwrap(payload.error.toolOutput)
        XCTAssertTrue(jsonToolOutput.contains("缺失 source.s"))
        XCTAssertTrue(
            jsonToolOutput.localizedCaseInsensitiveContains("no such file")
                || jsonToolOutput.contains("无法")
                || jsonToolOutput.localizedCaseInsensitiveContains("can't open")
        )

        let text = try runCLI(["build", "--format", "text"], in: directory.url)
        XCTAssertEqual(text.status, YagartoExitCode.buildFailure.rawValue)
        XCTAssertTrue(text.stderr.contains("build.step_failed"))
        XCTAssertTrue(text.stderr.contains("工具输出："))
        XCTAssertTrue(text.stderr.contains("缺失 source.s"))
    }

    func testMissingSourceTextIncludesDiagnosticCodeAndToolOutput() throws {
        try requireARMBuildTools()
        let directory = try CLITemporaryDirectory()
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            sources: ["missing-text.s"],
            outputName: "missing-text"
        ))

        let result = try runCLI(["build", "--format", "text"], in: directory.url)

        XCTAssertEqual(result.status, YagartoExitCode.buildFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("build.step_failed"))
        XCTAssertTrue(result.stderr.contains("工具输出："))
        XCTAssertTrue(result.stderr.contains("missing-text.s"))
    }

    func testInvalidAssemblyReportsControlledToolOutputInTextAndJSON() throws {
        try requireARMBuildTools()
        let directory = try CLITemporaryDirectory()
        try Data("""
        .text
        .global start
        start:
            definitely_not_an_arm_instruction r0, r1
        """.utf8).write(to: directory.url.appendingPathComponent("bad.s"))
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            sources: ["bad.s"],
            outputName: "bad"
        ))

        let json = try runCLI(["build", "--format", "json"], in: directory.url)
        XCTAssertEqual(json.status, YagartoExitCode.buildFailure.rawValue)
        let payload = try decodeErrorEnvelope(json.stderr)
        XCTAssertEqual(payload.error.code, "build.step_failed")
        XCTAssertNil(payload.error.details)
        let jsonToolOutput = try XCTUnwrap(payload.error.toolOutput)
        XCTAssertTrue(jsonToolOutput.contains("bad.s"))
        XCTAssertTrue(
            jsonToolOutput.localizedCaseInsensitiveContains("instruction")
                || jsonToolOutput.localizedCaseInsensitiveContains("error")
        )

        let text = try runCLI(["build", "--format", "text"], in: directory.url)
        XCTAssertEqual(text.status, YagartoExitCode.buildFailure.rawValue)
        XCTAssertTrue(text.stderr.contains("build.step_failed"))
        XCTAssertTrue(text.stderr.contains("工具输出："))
        XCTAssertTrue(text.stderr.contains("bad.s"))
    }

    func testInvalidAssemblyTextIncludesDiagnosticCodeAndToolOutput() throws {
        try requireARMBuildTools()
        let directory = try CLITemporaryDirectory()
        try Data("""
        .text
        .global start
        start:
            invalid_instruction_for_text_case r0
        """.utf8).write(to: directory.url.appendingPathComponent("bad-text.s"))
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            sources: ["bad-text.s"],
            outputName: "bad-text"
        ))

        let result = try runCLI(["build", "--format", "text"], in: directory.url)

        XCTAssertEqual(result.status, YagartoExitCode.buildFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("build.step_failed"))
        XCTAssertTrue(result.stderr.contains("工具输出："))
        XCTAssertTrue(result.stderr.contains("bad-text.s"))
    }

    func testProfileSetInvalidValueIsLocalized() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            ["profile", "set", "invalid", "--format", "json"],
            in: directory.url
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "usage.invalid_value")
        XCTAssertTrue(payload.error.message.contains("invalid"))
        XCTAssertTrue(payload.error.message.contains("可选值"))
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

    func testDoctorTextSeparatesGDBCapabilityQEMUOpenOCDAndBoardConfig() throws {
        let directory = try CLITemporaryDirectory()
        let prefix = directory.url.appendingPathComponent("doctor-tools", isDirectory: true)
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        for tool in ["arm-none-eabi-gdb", "qemu-system-arm", "openocd"] {
            try writeExecutable("#!/bin/sh\nexit 0\n", to: bin.appendingPathComponent(tool))
        }
        let board = prefix.appendingPathComponent(
            "share/openocd/scripts/board/stm32f4discovery.cfg"
        )
        try FileManager.default.createDirectory(
            at: board.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# fake board config\n".utf8).write(to: board)

        let result = try runCLI(
            ["doctor", "--format", "text"],
            in: directory.url,
            environment: ["PATH": "\(bin.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("GDB 可执行文件"))
        XCTAssertTrue(result.stdout.contains("常规 GDB target sim：支持"))
        XCTAssertTrue(result.stdout.contains("GDB target sim：支持"))
        XCTAssertTrue(result.stdout.contains("QEMU"))
        XCTAssertTrue(result.stdout.contains("OpenOCD"))
        XCTAssertTrue(result.stdout.contains("stm32f4discovery.cfg"))
    }

    func testDoctorProfileSelectionsMatchAllDebugDryRunPlans() throws {
        let directory = try CLITemporaryDirectory()
        let prefix = directory.url.appendingPathComponent("selection-tools", isDirectory: true)
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        let normalGDB = bin.appendingPathComponent("arm-none-eabi-gdb")
        let simulatorGDB = bin.appendingPathComponent("arm-none-eabi-gdb-sim")
        try writeExecutable("#!/bin/sh\nexit 1\n", to: normalGDB)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: simulatorGDB)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: bin.appendingPathComponent("qemu-system-arm"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: bin.appendingPathComponent("openocd"))
        let board = prefix.appendingPathComponent(
            "share/openocd/scripts/board/stm32f4discovery.cfg"
        )
        try FileManager.default.createDirectory(
            at: board.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# fake board config\n".utf8).write(to: board)
        let environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "YAGARTO_MAC_GDB_SIM": simulatorGDB.path
        ]

        let doctorResult = try runCLI(
            ["doctor", "--format", "json"],
            in: directory.url,
            environment: environment
        )
        XCTAssertEqual(doctorResult.status, 0, doctorResult.stderr)
        let report = try JSONDecoder().decode(
            DoctorReport.self,
            from: Data(doctorResult.stdout.utf8)
        )
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.normalGDB.path, normalGDB.path)
        XCTAssertEqual(report.simulatorGDB.path, simulatorGDB.path)

        for profile in ProfileID.allCases {
            let planResult = try runCLI(
                [
                    "debug", "firmware.elf",
                    "--profile", profile.rawValue,
                    "--dry-run",
                    "--format", "json"
                ],
                in: directory.url,
                environment: environment
            )
            XCTAssertEqual(planResult.status, 0, "\(profile): \(planResult.stderr)")
            let plan = try JSONDecoder().decode(
                DebugLaunchPlan.self,
                from: Data(planResult.stdout.utf8)
            )
            let selection = try XCTUnwrap(report.debugSelection(for: profile))
            XCTAssertTrue(selection.available)
            XCTAssertEqual(selection.backend, plan.backend)
            XCTAssertEqual(selection.gdbExecutable, plan.gdbExecutable)
            XCTAssertEqual(selection.warnings, plan.warnings)
        }
    }

    func testDebugDryRunJSONUsesConfiguredELFAndGDBSimulatorPlan() throws {
        let directory = try CLITemporaryDirectory()
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "课程入口",
            sources: ["demo.s"],
            outputName: "演示 固件"
        ))
        let simulator = directory.url.appendingPathComponent("工具/gdb sim")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: simulator)

        let result = try runCLI(
            ["debug", "--dry-run", "--format", "json"],
            in: directory.url,
            environment: ["YAGARTO_MAC_GDB_SIM": simulator.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        let plan = try JSONDecoder().decode(
            DebugLaunchPlan.self,
            from: Data(result.stdout.utf8)
        )
        XCTAssertEqual(plan.backend, .gdbSimulator)
        XCTAssertEqual(plan.gdbExecutable, simulator.path)
        XCTAssertEqual(plan.initCommands, [
            "file \"\(plan.elf)\"",
            "target sim",
            "load",
            "tbreak 课程入口",
            "run"
        ])
    }

    func testRunDryRunTextAcceptsExplicitELFAndProfileOverride() throws {
        let directory = try CLITemporaryDirectory()
        let tools = directory.url.appendingPathComponent("fake-tools", isDirectory: true)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: tools.appendingPathComponent("arm-none-eabi-gdb"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: tools.appendingPathComponent("qemu-system-arm"))

        let result = try runCLI(
            [
                "run", "固件 路径.elf",
                "--profile", "cortex-m4",
                "--dry-run",
                "--format", "text"
            ],
            in: directory.url,
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("profile：cortex-m4"))
        XCTAssertTrue(result.stdout.contains("backend：qemu-mps2-an386"))
        XCTAssertTrue(result.stdout.contains("固件 路径.elf"))
        XCTAssertTrue(result.stdout.contains("  -ex continue"))
        XCTAssertFalse(result.stdout.contains("tbreak"))
    }

    func testActualARM926FallbackPrintsWarningBeforeLaunchingGDB() throws {
        let directory = try CLITemporaryDirectory()
        let tools = directory.url.appendingPathComponent("warning-tools", isDirectory: true)
        let marker = directory.url.appendingPathComponent("gdb-launched")
        try writeExecutable(
            """
            #!/bin/sh
            case " $* " in
                *" target sim "*) exit 1 ;;
            esac
            printf 'GDB 已启动\n' >&2
            : > "$YAGARTO_GDB_LAUNCH_MARKER"
            exit 0
            """,
            to: tools.appendingPathComponent("arm-none-eabi-gdb")
        )
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: tools.appendingPathComponent("qemu-system-arm")
        )

        let result = try runCLI(
            ["run", "firmware.elf", "--profile", "arm7tdmi", "--format", "text"],
            in: directory.url,
            environment: [
                "PATH": "\(tools.path):/usr/bin:/bin",
                "YAGARTO_GDB_LAUNCH_MARKER": marker.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("警告"))
        XCTAssertTrue(result.stderr.contains("ARM926"))
        XCTAssertTrue(result.stderr.contains("非精确模型"))
        XCTAssertLessThan(
            try XCTUnwrap(result.stderr.range(of: "警告")).lowerBound,
            try XCTUnwrap(result.stderr.range(of: "GDB 已启动")).lowerBound
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testARM926FallbackDryRunJSONCarriesWarningWithoutMixingStderr() throws {
        let directory = try CLITemporaryDirectory()
        let tools = directory.url.appendingPathComponent("warning-json-tools", isDirectory: true)
        try writeExecutable(
            "#!/bin/sh\nexit 1\n",
            to: tools.appendingPathComponent("arm-none-eabi-gdb")
        )
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: tools.appendingPathComponent("qemu-system-arm")
        )

        let result = try runCLI(
            [
                "debug", "firmware.elf",
                "--profile", "arm7tdmi",
                "--dry-run",
                "--format", "json"
            ],
            in: directory.url,
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        let plan = try JSONDecoder().decode(DebugLaunchPlan.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(plan.backend, .qemuARM926Compatible)
        XCTAssertEqual(plan.warnings, ["ARM926 是 ARM7TDMI 兼容超集，非精确模型"])
    }

    func testInteractiveRunAndDebugRejectJSONBeforeLaunchingGDB() throws {
        for command in ["run", "debug"] {
            let directory = try CLITemporaryDirectory()
            let tools = directory.url.appendingPathComponent("json-tools", isDirectory: true)
            let marker = directory.url.appendingPathComponent("gdb-launched")
            try writeExecutable(
                "#!/bin/sh\n: > \"$YAGARTO_GDB_LAUNCH_MARKER\"\nexit 0\n",
                to: tools.appendingPathComponent("arm-none-eabi-gdb")
            )
            try writeExecutable(
                "#!/bin/sh\nexit 0\n",
                to: tools.appendingPathComponent("qemu-system-arm")
            )

            let result = try runCLI(
                [command, "firmware.elf", "--profile", "cortex-m4", "--format", "json"],
                in: directory.url,
                environment: [
                    "PATH": "\(tools.path):/usr/bin:/bin",
                    "YAGARTO_GDB_LAUNCH_MARKER": marker.path
                ]
            )

            XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue, command)
            XCTAssertEqual(result.stdout, "")
            let payload = try decodeErrorEnvelope(result.stderr)
            XCTAssertEqual(payload.error.code, "usage.interactive_json_unsupported")
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testRunMapsInteractiveGDBInterruptToExit130TextDiagnostic() throws {
        let directory = try CLITemporaryDirectory()
        let tools = directory.url.appendingPathComponent("interrupt-tools", isDirectory: true)
        try writeExecutable(
            "#!/bin/sh\nkill -INT $$\nexit 99\n",
            to: tools.appendingPathComponent("arm-none-eabi-gdb")
        )
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: tools.appendingPathComponent("qemu-system-arm")
        )

        let result = try runCLI(
            [
                "run", "firmware.elf",
                "--profile", "cortex-m4",
                "--format", "text"
            ],
            in: directory.url,
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, YagartoExitCode.interrupted.rawValue)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("process.interrupted"))
        XCTAssertTrue(result.stderr.contains("Ctrl-C"))
    }

    func testRunDoesNotMisreportNormalGDBExit130AsCtrlC() throws {
        let directory = try CLITemporaryDirectory()
        let tools = directory.url.appendingPathComponent("exit-130-tools", isDirectory: true)
        try writeExecutable(
            "#!/bin/sh\nexit 130\n",
            to: tools.appendingPathComponent("arm-none-eabi-gdb")
        )
        try writeExecutable(
            "#!/bin/sh\nexit 0\n",
            to: tools.appendingPathComponent("qemu-system-arm")
        )

        let result = try runCLI(
            [
                "run", "firmware.elf",
                "--profile", "cortex-m4",
                "--format", "text"
            ],
            in: directory.url,
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, YagartoExitCode.buildFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("build.step_failed"), result.stderr)
        XCTAssertFalse(result.stderr.contains("process.interrupted"), result.stderr)
        XCTAssertFalse(result.stderr.contains("Ctrl-C"), result.stderr)
    }

    func testRunEscalatesParentSignalsAndReapsIgnoringProcessGroupWithinBound() throws {
        let cases: [(
            signal: Int32,
            expectedStatus: Int32,
            diagnosticCode: String,
            name: String
        )] = [
            (SIGINT, 128 + SIGINT, "process.interrupted", "SIGINT"),
            (SIGTERM, 128 + SIGTERM, "process.terminated_by_signal", "SIGTERM"),
            (SIGHUP, 128 + SIGHUP, "process.terminated_by_signal", "SIGHUP")
        ]

        for testCase in cases {
            let directory = try CLITemporaryDirectory()
            let tools = directory.url.appendingPathComponent("signal-tools", isDirectory: true)
            let pidFile = directory.url.appendingPathComponent("descendant-pids.txt")
            try writeExecutable(
                """
                #!/bin/sh
                trap '' INT TERM HUP
                /bin/sleep 30 &
                grandchild=$!
                printf '%s %s\n' "$$" "$grandchild" > "$YAGARTO_SIGNAL_PID_FILE"
                wait "$grandchild"
                """,
                to: tools.appendingPathComponent("arm-none-eabi-gdb")
            )
            try writeExecutable(
                "#!/bin/sh\nexit 0\n",
                to: tools.appendingPathComponent("qemu-system-arm")
            )

            let start = Date()
            let result = try runCLIAndSendSignal(
                ["run", "firmware.elf", "--profile", "cortex-m4", "--format", "text"],
                in: directory.url,
                environment: [
                    "PATH": "\(tools.path):/usr/bin:/bin",
                    "YAGARTO_SIGNAL_PID_FILE": pidFile.path
                ],
                signal: testCase.signal,
                pidFile: pidFile
            )

            XCTAssertEqual(
                result.status,
                testCase.expectedStatus,
                "\(testCase.name)：\(result.stderr)"
            )
            XCTAssertLessThan(Date().timeIntervalSince(start), 3, testCase.name)
            XCTAssertTrue(result.stderr.contains(testCase.diagnosticCode), testCase.name)
            let remaining = result.descendantPIDs.filter { !processHasExited($0) }
            XCTAssertTrue(
                remaining.isEmpty,
                "\(testCase.name) 后仍存在 PID：\(remaining)"
            )
        }
    }

    func testDebugLaunchesSelectedGDBAndReturnsItsSuccessfulStatus() throws {
        let directory = try CLITemporaryDirectory()
        let simulator = directory.url.appendingPathComponent("actual-tools/gdb-sim")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: simulator)

        let result = try runCLI(
            [
                "debug", "firmware.elf",
                "--profile", "arm7tdmi",
                "--format", "text"
            ],
            in: directory.url,
            environment: ["YAGARTO_MAC_GDB_SIM": simulator.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }

    func testRunMapsNonzeroGDBStatusToControlledTextFailure() throws {
        let directory = try CLITemporaryDirectory()
        let tools = directory.url.appendingPathComponent("failed-tools", isDirectory: true)
        try writeExecutable("#!/bin/sh\nexit 7\n", to: tools.appendingPathComponent("arm-none-eabi-gdb"))
        try writeExecutable("#!/bin/sh\nexit 0\n", to: tools.appendingPathComponent("qemu-system-arm"))

        let result = try runCLI(
            [
                "run", "firmware.elf",
                "--profile", "cortex-m4",
                "--format", "text"
            ],
            in: directory.url,
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, YagartoExitCode.buildFailure.rawValue)
        XCTAssertTrue(result.stderr.contains("build.step_failed"))
        XCTAssertTrue(result.stderr.contains("7"))
    }

    func testFlashRequiresExplicitYesBeforeResolvingToolsOrHardware() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            [
                "flash", "firmware.elf",
                "--profile", "stm32f4-discovery",
                "--format", "json"
            ],
            in: directory.url,
            environment: ["PATH": "/nonexistent"]
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "usage.confirmation_required")
        XCTAssertTrue(payload.error.message.contains("--yes"))
    }

    func testFlashDryRunTextAndJSONNeedNoConfirmationAndDoNotProbeOrProgram() throws {
        let directory = try CLITemporaryDirectory()
        let prefix = directory.url.appendingPathComponent("dry-run-openocd", isDirectory: true)
        let openOCD = prefix.appendingPathComponent("bin/openocd")
        let marker = directory.url.appendingPathComponent("openocd-executed")
        let profilerMarker = directory.url.appendingPathComponent("system-profiler-executed")
        let profiler = prefix.appendingPathComponent("bin/system_profiler")
        try writeExecutable(
            "#!/bin/sh\n: > \"$YAGARTO_OPENOCD_MARKER\"\nexit 0\n",
            to: openOCD
        )
        try writeExecutable(
            "#!/bin/sh\n: > \"$YAGARTO_PROFILER_MARKER\"\nprintf '{\"SPUSBDataType\":[]}'\n",
            to: profiler
        )
        let board = prefix.appendingPathComponent(
            "share/openocd/scripts/board/stm32f4discovery.cfg"
        )
        try FileManager.default.createDirectory(
            at: board.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# fake board config\n".utf8).write(to: board)

        let result = try runCLI(
            [
                "flash", "固件 文件.elf",
                "--profile", "stm32f4-discovery",
                "--dry-run",
                "--format", "json"
            ],
            in: directory.url,
            environment: [
                "PATH": "\(prefix.appendingPathComponent("bin").path):/usr/bin:/bin",
                "YAGARTO_OPENOCD_MARKER": marker.path,
                "YAGARTO_MAC_SYSTEM_PROFILER": profiler.path,
                "YAGARTO_PROFILER_MARKER": profilerMarker.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
        let plan = try JSONDecoder().decode(FlashPlan.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(plan.profile, .stm32f4Discovery)
        XCTAssertTrue(plan.elf.hasSuffix("/固件 文件.elf"))
        XCTAssertEqual(plan.command.executable, openOCD.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilerMarker.path))

        let textResult = try runCLI(
            [
                "flash", "固件 文件.elf",
                "--profile", "stm32f4-discovery",
                "--dry-run",
                "--format", "text"
            ],
            in: directory.url,
            environment: [
                "PATH": "\(prefix.appendingPathComponent("bin").path):/usr/bin:/bin",
                "YAGARTO_OPENOCD_MARKER": marker.path,
                "YAGARTO_MAC_SYSTEM_PROFILER": profiler.path,
                "YAGARTO_PROFILER_MARKER": profilerMarker.path
            ]
        )
        XCTAssertEqual(textResult.status, 0, textResult.stderr)
        XCTAssertTrue(textResult.stdout.contains("profile：stm32f4-discovery"))
        XCTAssertTrue(textResult.stdout.contains("OpenOCD：\(openOCD.path)"))
        XCTAssertTrue(textResult.stdout.contains("program"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilerMarker.path))
    }

    func testFlashRejectsNonDiscoveryProfileAsUsageBeforeToolLookup() throws {
        let directory = try CLITemporaryDirectory()

        let result = try runCLI(
            [
                "flash", "firmware.elf",
                "--profile", "arm7tdmi",
                "--yes",
                "--format", "json"
            ],
            in: directory.url,
            environment: ["PATH": "/nonexistent"]
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "flash.unsupported_profile")
        XCTAssertTrue(payload.error.message.contains("stm32f4-discovery"))
    }

    func testFlashRejectsConfiguredNonDiscoveryProfileWithExitTwo() throws {
        let directory = try CLITemporaryDirectory()
        try ConfigStore(projectDirectory: directory.url).save(.default)

        let result = try runCLI(
            ["flash", "--yes", "--format", "json"],
            in: directory.url,
            environment: ["PATH": "/nonexistent"]
        )

        XCTAssertEqual(result.status, YagartoExitCode.usage.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "flash.unsupported_profile")
        XCTAssertTrue(payload.error.message.contains("arm7tdmi"))
    }

    func testFlashReportsExitSixWithoutOpenOCDWhenUSBEnumerationFindsNoBoard() throws {
        let directory = try CLITemporaryDirectory()
        let prefix = directory.url.appendingPathComponent("openocd-prefix", isDirectory: true)
        let openOCD = prefix.appendingPathComponent("bin/openocd")
        let openOCDMarker = directory.url.appendingPathComponent("openocd-executed")
        try writeExecutable(
            "#!/bin/sh\n: > \"$YAGARTO_OPENOCD_MARKER\"\nexit 1\n",
            to: openOCD
        )
        let profiler = prefix.appendingPathComponent("bin/system_profiler")
        try writeExecutable(
            "#!/bin/sh\nprintf '{\"SPUSBDataType\":[]}'\n",
            to: profiler
        )
        let board = prefix.appendingPathComponent(
            "share/openocd/scripts/board/stm32f4discovery.cfg"
        )
        try FileManager.default.createDirectory(
            at: board.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# fake board config\n".utf8).write(to: board)

        let result = try runCLI(
            [
                "flash", "固件 文件.elf",
                "--profile", "stm32f4-discovery",
                "--yes",
                "--format", "json"
            ],
            in: directory.url,
            environment: [
                "PATH": "\(prefix.appendingPathComponent("bin").path):/usr/bin:/bin",
                "YAGARTO_MAC_SYSTEM_PROFILER": profiler.path,
                "YAGARTO_OPENOCD_MARKER": openOCDMarker.path
            ]
        )

        XCTAssertEqual(result.status, YagartoExitCode.unsupported.rawValue)
        let payload = try decodeErrorEnvelope(result.stderr)
        XCTAssertEqual(payload.error.code, "flash.board_not_found")
        XCTAssertTrue(payload.error.message.contains("STM32F4 Discovery"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openOCDMarker.path))
    }

    func testFlashSuccessProbesThenProgramsWithSafeArgumentsAndJSONOutput() throws {
        let directory = try CLITemporaryDirectory()
        let prefix = directory.url.appendingPathComponent("successful-openocd", isDirectory: true)
        let openOCD = prefix.appendingPathComponent("bin/openocd")
        try writeExecutable(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$YAGARTO_TEST_OPENOCD_LOG\"\nexit 0\n",
            to: openOCD
        )
        let board = prefix.appendingPathComponent(
            "share/openocd/scripts/board/stm32f4discovery.cfg"
        )
        try FileManager.default.createDirectory(
            at: board.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# fake board config\n".utf8).write(to: board)
        let log = directory.url.appendingPathComponent("openocd-arguments.log")
        let profiler = prefix.appendingPathComponent("bin/system_profiler")
        try writeExecutable(
            "#!/bin/sh\nprintf '{\"SPUSBDataType\":[{\"vendor_id\":\"0x0483\",\"product_id\":\"0x374b\"}]}'\n",
            to: profiler
        )

        let result = try runCLI(
            [
                "flash", "固件; shutdown.elf",
                "--profile", "stm32f4-discovery",
                "--yes",
                "--format", "json"
            ],
            in: directory.url,
            environment: [
                "PATH": "\(prefix.appendingPathComponent("bin").path):/usr/bin:/bin",
                "YAGARTO_TEST_OPENOCD_LOG": log.path,
                "YAGARTO_MAC_SYSTEM_PROFILER": profiler.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["status"] as? String, "ok")
        XCTAssertEqual(payload["profile"] as? String, "stm32f4-discovery")
        XCTAssertTrue((payload["elf"] as? String)?.hasSuffix("/固件; shutdown.elf") == true)
        let arguments = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(arguments.contains("\ninit\n"))
        XCTAssertTrue(arguments.contains("\nshutdown\n"))
        XCTAssertTrue(arguments.contains("program {"))
        XCTAssertTrue(arguments.contains("固件; shutdown.elf} verify reset exit"))
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

    func testCortexBuildWithOnlyPreprocessedSourceResolvesStartupAssemblerAndReportsArtifact() throws {
        let directory = try CLITemporaryDirectory()
        try Data(".global user_main\nuser_main:\n  bx lr\n".utf8).write(
            to: directory.url.appendingPathComponent("demo.S")
        )
        try ConfigStore(projectDirectory: directory.url).save(ProjectConfiguration(
            profile: .cortexM4,
            entry: "user_main",
            sources: ["demo.S"],
            outputName: "firmware"
        ))
        let tools = directory.url.appendingPathComponent("build-tools", isDirectory: true)
        let producingTool = """
        #!/bin/sh
        name=${0##*/}
        previous=
        last=
        for argument in "$@"; do
            case "$previous" in
                -o|-Map) : > "$argument" ;;
            esac
            previous=$argument
            last=$argument
        done
        case "$name" in
            *objcopy) : > "$last" ;;
            *objdump) printf 'listing\n' ;;
        esac
        exit 0
        """
        for tool in [
            "arm-none-eabi-as", "arm-none-eabi-gcc", "arm-none-eabi-ld",
            "arm-none-eabi-objcopy", "arm-none-eabi-objdump"
        ] {
            try writeExecutable(producingTool, to: tools.appendingPathComponent(tool))
        }

        let result = try runCLI(
            ["build", "--format", "json"],
            in: directory.url,
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let artifacts = try XCTUnwrap(payload["artifacts"] as? [String])
        XCTAssertTrue(artifacts.contains(where: { $0.hasSuffix("/cortex-m4-startup.o") }))
    }

    func testRealBuildAtomicallyReplacesPreexistingMapSymlinkWithoutChangingVictim() throws {
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

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)))
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "不可修改")
        let mapAttributes = try FileManager.default.attributesOfItem(
            atPath: outputDirectory.appendingPathComponent("firmware.map").path
        )
        XCTAssertEqual(mapAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((mapAttributes[.referenceCount] as? NSNumber)?.intValue, 1)
        let objectFiles = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "o" }
        XCTAssertEqual(objectFiles.count, 1)
    }

    func testConcurrentSameProfileCLIBuildWaitsWithoutRemovingActiveStaging() throws {
        let fixture = try ConcurrentBuildFixture(profile: .arm7tdmi)
        defer { fixture.cleanup() }
        let first = try RunningCLIProcess(
            arguments: ["build", "--format", "json"],
            directory: fixture.directory,
            environment: fixture.environment
        )
        defer { first.cleanup() }
        XCTAssertTrue(fixture.waitForFirstAssembler())
        let activeStaging = try XCTUnwrap(fixture.stagingDirectories(profile: .arm7tdmi).first)

        let second = try RunningCLIProcess(
            arguments: ["build", "--format", "json"],
            directory: fixture.directory,
            environment: fixture.environment
        )
        defer { second.cleanup() }
        Thread.sleep(forTimeInterval: 0.35)

        XCTAssertTrue(second.isRunning, "同 profile 的第二个 CLI 应阻塞等待锁")
        XCTAssertEqual(fixture.assemblerInvocationCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: activeStaging.path),
            "等待者不得把持锁构建的 staging 当作残留删除"
        )

        fixture.releaseAssembler()
        let firstResult = try first.waitForExit()
        let secondResult = try second.waitForExit()
        XCTAssertEqual(firstResult.status, 0, firstResult.stderr)
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
    }

    func testConcurrentDifferentProfileCLIBuildsDoNotShareOneGlobalLock() throws {
        let fixture = try ConcurrentBuildFixture(profile: .arm7tdmi)
        defer { fixture.cleanup() }
        let first = try RunningCLIProcess(
            arguments: ["build", "--format", "json"],
            directory: fixture.directory,
            environment: fixture.environment
        )
        defer { first.cleanup() }
        XCTAssertTrue(fixture.waitForFirstAssembler())

        try fixture.saveConfiguration(profile: .cortexM4)
        let second = try RunningCLIProcess(
            arguments: ["build", "--format", "json"],
            directory: fixture.directory,
            environment: fixture.environment
        )
        defer { second.cleanup() }
        XCTAssertTrue(
            waitUntil(timeout: 2) { fixture.assemblerInvocationCount >= 2 },
            "不同 profile 构建必须能在第一个 profile 暂停时进入工具阶段"
        )

        fixture.releaseAssembler()
        let firstResult = try first.waitForExit()
        let secondResult = try second.waitForExit()
        XCTAssertEqual(firstResult.status, 0, firstResult.stderr)
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
    }

    func testTerminatedBuildCLIReleasesProfileLockWithoutLeakingItToAssembler() throws {
        let fixture = try ConcurrentBuildFixture(profile: .arm7tdmi)
        defer { fixture.cleanup() }
        let first = try RunningCLIProcess(
            arguments: ["build", "--format", "json"],
            directory: fixture.directory,
            environment: fixture.environment
        )
        defer { first.cleanup() }
        XCTAssertTrue(fixture.waitForFirstAssembler())
        XCTAssertEqual(Darwin.kill(first.processIdentifier, SIGTERM), 0)
        XCTAssertTrue(waitUntil(timeout: 2) { !first.isRunning })
        _ = try first.waitForExit()

        let second = try RunningCLIProcess(
            arguments: ["build", "--format", "json"],
            directory: fixture.directory,
            environment: fixture.environment
        )
        defer { second.cleanup() }
        XCTAssertTrue(
            waitUntil(timeout: 2) { fixture.assemblerInvocationCount >= 2 },
            "CLI 被信号终止后，assembler 不得继承锁 FD"
        )

        fixture.releaseAssembler()
        let secondResult = try second.waitForExit()
        XCTAssertEqual(secondResult.status, 0, secondResult.stderr)
        XCTAssertTrue(
            waitUntil(timeout: 2) { fixture.assemblerPIDs.allSatisfy(processHasExited) },
            "信号测试的 assembler fixture 未退出"
        )
    }
}

private struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct SignalledCLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let descendantPIDs: [pid_t]
}

private final class RunningCLIProcess {
    private let process = Process()
    private let captureDirectory: URL
    private let stdoutURL: URL
    private let stderrURL: URL
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var handlesClosed = false

    init(
        arguments: [String],
        directory: URL,
        environment: [String: String]
    ) throws {
        captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        stdoutURL = captureDirectory.appendingPathComponent("stdout")
        stderrURL = captureDirectory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.executableURL = cliExecutableURL()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: pid_t { process.processIdentifier }

    func waitForExit(timeout: TimeInterval = 8) throws -> CLIResult {
        guard waitUntil(timeout: timeout, condition: { !process.isRunning }) else {
            throw YagartoError.internalFailure("等待并发 build CLI 退出超时。")
        }
        process.waitUntilExit()
        try closeHandles()
        return CLIResult(
            status: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }

    func cleanup() {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? closeHandles()
        try? FileManager.default.removeItem(at: captureDirectory)
    }

    private func closeHandles() throws {
        guard !handlesClosed else { return }
        try stdoutHandle.close()
        try stderrHandle.close()
        handlesClosed = true
    }
}

private final class ConcurrentBuildFixture {
    let directory: URL
    private let tools: URL
    private let calls: URL
    private let claim: URL
    private let started: URL
    private let release: URL

    init(profile: ProfileID) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("concurrent-build-\(UUID().uuidString)", isDirectory: true)
        tools = directory.appendingPathComponent("tools", isDirectory: true)
        calls = directory.appendingPathComponent("assembler-calls", isDirectory: true)
        claim = directory.appendingPathComponent("assembler-claim", isDirectory: true)
        started = directory.appendingPathComponent("assembler-started")
        release = directory.appendingPathComponent("assembler-release")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: calls, withIntermediateDirectories: true)
        try Data(".text\n.global user_main\nuser_main:\n  bx lr\n".utf8).write(
            to: directory.appendingPathComponent("demo.s")
        )
        try saveConfiguration(profile: profile)

        let tool = """
        #!/bin/sh
        name=${0##*/}
        if [ "$name" = "arm-none-eabi-as" ] || [ "$name" = "arm-none-eabi-gcc" ]; then
            : > "$YAGARTO_BUILD_CALLS/call-$$"
            if /bin/mkdir "$YAGARTO_BUILD_CLAIM" 2>/dev/null; then
                : > "$YAGARTO_BUILD_STARTED"
                while [ ! -f "$YAGARTO_BUILD_RELEASE" ]; do
                    /bin/sleep 0.02
                done
            fi
        fi
        previous=
        last=
        for argument in "$@"; do
            case "$previous" in
                -o|-Map) : > "$argument" ;;
            esac
            previous=$argument
            last=$argument
        done
        case "$name" in
            *objcopy) : > "$last" ;;
            *objdump) printf 'listing\n' ;;
        esac
        exit 0
        """
        for name in [
            "arm-none-eabi-as", "arm-none-eabi-gcc", "arm-none-eabi-ld",
            "arm-none-eabi-objcopy", "arm-none-eabi-objdump"
        ] {
            try writeExecutable(tool, to: tools.appendingPathComponent(name))
        }
    }

    var environment: [String: String] {
        [
            "PATH": "\(tools.path):/usr/bin:/bin",
            "YAGARTO_BUILD_CALLS": calls.path,
            "YAGARTO_BUILD_CLAIM": claim.path,
            "YAGARTO_BUILD_STARTED": started.path,
            "YAGARTO_BUILD_RELEASE": release.path
        ]
    }

    var assemblerInvocationCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: calls.path).count) ?? 0
    }

    var assemblerPIDs: [pid_t] {
        ((try? FileManager.default.contentsOfDirectory(atPath: calls.path)) ?? [])
            .compactMap { name in
                guard name.hasPrefix("call-") else { return nil }
                return pid_t(name.dropFirst("call-".count))
            }
    }

    func waitForFirstAssembler() -> Bool {
        waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: started.path)
        }
    }

    func releaseAssembler() {
        FileManager.default.createFile(atPath: release.path, contents: Data())
    }

    func saveConfiguration(profile: ProfileID) throws {
        try ConfigStore(projectDirectory: directory).save(ProjectConfiguration(
            profile: profile,
            entry: "user_main",
            sources: ["demo.s"],
            outputName: "firmware"
        ))
    }

    func stagingDirectories(profile: ProfileID) throws -> [URL] {
        let buildRoot = directory.appendingPathComponent(".yagarto/build", isDirectory: true)
        let prefix = ".\(profile.rawValue)-staging-"
        return try FileManager.default.contentsOfDirectory(
            at: buildRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func cleanup() {
        releaseAssembler()
        for pid in assemblerPIDs where !processHasExited(pid) {
            _ = Darwin.kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct CLIErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
        let details: String?
        let toolOutput: String?
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

private func runCLI(
    _ arguments: [String],
    in directory: URL,
    environment: [String: String] = [:]
) throws -> CLIResult {
    try runCapturedProcess(
        executable: cliExecutableURL(),
        arguments: arguments,
        in: directory,
        environment: environment
    )
}

private func runCapturedProcess(
    executable: URL,
    arguments: [String],
    in directory: URL,
    environment: [String: String] = [:]
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
    var isolatedEnvironment = ProcessInfo.processInfo.environment
    isolatedEnvironment["HOME"] = directory.path
    process.environment = isolatedEnvironment.merging(
        environment,
        uniquingKeysWith: { _, override in override }
    )
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

private func runCLIAndSendSignal(
    _ arguments: [String],
    in directory: URL,
    environment: [String: String],
    signal: Int32,
    pidFile: URL
) throws -> SignalledCLIResult {
    let captureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: captureDirectory) }
    let stdoutURL = captureDirectory.appendingPathComponent("stdout")
    let stderrURL = captureDirectory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)

    let process = Process()
    process.executableURL = cliExecutableURL()
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.merging(
        environment,
        uniquingKeysWith: { _, override in override }
    )
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    var descendants: [pid_t] = []
    defer {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        for pid in descendants where !processHasExited(pid) {
            Darwin.kill(pid, SIGKILL)
        }
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    try process.run()
    guard waitUntil(timeout: 5, condition: {
        FileManager.default.fileExists(atPath: pidFile.path)
    }) else {
        throw YagartoError.internalFailure("等待受控子进程 PID 超时。")
    }
    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
    descendants = pidText.split(whereSeparator: \.isWhitespace).compactMap {
        pid_t($0)
    }
    guard descendants.count == 2 else {
        throw YagartoError.internalFailure("受控子进程未记录完整 PID。")
    }

    XCTAssertEqual(Darwin.kill(process.processIdentifier, signal), 0)
    guard waitUntil(timeout: 5, condition: { !process.isRunning }) else {
        throw YagartoError.internalFailure("CLI 收到信号后未及时退出。")
    }
    process.waitUntilExit()
    _ = waitUntil(timeout: 2, condition: {
        descendants.allSatisfy(processHasExited)
    })
    try stdoutHandle.close()
    try stderrHandle.close()
    return SignalledCLIResult(
        status: process.terminationStatus,
        stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self),
        descendantPIDs: descendants
    )
}

private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func processHasExited(_ pid: pid_t) -> Bool {
    errno = 0
    return Darwin.kill(pid, 0) == -1 && errno == ESRCH
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
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

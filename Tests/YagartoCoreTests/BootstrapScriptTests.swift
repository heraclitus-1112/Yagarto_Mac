// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Darwin
import XCTest
@testable import YagartoCore

final class BootstrapScriptTests: XCTestCase {
    func testHelpDocumentsRequiredPrefixChecksumAndFixedGDBRelease() throws {
        let result = try runBootstrap(["--help"])

        XCTAssertEqual(result.exitStatus, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("--prefix"))
        XCTAssertTrue(result.stdout.contains("--sha256"))
        XCTAssertTrue(result.stdout.contains("gdb-15.2.tar.xz"))
        XCTAssertTrue(result.stdout.contains("ftp.gnu.org/gnu/gdb"))
    }

    func testMissingPrefixIsRejectedAsUsageError() throws {
        let result = try runBootstrap([])

        XCTAssertEqual(result.exitStatus, 2)
        XCTAssertTrue(result.stderr.contains("--prefix"))
    }

    func testMissingChecksumIsRejectedInsteadOfSilentlySkippingVerification() throws {
        let result = try runBootstrap(["--prefix", "/tmp/yagarto-gdb"])

        XCTAssertEqual(result.exitStatus, 2)
        XCTAssertTrue(result.stderr.contains("--sha256"))
    }

    func testMalformedChecksumIsRejectedBeforeDownloadOrDependencyChecks() throws {
        let result = try runBootstrap([
            "--prefix", "/tmp/yagarto-gdb",
            "--sha256", "xyz"
        ])

        XCTAssertEqual(result.exitStatus, 2)
        XCTAssertTrue(result.stderr.contains("64"))
        XCTAssertTrue(result.stderr.localizedCaseInsensitiveContains("sha-256"))
    }

    func testCanonicalRootPrefixVariantsAreRejectedBeforeArchiveAccess() throws {
        for prefix in ["/.", "//", "/definitely-yagarto-prefix/.."] {
            let result = try runBootstrap([
                "--prefix", prefix,
                "--sha256", String(repeating: "0", count: 64),
                "--archive", "/definitely/missing/gdb-15.2.tar.xz"
            ])

            XCTAssertEqual(result.exitStatus, 2, "未拒绝 prefix：\(prefix)")
            XCTAssertTrue(result.stderr.contains("根目录"), "诊断不明确：\(prefix)")
        }
    }

    func testLocalArchiveChecksumMismatchStopsBeforeExtractionOrCompilation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("gdb-15.2.tar.xz")
        try Data("not a gdb archive".utf8).write(to: archive)

        let result = try runBootstrap([
            "--prefix", directory.appendingPathComponent("install").path,
            "--sha256", String(repeating: "0", count: 64),
            "--archive", archive.path
        ])

        XCTAssertEqual(result.exitStatus, 1)
        XCTAssertTrue(result.stderr.contains("SHA-256 校验失败"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("install").path
        ))
    }

    func testLocalArchiveUsesOnePrivateVerifiedSnapshotForHashAndExtraction() throws {
        for sourceKind in BootstrapArchiveSnapshotFixture.SourceKind.allCases {
            let fixture = try BootstrapArchiveSnapshotFixture(sourceKind: sourceKind)
            defer { fixture.cleanup() }

            let result = try runBootstrap(
                [
                    "--prefix", fixture.installPrefix.path,
                    "--sha256", String(repeating: "0", count: 64),
                    "--archive", fixture.archive.path
                ],
                environment: fixture.environment
            )

            XCTAssertEqual(result.exitStatus, 0, "\(sourceKind): \(result.stderr)")
            let hashedPath = try String(contentsOf: fixture.hashedPathLog, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let extractedPath = try String(contentsOf: fixture.extractedPathLog, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(hashedPath, extractedPath, "\(sourceKind)")
            XCTAssertNotEqual(hashedPath, fixture.archive.path, "\(sourceKind)")
            XCTAssertTrue(hashedPath.contains("yagarto-gdb."), "\(sourceKind): \(hashedPath)")
            XCTAssertEqual(
                try String(contentsOf: fixture.extractedContentsLog, encoding: .utf8),
                "verified snapshot\n",
                "\(sourceKind) 解压必须使用校验过的私有快照"
            )
            XCTAssertEqual(
                try String(contentsOf: fixture.snapshotModeLog, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                "700",
                "\(sourceKind) 工作目录必须仅当前用户可访问"
            )
            XCTAssertEqual(
                try String(contentsOf: fixture.archive, encoding: .utf8),
                "replacement after hash\n",
                "测试必须确实在 hash 后替换调用者归档"
            )
            let configureArguments = try String(
                contentsOf: fixture.configureArgumentsLog,
                encoding: .utf8
            )
            XCTAssertTrue(
                configureArguments.contains("--with-gmp=/fixture/gmp"),
                "GMP prefix 必须显式传给顶层 configure：\(configureArguments)"
            )
            XCTAssertTrue(
                configureArguments.contains("--with-mpfr=/fixture/mpfr"),
                "MPFR prefix 必须显式传给顶层 configure：\(configureArguments)"
            )
            XCTAssertTrue(
                configureArguments.contains("gdb_cv_readline_ok=yes"),
                "Readline 能力缓存必须作为参数传入递归 configure：\(configureArguments)"
            )
        }
    }

    func testDarwinBuildRejectsMissingGNUCompilerInsteadOfFallingBackToClang() throws {
        let fixture = try BootstrapArchiveSnapshotFixture(
            sourceKind: .regular,
            includeGNUCompiler: false
        )
        defer { fixture.cleanup() }

        let result = try runBootstrap(
            [
                "--prefix", fixture.installPrefix.path,
                "--sha256", String(repeating: "0", count: 64),
                "--archive", fixture.archive.path
            ],
            environment: fixture.environment
        )

        XCTAssertEqual(result.exitStatus, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("GNU GCC"), result.stderr)
        XCTAssertTrue(result.stderr.contains("brew install gcc@15"), result.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.configureArgumentsLog.path),
            "缺少 GNU GCC 时不应进入 configure"
        )
    }

    func testDarwinBuildRejectsExplicitAppleClangOverride() throws {
        let fixture = try BootstrapArchiveSnapshotFixture(
            sourceKind: .regular,
            includeGNUCompiler: false
        )
        defer { fixture.cleanup() }
        var environment = fixture.environment
        environment["CC"] = "/usr/bin/cc"
        environment["CXX"] = "/usr/bin/c++"

        let result = try runBootstrap(
            [
                "--prefix", fixture.installPrefix.path,
                "--sha256", String(repeating: "0", count: 64),
                "--archive", fixture.archive.path
            ],
            environment: environment
        )

        XCTAssertEqual(result.exitStatus, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("不是 GNU GCC"), result.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.configureArgumentsLog.path),
            "显式传入 Apple Clang 时不应进入 configure"
        )
    }

    func testDarwinBuildRejectsGNUCompilerWithWrongMajorVersion() throws {
        let fixture = try BootstrapArchiveSnapshotFixture(
            sourceKind: .regular,
            includeGNUCompiler: false
        )
        defer { fixture.cleanup() }
        let gcc16 = fixture.tools.appendingPathComponent("gcc-16")
        let gxx16 = fixture.tools.appendingPathComponent("g++-16")
        for compiler in [gcc16, gxx16] {
            try writeBootstrapExecutable(
                "#!/bin/sh\ncase \"$1\" in -dumpfullversion) printf '16.2.0\\n' ;; *) printf 'gcc-16 (Homebrew GCC 16.2.0) 16.2.0\\n' ;; esac\n",
                to: compiler
            )
        }
        var environment = fixture.environment
        environment["CC"] = gcc16.path
        environment["CXX"] = gxx16.path

        let result = try runBootstrap(
            [
                "--prefix", fixture.installPrefix.path,
                "--sha256", String(repeating: "0", count: 64),
                "--archive", fixture.archive.path
            ],
            environment: environment
        )

        XCTAssertEqual(result.exitStatus, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("主版本必须为 15"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configureArgumentsLog.path))
    }

    func testDarwinBuildDiscoversKegOnlyGCC15UsingHomebrewPrefix() throws {
        let fixture = try BootstrapArchiveSnapshotFixture(
            sourceKind: .regular,
            includeGNUCompiler: false,
            includeKegOnlyGNUCompiler: true
        )
        defer { fixture.cleanup() }

        let result = try runBootstrap(
            [
                "--prefix", fixture.installPrefix.path,
                "--sha256", String(repeating: "0", count: 64),
                "--archive", fixture.archive.path
            ],
            environment: fixture.environment
        )

        XCTAssertEqual(result.exitStatus, 0, result.stderr)
    }

    func testLocalArchiveSnapshotCopyFailureStopsBeforeHashAndExtraction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-copy-failure-\(UUID().uuidString)", isDirectory: true)
        let tools = directory.appendingPathComponent("tools", isDirectory: true)
        let archive = directory.appendingPathComponent("gdb-15.2.tar.xz")
        let copyMarker = directory.appendingPathComponent("copy-called")
        let downstreamMarker = directory.appendingPathComponent("downstream-called")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("archive\n".utf8).write(to: archive)
        try writeBootstrapExecutable(
            "#!/bin/sh\n: > \"$YAGARTO_COPY_MARKER\"\nexit 37\n",
            to: tools.appendingPathComponent("cp")
        )
        for tool in ["shasum", "tar"] {
            try writeBootstrapExecutable(
                "#!/bin/sh\n: > \"$YAGARTO_DOWNSTREAM_MARKER\"\nexit 1\n",
                to: tools.appendingPathComponent(tool)
            )
        }

        let result = try runBootstrap(
            [
                "--prefix", directory.appendingPathComponent("install").path,
                "--sha256", String(repeating: "0", count: 64),
                "--archive", archive.path
            ],
            environment: [
                "PATH": "\(tools.path):/usr/bin:/bin",
                "YAGARTO_COPY_MARKER": copyMarker.path,
                "YAGARTO_DOWNSTREAM_MARKER": downstreamMarker.path
            ]
        )

        XCTAssertEqual(result.exitStatus, 1)
        XCTAssertTrue(result.stderr.contains("归档快照"), result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downstreamMarker.path))
    }

    func testScriptKeepsSimulatorBuildAndPostInstallVerificationContract() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        for dependency in ["gmake", "gmp", "mpfr", "makeinfo"] {
            XCTAssertTrue(script.contains(dependency), "脚本缺少依赖检查：\(dependency)")
        }
        XCTAssertTrue(script.contains("gcc-15"))
        XCTAssertTrue(script.contains("g++-15"))
        XCTAssertTrue(script.contains("CC=\"$GDB_CC\" CXX=\"$GDB_CXX\""))
        XCTAssertTrue(script.contains("gdb-15.2-macos26.patch"))
        XCTAssertTrue(script.contains("run_supervised apply_compatibility_patch"))
        XCTAssertTrue(script.contains("SED=\"$GDB_SED\""))
        XCTAssertTrue(script.contains("$(uname -s 2>/dev/null || true)"))
        XCTAssertTrue(script.contains("command -v gsed"))
        XCTAssertTrue(script.contains("BUILD_PATH=\"${COMPAT_TOOL_DIRECTORY}:${PATH}\""))
        XCTAssertTrue(script.contains("PATH=\"$BUILD_PATH\""))
        XCTAssertTrue(script.contains("export PATH"))
        XCTAssertTrue(script.contains("export gdb_cv_readline_ok"))
        XCTAssertTrue(script.contains("CPPFLAGS=\"$GDB_CPPFLAGS\""))
        XCTAssertTrue(script.contains("export CPPFLAGS LDFLAGS"))
        XCTAssertTrue(script.contains("--target=arm-none-eabi"))
        XCTAssertTrue(script.contains("--with-system-zlib"))
        XCTAssertTrue(script.contains("--with-system-readline"))
        XCTAssertTrue(script.contains("gdb_cv_readline_ok=yes"))
        XCTAssertTrue(script.contains("RL_VERSION_MAJOR"))
        XCTAssertTrue(script.contains("Readline 7"))
        XCTAssertFalse(script.contains("--disable-sim"))
        XCTAssertTrue(script.contains("-ex \"target sim\""))
        XCTAssertTrue(script.contains("arm-none-eabi-gdb-sim"))
        XCTAssertTrue(script.contains("trap cleanup EXIT"))
        XCTAssertFalse(script.contains("trap cleanup EXIT HUP INT TERM"))
        XCTAssertTrue(script.contains("run_supervised configure_gdb"))
        XCTAssertTrue(script.contains("run_supervised gmake -C \"$BUILD_DIRECTORY\" -j"))
        XCTAssertTrue(script.contains("run_supervised gmake -C \"$BUILD_DIRECTORY\" install"))
        XCTAssertTrue(script.contains("run_supervised_with_timeout \"$verify_timeout\" run_gdb_selftest"))
        for invocation in [
            "run_supervised calculate_archive_checksum",
            "run_supervised pkg-config --exists gmp",
            "run_supervised pkg-config --exists mpfr",
            "run_supervised brew --prefix gmp",
            "run_supervised brew --prefix mpfr",
            "run_supervised curl --fail",
            "run_supervised tar -xf",
            "run_supervised sysctl -n hw.logicalcpu",
            "run_supervised ln -sf"
        ] {
            XCTAssertTrue(script.contains(invocation), "未受控：\(invocation)")
        }
        XCTAssertFalse(script.contains("ACTUAL_SHA256=$(shasum"))
        XCTAssertFalse(script.contains("ACTUAL_SHA256=$(sha256sum"))
    }

    func testMacOSCompatibilityPatchOnlyCorrectsFunctionPointerTypes() throws {
        let patchURL = repositoryRoot
            .appendingPathComponent("scripts/patches/gdb-15.2-macos26.patch")
        let patch = try String(contentsOf: patchURL, encoding: .utf8)

        XCTAssertTrue(patch.contains("RETSIGTYPE (*prev_sigint) (int);"))
        XCTAssertTrue(patch.contains("RETSIGTYPE (*prev_sigint) ();"))
        XCTAssertTrue(patch.contains("RETSIGTYPE (*orig) (int);"))
        XCTAssertTrue(patch.contains("RETSIGTYPE (*orig) ();"))
        XCTAssertTrue(patch.contains("unsigned (*func) (ARMul_State *)"))
        XCTAssertTrue(patch.contains("unsigned (*func) ()"))
        XCTAssertFalse(patch.contains("sim_resume"))
    }

    func testVerifyInstalledGDBRunsCompleteARM7SimulatorContractWithoutBuilding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = directory.appendingPathComponent("tools", isDirectory: true)
        let toolStub = """
        #!/bin/sh
        output=
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then
                output=$2
                shift 2
            else
                shift
            fi
        done
        : > "$output"
        """
        try writeBootstrapExecutable(
            toolStub,
            to: tools.appendingPathComponent("arm-none-eabi-as")
        )
        try writeBootstrapExecutable(
            toolStub,
            to: tools.appendingPathComponent("arm-none-eabi-ld")
        )
        let gdbLog = directory.appendingPathComponent("gdb-arguments.log")
        let gdb = tools.appendingPathComponent("arm-none-eabi-gdb")
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            printf '%s\n' "$@" > "$YAGARTO_GDB_ARGUMENT_LOG"
            for register in r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc cpsr; do
                if [ "$register" = "r0" ]; then
                    printf 'r0 0x1\n'
                else
                    printf '%s 0x0\n' "$register"
                fi
            done
            exit 0
            """,
            to: gdb
        )

        let result = try runBootstrap(
            ["--verify-gdb", gdb.path],
            environment: [
                "PATH": "\(tools.path):/usr/bin:/bin",
                "YAGARTO_GDB_ARGUMENT_LOG": gdbLog.path
            ]
        )

        XCTAssertEqual(result.exitStatus, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("完整 ARM7 simulator 自测通过"))
        let arguments = try String(contentsOf: gdbLog, encoding: .utf8)
        for command in [
            "file selftest.elf",
            "target sim",
            "load",
            "break _start",
            "run",
            "stepi",
            "info registers r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc cpsr"
        ] {
            XCTAssertTrue(arguments.contains(command), "GDB 自测缺少：\(command)")
        }
    }

    func testVerifyInstalledGDBRejectsSimulatorThatDidNotExecuteFirstInstruction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = directory.appendingPathComponent("tools", isDirectory: true)
        let toolStub = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then
                : > "$2"
                exit 0
            fi
            shift
        done
        exit 1
        """
        try writeBootstrapExecutable(
            toolStub,
            to: tools.appendingPathComponent("arm-none-eabi-as")
        )
        try writeBootstrapExecutable(
            toolStub,
            to: tools.appendingPathComponent("arm-none-eabi-ld")
        )
        let gdb = tools.appendingPathComponent("arm-none-eabi-gdb")
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            for register in r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc cpsr; do
                printf '%s 0x0\n' "$register"
            done
            exit 0
            """,
            to: gdb
        )

        let result = try runBootstrap(
            ["--verify-gdb", gdb.path],
            environment: ["PATH": "\(tools.path):/usr/bin:/bin"]
        )

        XCTAssertEqual(result.exitStatus, 1)
        XCTAssertFalse(result.stdout.contains("完整 ARM7 simulator 自测通过"))
        XCTAssertTrue(result.stderr.contains("r0"))
    }

    func testVerifyGDBForwardsAndEscalatesSignalsWithoutLeavingDescendants() throws {
        let cases: [(signal: Int32, expectedStatus: Int32, name: String)] = [
            (SIGHUP, 128 + SIGHUP, "SIGHUP"),
            (SIGINT, 128 + SIGINT, "SIGINT"),
            (SIGTERM, 128 + SIGTERM, "SIGTERM")
        ]

        for testCase in cases {
            let fixture = try BootstrapSignalFixture(name: testCase.name)
            defer { fixture.cleanup() }
            let result = try runBootstrapAndSendSignal(
                ["--verify-gdb", fixture.gdb.path],
                environment: fixture.environment,
                signal: testCase.signal,
                pidFile: fixture.pidFile
            )

            XCTAssertFalse(result.watchdogFired, testCase.name)
            XCTAssertEqual(result.process.exitStatus, testCase.expectedStatus, testCase.name)
            XCTAssertLessThan(result.elapsed, 3, testCase.name)
            XCTAssertFalse(result.process.stderr.contains("sed:"), result.process.stderr)
            XCTAssertTrue(
                result.descendantsExitedBeforeCleanup,
                "\(testCase.name) 留下后代：\(result.descendantPIDs)"
            )
        }
    }

    func testArchiveChecksumForwardsAndEscalatesSignalsWithoutLeavingDescendants() throws {
        let cases: [(signal: Int32, expectedStatus: Int32, name: String)] = [
            (SIGHUP, 128 + SIGHUP, "SIGHUP"),
            (SIGINT, 128 + SIGINT, "SIGINT"),
            (SIGTERM, 128 + SIGTERM, "SIGTERM")
        ]

        for testCase in cases {
            let fixture = try BootstrapChecksumSignalFixture(name: testCase.name)
            defer { fixture.cleanup() }
            let result = try runBootstrapAndSendSignal(
                [
                    "--prefix", fixture.installPrefix.path,
                    "--sha256", String(repeating: "0", count: 64),
                    "--archive", fixture.archive.path
                ],
                environment: fixture.environment,
                signal: testCase.signal,
                pidFile: fixture.pidFile
            )

            XCTAssertFalse(result.watchdogFired, testCase.name)
            XCTAssertEqual(result.process.exitStatus, testCase.expectedStatus, testCase.name)
            XCTAssertLessThan(result.elapsed, 3, testCase.name)
            XCTAssertTrue(
                result.descendantsExitedBeforeCleanup,
                "hash \(testCase.name) 留下后代：\(result.descendantPIDs)"
            )
        }
    }

    func testLaunchAccountingGapQueuesAndReapsEachTerminationSignal() throws {
        let cases: [(signalName: String, expectedStatus: Int32)] = [
            ("HUP", 128 + SIGHUP),
            ("INT", 128 + SIGINT),
            ("TERM", 128 + SIGTERM)
        ]

        for testCase in cases {
            let fixture = try BootstrapLaunchGapFixture(signalName: testCase.signalName)
            defer { fixture.cleanup() }
            let result = try runBootstrapUntilExit(
                [
                    "--prefix", fixture.installPrefix.path,
                    "--sha256", String(repeating: "0", count: 64),
                    "--archive", fixture.archive.path
                ],
                environment: fixture.environment,
                pidFile: fixture.pidFile,
                watchdogSeconds: 4
            )

            XCTAssertFalse(result.watchdogFired, testCase.signalName)
            XCTAssertEqual(
                result.process.exitStatus,
                testCase.expectedStatus,
                "\(testCase.signalName): \(result.process.stderr)"
            )
            XCTAssertLessThan(result.elapsed, 3, testCase.signalName)
            XCTAssertTrue(
                result.descendantsExitedBeforeCleanup,
                "launch gap \(testCase.signalName) 留下后代：\(result.descendantPIDs)"
            )
        }
    }

    func testVerifyGDBHasExplicitTimeoutAndReapsItsProcessGroup() throws {
        let fixture = try BootstrapSignalFixture(name: "timeout")
        defer { fixture.cleanup() }
        var environment = fixture.environment
        environment["YAGARTO_GDB_VERIFY_TIMEOUT_SECONDS"] = "1"

        let result = try runBootstrapUntilExit(
            ["--verify-gdb", fixture.gdb.path],
            environment: environment,
            pidFile: fixture.pidFile,
            watchdogSeconds: 4
        )

        XCTAssertFalse(result.watchdogFired)
        XCTAssertNotEqual(result.process.exitStatus, 0)
        XCTAssertLessThan(result.elapsed, 3)
        XCTAssertTrue(result.process.stderr.contains("超时"), result.process.stderr)
        XCTAssertFalse(result.process.stderr.contains("sed:"), result.process.stderr)
        XCTAssertTrue(result.descendantsExitedBeforeCleanup)
    }

    private func runBootstrap(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> ProcessResult {
        try ProcessRunner().run(CommandSpec(
            executable: "/usr/bin/env",
            args: ["-i"]
                + isolatedBootstrapEnvironment(environment).map { "\($0.key)=\($0.value)" }
                + ["/bin/sh", scriptURL.path]
                + arguments,
            workingDirectory: repositoryRoot
        ))
    }

    private var scriptURL: URL {
        repositoryRoot.appendingPathComponent("scripts/bootstrap-gdb-sim.sh")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct BootstrapSignalFixture {
    let directory: URL
    let tools: URL
    let gdb: URL
    let pidFile: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-signal-\(name)-\(UUID().uuidString)", isDirectory: true)
        tools = directory.appendingPathComponent("tools", isDirectory: true)
        gdb = tools.appendingPathComponent("arm-none-eabi-gdb")
        pidFile = directory.appendingPathComponent("descendants.txt")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let producer = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then
                : > "$2"
                exit 0
            fi
            shift
        done
        exit 1
        """
        try writeBootstrapExecutable(
            producer,
            to: tools.appendingPathComponent("arm-none-eabi-as")
        )
        try writeBootstrapExecutable(
            producer,
            to: tools.appendingPathComponent("arm-none-eabi-ld")
        )
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            trap '' HUP INT TERM
            /bin/sleep 30 &
            grandchild=$!
            printf '%s %s\n' "$$" "$grandchild" > "$YAGARTO_BOOTSTRAP_PID_FILE"
            wait "$grandchild"
            """,
            to: gdb
        )
    }

    var environment: [String: String] {
        [
            "PATH": "\(tools.path):/usr/bin:/bin",
            "YAGARTO_BOOTSTRAP_PID_FILE": pidFile.path
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct BootstrapChecksumSignalFixture {
    let directory: URL
    let tools: URL
    let archive: URL
    let installPrefix: URL
    let pidFile: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap-hash-\(name)-\(UUID().uuidString)", isDirectory: true)
        tools = directory.appendingPathComponent("tools", isDirectory: true)
        archive = directory.appendingPathComponent("gdb-15.2.tar.xz")
        installPrefix = directory.appendingPathComponent("install", isDirectory: true)
        pidFile = directory.appendingPathComponent("hash-descendants.txt")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data("fixture archive".utf8).write(to: archive)
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            trap '' HUP INT TERM
            /bin/sleep 30 &
            grandchild=$!
            printf '%s %s\n' "$$" "$grandchild" > "$YAGARTO_BOOTSTRAP_PID_FILE"
            wait "$grandchild"
            printf '%064d  %s\n' 0 "$1"
            """,
            to: tools.appendingPathComponent("shasum")
        )
    }

    var environment: [String: String] {
        [
            "PATH": "\(tools.path):/usr/bin:/bin",
            "YAGARTO_BOOTSTRAP_PID_FILE": pidFile.path
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct BootstrapArchiveSnapshotFixture {
    enum SourceKind: String, CaseIterable {
        case regular
        case symbolicLink
    }

    let directory: URL
    let tools: URL
    let archive: URL
    let installPrefix: URL
    let hashedPathLog: URL
    let extractedPathLog: URL
    let extractedContentsLog: URL
    let snapshotModeLog: URL
    let configureArgumentsLog: URL

    init(
        sourceKind: SourceKind,
        includeGNUCompiler: Bool = true,
        includeKegOnlyGNUCompiler: Bool = false
    ) throws {
        var additionalEnvironment: [String: String] = [:]
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bootstrap-snapshot-\(sourceKind.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
        tools = directory.appendingPathComponent("tools", isDirectory: true)
        archive = directory.appendingPathComponent("gdb-15.2.tar.xz")
        installPrefix = directory.appendingPathComponent("install", isDirectory: true)
        hashedPathLog = directory.appendingPathComponent("hashed-path.log")
        extractedPathLog = directory.appendingPathComponent("extracted-path.log")
        extractedContentsLog = directory.appendingPathComponent("extracted-contents.log")
        snapshotModeLog = directory.appendingPathComponent("snapshot-mode.log")
        configureArgumentsLog = directory.appendingPathComponent("configure-arguments.log")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)

        let backingArchive = directory.appendingPathComponent("archive-backing.tar.xz")
        try Data("verified snapshot\n".utf8).write(to: backingArchive)
        switch sourceKind {
        case .regular:
            try FileManager.default.copyItem(at: backingArchive, to: archive)
        case .symbolicLink:
            try FileManager.default.createSymbolicLink(
                atPath: archive.path,
                withDestinationPath: backingArchive.path
            )
        }
        let replacementArchive = directory.appendingPathComponent("replacement.tar.xz")
        try Data("replacement after hash\n".utf8).write(to: replacementArchive)

        let configureTemplate = directory.appendingPathComponent("configure-template")
        try writeBootstrapExecutable(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$YAGARTO_CONFIGURE_ARGUMENTS_LOG\"\n",
            to: configureTemplate
        )
        let gdbTemplate = directory.appendingPathComponent("gdb-template")
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            for register in r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc cpsr; do
                if [ "$register" = "r0" ]; then
                    printf 'r0 0x1\n'
                else
                    printf '%s 0x0\n' "$register"
                fi
            done
            """,
            to: gdbTemplate
        )

        try writeBootstrapExecutable(
            """
            #!/bin/sh
            archive=
            for argument in "$@"; do archive=$argument; done
            printf '%s\n' "$archive" > "$YAGARTO_HASHED_PATH_LOG"
            /usr/bin/stat -f '%Lp' "${archive%/*}" > "$YAGARTO_SNAPSHOT_MODE_LOG"
            /bin/mv "$YAGARTO_REPLACEMENT_ARCHIVE" "$YAGARTO_ORIGINAL_ARCHIVE"
            printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' "$archive"
            """,
            to: tools.appendingPathComponent("shasum")
        )
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            archive=
            destination=
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -xf) archive=$2; shift 2 ;;
                    -C) destination=$2; shift 2 ;;
                    *) shift ;;
                esac
            done
            printf '%s\n' "$archive" > "$YAGARTO_EXTRACTED_PATH_LOG"
            /bin/cat "$archive" > "$YAGARTO_EXTRACTED_CONTENTS_LOG"
            /bin/mkdir -p "$destination/gdb-15.2"
            /bin/cp "$YAGARTO_CONFIGURE_TEMPLATE" "$destination/gdb-15.2/configure"
            """,
            to: tools.appendingPathComponent("tar")
        )
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            for argument in "$@"; do
                if [ "$argument" = "install" ]; then
                    /bin/mkdir -p "$YAGARTO_INSTALL_PREFIX/bin"
                    /bin/cp "$YAGARTO_GDB_TEMPLATE" "$YAGARTO_INSTALL_PREFIX/bin/arm-none-eabi-gdb"
                    /bin/chmod 755 "$YAGARTO_INSTALL_PREFIX/bin/arm-none-eabi-gdb"
                fi
            done
            exit 0
            """,
            to: tools.appendingPathComponent("gmake")
        )
        try writeBootstrapExecutable("#!/bin/sh\nexit 0\n", to: tools.appendingPathComponent("makeinfo"))
        try writeBootstrapExecutable("#!/bin/sh\nexit 0\n", to: tools.appendingPathComponent("patch"))
        try writeBootstrapExecutable("#!/bin/sh\nexec /usr/bin/sed \"$@\"\n", to: tools.appendingPathComponent("gsed"))
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            case "$1" in
                --exists) exit 0 ;;
                --cflags) printf '%s\n' '-I/fixture/gmp/include -I/fixture/mpfr/include' ;;
                --libs-only-L) printf '%s\n' '-L/fixture/gmp/lib -L/fixture/mpfr/lib' ;;
                --modversion) printf '%s\n' '8.3' ;;
                --variable=prefix)
                    case "$2" in
                        gmp) printf '%s\n' /fixture/gmp ;;
                        mpfr) printf '%s\n' /fixture/mpfr ;;
                    esac
                    ;;
            esac
            """,
            to: tools.appendingPathComponent("pkg-config")
        )
        try writeBootstrapExecutable("#!/bin/sh\nprintf '1\\n'\n", to: tools.appendingPathComponent("sysctl"))
        if includeGNUCompiler {
            for compiler in ["gcc-15", "g++-15"] {
                try writeBootstrapExecutable(
                    "#!/bin/sh\ncase \"$1\" in -dumpfullversion) printf '15.2.0\\n' ;; *) printf '%s\\n' 'gcc-15 (Homebrew GCC 15.2.0) 15.2.0' ;; esac\n",
                    to: tools.appendingPathComponent(compiler)
                )
            }
        }
        if includeKegOnlyGNUCompiler {
            let prefix = directory.appendingPathComponent("gcc@15", isDirectory: true)
            for compiler in ["gcc-15", "g++-15"] {
                try writeBootstrapExecutable(
                    "#!/bin/sh\ncase \"$1\" in -dumpfullversion) printf '15.3.0\\n' ;; *) printf '%s\\n' 'gcc-15 (Homebrew GCC 15.3.0) 15.3.0' ;; esac\n",
                    to: prefix.appendingPathComponent("bin/\(compiler)")
                )
            }
            try writeBootstrapExecutable(
                "#!/bin/sh\nif [ \"$1\" = --prefix ] && [ \"$2\" = gcc@15 ]; then printf '%s\\n' \"$YAGARTO_GCC15_PREFIX\"; exit 0; fi\nexit 1\n",
                to: tools.appendingPathComponent("brew")
            )
            additionalEnvironment["YAGARTO_GCC15_PREFIX"] = prefix.path
        }
        let producer = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-o" ]; then
                : > "$2"
                exit 0
            fi
            shift
        done
        exit 1
        """
        try writeBootstrapExecutable(producer, to: tools.appendingPathComponent("arm-none-eabi-as"))
        try writeBootstrapExecutable(producer, to: tools.appendingPathComponent("arm-none-eabi-ld"))

        environment = [
            "PATH": "\(tools.path):/usr/bin:/bin",
            "YAGARTO_ORIGINAL_ARCHIVE": archive.path,
            "YAGARTO_REPLACEMENT_ARCHIVE": replacementArchive.path,
            "YAGARTO_HASHED_PATH_LOG": hashedPathLog.path,
            "YAGARTO_EXTRACTED_PATH_LOG": extractedPathLog.path,
            "YAGARTO_EXTRACTED_CONTENTS_LOG": extractedContentsLog.path,
            "YAGARTO_SNAPSHOT_MODE_LOG": snapshotModeLog.path,
            "YAGARTO_CONFIGURE_ARGUMENTS_LOG": configureArgumentsLog.path,
            "YAGARTO_CONFIGURE_TEMPLATE": configureTemplate.path,
            "YAGARTO_GDB_TEMPLATE": gdbTemplate.path,
            "YAGARTO_INSTALL_PREFIX": installPrefix.path
        ].merging(additionalEnvironment, uniquingKeysWith: { _, override in override })
    }

    let environment: [String: String]

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct BootstrapLaunchGapFixture {
    let directory: URL
    let tools: URL
    let archive: URL
    let installPrefix: URL
    let pidFile: URL
    let signalName: String

    init(signalName: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "bootstrap-launch-gap-\(signalName)-\(UUID().uuidString)",
                isDirectory: true
            )
        tools = directory.appendingPathComponent("tools", isDirectory: true)
        archive = directory.appendingPathComponent("gdb-15.2.tar.xz")
        installPrefix = directory.appendingPathComponent("install", isDirectory: true)
        pidFile = directory.appendingPathComponent("copy-descendants.txt")
        self.signalName = signalName
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data("archive\n".utf8).write(to: archive)
        try writeBootstrapExecutable(
            """
            #!/bin/sh
            trap '' HUP INT TERM
            /bin/sleep 30 &
            grandchild=$!
            printf '%s %s\n' "$$" "$grandchild" > "$YAGARTO_BOOTSTRAP_PID_FILE"
            wait "$grandchild"
            """,
            to: tools.appendingPathComponent("cp")
        )
    }

    var environment: [String: String] {
        [
            "PATH": "\(tools.path):/usr/bin:/bin",
            "YAGARTO_BOOTSTRAP_PID_FILE": pidFile.path,
            "YAGARTO_BOOTSTRAP_TEST_LAUNCH_TARGET": "cp",
            "YAGARTO_BOOTSTRAP_TEST_SIGNAL_DURING_LAUNCH": signalName,
            "YAGARTO_BOOTSTRAP_TEST_LAUNCH_READY_FILE": pidFile.path
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct BootstrapSupervisionResult {
    let process: ProcessResult
    let elapsed: TimeInterval
    let watchdogFired: Bool
    let descendantPIDs: [pid_t]
    let descendantsExitedBeforeCleanup: Bool
}

private func runBootstrapAndSendSignal(
    _ arguments: [String],
    environment: [String: String],
    signal: Int32,
    pidFile: URL
) throws -> BootstrapSupervisionResult {
    try runBootstrapProcess(
        arguments,
        environment: environment,
        pidFile: pidFile,
        watchdogSeconds: 4,
        signal: signal
    )
}

private func runBootstrapUntilExit(
    _ arguments: [String],
    environment: [String: String],
    pidFile: URL,
    watchdogSeconds: TimeInterval
) throws -> BootstrapSupervisionResult {
    try runBootstrapProcess(
        arguments,
        environment: environment,
        pidFile: pidFile,
        watchdogSeconds: watchdogSeconds,
        signal: nil
    )
}

private func runBootstrapProcess(
    _ arguments: [String],
    environment: [String: String],
    pidFile: URL,
    watchdogSeconds: TimeInterval,
    signal: Int32?
) throws -> BootstrapSupervisionResult {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let capture = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: capture) }
    let stdoutURL = capture.appendingPathComponent("stdout")
    let stderrURL = capture.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer {
        try? stdout.close()
        try? stderr.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [repositoryRoot.appendingPathComponent("scripts/bootstrap-gdb-sim.sh").path]
        + arguments
    process.currentDirectoryURL = repositoryRoot
    process.environment = isolatedBootstrapEnvironment(environment)
    process.standardOutput = stdout
    process.standardError = stderr

    let start = Date()
    try process.run()
    let markerDeadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: pidFile.path),
          process.isRunning,
          Date() < markerDeadline {
        usleep(10_000)
    }
    if let signal, process.isRunning {
        _ = Darwin.kill(process.processIdentifier, signal)
    }

    let deadline = Date().addingTimeInterval(watchdogSeconds)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    let watchdogFired = process.isRunning
    if watchdogFired {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()

    let descendants = ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "")
        .split(whereSeparator: \.isWhitespace)
        .compactMap { pid_t($0) }
    for _ in 0..<100 where !descendants.allSatisfy(bootstrapProcessHasExited) {
        usleep(10_000)
    }
    let descendantsExitedBeforeCleanup = descendants.allSatisfy(bootstrapProcessHasExited)
    for pid in descendants.reversed() where !bootstrapProcessHasExited(pid) {
        _ = Darwin.kill(pid, SIGKILL)
    }

    try stdout.close()
    try stderr.close()
    return BootstrapSupervisionResult(
        process: ProcessResult(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        ),
        elapsed: Date().timeIntervalSince(start),
        watchdogFired: watchdogFired,
        descendantPIDs: descendants,
        descendantsExitedBeforeCleanup: descendantsExitedBeforeCleanup
    )
}

private func bootstrapProcessHasExited(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return true }
    errno = 0
    return Darwin.kill(pid, 0) == -1 && errno == ESRCH
}

private func isolatedBootstrapEnvironment(
    _ overrides: [String: String]
) -> [String: String] {
    [
        "HOME": FileManager.default.temporaryDirectory.path,
        "PATH": "/usr/bin:/bin",
        "TMPDIR": FileManager.default.temporaryDirectory.path,
        "LANG": "en_US.UTF-8"
    ].merging(overrides, uniquingKeysWith: { _, override in override })
}

private func writeBootstrapExecutable(_ contents: String, to url: URL) throws {
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

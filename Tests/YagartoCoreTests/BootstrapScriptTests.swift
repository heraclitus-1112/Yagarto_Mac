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
        XCTAssertTrue(result.stdout.contains("gdb-17.2.tar.xz"))
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
                "--archive", "/definitely/missing/gdb-17.2.tar.xz"
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
        let archive = directory.appendingPathComponent("gdb-17.2.tar.xz")
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

    func testScriptKeepsSimulatorBuildAndPostInstallVerificationContract() throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        for dependency in ["gmake", "gmp", "mpfr", "makeinfo"] {
            XCTAssertTrue(script.contains(dependency), "脚本缺少依赖检查：\(dependency)")
        }
        XCTAssertTrue(script.contains("--target=arm-none-eabi"))
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
            args: environment.map { "\($0.key)=\($0.value)" }
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
        archive = directory.appendingPathComponent("gdb-17.2.tar.xz")
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
    process.environment = ProcessInfo.processInfo.environment.merging(
        environment,
        uniquingKeysWith: { _, override in override }
    )
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

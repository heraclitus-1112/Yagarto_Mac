// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
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

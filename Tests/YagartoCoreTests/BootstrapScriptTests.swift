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

    private func runBootstrap(_ arguments: [String]) throws -> ProcessResult {
        try ProcessRunner().run(CommandSpec(
            executable: "/bin/sh",
            args: [scriptURL.path] + arguments,
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

// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import YagartoCore

final class ToolResolverTests: XCTestCase {
    func testExplicitOverrideWinsOverPathAndHomebrew() throws {
        let existing = Set([
            "/custom/bin/arm-none-eabi-as",
            "/path/bin/arm-none-eabi-as",
            "/opt/homebrew/bin/arm-none-eabi-as"
        ])
        let resolver = ToolResolver(
            environment: ["PATH": "/path/bin"],
            fileExists: existing.contains
        )

        let resolved = try resolver.resolve(
            .assembler,
            overrides: [.assembler: "/custom/bin/arm-none-eabi-as"]
        )

        XCTAssertEqual(resolved, "/custom/bin/arm-none-eabi-as")
    }

    func testPathDirectoryOrderWinsBeforeHomebrewFallback() throws {
        let existing = Set([
            "/second/arm-none-eabi-gcc",
            "/opt/homebrew/bin/arm-none-eabi-gcc"
        ])
        let resolver = ToolResolver(
            environment: ["PATH": "/first:/second"],
            fileExists: existing.contains
        )

        XCTAssertEqual(try resolver.resolve(.compiler), "/second/arm-none-eabi-gcc")
    }

    func testHomebrewIsUsedAfterPath() throws {
        let resolver = ToolResolver(
            environment: ["PATH": "/usr/bin"],
            fileExists: { $0 == "/opt/homebrew/bin/arm-none-eabi-objdump" }
        )

        XCTAssertEqual(
            try resolver.resolve(.objdump),
            "/opt/homebrew/bin/arm-none-eabi-objdump"
        )
    }

    func testMissingToolThrowsAndHostClangIsNeverAccepted() {
        let resolver = ToolResolver(
            environment: ["PATH": "/usr/bin"],
            fileExists: { $0 == "/usr/bin/clang" }
        )

        XCTAssertThrowsError(try resolver.resolve(.compiler)) { error in
            XCTAssertEqual(
                error as? YagartoError,
                .toolNotFound("arm-none-eabi-gcc")
            )
        }
    }

    func testDoctorReturnsRequiredAndOptionalStructuredEntries() {
        let resolver = ToolResolver(
            environment: ["PATH": "/tools"],
            fileExists: { path in
                path.hasSuffix("arm-none-eabi-as") || path.hasSuffix("qemu-system-arm")
            }
        )

        let report = resolver.doctor()

        XCTAssertEqual(report.entries.count, 8)
        XCTAssertEqual(
            report.entries.filter(\.required).map(\.tool),
            [.assembler, .compiler, .linker, .objcopy, .objdump]
        )
        XCTAssertEqual(
            report.entries.filter { !$0.required }.map(\.tool),
            [.gdb, .openOCD, .qemuSystemARM]
        )
        XCTAssertEqual(report.entry(for: .assembler)?.path, "/tools/arm-none-eabi-as")
        XCTAssertNil(report.entry(for: .compiler)?.path)
        XCTAssertEqual(report.entry(for: .qemuSystemARM)?.path, "/tools/qemu-system-arm")
        XCTAssertFalse(report.requiredToolsAvailable)
    }
}

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
        XCTAssertEqual(report.entry(for: .gdb)?.executablePresent, false)
        XCTAssertEqual(report.entry(for: .gdb)?.targetSimCapable, false)
        XCTAssertFalse(report.stm32f4BoardConfigAvailable)
        XCTAssertFalse(report.requiredToolsAvailable)
    }

    func testDoctorJSONIncludesExplicitBoardConfigAvailabilityWhenMissing() throws {
        let report = ToolResolver(
            environment: ["PATH": ""],
            fileExists: { _ in false },
            resourceExists: { _ in false }
        ).doctor()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )

        XCTAssertEqual(object["stm32f4BoardConfigAvailable"] as? Bool, false)
    }

    func testSimulatorEnvironmentOverrideWinsAndIsCapabilityProbedWithExactArguments() throws {
        let recorder = CapabilityProbeRecorder(capablePaths: ["/custom/gdb sim"])
        let resolver = ToolResolver(
            environment: [
                "PATH": "/tools",
                "YAGARTO_MAC_GDB_SIM": "/custom/gdb sim"
            ],
            fileExists: { $0 == "/custom/gdb sim" || $0 == "/tools/arm-none-eabi-gdb" },
            capabilityProbe: recorder.probe
        )

        XCTAssertEqual(try resolver.resolveGDBSimulator(), "/custom/gdb sim")
        XCTAssertEqual(recorder.commands.first, CommandSpec(
            executable: "/custom/gdb sim",
            args: ["-q", "-nx", "-batch", "-ex", "target sim"],
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ))
    }

    func testDoctorReportsSimulatorEnvironmentOverrideAsSelectedGDB() {
        let resolver = ToolResolver(
            environment: [
                "PATH": "/tools",
                "YAGARTO_MAC_GDB_SIM": "/custom/gdb-sim"
            ],
            fileExists: {
                $0 == "/custom/gdb-sim" || $0 == "/tools/arm-none-eabi-gdb"
            },
            capabilityProbe: { $0.executable == "/custom/gdb-sim" }
        )

        let entry = resolver.doctor().entry(for: .gdb)

        XCTAssertEqual(entry?.path, "/custom/gdb-sim")
        XCTAssertEqual(entry?.executablePresent, true)
        XCTAssertEqual(entry?.targetSimCapable, true)
    }

    func testDoctorSkipsIncapableSimulatorOverrideLikeRuntimeResolution() {
        let resolver = ToolResolver(
            environment: [
                "PATH": "/tools",
                "YAGARTO_MAC_GDB_SIM": "/custom/incapable-gdb"
            ],
            fileExists: {
                $0 == "/custom/incapable-gdb" || $0 == "/tools/arm-none-eabi-gdb"
            },
            capabilityProbe: { $0.executable == "/tools/arm-none-eabi-gdb" }
        )

        let entry = resolver.doctor().entry(for: .gdb)

        XCTAssertEqual(entry?.path, "/tools/arm-none-eabi-gdb")
        XCTAssertEqual(entry?.targetSimCapable, true)
    }

    func testExplicitGDBOverrideCanSelectSimulatorButOrdinaryGDBMustBeCapable() throws {
        let recorder = CapabilityProbeRecorder(capablePaths: ["/explicit/gdb"])
        let resolver = ToolResolver(
            environment: ["PATH": "/tools"],
            fileExists: { ["/explicit/gdb", "/tools/arm-none-eabi-gdb"].contains($0) },
            capabilityProbe: recorder.probe
        )

        XCTAssertEqual(
            try resolver.resolveGDBSimulator(overrides: [.gdb: "/explicit/gdb"]),
            "/explicit/gdb"
        )
    }

    func testPresentOrdinaryGDBIsNotSimulatorWhenTargetSimProbeFails() {
        let resolver = ToolResolver(
            environment: ["PATH": "/tools"],
            fileExists: { $0 == "/tools/arm-none-eabi-gdb" },
            capabilityProbe: { _ in false }
        )

        XCTAssertThrowsError(try resolver.resolveGDBSimulator()) { error in
            XCTAssertEqual(error as? YagartoError, .debugBackendUnavailable(.arm7tdmi))
        }
        let entry = resolver.doctor().entry(for: .gdb)
        XCTAssertEqual(entry?.path, "/tools/arm-none-eabi-gdb")
        XCTAssertEqual(entry?.executablePresent, true)
        XCTAssertEqual(entry?.targetSimCapable, false)
    }

    func testDoctorSeparatesPresentGDBFromTargetSimCapability() {
        let recorder = CapabilityProbeRecorder(capablePaths: ["/tools/arm-none-eabi-gdb"])
        let resolver = ToolResolver(
            environment: ["PATH": "/tools"],
            fileExists: { $0 == "/tools/arm-none-eabi-gdb" },
            capabilityProbe: recorder.probe
        )

        let entry = resolver.doctor().entry(for: .gdb)

        XCTAssertEqual(entry?.available, true)
        XCTAssertEqual(entry?.executablePresent, true)
        XCTAssertEqual(entry?.targetSimCapable, true)
    }

    func testInstalledOpenOCDBoardConfigIsResolvedBesideCellarExecutable() throws {
        let openOCD = "/opt/homebrew/Cellar/open-ocd/0.12.0_1/bin/openocd"
        let board = "/opt/homebrew/Cellar/open-ocd/0.12.0_1/share/openocd/scripts/board/stm32f4discovery.cfg"
        let resolver = ToolResolver(
            environment: ["PATH": ""],
            fileExists: { $0 == openOCD || $0 == board },
            resourceExists: { $0 == board },
            resolvingSymlinks: { $0 }
        )

        XCTAssertEqual(
            try resolver.resolveSTM32F4BoardConfig(openOCDPath: openOCD),
            board
        )
        XCTAssertEqual(resolver.doctor(overrides: [.openOCD: openOCD]).stm32f4BoardConfig, board)
    }
}

private final class CapabilityProbeRecorder {
    private let capablePaths: Set<String>
    private(set) var commands: [CommandSpec] = []

    init(capablePaths: Set<String>) {
        self.capablePaths = capablePaths
    }

    func probe(_ command: CommandSpec) -> Bool {
        commands.append(command)
        return capablePaths.contains(command.executable)
    }
}

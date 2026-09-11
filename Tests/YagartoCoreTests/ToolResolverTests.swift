// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
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

    func testDoctorDoesNotSelectQEMUProfilesWhenQEMUExecutableIsMissing() throws {
        let resolver = ToolResolver(
            environment: ["PATH": "/tools"],
            fileExists: { $0 == "/tools/arm-none-eabi-gdb" },
            capabilityProbe: { _ in false }
        )

        let report = resolver.doctor()

        XCTAssertFalse(try XCTUnwrap(report.debugSelection(for: .arm7tdmi)).available)
        XCTAssertNil(report.debugSelection(for: .arm7tdmi)?.backend)
        XCTAssertFalse(try XCTUnwrap(report.debugSelection(for: .cortexM4)).available)
        XCTAssertNil(report.debugSelection(for: .cortexM4)?.backend)
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
            args: [
                "-q", "-nx", "-batch",
                "-ex", "set endian little",
                "-ex", "set architecture arm",
                "-ex", "target sim"
            ],
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ))
    }

    func testSimulatorAliasOnPathIsDiscoveredWithoutEnvironmentOverride() throws {
        let simulator = "/tools/arm-none-eabi-gdb-sim"
        let resolver = ToolResolver(
            environment: ["PATH": "/tools"],
            fileExists: { $0 == simulator },
            capabilityProbe: { $0.executable == simulator }
        )

        XCTAssertEqual(try resolver.resolveGDBSimulator(), simulator)
    }

    func testSimulatorInDefaultUserToolchainDirectoryIsDiscoveredByFinderLaunchedApp() throws {
        let simulator = "/Users/student/.local/share/yagarto-mac/toolchains/gdb-15.2-sim/bin/arm-none-eabi-gdb-sim"
        let resolver = ToolResolver(
            environment: ["PATH": "/usr/bin", "HOME": "/Users/student"],
            fileExists: { $0 == simulator },
            capabilityProbe: { $0.executable == simulator }
        )

        XCTAssertEqual(try resolver.resolveGDBSimulator(), simulator)
    }

    func testCapabilityProbeTimesOutAndReapsIgnoringProcessGroup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pids")
        let escapedPIDFile = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let hangingCommand = """
        trap '' TERM
        (trap '' TERM; while :; do /bin/sleep 30; done) &
        child=$!
        printf '%s %s\n' "$$" "$child" > '\(escapedPIDFile)'
        while :; do /bin/sleep 30; done
        """

        let start = Date()
        let capable = TimedProcessCapabilityProbe.run(
            CommandSpec(
                executable: "/bin/sh",
                args: ["-c", hangingCommand],
                workingDirectory: directory
            ),
            timeout: 0.2
        )

        XCTAssertFalse(capable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let processIDs = try String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        XCTAssertEqual(processIDs.count, 2)
        for _ in 0..<100 where !processIDs.allSatisfy(toolResolverProcessHasExited) {
            usleep(10_000)
        }
        XCTAssertTrue(
            processIDs.allSatisfy(toolResolverProcessHasExited),
            "能力探测留下进程：\(processIDs)"
        )
        XCTAssertTrue(
            toolResolverProcessGroupHasExited(processIDs[0]),
            "能力探测留下进程组：\(processIDs[0])"
        )
    }

    func testDoctorReportsNormalAndSimulatorGDBSeparatelyWithProfileSelections() {
        let resolver = ToolResolver(
            environment: [
                "PATH": "/tools",
                "YAGARTO_MAC_GDB_SIM": "/custom/gdb-sim"
            ],
            fileExists: {
                [
                    "/custom/gdb-sim",
                    "/tools/arm-none-eabi-gdb",
                    "/tools/qemu-system-arm"
                ].contains($0)
            },
            capabilityProbe: { $0.executable == "/custom/gdb-sim" }
        )

        let report = resolver.doctor()
        let entry = report.entry(for: .gdb)

        XCTAssertEqual(entry?.path, "/tools/arm-none-eabi-gdb")
        XCTAssertEqual(entry?.executablePresent, true)
        XCTAssertEqual(entry?.targetSimCapable, false)
        XCTAssertEqual(report.normalGDB.path, "/tools/arm-none-eabi-gdb")
        XCTAssertFalse(report.normalGDB.targetSimCapable)
        XCTAssertEqual(report.simulatorGDB.path, "/custom/gdb-sim")
        XCTAssertTrue(report.simulatorGDB.targetSimCapable)
        XCTAssertEqual(
            report.debugSelection(for: .arm7tdmi),
            DoctorDebugSelection(
                profile: .arm7tdmi,
                backend: .gdbSimulator,
                gdbExecutable: "/custom/gdb-sim",
                warnings: []
            )
        )
        XCTAssertEqual(
            report.debugSelection(for: .cortexM4)?.gdbExecutable,
            "/tools/arm-none-eabi-gdb"
        )
        XCTAssertEqual(
            report.debugSelection(for: .cortexM4)?.backend,
            .qemuMPS2AN386
        )
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

    func testDoctorDistinguishesPresentSimulatorCandidateFromFailedCapability() throws {
        let resolver = ToolResolver(
            environment: [
                "PATH": "",
                "YAGARTO_MAC_GDB_SIM": "/custom/incapable-gdb"
            ],
            fileExists: { $0 == "/custom/incapable-gdb" },
            capabilityProbe: { _ in false }
        )

        let report = resolver.doctor()

        XCTAssertEqual(report.simulatorGDB.path, "/custom/incapable-gdb")
        XCTAssertTrue(report.simulatorGDB.executablePresent)
        XCTAssertFalse(report.simulatorGDB.targetSimCapable)
        XCTAssertFalse(try XCTUnwrap(report.debugSelection(for: .arm7tdmi)).available)
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

private func toolResolverProcessHasExited(_ processID: pid_t) -> Bool {
    errno = 0
    return Darwin.kill(processID, 0) == -1 && errno == ESRCH
}

private func toolResolverProcessGroupHasExited(_ processGroup: pid_t) -> Bool {
    errno = 0
    return Darwin.kill(-processGroup, 0) == -1 && errno == ESRCH
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

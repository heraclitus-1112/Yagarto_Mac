// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import YagartoCore

final class ARM7QEMUFallbackE2ETests: XCTestCase {
    func testRealFallbackStopsAtEntryStepsAndReapsQEMU() async throws {
        let resolver = ToolResolver()
        let required: [ToolIdentifier] = [
            .assembler, .linker, .objcopy, .objdump, .gdb, .qemuSystemARM
        ]
        var tools: [ToolIdentifier: String] = [:]
        for tool in required {
            guard let path = try? resolver.resolve(tool) else {
                throw XCTSkip("缺少真实工具 \(tool.rawValue)，跳过 ARM7 QEMU E2E")
            }
            tools[tool] = path
        }

        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("yagarto-arm7-qemu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        try Data("""
        .section .text.start, "ax", %progbits
        .align 2
        .global start
        .type start, %function
        start:
            mov r0, #1
            add r0, r0, #1
        .Lhalt:
            b .Lhalt
        .size start, . - start
        .section .note.GNU-stack, "", %progbits
        """.utf8).write(to: project.appendingPathComponent("fallback.s"))

        let configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["fallback.s"],
            outputName: "fallback"
        )
        let buildPlan = try BuildPlanner(toolPaths: tools).plan(
            configuration: configuration,
            projectDirectory: project
        )
        _ = try BuildExecutor().execute(buildPlan)

        let pidFile = project.appendingPathComponent("qemu.pid")
        let wrapper = project.appendingPathComponent("qemu-wrapper")
        let realQEMU = try XCTUnwrap(tools[.qemuSystemARM])
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$$" > \(shellQuote(pidFile.path))
        exec \(shellQuote(realQEMU)) "$@"
        """.utf8).write(to: wrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapper.path
        )

        let debugPlan = try DebugPlanner(
            toolPaths: [
                .gdb: try XCTUnwrap(tools[.gdb]),
                .qemuSystemARM: wrapper.path
            ]
        ).plan(
            mode: .debug,
            configuration: configuration,
            elf: buildPlan.elfFile,
            projectDirectory: project
        )
        XCTAssertEqual(debugPlan.backend, .qemuARM926Compatible)

        let controller = DebuggerController(
            plan: debugPlan,
            snapshotCommandTimeout: .seconds(2)
        )
        do {
            try await controller.launch()
            let initial = try await waitForSnapshot(controller)
            let initialPC = try XCTUnwrap(initial.location?.address?.numeric)
            XCTAssertEqual(initialPC, 0x8000)
            XCTAssertEqual(initial.location?.function, "start")

            try await controller.stepInstruction()
            let stepped = try await waitForSnapshot(controller, excludingAddress: initialPC)
            XCTAssertEqual(stepped.location?.address?.numeric, initialPC + 4)

            try await controller.continue()
            try await waitForState(.running, controller: controller)
            try await controller.stop()
            let finalState = await controller.currentState
            XCTAssertEqual(finalState, .ready)
        } catch {
            try? await controller.stop()
            throw error
        }

        let qemuPID = try await waitForPID(in: pidFile)
        try await waitForProcessExit(qemuPID)
    }

    private func waitForSnapshot(
        _ controller: DebuggerController,
        excludingAddress: UInt64? = nil
    ) async throws -> DebugSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await controller.currentState == .stopped,
               let snapshot = await controller.latestSnapshot,
               let address = snapshot.location?.address?.numeric,
               address != excludingAddress {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timeout("等待 ARM7 QEMU 停止快照超时")
    }

    private func waitForState(
        _ expected: DebuggerState,
        controller: DebuggerController
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await controller.currentState == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timeout("等待调试状态 \(expected.rawValue) 超时")
    }

    private func waitForPID(in file: URL) async throws -> pid_t {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timeout("QEMU wrapper 未写入 PID")
    }

    private func waitForProcessExit(_ processID: pid_t) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            errno = 0
            if kill(processID, 0) == -1, errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timeout("QEMU 进程 \(processID) 未被回收")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private enum TestFailure: Error {
    case timeout(String)
}

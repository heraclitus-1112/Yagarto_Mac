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

        let qemuPIDFile = project.appendingPathComponent("qemu.pid")
        let qemuWrapper = project.appendingPathComponent("qemu-wrapper")
        let realQEMU = try XCTUnwrap(tools[.qemuSystemARM])
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$$" > \(shellQuote(qemuPIDFile.path))
        exec \(shellQuote(realQEMU)) "$@"
        """.utf8).write(to: qemuWrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: qemuWrapper.path
        )

        let gdbPIDFile = project.appendingPathComponent("gdb.pid")
        let gdbWrapper = project.appendingPathComponent("gdb-wrapper")
        let realGDB = try XCTUnwrap(tools[.gdb])
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$$" > \(shellQuote(gdbPIDFile.path))
        exec \(shellQuote(realGDB)) "$@"
        """.utf8).write(to: gdbWrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: gdbWrapper.path
        )

        let debugPlan = try DebugPlanner(
            toolPaths: [
                .gdb: gdbWrapper.path,
                .qemuSystemARM: qemuWrapper.path
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
        var operationError: (any Error)?
        var gdbPID: pid_t?
        var qemuPID: pid_t?
        do {
            try await controller.launch()
            gdbPID = try await waitForPID(in: gdbPIDFile, processName: "GDB")
            qemuPID = try await waitForPID(in: qemuPIDFile, processName: "QEMU")
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
            operationError = error
        }

        // Always execute a second, idempotent controller cleanup. If the main
        // scenario failed before reading the wrappers' marker files, recover
        // their exact PIDs before applying the identity-checked fallback.
        try? await controller.stop()
        gdbPID = gdbPID ?? readPIDIfPresent(in: gdbPIDFile)
        qemuPID = qemuPID ?? readPIDIfPresent(in: qemuPIDFile)

        if let gdbPID {
            do {
                try await terminateExactProcessIfNeeded(
                    gdbPID,
                    expectedExecutable: realGDB,
                    processName: "GDB"
                )
            } catch {
                if operationError == nil { operationError = error }
            }
        }
        if let qemuPID {
            do {
                try await terminateExactProcessIfNeeded(
                    qemuPID,
                    expectedExecutable: realQEMU,
                    processName: "QEMU"
                )
            } catch {
                if operationError == nil { operationError = error }
            }
        }

        XCTAssertNotNil(gdbPID, "GDB wrapper 未写入 PID")
        XCTAssertNotNil(qemuPID, "QEMU wrapper 未写入 PID")
        if let gdbPID { XCTAssertFalse(isProcessAlive(gdbPID), "GDB 进程 \(gdbPID) 未被回收") }
        if let qemuPID { XCTAssertFalse(isProcessAlive(qemuPID), "QEMU 进程 \(qemuPID) 未被回收") }
        if let operationError { throw operationError }
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

    private func waitForPID(in file: URL, processName: String) async throws -> pid_t {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timeout("\(processName) wrapper 未写入 PID")
    }

    private func readPIDIfPresent(in file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func terminateExactProcessIfNeeded(
        _ processID: pid_t,
        expectedExecutable: String,
        processName: String
    ) async throws {
        guard isProcessAlive(processID) else { return }
        let expected = URL(fileURLWithPath: expectedExecutable)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let actual = try executablePath(for: processID)
        guard actual == expected else {
            throw TestFailure.unsafeProcessIdentity(
                "拒绝清理 PID \(processID)：预期 \(processName) 为 \(expected)，实际为 \(actual)"
            )
        }

        _ = kill(processID, SIGTERM)
        if await waitForProcessExit(processID, timeout: .milliseconds(300)) { return }
        _ = kill(processID, SIGKILL)
        guard await waitForProcessExit(processID, timeout: .seconds(2)) else {
            throw TestFailure.timeout("\(processName) 进程 \(processID) 未被回收")
        }
    }

    private func executablePath(for processID: pid_t) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard count > 0 else {
            throw TestFailure.unsafeProcessIdentity("无法核验 PID \(processID) 的可执行文件")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func waitForProcessExit(
        _ processID: pid_t,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !isProcessAlive(processID) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !isProcessAlive(processID)
    }

    private func isProcessAlive(_ processID: pid_t) -> Bool {
        errno = 0
        return kill(processID, 0) == 0 || errno != ESRCH
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private enum TestFailure: Error {
    case timeout(String)
    case unsafeProcessIdentity(String)
}

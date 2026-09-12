// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import YagartoCore

final class DebuggerControllerTests: XCTestCase {
    func testStoppedEventRefreshesCompleteARM7Snapshot() async throws {
        let fixture = try ControllerGDBFixture()
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi), consoleLimit: 3)
        let events = await controller.events()

        try await controller.launch()
        let snapshot = try await waitForSnapshot(controller)
        let state = await controller.currentState

        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(snapshot.stopReason, .breakpointHit)
        XCTAssertEqual(snapshot.location?.fullName, "/tmp/课程/main.s")
        XCTAssertEqual(snapshot.location?.line?.numeric, 12)
        XCTAssertEqual(snapshot.stack.count, 2)
        XCTAssertEqual(snapshot.memory.first?.contents, "002affff")
        XCTAssertEqual(snapshot.disassembly.first?.instruction, "mov r0, #42")
        XCTAssertEqual(snapshot.registers.map(\.name), (0...15).map { "r\($0)" } + ["CPSR"])
        XCTAssertEqual(snapshot.registers.first?.value?.numeric, 42)
        XCTAssertEqual(snapshot.registers.last?.value?.numeric, 0x60000013)
        XCTAssertEqual(snapshot.console.map(\.text), ["console-3", "console-4", "console-5"])
        XCTAssertTrue(snapshot.diagnostics.isEmpty)

        let emitted = try await firstSnapshot(from: events)
        XCTAssertEqual(emitted, snapshot)
        try await controller.stop()
    }

    func testResultDoneNeverGuessesRunningStateBeforeAsyncRunning() async throws {
        let fixture = try ControllerGDBFixture()
        let controller = DebuggerController(plan: fixture.plan(
            profile: .arm7tdmi,
            backend: .qemuMPS2AN386
        ))
        try await controller.launch()
        _ = try await waitForSnapshot(controller)

        try await controller.run()
        let immediately = await controller.currentState
        XCTAssertEqual(immediately, .stopped)
        try await waitForState(.running, controller: controller)
        try await controller.pause()
        try await waitForState(.stopped, controller: controller)
        XCTAssertTrue(try fixture.commands().contains("-exec-interrupt --all"))
        try await controller.stop()
    }

    func testARM7SimulatorPauseUsesProcessSignalWhenMIInterruptIsUnsupported() async throws {
        let fixture = try ControllerGDBFixture(signalInterrupt: true)
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi))
        try await controller.launch()
        _ = try await waitForSnapshot(controller)
        try await controller.run()
        try await waitForState(.running, controller: controller)

        try await controller.pause()
        try await waitForState(.stopped, controller: controller)

        XCTAssertFalse(try fixture.commands().contains("-exec-interrupt --all"))
        try await controller.stop()
    }

    func testRunningARM7SimulatorStopInterruptsBeforeGDBExitWithoutTimeout() async throws {
        let fixture = try ControllerGDBFixture(signalInterrupt: true)
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi))
        try await controller.launch()
        _ = try await waitForSnapshot(controller)
        try await controller.run()
        try await waitForState(.running, controller: controller)
        let started = ContinuousClock.now

        try await controller.stop()

        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        let state = await controller.currentState
        XCTAssertEqual(state, .ready)
        XCTAssertTrue(try fixture.commands().contains("-gdb-exit"))
        XCTAssertFalse(try fixture.commands().contains("-exec-interrupt --all"))
    }

    func testOptionalPaneFailureKeepsStoppedSnapshotAndDiagnostic() async throws {
        let fixture = try ControllerGDBFixture(failMemory: true)
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi))

        try await controller.launch()
        let snapshot = try await waitForSnapshot(controller)

        let state = await controller.currentState
        XCTAssertEqual(state, .stopped)
        XCTAssertTrue(snapshot.memory.isEmpty)
        XCTAssertTrue(snapshot.diagnostics.contains(where: {
            $0.pane == .memory && !$0.isCritical && $0.message.contains("memory unavailable")
        }))
        XCTAssertNotNil(snapshot.location)
        XCTAssertFalse(snapshot.registers.isEmpty)
        try await controller.stop()
    }

    func testM4RegisterProfileUsesXPSRAndSystemRegistersNeverCPSR() async throws {
        let fixture = try ControllerGDBFixture()
        let controller = DebuggerController(plan: fixture.plan(profile: .cortexM4))

        try await controller.launch()
        let snapshot = try await waitForSnapshot(controller)
        let names = snapshot.registers.map { $0.name.lowercased() }

        XCTAssertEqual(names, (0...15).map { "r\($0)" } + [
            "xpsr", "msp", "psp", "control", "primask"
        ])
        XCTAssertFalse(names.contains("cpsr"))
        XCTAssertNil(snapshot.registers.first(where: { $0.name == "PSP" })?.value)
        try await controller.stop()
    }

    func testRealArmGDBCanonicalAliasesPopulateDisplayedR13R14R15Slots() async throws {
        let fixture = try ControllerGDBFixture()
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi))

        try await controller.launch()
        let snapshot = try await waitForSnapshot(controller)
        let registers = Dictionary(uniqueKeysWithValues: snapshot.registers.map { ($0.name, $0) })

        XCTAssertEqual(registers["r13"]?.number, 13)
        XCTAssertEqual(registers["r13"]?.value?.numeric, 0x2000_1000)
        XCTAssertEqual(registers["r14"]?.number, 14)
        XCTAssertEqual(registers["r14"]?.value?.numeric, 0x100)
        XCTAssertEqual(registers["r15"]?.number, 15)
        XCTAssertEqual(registers["r15"]?.value?.numeric, 0x104)
        XCTAssertEqual(registers["CPSR"]?.number, 17)
        try await controller.stop()
    }

    func testCriticalFrameAndRegisterFailuresRemainVisibleWithoutDeadlock() async throws {
        let fixture = try ControllerGDBFixture(failCritical: true)
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi))

        try await controller.launch()
        let snapshot = try await waitForSnapshot(controller)

        let state = await controller.currentState
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(snapshot.location?.function, "main")
        XCTAssertTrue(snapshot.registers.allSatisfy { $0.value == nil })
        XCTAssertTrue(snapshot.diagnostics.contains(where: { $0.pane == .frame && $0.isCritical }))
        XCTAssertTrue(snapshot.diagnostics.contains(where: { $0.pane == .registers && $0.isCritical }))
        try await controller.stop()
    }

    func testHungCriticalPaneTimesOutAndStillPublishesSnapshot() async throws {
        let fixture = try ControllerGDBFixture(hangFrame: true)
        let controller = DebuggerController(
            plan: fixture.plan(profile: .arm7tdmi),
            snapshotCommandTimeout: .milliseconds(50)
        )

        try await controller.launch()
        let snapshot = try await waitForSnapshot(controller)

        XCTAssertTrue(snapshot.diagnostics.contains(where: {
            $0.pane == .frame && $0.isCritical && $0.message.contains("timed out")
        }))
        try await controller.stop()
    }

    func testRunningEventIsNotBlockedByAHungSnapshotPane() async throws {
        let fixture = try ControllerGDBFixture(
            hangStack: true,
            emitRunningWhileStackHung: true
        )
        let controller = DebuggerController(
            plan: fixture.plan(profile: .arm7tdmi, backend: .qemuMPS2AN386),
            snapshotCommandTimeout: .milliseconds(500)
        )

        try await controller.launch()
        try await waitForCommand("-stack-list-frames", fixture: fixture)
        let started = ContinuousClock.now
        try await waitForState(.running, controller: controller)

        XCTAssertLessThan(started.duration(to: .now), .milliseconds(100))
        try await controller.stop()
    }

    func testStopCancelsOldSnapshotBeforeItCanPublish() async throws {
        let fixture = try ControllerGDBFixture(hangStack: true)
        let controller = DebuggerController(
            plan: fixture.plan(profile: .arm7tdmi),
            snapshotCommandTimeout: .milliseconds(500)
        )

        try await controller.launch()
        try await waitForCommand("-stack-list-frames", fixture: fixture)
        try await controller.stop()
        try await Task.sleep(for: .milliseconds(100))

        let state = await controller.currentState
        let snapshot = await controller.latestSnapshot
        XCTAssertEqual(state, .ready)
        XCTAssertNil(snapshot)
    }

    func testOldRecoveryCompletionCannotClearRelaunchedSession() async throws {
        let oldFixture = try ControllerGDBFixture(autoExitWithStubbornChild: true, label: "old")
        let newFixture = try ControllerGDBFixture(label: "new")
        let controller = DebuggerController(plan: oldFixture.plan(profile: .arm7tdmi))

        try await controller.launch()
        let oldChild = try await oldFixture.waitForChildPID()
        try await waitForState(.ready, controller: controller)
        XCTAssertEqual(Darwin.kill(oldChild, 0), 0)

        try await controller.buildStarted()
        try await controller.buildSucceeded(plan: newFixture.plan(
            profile: .arm7tdmi,
            backend: .qemuMPS2AN386
        ))
        try await controller.launch()
        let snapshot = try await waitForSnapshot(controller, fullName: "/tmp/new/main.s")
        XCTAssertEqual(snapshot.location?.fullName, "/tmp/new/main.s")
        try await controller.run()
        try await waitForState(.running, controller: controller)
        try await controller.stop()
        withExtendedLifetime((oldFixture, newFixture)) {}
    }

    func testCancellingRelaunchDuringOldRecoveryRollsBackAndAllowsNextLaunch() async throws {
        let oldFixture = try ControllerGDBFixture(autoExitWithStubbornChild: true, label: "old")
        let newFixture = try ControllerGDBFixture(label: "new")
        let controller = DebuggerController(plan: oldFixture.plan(profile: .arm7tdmi))

        try await controller.launch()
        _ = try await oldFixture.waitForChildPID()
        try await waitForState(.ready, controller: controller)
        try await controller.buildStarted()
        try await controller.buildSucceeded(plan: newFixture.plan(profile: .arm7tdmi))

        let cancelledLaunch = Task { try await controller.launch() }
        try await waitForState(.launching, controller: controller)
        cancelledLaunch.cancel()
        do {
            try await cancelledLaunch.value
            XCTFail("expected cleanup-time launch cancellation")
        } catch is CancellationError {
            // Expected: the cancelled attempt owns and rolls back `.launching`.
        }

        let stateAfterCancellation = await controller.currentState
        XCTAssertEqual(stateAfterCancellation, .ready)
        XCTAssertTrue(newFixture.processIDsIfPresent().isEmpty)
        try await controller.launch()
        _ = try await waitForSnapshot(controller, fullName: "/tmp/new/main.s")
        try await controller.stop()
        withExtendedLifetime((oldFixture, newFixture)) {}
    }

    func testStopDuringRelaunchCleanupPreventsPostStopSpawn() async throws {
        let oldFixture = try ControllerGDBFixture(autoExitWithStubbornChild: true, label: "old")
        let newFixture = try ControllerGDBFixture(label: "new")
        let controller = DebuggerController(plan: oldFixture.plan(profile: .arm7tdmi))

        try await controller.launch()
        let oldChild = try await oldFixture.waitForChildPID()
        try await waitForState(.ready, controller: controller)
        try await controller.buildStarted()
        try await controller.buildSucceeded(plan: newFixture.plan(profile: .arm7tdmi))

        let invalidatedLaunch = Task { try await controller.launch() }
        try await waitForState(.launching, controller: controller)
        try await controller.stop()
        do {
            try await invalidatedLaunch.value
            XCTFail("expected stop to invalidate the concurrent launch")
        } catch is CancellationError {
            // Expected: stop owns termination after invalidating this attempt.
        }

        try await Task.sleep(for: .milliseconds(50))
        let stateAfterStop = await controller.currentState
        XCTAssertEqual(stateAfterStop, .ready)
        XCTAssertTrue(newFixture.processIDsIfPresent().isEmpty)
        XCTAssertEqual(Darwin.kill(oldChild, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        withExtendedLifetime((oldFixture, newFixture)) {}
    }

    func testCancellationAfterSessionStartShutsDownSpawnedProcessAndRollsBack() async throws {
        let fixture = try ControllerGDBFixture(label: "post-start")
        let gate = ControllerLaunchGate()
        let controller = DebuggerController(
            plan: fixture.plan(profile: .arm7tdmi),
            postStartSynchronization: { await gate.pause() }
        )

        let cancelledLaunch = Task { try await controller.launch() }
        try await waitForArrival(1, at: gate)
        try await waitForProcessCount(1, fixture: fixture)
        cancelledLaunch.cancel()
        await gate.release(1)
        do {
            try await cancelledLaunch.value
            XCTFail("expected cancellation after the session started")
        } catch is CancellationError {
            // Expected: rollback shuts down the already-spawned session.
        }

        let processID = try XCTUnwrap(fixture.processIDsIfPresent().first)
        XCTAssertEqual(Darwin.kill(processID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let finalState = await controller.currentState
        XCTAssertEqual(finalState, .ready)
    }

    func testRepeatedCancelAndStopInterleavingsCannotLeakAcrossLaunchAttempts() async throws {
        let fixture = try ControllerGDBFixture(label: "interleaved")
        let gate = ControllerLaunchGate()
        let controller = DebuggerController(
            plan: fixture.plan(profile: .arm7tdmi),
            postStartSynchronization: { await gate.pause() }
        )

        for attempt in 1...6 {
            let invalidatedLaunch = Task { try await controller.launch() }
            try await waitForArrival(attempt, at: gate)
            try await waitForProcessCount(attempt, fixture: fixture)
            if attempt.isMultiple(of: 2) {
                try await controller.stop()
            } else {
                invalidatedLaunch.cancel()
            }
            await gate.release(attempt)
            do {
                try await invalidatedLaunch.value
                XCTFail("attempt \(attempt) should have been invalidated")
            } catch is CancellationError {
                // Expected for both direct cancellation and stop takeover.
            }
            let state = await controller.currentState
            XCTAssertEqual(state, .ready)
        }

        let processIDs = fixture.processIDsIfPresent()
        XCTAssertEqual(processIDs.count, 6)
        for processID in processIDs {
            XCTAssertEqual(Darwin.kill(processID, 0), -1, "pid \(processID) still exists")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testRapidStopAndRelaunchCyclesDoNotLeakOrDeadlock() async throws {
        let fixture = try ControllerGDBFixture()
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi))

        for _ in 0..<5 {
            try await controller.launch()
            try await waitForState(.stopped, controller: controller)
            try await controller.stop()
        }

        let processIDs = try fixture.processIDs()
        XCTAssertEqual(processIDs.count, 5)
        XCTAssertEqual(Set(processIDs).count, 5)
        for processID in processIDs {
            XCTAssertEqual(Darwin.kill(processID, 0), -1, "pid \(processID) still exists")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testControlMemoryAndBreakpointMethodsSendTypedMICommands() async throws {
        let fixture = try ControllerGDBFixture()
        let controller = DebuggerController(plan: fixture.plan(profile: .arm7tdmi))
        try await controller.launch()
        _ = try await waitForSnapshot(controller)

        let memory = try await controller.readMemory(
            DebugMemoryRequest(address: "0x2000", byteCount: 16)
        )
        XCTAssertEqual(memory.first?.begin.numeric, 0x1000)
        let breakpoint = try await controller.setBreakpoint("main.s:12")
        XCTAssertEqual(breakpoint.id, "7")
        try await controller.removeBreakpoint(breakpoint.id)
        try await controller.stepInstruction()
        try await controller.stepOver()

        let commands = try fixture.commands()
        XCTAssertTrue(commands.contains("-data-read-memory-bytes 0x2000 16"))
        XCTAssertTrue(commands.contains("-break-insert -- \"main.s:12\""))
        XCTAssertTrue(commands.contains("-break-delete 7"))
        XCTAssertTrue(commands.contains("-exec-step-instruction"))
        XCTAssertTrue(commands.contains("-exec-next"))
        try await controller.stop()
    }

    func testBuildAndLaunchFailuresRecoverToDocumentedStableStates() async throws {
        let profileController = DebuggerController(profile: .arm7tdmi)
        try await profileController.buildStarted()
        try await profileController.buildFailed()
        let buildFailureState = await profileController.currentState
        XCTAssertEqual(buildFailureState, .idle)

        let brokenPlan = DebugLaunchPlan(
            profile: .arm7tdmi,
            backend: .gdbSimulator,
            gdbExecutable: "/missing/gdb",
            gdbArguments: [],
            initCommands: [],
            warnings: [],
            elf: "/tmp/a.elf",
            projectDirectory: "/tmp"
        )
        let launchController = DebuggerController(plan: brokenPlan)
        do {
            try await launchController.launch()
            XCTFail("expected launch failure")
        } catch {
            let launchFailureState = await launchController.currentState
            XCTAssertEqual(launchFailureState, .ready)
        }
    }

    private func waitForSnapshot(_ controller: DebuggerController) async throws -> DebugSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let snapshot = await controller.latestSnapshot { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ControllerTestError.timeout
    }

    private func waitForSnapshot(
        _ controller: DebuggerController,
        fullName: String
    ) async throws -> DebugSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let snapshot = await controller.latestSnapshot,
               snapshot.location?.fullName == fullName {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ControllerTestError.timeout
    }

    private func waitForState(
        _ expected: DebuggerState,
        controller: DebuggerController
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await controller.currentState == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ControllerTestError.timeout
    }

    private func waitForCommand(
        _ command: String,
        fixture: ControllerGDBFixture
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if (try? fixture.commands().contains(command)) == true { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ControllerTestError.timeout
    }

    private func waitForArrival(
        _ expected: Int,
        at gate: ControllerLaunchGate
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await gate.arrivalCount >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ControllerTestError.timeout
    }

    private func waitForProcessCount(
        _ expected: Int,
        fixture: ControllerGDBFixture
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if fixture.processIDsIfPresent().count == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ControllerTestError.timeout
    }

    private func firstSnapshot(from stream: AsyncStream<DebuggerEvent>) async throws -> DebugSnapshot {
        for await event in stream {
            if case .snapshot(let snapshot) = event { return snapshot }
        }
        throw ControllerTestError.timeout
    }

}

private enum ControllerTestError: Error {
    case timeout
}

private actor ControllerLaunchGate {
    private(set) var arrivalCount = 0
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]

    func pause() async {
        arrivalCount += 1
        let arrival = arrivalCount
        await withCheckedContinuation { continuation in
            releases[arrival] = continuation
        }
    }

    func release(_ arrival: Int) {
        releases.removeValue(forKey: arrival)?.resume()
    }
}

private final class ControllerGDBFixture {
    let directory: URL
    let script: URL
    let capture: URL
    let failMemory: Bool
    let failCritical: Bool
    let hangFrame: Bool
    let hangStack: Bool
    let emitRunningWhileStackHung: Bool
    let autoExitWithStubbornChild: Bool
    let signalInterrupt: Bool
    let label: String
    let pidLog: URL
    let childPIDFile: URL

    init(
        failMemory: Bool = false,
        failCritical: Bool = false,
        hangFrame: Bool = false,
        hangStack: Bool = false,
        emitRunningWhileStackHung: Bool = false,
        autoExitWithStubbornChild: Bool = false,
        signalInterrupt: Bool = false,
        label: String = "课程"
    ) throws {
        self.failMemory = failMemory
        self.failCritical = failCritical
        self.hangFrame = hangFrame
        self.hangStack = hangStack
        self.emitRunningWhileStackHung = emitRunningWhileStackHung
        self.autoExitWithStubbornChild = autoExitWithStubbornChild
        self.signalInterrupt = signalInterrupt
        self.label = label
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("controller fake gdb.py")
        capture = directory.appendingPathComponent("commands.txt")
        pidLog = directory.appendingPathComponent("pids.txt")
        childPIDFile = directory.appendingPathComponent("child.pid")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    deinit {
        if let processIDs = try? processIDs() {
            for processID in processIDs { _ = Darwin.kill(processID, SIGKILL) }
        }
        if autoExitWithStubbornChild,
           let raw = try? String(contentsOf: childPIDFile, encoding: .utf8),
           let childPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = Darwin.kill(childPID, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func plan(
        profile: ProfileID,
        backend: DebugBackend = .gdbSimulator
    ) -> DebugLaunchPlan {
        DebugLaunchPlan(
            profile: profile,
            backend: backend,
            gdbExecutable: script.path,
            gdbArguments: [
                "--capture", capture.path,
                "--fail-memory", failMemory ? "yes" : "no",
                "--fail-critical", failCritical ? "yes" : "no",
                "--hang-frame", hangFrame ? "yes" : "no",
                "--hang-stack", hangStack ? "yes" : "no",
                "--emit-running-while-stack-hung", emitRunningWhileStackHung ? "yes" : "no",
                "--auto-exit-with-stubborn-child", autoExitWithStubbornChild ? "yes" : "no",
                "--signal-interrupt", signalInterrupt ? "yes" : "no",
                "--label", label,
                "--pid-log", pidLog.path,
                "--child-pid-file", childPIDFile.path
            ],
            initCommands: [],
            warnings: [],
            elf: directory.appendingPathComponent("demo.elf").path,
            projectDirectory: directory.path
        )
    }

    func commands() throws -> [String] {
        try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    func processIDs() throws -> [pid_t] {
        try String(contentsOf: pidLog, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { pid_t($0) }
    }

    func processIDsIfPresent() -> [pid_t] {
        (try? processIDs()) ?? []
    }

    func waitForChildPID() async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let raw = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let processID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return processID
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ControllerTestError.timeout
    }

    private static let source = #"""
#!/usr/bin/python3
import os, signal, sys, threading, time

capture = sys.argv[sys.argv.index("--capture") + 1]
fail_memory = sys.argv[sys.argv.index("--fail-memory") + 1] == "yes"
fail_critical = sys.argv[sys.argv.index("--fail-critical") + 1] == "yes"
hang_frame = sys.argv[sys.argv.index("--hang-frame") + 1] == "yes"
hang_stack = sys.argv[sys.argv.index("--hang-stack") + 1] == "yes"
emit_running_while_stack_hung = sys.argv[sys.argv.index("--emit-running-while-stack-hung") + 1] == "yes"
auto_exit_with_stubborn_child = sys.argv[sys.argv.index("--auto-exit-with-stubborn-child") + 1] == "yes"
signal_interrupt = sys.argv[sys.argv.index("--signal-interrupt") + 1] == "yes"
label = sys.argv[sys.argv.index("--label") + 1]
pid_log = sys.argv[sys.argv.index("--pid-log") + 1]
child_pid_file = sys.argv[sys.argv.index("--child-pid-file") + 1]

with open(pid_log, "a", encoding="utf-8") as handle:
    handle.write(str(os.getpid()) + "\n")

if auto_exit_with_stubborn_child:
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        while True:
            time.sleep(1)
    with open(child_pid_file, "w", encoding="utf-8") as handle:
        handle.write(str(child))

def out(value):
    sys.stdout.write(value + "\n")
    sys.stdout.flush()

running = False
def handle_sigint(_signum, _frame):
    global running
    if signal_interrupt and running:
        running = False
        out('*stopped,reason="signal-received",frame={addr="0x1000",func="main"}')

signal.signal(signal.SIGINT, handle_sigint)

for value in range(1, 6):
    out('~"console-%d"' % value)
out('*stopped,reason="breakpoint-hit",frame={addr="0x1000",func="main",file="main.s",fullname="/tmp/%s/main.s",line="12"}' % label)

if auto_exit_with_stubborn_child:
    time.sleep(0.05)
    sys.exit(17)

for raw in sys.stdin:
    raw = raw.rstrip("\r\n")
    pos = 0
    while pos < len(raw) and raw[pos].isdigit():
        pos += 1
    token, command = raw[:pos], raw[pos:]
    with open(capture, "a", encoding="utf-8") as handle:
        handle.write(command + "\n")
    if command == "-stack-info-frame":
        if hang_frame:
            pass
        elif fail_critical:
            out(token + '^error,msg="frame unavailable"')
        else:
            out(token + '^done,frame={addr="0x1000",func="main",file="main.s",fullname="/tmp/%s/main.s",line="12"}' % label)
    elif command == "-data-list-register-names":
        if fail_critical:
            out(token + '^error,msg="registers unavailable"')
        else:
            names = ["r%d" % value for value in range(13)] + ["SP", "lr", "Pc", "", "CPSR", "xPsR", "msp", "", "control", "primask"]
            out(token + '^done,register-names=[' + ','.join('"%s"' % value for value in names) + ']')
    elif command == "-data-list-register-values x":
        out(token + '^done,register-values=[{number="17",value="0x60000013"},{number="14",value="0x100"},{number="0",value="42"},{number="15",value="0x104"},{number="18",value="0x01000000"},{number="13",value="0x20001000"},{number="19",value="0x20001000"},{number="21",value="0"},{number="22",value="1"}]')
    elif command == "-stack-list-frames":
        if hang_stack:
            if emit_running_while_stack_hung:
                threading.Thread(target=lambda: (time.sleep(0.02), out("*running,thread-id=\"all\"")), daemon=True).start()
        else:
            out(token + '^done,stack=[frame={addr="0x1000",func="main",line="12"},frame={addr="0x2000",func="reset"}]')
    elif command.startswith("-data-read-memory-bytes"):
        if fail_memory:
            out(token + '^error,msg="memory unavailable"')
        else:
            out(token + '^done,memory=[{begin="0x1000",offset="0",end="0x1004",contents="002affff"}]')
    elif command.startswith("-data-disassemble"):
        out(token + '^done,asm_insns=[{address="0x1000",func-name="main",offset="0",inst="mov r0, #42"}]')
    elif command == "-exec-continue":
        out(token + "^done")
        running = True
        threading.Thread(target=lambda: (time.sleep(0.15), out("*running,thread-id=\"all\"")), daemon=True).start()
    elif command == "-exec-interrupt --all":
        if signal_interrupt:
            out(token + '^error,msg="simulator MI interrupt unsupported"')
        else:
            out(token + "^done")
            out('*stopped,reason="signal-received",frame={addr="0x1000",func="main"}')
    elif command.startswith("-break-insert"):
        out(token + '^done,bkpt={number="7",addr="0x1000"}')
    elif command == "-gdb-exit":
        if not (signal_interrupt and running):
            out(token + "^exit")
            sys.exit(0)
    else:
        out(token + "^done")
"""#
}

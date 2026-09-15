// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import XCTest
@testable import YagartoAppSupport

final class CoreServiceIntegrationTests: XCTestCase {
    func testCoreBuildServiceRunsRealConfigPlannerAndExecutor() async throws {
        let fixture = try CoreServiceFixture()
        let service = CoreBuildService(overrides: fixture.toolOverrides)

        let result = try await service.build(projectDirectory: fixture.directory)

        XCTAssertEqual(result.configuration.profile, .arm7tdmi)
        XCTAssertEqual(result.elf.lastPathComponent, "课程固件.elf")
        let extensions = Set(result.artifacts.map(\.pathExtension))
        XCTAssertTrue(Set(["elf", "map", "bin", "lst"]).isSubset(of: extensions))
        XCTAssertTrue(result.artifacts.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(result.output.contains("listing"))
    }

    func testCoreBuildServiceMapsRealExecutorFailureToStructuredDiagnostic() async throws {
        let fixture = try CoreServiceFixture(failBuild: true)
        let service = CoreBuildService(overrides: fixture.toolOverrides)

        do {
            _ = try await service.build(projectDirectory: fixture.directory)
            XCTFail("Expected build failure")
        } catch let error as BuildServiceFailure {
            XCTAssertTrue(error.message.contains("构建"))
            XCTAssertEqual(error.diagnostics.first?.line, 2)
            XCTAssertEqual(error.diagnostics.first?.severity, .error)
            XCTAssertLessThanOrEqual(error.output.utf8.count, BuildDiagnosticParser.defaultOutputLimit)
        }
    }

    func testCoreDebugAdapterUsesDebugPlannerForBothModes() async throws {
        let fixture = try CoreServiceFixture()
        let build = AppBuildResult(
            configuration: fixture.configuration,
            projectDirectory: fixture.directory,
            elf: fixture.directory.appendingPathComponent("firmware.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        )
        let adapter = CoreDebugAdapter(
            overrides: [.gdb: "/usr/bin/true"],
            gdbSimulatorPath: "/usr/bin/true"
        )

        try await adapter.prepare(build)

        let backend = await adapter.preparedBackend
        let modes = await adapter.preparedModes
        XCTAssertEqual(backend, .gdbSimulator)
        XCTAssertEqual(modes, [.debug, .run])
    }

    func testCoreDebugAdapterRunsRealMIThroughSnapshotStepBreakpointAndReap() async throws {
        let fixture = try AdapterMIFixture()
        let configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["main.s"],
            outputName: "adapter"
        )
        try ConfigStore(projectDirectory: fixture.directory).save(configuration)
        try Data("MOV r0, #1\nMOV r0, #2\n".utf8)
            .write(to: fixture.directory.appendingPathComponent("main.s"))
        let build = AppBuildResult(
            configuration: configuration,
            projectDirectory: fixture.directory,
            elf: fixture.directory.appendingPathComponent("adapter.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        )
        let adapter = CoreDebugAdapter(
            overrides: [.gdb: fixture.script.path],
            gdbSimulatorPath: fixture.script.path
        )
        let initialEvents = await adapter.events()
        try await adapter.prepare(build)

        let launch = try await adapter.launch(
            mode: .debug,
            breakpoints: [DebugSourceBreakpoint(
                file: fixture.directory.appendingPathComponent("main.s"),
                line: 2
            )]
        )
        let initial = try await firstSnapshot(from: initialEvents)

        XCTAssertEqual(launch.breakpointIdentifiers, [2: "7"])
        XCTAssertTrue(launch.failures.isEmpty)
        XCTAssertEqual(initial.location?.line?.numeric, 1)
        XCTAssertEqual(initial.registers.first?.value?.numeric, 1)
        let processIdentifier = try fixture.processIdentifier()
        XCTAssertEqual(kill(processIdentifier, 0), 0)

        let stepEvents = await adapter.events()
        try await adapter.stepInstruction()
        let stepped = try await firstSnapshot(from: stepEvents)
        XCTAssertEqual(stepped.location?.line?.numeric, 2)
        XCTAssertEqual(stepped.registers.first?.value?.numeric, 2)

        try await adapter.stop()
        try await waitUntilProcessIsGone(processIdentifier)
        let commands = try fixture.commands()
        XCTAssertTrue(commands.contains { $0.hasPrefix("-break-insert -- ") })
        XCTAssertTrue(commands.contains("-exec-step-instruction"))
        XCTAssertTrue(commands.contains("-gdb-exit"))
    }

    func testCoreDebugAdapterAppliesPendingAndActiveMemoryRequestsThenResetsAfterStop() async throws {
        let fixture = try AdapterMIFixture()
        let adapter = CoreDebugAdapter(
            overrides: [.gdb: fixture.script.path],
            gdbSimulatorPath: fixture.script.path
        )
        try await adapter.prepare(adapterBuild(for: fixture.directory))
        try await adapter.setMemoryRequest(
            DebugMemoryRequest(address: "0x9000", byteCount: 112)
        )

        let initialEvents = await adapter.events()
        _ = try await adapter.launch(mode: .debug, breakpoints: [])
        _ = try await firstSnapshot(from: initialEvents)
        let commandsBeforeActiveRequest = try fixture.commands()

        try await adapter.setMemoryRequest(
            DebugMemoryRequest(address: "0xA000", byteCount: 112)
        )

        XCTAssertEqual(try fixture.commands(), commandsBeforeActiveRequest)
        let stepEvents = await adapter.events()
        try await adapter.stepInstruction()
        _ = try await firstSnapshot(from: stepEvents)
        try await adapter.stop()

        let relaunchedEvents = await adapter.events()
        _ = try await adapter.launch(mode: .debug, breakpoints: [])
        _ = try await firstSnapshot(from: relaunchedEvents)
        let requests = try fixture.commands().filter {
            $0.hasPrefix("-data-read-memory-bytes")
        }
        XCTAssertEqual(requests, [
            "-data-read-memory-bytes 0x9000 112",
            "-data-read-memory-bytes 0xA000 112",
            "-data-read-memory-bytes 0x8000 112"
        ])
        try await adapter.stop()
    }

    func testCoreDebugAdapterStopWithoutSessionResetsPendingMemoryRequest() async throws {
        let fixture = try AdapterMIFixture()
        let adapter = CoreDebugAdapter(
            overrides: [.gdb: fixture.script.path],
            gdbSimulatorPath: fixture.script.path
        )
        try await adapter.prepare(adapterBuild(for: fixture.directory))
        try await adapter.setMemoryRequest(
            DebugMemoryRequest(address: "0x9000", byteCount: 112)
        )

        try await adapter.stop()

        let events = await adapter.events()
        _ = try await adapter.launch(mode: .debug, breakpoints: [])
        _ = try await firstSnapshot(from: events)
        XCTAssertTrue(
            try fixture.commands().contains("-data-read-memory-bytes 0x8000 112")
        )
        XCTAssertFalse(
            try fixture.commands().contains("-data-read-memory-bytes 0x9000 112")
        )
        try await adapter.stop()
    }

    func testCoreDebugAdapterSynchronizesSafeBreakpointBeforeRunAndRejectsOutsidePath() async throws {
        let fixture = try AdapterMIFixture()
        let configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["main.s"],
            outputName: "adapter"
        )
        try ConfigStore(projectDirectory: fixture.directory).save(configuration)
        let source = fixture.directory.appendingPathComponent("main.s")
        try Data("MOV r0, #1\n".utf8).write(to: source)
        let adapter = CoreDebugAdapter(
            overrides: [.gdb: fixture.script.path],
            gdbSimulatorPath: fixture.script.path
        )
        try await adapter.prepare(AppBuildResult(
            configuration: configuration,
            projectDirectory: fixture.directory,
            elf: fixture.directory.appendingPathComponent("adapter.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        ))

        let result = try await adapter.launch(mode: .run, breakpoints: [
            DebugSourceBreakpoint(file: source, line: 1),
            DebugSourceBreakpoint(file: URL(fileURLWithPath: "/tmp/foreign.s"), line: 9)
        ])

        XCTAssertEqual(result.breakpointIdentifiers, [1: "7"])
        XCTAssertEqual(result.failures.map(\.breakpoint.line), [9])
        let commands = try fixture.commands()
        let breakpointIndex = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("-break-insert -- ") })
        let continueIndex = try XCTUnwrap(commands.firstIndex(of: "-exec-continue"))
        XCTAssertLessThan(breakpointIndex, continueIndex)
        try await adapter.stop()
        try await waitUntilProcessIsGone(fixture.processIdentifier())
    }

    func testCoreDebugAdapterOldStopCannotClearOrCancelNewSession() async throws {
        let fixture = try AdapterSessionGenerationFixture()
        let configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["main.s"],
            outputName: "adapter-generation"
        )
        try ConfigStore(projectDirectory: fixture.directory).save(configuration)
        try Data("MOV r0, #1\n".utf8).write(to: fixture.directory.appendingPathComponent("main.s"))
        let build = AppBuildResult(
            configuration: configuration,
            projectDirectory: fixture.directory,
            elf: fixture.directory.appendingPathComponent("adapter-generation.elf"),
            artifacts: [],
            diagnostics: [],
            output: ""
        )
        let adapter = CoreDebugAdapter(
            overrides: [.gdb: fixture.script.path],
            gdbSimulatorPath: fixture.script.path
        )
        try await adapter.prepare(build)

        let firstEvents = await adapter.events()
        _ = try await adapter.launch(mode: .debug, breakpoints: [])
        _ = try await firstSnapshot(from: firstEvents)
        let firstPIDs = try await fixture.waitForProcessCount(1)
        let firstPID = try XCTUnwrap(firstPIDs.first)

        let oldStop = Task { try await adapter.stop() }
        try await fixture.waitForCommand("-gdb-exit", from: firstPID)
        try await adapter.setMemoryRequest(
            DebugMemoryRequest(address: "0xA000", byteCount: 112)
        )

        let secondEvents = await adapter.events()
        _ = try await adapter.launch(mode: .debug, breakpoints: [])
        _ = try await firstSnapshot(from: secondEvents)
        let processIdentifiers = try await fixture.waitForProcessCount(2)
        let secondPID = try XCTUnwrap(processIdentifiers.first { $0 != firstPID })
        try await oldStop.value

        XCTAssertEqual(kill(secondPID, 0), 0, "旧 stop 不得终止新会话")
        XCTAssertTrue(
            try fixture.commands(from: secondPID)
                .contains("-data-read-memory-bytes 0xA000 112"),
            "旧 stop 不得覆盖其启动后收到的新内存窗口"
        )
        try await adapter.stop()
        try await waitUntilProcessIsGone(secondPID)
        try await waitUntilProcessIsGone(firstPID)

        let thirdEvents = await adapter.events()
        _ = try await adapter.launch(mode: .debug, breakpoints: [])
        _ = try await firstSnapshot(from: thirdEvents)
        let thirdPIDs = try await fixture.waitForProcessCount(3)
        let thirdPID = try XCTUnwrap(thirdPIDs.first { $0 != firstPID && $0 != secondPID })
        try await adapter.stop()
        try await waitUntilProcessIsGone(thirdPID)
    }
}

private func adapterBuild(for directory: URL) -> AppBuildResult {
    let configuration = ProjectConfiguration(
        profile: .arm7tdmi,
        entry: "start",
        sources: ["main.s"],
        outputName: "adapter"
    )
    return AppBuildResult(
        configuration: configuration,
        projectDirectory: directory,
        elf: directory.appendingPathComponent("adapter.elf"),
        artifacts: [],
        diagnostics: [],
        output: ""
    )
}

private func firstSnapshot(
    from stream: AsyncStream<DebuggerEvent>,
    timeout: Duration = .seconds(3)
) async throws -> DebugSnapshot {
    try await withThrowingTaskGroup(of: DebugSnapshot.self) { group in
        group.addTask {
            for await event in stream {
                if case .snapshot(let snapshot) = event { return snapshot }
            }
            throw AdapterMITestError.timeout
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw AdapterMITestError.timeout
        }
        defer { group.cancelAll() }
        guard let snapshot = try await group.next() else { throw AdapterMITestError.timeout }
        return snapshot
    }
}

private func waitUntilProcessIsGone(_ processIdentifier: pid_t) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if kill(processIdentifier, 0) == -1, errno == ESRCH { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AdapterMITestError.timeout
}

private enum AdapterMITestError: Error {
    case timeout
}

private final class AdapterMIFixture: @unchecked Sendable {
    let directory: URL
    let script: URL
    private let pidFile: URL
    private let commandFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Adapter MI 中文 空格 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fake adapter gdb.py")
        pidFile = directory.appendingPathComponent("gdb.pid")
        commandFile = directory.appendingPathComponent("commands.txt")
        try Data(Self.source.utf8).write(to: script)
        guard chmod(script.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    deinit {
        if let processIdentifier = try? processIdentifier() {
            _ = kill(processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func processIdentifier() throws -> pid_t {
        let raw = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processIdentifier = pid_t(raw) else { throw AdapterMITestError.timeout }
        return processIdentifier
    }

    func commands() throws -> [String] {
        try String(contentsOf: commandFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    private static let source = #"""
#!/usr/bin/python3
import os, sys, threading, time

root = os.path.dirname(os.path.realpath(__file__))
pid_file = os.path.join(root, "gdb.pid")
command_file = os.path.join(root, "commands.txt")
source_file = os.path.join(root, "main.s").replace("\\", "\\\\").replace('"', '\\"')
with open(pid_file, "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))

def out(value):
    sys.stdout.write(value + "\n")
    sys.stdout.flush()

def stopped(line):
    out('*stopped,reason="end-stepping-range",frame={addr="0x100",func="start",file="main.s",fullname="%s",line="%d"}' % (source_file, line))

out("(gdb)")
stopped(1)
current_line = 1
for raw in sys.stdin:
    raw = raw.rstrip("\r\n")
    index = 0
    while index < len(raw) and raw[index].isdigit():
        index += 1
    token, command = raw[:index], raw[index:]
    with open(command_file, "a", encoding="utf-8") as handle:
        handle.write(command + "\n")
    if command == "-stack-info-frame":
        out(token + '^done,frame={addr="0x100",func="start",file="main.s",fullname="%s",line="%d"}' % (source_file, current_line))
    elif command == "-data-list-register-names":
        out(token + '^done,register-names=["r0","r1","sp","lr","pc","cpsr"]')
    elif command == "-data-list-register-values x":
        out(token + '^done,register-values=[{number="0",value="0x%d"}]' % current_line)
    elif command == "-stack-list-frames":
        out(token + '^done,stack=[frame={addr="0x100",func="start",file="main.s",line="%d"}]' % current_line)
    elif command.startswith("-data-read-memory-bytes"):
        out(token + '^done,memory=[{begin="0x2000",offset="0",end="0x2004",contents="00000000"}]')
    elif command.startswith("-data-disassemble"):
        out(token + '^done,asm_insns=[{address="0x100",func-name="start",offset="0",inst="mov r0, #1"}]')
    elif command.startswith("-break-insert -- "):
        out(token + '^done,bkpt={number="7",addr="0x100"}')
    elif command == "-exec-step-instruction":
        current_line = 2
        out(token + "^running")
        out('*running,thread-id="all"')
        threading.Thread(target=lambda: (time.sleep(0.03), stopped(2)), daemon=True).start()
    elif command == "-exec-continue":
        out(token + "^running")
        out('*running,thread-id="all"')
    elif command == "-gdb-exit":
        out(token + "^exit")
        sys.exit(0)
    else:
        out(token + "^done")
"""#
}

private final class AdapterSessionGenerationFixture: @unchecked Sendable {
    let directory: URL
    let script: URL
    private let pidFile: URL
    private let commandFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Adapter Session Generation \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("fake delayed exit gdb.py")
        pidFile = directory.appendingPathComponent("pids.txt")
        commandFile = directory.appendingPathComponent("commands.txt")
        try Data(Self.source.utf8).write(to: script)
        guard chmod(script.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    deinit {
        for processIdentifier in processIdentifiers() {
            _ = kill(processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForProcessCount(_ count: Int) async throws -> [pid_t] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let values = processIdentifiers()
            if values.count >= count { return values }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AdapterMITestError.timeout
    }

    func waitForCommand(_ command: String, from processIdentifier: pid_t) async throws {
        let expected = "\(processIdentifier):\(command)"
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let text = (try? String(contentsOf: commandFile, encoding: .utf8)) ?? ""
            if text.split(separator: "\n").contains(Substring(expected)) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AdapterMITestError.timeout
    }

    func commands(from processIdentifier: pid_t) throws -> [String] {
        try String(contentsOf: commandFile, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                let prefix = "\(processIdentifier):"
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }
    }

    private func processIdentifiers() -> [pid_t] {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    private static let source = #"""
#!/usr/bin/python3
import os, sys, time

root = os.path.dirname(os.path.realpath(__file__))
pid = os.getpid()
pid_file = os.path.join(root, "pids.txt")
command_file = os.path.join(root, "commands.txt")
source_file = os.path.join(root, "main.s").replace("\\", "\\\\").replace('"', '\\"')
with open(pid_file, "a", encoding="utf-8") as handle:
    handle.write(str(pid) + "\n")

def out(value):
    sys.stdout.write(value + "\n")
    sys.stdout.flush()

out("(gdb)")
out('*stopped,reason="end-stepping-range",frame={addr="0x100",func="start",file="main.s",fullname="%s",line="1"}' % source_file)
for raw in sys.stdin:
    raw = raw.rstrip("\r\n")
    index = 0
    while index < len(raw) and raw[index].isdigit():
        index += 1
    token, command = raw[:index], raw[index:]
    with open(command_file, "a", encoding="utf-8") as handle:
        handle.write("%d:%s\n" % (pid, command))
    if command == "-stack-info-frame":
        out(token + '^done,frame={addr="0x100",func="start",file="main.s",fullname="%s",line="1"}' % source_file)
    elif command == "-data-list-register-names":
        out(token + '^done,register-names=["r0"]')
    elif command == "-data-list-register-values x":
        out(token + '^done,register-values=[{number="0",value="0x1"}]')
    elif command == "-stack-list-frames":
        out(token + '^done,stack=[]')
    elif command.startswith("-data-read-memory-bytes"):
        out(token + '^done,memory=[]')
    elif command.startswith("-data-disassemble"):
        out(token + '^done,asm_insns=[]')
    elif command == "-gdb-exit":
        time.sleep(0.35)
        out(token + "^exit")
        sys.exit(0)
    else:
        out(token + "^done")
"""#
}

private struct CoreServiceFixture {
    let directory: URL
    let configuration: ProjectConfiguration
    let toolOverrides: [ToolIdentifier: String]

    init(failBuild: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Core 服务 \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configuration = ProjectConfiguration(
            profile: .arm7tdmi,
            entry: "start",
            sources: ["主 程序.s"],
            outputName: "课程固件"
        )
        try ConfigStore(projectDirectory: directory).save(configuration)
        try Data(".global start\nstart: MOV r0, #1\n".utf8)
            .write(to: directory.appendingPathComponent("主 程序.s"))
        let tool = directory.appendingPathComponent("fake-arm-tool")
        let failureLine = failBuild
            ? "echo \"$PWD/主 程序.s:2: Error: bad instruction\" >&2; exit 1"
            : ""
        let script = """
        #!/bin/sh
        set -eu
        \(failureLine)
        output=""
        map=""
        previous=""
        last=""
        for argument in "$@"; do
          if [ "$previous" = "-o" ]; then output="$argument"; fi
          if [ "$previous" = "-Map" ]; then map="$argument"; fi
          previous="$argument"
          last="$argument"
        done
        if [ -n "$output" ]; then mkdir -p "$(dirname "$output")"; : > "$output"; fi
        if [ -n "$map" ]; then : > "$map"; fi
        if [ "${1:-}" = "-O" ]; then : > "$last"; fi
        if [ "${1:-}" = "-d" ]; then echo "listing"; fi
        """
        try Data(script.utf8).write(to: tool)
        guard chmod(tool.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        toolOverrides = [
            .assembler: tool.path,
            .compiler: tool.path,
            .linker: tool.path,
            .objcopy: tool.path,
            .objdump: tool.path
        ]
    }
}
